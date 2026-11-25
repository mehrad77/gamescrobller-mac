import ScrobblerCore
import SwiftUI

/// The Settings window's tabs. A `String` raw value, so the selected one
/// can be saved with `@AppStorage`, and the menu can pick the Games tab.
enum SettingsTab: String {
    case general
    case games
}

/// The Settings window (⌘, from the menu): a `TabView` with one tab per
/// page. In a `Settings` scene, macOS draws the tabs as the toolbar buttons
/// every Mac app's settings have, and resizes the window to fit each tab.
struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppSettings.settingsTabKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            GamesSettingsView(model: model)
                .tabItem { Label("Games", systemImage: "gamecontroller") }
                .tag(SettingsTab.games)
        }
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

    /// Whether the app opens at login. macOS keeps this, not the app, and
    /// does not announce changes, so it is read when the tab appears and
    /// after each change.
    @State private var loginItem = LoginItem.state
    @State private var loginItemError: String?

    var body: some View {
        Form {
            if let profile = model.profile {
                Section("Account") {
                    AccountCard(profile: profile, avatar: model.avatar, openHub: model.openHub)
                }
            }

            Section("Personal access token") {
                // A `SecureField` shows dots instead of the text.
                SecureField("gsp_…", text: $tokenDraft)
                HStack {
                    Text(model.hasToken ? "A token is saved in your Keychain." : "No token saved.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeToken() }
                        .disabled(!model.hasToken)
                    Button("Save") {
                        model.saveToken(tokenDraft)
                        tokenDraft = ""
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)  // Return presses it
                }
                Text("Create one on gamescrobbler.com in your developer settings, with the activity:write and library:write scopes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Startup") {
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
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

    /// A computed property can return part of a view, to keep `body` short.
    /// `@ViewBuilder` lets it use `switch`, giving a different view per case.
    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connection {
        case .notChecked:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .connected(let profile):
            Label("Connected as \(profile.name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
