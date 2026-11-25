import ScrobblerCore
import UserNotifications

/// Posts "<game> isn't in your library" with two buttons, Add to Library and
/// Don't Scrobble. The menu offers the same, so all of it still works if you
/// never allow notifications.
///
/// `UserNotifications` is the framework for the banners in the corner and
/// Notification Center. A notification can carry *actions*: buttons that
/// call the app back (`AppDelegate` answers them) without opening a window.
@MainActor
final class Notifier {
    /// What the buttons send back.
    enum Action: String {
        case add = "add-to-library"
        case ignore = "dont-scrobble"
    }

    /// The `userInfo` key holding the game's id.
    nonisolated static let gameIDKey = "gameID"
    private static let category = "not-in-library"

    private var center: UNUserNotificationCenter { .current() }
    /// One notification per game and run.
    private var notified: Set<String> = []
    private var askedForPermission = false

    init() {
        // A *category* is a set of buttons; each notification names the one
        // it shows.
        let add = UNNotificationAction(identifier: Action.add.rawValue, title: "Add to Library")
        let ignore = UNNotificationAction(identifier: Action.ignore.rawValue, title: "Don’t Scrobble", options: .destructive)
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [add, ignore], intentIdentifiers: []),
        ])
    }

    func notifyNotInLibrary(_ game: DetectedGame) {
        guard notified.insert(game.id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(game.name) isn’t in your library"
        content.body = "GameScrobbler refused its play. Add it to your library to scrobble it; the play is kept until you decide."
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.gameIDKey: game.id]
        // The game id as the request id: a second one for the same game
        // replaces the first instead of stacking up.
        let request = UNNotificationRequest(identifier: "not-in-library-\(game.id)", content: content, trigger: nil)

        Task {
            // macOS asks you once; after that this answers at once.
            if !askedForPermission {
                askedForPermission = true
                _ = try? await center.requestAuthorization(options: [.alert])
            }
            try? await center.add(request)
        }
    }

    /// Takes the notification away once the game is dealt with elsewhere.
    func clear(_ game: DetectedGame) {
        center.removeDeliveredNotifications(withIdentifiers: ["not-in-library-\(game.id)"])
    }
}
