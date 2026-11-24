// swift-tools-version: 6.0
// The line above is not a comment to delete: SwiftPM reads it to know which
// manifest format this file uses.

import PackageDescription

let package = Package(
    name: "GameScrobblerMac",
    // The oldest macOS the app runs on. MenuBarExtra and SMAppService need 13+;
    // the Observation framework (@Observable) needs 14.
    platforms: [.macOS(.v14)],
    targets: [
        // All the logic: game detection, the API client, the scrobbler.
        // A library, so tests can import it without starting any UI.
        .target(name: "ScrobblerCore"),

        // The menu bar app itself: a thin SwiftUI layer over ScrobblerCore.
        .executableTarget(
            name: "GSScrobbler",
            dependencies: ["ScrobblerCore"]
        ),

        // A command-line debug tool: lists installed games, or prints games
        // as they start and stop (`swift run gs-detect --watch`).
        .executableTarget(
            name: "gs-detect",
            dependencies: ["ScrobblerCore"]
        ),

        // Tests for ScrobblerCore, written with Swift Testing (`import Testing`).
        .testTarget(
            name: "ScrobblerCoreTests",
            dependencies: ["ScrobblerCore"]
        ),
    ]
)
