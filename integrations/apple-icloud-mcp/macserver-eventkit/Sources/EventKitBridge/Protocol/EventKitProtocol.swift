// EventKitProtocol.swift
// NEW_IMPLEMENTATION | FIX-R4A-01 | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Defines the replaceable interface for EventKit access.
// All callers must use this protocol — never concrete EK types directly.
//
// FIX-R4A-01: fetchListsMetadata() must NOT return reminder counts or content.
//             Only list-level metadata (ID, title, source, color) is permitted.
// FIX-R4A-02: fetchReminders(listID:) must verify the iCloud source before
//             returning any reminder data.

import Foundation

/// The single access point for EventKit operations in this bridge.
/// Implementors: FakeEventKitStore (tests), ProductionEventKitStore (gated).
///
/// - Note: This protocol is intentionally read-only. No write methods exist.
///         Write requests are rejected at the HTTP layer (see EventKitBridgeServer).
public protocol EventKitStoreProtocol: Sendable {

    // MARK: — Metadata only (FIX-R4A-01)

    /// Returns reminder list metadata WITHOUT fetching reminder content or counts.
    ///
    /// - FIX-R4A-01: Implementations MUST NOT touch reminder items or their count
    ///   during this call. The returned [RemindersList] contains only list-level metadata.
    /// - Returns: Array of reminder list metadata objects.
    /// - Throws: ``EventKitBridgeError`` on permission or access failure.
    func fetchListsMetadata() async throws -> [RemindersList]

    // MARK: — Content (FIX-R4A-02 gated)

    /// Returns reminders for a specific list, verifying the iCloud source first.
    ///
    /// - FIX-R4A-02: Implementations MUST call ``SourceVerifier`` before returning
    ///   any reminder items. If the list is not from a verified iCloud source, this
    ///   method MUST throw ``EventKitBridgeError.sourceNotAllowed``.
    /// - Parameter listID: The allowlist-validated list identifier.
    /// - Returns: Array of reminder items (read-only snapshot).
    /// - Throws: ``EventKitBridgeError`` on permission, source, or access failure.
    func fetchReminders(listID: String) async throws -> [ReminderItem]

    // MARK: — Diagnostics (for test assertions)

    /// Count of times reminder content was accessed. Must be 0 in metadata-only tests.
    var contentAccessCount: Int { get async }

    /// Resets all diagnostic counters. Call between test cases.
    func resetCounters() async
}
