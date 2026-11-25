import AppKit  // NSWorkspace
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

    /// What the one scrobbling loop works through, strictly in order.
    private enum ScrobbleInput {
        case event(ScrobbleEvent)
        /// Finish with the current scrobbler and start afresh: the token, or
        /// the on/off switch, changed.
        case rebuild
        /// The app is quitting: end the open play, then call `done`.
        case quit(at: Date, done: CheckedContinuation<Void, Never>)
        /// Add the game to your library, then send its refused plays.
        case addToLibrary(DetectedGame)
    }

    /// Where asking the server to add a game to your library stands.
    enum LibraryRequest: Equatable {
        case adding
        case failed(String)
    }

    private(set) var running: [RunningGame] = []
    private(set) var installed: [DetectedGame] = []
    /// Whether a token is in the Keychain. The token itself never lives here.
    private(set) var hasToken = false
    private(set) var connection: Connection = .notChecked
    private(set) var scrobblingEnabled = AppSettings.scrobblingEnabled
    /// nil until a scrobbler exists (scrobbling off, no token, or no game
    /// started since launch).
    private(set) var scrobbleStatus: ScrobbleStatus?
    private(set) var lastScrobble: GSSession?
    /// Plays saved in the journal and not yet sent.
    private(set) var unsentCount = 0
    /// Which games you scrobble, and what the server said about each one.
    /// Saved per server, next to the journal.
    private(set) var records = GameRecords()
    /// Games whose plays the server refused on this run.
    private(set) var refusedGames: [RefusedGame] = []
    /// Games being added to the library, or that could not be.
    private(set) var libraryRequests: [String: LibraryRequest] = [:]
    /// Games added to the library on this run. If the server still refuses
    /// one, asking "Add it?" again would go round in circles.
    private(set) var addedThisRun: Set<String> = []
    /// The game selected in Settings, so the menu can open it there.
    var selectedGameID: String?
    /// Opens the Settings window; set by the menu bar icon (see
    /// `MenuBarIcon`).
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    // Not part of the UI state, so they need not be observed.
    @ObservationIgnored private let monitor = ProcessMonitor()
    @ObservationIgnored private let tokenStore = KeychainTokenStore()
    @ObservationIgnored private let scrobbleInput: AsyncStream<ScrobbleInput>.Continuation
    @ObservationIgnored private var scrobbler: Scrobbler?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The sleep and wake observers. The model lives as long as the app, so
    /// they are never removed; keeping them says what they are.
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored let notifier = Notifier()

    init() {
        // The queue every scrobbling input goes through. Set first: Swift
        // requires every stored property to have a value before `self` is
        // used, and the tasks below use it.
        let (inputs, continuation) = AsyncStream.makeStream(of: ScrobbleInput.self)
        scrobbleInput = continuation

        // `try?` turns a thrown error into nil; `?? false` then treats an
        // unreadable Keychain like "no token".
        hasToken = (try? tokenStore.hasToken()) ?? false

        let appStore = AppStoreClassifier()
        let steam = SteamClassifier()
        installed = InstalledGames.scan(appStore: appStore, steam: steam)

        records = Self.loadRecords()

        let tracker = GameTracker(classifiers: [appStore, steam])
        // Watch processes and turn them into game events. `[weak self]` so
        // these long-running tasks do not keep the model alive on their own.
        tasks.append(Task { [weak self, monitor] in
            for await processEvent in monitor.events() {
                for gameEvent in await tracker.handle(processEvent) {
                    self?.apply(gameEvent)
                }
            }
        })
        // The one loop that talks to the scrobbler: it handles each input to
        // the end before taking the next, so a "stopped" can never overtake
        // the "start" request still waiting for the server.
        tasks.append(Task { [weak self] in
            for await input in inputs {
                await self?.process(input)
            }
        })
        // A tick now, so plays left from the last run go out at launch, then
        // one a minute, so heartbeats and retries go out on time.
        scrobbleInput.yield(.event(.tick(.now)))
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.scrobbleInput.yield(.event(.tick(.now)))
            }
        })
        watchSleep()
        // Check the token and look the games up in your library: reads only,
        // once per launch.
        if hasToken { checkConnection() }
    }

    // MARK: - Sleep

    /// The Mac sleeping and waking. Only the whole Mac counts: the display
    /// sleeping, or the screen locking, leaves the game's play going.
    ///
    /// These notifications come from `NSWorkspace.shared.notificationCenter`,
    /// AppKit's own notification center, not `NotificationCenter.default`.
    /// The time is taken when the notification arrives, so the play ends at
    /// the sleep even if the scrobbler gets to the event after the wake.
    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        // A local copy: the closures must be `@Sendable`, so they may not
        // reach into this main-actor object, only into the (Sendable)
        // continuation.
        let input = scrobbleInput
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                input.yield(.event(.sleep(at: .now)))
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                input.yield(.event(.wake(at: .now)))
            },
        ]
    }

    // MARK: - Games

    private func apply(_ event: GameEvent) {
        // The time is taken now, when the game started or stopped, not later
        // when the scrobbler gets to the event.
        let now = Date.now
        switch event {
        case .started(let game):
            running.append(RunningGame(game: game, startedAt: now))
            scrobbleInput.yield(.event(.started(game, at: now)))
        case .stopped(let game):
            // `removeAll(where:)` deletes every element the closure matches.
            running.removeAll { $0.game.id == game.id }
            scrobbleInput.yield(.event(.stopped(game, at: now)))
        }
    }

    // MARK: - Scrobbling

    func setScrobblingEnabled(_ enabled: Bool) {
        guard enabled != scrobblingEnabled else { return }
        scrobblingEnabled = enabled
        AppSettings.scrobblingEnabled = enabled
        scrobbleInput.yield(.rebuild)
    }

    private func process(_ input: ScrobbleInput) async {
        switch input {
        case .event(let event):
            // A scrobbler is made when a game starts, or on a tick when the
            // journal holds plays to send. Otherwise the Keychain is not read.
            switch event {
            case .stopped, .stopAll, .sleep, .wake, .ignoredGamesChanged, .addedToLibrary:
                if scrobbler == nil { return }
            case .tick:
                if scrobbler == nil, !journalHasPlays() { return }
            case .started:
                break
            }
            guard let scrobbler = makeScrobblerIfNeeded() else { return }
            await scrobbler.handle(event)
            await showState(of: scrobbler)

        case .rebuild:
            if let old = scrobbler {
                await old.handle(.stopAll(at: .now))
                await showState(of: old)
            }
            scrobbler = nil
            scrobbleStatus = nil
            refusedGames = []
            // The server may have changed with the token, and the records
            // are kept per server.
            records = Self.loadRecords()
            // The next scrobbler hears about the games already running. These
            // go to the back of the queue, after anything already waiting.
            for game in running {
                scrobbleInput.yield(.event(.started(game.game, at: .now)))
            }

        case .quit(let time, let done):
            if let scrobbler {
                await scrobbler.handle(.stopAll(at: time))
            }
            done.resume()

        case .addToLibrary(let game):
            await addToLibraryNow(game)
        }
    }

    /// Whether quitting has a play to end first.
    var hasOpenPlay: Bool {
        scrobbler != nil && !running.isEmpty
    }

    /// Ends the open play, for a quit. It goes through the same queue as
    /// every other input, so it runs after whatever is already waiting.
    ///
    /// When the loop gets to it, the journal gets the play's end before the
    /// finish goes out, so if the app is gone before the server answers, the
    /// next launch sends it. If a request already in flight holds the loop
    /// past the quit timeout, the end is never written, and the next launch
    /// ends the play where it was last seen (up to a minute short).
    ///
    /// `withCheckedContinuation` turns "call me back when done" into
    /// something to `await`: the loop calls `done.resume()`, and this
    /// function returns then. The time is taken now, at the quit.
    func endPlayForQuit() async {
        let time = Date.now
        await withCheckedContinuation { done in
            scrobbleInput.yield(.quit(at: time, done: done))
        }
    }

    private func makeScrobblerIfNeeded() -> Scrobbler? {
        if let scrobbler { return scrobbler }
        guard scrobblingEnabled, hasToken,
              let baseURL = AppSettings.baseURL,
              let journal = AppSettings.journal(for: baseURL),
              let token = try? tokenStore.token()
        else { return nil }
        let new = Scrobbler(
            api: GSClient(baseURL: baseURL, token: token),
            deviceID: AppSettings.deviceID,
            journal: journal,
            ignoredGames: records.ignoredGames
        )
        scrobbler = new
        return new
    }

    /// Whether the current server's journal holds plays. Read from the file
    /// on every tick while there is no scrobbler: it is small.
    private func journalHasPlays() -> Bool {
        guard scrobblingEnabled, hasToken,
              let baseURL = AppSettings.baseURL,
              let journal = AppSettings.journal(for: baseURL)
        else { return false }
        // `try?` makes a damaged file read as nil, so it waits for the next
        // game start, whose scrobbler sets it aside.
        let plays = (try? journal.load()) ?? []
        unsentCount = plays.count
        return !plays.isEmpty
    }

    /// Copies the scrobbler's state into properties the menu can observe.
    /// Each `await` hops to the scrobbler actor to read it.
    private func showState(of scrobbler: Scrobbler) async {
        scrobbleStatus = await scrobbler.status
        unsentCount = await scrobbler.unsentCount
        if let finished = await scrobbler.lastFinished {
            lastScrobble = finished
        }
        refusedGames = await scrobbler.refusedGames
        remember(await scrobbler.recognized)
        notifyAboutRefusedGames()
    }

    // MARK: - Games and your library

    /// Every game the app knows of: installed, running, or with plays
    /// waiting, by name.
    var allGames: [DetectedGame] {
        var byID: [String: DetectedGame] = [:]
        for game in installed + running.map(\.game) + refusedGames.map(\.game) {
            byID[game.id] = game
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What the Games tab and the menu say about a game, most urgent first.
    func status(of game: DetectedGame) -> GameStatus {
        let record = records[game.id]
        if record.ignored { return .ignored }
        switch libraryRequests[game.id] {
        case .adding?: return .adding
        case .failed(let message)?: return .addFailed(message)
        case nil: break
        }
        if let refused = refusedGames.first(where: { $0.game.id == game.id }) {
            if !refused.isNotInLibrary { return .refused(refused.error.summary) }
            if addedThisRun.contains(game.id) { return .stillRefused }
            if record.lookup == .unknownGame { return .unknownGame }
            return .notInLibrary(plays: refused.playCount)
        }
        switch record.lookup {
        case .unknownGame?: return .unknownGame
        case .notInLibrary?: return .notOwned
        case .inLibrary(let title, _)?: return .inLibrary(title: title)
        case nil: return .notChecked
        }
    }

    /// The game's page on the GameScrobbler website, when the server told
    /// us its slug.
    func pageURL(of game: DetectedGame) -> URL? {
        guard case .inLibrary(_, let slug?)? = records[game.id].lookup,
              let site = AppSettings.baseURL.flatMap(AppSettings.website(for:)) else { return nil }
        return site.appending(path: "games").appending(path: slug)
    }

    /// Opens Settings on the Games tab, with `game` selected.
    func showInSettings(_ game: DetectedGame? = nil) {
        if let game { selectedGameID = game.id }
        UserDefaults.standard.set(SettingsTab.games.rawValue, forKey: AppSettings.settingsTabKey)
        // A menu bar app is never the active app on its own, so the window
        // would open behind other windows without this.
        NSApplication.shared.activate()
        openSettingsWindow?()
    }

    /// Whether the menu and the notification may offer "Add to Library".
    func canAddToLibrary(_ game: DetectedGame) -> Bool {
        switch status(of: game) {
        // After "unknown game" too: a 404 can also mean scrobbling is off on
        // the server, or a catalogue that has the game since, so asking
        // again must stay possible.
        case .notInLibrary, .notOwned, .notChecked, .addFailed, .unknownGame: true
        default: false
        }
    }

    /// Asks the server to add the game to your library. The request goes through the scrobbling queue, so it never
    /// overlaps a play being sent.
    func addToLibrary(_ game: DetectedGame) {
        guard libraryRequests[game.id] != .adding else { return }
        libraryRequests[game.id] = .adding
        scrobbleInput.yield(.addToLibrary(game))
    }

    /// Turns scrobbling of one game off or on, and tells the scrobbler.
    func setIgnored(_ ignored: Bool, for game: DetectedGame) {
        guard records[game.id].ignored != ignored else { return }
        if ignored { notifier.clear(game) }
        records[game.id].ignored = ignored
        saveRecords()
        scrobbleInput.yield(.event(.ignoredGamesChanged(records.ignoredGames, at: .now)))
    }

    /// Runs inside the scrobbling loop.
    private func addToLibraryNow(_ game: DetectedGame) async {
        guard let client = makeClient() else {
            libraryRequests[game.id] = .failed("Add a token in Settings first.")
            return
        }
        let ref = game.defaultRef
        let outcome = await client.addToLibrary(ref)

        var new = records
        switch outcome {
        case .added(let entry):
            new[game.id].lookup = .inLibrary(title: entry.title, slug: entry.slug)
        case .alreadyInLibrary:
            // Already there: a read gives its title and slug.
            if case .inLibrary(let item) = await client.lookUp(ref) {
                new[game.id].lookup = .inLibrary(title: item.title, slug: item.slug)
            } else {
                new[game.id].lookup = .inLibrary(title: nil)
            }
        case .unknownGame:
            new[game.id].lookup = .unknownGame
        case .failed(let error):
            libraryRequests[game.id] = .failed(error.summary)
            return
        }
        libraryRequests[game.id] = nil
        records = new
        saveRecords()
        notifier.clear(game)

        guard new[game.id].lookup != .unknownGame else { return }
        addedThisRun.insert(game.id)
        if let scrobbler {
            await scrobbler.handle(.addedToLibrary(gameID: game.id, at: .now))
            await showState(of: scrobbler)
        }
    }

    /// Looks every game up in your library (`GET /me/library/{game}`, a
    /// read), so the Games tab knows before the first play which ones would
    /// be refused. One request per game, once per connection check.
    private func lookUpGames(with client: GSClient) async {
        for game in allGames where !records[game.id].ignored {
            let outcome = await client.lookUp(game.defaultRef)
            var new = records
            switch outcome {
            case .inLibrary(let item):
                new[game.id].lookup = .inLibrary(title: item.title, slug: item.slug)
            case .notInLibrary:
                // A game known to be missing from the catalogue stays so.
                if new[game.id].lookup != .unknownGame { new[game.id].lookup = .notInLibrary }
            case .failed:
                continue
            }
            if new != records {
                records = new
                saveRecords()
            }
        }
    }

    /// Notes what the server called each game it took a session for.
    private func remember(_ recognized: [String: RecognizedGame]) {
        var new = records
        for (id, game) in recognized {
            // Keep a slug learned before if the session did not carry one.
            var slug = game.slug
            if slug == nil, case .inLibrary(_, let known)? = new[id].lookup { slug = known }
            new[id].lookup = .inLibrary(title: game.title, slug: slug)
        }
        guard new != records else { return }
        records = new
        saveRecords()
    }

    /// One notification per game and run, for a game newly refused as not in
    /// your library.
    private func notifyAboutRefusedGames() {
        for refused in refusedGames where status(of: refused.game) == .notInLibrary(plays: refused.playCount) {
            notifier.notifyNotInLibrary(refused.game)
        }
    }

    private static func loadRecords() -> GameRecords {
        guard let baseURL = AppSettings.baseURL, let store = AppSettings.recordStore(for: baseURL)
        else { return GameRecords() }
        return store.load()
    }

    private func saveRecords() {
        guard let baseURL = AppSettings.baseURL, let store = AppSettings.recordStore(for: baseURL) else { return }
        try? store.save(records)
    }

    /// A client with the saved token, for calls outside the scrobbler.
    private func makeClient() -> GSClient? {
        guard hasToken, let baseURL = AppSettings.baseURL, let token = try? tokenStore.token()
        else { return nil }
        return GSClient(baseURL: baseURL, token: token)
    }

    // MARK: - Settings

    /// Saves a pasted token to the Keychain, then checks it against the server.
    func saveToken(_ text: String) {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try tokenStore.save(token)
            hasToken = true
            scrobbleInput.yield(.rebuild)
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
            scrobbleInput.yield(.rebuild)
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
                let profile = try await client.me()
                connection = .connected(profile)
                await lookUpGames(with: client)
            } catch {
                connection = .failed(error.summary)
            }
        }
    }
}
