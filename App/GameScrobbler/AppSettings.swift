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
