import Foundation

/// The session calls the scrobbler makes. `GSClient` is the real one; tests
/// use a fake that answers from memory.
///
/// A protocol instead of `GSClient` itself is *dependency injection*: the
/// scrobbler only knows "something that can start, heartbeat and finish",
/// so a test can hand it a fake and check exactly which calls it made.
public protocol SessionAPI: Sendable {
    func startSession(_ start: StartSessionRequest, idempotencyKey: String) async throws(GSClientError) -> GSSession
    func heartbeat(sessionID: String) async throws(GSClientError) -> GSSession
    func finishSession(id: String, endedAt: Date?, idempotencyKey: String) async throws(GSClientError) -> GSSession
}

/// `GSClient` already has these three methods, so an empty extension is
/// enough to declare that it conforms.
extension GSClient: SessionAPI {}

/// Something the scrobbler reacts to. Each carries the time it happened,
/// stamped when the event is created, so a slow network call never shifts it.
public enum ScrobbleEvent: Sendable, Equatable {
    case started(DetectedGame, at: Date)
    case stopped(DetectedGame, at: Date)
    /// The clock moved on: a chance to send a heartbeat that is due.
    case tick(Date)
    /// Finish the open session and forget every game (scrobbling turned off,
    /// or the token changed).
    case stopAll(at: Date)
}

/// What the menu shows about scrobbling.
public enum ScrobbleStatus: Sendable, Equatable {
    case idle
    case scrobbling(DetectedGame, since: Date)
    /// A start or finish failed. Not retried yet (the outbox, step 11).
    case failed(DetectedGame, GSClientError)
    /// The server refused the token (401 or 403). Nothing more is sent until
    /// the token changes, so a bad token cannot burn through the rate limits.
    case signedOut(GSClientError)
}

/// Turns "game started / stopped" into GameScrobbler play sessions.
///
/// The rules:
/// - One session at a time, for the game that started last ("newest wins"):
///   the server keeps one open session per device anyway. When that game
///   quits, the game that was running before it gets a new session.
/// - A heartbeat every `heartbeatInterval` (5 minutes) keeps the session open.
/// - A heartbeat answered 409 or 404 means the server already closed the
///   session (45 silent minutes, or the 24-hour limit): start a new one.
///
/// API docs: https://developers.gamescrobbler.com/guides/recording-play/#the-full-path-sessions
///
/// **Call `handle` from one loop, one event at a time.** An actor protects
/// its state from two threads at once, but at every `await` inside it another
/// call may run (*actor reentrancy*), so a "stopped" could slip in while the
/// "start" request is still out. The app therefore puts every event into one
/// `AsyncStream` and handles them in order.
public actor Scrobbler {
    /// The session the server has open for the newest game.
    struct OpenSession {
        let game: DetectedGame
        let id: String
        var nextHeartbeat: Date
    }

    private let api: any SessionAPI
    private let deviceID: String
    private let heartbeatInterval: TimeInterval
    private let makeID: @Sendable () -> String

    /// Running games, oldest first. The last one is the one being scrobbled.
    private var games: [DetectedGame] = []
    private var current: OpenSession?

    public private(set) var status: ScrobbleStatus = .idle
    /// The session finished most recently, as the server recorded it.
    public private(set) var lastFinished: GSSession?

    /// - Parameters:
    ///   - deviceID: one stable id per Mac; a new session on the same device
    ///     ends the previous one on the server.
    ///   - heartbeatInterval: seconds between heartbeats; the guide suggests 5
    ///     minutes and the server closes a session after 45 silent ones.
    ///   - makeID: makes `clientSessionId`s and idempotency keys. Tests pass a
    ///     counter so the ids are predictable.
    public init(
        api: any SessionAPI,
        deviceID: String,
        heartbeatInterval: TimeInterval = 5 * 60,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.api = api
        self.deviceID = deviceID
        self.heartbeatInterval = heartbeatInterval
        self.makeID = makeID
    }

    public func handle(_ event: ScrobbleEvent) async {
        if isSignedOut { return }
        switch event {
        case .started(let game, let time):
            await gameStarted(game, at: time)
        case .stopped(let game, let time):
            await gameStopped(game, at: time)
        case .tick(let now):
            await sendHeartbeatIfDue(now: now)
        case .stopAll(let time):
            games.removeAll()
            if let session = current { await finish(session, at: time) }
        }
    }

    // MARK: - Events

    private func gameStarted(_ game: DetectedGame, at time: Date) async {
        guard !games.contains(where: { $0.id == game.id }) else { return }
        games.append(game)
        // Newest wins: end the older game's session first, then start this one.
        if let previous = current {
            await finish(previous, at: time)
        }
        if !isSignedOut { await start(game, at: time) }
    }

    private func gameStopped(_ game: DetectedGame, at time: Date) async {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let wasNewest = index == games.count - 1
        games.remove(at: index)
        // An older game quitting changes nothing on the server.
        guard wasNewest else { return }

        if let session = current, session.game.id == game.id {
            await finish(session, at: time)
        } else if case .failed(let failedGame, _) = status, failedGame.id == game.id {
            status = .idle  // its start had failed; nothing to finish
        }
        // The game that was running before this one takes over.
        if let next = games.last, !isSignedOut {
            await start(next, at: time)
        }
    }

    private func sendHeartbeatIfDue(now: Date) async {
        guard let session = current, now >= session.nextHeartbeat else { return }
        do throws(GSClientError) {
            _ = try await api.heartbeat(sessionID: session.id)
            reschedule(session.id, to: now + heartbeatInterval)
        } catch .api(let error) where error.status == 409 || error.status == 404 {
            // The server already closed it. Start exactly one fresh session.
            guard current?.id == session.id else { return }
            current = nil
            await start(session.game, at: now)
        } catch .api(let error) where error.status == 401 || error.status == 403 {
            status = .signedOut(.api(error))
        } catch {
            // Rate limited or overloaded: wait as long as the server asks.
            // `if case` matches one enum case and binds its value; the `,`
            // adds a second condition that must also hold.
            if case .api(let apiError) = error, let wait = apiError.retryAfter {
                reschedule(session.id, to: now + Self.seconds(wait))
            }
            // Otherwise (offline, a server error) the schedule stays as it
            // is, so the next tick, a minute later, tries again.
        }
    }

    // MARK: - API calls

    private func start(_ game: DetectedGame, at time: Date) async {
        // The body and its key are built exactly once. A retry (step 11) must
        // send this same body with this same key, or the server answers 409
        // idempotency_conflict.
        let request = StartSessionRequest(
            game: game.defaultRef,
            deviceId: deviceID,
            clientSessionId: makeID(),
            startedAt: time
        )
        let key = makeID()
        do throws(GSClientError) {
            let session = try await api.startSession(request, idempotencyKey: key)
            current = OpenSession(game: game, id: session.id, nextHeartbeat: time + heartbeatInterval)
            status = .scrobbling(game, since: time)
        } catch {
            status = error.isAuthFailure ? .signedOut(error) : .failed(game, error)
        }
    }

    private func finish(_ session: OpenSession, at time: Date) async {
        // Change the state *before* the `await`: whatever the server answers,
        // this session is over on our side.
        current = nil
        let key = makeID()
        do throws(GSClientError) {
            lastFinished = try await api.finishSession(id: session.id, endedAt: time, idempotencyKey: key)
            status = .idle
        } catch .api(let error) where error.status == 409 {
            status = .idle  // already finished on the server: nothing was lost
        } catch {
            status = error.isAuthFailure ? .signedOut(error) : .failed(session.game, error)
        }
    }

    // MARK: - Helpers

    private var isSignedOut: Bool {
        if case .signedOut = status { return true }
        return false
    }

    /// Moves the next heartbeat, but only if that session is still the open one.
    private func reschedule(_ sessionID: String, to date: Date) {
        guard current?.id == sessionID else { return }
        current?.nextHeartbeat = date
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
    }
}

extension GSClientError {
    /// 401 or 403: the token is wrong, expired, revoked or lacks a scope.
    var isAuthFailure: Bool {
        if case .api(let error) = self { return error.status == 401 || error.status == 403 }
        return false
    }
}
