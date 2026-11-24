import CoreServices  // Spotlight's C API (MDItem…)
import Foundation    // URL, FileManager, Bundle, NSNumber

/// Recognises Mac App Store and Apple Arcade games from their app bundle.
///
/// An app bundle (`Mini Motorways.app`) is a folder that Finder shows as one
/// file. Everything we need is inside it, or known to Spotlight:
///
///     Mini Motorways.app/
///       Contents/
///         Info.plist            <- bundle id, name, App Store category
///         _MASReceipt/receipt   <- only present for App Store installs
///         MacOS/…               <- the executable
///
/// It is a `struct` with no stored state except the lookup function, so it is
/// cheap to create and trivially `Sendable`.
public struct AppStoreClassifier: Sendable {
    /// Looks up an app's App Store ("Adam") id. A *function type* stored as a
    /// property: production code uses Spotlight, tests pass a fake that returns
    /// a fixed number. This is dependency injection without a protocol.
    ///
    /// `@Sendable` marks the closure as safe to call from any thread.
    public typealias AdamIDLookup = @Sendable (URL) -> Int?

    private let lookUpAdamID: AdamIDLookup

    /// `= AppStoreClassifier.spotlightAdamID` is a *default argument*: callers
    /// may leave it out, and tests replace it.
    public init(lookUpAdamID: @escaping AdamIDLookup = AppStoreClassifier.spotlightAdamID) {
        self.lookUpAdamID = lookUpAdamID
    }

    /// Returns a `DetectedGame` when the bundle at `appURL` is an App Store
    /// game, and `nil` for anything else (a non-game, a non-App-Store app, a
    /// folder that is not a bundle).
    public func classify(appURL: URL) -> DetectedGame? {
        // `Bundle(url:)` reads Info.plist for us. It is failable: not a bundle -> nil.
        guard let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier
        else { return nil }

        // 1. Installed from the App Store? Only those carry a receipt.
        let receipt = appURL.appending(path: "Contents/_MASReceipt/receipt")
        guard FileManager.default.fileExists(atPath: receipt.path(percentEncoded: false)) else {
            return nil
        }

        // 2. Is it a game? Apple's game categories all end in "games":
        //    public.app-category.games, …simulation-games, …puzzle-games, …
        //    `as? String` is a *conditional cast*: nil if the value is missing
        //    or is not a string.
        guard let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
              category.hasPrefix("public.app-category."),
              category.hasSuffix("games")
        else { return nil }

        // 3. Which App Store item is it?
        guard let adamID = lookUpAdamID(appURL) else { return nil }

        return DetectedGame(id: bundleID, name: Self.displayName(of: bundle, at: appURL), source: .appStore(adamID: adamID))
    }

    /// The name people see: CFBundleDisplayName, then CFBundleName, then the
    /// file name without ".app". `??` is the *nil-coalescing operator*: it
    /// takes the right side when the left side is nil.
    static func displayName(of bundle: Bundle, at url: URL) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    /// Reads `kMDItemAppStoreAdamID` from Spotlight's index.
    ///
    /// This calls a C API. `MDItemCreateWithURL` returns an optional because
    /// the C function can return NULL. `url as CFURL` *bridges* the Swift type
    /// to its Core Foundation twin; Swift does this for free for many types.
    /// Returns nil if Spotlight indexing is off for the volume.
    @Sendable
    public static func spotlightAdamID(_ url: URL) -> Int? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        let value = MDItemCopyAttribute(item, "kMDItemAppStoreAdamID" as CFString)
        return (value as? NSNumber)?.intValue
    }
}
