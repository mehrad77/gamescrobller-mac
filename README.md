# GameScrobbler for Mac

A macOS menu bar app that notices when you play a game on your Mac and
scrobbles the play session to [GameScrobbler](https://gamescrobbler.com)
through its public API.

- **Apple Arcade / Mac App Store games:** detected from the app's App Store receipt and its "games" category.
- **Steam games:** detected from the running game's install folder.
- **GOG and Epic:** planned.

Work in progress; this is also my first Swift project.

## Layout

```text
Package.swift                  the SwiftPM manifest: targets and platforms
Sources/
  ScrobblerCore/               all logic (detection, API client, scrobbler), a library
  GSScrobbler/                 the menu bar app, a thin UI over ScrobblerCore
Tests/
  ScrobblerCoreTests/          Swift Testing tests for ScrobblerCore
```

## Build and run

The Xcode Command Line Tools are enough; full Xcode is optional. If you don't have them yet:

```bash
xcode-select --install
```

```bash
swift build              # compile everything
swift run GSScrobbler    # run the app
swift test               # run the tests
```

## License

GPL-3.0, see [LICENSE](LICENSE).
