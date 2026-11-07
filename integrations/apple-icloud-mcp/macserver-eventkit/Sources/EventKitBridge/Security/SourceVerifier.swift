// SourceVerifier.swift
// NEW_IMPLEMENTATION | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Verifies that a reminder list's source is an allowed iCloud source.
//
// FIX-R4A-02: Content reads MUST call verify(sourceName:) before returning data.
//             Lists from Local, Exchange, or other non-iCloud sources are rejected.

import Foundation

/// Verifies that a reminder list's source name is in the permitted iCloud sources set.
///
/// FIX-R4A-02: All content access paths in EventKitBridge must call this verifier
/// before returning any reminder items. Lists whose source does not match the
/// allowedSources set must be rejected with ``EventKitBridgeError.sourceNotAllowed``.
public struct SourceVerifier: Sendable {

    /// The set of source names considered valid iCloud sources.
    /// Default: ["iCloud"] — covers both personal and Family Sharing calendars.
    private let allowedSources: Set<String>

    /// - Parameter allowedSources: Source names that pass verification.
    ///   Must not be empty. Names are compared case-sensitively.
    public init(allowedSources: Set<String> = ["iCloud"]) {
        precondition(!allowedSources.isEmpty, "allowedSources must not be empty")
        self.allowedSources = allowedSources
    }

    /// Verifies that a source name is permitted.
    ///
    /// - Parameter sourceName: The source name from EKCalendar.source.title or RemindersList.sourceName.
    /// - Throws: ``EventKitBridgeError.sourceNotAllowed`` if the source is not permitted.
    ///
    /// FIX-R4A-02: This method MUST be called before returning any reminder item content.
    public func verify(sourceName: String) throws {
        guard allowedSources.contains(sourceName) else {
            // Do NOT include sourceName in the error message (desensitization).
            throw EventKitBridgeError.sourceNotAllowed
        }
    }

    /// Returns whether a source name passes verification (non-throwing variant).
    public func isAllowed(sourceName: String) -> Bool {
        allowedSources.contains(sourceName)
    }
}
