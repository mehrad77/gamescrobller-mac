import ScrobblerCore
import SwiftUI
import UserNotifications

/// The app's entry point. `@main` marks the type whose `main()` starts the
/// program; for a SwiftUI `App`, that sets up AppKit and runs the event loop.
///
/// SwiftUI describes the app as nested values:
///
///     App  ->  Scene(s)  ->  View(s)
///
/// There are two scenes: a `MenuBarExtra` (an icon in the menu bar with a
/// menu) and a `Window`, the app's one window, which ⌘, and "Settings…"
/// open. The `LSUIElement` setting in the Xcode project ("Application is
/// agent") keeps the app out of the Dock, except while the window is open
/// (`DockIcon`).
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

    /// The "Show in Menu Bar" setting, in General.
    @AppStorage(AppSettings.showsMenuBarIconKey) private var showsMenuBarIcon = true

    /// `some Scene` is an *opaque type*: "some specific type that conforms to
    /// Scene, which the compiler knows and I don't have to spell out".
    var body: some Scene {
        // `isInserted` adds or removes the icon as the setting changes.
        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            MenuContent(model: model)
        } label: {
            MenuBarIcon(model: model)
        }

        // Both scenes get the same `model`, so they share one state.
        //
        // A `Window`, not a `Settings` scene: a Settings window has a fixed
        // size, and this one is the whole app while the menu bar icon is
        // hidden. A `Window` is a single window (a `WindowGroup` could open
        // several), opened by its `id`.
        Window("GameScrobbler", id: AppWindow.id) {
            SettingsView(model: model)
        }
        .defaultSize(width: 660, height: 760)
        // Any size from the tabs' smallest one up (`settingsPane`).
        .windowResizability(.contentMinSize)
        .commands {
            // The app menu's "Settings…" (⌘,) opens this window.
            CommandGroup(replacing: .appSettings) {
                OpenWindowButton(model: model)
            }
        }
    }
}

/// The app's window.
enum AppWindow {
    static let id = "main"
}

/// "Settings…" in the app menu, with ⌘,. A view of its own, because only
/// a view can read the `openWindow` action.
private struct OpenWindowButton: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: AppWindow.id) }
            .keyboardShortcut(",")
            // The menu exists from launch, even with the menu bar icon
            // hidden, so it hands the model the action too.
            .onAppear { model.openAppWindow = { openWindow(id: AppWindow.id) } }
    }
}

/// The menu bar icon, the GameScrobbler tick: a ring when idle, a filled
/// disc while a game is running, and a ring with a dot while a game waits
/// for your answer. These are images from `Assets.xcassets`, drawn as
/// *templates*, so macOS colours them to match the menu bar.
///
/// It is on screen from launch (unless you hid it), so it also hands the
/// model SwiftUI's "open window" action: only a view can read it, and a
/// click on a notification needs it.
private struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(menuBarImage)
            .onAppear { model.openAppWindow = { openWindow(id: AppWindow.id) } }
    }

    private var menuBarImage: String {
        if !model.refusedGames.isEmpty { return "MenuBarAttention" }
        // Paused, a running game is not being scrobbled: the idle ring.
        if model.isPaused { return "MenuBarIdle" }
        return model.running.isEmpty ? "MenuBarIdle" : "MenuBarPlaying"
    }
}

/// Answers AppKit's questions about the app's life. An `NSObject` subclass,
/// because AppKit is an Objective-C framework and calls these methods by name.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private let dockIcon = DockIcon()

    /// Whether macOS opened the app at login, read while launching (see
    /// `applicationWillFinishLaunching`).
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The Apple event that opened the app says whether it was a login
        // item. It is only "current" while the app is starting up.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The notification center asks this object what to do with the
        // buttons on our notifications.
        UNUserNotificationCenter.current().delegate = self
        dockIcon.start()

        // With the menu bar icon hidden, opening the app shows the window,
        // or nothing would show it opened. Not at login: then it starts
        // quietly, as with the icon.
        let showsIcon = UserDefaults.standard.object(forKey: AppSettings.showsMenuBarIconKey) as? Bool ?? true
        if !showsIcon, !launchedAtLogin {
            // A `Task` runs after launch finishes, once SwiftUI has set up
            // the app menu that `showWindow` may use.
            Task { model.showWindow(.nowPlaying) }
        }
    }

    /// The app was opened again while running (from Finder, Spotlight, or
    /// the Dock): show the window, the way any Mac app does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            model.showWindow(.nowPlaying)
        }
        return true
    }

    // MARK: - Notifications

    /// A button on a notification was clicked, or the notification itself.
    ///
    /// The system calls this from its own thread, so it is `nonisolated`:
    /// not tied to the main actor like the rest of this class. It takes the
    /// two strings it needs out of `response` (which may not cross threads),
    /// then `await`s its way back onto the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let gameID = response.notification.request.content.userInfo[Notifier.gameIDKey] as? String
        await notificationClicked(action: action, gameID: gameID)
    }

    /// Without this, a notification that arrives while the app is the
    /// active one is never shown.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    private func notificationClicked(action: String, gameID: String?) {
        guard let gameID, let game = model.allGames.first(where: { $0.id == gameID }) else { return }
        switch Notifier.Action(rawValue: action) {
        case .add?:
            model.addToLibrary(game)
        case .ignore?:
            model.setIgnored(true, for: game)
        case nil:
            // The notification itself: show the game in Settings.
            model.showInSettings(game)
        }
    }

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
