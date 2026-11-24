import Testing
@testable import ScrobblerCore

@Suite("ValveKeyValues")
struct ValveKeyValuesTests {
    @Test func parsesAnAppManifest() throws {
        // A *multi-line string literal*: three quotes, and the closing """
        // sets the indentation that gets stripped from every line.
        let text = """
        "AppState"
        {
            "appid"       "330020"
            "name"        "Children of Morta"
            "installdir"  "ChildrenOfMorta"
            "UserConfig"
            {
                "language"  "english"
            }
        }
        """
        let root = try ValveKeyValues.parse(text)
        #expect(root["AppState", "appid"]?.string == "330020")
        #expect(root["AppState", "name"]?.string == "Children of Morta")
        #expect(root["AppState", "UserConfig", "language"]?.string == "english")
        #expect(root["AppState", "missing"] == nil)
    }

    @Test func handlesEscapesAndComments() throws {
        // `#"…"#` is a *raw string*: backslashes are taken literally, so the
        // VDF escapes reach the parser exactly as Steam writes them.
        let text = #"""
        // a comment line
        "path"   "C:\\Games\\Steam"   // trailing comment
        "quote"  "say \"hi\""
        """#
        let root = try ValveKeyValues.parse(text)
        #expect(root["path"]?.string == #"C:\Games\Steam"#)
        #expect(root["quote"]?.string == #"say "hi""#)
    }

    // `#expect(throws:)` passes only if the code throws that exact error.
    @Test func reportsAMissingCloseBrace() {
        #expect(throws: ValveKeyValues.ParseError.unexpectedEnd) {
            try ValveKeyValues.parse(#""AppState" { "appid" "1""#)
        }
    }

    @Test func reportsAStrayCloseBrace() {
        #expect(throws: ValveKeyValues.ParseError.unexpectedCloseBrace(line: 2)) {
            try ValveKeyValues.parse("\"a\" \"b\"\n}")
        }
    }
}
