import Foundation

/// Talks to the GameScrobbler public API (`/v1`) with a personal access token.
///
/// API docs: https://developers.gamescrobbler.com/reference/
///
/// A `struct` with only `let` properties never changes after it is made, so it
/// is `Sendable` and any task may use it at the same time.
///
/// Every call is `async throws(GSClientError)`:
/// - `async`: it waits for the network without blocking a thread; the caller
///   writes `try await client.me()`.
/// - `throws(GSClientError)` is *typed throws*: the only error it can throw is
///   a `GSClientError`, so a caller's `catch` can `switch` over its cases
///   without a "some other error" fallback.
public struct GSClient: Sendable {
    /// Sends a request and returns the raw answer. Production uses
    /// `URLSession`; tests pass a fake that answers from memory, so no test
    /// touches the network. (The same idea as `AppStoreClassifier.AdamIDLookup`.)
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let productionBaseURL = URL(string: "https://api.gamescrobbler.com/v1")!

    /// `URLSession.shared` is the system's ready-made HTTP client.
    public static let urlSessionTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    public let baseURL: URL
    private let token: String
    private let transport: Transport

    /// - Parameters:
    ///   - baseURL: `productionBaseURL`, or a local stack such as
    ///     `http://localhost:8000/v1` (the backend's default port).
    ///   - token: a personal access token (`gsp_...`).
    ///   - transport: how requests are sent; only tests change it.
    ///
    /// `@escaping`: the closure is stored and called after `init` returns.
    public init(
        baseURL: URL = GSClient.productionBaseURL,
        token: String,
        transport: @escaping Transport = GSClient.urlSessionTransport
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    // MARK: - Endpoints

    /// `GET /me`: who the token belongs to. Also a cheap way to check a token.
    ///
    /// API docs: https://developers.gamescrobbler.com/reference/#api-1/tag/profile/GET/me
    public func me() async throws(GSClientError) -> GSProfile {
        try await send("GET", "me")
    }

    /// `POST /me/sessions`: starts a live session, or logs a finished one
    /// when `start.endedAt` is set.
    ///
    /// `idempotencyKey` makes a retry safe: send the same key with the same
    /// request, and the server answers with what it stored the first time
    /// instead of recording the session twice. Use a new key (a UUID) for each
    /// new session, and keep it until the call succeeds.
    ///
    /// API docs:
    /// - https://developers.gamescrobbler.com/reference/#api-1/tag/activity/POST/me/sessions
    /// - https://developers.gamescrobbler.com/guides/recording-play/#start-a-session
    /// - https://developers.gamescrobbler.com/guides/recording-play/#retry-safely-idempotency-key-not-clientsessionid
    public func startSession(
        _ start: StartSessionRequest,
        idempotencyKey: String
    ) async throws(GSClientError) -> GSSession {
        try await send("POST", "me/sessions", body: Self.encode(start), idempotencyKey: idempotencyKey)
    }

    /// `POST /me/sessions/{id}/heartbeat`: "still playing". Send one every
    /// 5 minutes; after 45 silent minutes the server closes the session.
    ///
    /// API docs:
    /// - https://developers.gamescrobbler.com/reference/#api-1/tag/activity/POST/me/sessions/{id}/heartbeat
    /// - https://developers.gamescrobbler.com/guides/recording-play/#keep-it-open
    public func heartbeat(sessionID: String) async throws(GSClientError) -> GSSession {
        try await send("POST", "me/sessions/\(sessionID)/heartbeat")
    }

    /// `POST /me/sessions/{id}/finish`: ends a session at `endedAt`, or now
    /// when it is nil. Finishing twice answers 409 `conflict`.
    ///
    /// API docs:
    /// - https://developers.gamescrobbler.com/reference/#api-1/tag/activity/POST/me/sessions/{id}/finish
    /// - https://developers.gamescrobbler.com/guides/recording-play/#finish-it
    public func finishSession(
        id: String,
        endedAt: Date? = nil,
        idempotencyKey: String
    ) async throws(GSClientError) -> GSSession {
        try await send(
            "POST", "me/sessions/\(id)/finish",
            body: Self.encode(FinishSessionBody(endedAt: endedAt)),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Sending a request

    /// Builds the request, sends it, and turns the answer into `Response` or
    /// a `GSClientError`. Every endpoint above goes through here.
    ///
    /// `<Response: Decodable>` makes this *generic*: the caller's expected
    /// return type picks `Response` (`GSProfile`, `GSSession`, ...), and
    /// the compiler checks that it is `Decodable`.
    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) async throws(GSClientError) -> Response {
        // `appending(path:)` adds the slash: ".../v1" + "me" = ".../v1/me".
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GameScrobblerMac/\(ScrobblerCore.version)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

        // The transport throws untyped errors, so each one is caught here and
        // converted. `catch let error as URLError` only matches that type.
        let answer: (Data, URLResponse)
        do {
            answer = try await transport(request)
        } catch let error as URLError {
            throw .network(error)
        } catch {
            throw .network(URLError(.unknown))
        }
        let (data, response) = answer

        guard let http = response as? HTTPURLResponse else {
            throw .unexpectedResponse(status: 0)
        }
        // Any 2xx status is success (200 for a replay, 201 for a new session).
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: data, response: http)
        }
        do {
            return try Self.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw .unexpectedResponse(status: http.statusCode)
        }
    }

    /// Reads the API's error JSON, or falls back when the body is something
    /// else (an HTML page from a proxy, an empty body).
    static func error(from data: Data, response: HTTPURLResponse) -> GSClientError {
        guard let body = try? makeDecoder().decode(ErrorBody.self, from: data) else {
            return .unexpectedResponse(status: response.statusCode)
        }
        // `Retry-After` is a number of seconds here. `flatMap` and `map` on an
        // optional run only when there is a value, so a missing or odd header
        // just gives nil.
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0) }
            .map { Duration.seconds($0) }
        return .api(GSAPIError(
            status: response.statusCode,
            code: body.error.code,
            message: body.error.message,
            requestID: body.error.requestId,
            retryAfter: retryAfter
        ))
    }

    // MARK: - JSON

    /// Request bodies send times as ISO 8601 in UTC, ending in `Z`, with
    /// whole seconds: `2026-11-24T18:30:00Z`, which is what the API asks for.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601))
        }
        return encoder
    }

    /// Answers may include milliseconds (`2026-11-24T18:30:00.000Z`) or not,
    /// so the decoder tries both forms.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = (try? withFraction.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not an ISO 8601 date: \(text)"
            )
        }
        return decoder
    }

    /// Our request bodies hold only strings and dates, which always encode,
    /// so a failure here would be a bug in this file. `preconditionFailure`
    /// stops the program with a message instead of throwing an error that no
    /// caller could do anything about.
    static func encode(_ value: some Encodable) -> Data {
        do {
            return try makeEncoder().encode(value)
        } catch {
            preconditionFailure("Could not encode \(type(of: value)): \(error)")
        }
    }
}
