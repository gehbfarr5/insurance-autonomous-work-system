// ReminderItem.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Read-only reminder content type.
// Only returned after FIX-R4A-02 source verification passes.

import Foundation

/// A read-only snapshot of a single reminder item.
///
/// This type is only vended by `fetchReminders(listID:)` after source verification.
/// It is never constructed during metadata-only paths (FIX-R4A-01).
public struct ReminderItem: Sendable, Codable, Equatable {

    /// Stable identifier (from EKReminder.calendarItemIdentifier).
    public let itemID: String

    /// Title of the reminder.
    public let title: String

    /// Whether the reminder is marked complete.
    public let isCompleted: Bool

    /// Due date, if set.
    public let dueDate: Date?

    /// Priority (0 = none, 1 = high, 5 = medium, 9 = low — matches EKReminderPriority).
    public let priority: Int

    /// Notes / description field.
    public let notes: String?

    /// The list ID this reminder belongs to.
    public let listID: String

    /// Whether the reminder is an all-day reminder (no specific hour/minute).
    public let isAllDay: Bool

    /// TimeZone identifier (e.g. "Asia/Shanghai" or "America/New_York"), if set.
    public let timeZone: String?

    /// Completion date, if completed.
    public let completionDate: Date?

    /// Creation date of the reminder.
    public let creationDate: Date?

    /// Last modification date.
    public let lastModifiedDate: Date?

    /// Associated URL string, if any.
    public let url: String?

    public init(
        itemID: String,
        title: String,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        listID: String,
        isAllDay: Bool = false,
        timeZone: String? = nil,
        completionDate: Date? = nil,
        creationDate: Date? = nil,
        lastModifiedDate: Date? = nil,
        url: String? = nil
    ) {
        self.itemID           = itemID
        self.title            = title
        self.isCompleted      = isCompleted
        self.dueDate          = dueDate
        self.priority         = priority
        self.notes            = notes
        self.listID           = listID
        self.isAllDay         = isAllDay
        self.timeZone         = timeZone
        self.completionDate   = completionDate
        self.creationDate     = creationDate
        self.lastModifiedDate = lastModifiedDate
        self.url              = url
    }
}
