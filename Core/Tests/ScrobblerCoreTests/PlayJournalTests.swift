import Foundation
import Testing
@testable import ScrobblerCore

/// 2026-11-25T18:00:00Z. Whole seconds, like every time the journal keeps.
private let t0 = Date(timeIntervalSince1970: 1_795_629_600)

private let motorways = DetectedGame(
    id: "com.dinopoloclub.minimotorways.macos",
    name: "Mini Motorways",
    source: .appStore(adamID: 1_456_188_526)
)
private let morta = DetectedGame(id: "/Steam/ChildrenOfMorta", name: "Children of Morta", source: .steam(appID: 330_020))

/// A play the server has, which ended and still needs its finish.
private let finished = Play(
    id: "c1", game: morta, ref: morta.defaultRef,
    startedAt: t0, lastSeenAt: t0 + 1_800, endedAt: t0 + 1_800,
    sessionID: "3c1f7a52-9b0e-4d6a-8f21-6e4d2b9c7a10", idempotencyKey: "k2"
)
/// A play still running, whose start has not gone through yet.
private let live = Play(id: "c2", game: motorways, ref: motorways.defaultRef, startedAt: t0 + 1_800, idempotencyKey: "k3")

/// The suite is a `final class` rather than a struct so it can have a
/// `deinit`. Swift Testing makes a new instance for every test and releases
/// it when the test ends, so `deinit` is the place for cleanup ("teardown"):
/// here, deleting the test's own temporary folder.
@Suite("PlayJournal")
final class PlayJournalTests {
    /// A folder no other test or run shares. It does not exist until a save.
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "PlayJournalTests-\(UUID().uuidString)")
    private let journal: PlayJournal

    init() {
        journal = PlayJournal(fileURL: directory.appending(path: "plays.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func noFileMeansNoPlays() throws {
        #expect(try journal.load().isEmpty)
    }

    @Test func savedPlaysComeBackUnchanged() throws {
        // The folder does not exist yet: `save` makes it.
        try journal.save([finished, live])

        #expect(try journal.load() == [finished, live])
    }

    @Test func aSaveReplacesThePreviousList() throws {
        try journal.save([finished, live])
        try journal.save([live])

        #expect(try journal.load() == [live])
    }

    @Test func theFileIsJSONYouCanRead() throws {
        try journal.save([live])

        let text = try String(contentsOf: journal.fileURL, encoding: .utf8)
        // Raw strings, `#"…"#`, keep the quotes inside without escaping them.
        #expect(text.contains(#""startedAt" : "2026-11-25T18:30:00Z""#))
        #expect(text.contains(#""ref" : "apple:1456188526""#))
        // A nil optional is left out of the JSON, not written as `null`.
        #expect(!text.contains("endedAt"))
    }

    @Test func aDamagedFileIsAnErrorNotAnEmptyJournal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a journal".utf8).write(to: journal.fileURL)

        #expect(throws: DecodingError.self) { try self.journal.load() }
    }

    @Test func aDamagedFileCanBeSetAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a journal".utf8).write(to: journal.fileURL)

        try journal.setAside()

        #expect(try journal.load().isEmpty)
        let damaged = directory.appending(path: "plays.damaged.json")
        #expect(try String(contentsOf: damaged, encoding: .utf8) == "not a journal")
    }

    @Test("one file per server", arguments: [
        ("https://api.gamescrobbler.com/v1", "plays-api.gamescrobbler.com.json"),
        ("http://localhost:8000/v1", "plays-localhost-8000.json"),
    ])
    func oneFilePerServer(baseURL: String, fileName: String) throws {
        let url = try #require(URL(string: baseURL))
        let journal = PlayJournal(directory: directory, server: url)
        #expect(journal.fileURL.lastPathComponent == fileName)
        #expect(journal.fileURL.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent)
    }
}
