import Foundation

/// How long to pause scrobbling for, as the menu offers it.
public enum PauseLength: CaseIterable, Sendable {
    case oneHour
    case untilTomorrow
    case untilResumed

    /// When the pause ends, counted from `now`; nil when only you end it.
    /// "Tomorrow" is the start of the next day on your calendar (midnight,
    /// in your time zone), so a late-evening pause ends at midnight.
    ///
    /// The calendar is a parameter so tests can fix the time zone.
    public func end(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour:
            return now + 60 * 60
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: today)
        case .untilResumed:
            return nil
        }
    }
}
