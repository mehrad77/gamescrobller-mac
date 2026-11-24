import Foundation
import Testing
@testable import ScrobblerCore

/// Builds throwaway `.app` folders on disk, so the classifier reads real
/// files without depending on what is installed on this Mac.
///
/// Cleaning up in a `deinit` would be neat, but ordinary structs have no
/// deinitializer (classes do), so each test calls `cleanUp()` with `defer`.
struct FakeAppBundle {
    let root: URL
    var appURL: URL { root.appending(path: "Fake Game.app") }

    /// `throws` means creating the bundle can fail; callers must use `try`.
    init(category: String?, appStoreReceipt: Bool, bundleID: String = "com.example.fakegame") throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let contents = root.appending(path: "Fake Game.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        // A dictionary literal of type [String: Any]: Any because plist values
        // can be strings, numbers, arrays…
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Fake Game",
            "CFBundlePackageType": "APPL",
        ]
        if let category { info["LSApplicationCategoryType"] = category }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))

        if appStoreReceipt {
            let receiptDir = contents.appending(path: "_MASReceipt")
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data().write(to: receiptDir.appending(path: "receipt"))
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("AppStoreClassifier")
struct AppStoreClassifierTests {
    // A fake Spotlight: always answers 42. `{ _ in 42 }` is a closure that
    // ignores its URL argument (`_`).
    let classifier = AppStoreClassifier(lookUpAdamID: { _ in 42 })

    @Test("recognises App Store games", arguments: [
        "public.app-category.games",
        "public.app-category.simulation-games",
        "public.app-category.puzzle-games",
    ])
    func recognisesGames(category: String) throws {
        let app = try FakeAppBundle(category: category, appStoreReceipt: true)
        defer { app.cleanUp() }  // `defer` runs when the function exits, even on failure

        let game = try #require(classifier.classify(appURL: app.appURL))
        #expect(game.id == "com.example.fakegame")
        #expect(game.name == "Fake Game")
        #expect(game.source == .appStore(adamID: 42))
    }

    @Test func ignoresAppsWithoutAReceipt() throws {
        let app = try FakeAppBundle(category: "public.app-category.games", appStoreReceipt: false)
        defer { app.cleanUp() }
        #expect(classifier.classify(appURL: app.appURL) == nil)
    }

    @Test("ignores App Store apps that are not games", arguments: [
        "public.app-category.productivity",
        "public.app-category.music",
        nil,  // no category at all
    ] as [String?])
    func ignoresNonGames(category: String?) throws {
        let app = try FakeAppBundle(category: category, appStoreReceipt: true)
        defer { app.cleanUp() }
        #expect(classifier.classify(appURL: app.appURL) == nil)
    }

    @Test func ignoresGamesSpotlightDoesNotKnow() throws {
        let noSpotlight = AppStoreClassifier(lookUpAdamID: { _ in nil })
        let app = try FakeAppBundle(category: "public.app-category.games", appStoreReceipt: true)
        defer { app.cleanUp() }
        #expect(noSpotlight.classify(appURL: app.appURL) == nil)
    }

    @Test func ignoresFoldersThatAreNotBundles() {
        let folder = FileManager.default.temporaryDirectory
        #expect(classifier.classify(appURL: folder) == nil)
    }
}
