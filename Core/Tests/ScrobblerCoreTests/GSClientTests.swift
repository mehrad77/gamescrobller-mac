import Foundation
import Testing
@testable import ScrobblerCore

/// A fake server for `GSClient`: it answers every request with one canned
/// response and remembers the requests it saw.
///
/// It is an `actor` because the client calls it from its own task while the
/// test reads `requests` afterwards; the actor keeps those two from colliding.
private actor FakeServer {
    private(set) var requests: [URLRequest] = []
    private let status: Int
    private let headers: [String: String]
    private let body: Data
    private let failure: URLError?

    init(status: Int = 200, headers: [String: String] = [:], json: String = "{}", failure: URLError? = nil) {
        self.status = status
        self.headers = headers
        self.body = Data(json.utf8)
        self.failure = failure
    }

    func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return (body, response)
    }

    /// A client whose transport is this fake server.
    /// `nonisolated`: making a client touches no actor state, so callers need
    /// not `await` it.
    nonisolated func client() -> GSClient {
        GSClient(
            baseURL: URL(string: "https://api.test/v1")!,
            token: "gsp_test",
            transport: { request in try await self.answer(request) }
        )
    }
}

/// What a session answer looks like, with the milliseconds the server sends.
private let sessionJSON = """
{
  "id": "3c1f7a52-9b0e-4d6a-8f21-6e4d2b9c7a10",
  "gameId": "g_7k2m9q4xzt",
  "gameSlug": "mini-motorways",
  "gameTitle": "Mini Motorways",
  "writer": "self",
  "clientSessionId": "c-1",
  "deviceId": "mac-1",
  "startedAt": "2026-11-24T18:00:00.000Z",
  "lastHeartbeatAt": "2026-11-24T18:05:00.000Z",
  "endedAt": null,
  "durationSeconds": 300,
  "isActive": true,
  "countsTowardTotals": true
}
"""

/// Decodes a request body into a dictionary, to check what was sent.
private func jsonBody(_ request: URLRequest) throws -> [String: String] {
    let data = try #require(request.httpBody)
    return try JSONDecoder().decode([String: String].self, from: data)
}

@Suite("GSClient")
struct GSClientTests {
    @Test func meSendsTheTokenAndDecodesTheProfile() async throws {
        let server = FakeServer(json: """
        {"id": "u1", "handle": null, "displayName": "Mehrad", "avatarUrl": null, "platforms": ["steam"]}
        """)

        let profile = try await server.client().me()

        #expect(profile == GSProfile(id: "u1", handle: nil, displayName: "Mehrad", avatarUrl: nil, platforms: ["steam"]))
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.test/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsp_test")
        #expect(request.httpBody == nil)
    }

    @Test func startSessionSendsTheBodyAndIdempotencyKey() async throws {
        let server = FakeServer(status: 201, json: sessionJSON)
        let start = StartSessionRequest(
            game: .store(.steam, id: "570"),
            deviceId: "mac-1",
            startedAt: Date(timeIntervalSince1970: 1_795_000_000)
        )

        let session = try await server.client().startSession(start, idempotencyKey: "key-1")

        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/me/sessions")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // nil properties (clientSessionId, endedAt) are left out entirely, and
        // the date is UTC with whole seconds and a Z.
        #expect(try jsonBody(request) == [
            "game": "steam:570",
            "deviceId": "mac-1",
            "startedAt": "2026-11-18T11:06:40Z",
        ])

        #expect(session.id == "3c1f7a52-9b0e-4d6a-8f21-6e4d2b9c7a10")
        #expect(session.gameTitle == "Mini Motorways")
        #expect(session.endedAt == nil)
        // The answer had milliseconds; it still decodes to the exact time.
        #expect(session.startedAt == Date(timeIntervalSince1970: 1_795_543_200))
    }

    @Test func heartbeatPostsWithoutABody() async throws {
        let server = FakeServer(json: sessionJSON)

        _ = try await server.client().heartbeat(sessionID: "s-1")

        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/me/sessions/s-1/heartbeat")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }

    @Test func finishSessionSendsEndedAt() async throws {
        let server = FakeServer(json: sessionJSON)

        _ = try await server.client().finishSession(
            id: "s-1", endedAt: Date(timeIntervalSince1970: 1_795_000_000), idempotencyKey: "key-2"
        )

        let request = try #require(await server.requests.first)
        #expect(request.url?.path() == "/v1/me/sessions/s-1/finish")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-2")
        #expect(try jsonBody(request) == ["endedAt": "2026-11-18T11:06:40Z"])
    }

    @Test func finishWithoutATimeSendsAnEmptyObject() async throws {
        let server = FakeServer(json: sessionJSON)

        _ = try await server.client().finishSession(id: "s-1", idempotencyKey: "key-3")

        let request = try #require(await server.requests.first)
        #expect(try jsonBody(request).isEmpty)
    }

    @Test func apiErrorsKeepTheirCode() async throws {
        let server = FakeServer(status: 404, json: """
        {"error": {"code": "not_found", "message": "No such game", "requestId": "req-1"}}
        """)

        // `#expect(throws:)` passes only if the call throws exactly this error.
        await #expect(throws: GSClientError.api(GSAPIError(
            status: 404, code: .notFound, message: "No such game", requestID: "req-1", retryAfter: nil
        ))) {
            try await server.client().me()
        }
    }

    @Test func rateLimitsCarryRetryAfter() async throws {
        let server = FakeServer(status: 429, headers: ["Retry-After": "30"], json: """
        {"error": {"code": "rate_limited", "message": "Slow down", "requestId": "req-2"}}
        """)

        // `do`/`catch` when we want to look inside the error instead of
        // comparing all of it. With typed throws, `error` is a GSClientError.
        do {
            _ = try await server.client().heartbeat(sessionID: "s-1")
            Issue.record("expected an error")
        } catch {
            guard case .api(let apiError) = error else {
                Issue.record("expected an API error, got \(error)")
                return
            }
            #expect(apiError.code == .rateLimited)
            #expect(apiError.retryAfter == .seconds(30))
        }
    }

    @Test func unknownErrorCodesStillDecode() async throws {
        let server = FakeServer(status: 400, json: """
        {"error": {"code": "brand_new_code", "message": "?", "requestId": "req-3"}}
        """)

        do {
            _ = try await server.client().me()
            Issue.record("expected an error")
        } catch {
            guard case .api(let apiError) = error else {
                Issue.record("expected an API error, got \(error)")
                return
            }
            #expect(apiError.code.rawValue == "brand_new_code")
        }
    }

    @Test func nonJSONErrorsAreUnexpectedResponses() async throws {
        let server = FakeServer(status: 502, json: "<html>Bad Gateway</html>")

        await #expect(throws: GSClientError.unexpectedResponse(status: 502)) {
            try await server.client().me()
        }
    }

    @Test func networkFailuresAreNetworkErrors() async throws {
        let server = FakeServer(failure: URLError(.notConnectedToInternet))

        await #expect(throws: GSClientError.network(URLError(.notConnectedToInternet))) {
            try await server.client().me()
        }
    }

    // MARK: - Library entries

    private let entryJSON = """
    {"id": "e-1", "gameId": "g_7k2m9q4xzt", "slug": "mini-motorways",
     "title": "Mini Motorways", "createdAt": "2026-11-25T18:30:00.000Z"}
    """

    @Test func addingToTheLibraryPostsTheReference() async throws {
        let server = FakeServer(status: 201, json: entryJSON)

        let outcome = await server.client().addToLibrary(.store(.apple, id: "1456188526"))

        guard case .added(let entry) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        #expect(entry.title == "Mini Motorways")
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/v1/me/library/entries")
        #expect(try jsonBody(request)["game"] == "apple:1456188526")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }

    @Test("library entry answers", arguments: [
        (409, "conflict", LibraryEntryOutcome.alreadyInLibrary),
        (404, "not_found", LibraryEntryOutcome.unknownGame),
    ])
    func libraryEntryAnswers(status: Int, code: String, expected: LibraryEntryOutcome) async {
        let server = FakeServer(status: status, json: """
        {"error": {"code": "\(code)", "message": "?", "requestId": "req-4"}}
        """)

        #expect(await server.client().addToLibrary(.slug("mini-motorways")) == expected)
    }

    @Test func aFullDayOfEntriesIsAFailureToShow() async {
        let server = FakeServer(status: 429, json: """
        {"error": {"code": "rate_limited", "message": "At most 20", "requestId": "req-5"}}
        """)

        let outcome = await server.client().addToLibrary(.slug("mini-motorways"))

        guard case .failed(.api(let error)) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(error.code == .rateLimited)
    }

    @Test func lookingUpAGameReadsYourLibrary() async throws {
        let server = FakeServer(json: """
        {"gameId": "84725", "slug": "children-of-morta", "title": "Children of Morta", "playtimeSeconds": 1081}
        """)

        let outcome = await server.client().lookUp(.store(.steam, id: "330020"))

        #expect(outcome == .inLibrary(GSLibraryItem(gameId: "84725", slug: "children-of-morta", title: "Children of Morta")))
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.test/v1/me/library/steam:330020")
    }

    @Test func aGameNotInYourLibraryIsAnAnswerNotAnError() async {
        let server = FakeServer(status: 404, json: """
        {"error": {"code": "not_found", "message": "Game not found in the library", "requestId": "req-6"}}
        """)

        #expect(await server.client().lookUp(.store(.apple, id: "1456188526")) == .notInLibrary)
    }
}

