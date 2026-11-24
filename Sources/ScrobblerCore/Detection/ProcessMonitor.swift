import AppKit  // NSWorkspace, NSRunningApplication
import Darwin  // proc_listallpids, proc_pidpath (the C process API)

/// Watches processes start and stop, and reports them as an `AsyncStream`.
///
/// Two sources feed the same stream:
/// - `NSWorkspace` notifications, instant, for anything with an app bundle;
/// - a poll every `pollInterval`, which lists every process. It catches bare
///   executables (some Steam games) and any notification that was missed.
///
/// `@MainActor` pins the whole class to the main thread, where AppKit expects
/// to be used. That also makes it safe to share: a main-actor class is
/// `Sendable`, because only one thread ever touches it.
@MainActor
public final class ProcessMonitor {
    private let pollInterval: Duration
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    /// `Duration` is Swift's type for a length of time: `.seconds(30)`.
    public init(pollInterval: Duration = .seconds(30)) {
        self.pollInterval = pollInterval
    }

    /// Starts watching. Events arrive in order, beginning with one `.launched`
    /// per app already running.
    ///
    /// An `AsyncStream` is a sequence whose elements arrive over time; the
    /// consumer reads it with `for await event in stream { … }`. We push into
    /// it through its *continuation*.
    public func events() -> AsyncStream<ProcessEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)

        // Apps already running when we start.
        for app in NSWorkspace.shared.runningApplications {
            continuation.yield(.launched(pid: app.processIdentifier, app: LaunchedApp(app)))
        }

        let center = NSWorkspace.shared.notificationCenter
        // `queue: .main` delivers on the main thread. The closure must be
        // `@Sendable`, so it only touches the continuation (which is Sendable)
        // and values it builds itself.
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            continuation.yield(.launched(pid: app.processIdentifier, app: LaunchedApp(app)))
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            continuation.yield(.terminated(pid: app.processIdentifier))
        })

        // A `Task` runs work concurrently. This one loops until cancelled.
        // `[pollInterval]` is a *capture list*: the closure keeps a copy of
        // the value instead of reaching back into `self`.
        pollTask = Task { [pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                continuation.yield(.snapshot(Self.allProcesses()))
            }
        }

        // Runs when the consumer stops reading. The hop back onto the main
        // actor is needed because `stop()` is main-actor isolated.
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        return stream
    }

    public func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        pollTask?.cancel()
        pollTask = nil
    }

    /// Every process on the system that we may read, with its executable path.
    ///
    /// `nonisolated` lets this run off the main actor: it only calls C
    /// functions and touches no stored state.
    nonisolated static func allProcesses() -> [Int32: LaunchedApp] {
        // C APIs often take a buffer to fill. First ask how many pids exist,
        // then allocate a little extra room in case more start meanwhile.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        // `&pids` passes a pointer to the array's storage to C.
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [:] }

        var result: [Int32: LaunchedApp] = [:]
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)  // PROC_PIDPATHINFO_MAXSIZE
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }  // gone already, or not ours to read
            // Turn the C bytes (not NUL-terminated past `length`) into a String.
            let bytes = pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            result[pid] = LaunchedApp(bundleURL: nil, executableURL: URL(filePath: path))
        }
        return result
    }
}

extension LaunchedApp {
    /// A *convenience initializer* added in an extension, so the model stays
    /// free of AppKit everywhere else.
    init(_ app: NSRunningApplication) {
        self.init(bundleURL: app.bundleURL, executableURL: app.executableURL)
    }
}
