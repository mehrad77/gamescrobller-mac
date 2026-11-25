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
    /// The clock moved on: a chance to send a heartbeat, or a retry, that is due.
    case tick(Date)
    /// End the open play and forget every game (scrobbling turned off, the
    /// token changed, or the app is quitting).
    case stopAll(at: Date)

    var time: Date {
        switch self {
        case .started(_, let time), .stopped(_, let time), .tick(let time), .stopAll(let time):
            time
        }
    }
}

/// What the menu shows about scrobbling.
public enum ScrobbleStatus: Sendable, Equatable {
    case idle
    case scrobbling(DetectedGame, since: Date)
    /// The server could not be reached, or asked us to wait. The plays are
    /// kept in the journal, and nothing is sent before `until`.
    case waiting(until: Date, GSClientError)
    /// The server refused the play of the game being played (404: not in
    /// your library, an unknown game, or writes turned off). It stays in the
    /// journal and is tried again at the next launch.
    case failed(DetectedGame, GSClientError)
    /// The server refused the token (401 or 403). Nothing more is sent until
    /// the token changes, so a bad token cannot burn through the rate limits.
    /// Plays are still kept, for the next token.
    case signedOut(GSClientError)
}

/// Turns "game started / stopped" into GameScrobbler play sessions.
///
/// The rules:
/// - One play at a time, for the game that started last ("newest wins"):
///   the server keeps one open session per device anyway. When that game
///   quits, the game that was running before it gets a new play.
/// - Every play goes into the `PlayJournal` first and leaves it only once
///   the server has all of it, so a quit, a crash or a night offline loses
///   nothing.
/// - Plays are sent oldest first. A failure that may clear by itself
///   (offline, rate limited, server trouble) stops the whole pass and waits
///   1, 2, 4, then 5 minutes, or as long as the server asks.
/// - A heartbeat every `heartbeatInterval` (5 minutes) keeps the open session
///   open. A heartbeat answered 409 or 404 means the server already closed
///   it (45 silent minutes, or the 24-hour limit): a new play begins.
///
/// API docs: https://developers.gamescrobbler.com/guides/recording-play/#the-full-path-sessions
///
/// **Call `handle` from one loop, one event at a time.** An actor protects
/// its state from two threads at once, but at every `await` inside it another
/// call may run (*actor reentrancy*), so a "stopped" could slip in while the
/// "start" request is still out. The app therefore puts every event into one
/// `AsyncStream` and handles them in order.
public actor Scrobbler {
    /// How far back the server accepts a finished session: 7 days. An hour
    /// less, so a slightly wrong clock is not refused.
    static let maxPlayAge: TimeInterval = 7 * 24 * 60 * 60 - 60 * 60
    /// The longest session the server accepts.
    static let maxPlayLength: TimeInterval = 24 * 60 * 60
    /// The waits after 1, 2, 3, and 4 or more failures in a row.
    static let backoff: [TimeInterval] = [60, 120, 240, 300]

    private let api: any SessionAPI
    private let deviceID: String
    private let journal: PlayJournal
    private let heartbeatInterval: TimeInterval
    private let makeID: @Sendable () -> String

    /// Running games, oldest first. The last one is the one being scrobbled.
    private var games: [DetectedGame] = []
    /// The plays not yet fully sent, oldest first: what the journal file
    /// holds. At most one has no `endedAt`, the last: the newest game's play.
    private var plays: [Play]
    /// When the open play's next heartbeat is due.
    private var nextHeartbeat: Date?
    /// Plays the server refused on this run, by play id. They stay in the
    /// journal and are sent again at the next launch, but do not hold up the
    /// plays behind them. Kept in memory only, on purpose.
    private var refused: [String: GSClientError] = [:]
    /// Set after a failure that may clear by itself: nothing is sent before
    /// `retryAt`.
    private var retryAt: Date?
    private var lastFailure: GSClientError?
    private var failuresInARow = 0
    private var signedOutError: GSClientError?

    public private(set) var status: ScrobbleStatus = .idle
    /// The session finished most recently, as the server recorded it.
    public private(set) var lastFinished: GSSession?

    /// Plays that still need a request, for the menu.
    public var unsentCount: Int {
        plays.count { $0.nextRequest != nil }
    }

    /// Reads the journal, so plays left over from the last run are sent too.
    ///
    /// - Parameters:
    ///   - deviceID: one stable id per Mac; a new session on the same device
    ///     ends the previous one on the server.
    ///   - journal: where the plays are kept; one per server.
    ///   - now: the time of the launch, to drop the plays the server would
    ///     refuse as too old.
    ///   - heartbeatInterval: seconds between heartbeats; the guide suggests 5
    ///     minutes and the server closes a session after 45 silent ones.
    ///   - makeID: makes `clientSessionId`s and idempotency keys. Tests pass a
    ///     counter so the ids are predictable.
    public init(
        api: any SessionAPI,
        deviceID: String,
        journal: PlayJournal,
        now: Date = .now,
        heartbeatInterval: TimeInterval = 5 * 60,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.api = api
        self.deviceID = deviceID
        self.journal = journal
        self.heartbeatInterval = heartbeatInterval
        self.makeID = makeID

        var saved: [Play]
        do {
            saved = try journal.load()
        } catch {
            // Never overwrite a file we cannot read: it moves aside, and a
            // new journal starts.
            try? journal.setAside()
            saved = []
        }
        // A play with no end means the app quit or crashed while its game
        // ran. It ends where the app last saw the game running.
        for index in saved.indices where saved[index].endedAt == nil {
            saved[index].end(at: saved[index].lastSeenAt, newKey: makeID())
        }
        saved.removeAll { Self.isTooOld($0, at: now) }
        // A local copy is saved, not `self.plays`: in an initializer that is
        // not `async`, an actor's own state is off limits once it is set up.
        try? journal.save(saved)
        plays = saved
    }

    public func handle(_ event: ScrobbleEvent) async {
        // First the journal: what happened is written down before anything
        // goes out, so a request cut short by a quit is sent again later.
        switch event {
        case .started(let game, let time):
            gameStarted(game, at: time)
        case .stopped(let game, let time):
            gameStopped(game, at: time)
        case .tick(let now):
            if let index = openIndex { plays[index].lastSeenAt = now }
        case .stopAll(let time):
            games.removeAll()
            endOpenPlay(at: time)
        }
        plays.removeAll { Self.isTooOld($0, at: event.time) }
        save()

        // Then the network.
        await sendHeartbeatIfDue(now: event.time)
        await sendPlays(now: event.time)
        updateStatus()
    }

    // MARK: - Events

    private func gameStarted(_ game: DetectedGame, at time: Date) {
        guard !games.contains(where: { $0.id == game.id }) else { return }
        games.append(game)
        // Newest wins: the older game's play ends, and this one's begins.
        endOpenPlay(at: time)
        beginPlay(of: game, at: time)
    }

    private func gameStopped(_ game: DetectedGame, at time: Date) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let wasNewest = index == games.count - 1
        games.remove(at: index)
        // An older game quitting changes nothing on the server.
        guard wasNewest else { return }

        endOpenPlay(at: time)
        // The game that was running before this one takes over.
        if let next = games.last {
            beginPlay(of: next, at: time)
        }
    }

    private func beginPlay(of game: DetectedGame, at time: Date) {
        plays.append(Play(id: makeID(), game: game, ref: game.defaultRef, startedAt: time, idempotencyKey: makeID()))
    }

    private func endOpenPlay(at time: Date) {
        guard let index = openIndex else { return }
        plays[index].end(at: time, newKey: makeID())
        nextHeartbeat = nil
    }

    // MARK: - Sending

    private func sendHeartbeatIfDue(now: Date) async {
        guard canSend(at: now),
              let index = openIndex,
              let sessionID = plays[index].sessionID,
              let due = nextHeartbeat, now >= due
        else { return }
        let play = plays[index]
        do throws(GSClientError) {
            _ = try await api.heartbeat(sessionID: sessionID)
            reachedServer()
            nextHeartbeat = now + heartbeatInterval
        } catch {
            switch error.verdict {
            case .conflict, .refused:
                // The server already closed it at its last heartbeat, so it
                // has that session in full. The game is still running: a new
                // play begins, and the pass below starts it.
                reachedServer()
                remove(play.id)
                nextHeartbeat = nil
                beginPlay(of: play.game, at: now)
                save()
            default:
                react(to: error, for: play.id, at: now)
            }
        }
    }

    /// Sends what each play needs next, oldest first, until one fails in a
    /// way that may clear by itself.
    private func sendPlays(now: Date) async {
        // A copy of the ids: the loop removes plays as they go through.
        for id in plays.map(\.id) {
            guard canSend(at: now) else { return }
            guard refused[id] == nil,
                  let play = plays.first(where: { $0.id == id }),
                  let request = play.nextRequest
            else { continue }

            switch request {
            case .liveStart:
                await sendLiveStart(play, now: now)
            case .finish(let sessionID, let endedAt):
                await sendFinish(play, sessionID: sessionID, endedAt: endedAt, now: now)
            case .log(let endedAt):
                await sendLog(play, endedAt: endedAt, now: now)
            }
        }
    }

    /// `POST /me/sessions` without `endedAt`: the play is still going.
    ///
    /// API docs: https://developers.gamescrobbler.com/guides/recording-play/#start-a-session
    private func sendLiveStart(_ play: Play, now: Date) async {
        do throws(GSClientError) {
            let session = try await api.startSession(startRequest(for: play), idempotencyKey: play.idempotencyKey)
            reachedServer()
            change(play.id) { $0.sessionID = session.id }
            nextHeartbeat = now + heartbeatInterval
        } catch {
            if error.verdict == .conflict {
                // Too many open sessions, or too many starts today. Not this
                // play's fault, and it clears by itself: try again, slowly.
                postpone(after: error, at: now, by: Self.backoff.last ?? 300)
            } else {
                react(to: error, for: play.id, at: now)
            }
        }
    }

    /// `POST /me/sessions/{id}/finish`: the play ended after its live start
    /// went through.
    ///
    /// API docs: https://developers.gamescrobbler.com/guides/recording-play/#finish-it
    private func sendFinish(_ play: Play, sessionID: String, endedAt: Date, now: Date) async {
        do throws(GSClientError) {
            lastFinished = try await api.finishSession(id: sessionID, endedAt: endedAt, idempotencyKey: play.idempotencyKey)
            reachedServer()
            remove(play.id)
        } catch {
            if error.verdict == .conflict {
                // Already finished. Usually the server closed it itself at
                // its last heartbeat (45 silent minutes, say after a night
                // offline): the minutes after that heartbeat are lost, and
                // there is no way to send them now. The play is done.
                reachedServer()
                remove(play.id)
            } else {
                react(to: error, for: play.id, at: now)
            }
        }
    }

    /// `POST /me/sessions` with `startedAt` and `endedAt`: the play ended
    /// before the server ever took its start, so it goes out whole, in one
    /// call. Never as a late live start: that would close whatever session
    /// is open on this Mac now.
    ///
    /// A 409 here means the server already has this `clientSessionId` open
    /// (a live start whose answer was lost). It is refused for this run; at
    /// the next launch the server has closed that session, and the same
    /// `clientSessionId` returns it instead of making a second one.
    ///
    /// **Known loss:** that returned session keeps the server's end (its last
    /// heartbeat, often the start), not our `endedAt`, so the play counts as
    /// shorter than it was. Sending the rest under a new id is possible, but
    /// waits until the server's rules for such a log are checked.
    ///
    /// API docs: https://developers.gamescrobbler.com/guides/recording-play/#log-a-session-that-is-already-over
    private func sendLog(_ play: Play, endedAt: Date, now: Date) async {
        do throws(GSClientError) {
            let request = startRequest(for: play, endedAt: endedAt)
            lastFinished = try await api.startSession(request, idempotencyKey: play.idempotencyKey)
            reachedServer()
            remove(play.id)
        } catch {
            react(to: error, for: play.id, at: now)
        }
    }

    /// The body is built from the play's own fields every time, so a retry
    /// sends exactly the same body, as the idempotency key requires.
    private func startRequest(for play: Play, endedAt: Date? = nil) -> StartSessionRequest {
        StartSessionRequest(
            game: play.ref,
            deviceId: deviceID,
            clientSessionId: play.id,
            startedAt: play.startedAt,
            endedAt: endedAt
        )
    }

    // MARK: - Failures

    /// What a refused request means for the play, apart from the cases each
    /// call handles itself.
    private func react(to error: GSClientError, for playID: String, at now: Date) {
        switch error.verdict {
        case .retryLater:
            postpone(after: error, at: now)
        case .signedOut:
            signedOutError = error
        case .newKey:
            // The key was already used with another body. A new key makes
            // the next try a new request.
            let key = makeID()
            change(playID) { $0.idempotencyKey = key }
            postpone(after: error, at: now)
        case .refused, .conflict:
            reachedServer()
            refused[playID] = error
        }
    }

    private func postpone(after error: GSClientError, at now: Date, by wait: TimeInterval? = nil) {
        failuresInARow += 1
        lastFailure = error
        let step = Self.backoff[min(failuresInARow, Self.backoff.count) - 1]
        // `??` chains: the wait the caller asked for, else the server's
        // `Retry-After`, else the next backoff step.
        retryAt = now + (wait ?? error.retryAfter.map(Self.seconds) ?? step)
    }

    /// The server answered, so the waiting is over.
    private func reachedServer() {
        failuresInARow = 0
        retryAt = nil
        lastFailure = nil
    }

    private func canSend(at now: Date) -> Bool {
        guard signedOutError == nil else { return false }
        // `map` on an optional: nil stays nil, so no `retryAt` means "yes".
        return retryAt.map { now >= $0 } ?? true
    }

    private func updateStatus() {
        if let error = signedOutError {
            status = .signedOut(error)
        } else if let error = lastFailure, let retryAt {
            status = .waiting(until: retryAt, error)
        } else if let index = openIndex {
            let play = plays[index]
            if let error = refused[play.id] {
                status = .failed(play.game, error)
            } else if play.sessionID != nil {
                status = .scrobbling(play.game, since: play.startedAt)
            } else {
                status = .idle
            }
        } else {
            status = .idle
        }
    }

    // MARK: - The journal

    /// The play still going, if any. Only the last play can be open.
    private var openIndex: Int? {
        plays.lastIndex { $0.endedAt == nil }
    }

    /// Changes one play, found by id, and saves.
    private func change(_ id: String, _ update: (inout Play) -> Void) {
        guard let index = plays.firstIndex(where: { $0.id == id }) else { return }
        update(&plays[index])
        save()
    }

    private func remove(_ id: String) {
        plays.removeAll { $0.id == id }
        refused[id] = nil
        save()
    }

    /// A failed save is not the end: the plays are still in memory and are
    /// sent anyway. Only a crash before the next good save would lose them.
    private func save() {
        try? journal.save(plays)
    }

    private static func isTooOld(_ play: Play, at now: Date) -> Bool {
        play.endedAt != nil && now.timeIntervalSince(play.startedAt) > maxPlayAge
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
    }
}

extension Play {
    /// The next request a play needs (the table on `Play`).
    enum Request: Equatable {
        case liveStart
        case finish(sessionID: String, endedAt: Date)
        case log(endedAt: Date)
    }

    /// nil while the live session is open: heartbeats keep it going.
    ///
    /// A `switch` over a *tuple* matches both values at once. `let id?` is an
    /// *optional pattern*: it matches a value that is not nil and unwraps it.
    var nextRequest: Request? {
        switch (sessionID, endedAt) {
        case (nil, nil): .liveStart
        case (_?, nil): nil
        case (let id?, let end?): .finish(sessionID: id, endedAt: end)
        case (nil, let end?): .log(endedAt: end)
        }
    }

    /// Ends the play at `time`. The next request now has `endedAt` in its
    /// body, so it gets a new idempotency key.
    ///
    /// `mutating` lets a method change a struct's own properties; it can only
    /// be called on a `var`.
    mutating func end(at time: Date, newKey: String) {
        // The server takes sessions of up to 24 hours, and never one that
        // ends before it starts.
        let end = min(max(time, startedAt), startedAt + Scrobbler.maxPlayLength)
        endedAt = end
        lastSeenAt = end
        idempotencyKey = newKey
    }
}

/// How the scrobbler treats a failed request.
enum Verdict {
    /// Offline, rate limited, or server trouble: wait, then send it again.
    case retryLater
    /// 401 or 403: stop sending until the token changes.
    case signedOut
    /// 409 `idempotency_conflict`: the key was used with another body.
    case newKey
    /// Any other 409. What it means depends on the request.
    case conflict
    /// 404 and other 4xx: the same request would get the same answer.
    case refused
}

extension GSClientError {
    var verdict: Verdict {
        guard case .api(let error) = self else { return .retryLater }
        // A `switch` on a number can match ranges (`400..<500`), and a
        // `where` clause adds a condition. Cases are tried top to bottom.
        switch error.status {
        case 401, 403: return .signedOut
        case 409 where error.code == .idempotencyConflict: return .newKey
        case 409: return .conflict
        case 408, 429: return .retryLater
        case 400..<500: return .refused
        default: return .retryLater
        }
    }

    /// How long the server asked us to wait, if it did.
    var retryAfter: Duration? {
        if case .api(let error) = self { return error.retryAfter }
        return nil
    }
}
