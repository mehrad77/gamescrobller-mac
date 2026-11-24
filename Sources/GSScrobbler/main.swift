// A file named main.swift is the program's entry point: its top-level code
// runs from top to bottom when the executable starts. Later this becomes a
// SwiftUI `App` marked with `@main` instead.
//
// For now it is a small debug tool: `swift run GSScrobbler` lists the
// App Store games installed in /Applications.

import Foundation
import ScrobblerCore

print("GameScrobbler for Mac \(ScrobblerCore.version)\n")

let applications = URL(filePath: "/Applications")
let classifier = AppStoreClassifier()

// `try?` turns a thrown error into nil, and `?? []` then gives an empty list:
// if /Applications cannot be read we print nothing instead of crashing.
let apps = (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? []

// `compactMap` transforms each element and drops the nils, so only games
// remain. `sorted { … }` takes a closure that says which of two comes first.
let games = apps
    .filter { $0.pathExtension == "app" }
    .compactMap { classifier.classify(appURL: $0) }
    .sorted { $0.name < $1.name }

print("App Store games in /Applications: \(games.count)")
for game in games {
    // `if case` pulls the associated value out of one enum case.
    if case .appStore(let adamID) = game.source {
        print("  \(game.name)  [\(game.id)]  apple:\(adamID)  ->  needs mapping")
    }
}
