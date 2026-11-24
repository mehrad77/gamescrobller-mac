// `gs-detect`: a command-line debug tool for the detection code, separate
// from the menu bar app. A file named main.swift is a program's entry point:
// its top-level code runs from top to bottom.
//
//   swift run gs-detect           lists the games this Mac has
//   swift run gs-detect --watch   prints games as they start and stop

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
    let games = InstalledGames.scan(appStore: appStore, steam: steam)
    log("Games this Mac has: \(games.count)")
    for game in games {
        // `if case` pulls the associated value out of one enum case.
        if case .appStore(let adamID) = game.source {
            log("  \(game.name)  [App Store, apple:\(adamID)]  ->  needs mapping")
        } else if let ref = game.defaultRef {
            log("  \(game.name)  ->  \(ref)")
        }
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
