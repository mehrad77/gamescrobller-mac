import Foundation
import Testing
@testable import ScrobblerCore

@Suite("Pause lengths")
struct PauseLengthTests {
    /// A calendar fixed to one time zone, so the tests pass anywhere.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// 2026-11-25 22:30 in Berlin (21:30 UTC).
    private let lateEvening = Date(timeIntervalSince1970: 1_795_642_200)

    @Test func anHourIsAnHour() {
        #expect(PauseLength.oneHour.end(from: lateEvening, calendar: calendar) == lateEvening + 3600)
    }

    @Test func tomorrowStartsAtMidnight() throws {
        let end = try #require(PauseLength.untilTomorrow.end(from: lateEvening, calendar: calendar))
        let parts = calendar.dateComponents([.day, .hour, .minute], from: end)
        #expect(parts.day == 26)
        #expect(parts.hour == 0)
        #expect(parts.minute == 0)
    }

    @Test func untilResumedHasNoEnd() {
        #expect(PauseLength.untilResumed.end(from: lateEvening, calendar: calendar) == nil)
    }
}
