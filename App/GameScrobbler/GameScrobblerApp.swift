import SwiftUI

/// The app's entry point. `@main` marks the type whose `main()` starts the
/// program; for a SwiftUI `App`, that sets up AppKit and runs the event loop.
///
/// SwiftUI describes the app as nested values:
///
///     App  ->  Scene(s)  ->  View(s)
///
/// There are two scenes: a `MenuBarExtra` (an icon in the menu bar with a
/// menu) and `Settings`, the window ⌘, opens. The `LSUIElement` setting in
/// the Xcode project ("Application is agent") keeps the app out of the Dock.
@main
struct GameScrobblerApp: App {
    /// SwiftUI has no "the app is about to quit" hook, but AppKit does, on
    /// its *application delegate*. `@NSApplicationDelegateAdaptor` makes one
    /// `AppDelegate` for the app's whole life and hands it to AppKit.
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    /// The delegate owns the model, so the quit hook can reach it. Views
    /// still redraw when it changes: that comes from `@Observable`, not from
    /// where the model is stored.
    private var model: AppModel { appDelegate.model }

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

        // Both scenes get the same `model`, so they share one state.
        Settings {
            SettingsView(model: model)
        }
    }
}

/// Answers AppKit's questions about the app's life. An `NSObject` subclass,
/// because AppKit is an Objective-C framework and calls these methods by name.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// The longest a quit waits for the server. The journal already has the
    /// play's end by then, so the next launch sends whatever did not get out.
    private static let quitTimeout: Duration = .seconds(3)

    /// AppKit asks before quitting. `.terminateLater` means "not yet": the
    /// app keeps running until `reply(toApplicationShouldTerminate:)`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasOpenPlay else { return .terminateNow }

        // Two tasks race: the play's end reaching the server, and the
        // timeout. Whichever finishes first lets the app quit. Both run on
        // the main actor, one after the other, so `replied` needs no lock.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await model.endPlayForQuit()
            reply()
        }
        Task {
            try? await Task.sleep(for: Self.quitTimeout)
            reply()
        }
        return .terminateLater
    }
}
