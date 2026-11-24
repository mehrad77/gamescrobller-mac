import Foundation

/// Everything a `GSClient` call can fail with.
///
/// The cases are what the caller does about it, not every possible cause:
/// - `network`: the request never got an answer (offline, timeout). Retry later.
/// - `api`: the server answered with an error. Look at its `code`.
/// - `unexpectedResponse`: an answer that is not the API's JSON, such as an
///   HTML error page from a proxy. Treat like a server error and retry later.
public enum GSClientError: Error, Sendable, Equatable {
    case network(URLError)
    case api(GSAPIError)
    case unexpectedResponse(status: Int)
}

/// An error the GameScrobbler API answered with.
///
/// API docs: https://developers.gamescrobbler.com/guides/errors/
public struct GSAPIError: Error, Sendable, Equatable {
    /// The HTTP status, such as 404 or 429.
    public let status: Int
    /// A stable code to branch on (the `message` wording may change).
    public let code: Code
    /// Plain-English explanation, for logs.
    public let message: String
    /// Quote it when reporting a problem.
    public let requestID: String
    /// How long the server asks us to wait (429 and 503), from `Retry-After`.
    public let retryAfter: Duration?

    /// An *open enum*: a struct wrapping the code's text, with the known codes
    /// as static constants. Unlike a real `enum`, a code the server adds later
    /// still decodes (as `Code(rawValue: "new_code")`) instead of failing.
    ///
    /// `RawRepresentable` with a `String` raw value also gives us `Decodable`
    /// for free: Swift decodes the string and calls `init(rawValue:)`.
    public struct Code: RawRepresentable, Hashable, Sendable, Decodable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The token is wrong or was revoked.
        public static let invalidToken = Code(rawValue: "invalid_token")
        /// The token expired (personal tokens last 90 days by default).
        public static let tokenExpired = Code(rawValue: "token_expired")
        /// The token lacks a scope, such as `activity:write`.
        public static let insufficientScope = Code(rawValue: "insufficient_scope")
        /// Unknown game, a game not in your library, or writes turned off.
        public static let notFound = Code(rawValue: "not_found")
        /// For example: the session is already finished, or too many are open.
        public static let conflict = Code(rawValue: "conflict")
        /// The same Idempotency-Key was sent with a different body.
        public static let idempotencyConflict = Code(rawValue: "idempotency_conflict")
        public static let rateLimited = Code(rawValue: "rate_limited")
        public static let serviceUnavailable = Code(rawValue: "service_unavailable")
    }
}
