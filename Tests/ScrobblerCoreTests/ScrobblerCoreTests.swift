import Testing

// `@testable` also exposes `internal` (non-public) declarations to the tests.
@testable import ScrobblerCore

@Test func versionIsSemantic() {
    let parts = ScrobblerCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
