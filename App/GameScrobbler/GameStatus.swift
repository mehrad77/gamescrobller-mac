import ScrobblerCore
import SwiftUI

/// Where one game stands with GameScrobbler, as the Games tab and the menu
/// show it. `AppModel.status(of:)` works it out; this file only decides how
/// each case looks and reads, so the wording lives in one place.
enum GameStatus: Equatable {
    /// Nothing known yet: the server is asked the first time you play it.
    case notChecked
    /// In your library, by this title when the server said it.
    case inLibrary(title: String?)
    /// The server refused its plays (404). They wait for you.
    case notInLibrary(plays: Int)
    /// Not in your library, found by looking it up: no play refused yet.
    case notOwned
    /// Added to your library on this run, and still refused.
    case stillRefused
    /// Refused for another reason, explained in the text.
    case refused(String)
    /// GameScrobbler's catalogue has no game for its reference.
    case unknownGame
    case adding
    case addFailed(String)
    /// You turned scrobbling off for it.
    case ignored

    var title: String {
        switch self {
        case .notChecked: "Not checked"
        case .inLibrary: "In library"
        case .notInLibrary, .notOwned: "Not in library"
        case .stillRefused, .refused: "Refused"
        case .unknownGame: "Unknown game"
        case .adding: "Adding…"
        case .addFailed: "Not added"
        case .ignored: "Not scrobbled"
        }
    }

    /// An SF Symbol name.
    var symbol: String {
        switch self {
        case .notChecked: "circle.dashed"
        case .inLibrary: "checkmark.circle.fill"
        case .notInLibrary: "exclamationmark.triangle.fill"
        case .notOwned: "plus.circle"
        case .stillRefused, .refused: "xmark.octagon.fill"
        case .unknownGame: "questionmark.circle.fill"
        case .adding: "arrow.triangle.2.circlepath"
        case .addFailed: "exclamationmark.circle.fill"
        case .ignored: "eye.slash"
        }
    }

    var color: Color {
        switch self {
        case .notChecked, .ignored: .secondary
        case .inLibrary: .green
        case .notInLibrary, .notOwned, .addFailed: .orange
        case .stillRefused, .refused, .unknownGame: .red
        case .adding: .blue
        }
    }

    /// One or two sentences for the game's detail panel.
    func explanation(for game: DetectedGame) -> String {
        switch self {
        case .notChecked:
            "Not checked yet: the app looks each game up in your library when it connects to GameScrobbler."
        case .notOwned:
            "\(game.name) is not in your GameScrobbler library, so its plays would be refused. Add it to your library to scrobble it."
        case .inLibrary(let title?):
            "GameScrobbler knows it as “\(title)”, and it is in your library. Plays are scrobbled."
        case .inLibrary(nil):
            "It is in your GameScrobbler library. Plays are scrobbled."
        case .notInLibrary(let plays):
            "GameScrobbler refused \(plays == 1 ? "its play" : "its \(plays) plays"): \(game.name) is not in your library. Add it to your library to scrobble it; plays wait until then."
        case .stillRefused:
            "Added to your library, but its plays are still refused. Scrobbling may be off on the server; plays are kept and sent at the next launch."
        case .refused(let reason):
            "The server refused its plays. \(reason)"
        case .unknownGame:
            "GameScrobbler doesn’t know this game yet, so it can’t be added to your library. Its plays are kept for a week: check again later, or turn scrobbling off for it."
        case .adding:
            "Adding \(game.name) to your library…"
        case .addFailed(let reason):
            "Could not add it to your library. \(reason)"
        case .ignored:
            "You turned scrobbling off for this game. Plays the server hasn’t seen wait for a week, in case you turn it back on."
        }
    }
}

/// A small coloured capsule with the status's symbol and title.
struct StatusBadge: View {
    let status: GameStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // `in: Capsule()` fills the background in that shape.
            .background(status.color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}
