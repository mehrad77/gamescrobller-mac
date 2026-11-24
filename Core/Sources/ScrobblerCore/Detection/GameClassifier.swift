import Foundation

/// What the detector knows about a process that just started.
///
/// App bundles have both URLs; a bare executable (some Steam games) has only
/// `executableURL`. Optionals model "may be missing" in the type itself.
public struct LaunchedApp: Hashable, Sendable {
    public let bundleURL: URL?
    public let executableURL: URL?

    public init(bundleURL: URL?, executableURL: URL?) {
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }
}

/// Anything that can tell whether a launched app is a game it knows about.
///
/// A *protocol* is a contract: a list of requirements a type promises to meet.
/// The detector will hold a list of `any GameClassifier` and ask each in turn,
/// without knowing or caring whether it is the App Store one or the Steam one.
/// That is how Swift prefers composition over inheritance: small types that
/// each conform to a protocol, instead of a base class with subclasses.
public protocol GameClassifier: Sendable {
    func classify(_ app: LaunchedApp) -> DetectedGame?
}

/// *Retroactive conformance*: `AppStoreClassifier` was written without knowing
/// about this protocol, and an extension adds the conformance afterwards.
extension AppStoreClassifier: GameClassifier {
    public func classify(_ app: LaunchedApp) -> DetectedGame? {
        guard let bundleURL = app.bundleURL else { return nil }
        return classify(appURL: bundleURL)
    }
}
