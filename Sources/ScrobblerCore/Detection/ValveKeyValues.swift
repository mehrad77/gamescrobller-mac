/// A parser for Valve's "KeyValues" text format, used by Steam's `.vdf` and
/// `.acf` files:
///
///     "AppState"
///     {
///         "appid"       "330020"
///         "name"        "Children of Morta"
///         "installdir"  "ChildrenOfMorta"
///     }
///
/// A value is either a string or a nested block of more key/value pairs.
public enum ValveKeyValues {
    /// `indirect` lets an enum contain itself (a block holds more values).
    /// Without it Swift could not work out how much memory a value needs.
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case block([String: Value])

        /// Reads a nested value by path: `root["AppState", "appid"]`.
        /// A *subscript* is what makes `thing[...]` syntax work on a type, and
        /// variadic `String...` accepts any number of keys.
        public subscript(_ path: String...) -> Value? {
            var current: Value? = self
            for key in path {
                guard case .block(let entries)? = current else { return nil }
                current = entries[key]
            }
            return current
        }

        /// The text of a `.string` value, or nil for a block.
        public var string: String? {
            if case .string(let text) = self { return text }
            return nil
        }
    }

    /// Errors are plain types that conform to the `Error` protocol; an enum is
    /// the usual choice. Associated values carry the details.
    public enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpectedCharacter(Character, line: Int)
        case unexpectedCloseBrace(line: Int)
    }

    /// Parses a whole file into one top-level block.
    /// `throws` lets the caller decide what to do with a broken file.
    public static func parse(_ text: String) throws -> Value {
        var parser = Parser(text: text)
        return .block(try parser.parseEntries(untilCloseBrace: false))
    }

    /// The parser keeps its position in the text, so its methods change it:
    /// on a struct those must be marked `mutating`.
    private struct Parser {
        let characters: [Character]
        var index = 0
        var line = 1

        init(text: String) { characters = Array(text) }

        mutating func parseEntries(untilCloseBrace: Bool) throws -> [String: Value] {
            var entries: [String: Value] = [:]
            while true {
                skipWhitespaceAndComments()
                guard index < characters.count else {
                    // End of text is fine at the top level, an error inside { }.
                    if untilCloseBrace { throw ParseError.unexpectedEnd }
                    return entries
                }
                if characters[index] == "}" {
                    guard untilCloseBrace else { throw ParseError.unexpectedCloseBrace(line: line) }
                    index += 1
                    return entries
                }
                let key = try parseToken()
                skipWhitespaceAndComments()
                guard index < characters.count else { throw ParseError.unexpectedEnd }
                if characters[index] == "{" {
                    index += 1
                    entries[key] = .block(try parseEntries(untilCloseBrace: true))
                } else {
                    entries[key] = .string(try parseToken())
                }
            }
        }

        /// A quoted string (with \" \\ \n \t escapes) or a bare word.
        mutating func parseToken() throws -> String {
            guard index < characters.count else { throw ParseError.unexpectedEnd }
            let first = characters[index]
            if first == "{" || first == "}" {
                throw ParseError.unexpectedCharacter(first, line: line)
            }
            if first != "\"" {
                var word = ""
                while index < characters.count, !characters[index].isWhitespace,
                      !"{}\"".contains(characters[index]) {
                    word.append(characters[index])
                    index += 1
                }
                return word
            }
            index += 1  // opening quote
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                switch character {
                case "\"":
                    return text
                case "\\" where index < characters.count:
                    let escaped = characters[index]
                    index += 1
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    default: text.append(escaped)  // \" and \\ and anything else
                    }
                default:
                    if character.isNewline { line += 1 }
                    text.append(character)
                }
            }
            throw ParseError.unexpectedEnd
        }

        mutating func skipWhitespaceAndComments() {
            while index < characters.count {
                let character = characters[index]
                if character.isNewline {
                    line += 1
                    index += 1
                } else if character.isWhitespace {
                    index += 1
                } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    // A // comment runs to the end of the line.
                    while index < characters.count, !characters[index].isNewline { index += 1 }
                } else {
                    return
                }
            }
        }
    }
}
