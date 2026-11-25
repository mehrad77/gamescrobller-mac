import Foundation
import Testing
@testable import ScrobblerCore

/// A pretend GameScrobbler server. It records every call, answers with a
/// made-up session, and can be told to fail the next call of a kind.
private actor FakeSessionAPI: SessionAPI {
    enum Call: Equatable {
        case start(game: String, startedAt: Date?)
        case heartbeat(String)
        case finish(String, endedAt: Date?)
    }

    private(set) var calls: [Call] = []
    private(set) var startRequests: [StartSessionRequest] = []
    private var sessionCount = 0
    private var startErrors: [GSClientError] = []
    private var heartbeatErrors: [GSClientError] = []
    private var finishErrors: [GSClientError] = []

    func failNextStart(with error: GSClientError) { startErrors.append(error) }
    func failNextHeartbeat(with error: GSClientError) { heartbeatErrors.append(error) }
    func failNextFinish(with error: GSClientError) { finishErrors.append(error) }

    func startSession(_ start: StartSessionRequest, idempotencyKey: String) async throws(GSClientError) -> GSSession {
        calls.append(.start(game: start.game.apiValue, startedAt: start.startedAt))
        startRequests.append(start)
        if !startErrors.isEmpty { throw startErrors.removeFirst() }
        sessionCount += 1
        return .fake(id: "s\(sessionCount)")
    }

    func heartbeat(sessionID: String) async throws(GSClientError) -> GSSession {
        calls.append(.heartbeat(sessionID))
        if !heartbeatErrors.isEmpty { throw heartbeatErrors.removeFirst() }
        return .fake(id: sessionID)
    }

    func finishSession(id: String, endedAt: Date?, idempotencyKey: String) async throws(GSClientError) -> GSSession {
        calls.append(.finish(id, endedAt: endedAt))
        if !finishErrors.isEmpty { throw finishErrors.removeFirst() }
        return .fake(id: id, isActive: false)
    }
}

extension GSSession {
    /// The memberwise initializer Swift writes for a struct is `internal`;
    /// `@testable import` lets the tests use it.
    fileprivate static func fake(id: String, isActive: Bool = true) -> GSSession {
        GSSession(
            id: id, gameId: "g_7k2m9q4xzt", gameSlug: nil, gameTitle: "A game",
            clientSessionId: "c", deviceId: "mac-test",
            startedAt: .distantPast, lastHeartbeatAt: .distantPast, endedAt: nil,
            durationSeconds: 0, isActive: isActive, countsTowardTotals: true
        )
    }
}

private let motorways = DetectedGame(id: "mm", name: "Mini Motorways", source: .appStore(adamID: 1_456_188_526))
private let morta = DetectedGame(id: "cm", name: "Children of Morta", source: .steam(appID: 330_020))

/// The start of every test's timeline. Times are plain `Date` values, so a
/// test can say "five minutes later" without waiting five minutes.
private let t0 = Date(timeIntervalSince1970: 1_795_543_200)

private func minutes(_ count: Double) -> Date { t0 + count * 60 }

private let conflict = GSClientError.api(GSAPIError(
    status: 409, code: .conflict, message: "Session finished", requestID: "r", retryAfter: nil
))
private let offline = GSClientError.network(URLError(.notConnectedToInternet))

@Suite("Scrobbler")
struct ScrobblerTests {
    // Swift Testing makes a new `ScrobblerTests` for every test, so each
    // test gets its own fake server and its own scrobbler.
    private let api = FakeSessionAPI()
    private let scrobbler: Scrobbler

    init() {
        scrobbler = Scrobbler(api: api, deviceID: "mac-test")
    }

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

    @Test func aClosedSessionIsReplacedOnce() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: conflict)

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.tick(minutes(6)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .heartbeat("s1"),
            .start(game: "apple:1456188526", startedAt: minutes(5)),
        ])
        #expect(await scrobbler.status == .scrobbling(motorways, since: minutes(5)))
    }

    @Test func anOfflineHeartbeatIsTriedAgainOnTheNextTick() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: offline)

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.tick(minutes(6)))

        #expect(await api.calls == [
            .start(game: "apple:1456188526", startedAt: t0),
            .heartbeat("s1"),
            .heartbeat("s1"),
        ])
    }

    @Test func aRateLimitedHeartbeatWaitsAsLongAsTheServerAsks() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: .api(GSAPIError(
            status: 429, code: .rateLimited, message: "Slow down", requestID: "r", retryAfter: .seconds(120)
        )))

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
        let revoked = GSClientError.api(GSAPIError(
            status: 401, code: .invalidToken, message: "Revoked", requestID: "r", retryAfter: nil
        ))
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextHeartbeat(with: revoked)

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.tick(minutes(10)))
        await scrobbler.handle(.stopped(motorways, at: minutes(12)))

        #expect(await api.calls.count == 2)  // the start and the refused heartbeat
        #expect(await scrobbler.status == .signedOut(revoked))
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
        await scrobbler.handle(.stopped(morta, at: minutes(15)))

        #expect(await api.calls.count == 3)  // start, finish, start: nothing new
        #expect(await scrobbler.status == .scrobbling(motorways, since: minutes(10)))
    }

    @Test func aFailedStartIsReportedAndNotRetried() async {
        let notFound = GSClientError.api(GSAPIError(
            status: 404, code: .notFound, message: "Not found", requestID: "r", retryAfter: nil
        ))
        await api.failNextStart(with: notFound)

        await scrobbler.handle(.started(motorways, at: t0))
        #expect(await scrobbler.status == .failed(motorways, notFound))

        await scrobbler.handle(.tick(minutes(5)))
        await scrobbler.handle(.stopped(motorways, at: minutes(10)))

        #expect(await api.calls.count == 1)  // the start; no heartbeat, no finish
        #expect(await scrobbler.status == .idle)
    }

    @Test func aRefusedTokenStopsAllSending() async {
        let expired = GSClientError.api(GSAPIError(
            status: 401, code: .tokenExpired, message: "Expired", requestID: "r", retryAfter: nil
        ))
        await api.failNextStart(with: expired)

        await scrobbler.handle(.started(motorways, at: t0))
        await scrobbler.handle(.started(morta, at: minutes(1)))
        await scrobbler.handle(.tick(minutes(10)))

        #expect(await api.calls.count == 1)
        #expect(await scrobbler.status == .signedOut(expired))
    }

    @Test func aFinishAnswered409CountsAsFinished() async {
        await scrobbler.handle(.started(motorways, at: t0))
        await api.failNextFinish(with: conflict)

        await scrobbler.handle(.stopped(motorways, at: minutes(30)))

        #expect(await scrobbler.status == .idle)
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
}
