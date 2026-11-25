import AppKit
import ScrobblerCore
import SwiftUI

/// A game's own app icon, as Finder shows it.
struct GameIcon: View {
    let game: DetectedGame
    var size: CGFloat = 20

    var body: some View {
        // `Image(nsImage:)` shows an AppKit image in SwiftUI.
        Image(nsImage: GameIcons.icon(for: game))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Finds and keeps each game's icon. Looking one up reads the disk, and a
/// table redraws its rows often, so each is looked up once.
@MainActor
enum GameIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for game: DetectedGame) -> NSImage {
        if let icon = cache[game.id] { return icon }
        let icon = appURL(of: game).map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            ?? NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
            ?? NSImage()
        cache[game.id] = icon
        return icon
    }

    /// The `.app` to take the icon from: found by bundle id for App Store
    /// games, and the first app inside the install folder for Steam ones.
    private static func appURL(of game: DetectedGame) -> URL? {
        switch game.source {
        case .appStore:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: game.id)
        case .steam:
            let folder = URL(filePath: game.id, directoryHint: .isDirectory)
            let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return contents?.first { $0.pathExtension == "app" } ?? folder
        }
    }
}
