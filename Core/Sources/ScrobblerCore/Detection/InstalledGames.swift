import Foundation

/// Lists the games installed on this Mac that the app can recognise, for the
/// "Installed games" part of the menu and the `gs-detect` debug tool.
public enum InstalledGames {
    /// App Store games found in `applicationsFolder`, plus every Steam game.
    public static func scan(
        appStore: AppStoreClassifier,
        steam: SteamClassifier,
        applicationsFolder: URL = URL(filePath: "/Applications")
    ) -> [DetectedGame] {
        // `try?` turns a thrown error into nil, and `?? []` then gives an
        // empty list: an unreadable folder means "no games", not a crash.
        let apps = (try? FileManager.default.contentsOfDirectory(
            at: applicationsFolder, includingPropertiesForKeys: nil)) ?? []

        let appStoreGames = apps
            .filter { $0.pathExtension == "app" }
            .compactMap { appStore.classify(appURL: $0) }
        let steamGames = steam.installedApps.values.map(\.detectedGame)

        // `+` joins two arrays. `localizedStandardCompare` sorts the way
        // Finder does ("Game 2" before "Game 10", ignoring case).
        return (appStoreGames + steamGames).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
