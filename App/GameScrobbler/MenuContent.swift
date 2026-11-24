import SwiftUI
import ScrobblerCore

/// What the menu shows. A SwiftUI *view* is a struct with a `body` that
/// describes the UI for the current state; SwiftUI calls `body` again whenever
/// that state changes, and works out what to update on screen.
///
/// With the default menu style, SwiftUI turns these views into real menu
/// items: `Text` is a disabled item, `Button` a clickable one, `Divider` a
/// separator, `Section` a group with a header.
struct MenuContent: View {
    /// A plain `let`: the view only reads the model. `@Observable` still
    /// redraws it when `running` or `installed` change.
    let model: AppModel

    /// An *environment value*: something SwiftUI provides to every view, read
    /// with `@Environment`. `openSettings` is an action that opens the
    /// app's Settings window.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Section("Now playing") {
            if model.running.isEmpty {
                Text("Nothing right now")
            } else {
                // `ForEach` repeats a view for each element; it needs
                // `Identifiable` elements so it can tell them apart.
                ForEach(model.running) { running in
                    // `formatted(date:time:)` writes the time in the user's
                    // locale and 12/24-hour setting, such as "18:05".
                    Text("\(running.game.name), since \(running.startedAt.formatted(date: .omitted, time: .shortened))")
                }
            }
        }

        Divider()

        Section("Installed games") {
            ForEach(model.installed) { game in
                Text("\(game.name)  (\(game.sourceLabel))")
            }
        }

        Divider()

        Text("GameScrobbler for Mac \(ScrobblerCore.version)")
        Button("Settings…") {
            // A menu bar app is never the active app on its own, so the
            // Settings window would open behind other windows without this.
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        // `.keyboardShortcut("q")` gives the item a ⌘Q shortcut.
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// A small *extension* only the app needs, so it lives here, not in the core.
extension DetectedGame {
    var sourceLabel: String {
        switch source {
        case .appStore: "App Store"
        case .steam: "Steam"
        }
    }
}
