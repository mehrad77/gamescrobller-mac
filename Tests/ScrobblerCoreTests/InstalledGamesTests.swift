import Foundation
import Testing
@testable import ScrobblerCore

@Suite("InstalledGames")
struct InstalledGamesTests {
    @Test func listsAppStoreAndSteamGamesTogether() throws {
        let app = try FakeAppBundle(category: "public.app-category.games", appStoreReceipt: true)
        let steam = try FakeSteam()
        defer { app.cleanUp(); steam.cleanUp() }

        let games = InstalledGames.scan(
            appStore: AppStoreClassifier(lookUpAdamID: { _ in 7 }),
            steam: SteamClassifier(steamRoot: steam.steamRoot),
            applicationsFolder: app.root
        )
        #expect(games.map(\.name) == ["Children of Morta", "Fake Game", "Hades"])
    }

    @Test func anInstalledSteamGameEqualsTheRunningOne() throws {
        let steam = try FakeSteam()
        defer { steam.cleanUp() }
        let classifier = SteamClassifier(steamRoot: steam.steamRoot)

        let installed = try #require(classifier.installedApps.values.first { $0.appID == 330020 })
        let running = classifier.classify(LaunchedApp(
            bundleURL: nil,
            executableURL: installed.installURL.appending(path: "ChildrenOfMorta.app/Contents/MacOS/ChildrenOfMorta")))
        #expect(running == installed.detectedGame)
    }
}
