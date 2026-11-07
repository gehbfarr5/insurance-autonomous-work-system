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

    public init(
        itemID: String,
        title: String,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        listID: String
    ) {
        self.itemID      = itemID
        self.title       = title
        self.isCompleted = isCompleted
        self.dueDate     = dueDate
        self.priority    = priority
        self.notes       = notes
        self.listID      = listID
    }
}
