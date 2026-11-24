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

    private(set) var running: [RunningGame] = []
    private(set) var installed: [DetectedGame] = []

    // Not part of the UI state, so they need not be observed.
    @ObservationIgnored private let monitor = ProcessMonitor()
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init() {
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
