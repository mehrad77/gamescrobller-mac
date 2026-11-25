import Foundation
import Testing
@testable import ScrobblerCore

/// A pretend GameScrobbler server that keeps the real server's rules, so a
/// test fails if the scrobbler would make a duplicate or a refused request:
///
/// 1. An `Idempotency-Key` sent again replays the stored answer; with a
///    different body it is refused (409 `idempotency_conflict`).
/// 2. A `clientSessionId` sent again returns that same session, but only for
///    the same game (else 409). A finished session cannot be logged under the
///    id of one that is still open (409).
/// 3. A live start closes this device's open session.
/// 4. Finishing a closed session, or a heartbeat on one, answers 409.
///
/// It records every call, and a test can make the next call of a kind fail.
private actor FakeServer: SessionAPI {
    enum Call: Equatable {
        case start(game: String, startedAt: Date?)
        /// A start with `endedAt`: a session logged in one call.
        case log(game: String, startedAt: Date?, endedAt: Date?)
        case heartbeat(String)
        case finish(String, endedAt: Date?)
    }

    /// A session as the server keeps it.
    struct Session {
        let id: String
        let game: String
        let clientSessionId: String?
        let deviceId: String?
        let startedAt: Date?
        var endedAt: Date?
        var isOpen: Bool

        var answer: GSSession {
            GSSession(
                id: id, gameId: "g_7k2m9q4xzt", gameSlug: nil, gameTitle: "A game",
                clientSessionId: clientSessionId ?? "", deviceId: deviceId,
                startedAt: startedAt ?? .distantPast, lastHeartbeatAt: startedAt ?? .distantPast,
                endedAt: endedAt, durationSeconds: 0, isActive: isOpen, countsTowardTotals: true
            )
        }
    }

    /// The body a key was first used with.
    private enum Body: Equatable {
        case start(StartSessionRequest)
        case finish(id: String, endedAt: Date?)
    }

    private(set) var calls: [Call] = []
    private(set) var startRequests: [StartSessionRequest] = []
    private(set) var startKeys: [String] = []
    private(set) var sessions: [Session] = []
    private var answers: [String: (body: Body, session: GSSession)] = [:]
    private var startErrors: [GSClientError] = []
    private var heartbeatErrors: [GSClientError] = []
    private var finishErrors: [GSClientError] = []
    private var startAnswersToLose = 0

    func failNextStart(with error: GSClientError) { startErrors.append(error) }
    func failNextHeartbeat(with error: GSClientError) { heartbeatErrors.append(error) }
    func failNextFinish(with error: GSClientError) { finishErrors.append(error) }
    /// The server makes the session, but its answer never arrives (a timeout).
    func loseNextStartAnswer() { startAnswersToLose += 1 }
    /// What the server does to a session after 45 minutes without a heartbeat.
    func closeQuietSessions() {
        for index in sessions.indices { sessions[index].isOpen = false }
    }

    func startSession(_ start: StartSessionRequest, idempotencyKey: String) async throws(GSClientError) -> GSSession {
        if let endedAt = start.endedAt {
            calls.append(.log(game: start.game.apiValue, startedAt: start.startedAt, endedAt: endedAt))
        } else {
            calls.append(.start(game: start.game.apiValue, startedAt: start.startedAt))
        }
        startRequests.append(start)
        startKeys.append(idempotencyKey)
        // A failed request changes nothing on the server, as with the real
        // one: errors roll back, and only successful answers are stored.
        if !startErrors.isEmpty { throw startErrors.removeFirst() }

        let answer = try startOrReplay(start, key: idempotencyKey)
        if startAnswersToLose > 0 {
            startAnswersToLose -= 1
            throw offline
        }
        return answer
    }

    private func startOrReplay(_ start: StartSessionRequest, key: String) throws(GSClientError) -> GSSession {
        // Rule 1.
        if let stored = answers[key] {
            guard stored.body == .start(start) else { throw idempotencyConflict }
            return stored.session
        }
        // Rule 2.
        if let cid = start.clientSessionId, let existing = sessions.first(where: { $0.clientSessionId == cid }) {
            guard existing.game == start.game.apiValue else { throw conflict }
            guard start.endedAt == nil || !existing.isOpen else { throw conflict }
            answers[key] = (.start(start), existing.answer)
            return existing.answer
        }
        // Rule 3.
        if start.endedAt == nil {
            for index in sessions.indices where sessions[index].deviceId == start.deviceId {
                sessions[index].isOpen = false
            }
        }
        let session = Session(
            id: "s\(sessions.count + 1)", game: start.game.apiValue,
            clientSessionId: start.clientSessionId, deviceId: start.deviceId,
            startedAt: start.startedAt, endedAt: start.endedAt, isOpen: start.endedAt == nil
        )
        sessions.append(session)
        answers[key] = (.start(start), session.answer)
        return session.answer
    }

    func heartbeat(sessionID: String) async throws(GSClientError) -> GSSession {
        calls.append(.heartbeat(sessionID))
        if !heartbeatErrors.isEmpty { throw heartbeatErrors.removeFirst() }
        guard let session = sessions.first(where: { $0.id == sessionID }) else { throw notFound }
        guard session.isOpen else { throw conflict }  // rule 4
        return session.answer
    }

    func finishSession(id: String, endedAt: Date?, idempotencyKey: String) async throws(GSClientError) -> GSSession {
        calls.append(.finish(id, endedAt: endedAt))
        if !finishErrors.isEmpty { throw finishErrors.removeFirst() }
        if let stored = answers[idempotencyKey] {
            guard stored.body == .finish(id: id, endedAt: endedAt) else { throw idempotencyConflict }
            return stored.session
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw notFound }
        guard sessions[index].isOpen else { throw conflict }  // rule 4
        sessions[index].isOpen = false
        sessions[index].endedAt = endedAt
        answers[idempotencyKey] = (.finish(id: id, endedAt: endedAt), sessions[index].answer)
        return sessions[index].answer
    }
}

private let motorways = DetectedGame(id: "mm", name: "Mini Motorways", source: .appStore(adamID: 1_456_188_526))
private let morta = DetectedGame(id: "cm", name: "Children of Morta", source: .steam(appID: 330_020))

/// The start of every test's timeline. Times are plain `Date` values, so a
/// test can say "five minutes later" without waiting five minutes.
private let t0 = Date(timeIntervalSince1970: 1_795_543_200)

private func minutes(_ count: Double) -> Date { t0 + count * 60 }

private func apiError(_ status: Int, _ code: GSAPIError.Code, retryAfter: Duration? = nil) -> GSClientError {
    .api(GSAPIError(status: status, code: code, message: "A message", requestID: "r", retryAfter: retryAfter))
}

private let conflict = apiError(409, .conflict)
private let idempotencyConflict = apiError(409, .idempotencyConflict)
private let notFound = apiError(404, .notFound)
private let expired = apiError(401, .tokenExpired)
private let offline = GSClientError.network(URLError(.notConnectedToInternet))

/// A `final class` so `deinit` can delete the test's journal folder, as in
/// `PlayJournalTests`.
@Suite("Scrobbler")
final class ScrobblerTests {
    private let api = FakeServer()
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "ScrobblerTests-\(UUID().uuidString)")
    private let journal: PlayJournal
    private var scrobbler: Scrobbler

    init() {
        journal = PlayJournal(fileURL: directory.appending(path: "plays.json"))
        scrobbler = Scrobbler(api: api, deviceID: "mac-test", journal: journal, now: t0)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The app quits (or crashes) and starts again: a new scrobbler reads
    /// the same journal and talks to the same server.
    private func relaunch(at time: Date) {
        scrobbler = Scrobbler(api: api, deviceID: "mac-test", journal: journal, now: time)
    }

    // MARK: - Sessions

    @Test func aGameGetsOneSessionFromStartToStop() async {
        await scrobbler.handle(.started(motorways, at: t0))
        #expect(await scrobbler.status == .scrobbling(motorways, since: t0))
        await scrobbler.handle(.stopped(motorways, at: minutes(30)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .finish("s1", endedAt: minutes(30)),
        ])
        #expect(await scrobbler.status == .idle)
        #expect(await scrobbler.lastFinished?.id == "s1")
        #expect(await scrobbler.unsentCount == 0)
    }

    @Test func theStartNamesTheGameAndTheDevice() async throws {
        await scrobbler.handle(.started(morta, at: t0))

        let request = try #require(await api.startRequests.first)
        #expect(request.game == .store(.steam, id: "330020"))
        #expect(request.deviceId == "mac-test")
        #expect(request.clientSessionId != nil)
        #expect(request.endedAt == nil)  // a live session, not a finished one
    }

    @Test func heartbeatsAreSentEveryFiveMinutes() async {
        await scrobbler.handle(.started(motorways, at: t0))

        await scrobbler.handle(.tick(minutes(1)))
        await scrobbler.handle(.tick(minutes(4)))
        #expect(await api.calls.count == 1)  // only the start so far

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.tick(minutes(6)))
        await scrobbler.handle(.tick(minutes(10)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .heartbeat("s1"),
            .heartbeat("s1"),
        ])
    }

    @Test func aSessionTheServerClosedIsReplacedOnce() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.closeQuietSessions()

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.tick(minutes(6)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .heartbeat("s1"),
            .start(game: "apple:1456188526", startedAt: minutes(5)),
        ])
        #expect(await scrobbler.status == .scrobbling(motorways, since: minutes(5)))
    }

    @Test func anOfflineHeartbeatIsTriedAgainAMinuteLater() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: offline)

        await scrobbler.handle(.tick(minutes(5)))
        #expect(await scrobbler.status == .waiting(until: minutes(6), offline))
        await scrobbler.handle(.tick(minutes(6)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .heartbeat("s1"),
            .heartbeat("s1"),
        ])
        #expect(await scrobbler.status == .scrobbling(motorways, since: t0))
    }

    @Test func aRateLimitedHeartbeatWaitsAsLongAsTheServerAsks() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: apiError(429, .rateLimited, retryAfter: .seconds(120)))

        await scrobbler.handle(.tick(minutes(5)))  // refused: wait 2 minutes
        await scrobbler.handle(.tick(minutes(6)))  // too early, nothing sent
        await scrobbler.handle(.tick(minutes(7)))  // now it goes out

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .heartbeat("s1"),
            .heartbeat("s1"),
        ])
    }

    @Test func aHeartbeatWithARefusedTokenStopsAllSending() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: expired)

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.tick(minutes(10)))
        await scrobbler.handle(.stopped(motorways, at: minutes(12)))

        #expect(await api.calls.count == 2)  // the start and the refused heartbeat
        #expect(await scrobbler.status == .signedOut(expired))
    }

    @Test func theNewestGameWinsAndTheOlderOneResumes() async {
        await scrobbler.handle(.started(morta, at: t0))
        await scrobbler.handle(.started(motorways, at: minutes(10)))
        await scrobbler.handle(.stopped(motorways, at: minutes(20)))
        await scrobbler.handle(.stopped(morta, at: minutes(30)))

        #expect(await api.calls == [
            .start(game: "steam:330020", startedAt: t0),
            .finish("s1", endedAt: minutes(10)),
            .start(game: "apple:1456188526", startedAt: minutes(10)),
            .finish("s2", endedAt: minutes(20)),
            .start(game: "steam:330020", startedAt: minutes(20)),
            .finish("s3", endedAt: minutes(30)),
        ])
    }

    @Test func anOlderGameQuittingChangesNothing() async {
        await scrobbler.handle(.started(morta, at: t0))
        await scrobbler.handle(.started(motorways, at: minutes(10)))
        await scrobbler.handle(.stopped(morta, at: minutes(12)))

        #expect(await api.calls.count == 3)  // start, finish, start: nothing new
        #expect(await scrobbler.status == .scrobbling(motorways, since: minutes(10)))
    }

    @Test func aFinishTheServerAlreadyDidCountsAsDone() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.closeQuietSessions()

        await scrobbler.handle(.stopped(motorways, at: minutes(30)))

        #expect(await api.calls.last == .finish("s1", endedAt: minutes(30)))
        #expect(await scrobbler.status == .idle)
        #expect(await scrobbler.unsentCount == 0)
    }

    @Test func stopAllFinishesTheOpenSession() async {
        await scrobbler.handle(.started(morta, at: t0))
        await scrobbler.handle(.started(motorways, at: minutes(5)))
        await scrobbler.handle(.stopAll(at: minutes(8)))
        await scrobbler.handle(.stopped(motorways, at: minutes(9)))

        let calls = await api.calls
        #expect(calls.last == .finish("s2", endedAt: minutes(8)))
        #expect(calls.count == 4)  // nothing resumes after stopAll
    }

    // MARK: - Retries

    @Test func aStartIsRetriedWithTheSameKeyAndBody() async {
        await api.failNextStart(with: offline)

        await scrobbler.handle(.started(motorways, at: t0))
        #expect(await scrobbler.status == .waiting(until: minutes(1), offline))
        await scrobbler.handle(.tick(minutes(1)))

        let requests = await api.startRequests
        let keys = await api.startKeys
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(keys[0] == keys[1])
        // The session still starts when the game did, not when it got through.
        #expect(await scrobbler.status == .scrobbling(motorways, since: t0))
    }

    @Test func aLostAnswerIsReplayedNotDuplicated() async {
        // The server makes the session, but the Mac never hears back.
        await api.loseNextStartAnswer()

        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.tick(minutes(1)))  // same key: the server replays s1
        await scrobbler.handle(.stopped(motorways, at: minutes(30)))

        #expect(await api.sessions.count == 1)
        #expect(await api.calls.last == .finish("s1", endedAt: minutes(30)))
    }

    @Test func thePauseGrowsAfterEachFailure() async {
        for _ in 1...5 { await api.failNextStart(with: offline) }

        await scrobbler.handle(.started(motorways, at: t0))
        for minute in 1...16 { await scrobbler.handle(.tick(minutes(Double(minute)))) }
        // Tried at 0, 1, 3, 7 and 12: waits of 1, 2, 4, then 5 minutes.
        #expect(await api.calls.count == 5)
        #expect(await scrobbler.status == .waiting(until: minutes(17), offline))

        await scrobbler.handle(.tick(minutes(17)))
        #expect(await api.calls.count == 6)
        #expect(await scrobbler.status == .scrobbling(motorways, since: t0))
    }

    @Test func theServerCanAskForALongerPause() async {
        let busy = apiError(503, .serviceUnavailable, retryAfter: .seconds(600))
        await api.failNextStart(with: busy)

        await scrobbler.handle(.started(motorways, at: t0))

        #expect(await scrobbler.status == .waiting(until: minutes(10), busy))
    }

    @Test func tooManyOpenSessionsWaitsFiveMinutes() async {
        await api.failNextStart(with: conflict)

        await scrobbler.handle(.started(motorways, at: t0))

        #expect(await scrobbler.status == .waiting(until: minutes(5), conflict))
    }

    @Test func aPlayThatEndedOfflineIsSentWholeInOneCall() async {
        await api.failNextStart(with: offline)

        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.stopped(motorways, at: minutes(30)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .log(game: "apple:1456188526", startedAt: t0, endedAt: minutes(30)),
        ])
        // A new body, so a new key.
        let keys = await api.startKeys
        #expect(keys[0] != keys[1])
        #expect(await scrobbler.lastFinished?.id == "s1")
        #expect(await scrobbler.unsentCount == 0)
    }

    // MARK: - Refusals

    @Test func aRefusedStartIsNotRetriedOnThisRun() async {
        await api.failNextStart(with: notFound)

        await scrobbler.handle(.started(motorways, at: t0))
        #expect(await scrobbler.status == .failed(motorways, notFound))

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.stopped(motorways, at: minutes(10)))

        #expect(await api.calls.count == 1)  // the start; no heartbeat, no log
        #expect(await scrobbler.status == .idle)
        #expect(await scrobbler.unsentCount == 1)  // still kept
    }

    @Test func aRefusedPlayDoesNotHoldUpTheOthers() async {
        await api.failNextStart(with: notFound)

        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.stopped(motorways, at: minutes(10)))
        await scrobbler.handle(.started(morta, at: minutes(11)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .start(game: "steam:330020", startedAt: minutes(11)),
        ])

        // The next launch tries the refused play again, oldest first.
        relaunch(at: minutes(20))
        await scrobbler.handle(.tick(minutes(20)))

        #expect(await api.calls.suffix(2) == [
            .log(game: "apple:1456188526", startedAt: t0, endedAt: minutes(10)),
            .finish("s1", endedAt: minutes(11)),  // morta, ended where last seen
        ])
    }

    /// No duplicate, but not the whole play either: the server keeps its own
    /// end for that session (see "Known loss" on `sendLog`).
    @Test func aLogTheServerHasOpenIsNotDuplicated() async {
        await api.loseNextStartAnswer()

        // The start reached the server, but the game quit before a retry,
        // so the play goes out as a log under the same clientSessionId.
        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.stopped(motorways, at: minutes(0.5)))
        await scrobbler.handle(.tick(minutes(1)))
        #expect(await api.calls.last == .log(game: "apple:1456188526", startedAt: t0, endedAt: minutes(0.5)))
        #expect(await scrobbler.unsentCount == 1)  // 409: that session is still open

        // By the next launch the server has closed it, and the same
        // clientSessionId returns it.
        await api.closeQuietSessions()
        relaunch(at: minutes(60))
        await scrobbler.handle(.tick(minutes(60)))

        #expect(await api.sessions.count == 1)
        #expect(await scrobbler.unsentCount == 0)
    }

    @Test func aRefusedTokenKeepsThePlaysForTheNextOne() async {
        await api.failNextStart(with: expired)

        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.started(morta, at: minutes(1)))
        await scrobbler.handle(.stopAll(at: minutes(30)))
        #expect(await api.calls.count == 1)
        #expect(await scrobbler.status == .signedOut(expired))
        #expect(await scrobbler.unsentCount == 2)

        // A new token means a new scrobbler, which sends them.
        relaunch(at: minutes(31))
        await scrobbler.handle(.tick(minutes(31)))

        #expect(await api.calls.suffix(2) == [
            .log(game: "apple:1456188526", startedAt: t0, endedAt: minutes(1)),
            .log(game: "steam:330020", startedAt: minutes(1), endedAt: minutes(30)),
        ])
    }

    // MARK: - Relaunch

    @Test func aPlayLeftOpenByACrashEndsWhereItWasLastSeen() async {
        await scrobbler.handle(.started(motorways, at: t0))
        for minute in 1...12 { await scrobbler.handle(.tick(minutes(Double(minute)))) }

        // No stop: the app died. It comes back two hours later.
        relaunch(at: minutes(120))
        await scrobbler.handle(.tick(minutes(120)))

        #expect(await api.calls.last == .finish("s1", endedAt: minutes(12)))
        #expect(await scrobbler.unsentCount == 0)
    }

    @Test func playsOlderThanSevenDaysAreDropped() async {
        await api.failNextStart(with: offline)
        await api.failNextStart(with: offline)
        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.stopped(motorways, at: minutes(30)))
        #expect(await scrobbler.unsentCount == 1)

        relaunch(at: t0 + 8 * 24 * 60 * 60)

        #expect(await scrobbler.unsentCount == 0)
    }

    @Test func aDamagedJournalIsKeptAside() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a journal".utf8).write(to: journal.fileURL)

        relaunch(at: t0)
        await scrobbler.handle(.started(motorways, at: t0))

        let damaged = directory.appending(path: "plays.damaged.json")
        #expect(FileManager.default.fileExists(atPath: damaged.path()))
        #expect(await api.calls.count == 1)
    }
}
