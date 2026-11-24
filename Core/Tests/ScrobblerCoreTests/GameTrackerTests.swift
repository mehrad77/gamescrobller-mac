import Foundation
import Testing
@testable import ScrobblerCore

/// A classifier for tests: any executable under `/Games/<name>/` is the game
/// `<name>`. Conforming to the protocol is all it takes to plug it in.
struct FolderClassifier: GameClassifier {
    func classify(_ app: LaunchedApp) -> DetectedGame? {
        guard let parts = app.executableURL?.pathComponents,
              parts.count > 2, parts[1] == "Games"
        else { return nil }
        return DetectedGame(id: "/Games/\(parts[2])", name: parts[2], source: .steam(appID: parts[2].count))
    }
}

/// Shorthand so the tests read like a story.
func exe(_ path: String) -> LaunchedApp {
    LaunchedApp(bundleURL: nil, executableURL: URL(filePath: path))
}

@Suite("GameTracker")
struct GameTrackerTests {
    let tracker = GameTracker(classifiers: [FolderClassifier()])

    // Test functions can be `async`: calls into an actor need `await`.
    @Test func aGameStartsAndStops() async {
        let started = await tracker.handle(.launched(pid: 10, app: exe("/Games/Hades/Hades")))
        #expect(started.map(\.description) == ["started Hades"])

        let stopped = await tracker.handle(.terminated(pid: 10))
        #expect(stopped.map(\.description) == ["stopped Hades"])
        #expect(await tracker.runningGames.isEmpty)
    }

    @Test func helperProcessesDoNotStartOrStopTheGameTwice() async {
        _ = await tracker.handle(.launched(pid: 10, app: exe("/Games/Hades/Hades")))
        let helper = await tracker.handle(.launched(pid: 11, app: exe("/Games/Hades/crashpad_handler")))
        #expect(helper.isEmpty)

        // The main process quits first; the game is still "running".
        #expect(await tracker.handle(.terminated(pid: 10)).isEmpty)
        // Only the last process ending stops it.
        #expect(await tracker.handle(.terminated(pid: 11)).map(\.description) == ["stopped Hades"])
    }

    @Test func nonGamesAndUnknownPidsAreIgnored() async {
        #expect(await tracker.handle(.launched(pid: 20, app: exe("/Applications/Safari.app/Contents/MacOS/Safari"))).isEmpty)
        #expect(await tracker.handle(.terminated(pid: 999)).isEmpty)
    }

    @Test func aDuplicateLaunchOfTheSamePidIsIgnored() async {
        // The notification and the poll can both report the same process.
        _ = await tracker.handle(.launched(pid: 10, app: exe("/Games/Hades/Hades")))
        #expect(await tracker.handle(.launched(pid: 10, app: exe("/Games/Hades/Hades"))).isEmpty)
    }

    @Test func aSnapshotCatchesMissedLaunchesAndQuits() async {
        _ = await tracker.handle(.launched(pid: 10, app: exe("/Games/Hades/Hades")))

        // Hades quit without a notification; Celeste started as a bare binary.
        let events = await tracker.handle(.snapshot([
            1: exe("/sbin/launchd"),
            30: exe("/Games/Celeste/Celeste"),
        ]))
        // Sort so the test does not depend on dictionary order.
        #expect(events.map(\.description).sorted() == ["started Celeste", "stopped Hades"])
        #expect(await tracker.runningGames.map(\.name) == ["Celeste"])
    }
}

/// Readable test output: "started Hades" instead of a long enum dump.
extension GameEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .started(let game): "started \(game.name)"
        case .stopped(let game): "stopped \(game.name)"
        }
    }
}
