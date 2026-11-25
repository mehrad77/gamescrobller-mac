import Foundation
import ScrobblerCore

/// The app's preferences, saved in `UserDefaults`: a small key-value store
/// every Mac app has (`~/Library/Preferences/<bundle id>.plist`). It suits
/// plain settings; secrets such as the token go to the Keychain instead.
///
/// An `enum` with no cases cannot be created; it only groups static members,
/// which makes it a tidy namespace.
enum AppSettings {
    /// The `UserDefaults` key of the API base URL. `SettingsView` reads and
    /// writes it through `@AppStorage`.
    static let baseURLKey = "baseURL"

    /// The API base URL to use: the saved one, or production when nothing is
    /// saved. nil when the saved text is not an http(s) URL.
    static var baseURL: URL? {
        let text = UserDefaults.standard.string(forKey: baseURLKey) ?? GSClient.productionBaseURL.absoluteString
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http",
              url.host() != nil
        else { return nil }
        return url
    }

    /// Whether plays are sent to GameScrobbler. Off until you turn it on, so
    /// launching a test build with a game open never writes by surprise.
    /// `bool(forKey:)` answers false for a key that was never saved.
    static var scrobblingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "scrobblingEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "scrobblingEnabled") }
    }

    /// When the pause you chose in the menu ends: nil when not paused, and
    /// `Date.distantFuture` for "until I resume". Saved as seconds since
    /// 1970, so a pause survives a relaunch.
    static var pausedUntil: Date? {
        get {
            let seconds = UserDefaults.standard.double(forKey: "pausedUntil")
            return seconds == 0 ? nil : Date(timeIntervalSince1970: seconds)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "pausedUntil")
            } else {
                UserDefaults.standard.removeObject(forKey: "pausedUntil")
            }
        }
    }

    /// The journal of plays for the server at `baseURL`, in
    /// `~/Library/Application Support/<bundle id>/`, the folder macOS gives
    /// each app for files it keeps for itself. nil only if macOS has no such
    /// folder, which does not happen in practice.
    static func journal(for baseURL: URL) -> PlayJournal? {
        supportFolder.map { PlayJournal(directory: $0, server: baseURL) }
    }

    /// What the app keeps about each game for the server at `baseURL`,
    /// next to its journal.
    static func recordStore(for baseURL: URL) -> GameRecordStore? {
        supportFolder.map { GameRecordStore(directory: $0, server: baseURL) }
    }

    private static var supportFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? "GameScrobbler")
    }

    /// The GameScrobbler website that goes with the API at `baseURL`:
    /// `api.gamescrobbler.com` is served by `gamescrobbler.com`, and a local
    /// stack's API on port 8000 by its frontend on port 3000.
    static func website(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host
        else { return nil }
        if host.hasPrefix("api.") {
            components.host = String(host.dropFirst("api.".count))
        } else if host == "localhost" || host == "127.0.0.1" {
            components.port = 3000
        }
        components.path = ""
        return components.url
    }

    /// Your Hub on the website (`/dashboard/hub`), for the "Open Hub" buttons.
    static var hubURL: URL? {
        baseURL.flatMap(website(for:))?.appending(path: "dashboard/hub")
    }

    /// The page in your Hub settings where personal access tokens are made
    /// (Settings > Developer > Tokens).
    static var tokensURL: URL? {
        hubURL?.appending(path: "settings/developer/tokens")
    }

    /// The Settings tab to show, so the menu can open the Games tab.
    static let settingsTabKey = "settingsTab"

    /// Whether the icon is in the menu bar (on unless you turn it off).
    static let showsMenuBarIconKey = "showsMenuBarIcon"

    /// The `deviceId` of the server check (`GSClient.checkServer`): one no
    /// session ever uses, so the check stops nothing.
    static var statusProbeDeviceID: String {
        deviceID + "-status-check"
    }

    /// This Mac's `deviceId` for the API: made once, then kept forever, so
    /// every session from this Mac counts as the same device.
    static var deviceID: String {
        if let saved = UserDefaults.standard.string(forKey: "deviceID") {
            return saved
        }
        let new = "mac-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: "deviceID")
        return new
    }
}

extension GSClientError {
    /// One sentence for the Settings window.
    var summary: String {
        switch self {
        case .network(let error):
            return "Could not reach the server: \(error.localizedDescription)"
        case .api(let error) where error.status == 401:
            // `where` adds a condition to a `case`: this one matches only 401s.
            return "The server refused the token (\(error.code.rawValue)). Paste a new one."
        case .api(let error):
            return "The server answered \(error.status) \(error.code.rawValue): \(error.message)"
        case .unexpectedResponse(let status):
            return "The server sent an unexpected answer (HTTP \(status)). Check the address."
        }
    }
}
