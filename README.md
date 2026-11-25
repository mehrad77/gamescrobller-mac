![GameScrobbler for Mac: the Games tab of Settings, showing which of the games on this Mac are in your GameScrobbler library](docs/banner.png)

# GameScrobbler for Mac

A macOS menu bar app that notices when you play a game on your Mac and
scrobbles the play session to [GameScrobbler](https://gamescrobbler.com)
through its public API.

- **Apple Arcade / Mac App Store games:** detected from the app's App Store receipt and its "games" category.
- **Steam games:** detected from the running game's install folder.
- **GOG and Epic:** planned.

Work in progress; this is also my first Swift project.

## Install

Needs macOS 14 Sonoma or later, on Apple silicon or Intel.

1. Download the `.dmg` from the [latest release](https://github.com/mehrad77/gamescrobller-mac/releases/latest),
   open it, and drag **GameScrobbler** to **Applications**.
2. Open GameScrobbler from Applications. The app is not signed with an Apple
   Developer ID, so macOS blocks the first launch. Allow it once, either way:
   - in **System Settings → Privacy & Security**, click **Open Anyway** next to
     the message about GameScrobbler;
   - or run this in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/GameScrobbler.app
     ```

3. Click the GameScrobbler icon in the menu bar and open **Settings…** (or
   press ⌘,). In **General**, paste a personal access token, created in your
   GameScrobbler
   [developer settings](https://gamescrobbler.com/dashboard/hub/settings/developer/tokens)
   with the `activity:write` and `library:write` scopes. The **Create a Token**
   link under the token field opens that page. Once the token works, the
   same place shows your account.
4. Turn on **Send plays to GameScrobbler**.

## Using it

The window has three tabs:

- **Now Playing:** the game you're playing, whether plays are being sent,
  pausing and resuming, and games that need your answer. It's the same as the
  menu bar menu.
- **Games:** every game on this Mac, whether it is in your GameScrobbler
  library, and a switch to stop scrobbling one.
- **General:** your account and token, the connection, Open at Login, and
  **Show in Menu Bar**.

The app shows in the Dock while its window is open. If you turn off **Show in
Menu Bar**, open GameScrobbler again from Applications, Spotlight or the Dock
to get the window back.

## Layout

```text
App/                           the menu bar app (Xcode only)
  GameScrobbler.xcodeproj      Xcode project; links ScrobblerCore from Core/
  GameScrobbler/               the app's SwiftUI code
Core/                          a Swift package (Xcode, or swift build/test in Terminal)
  Package.swift                SwiftPM manifest for the core library and tools
  Sources/
    ScrobblerCore/             all logic (detection, API client, scrobbler), a library
    gs-detect/                 command-line debug tool for the detection code
  Tests/
    ScrobblerCoreTests/        Swift Testing tests for ScrobblerCore
```

The app is a thin SwiftUI shell; everything it does lives in `Core/`, so the
logic builds and tests without Xcode or any UI.

## Build and run

You need Xcode 27 or later (the project uses its text-based format; open Xcode once to finish its setup).

- **App:** open `App/GameScrobbler.xcodeproj` in Xcode and press Run (`Cmd+R`). The app lives in the menu bar (the GameScrobbler tick); it shows in the Dock only while its window is open.
- **From the terminal:**

  ```bash
  xcodebuild -project App/GameScrobbler.xcodeproj -scheme GameScrobbler -derivedDataPath .build/xcode build
  ```

  ```bash
  open .build/xcode/Build/Products/Debug/GameScrobbler.app
  ```

- **Tests** (from the `Core/` folder):

  ```bash
  cd Core && swift test
  ```

- **Debug tool** (from `Core/`): `swift run gs-detect` lists the games the app recognises, and `swift run gs-detect --watch` prints games as they start and stop.

## License

GPL-3.0, see [LICENSE](LICENSE).
