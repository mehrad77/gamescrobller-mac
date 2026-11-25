import ScrobblerCore
import SwiftUI

/// The window's tabs. A `String` raw value, so the selected one can be
/// saved with `@AppStorage`, and the menu can pick the Games tab.
enum SettingsTab: String {
    case nowPlaying
    case games
    case general
}

/// The app's window (⌘, or "Settings…" in the menu): a `TabView` with one
/// tab per page, drawn as a row of tabs along the top.
struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppSettings.settingsTabKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            NowPlayingView(model: model)
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
                .tag(SettingsTab.nowPlaying)
            GamesSettingsView(model: model)
                .tabItem { Label("Games", systemImage: "gamecontroller") }
                .tag(SettingsTab.games)
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
    }
}

extension View {
    /// The size of every tab: no smaller than this, and free to fill the
    /// window when you drag it larger (`maxWidth: .infinity`).
    func settingsPane(minWidth: CGFloat = 520) -> some View {
        frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }
}

/// The General tab: scrobbling on or off, the server address and the token.
struct GeneralSettingsView: View {
    let model: AppModel

    /// `@AppStorage` is a property wrapper that reads and writes one
    /// `UserDefaults` key, and redraws the view when it changes. The value
    /// after `=` is used while nothing is saved yet.
    @AppStorage(AppSettings.baseURLKey) private var baseURL = GSClient.productionBaseURL.absoluteString

    /// What is typed in the token field. `@State` keeps it only while the
    /// window is open; it is never saved anywhere but the Keychain.
    @State private var tokenDraft = ""

    /// Whether the icon is in the menu bar; the app's `MenuBarExtra` reads
    /// the same key.
    @AppStorage(AppSettings.showsMenuBarIconKey) private var showsMenuBarIcon = true

    /// Whether the token field shows while you are signed in, after
    /// "Change Token…".
    @State private var isChangingToken = false

    /// Whether the app opens at login. macOS keeps this, not the app, and
    /// does not announce changes, so it is read when the tab appears and
    /// after each change.
    @State private var loginItem = LoginItem.state
    @State private var loginItemError: String?

    var body: some View {
        Form {
            // One section for both: a token that works shows whose account
            // it is, so the token field only appears while there is none,
            // the server refused it, or you chose to change it.
            Section("Account") {
                if isChangingToken || !model.hasToken || model.tokenRefused {
                    tokenEntry
                } else if let profile = model.profile {
                    AccountCard(profile: profile, avatar: model.avatar, openHub: model.openHub)
                    tokenActions("Token saved in your Keychain.")
                } else if case .checking = model.connection {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking your token…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Offline, or the server in trouble: nothing is known
                    // about the token yet, good or bad.
                    tokenActions("A token is saved, but it couldn’t be checked: see Connection.")
                }
            }

            Section("Connection") {
                HStack {
                    connectionStatus
                    Spacer()
                    Button("Check Connection") { model.checkConnection() }
                        .disabled(!model.hasToken)
                }
                if let status = model.serverStatus {
                    serverStatus(status)
                }
            }

            Section("Scrobbling") {
                // A `Toggle` needs a `Binding<Bool>`. This one is built by
                // hand from a getter and a setter, so turning it on or off
                // goes through the model (which also restarts the scrobbler)
                // instead of just flipping a stored value.
                Toggle("Send plays to GameScrobbler", isOn: Binding(
                    get: { model.scrobblingEnabled },
                    set: { model.setScrobblingEnabled($0) }
                ))
                Text("This Mac is \(AppSettings.deviceID) to GameScrobbler.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Show in Menu Bar", isOn: $showsMenuBarIcon)
                if !showsMenuBarIcon {
                    Text("To come back to this window, open GameScrobbler again from Applications, Spotlight or the Dock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem != .off },
                    set: { setOpensAtLogin($0) }
                ))
                if loginItem == .needsApproval {
                    HStack {
                        Text("Allow GameScrobbler in System Settings to open it at login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onAppear { loginItem = LoginItem.state }

            Section("Server") {
                // `$baseURL` is the wrapper's *projected value*: a `Binding`,
                // a two-way link that lets the text field change the setting.
                TextField("API address", text: $baseURL)
                Text("Production: \(GSClient.productionBaseURL.absoluteString). A local stack: http://localhost:8000/v1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("GameScrobbler for Mac \(ScrobblerCore.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Quitting stops scrobbling until the app is opened again.
                    Button("Quit GameScrobbler") { NSApplication.shared.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .settingsPane()
        // Leaving the tab drops a half-typed token, so the next visit shows
        // your account again. On appearing too, in case a closed window's
        // views were kept alive instead of made anew.
        .onAppear(perform: cancelTokenChange)
        .onDisappear(perform: cancelTokenChange)
    }

    private func cancelTokenChange() {
        isChangingToken = false
        tokenDraft = ""
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItemError = nil
        } catch {
            loginItemError = "macOS refused: \(error.localizedDescription)"
        }
        loginItem = LoginItem.state
    }

    /// Whether GameScrobbler takes plays now, from the last check.
    @ViewBuilder
    private func serverStatus(_ status: ServerStatus) -> some View {
        switch status {
        case .acceptingPlays:
            Label("GameScrobbler is taking plays", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .playsTurnedOff:
            Label("GameScrobbler isn’t taking plays right now. They are kept and sent once it does.", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .tokenRefused(let error):
            Label("The token can’t send plays. \(error.summary)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .unreachable(let error):
            Label(error.summary, systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }

    /// A line about the saved token, with Change and Remove.
    private func tokenActions(_ caption: String) -> some View {
        HStack {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Change Token…") { isChangingToken = true }
            Button("Remove Token", role: .destructive) { model.removeToken() }
        }
    }

    /// The token field, with a link to the page where tokens are made.
    /// `@ViewBuilder` lets a property return several views, which the
    /// `Section` lays out as rows.
    @ViewBuilder
    private var tokenEntry: some View {
        // A `SecureField` shows dots instead of the text.
        SecureField("Personal access token", text: $tokenDraft, prompt: Text("gsp_…"))
        HStack {
            if isChangingToken {
                Text("Paste the new token.")
                    .foregroundStyle(.secondary)
            } else if model.tokenRefused {
                Text("GameScrobbler refused the saved token. Paste a new one.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isChangingToken {
                Button("Cancel") {
                    isChangingToken = false
                    tokenDraft = ""
                }
            } else if model.hasToken {
                Button("Remove Token", role: .destructive) { model.removeToken() }
            }
            Button("Save") {
                // On a failed save the field keeps its text, to try again.
                if model.saveToken(tokenDraft) {
                    tokenDraft = ""
                    isChangingToken = false
                }
            }
            .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)  // Return presses it
        }
        HStack(alignment: .firstTextBaseline) {
            Text("Create one in your GameScrobbler developer settings, with the activity:write and library:write scopes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // `Link` opens the address in the default browser.
            if let url = AppSettings.tokensURL {
                Link("Create a Token", destination: url)
                    .font(.caption)
            }
        }
    }

    /// A computed property can return part of a view, to keep `body` short.
    /// `@ViewBuilder` lets it use `switch`, giving a different view per case.
    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connection {
        case .notChecked:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .connected:
            // Whose account it is shows in the Account section above.
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
