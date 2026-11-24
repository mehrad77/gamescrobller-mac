/// How GameScrobbler names a game in an API call (the `game` field of
/// `POST /me/sessions`).
///
/// The server accepts three spellings, and an `enum` with *associated values*
/// models "exactly one of these, each carrying its own data" directly:
///
///     g_7k2m9q4xzt     -> .gameID("g_7k2m9q4xzt")
///     mini-motorways   -> .slug("mini-motorways")
///     steam:570        -> .store(.steam, id: "570")
///
/// Numeric ids (`570`) are internal to GameScrobbler and refused by the API
/// (ADR-064, gs-mono PR 442), so there is deliberately no case for them.
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

    /// Store prefixes the app knows how to produce. `String` as the *raw value*
    /// type means each case has a text form: `Store.steam.rawValue == "steam"`.
    public enum Store: String, CaseIterable, Sendable {
        case steam
        case gog
        case epic
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
            // `Store(rawValue:)` is itself failable: unknown prefixes give nil.
            guard let store = Store(rawValue: String(parts[0])),
                  !parts[1].isEmpty,
                  !parts[1].contains(where: \.isWhitespace)
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
