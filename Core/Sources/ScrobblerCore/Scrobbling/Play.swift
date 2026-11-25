import Foundation

/// One stretch of play of one game: from when it became the game being
/// scrobbled to when it stopped. It becomes one GameScrobbler session.
///
/// A play stays in the `PlayJournal` until the server has all of it, so a
/// quit, a crash or a night offline never loses it.
///
/// Which request a play needs next follows from its fields:
///
/// | `sessionID` | `endedAt` | Next request                                    |
/// | ----------- | --------- | ----------------------------------------------- |
/// | nil         | nil       | a live start (`POST /me/sessions`)              |
/// | set         | nil       | none: heartbeats keep it open                   |
/// | set         | set       | a finish (`POST /me/sessions/{id}/finish`)      |
/// | nil         | set       | one start with `startedAt` and `endedAt` (a log) |
///
/// API docs: https://developers.gamescrobbler.com/guides/recording-play/#the-full-path-sessions
public struct Play: Codable, Hashable, Identifiable, Sendable {
    /// Our own id for this play, sent as `clientSessionId`. The server keeps
    /// it, so sending a play again after the idempotency key has expired (24
    /// hours) still returns the same session instead of a second one.
    public let id: String
    /// The game, for the menu.
    public let game: DetectedGame
    /// The reference sent in `game`. It is fixed when the play begins, so a
    /// later change to how the game is mapped never changes a request that
    /// must be retried with exactly the same body.
    public let ref: GameRef
    public let startedAt: Date
    /// The last time the app saw the game still running. If the app dies
    /// mid-play, the play ends here.
    public var lastSeenAt: Date
    /// When play stopped; nil while the game is still running.
    public var endedAt: Date?
    /// The server's id for the session, once a live start went through.
    public var sessionID: String?
    /// The `Idempotency-Key` of the next request. It is kept with the play,
    /// so a retry sends the same key even after a relaunch. A request with a
    /// new body (the play ended, so the body now has `endedAt`) gets a new
    /// key: the server refuses an old key sent with a different body.
    public var idempotencyKey: String

    public init(
        id: String,
        game: DetectedGame,
        ref: GameRef,
        startedAt: Date,
        lastSeenAt: Date? = nil,
        endedAt: Date? = nil,
        sessionID: String? = nil,
        idempotencyKey: String
    ) {
        self.id = id
        self.game = game
        self.ref = ref
        self.startedAt = startedAt
        // `??` gives the value on its right when the left one is nil.
        self.lastSeenAt = lastSeenAt ?? startedAt
        self.endedAt = endedAt
        self.sessionID = sessionID
        self.idempotencyKey = idempotencyKey
    }
}
