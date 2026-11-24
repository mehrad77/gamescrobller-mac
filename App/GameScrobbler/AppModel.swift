import Foundation
import Observation
import ScrobblerCore

/// The app's state, shared by every view.
///
/// `@Observable` (the Observation framework, macOS 14+) watches which
/// properties each view reads while drawing. When one of them changes,
/// only those views are redrawn. No manual "notify the UI" calls.
///
/// `@MainActor`: SwiftUI reads this from the main thread, so every change to
/// it must happen there too. The compiler enforces that.
@MainActor
@Observable
final class AppModel {
    /// A game that is running now, and since when.
    struct RunningGame: Identifiable {
        let game: DetectedGame
        let startedAt: Date
        var id: String { game.id }
    }

    /// What the Settings window shows about the server.
    enum Connection {
        case notChecked
        case checking
        case connected(GSProfile)
        case failed(String)
    }

    private(set) var running: [RunningGame] = []
    private(set) var installed: [DetectedGame] = []
    /// Whether a token is in the Keychain. The token itself never lives here.
    private(set) var hasToken = false
    private(set) var connection: Connection = .notChecked

    // Not part of the UI state, so they need not be observed.
    @ObservationIgnored private let monitor = ProcessMonitor()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private let tokenStore = KeychainTokenStore()

    init() {
        // `try?` turns a thrown error into nil; `?? false` then treats an
        // unreadable Keychain like "no token".
        hasToken = (try? tokenStore.hasToken()) ?? false

        let appStore = AppStoreClassifier()
        let steam = SteamClassifier()
        installed = InstalledGames.scan(appStore: appStore, steam: steam)

        let tracker = GameTracker(classifiers: [appStore, steam])
        // Start watching right away. `[weak self]` so this long-running task
        // does not keep the model alive forever on its own.
        watchTask = Task { [weak self, monitor] in
            for await processEvent in monitor.events() {
                for gameEvent in await tracker.handle(processEvent) {
                    self?.apply(gameEvent)
                }
            }
        }
    }

    // MARK: - Settings

    /// Saves a pasted token to the Keychain, then checks it against the server.
    func saveToken(_ text: String) {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try tokenStore.save(token)
            hasToken = true
            checkConnection()
        } catch {
            connection = .failed("Could not save the token: \(error)")
        }
    }

    func removeToken() {
        do {
            try tokenStore.delete()
            hasToken = false
            connection = .notChecked
        } catch {
            connection = .failed("Could not remove the token: \(error)")
        }
    }

    /// Calls `GET /me` with the saved token and shows who it belongs to.
    func checkConnection() {
        guard let baseURL = AppSettings.baseURL else {
            connection = .failed("The server address is not a valid http or https URL.")
            return
        }
        let token: String
        do {
            guard let saved = try tokenStore.token() else {
                connection = .failed("No token saved.")
                return
            }
            token = saved
        } catch {
            connection = .failed("Could not read the token: \(error)")
            return
        }

        connection = .checking
        let client = GSClient(baseURL: baseURL, token: token)
        // This `Task` runs on the main actor, like the rest of the model, but
        // `await` lets the main thread do other work while the request is out.
        Task {
            // `do throws(GSClientError)` states the error type, so `error` in
            // `catch` is a `GSClientError` and has `summary`. Without it, a
            // `do` inside a closure gives a plain `any Error`.
            do throws(GSClientError) {
                connection = .connected(try await client.me())
            } catch {
                connection = .failed(error.summary)
            }
        }
    }

    private func apply(_ event: GameEvent) {
        switch event {
        case .started(let game):
            running.append(RunningGame(game: game, startedAt: .now))
        case .stopped(let game):
            // `removeAll(where:)` deletes every element the closure matches.
            running.removeAll { $0.game.id == game.id }
        }
    }
}
