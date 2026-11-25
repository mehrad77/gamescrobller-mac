/// A game the app found running on this Mac.
///
/// A `struct` is a *value type*: assigning it copies it, so two parts of the app
/// never accidentally change the same game. Most Swift data types are structs;
/// classes (reference types) are kept for things with identity and shared
/// state, such as a long-lived service.
///
/// `Codable` (`Encodable` plus `Decodable`) lets it be saved in the play
/// journal. Every stored property is itself `Codable`, so the compiler writes
/// the code; the enum below becomes `{"steam": {"appID": 330020}}`.
public struct DetectedGame: Codable, Hashable, Identifiable, Sendable {
    /// Where the game came from, with that launcher's own id for it.
    public enum Source: Codable, Hashable, Sendable {
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

    /// The reference the game is sent to GameScrobbler as: the store's own
    /// id, such as `steam:570` or `apple:1456188526`.
    ///
    /// Not optional: every source has a store prefix. A `switch` must cover
    /// every case, so adding a source (GOG, Epic) without a reference here is a
    /// build error, not a silent gap.
    public var defaultRef: GameRef {
        switch source {
        case .steam(let appID):
            return .store(.steam, id: String(appID))
        case .appStore(let adamID):
            return .store(.apple, id: String(adamID))
        }
    }
}
