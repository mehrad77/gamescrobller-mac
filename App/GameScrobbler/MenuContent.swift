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
            Text(scrobbleLine)
            if model.unsentCount > 0 {
                // `^[…](inflect: true)` is *automatic grammar agreement*:
                // Foundation writes "1 play" or "2 plays" to match the number.
                Text("^[\(model.unsentCount) play](inflect: true) saved, waiting to be sent")
            }
            if let last = model.lastScrobble {
                Text("Last scrobbled: \(last.gameTitle), \(last.durationSeconds / 60) min")
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

extension MenuContent {
    /// One line about scrobbling. `scrobbleStatus` is optional, so the
    /// `switch` uses *optional patterns*: `.idle?` matches "a value that is
    /// `.idle`", and `nil` matches "no value".
    private var scrobbleLine: String {
        if !model.scrobblingEnabled { return "Scrobbling is off (turn it on in Settings)" }
        if !model.hasToken { return "Add a token in Settings to scrobble" }
        switch model.scrobbleStatus {
        case nil, .idle?:
            return "Ready to scrobble"
        case .scrobbling(let game, _)?:
            return "Scrobbling \(game.name)"
        case .waiting(let until, let error)?:
            return "Trying again at \(until.formatted(date: .omitted, time: .shortened)). \(error.summary)"
        case .failed(let game, let error)?:
            return "Not scrobbled: \(game.name). Kept for the next launch. \(error.summary)"
        case .signedOut(let error)?:
            return "Stopped scrobbling. \(error.summary)"
        }
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
