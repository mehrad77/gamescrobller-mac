import Foundation
import Testing
@testable import ScrobblerCore

/// A fake Steam install in a temp folder: a main library plus a second one on
/// "another drive", each with one game.
struct FakeSteam {
    let root: URL
    var steamRoot: URL { root.appending(path: "Steam") }
    var otherLibrary: URL { root.appending(path: "External/SteamLibrary") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Self.write("""
            "libraryfolders"
            {
                "0" { "path" "\(steamRoot.path(percentEncoded: false))" }
                "1" { "path" "\(otherLibrary.path(percentEncoded: false))" }
            }
            """, to: steamRoot.appending(path: "steamapps/libraryfolders.vdf"))
        try Self.addGame(appID: 330020, name: "Children of Morta", installDir: "ChildrenOfMorta", library: steamRoot)
        try Self.addGame(appID: 1145360, name: "Hades", installDir: "Hades", library: otherLibrary)
    }

    static func addGame(appID: Int, name: String, installDir: String, library: URL) throws {
        try write("""
            "AppState" { "appid" "\(appID)" "name" "\(name)" "installdir" "\(installDir)" }
            """, to: library.appending(path: "steamapps/appmanifest_\(appID).acf"))
        try FileManager.default.createDirectory(
            at: library.appending(path: "steamapps/common/\(installDir)"), withIntermediateDirectories: true)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("SteamClassifier")
struct SteamClassifierTests {
    @Test func readsEveryLibrary() throws {
        let steam = try FakeSteam()
        defer { steam.cleanUp() }
        let classifier = SteamClassifier(steamRoot: steam.steamRoot)
        // `map(\.appID)` uses a key path to pull one property out of each value.
        #expect(Set(classifier.installedApps.values.map(\.appID)) == [330020, 1145360])
    }

    @Test func recognisesAnAppBundleGame() throws {
        let steam = try FakeSteam()
        defer { steam.cleanUp() }
        let classifier = SteamClassifier(steamRoot: steam.steamRoot)

        let bundle = steam.steamRoot.appending(path: "steamapps/common/ChildrenOfMorta/ChildrenOfMorta.app")
        let launched = LaunchedApp(bundleURL: bundle,
                                   executableURL: bundle.appending(path: "Contents/MacOS/ChildrenOfMorta"))
        let game = try #require(classifier.classify(launched))
        #expect(game.name == "Children of Morta")
        #expect(game.source == .steam(appID: 330020))
        #expect(game.defaultRef == .store(.steam, id: "330020"))
    }

    @Test func recognisesABareExecutableInASecondLibrary() throws {
        let steam = try FakeSteam()
        defer { steam.cleanUp() }
        let classifier = SteamClassifier(steamRoot: steam.steamRoot)

        let executable = steam.otherLibrary.appending(path: "steamapps/common/Hades/bin/Hades")
        let game = try #require(classifier.classify(LaunchedApp(bundleURL: nil, executableURL: executable)))
        #expect(game.source == .steam(appID: 1145360))
    }

    @Test func helperProcessesOfOneGameShareAnID() throws {
        let steam = try FakeSteam()
        defer { steam.cleanUp() }
        let classifier = SteamClassifier(steamRoot: steam.steamRoot)

        let common = steam.steamRoot.appending(path: "steamapps/common/ChildrenOfMorta")
        let main = classifier.classify(LaunchedApp(bundleURL: nil, executableURL: common.appending(path: "Game.app/Contents/MacOS/Game")))
        let helper = classifier.classify(LaunchedApp(bundleURL: nil, executableURL: common.appending(path: "tools/crashpad_handler")))
        #expect(main != nil)
        #expect(main?.id == helper?.id)
    }

    @Test func ignoresProgramsOutsideSteamAndUnknownFolders() throws {
        let steam = try FakeSteam()
        defer { steam.cleanUp() }
        let classifier = SteamClassifier(steamRoot: steam.steamRoot)

        let outside = LaunchedApp(bundleURL: URL(filePath: "/Applications/Safari.app"), executableURL: nil)
        // A folder with no manifest, like a leftover from an uninstalled game.
        let leftover = LaunchedApp(bundleURL: nil, executableURL: steam.steamRoot.appending(path: "steamapps/common/dota 2 beta/game/dota2"))
        #expect(classifier.classify(outside) == nil)
        #expect(classifier.classify(leftover) == nil)
    }

    @Test func installFolderStopsAtTheGameFolder() {
        let url = URL(filePath: "/Volumes/Games/SteamLibrary/steamapps/common/Hades/Hades.app/Contents/MacOS/Hades")
        // Compare path components, not text: a folder URL's path ends in "/".
        let folder = SteamClassifier.installFolder(containing: url)
        #expect(folder?.pathComponents.suffix(3) == ["steamapps", "common", "Hades"])
        #expect(SteamClassifier.installFolder(containing: URL(filePath: "/steamapps/common")) == nil)
    }
}
