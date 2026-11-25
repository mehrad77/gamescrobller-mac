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
    /// with `@Environment`. `openWindow` opens one of the app's windows by
    /// its `id`.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        account
        Divider()

        if !model.refusedGames.isEmpty {
            needsYourAnswer
            Divider()
        }

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
            Text(model.scrobbleLine)
            if model.serverStatus == .playsTurnedOff {
                Text("GameScrobbler isn’t taking plays right now; they are kept")
            }
            pauseControls
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
        Button("Games…") { model.showInSettings() }
        // Opens the window on the tab you last used, in the Dock and in
        // front of other windows.
        Button("Settings…") { model.showWindow() }
        .keyboardShortcut(",")
        // `.keyboardShortcut("q")` gives the item a ⌘Q shortcut.
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension MenuContent {
    /// "Pause Scrobbling" with how long, or "Resume Scrobbling" while
    /// paused. Only when scrobbling could run at all.
    @ViewBuilder
    private var pauseControls: some View {
        if model.isPaused {
            Button("Resume Scrobbling") { model.resume() }
        } else if model.canPause {
            Menu("Pause Scrobbling") {
                Button("For an Hour") { model.pause(.oneHour) }
                Button("Until Tomorrow") { model.pause(.untilTomorrow) }
                Button("Until I Resume") { model.pause(.untilResumed) }
            }
        }
    }

    /// Who is signed in, with the avatar, and the way to your Hub.
    @ViewBuilder
    private var account: some View {
        if let profile = model.profile {
            Button {
                model.openHub()
            } label: {
                // A `Label` in a menu item shows its image on the left.
                Label {
                    Text(profile.name)
                } icon: {
                    if let avatar = model.avatar {
                        Image(nsImage: avatar.circled(diameter: 18))
                    } else {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            Button("Open GameScrobbler Hub") { model.openHub() }
        } else {
            Button("Open GameScrobbler Hub") { model.openHub() }
        }
    }

    /// Each game whose plays the server refused, as a submenu with what you
    /// can do about it. `Menu` inside a menu becomes a submenu.
    private var needsYourAnswer: some View {
        Section("Needs your answer") {
            ForEach(model.refusedGames) { refused in
                let game = refused.game
                Menu {
                    Text("^[\(refused.playCount) play](inflect: true) waiting for your answer")
                    Divider()
                    if model.canAddToLibrary(game) {
                        Button("Add to My Library") { model.addToLibrary(game) }
                    }
                    Button("Show in Settings…") { model.showInSettings(game) }
                    Divider()
                    Button("Don’t Scrobble \(game.name)") { model.setIgnored(true, for: game) }
                } label: {
                    Text("\(game.name): \(model.status(of: game).title.lowercased())")
                }
            }
        }
        // Keeps the menu's copy of the "open window" action current too.
        .onAppear { model.openAppWindow = { openWindow(id: AppWindow.id) } }
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
