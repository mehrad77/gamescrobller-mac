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

    var body: some View {
        Section("Now playing") {
            if model.running.isEmpty {
                Text("Nothing right now")
            } else {
                // `ForEach` repeats a view for each element; it needs
                // `Identifiable` elements so it can tell them apart.
                ForEach(model.running) { running in
                    // `Text(_:format:)` formats the date for the user's locale.
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
