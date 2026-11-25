import ScrobblerCore
import SwiftUI

/// The Games tab: every game the app knows, and where each one stands with
/// GameScrobbler. Select one to see more, and to add it to your library or
/// turn scrobbling off for it, in the panel below the table.
struct GamesSettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.allGames.isEmpty {
                // A ready-made "nothing here yet" view (macOS 14+).
                ContentUnavailableView(
                    "No games yet",
                    systemImage: "gamecontroller",
                    description: Text("App Store and Steam games show up here once they are installed.")
                )
            } else {
                gameTable
                Divider()
                detail
                    .frame(height: 250)
            }
        }
        .frame(width: 640, height: 600)
    }

    /// A `Table` lays rows out in columns, like Finder's list view. Each
    /// `TableColumn` gets one row's value and returns that cell's view.
    ///
    /// `selection:` takes a `Binding` to the selected row's id. This one is
    /// built from the model, so the menu can select a game before it opens
    /// this window.
    private var gameTable: some View {
        Table(model.allGames, selection: Binding(
            get: { model.selectedGameID },
            set: { model.selectedGameID = $0 }
        )) {
            TableColumn("Game") { game in
                HStack(spacing: 8) {
                    GameIcon(game: game, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(game.name)
                        Text(game.sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .opacity(model.records[game.id].ignored ? 0.5 : 1)
            }

            TableColumn("Status") { game in
                StatusBadge(status: model.status(of: game))
            }
            .width(min: 120, ideal: 140)

            // The game's page on GameScrobbler, once the server told us
            // which game it is.
            TableColumn("") { game in
                if let url = model.pageURL(of: game) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open \(game.name) on GameScrobbler")
                }
            }
            .width(28)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedGameID, let game = model.allGames.first(where: { $0.id == id }) {
            GameDetailView(model: model, game: game)
        } else {
            ContentUnavailableView(
                "Select a game",
                systemImage: "cursorarrow.click.2",
                description: Text("See where it stands with GameScrobbler, and whether it is scrobbled.")
            )
        }
    }
}

/// Everything about one game: where it stands, its page on GameScrobbler,
/// whether it is scrobbled at all, and adding it to your library.
private struct GameDetailView: View {
    let model: AppModel
    let game: DetectedGame

    private var record: GameRecord { model.records[game.id] }
    private var status: GameStatus { model.status(of: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            explanation
            pageLink
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var header: some View {
        HStack(spacing: 14) {
            GameIcon(game: game, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name)
                    .font(.title2.weight(.semibold))
                Text(game.sourceLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: status)
        }
    }

    /// What the status means, in a box tinted with its colour.
    private var explanation: some View {
        Text(status.explanation(for: game))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(status.color.opacity(0.25))
            }
    }

    /// The game's page once the server told us which game it is; a search
    /// on gamescrobbler.com before that.
    @ViewBuilder
    private var pageLink: some View {
        Group {
            if let page = model.pageURL(of: game) {
                Link(destination: page) {
                    Label("View on GameScrobbler", systemImage: "arrow.up.right.square")
                }
            } else {
                Link(destination: searchURL) {
                    Label("Search for it on gamescrobbler.com", systemImage: "magnifyingglass")
                }
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            // A `Toggle` with `.switch` style is the on/off switch System
            // Settings uses.
            Toggle("Scrobble this game", isOn: Binding(
                get: { !record.ignored },
                set: { model.setIgnored(!$0, for: game) }
            ))
            .toggleStyle(.switch)
            Spacer()
            if status == .adding {
                ProgressView()
                    .controlSize(.small)
                Text("Adding…")
                    .foregroundStyle(.secondary)
            } else if model.canAddToLibrary(game) {
                Button {
                    model.addToLibrary(game)
                } label: {
                    if status == .unknownGame {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    } else {
                        Label("Add to Library", systemImage: "plus.circle")
                    }
                }
                .disabled(record.ignored)
                .help("Adds \(game.name) to your GameScrobbler library, so its plays are scrobbled.")
            }
        }
    }

    /// Searches gamescrobbler.com for the game's name.
    private var searchURL: URL {
        var components = URLComponents(string: "https://gamescrobbler.com/games")!
        components.queryItems = [URLQueryItem(name: "q", value: game.name)]
        return components.url!
    }
}
