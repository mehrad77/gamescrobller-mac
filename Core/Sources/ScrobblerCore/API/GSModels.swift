import Foundation

// The JSON shapes of the GameScrobbler public API (`/v1`) that the app uses.
// Full reference: https://developers.gamescrobbler.com/reference/

/// Your GameScrobbler profile, from `GET /me`.
///
/// API docs: https://developers.gamescrobbler.com/reference/#api-1/tag/profile/GET/me
///
/// `Decodable` lets `JSONDecoder` build this struct from JSON. The compiler
/// writes the decoding code: each stored property reads the JSON key with the
/// same name, and an optional (`String?`) accepts `null`. JSON keys the struct
/// does not list are ignored, so the app keeps working when the server adds
/// fields.
public struct GSProfile: Decodable, Sendable, Equatable {
    public let id: String
    /// Your public handle without the @, or nil if you have not claimed one.
    public let handle: String?
    public let displayName: String?
    public let avatarUrl: String?
    /// The stores and platforms you have linked, such as `steam`.
    public let platforms: [String]
}

/// A play session, as the session endpoints return it.
///
/// API docs: https://developers.gamescrobbler.com/reference/#api-1/tag/activity/POST/me/sessions
public struct GSSession: Decodable, Sendable, Equatable, Identifiable {
    /// Pass this to `heartbeat` and `finishSession`.
    public let id: String
    public let gameId: String
    public let gameSlug: String?
    public let gameTitle: String
    public let clientSessionId: String
    public let deviceId: String?
    /// `Date`, not `String`: the decoder turns the ISO 8601 text into a real
    /// point in time (see `GSClient.makeDecoder`).
    public let startedAt: Date
    public let lastHeartbeatAt: Date
    /// nil while the session is still open.
    public let endedAt: Date?
    public let durationSeconds: Int
    public let isActive: Bool
    /// false when another session already counts this time (for example a
    /// Steam session that overlaps it).
    public let countsTowardTotals: Bool
}

/// The body of `POST /me/sessions`.
///
/// Leave `endedAt` nil to start a live session (then heartbeat and finish
/// it), or set both `startedAt` and `endedAt` to log a session that is
/// already over, in one call.
///
/// API docs:
/// - https://developers.gamescrobbler.com/reference/#api-1/tag/activity/POST/me/sessions
/// - https://developers.gamescrobbler.com/guides/recording-play/#start-a-session
/// - https://developers.gamescrobbler.com/guides/recording-play/#log-a-session-that-is-already-over
///
/// `Encodable` is the other direction: struct to JSON. The generated code
/// skips properties that are nil, so they are left out of the JSON entirely.
public struct StartSessionRequest: Encodable, Sendable, Equatable {
    public var game: GameRef
    /// One stable id per Mac, so each new session ends the previous one.
    public var deviceId: String?
    public var clientSessionId: String?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        game: GameRef,
        deviceId: String? = nil,
        clientSessionId: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.game = game
        self.deviceId = deviceId
        self.clientSessionId = clientSessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// The body of `POST /me/sessions/{id}/finish`: `{}` ends the session now.
struct FinishSessionBody: Encodable {
    var endedAt: Date?
}

/// A `GameRef` goes into JSON as the API's text form, such as `"steam:570"`.
///
/// Writing `encode(to:)` by hand replaces what the compiler would generate.
/// A *single value container* holds one plain value instead of an object.
extension GameRef: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(apiValue)
    }
}

/// The one error shape on every `/v1` response:
/// `{"error": {"code": "...", "message": "...", "requestId": "..."}}`.
///
/// A struct nested inside another just namespaces it: `ErrorBody.Detail`.
struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let code: GSAPIError.Code
        let message: String
        let requestId: String
    }

    let error: Detail
}
