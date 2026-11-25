import ScrobblerCore
import SwiftUI

/// The Now Playing tab: everything the menu bar menu shows and does, so the
/// app works the same with its menu bar icon hidden.
struct NowPlayingView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Now playing") {
                if model.running.isEmpty {
                    Text("Nothing right now")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.running) { running in
                        HStack(spacing: 10) {
                            GameIcon(game: running.game, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(running.game.name)
                                    .font(.headline)
                                Text("Playing since \(running.startedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Scrobbling") {
                Text(model.scrobbleLine)
                if model.serverStatus == .playsTurnedOff {
                    Label("GameScrobbler isn’t taking plays right now; they are kept.", systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
                pauseControls
                if model.unsentCount > 0 {
                    // `^[…](inflect: true)` writes "1 play" or "2 plays".
                    Text("^[\(model.unsentCount) play](inflect: true) saved, waiting to be sent")
                        .foregroundStyle(.secondary)
                }
                if let last = model.lastScrobble {
                    Text("Last scrobbled: \(last.gameTitle), \(last.durationSeconds / 60) min")
                        .foregroundStyle(.secondary)
                }
            }

            if !model.refusedGames.isEmpty {
                needsYourAnswer
            }

            Section {
                HStack {
                    Text("Your plays and stats are on GameScrobbler.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.openHub) {
                        Label("Open Hub", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsPane()
    }

    /// "Pause" with how long, or "Resume" while paused; the same choices as
    /// the menu.
    @ViewBuilder
    private var pauseControls: some View {
        if model.isPaused {
            HStack {
                Text("Plays are not being recorded.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Resume Scrobbling") { model.resume() }
            }
        } else if model.canPause {
            HStack {
                Text("Take a break from scrobbling.")
                    .foregroundStyle(.secondary)
                Spacer()
                // A `Menu` outside a menu bar draws as a pop-up button.
                Menu("Pause Scrobbling") {
                    Button("For an Hour") { model.pause(.oneHour) }
                    Button("Until Tomorrow") { model.pause(.untilTomorrow) }
                    Button("Until I Resume") { model.pause(.untilResumed) }
                }
                .fixedSize()
            }
        }
    }

    /// Each game whose plays the server refused, with what you can do about
    /// it: the menu's "Needs your answer" submenus.
    private var needsYourAnswer: some View {
        Section("Needs your answer") {
            ForEach(model.refusedGames) { refused in
                let game = refused.game
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        GameIcon(game: game, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.name)
                                .font(.headline)
                            Text("^[\(refused.playCount) play](inflect: true) waiting · \(model.status(of: game).title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Don’t Scrobble") { model.setIgnored(true, for: game) }
                        Button("Show in Games") { model.showInSettings(game) }
                        if model.canAddToLibrary(game) {
                            Button("Add to My Library") { model.addToLibrary(game) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
