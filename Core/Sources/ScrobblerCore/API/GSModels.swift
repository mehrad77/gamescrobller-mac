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

/// One game in your library, from `GET /me/library/{game}`. Only the
/// fields the app uses; the answer has more.
///
/// API docs: https://developers.gamescrobbler.com/reference/#api-1/tag/library/GET/me/library/{game}
public struct GSLibraryItem: Decodable, Sendable, Equatable {
    public let gameId: String
    public let slug: String?
    public let title: String
}

/// What looking a game up in your library came to.
public enum LibraryLookupOutcome: Sendable, Equatable {
    case inLibrary(GSLibraryItem)
    /// 404: not in your library, or a reference the server does not know.
    case notInLibrary
    /// Offline, or anything else: nothing learned.
    case failed(GSClientError)
}

/// The body of `POST /me/library/entries`.
struct CreateLibraryEntryBody: Encodable {
    var game: GameRef
}

/// A custom library entry, from `POST /me/library/entries`.
///
/// API docs: https://developers.gamescrobbler.com/reference/#api-1/tag/library/POST/me/library/entries
public struct GSLibraryEntry: Decodable, Sendable, Equatable {
    /// The entry's id, used to delete it.
    public let id: String
    /// The game the reference resolved to.
    public let gameId: String
    public let slug: String?
    /// The game's title on GameScrobbler: the proof the reference named the
    /// game you meant.
    public let title: String
    public let createdAt: Date
}

/// What adding a game to the library came to, sorted by what the app does
/// next.
public enum LibraryEntryOutcome: Sendable, Equatable {
    /// 200 or 201: the game is in the library now. Its plays can be sent.
    case added(GSLibraryEntry)
    /// 409: the game was already in the library (from a store you linked, or
    /// another app's entry). Its plays can be sent too.
    case alreadyInLibrary
    /// 404: GameScrobbler's catalogue has no game for this reference (or
    /// scrobbling is off on the server, which answers the same).
    case unknownGame
    /// Anything else (offline, the daily limit, a token without
    /// `library:write`): nothing changed, and asking again later may work.
    case failed(GSClientError)

    init(error: GSClientError) {
        if case .api(let api) = error {
            switch api.status {
            case 409 where api.code == .conflict: self = .alreadyInLibrary; return
            case 404: self = .unknownGame; return
            default: break
            }
        }
        self = .failed(error)
    }
}

/// A `GameRef` goes into JSON as the API's text form, such as `"steam:570"`,
/// both in request bodies and in the play journal.
///
/// Writing `encode(to:)` and `init(from:)` by hand replaces what the compiler
/// would generate. A *single value container* holds one plain value instead
/// of an object.
extension GameRef: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(apiValue)
    }

    /// Reading goes through the same parser as typed text, so a damaged
    /// value in a saved file is an error, never a wrong game.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let ref = GameRef(parsing: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a game reference: \(text)"
            )
        }
        self = ref
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
