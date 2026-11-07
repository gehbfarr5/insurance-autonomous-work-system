// RemindersList.swift
// NEW_IMPLEMENTATION | FIX-R4A-01 | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Reminder list metadata type.
// FIX-R4A-01: This type contains ONLY list-level metadata.
//             It deliberately omits reminderCount and any content fields.

import Foundation

/// Identity and type specification for an EventKit source.
public struct SourceIdentity: Sendable, Codable, Equatable, Hashable {
    /// Opaque source identifier (UUID, from EKSource.sourceIdentifier).
    public let sourceID: String

    /// Underlying source type (e.g. "calDAV", "local", "exchange").
    public let sourceType: String

    /// Human-readable title of the source (e.g. "iCloud").
    public let sourceTitle: String

    public init(
        sourceID: String,
        sourceType: String = "calDAV",
        sourceTitle: String = "iCloud"
    ) {
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.sourceTitle = sourceTitle
    }
}

/// Metadata for a single reminder list (EKCalendar of type Reminder).
///
/// - FIX-R4A-01: `reminderCount` is intentionally absent. Callers that need
///   count information must call `fetchReminders(listID:)` explicitly, which
///   triggers source identity and type verification (FIX-R4A-02) and increments `contentAccessCount`.
public struct RemindersList: Sendable, Codable, Equatable {

    /// Opaque, stable identifier for this list (from EKCalendar.calendarIdentifier).
    public let listID: String

    /// Human-readable title of the list.
    public let title: String

    /// Unique source identifier (from EKSource.sourceIdentifier).
    public let sourceID: String

    /// Source type representation (e.g. "calDAV", "local").
    public let sourceType: String

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
        sourceID: String = "source-icloud-default",
        sourceType: String = "calDAV",
        sourceName: String = "iCloud",
        color: String = "",
        isImmutable: Bool = true
    ) {
        self.listID = listID
        self.title = title
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.sourceName = sourceName
        self.color = color
        self.isImmutable = isImmutable
    }
}
