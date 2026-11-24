/// How GameScrobbler names a game in an API call (the `game` field of
/// `POST /me/sessions`).
///
/// The server accepts three spellings, and an `enum` with *associated values*
/// models "exactly one of these, each carrying its own data" directly:
///
///     g_7k2m9q4xzt     -> .gameID("g_7k2m9q4xzt")
///     mini-motorways   -> .slug("mini-motorways")
///     steam:570        -> .store(.steam, id: "570")
///     apple:1456188526 -> .store(.apple, id: "1456188526")
///
/// Numeric ids (`570`) are GameScrobbler's internal ids. The API still reads
/// them today, but refuses them once gs-mono PR 442 (ADR-064) merges, so the
/// app never sends one and there is deliberately no case for them.
///
/// API docs:
/// - Endpoint reference (`POST /me/sessions`, `startSession`):
///   https://developers.gamescrobbler.com/reference/#api-1/tag/activity/POST/me/sessions
/// - Guide, "Start a session":
///   https://developers.gamescrobbler.com/guides/recording-play/#start-a-session
///
/// `Hashable` lets a `GameRef` be a dictionary key or live in a `Set`.
/// `Sendable` promises it is safe to pass between threads (Swift 6 checks this).
public enum GameRef: Hashable, Sendable {
    case gameID(String)
    case slug(String)
    case store(Store, id: String)

    /// A store prefix, such as `steam` in `steam:570`.
    ///
    /// An *open* type, like `GSAPIError.Code`: the server knows more stores
    /// than this app produces (`xbox`, `itch`, `amazon`, ...) and may add
    /// more, so any well-formed prefix is allowed and the server decides
    /// whether it knows it (an unknown store answers 404, like an unknown
    /// game). The `static let`s are the prefixes the app itself writes.
    public struct Store: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        /// `RawRepresentable` asks for a *failable* `init?(rawValue:)`; here it
        /// checks the server's prefix syntax: a lowercase letter, then 1 to 15
        /// lowercase letters or digits. Matching is case-sensitive, as on the
        /// server, so `Steam` is refused.
        public init?(rawValue: String) {
            guard rawValue.wholeMatch(of: GameRef.storePrefixPattern) != nil else { return nil }
            self.rawValue = rawValue
        }

        /// For the constants below, which are known to be well-formed.
        private init(known rawValue: String) {
            self.rawValue = rawValue
        }

        public static let steam = Store(known: "steam")
        public static let gog = Store(known: "gog")
        public static let epic = Store(known: "epic")
        /// Mac App Store and Apple Arcade games, by their App Store ("Adam")
        /// id (gs-mono PR 463). The server only resolves ids its catalogue has.
        public static let apple = Store(known: "apple")
    }

    /// The exact text the API expects in the `game` field.
    ///
    /// A *computed property*: it has no storage, its body runs on every read.
    public var apiValue: String {
        switch self {
        case .gameID(let id):
            return id
        case .slug(let slug):
            return slug
        case .store(let store, let id):
            return "\(store.rawValue):\(id)"
        }
    }
}

extension GameRef {
    /// The server's limit on a reference's length.
    static let maxLength = 200

    // Regex literals, written between `#/` and `/#`. They are checked when the
    // code compiles, so a typo in a pattern is a build error, not a crash.
    // These copy the server's rules in `gameReferenceSyntax.ts`.
    //
    // They are computed (`var … { … }`) rather than stored (`let … = …`):
    // `Regex` is not `Sendable`, and Swift 6 refuses a shared global value of a
    // type that might not be safe to read from two threads at once. Building
    // the pattern on each use sidesteps that and costs next to nothing here.

    /// A public game id: `g_` and 10 lowercase Crockford base32 characters
    /// (digits and letters without i, l, o and u).
    static var publicIDPattern: Regex<Substring> { #/g_[0-9a-hjkmnp-tv-z]{10}/# }
    /// A slug: starts with a letter or digit, then letters, digits, `.`, `_`, `-`.
    static var slugPattern: Regex<Substring> { #/[A-Za-z0-9][A-Za-z0-9._-]{0,199}/# }
    static var digitsPattern: Regex<Substring> { #/[0-9]+/# }
    /// A store prefix: a lowercase letter, then 1 to 15 lowercase letters or digits.
    static var storePrefixPattern: Regex<Substring> { #/[a-z][a-z0-9]{1,15}/# }
    /// The store's own id after the colon: letters, digits, `.`, `_`, `-`.
    static var storeIDPattern: Regex<Substring> { #/[A-Za-z0-9._-]{1,200}/# }

    /// Parses what a person types into the mapping editor, in the server's
    /// order: digits are refused, an id-shaped text is an id, `store:id` is a
    /// store reference, and anything else must be a valid slug.
    ///
    /// `init?` is a *failable initializer*: it returns `nil` instead of a value
    /// when the text is not a valid reference, so callers must handle that case.
    public init?(parsing text: String) {
        // `guard` exits early unless its condition holds. Everything below it
        // can rely on `text` being non-empty and short enough.
        guard !text.isEmpty, text.count <= Self.maxLength else { return nil }

        // `wholeMatch` succeeds only if the pattern covers the entire string,
        // so there is no need for `^` and `$` anchors.
        if text.wholeMatch(of: Self.digitsPattern) != nil {
            return nil
        }

        if text.wholeMatch(of: Self.publicIDPattern) != nil {
            self = .gameID(text)
            return
        }

        // `split` cuts at the colon. maxSplits: 1 keeps "a:b:c" as ["a", "b:c"].
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            // `Store(rawValue:)` is itself failable: a malformed prefix gives
            // nil. A well-formed one the server does not know still parses;
            // the server answers 404 for it, just as for an unknown game.
            guard let store = Store(rawValue: String(parts[0])),
                  parts[1].wholeMatch(of: Self.storeIDPattern) != nil
            else { return nil }
            self = .store(store, id: String(parts[1]))
            return
        }

        guard text.wholeMatch(of: Self.slugPattern) != nil else { return nil }
        self = .slug(text)
    }
}

/// `CustomStringConvertible` controls how a value prints with `print(...)`
/// or `"\(ref)"`, so logs show `steam:570` instead of `store(steam, id: "570")`.
extension GameRef: CustomStringConvertible {
    public var description: String { apiValue }
}
