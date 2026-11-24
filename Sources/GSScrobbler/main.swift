// A file named main.swift is the program's entry point: its top-level code
// runs from top to bottom when the executable starts. Later this becomes a
// SwiftUI `App` marked with `@main` instead.
//
// For now it is a small debug tool:
//   swift run GSScrobbler           lists the games this Mac has
//   swift run GSScrobbler --watch   prints games as they start and stop

import Foundation
import ScrobblerCore

log("GameScrobbler for Mac \(ScrobblerCore.version)\n")

let appStore = AppStoreClassifier()
let steam = SteamClassifier()

// `CommandLine.arguments[0]` is the program itself; options follow it.
if CommandLine.arguments.contains("--watch") {
    watch()
} else {
    listInstalledGames()
}

func listInstalledGames() {
    // `try?` turns a thrown error into nil, and `?? []` then gives an empty
    // list: if /Applications cannot be read we print nothing instead of crashing.
    let apps = (try? FileManager.default.contentsOfDirectory(
        at: URL(filePath: "/Applications"), includingPropertiesForKeys: nil)) ?? []

    // `compactMap` transforms each element and drops the nils, so only games
    // remain. `sorted { … }` takes a closure that says which of two comes first.
    let appStoreGames = apps
        .filter { $0.pathExtension == "app" }
        .compactMap { appStore.classify(appURL: $0) }
        .sorted { $0.name < $1.name }

    print("App Store games in /Applications: \(appStoreGames.count)")
    for game in appStoreGames {
        // `if case` pulls the associated value out of one enum case.
        if case .appStore(let adamID) = game.source {
            print("  \(game.name)  [\(game.id)]  apple:\(adamID)  ->  needs mapping")
        }
    }

    let steamGames = steam.installedApps.values.sorted { $0.name < $1.name }
    print("\nSteam games installed: \(steamGames.count)")
    for app in steamGames {
        print("  \(app.name)  ->  steam:\(app.appID)")
    }
}

/// Writes one line to the terminal immediately. `print` buffers its output
/// when it goes to a file or pipe, so a long-running process killed with
/// Ctrl+C or `kill` could lose its last lines. `FileHandle` writes straight
/// through.
func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func watch() {
    let tracker = GameTracker(classifiers: [appStore, steam])
    log("Watching for games. Start or quit one; press Ctrl+C to stop.\n")

    // `Task { @MainActor in … }` starts concurrent work on the main thread,
    // where the ProcessMonitor (an AppKit user) must live.
    Task { @MainActor in
        let monitor = ProcessMonitor(pollInterval: .seconds(5))
        // `for await` reads the stream one event at a time, in order.
        for await processEvent in monitor.events() {
            for gameEvent in await tracker.handle(processEvent) {
                let time = Date.now.formatted(date: .omitted, time: .standard)
                switch gameEvent {
                case .started(let game):
                    log("[\(time)] started  \(game.name)  ->  \(game.defaultRef?.apiValue ?? "needs mapping")")
                case .stopped(let game):
                    log("[\(time)] stopped  \(game.name)")
                }
            }
        }
    }

    // AppKit delivers workspace notifications through the main run loop, so
    // keep it running forever. This call never returns.
    RunLoop.main.run()
}
