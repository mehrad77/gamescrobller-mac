import Foundation

/// Recognises games installed by Steam, from where the running game lives.
///
/// Steam installs every game under a library folder:
///
///     <library>/steamapps/appmanifest_330020.acf   <- appid, name, installdir
///     <library>/steamapps/common/ChildrenOfMorta/  <- the game ("installdir")
///
/// and lists its libraries in `~/Library/Application Support/Steam/steamapps/libraryfolders.vdf`.
/// So a process whose path contains `steamapps/common/<installdir>/` is that
/// game, and its manifest gives the Steam app id.
public struct SteamClassifier: GameClassifier {
    /// One installed Steam game.
    public struct InstalledApp: Equatable, Sendable {
        public let appID: Int
        public let name: String
        /// The game's folder, `<library>/steamapps/common/<installdir>`.
        public let installURL: URL

        /// The same `DetectedGame` that `classify` returns for this game's
        /// processes, so an installed game and a running one compare equal.
        public var detectedGame: DetectedGame {
            DetectedGame(id: installURL.path(percentEncoded: false), name: name, source: .steam(appID: appID))
        }
    }

    /// Installed games keyed by their install folder path, so a lookup is one
    /// dictionary read instead of a scan.
    public let installedApps: [String: InstalledApp]

    /// The default Steam folder for the current user.
    public static var defaultSteamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Steam")
    }

    /// Reads every library and manifest once. Unreadable or broken files are
    /// skipped rather than thrown: one bad manifest should not hide every game.
    public init(steamRoot: URL = SteamClassifier.defaultSteamRoot) {
        var apps: [String: InstalledApp] = [:]
        for library in Self.libraryFolders(steamRoot: steamRoot) {
            for app in Self.installedApps(inLibrary: library) {
                apps[Self.key(for: app.installURL)] = app
            }
        }
        installedApps = apps
    }

    public func classify(_ app: LaunchedApp) -> DetectedGame? {
        // Prefer the executable: a bare binary has no bundle at all.
        guard let url = app.executableURL ?? app.bundleURL,
              let installURL = Self.installFolder(containing: url),
              let installed = installedApps[Self.key(for: installURL)]
        else { return nil }

        return installed.detectedGame
    }

    // MARK: - Reading Steam's files
    // (`MARK:` comments show up as section headers in VS Code's outline.)

    /// Library roots from libraryfolders.vdf, always including the Steam root.
    static func libraryFolders(steamRoot: URL) -> [URL] {
        var folders = [steamRoot]
        let vdfURL = steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        // `try?` turns "file missing" or "parse error" into nil.
        if let text = try? String(contentsOf: vdfURL, encoding: .utf8),
           let root = try? ValveKeyValues.parse(text),
           case .block(let libraries)? = root["libraryfolders"] {
            for library in libraries.values {
                if let path = library["path"]?.string {
                    folders.append(URL(filePath: path, directoryHint: .isDirectory))
                }
            }
        }
        // Remove duplicates while keeping order (the root is usually listed too).
        var seen = Set<String>()
        return folders.filter { seen.insert(key(for: $0)).inserted }
    }

    static func installedApps(inLibrary library: URL) -> [InstalledApp] {
        let steamapps = library.appending(path: "steamapps")
        let files = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
            .compactMap { manifestURL -> InstalledApp? in
                guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
                      let root = try? ValveKeyValues.parse(text),
                      let appIDText = root["AppState", "appid"]?.string,
                      let appID = Int(appIDText),
                      let installDir = root["AppState", "installdir"]?.string,
                      !installDir.isEmpty
                else { return nil }
                let name = root["AppState", "name"]?.string ?? installDir
                let installURL = steamapps.appending(path: "common").appending(path: installDir, directoryHint: .isDirectory)
                return InstalledApp(appID: appID, name: name, installURL: installURL)
            }
    }

    /// `/…/steamapps/common/Game/Game.app/Contents/MacOS/Game` -> `/…/steamapps/common/Game`.
    static func installFolder(containing url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        // `indices.dropLast(2)` leaves room for "common" and the install dir.
        for i in parts.indices.dropLast(2) where parts[i] == "steamapps" && parts[i + 1] == "common" {
            // `[...]` with a range takes a slice of the array.
            return URL(filePath: NSString.path(withComponents: Array(parts[...(i + 2)])), directoryHint: .isDirectory)
        }
        return nil
    }

    /// A comparable form of a folder path: standardized, no trailing slash,
    /// lowercased because the Mac's disk ignores case by default.
    static func key(for url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.lowercased()
    }
}
