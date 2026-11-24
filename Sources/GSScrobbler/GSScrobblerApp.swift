import AppKit
import SwiftUI

/// The app's entry point. `@main` marks the type whose `main()` starts the
/// program; for a SwiftUI `App`, that sets up AppKit and runs the event loop.
///
/// SwiftUI describes the app as nested values:
///
///     App  ->  Scene(s)  ->  View(s)
///
/// Here the only scene is a `MenuBarExtra`: an icon in the menu bar with a
/// menu. There is no window, so nothing appears in the Dock either.
@main
struct GSScrobblerApp: App {
    /// `@State` makes SwiftUI own this object for the app's whole life: it is
    /// created once, and SwiftUI keeps it while it re-evaluates `body`.
    @State private var model = AppModel()

    init() {
        // An app normally gets a Dock icon. "Accessory" apps live only in the
        // menu bar. Step 7's Info.plist (LSUIElement) will make this permanent;
        // until then we set it in code so `swift run` behaves the same.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// `some Scene` is an *opaque type*: "some specific type that conforms to
    /// Scene, which the compiler knows and I don't have to spell out".
    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // The menu bar icon: filled while a game is running.
            // `systemImage` names an SF Symbol, Apple's built-in icon set.
            Image(systemName: model.running.isEmpty ? "gamecontroller" : "gamecontroller.fill")
        }
    }
}
