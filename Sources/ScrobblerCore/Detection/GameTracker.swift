/// Something that happened to a process, as reported by the `ProcessMonitor`.
///
/// `pid` is the process id the system gives every running program.
/// `Int32` matches the C type `pid_t`.
public enum ProcessEvent: Sendable {
    case launched(pid: Int32, app: LaunchedApp)
    case terminated(pid: Int32)
    /// Every process alive right now, from the periodic poll. Catches games
    /// that run as bare executables, which app launch notifications miss.
    case snapshot([Int32: LaunchedApp])
}

/// What the rest of the app cares about: a game started or stopped.
public enum GameEvent: Equatable, Sendable {
    case started(DetectedGame)
    case stopped(DetectedGame)
}

/// Turns process events into game events.
///
/// One game can be several processes (a launcher, the game, a crash
/// reporter), so the tracker remembers which processes belong to which game:
/// a game *starts* with its first process and *stops* with its last.
///
/// An `actor` is a type that protects its own state: only one caller at a time
/// can run its methods, so two events arriving together can never corrupt
/// `processes` or `games`. Callers from outside must `await` each call,
/// because they may have to wait their turn.
public actor GameTracker {
    private let classifiers: [any GameClassifier]

    /// Which game each tracked process belongs to: pid -> game id.
    private var processes: [Int32: String] = [:]
    /// Running games and their live processes: game id -> (game, pids).
    /// A *tuple* groups values without declaring a type for them.
    private var games: [String: (game: DetectedGame, pids: Set<Int32>)] = [:]

    /// `any GameClassifier` is an *existential*: a box that can hold any type
    /// conforming to the protocol, so one array mixes App Store and Steam.
    public init(classifiers: [any GameClassifier]) {
        self.classifiers = classifiers
    }

    /// The games running right now, by name.
    public var runningGames: [DetectedGame] {
        games.values.map(\.game).sorted { $0.name < $1.name }
    }

    /// Handles one process event and returns the game events it causes,
    /// usually none or one.
    public func handle(_ event: ProcessEvent) -> [GameEvent] {
        switch event {
        case .launched(let pid, let app):
            return processStarted(pid: pid, app: app).map { [$0] } ?? []
        case .terminated(let pid):
            return processEnded(pid: pid).map { [$0] } ?? []
        case .snapshot(let alive):
            var events: [GameEvent] = []
            // Processes we track that are gone (a missed terminate).
            for pid in processes.keys where alive[pid] == nil {
                if let event = processEnded(pid: pid) { events.append(event) }
            }
            // Live processes we do not track yet (a missed or bare launch).
            for (pid, app) in alive where processes[pid] == nil {
                if let event = processStarted(pid: pid, app: app) { events.append(event) }
            }
            return events
        }
    }

    /// Returns `.started` only for the first process of a game.
    private func processStarted(pid: Int32, app: LaunchedApp) -> GameEvent? {
        guard processes[pid] == nil else { return nil }  // already tracked
        // `lazy` stops at the first classifier that recognises the app,
        // instead of asking every classifier and then picking one.
        guard let game = classifiers.lazy.compactMap({ $0.classify(app) }).first else {
            return nil
        }
        processes[pid] = game.id
        if games[game.id] != nil {
            games[game.id]?.pids.insert(pid)  // another process of a running game
            return nil
        }
        games[game.id] = (game, [pid])
        return .started(game)
    }

    /// Returns `.stopped` only when a game's last process ends.
    private func processEnded(pid: Int32) -> GameEvent? {
        // `removeValue` returns the removed value, or nil if there was none.
        guard let gameID = processes.removeValue(forKey: pid),
              var entry = games[gameID]
        else { return nil }
        entry.pids.remove(pid)
        if entry.pids.isEmpty {
            games[gameID] = nil
            return .stopped(entry.game)
        }
        games[gameID] = entry
        return nil
    }
}
