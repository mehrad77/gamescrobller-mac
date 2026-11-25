import Foundation
import ScrobblerCore

/// The sentences about scrobbling that both the menu and the Now Playing
/// tab show, so the two always say the same thing.
extension AppModel {
    /// One line about scrobbling. `scrobbleStatus` is optional, so the
    /// `switch` uses *optional patterns*: `.idle?` matches "a value that is
    /// `.idle`", and `nil` matches "no value".
    var scrobbleLine: String {
        if !scrobblingEnabled { return "Scrobbling is off (turn it on in Settings)" }
        if !hasToken { return "Add a token in Settings to scrobble" }
        if isPaused, let until = pausedUntil { return Self.pausedLine(until: until) }
        switch scrobbleStatus {
        case nil, .idle?:
            return "Ready to scrobble"
        case .scrobbling(let game, _)?:
            return "Scrobbling \(game.name)"
        case .waiting(let until, let error)?:
            return "Trying again at \(until.formatted(date: .omitted, time: .shortened)). \(error.summary)"
        case .failed(let game, let error)?:
            if case .api(let api) = error, api.status == 404 {
                return "Not scrobbled: \(game.name) is not in your library"
            }
            return "Not scrobbled: \(game.name). Kept for the next launch. \(error.summary)"
        case .signedOut(let error)?:
            return "Stopped scrobbling. \(error.summary)"
        }
    }

    /// Whether pausing makes sense now: scrobbling is on and has a token.
    var canPause: Bool {
        scrobblingEnabled && hasToken
    }

    /// "Paused until 18:30", "Paused until tomorrow", "Paused until
    /// tomorrow at 00:30", or "Paused" (until you resume).
    static func pausedLine(until: Date) -> String {
        // "Until I resume" is saved as `Date.distantFuture`. A date read back
        // from preferences may differ from it in the last digits, so any end
        // more than two days away counts as "until you resume".
        if until.timeIntervalSinceNow > 2 * 24 * 60 * 60 { return "Paused" }
        let calendar = Calendar.current
        let time = until.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(until) { return "Paused until \(time)" }
        // "Until Tomorrow" ends at midnight tonight, the start of tomorrow.
        if until == calendar.startOfDay(for: until) { return "Paused until tomorrow" }
        return "Paused until tomorrow at \(time)"
    }
}
