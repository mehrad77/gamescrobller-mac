import Foundation
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
        ("apple:1456188526", GameRef.store(.apple, id: "1456188526")),
    ])
    func parsesValid(text: String, expected: GameRef) {
        #expect(GameRef(parsing: text) == expected)
    }

    @Test("rejects invalid references", arguments: [
        "",                        // empty
        "570",                     // numeric ids are not sent (PR 442)
        "mini motorways",          // contains a space
        "-starts-with-dash",       // a slug must start with a letter or digit
        "steam:",                  // store without an id
        "Steam:570",               // prefixes are lowercase, as on the server
        "s:1",                     // a prefix has at least 2 characters
        "steam:570#x",             // `#` is not allowed in a store id
        "steam:a:b",               // nor is a second colon
        String(repeating: "a", count: 201), // over the server's 200-char limit
    ])
    func rejectsInvalid(text: String) {
        #expect(GameRef(parsing: text) == nil)
    }

    @Test("accepts any well-formed store prefix, not just the ones the app writes")
    func acceptsOtherStores() throws {
        // The server knows stores this app never produces; it decides whether
        // a prefix is known, so the parser only checks the shape.
        for text in ["xbox:1234567890", "itch:some-game", "amazon:amzn1.adg.product.x"] {
            let ref = try #require(GameRef(parsing: text))
            #expect(ref.apiValue == text)
        }
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

    @Test("goes into JSON as its text, and comes back")
    func jsonRoundTrip() throws {
        let refs: [GameRef] = [.gameID("g_7k2m9q4xzt"), .slug("mini-motorways"), .store(.apple, id: "1456188526")]
        let data = try JSONEncoder().encode(refs)
        #expect(String(decoding: data, as: UTF8.self) == #"["g_7k2m9q4xzt","mini-motorways","apple:1456188526"]"#)
        #expect(try JSONDecoder().decode([GameRef].self, from: data) == refs)
    }

    @Test("a damaged reference in JSON is an error")
    func damagedJSON() {
        // `#expect(throws:)` passes only if the closure throws that error type.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([GameRef].self, from: Data(#"["steam:"]"#.utf8))
        }
    }
}

@Suite("DetectedGame")
struct DetectedGameTests {
    @Test func steamGamesHaveADefaultReference() {
        let game = DetectedGame(id: "/Games/Hades", name: "Hades", source: .steam(appID: 1_145_360))
        #expect(game.defaultRef == .store(.steam, id: "1145360"))
    }

    @Test func appStoreGamesUseTheirAppleID() {
        let game = DetectedGame(
            id: "com.dinopoloclub.minimotorways.macos",
            name: "Mini Motorways",
            source: .appStore(adamID: 1_456_188_526)
        )
        #expect(game.defaultRef == .store(.apple, id: "1456188526"))
    }
}
