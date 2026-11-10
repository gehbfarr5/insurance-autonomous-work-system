// ReminderDateMapper.swift
// AG-05 | feat/ag05-resident-readonly-candidate
//
// Pure, testable mapping logic for Apple EventKit EKReminder DateComponents.
// Preserves exact user calendar semantics:
// - All-Day events (hour == nil)
// - Timed events with explicit timeZone
// - Timed events with default calendar timeZone
// - DST boundary handling

import Foundation

public struct ReminderDateComponentsSnapshot: Sendable, Equatable {
    public let date: Date?
    public let isAllDay: Bool
    public let timeZoneIdentifier: String?

    public init(date: Date?, isAllDay: Bool, timeZoneIdentifier: String?) {
        self.date = date
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum ReminderDateMapper {
    /// Maps EKReminder.dueDateComponents into normalized date, all-day flag, and timezone identifier.
    public static func mapDueDate(components: DateComponents?) -> ReminderDateComponentsSnapshot {
        guard let components = components else {
            return ReminderDateComponentsSnapshot(date: nil, isAllDay: false, timeZoneIdentifier: nil)
        }

        // An all-day reminder in Apple EventKit has year, month, day, but nil hour and minute.
        let isAllDay = (components.hour == nil)
        let tzIdentifier = components.timeZone?.identifier
        let computedDate = components.date

        return ReminderDateComponentsSnapshot(
            date: computedDate,
            isAllDay: isAllDay,
            timeZoneIdentifier: tzIdentifier
        )
    }

    /// Helper to construct DateComponents with precise calendar and timezone semantics.
    public static func constructComponents(
        year: Int,
        month: Int,
        day: Int,
        hour: Int? = nil,
        minute: Int? = nil,
        second: Int? = nil,
        timeZone: TimeZone? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> DateComponents {
        var comp = DateComponents()
        comp.calendar = calendar
        comp.timeZone = timeZone
        comp.year = year
        comp.month = month
        comp.day = day
        comp.hour = hour
        comp.minute = minute
        comp.second = second
        return comp
    }
}
