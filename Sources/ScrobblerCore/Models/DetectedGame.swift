/// A game the app found running on this Mac.
///
/// A `struct` is a *value type*: assigning it copies it, so two parts of the app
/// never accidentally change the same game. Most Swift data types are structs;
/// classes (reference types) are kept for things with identity and shared
/// state, such as a long-lived service.
public struct DetectedGame: Hashable, Identifiable, Sendable {
    /// Where the game came from, with that launcher's own id for it.
    public enum Source: Hashable, Sendable {
        /// Mac App Store or Apple Arcade, keyed by the App Store ("Adam") id.
        case appStore(adamID: Int)
        /// Steam, keyed by the Steam app id.
        case steam(appID: Int)
    }

    /// A stable key for this game on this Mac: the bundle identifier when the
    /// game is an app bundle, else its install folder. `Identifiable` requires
    /// it, and SwiftUI lists use it to tell rows apart.
    public let id: String
    /// The name shown in the menu, such as "Mini Motorways".
    public let name: String
    public let source: Source

    /// A *memberwise initializer*. Swift writes one automatically for structs,
    /// but only `internal`; a `public` type used from another module (the app)
    /// needs an explicit `public init`.
    public init(id: String, name: String, source: Source) {
        self.id = id
        self.name = name
        self.source = source
    }

    /// The reference to send to GameScrobbler when nobody has mapped this game
    /// by hand, or `nil` when the server has no way to name it yet.
    ///
    /// App Store games return nil: GameScrobbler has no `apple:` prefix, so
    /// those need a manual mapping to a GS slug or id (a later step).
    public var defaultRef: GameRef? {
        switch source {
        case .steam(let appID):
            return .store(.steam, id: String(appID))
        case .appStore:
            return nil
        }
    }
}
