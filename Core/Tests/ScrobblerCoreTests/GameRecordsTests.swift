import Foundation
import Testing
@testable import ScrobblerCore

@Suite("Game records")
final class GameRecordsTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "GameRecordsTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func anUntouchedGameIsScrobbledAndUnknown() {
        let records = GameRecords()
        #expect(records["mm"] == GameRecord())
        #expect(records.ignoredGames.isEmpty)
    }

    @Test func writingTheDefaultBackForgetsTheGame() {
        var records = GameRecords()
        records["mm"].ignored = true
        records["mm"].ignored = false
        #expect(records == GameRecords())
    }

    @Test func ignoredGamesAreListed() {
        var records = GameRecords()
        records["mm"].ignored = true
        records["cm"].lookup = .notInLibrary
        #expect(records.ignoredGames == ["mm"])
    }

    @Test func theStoreKeepsRecordsAcrossLaunches() throws {
        let store = GameRecordStore(fileURL: directory.appending(path: "games.json"))
        var records = GameRecords()
        records["mm"].lookup = .inLibrary(title: "Mini Motorways", slug: "mini-motorways")
        records["sc"].ignored = true

        try store.save(records)

        #expect(store.load() == records)
    }

    @Test func aMissingOrDamagedFileMeansNoRecords() throws {
        let store = GameRecordStore(fileURL: directory.appending(path: "games.json"))
        #expect(store.load() == GameRecords())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == GameRecords())
    }

    @Test func aFileWithoutSlugsStillLoads() throws {
        let store = GameRecordStore(fileURL: directory.appending(path: "games.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"byGame": {"mm": {"ignored": false, "lookup": {"inLibrary": {"title": "Mini Motorways"}}}}}"#.utf8)
            .write(to: store.fileURL)

        #expect(store.load()["mm"].lookup == .inLibrary(title: "Mini Motorways", slug: nil))
    }

    @Test func oneFilePerServerNextToTheJournal() throws {
        let url = try #require(URL(string: "http://localhost:8000/v1"))
        let store = GameRecordStore(directory: directory, server: url)
        #expect(store.fileURL.lastPathComponent == "games-localhost-8000.json")
    }
}
