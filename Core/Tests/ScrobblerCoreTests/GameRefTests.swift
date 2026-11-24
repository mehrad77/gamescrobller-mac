import Testing
@testable import ScrobblerCore

// A `@Suite` groups related tests; it shows as one folder in the Testing panel.
@Suite("GameRef")
struct GameRefTests {
    // A *parameterized test*: Swift Testing runs the body once per argument
    // and reports each case separately, so one failing input is easy to spot.
    @Test("parses valid references", arguments: [
        ("g_7k2m9q4xzt", GameRef.gameID("g_7k2m9q4xzt")),
        ("mini-motorways", GameRef.slug("mini-motorways")),
        ("celeste.2018_v2", GameRef.slug("celeste.2018_v2")),
        ("steam:570", GameRef.store(.steam, id: "570")),
        ("gog:1207658924", GameRef.store(.gog, id: "1207658924")),
    ])
    func parsesValid(text: String, expected: GameRef) {
        #expect(GameRef(parsing: text) == expected)
    }

    @Test("rejects invalid references", arguments: [
        "",                        // empty
        "570",                     // numeric ids are refused by the API
        "mini motorways",          // contains a space
        "-starts-with-dash",       // a slug must start with a letter or digit
        "apple:1456188526",        // the server has no apple: prefix
        "steam:",                  // store without an id
        String(repeating: "a", count: 201), // over the server's 200-char limit
    ])
    func rejectsInvalid(text: String) {
        #expect(GameRef(parsing: text) == nil)
    }

    @Test("id-shaped text is an id, even though it is also slug-shaped")
    func idWinsOverSlug() {
        // Same rule as the server: a public-id shape always reads as an id.
        #expect(GameRef(parsing: "g_0123456789") == .gameID("g_0123456789"))
        // `u` is not in Crockford base32, so this one is only a slug.
        #expect(GameRef(parsing: "g_uuuuuuuuuu") == .slug("g_uuuuuuuuuu"))
    }

    @Test("apiValue round-trips through parsing")
    func roundTrip() throws {
        let refs: [GameRef] = [.gameID("g_7k2m9q4xzt"), .slug("celeste"), .store(.epic, id: "fn")]
        for ref in refs {
            // `try #require` stops the test right here if the value is nil,
            // instead of carrying on with a meaningless comparison.
            let parsed = try #require(GameRef(parsing: ref.apiValue))
            #expect(parsed == ref)
        }
    }
}

@Suite("DetectedGame")
struct DetectedGameTests {
    @Test func steamGamesHaveADefaultReference() {
        let game = DetectedGame(id: "/Games/Hades", name: "Hades", source: .steam(appID: 1_145_360))
        #expect(game.defaultRef == .store(.steam, id: "1145360"))
    }

    @Test func appStoreGamesNeedAMapping() {
        let game = DetectedGame(
            id: "com.dinopoloclub.minimotorways.macos",
            name: "Mini Motorways",
            source: .appStore(adamID: 1_456_188_526)
        )
        #expect(game.defaultRef == nil)
    }
}
