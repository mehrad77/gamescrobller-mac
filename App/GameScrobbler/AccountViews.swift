import AppKit
import ScrobblerCore
import SwiftUI

/// Your avatar in a circle, or your initial while there is none.
struct AvatarView: View {
    let image: NSImage?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // `.prefix(1)` is the first character, as a Substring.
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.gradient)
            }
        }
        .frame(width: size, height: size)
        // `clipShape` cuts the view to the shape; the overlay draws a hairline
        // ring so a light avatar still has an edge.
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.primary.opacity(0.1)) }
    }
}

/// The Account card at the top of the General tab: who the token belongs
/// to, the stores linked to that account, and a way to your Hub.
struct AccountCard: View {
    let profile: GSProfile
    let avatar: NSImage?
    let openHub: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(image: avatar, name: profile.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                Text(profile.handle.map { "@\($0)" } ?? "No handle claimed yet")
                    .foregroundStyle(.secondary)
                if !profile.platforms.isEmpty {
                    Text("Linked: \(profile.platformList)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: openHub) {
                Label("Open Hub", systemImage: "arrow.up.forward.app")
            }
            .help("Opens your GameScrobbler Hub in your browser.")
        }
        .padding(.vertical, 4)
    }
}

extension GSProfile {
    /// The name to show: your display name, else your handle, else "You".
    var name: String {
        displayName ?? handle ?? "You"
    }

    /// "Android, Steam and Xbox": `ListFormatStyle` joins a list the way
    /// your language does.
    var platformList: String {
        platforms.map(\.localizedCapitalized).formatted(.list(type: .and))
    }
}

extension NSImage {
    /// A small round copy, for a menu item: a menu shows images square and
    /// at their own size.
    func circled(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            self.draw(in: rect)
            return true
        }
    }
}
