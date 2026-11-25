import ServiceManagement

/// Opening the app when you log in, with `SMAppService` (macOS 13+): the
/// system's own list of login items, the one in System Settings > General >
/// Login Items. The app adds or removes itself; macOS may still ask you to
/// approve it there.
///
/// `mainApp` is this app itself, wherever it lives. It works best from
/// `/Applications` or `~/Applications`: a copy run from a build folder is
/// registered at that path, and a rebuilt copy elsewhere is a different app
/// to macOS.
enum LoginItem {
    /// What System Settings says about the app.
    enum State: Equatable {
        case off
        case on
        /// Added, but waiting for you to allow it in System Settings.
        case needsApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        // `.notRegistered`, `.notFound`, and any case a later macOS adds.
        default: .off
        }
    }

    /// Adds or removes the app. It `throws` when macOS refuses, for example
    /// when the app is not signed.
    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens System Settings at Login Items, to approve the app there.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
