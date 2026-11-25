import AppKit

/// Shows the app in the Dock and the app switcher (⌘⇥) while one of its
/// windows is open, and hides it again once the last one closes.
///
/// The app starts as an *agent* (`LSUIElement` in the Xcode project): no
/// Dock icon, only the menu bar icon. `NSApplication.setActivationPolicy`
/// changes that while it runs: `.regular` is a normal app with a Dock icon
/// and a menu bar, `.accessory` is the agent again.
@MainActor
final class DockIcon {
    private var observers: [NSObjectProtocol] = []

    /// Starts watching windows open and close.
    func start() {
        let center = NotificationCenter.default
        // A window becoming key is a window being opened or brought back.
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
        // While it closes, the window still counts as visible, so look again
        // once it is gone: a `Task` runs after this notification is handled.
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
    }

    /// Puts the app in the Dock now, before a window opens. Opening one from
    /// the menu calls this; `update` takes it out again once it closes.
    static func show() {
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    private func update() {
        // `canBecomeMain` leaves out the menu bar icon's own window and
        // the menu, which never count as an open window.
        let windowOpen = NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = windowOpen ? .regular : .accessory
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
        // Turning into a regular app can leave the window behind others.
        if windowOpen {
            NSApplication.shared.activate()
        }
    }
}
