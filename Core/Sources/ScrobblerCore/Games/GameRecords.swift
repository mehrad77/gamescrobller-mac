import Foundation

/// What the app keeps about one game: whether you scrobble it, and what the
/// server last said about it.
///
/// Every field has a default, so a game nobody touched needs no entry.
/// A game is always sent as its own store id (`DetectedGame.defaultRef`):
/// you choose whether it is scrobbled, never which id it is sent as.
public struct GameRecord: Codable, Hashable, Sendable {
    /// What the server said about the game.
    public enum Lookup: Codable, Hashable, Sendable {
        /// In your library, by this title and slug (its page is
        /// `gamescrobbler.com/games/<slug>`) when the server said them.
        ///
        /// An associated value can have a default, so `.inLibrary(title:)`
        /// also works. An optional one may be missing from a saved file.
        case inLibrary(title: String?, slug: String? = nil)
        /// Looking it up in your library answered 404: not in your library
        /// yet, so its plays would be refused.
        case notInLibrary
        /// Adding it to the library answered 404: GameScrobbler's catalogue
        /// has no game for its store id.
        case unknownGame
    }

    /// Never scrobbled.
    public var ignored: Bool
    public var lookup: Lookup?

    public init(ignored: Bool = false, lookup: Lookup? = nil) {
        self.ignored = ignored
        self.lookup = lookup
    }

    /// Nothing chosen and nothing learned: no need to keep it.
    var isEmpty: Bool { !ignored && lookup == nil }
}

/// The records of every game on this Mac, by `DetectedGame.id`.
///
/// A value type: the app keeps the one everybody edits, and tells the
/// scrobbler only which games are ignored (`ScrobbleEvent.ignoredGamesChanged`).
public struct GameRecords: Codable, Hashable, Sendable {
    private var byGame: [String: GameRecord]

    public init(_ byGame: [String: GameRecord] = [:]) {
        self.byGame = byGame.filter { !$0.value.isEmpty }
    }

    /// A *subscript* lets `records[game.id]` read and write like a
    /// dictionary. A game with no entry reads as the default record, and
    /// writing the default back removes the entry.
    public subscript(gameID: String) -> GameRecord {
        get { byGame[gameID] ?? GameRecord() }
        set { byGame[gameID] = newValue.isEmpty ? nil : newValue }
    }

    /// The ids of the games you set not to be scrobbled.
    public var ignoredGames: Set<String> {
        Set(byGame.filter { $0.value.ignored }.keys)
    }
}

/// Where the records are saved: one small JSON file per server, next to the
/// play journal (`games-api.gamescrobbler.com.json`), since what is in your
/// library depends on the server.
public struct GameRecordStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(directory: URL, server baseURL: URL) {
        let journalName = PlayJournal.fileName(for: baseURL)
        // `plays-<host>.json` becomes `games-<host>.json`.
        let name = "games-" + journalName.dropFirst("plays-".count)
        self.init(fileURL: directory.appending(path: name))
    }

    /// The saved records. A missing or unreadable file gives none: losing a
    /// record costs a lookup, never a play, so no damaged-file dance.
    public func load() -> GameRecords {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode(GameRecords.self, from: data)
        else { return GameRecords() }
        return records
    }

    public func save(_ records: GameRecords) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
