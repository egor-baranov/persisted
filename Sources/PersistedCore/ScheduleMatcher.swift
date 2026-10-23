import Foundation

/// Local wall-clock minutes, with Calendar weekday numbers (1 = Sunday).
/// An overnight range belongs to the weekday on which it starts.
public struct LayoutSchedule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var layoutID: UUID
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, layoutID: UUID, weekdays: Set<Int>, startMinute: Int,
                endMinute: Int, enabled: Bool = true) {
        self.id = id; self.name = name; self.layoutID = layoutID; self.weekdays = weekdays
        self.startMinute = startMinute; self.endMinute = endMinute; self.enabled = enabled
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200
            && !weekdays.isEmpty && weekdays.isSubset(of: Set(1...7))
            && (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && startMinute != endMinute
    }
}

public struct ScheduleOccurrence: Hashable, Sendable {
    public var scheduleID: UUID
    public var layoutID: UUID
    public var startDate: Date

    public init(scheduleID: UUID, layoutID: UUID, startDate: Date) {
        self.scheduleID = scheduleID; self.layoutID = layoutID; self.startDate = startDate
    }
}

public enum ScheduleMatcher {
    /// First matching rule wins. Start is inclusive and end is exclusive.
    /// Missing DST wall times advance to the next valid time; repeated times use their first occurrence.
    public static func activeOccurrence(schedules: [LayoutSchedule], at date: Date,
                                        calendar: Calendar = .current) -> ScheduleOccurrence? {
        let today = calendar.startOfDay(for: date)
        for schedule in schedules where schedule.enabled && schedule.isValid {
            let startDays = schedule.startMinute > schedule.endMinute
                ? [today, calendar.date(byAdding: .day, value: -1, to: today)].compactMap { $0 }
                : [today]
            for startDay in startDays where schedule.weekdays.contains(calendar.component(.weekday, from: startDay)) {
                guard let start = time(schedule.startMinute, on: startDay, calendar: calendar) else { continue }
                let endDay = schedule.startMinute > schedule.endMinute
                    ? calendar.date(byAdding: .day, value: 1, to: startDay) : startDay
                guard let endDay, let end = time(schedule.endMinute, on: endDay, calendar: calendar),
                      start <= date, date < end else { continue }
                return ScheduleOccurrence(scheduleID: schedule.id, layoutID: schedule.layoutID, startDate: start)
            }
        }
        return nil
    }

    private static func time(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}
