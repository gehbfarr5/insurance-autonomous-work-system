// RemindersList.swift
// NEW_IMPLEMENTATION | FIX-R4A-01
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Reminder list metadata type.
// FIX-R4A-01: This type contains ONLY list-level metadata.
//             It deliberately omits reminderCount and any content fields.

import Foundation

/// Metadata for a single reminder list (EKCalendar of type Reminder).
///
/// - FIX-R4A-01: `reminderCount` is intentionally absent. Callers that need
///   count information must call `fetchReminders(listID:)` explicitly, which
///   triggers source verification (FIX-R4A-02) and increments `contentAccessCount`.
public struct RemindersList: Sendable, Codable, Equatable {

    /// Opaque, stable identifier for this list (from EKCalendar.calendarIdentifier).
    public let listID: String

    /// Human-readable title of the list.
    public let title: String

    /// Source name (e.g. "iCloud", "Local", "Exchange").
    /// Used by SourceVerifier to enforce FIX-R4A-02.
    public let sourceName: String

    /// Hex color string of the list (e.g. "#FF2D55"). May be empty.
    public let color: String

    /// Whether this list allows modifications in EventKit.
    /// Always `false` for the bridge's read-only posture.
    public let isImmutable: Bool

    public init(
        listID: String,
        title: String,
        sourceName: String,
        color: String = "",
        isImmutable: Bool = true
    ) {
        self.listID  = listID
        self.title   = title
        self.sourceName = sourceName
        self.color   = color
        self.isImmutable = isImmutable
    }
}
