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
    /// The Mac is going to sleep: the open play ends now, since a closed lid
    /// is not playtime. The running games are kept, for the wake.
    case sleep(at: Date)
    /// The Mac woke up: the newest game still running gets a new play.
    case wake(at: Date)
    /// You set a game not to be scrobbled, or back: these are the ids of
    /// the games not to scrobble now.
    case ignoredGamesChanged(Set<String>, at: Date)
    /// The game is in your library now: the plays the server refused for it
    /// are sent again.
    case addedToLibrary(gameID: String, at: Date)

    var time: Date {
        switch self {
        case .started(_, let time), .stopped(_, let time), .tick(let time),
             .stopAll(let time), .sleep(let time), .wake(let time),
             .ignoredGamesChanged(_, let time), .addedToLibrary(_, let time):
            time
        }
    }
}

/// A game whose plays the server refused on this run, for the menu's
/// "needs your attention" list.
public struct RefusedGame: Sendable, Equatable, Identifiable {
    public let game: DetectedGame
    /// The reference the server refused.
    public let ref: GameRef
    public let error: GSClientError
    /// How many of its plays wait for an answer from you.
    public let playCount: Int
    /// Whether the refused request was about a session the server already
    /// took (a finish): then a 404 means the session is gone, not the game.
    public var serverHadIt = false

    public var id: String { game.id }

    /// A start refused with 404: the game is not in your library, or
    /// GameScrobbler does not know the reference. Adding it tells which.
    public var isNotInLibrary: Bool {
        if case .api(let error) = error { return error.status == 404 && !serverHadIt }
        return false
    }
}

/// A game the server took a session for on this run: proof that the
/// reference works, and the title GameScrobbler knows it by.
public struct RecognizedGame: Sendable, Equatable {
    public let game: DetectedGame
    public let ref: GameRef
    public let title: String
    public var slug: String? = nil
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
/// - Sleep ends the open play; the wake begins a new one for the newest game
///   still running. Nothing is scrobbled while the Mac sleeps.
/// - A game you set not to be scrobbled is invisible: it never gets a play,
///   and the game running before it keeps its own. Plays of it the server
///   never took stay in the journal, unsent, until they age out, so turning
///   it back on within 7 days loses nothing.
/// - A play counts once it has lasted `minPlayLength` (a minute). Its live
///   start waits until then (with the real `startedAt`), and a play that
///   ends sooner is dropped, so a quick launch, a quick switch or a crash
///   right after a start leaves no session on the server.
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
    private let minPlayLength: TimeInterval
    private let makeID: @Sendable () -> String

    /// Running games, oldest first. The last one not ignored is the one
    /// being scrobbled (`current`).
    private var games: [DetectedGame] = []
    /// The ids of the games you set not to be scrobbled.
    private var ignored: Set<String>
    /// Between `.sleep` and `.wake`: games are still tracked, but no play
    /// begins.
    private var asleep = false
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
    /// Games the server took a session for on this run, by game id.
    public private(set) var recognized: [String: RecognizedGame] = [:]

    /// The games whose plays the server refused on this run, in the order
    /// their plays are in.
    public var refusedGames: [RefusedGame] {
        var result: [RefusedGame] = []
        for play in plays {
            // A game you set not to be scrobbled needs nothing from you.
            guard let error = refused[play.id], !ignored.contains(play.game.id) else { continue }
            if let index = result.firstIndex(where: { $0.game.id == play.game.id }) {
                let old = result[index]
                result[index] = RefusedGame(game: old.game, ref: old.ref, error: old.error, playCount: old.playCount + 1, serverHadIt: old.serverHadIt)
            } else {
                result.append(RefusedGame(game: play.game, ref: play.ref, error: error, playCount: 1, serverHadIt: play.sessionID != nil))
            }
        }
        return result
    }

    /// The time of the last event handled: "now", as far as the scrobbler
    /// knows.
    private var lastEventTime: Date?

    /// Plays that still need a request, for the menu. A play in its first
    /// minute is not counted: its start is not due yet, so it is not waiting.
    public var unsentCount: Int {
        plays.count { play in
            guard let request = play.nextRequest, !isHeldBack(play) else { return false }
            if request == .liveStart, let now = lastEventTime,
               now.timeIntervalSince(play.startedAt) < minPlayLength {
                return false
            }
            return true
        }
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
    ///   - ignoredGames: the ids of the games not to scrobble;
    ///     `ignoredGamesChanged` updates them.
    ///   - minPlayLength: seconds a play must last to be sent. Most tests pass
    ///     0, so a start goes out at once.
    ///   - makeID: makes `clientSessionId`s and idempotency keys. Tests pass a
    ///     counter so the ids are predictable.
    public init(
        api: any SessionAPI,
        deviceID: String,
        journal: PlayJournal,
        ignoredGames: Set<String> = [],
        now: Date = .now,
        heartbeatInterval: TimeInterval = 5 * 60,
        minPlayLength: TimeInterval = 60,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.api = api
        self.deviceID = deviceID
        self.journal = journal
        self.ignored = ignoredGames
        self.heartbeatInterval = heartbeatInterval
        self.minPlayLength = minPlayLength
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
        // A crash right after a start can leave a play too short to count.
        saved.removeAll { Self.isTooOld($0, at: now) || Self.isTooShort($0, minimum: minPlayLength) }
        // A local copy is saved, not `self.plays`: in an initializer that is
        // not `async`, an actor's own state is off limits once it is set up.
        try? journal.save(saved)
        plays = saved
    }

    public func handle(_ event: ScrobbleEvent) async {
        lastEventTime = event.time
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
        case .sleep(let time):
            asleep = true
            endOpenPlay(at: time)
        case .wake(let time):
            wokeUp(at: time)
        case .ignoredGamesChanged(let new, let time):
            ignoredGamesChanged(to: new, at: time)
        case .addedToLibrary(let gameID, _):
            // The plays go out again with the same body and key: a refused
            // request leaves no key behind on the server.
            refused = refused.filter { id, _ in
                plays.first { $0.id == id }?.game.id != gameID
            }
        }
        plays.removeAll { Self.isTooOld($0, at: event.time) || Self.isTooShort($0, minimum: minPlayLength) }
        save()

        // Then the network.
        await sendHeartbeatIfDue(now: event.time)
        await sendPlays(now: event.time)
        updateStatus()
    }

    // MARK: - Events

    /// The game being scrobbled: the newest one running that is not ignored.
    private var current: DetectedGame? {
        games.last { !ignored.contains($0.id) }
    }

    private func gameStarted(_ game: DetectedGame, at time: Date) {
        guard !games.contains(where: { $0.id == game.id }) else { return }
        let before = current
        games.append(game)
        // Newest wins: the older game's play ends, and this one's begins.
        // An ignored game changes nothing.
        follow(from: before, at: time)
    }

    private func gameStopped(_ game: DetectedGame, at time: Date) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let before = current
        games.remove(at: index)
        // When the game being scrobbled quits, the one running before it
        // takes over. An older game quitting changes nothing.
        follow(from: before, at: time)
    }

    /// Once the game being scrobbled changed, its play ends and the new
    /// one's begins. Asleep, nothing happens: the play already ended at the
    /// sleep, and the wake begins the next one.
    private func follow(from before: DetectedGame?, at time: Date) {
        guard !asleep, current?.id != before?.id else { return }
        endOpenPlay(at: time)
        if let current {
            beginPlay(of: current, at: time)
        }
    }

    /// A wake without a sleep before it changes nothing: the play that is
    /// open stays open.
    private func wokeUp(at time: Date) {
        guard asleep else { return }
        asleep = false
        if let current {
            beginPlay(of: current, at: time)
        }
    }

    /// The game being scrobbled may have been ignored, or an ignored one
    /// turned back on: the play follows whichever is current now.
    private func ignoredGamesChanged(to new: Set<String>, at time: Date) {
        let before = current
        ignored = new
        follow(from: before, at: time)
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
                // play begins, and its start goes out once it is a
                // minute old.
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
                  let request = play.nextRequest,
                  !isHeldBack(play)
            else { continue }

            switch request {
            case .liveStart:
                // Not yet a minute old: a later tick sends it. It is the open
                // play, so it is last, and nothing waits behind it.
                guard now.timeIntervalSince(play.startedAt) >= minPlayLength else { continue }
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
            recognize(play, in: session)
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
            let session = try await api.startSession(request, idempotencyKey: play.idempotencyKey)
            lastFinished = session
            reachedServer()
            recognize(play, in: session)
            remove(play.id)
        } catch {
            react(to: error, for: play.id, at: now)
        }
    }

    private func recognize(_ play: Play, in session: GSSession) {
        recognized[play.game.id] = RecognizedGame(game: play.game, ref: play.ref, title: session.gameTitle, slug: session.gameSlug)
    }

    /// A play of a game you set not to be scrobbled, that the server never
    /// took: it waits in the journal, unsent. One the server has is finished
    /// as usual.
    private func isHeldBack(_ play: Play) -> Bool {
        play.sessionID == nil && ignored.contains(play.game.id)
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

    /// A play that ended before it counted, and that the server never heard
    /// of. One that did get its live start is finished as usual: the server
    /// has it already. The server refuses a log that ends where it starts,
    /// so that one is dropped even when there is no minimum.
    private static func isTooShort(_ play: Play, minimum: TimeInterval) -> Bool {
        guard play.sessionID == nil, let end = play.endedAt else { return false }
        let length = end.timeIntervalSince(play.startedAt)
        return length <= 0 || length < minimum
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
