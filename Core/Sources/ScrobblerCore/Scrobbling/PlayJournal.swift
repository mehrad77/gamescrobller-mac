import Foundation

/// The plays not yet fully sent, kept in a JSON file.
///
/// The scrobbler saves the whole list after every change and reads it back
/// when it starts, so a quit, a crash or a night offline loses nothing: the
/// plays are sent once the server can be reached again.
///
/// There is one file per server (`plays-api.gamescrobbler.com.json`,
/// `plays-localhost-8000.json`). The session ids inside only mean something
/// to the server that made them, so a switch from a local stack to
/// production never sends one to the other.
///
/// A plain struct holding a file location: it keeps nothing in memory, and
/// every `load` reads the file as it is now.
public struct PlayJournal: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The journal for the server at `baseURL`, inside `directory`.
    public init(directory: URL, server baseURL: URL) {
        self.init(fileURL: directory.appending(path: Self.fileName(for: baseURL)))
    }

    /// `plays-<host>.json`, with `-<port>` when the URL names a port.
    static func fileName(for baseURL: URL) -> String {
        var name = "plays-" + (baseURL.host() ?? "server")
        // `if let` runs its block only when the optional has a value.
        if let port = baseURL.port {
            name += "-\(port)"
        }
        return name + ".json"
    }

    /// The saved plays, oldest first. No file yet means no plays.
    ///
    /// It `throws` (any error, untyped) when the file exists but cannot be
    /// read or is not a valid journal: the caller decides what to do, rather
    /// than this quietly answering "no plays" and the next save overwriting
    /// them.
    public func load() throws -> [Play] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            // A `catch` can match one specific error. Only "no such file"
            // means "nothing saved yet"; every other error is rethrown.
            return []
        }
        return try Self.makeDecoder().decode([Play].self, from: data)
    }

    /// Replaces the file with `plays`.
    public func save(_ plays: [Play]) throws {
        // The folder may not exist yet on the first save.
        // `withIntermediateDirectories: true` also makes the missing parents,
        // and is not an error when the folder is already there.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(plays)
        // `.atomic` writes a temporary file, then renames it over the old
        // one. A crash halfway leaves the old journal, never half of a new one.
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - JSON

    /// The API's own date format, so a time read back from the file is sent
    /// exactly as it was the first time: ISO 8601, UTC, whole seconds. The
    /// output is indented with sorted keys, so the file is easy to read.
    static func makeEncoder() -> JSONEncoder {
        let encoder = GSClient.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        GSClient.makeDecoder()
    }
}
