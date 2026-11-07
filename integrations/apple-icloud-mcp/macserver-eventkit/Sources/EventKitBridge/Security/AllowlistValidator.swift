// AllowlistValidator.swift
// NEW_IMPLEMENTATION | FIX-R4A-01
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Exact-match allowlist validator for reminder list IDs.
//
// FIX-R4A-01: Validation is by exact list ID only. Name-based guessing or
//             partial matching is explicitly prohibited.

import Foundation

/// Validates reminder list IDs against an exact-match allowlist.
///
/// Only explicitly allowlisted list IDs may be accessed. Name-based lookup,
/// prefix matching, or wildcard patterns are forbidden.
///
/// FIX-R4A-01: This is the gating mechanism that prevents metadata-only paths
/// from accidentally fetching reminder content. Callers must pass validation
/// before any content operation is attempted.
public struct AllowlistValidator: Sendable {

    /// The exact set of permitted list IDs.
    private let allowedIDs: Set<String>

    /// - Parameter allowedIDs: Exact list identifiers that are permitted.
    ///   These must be stable EKCalendar identifiers, not display names.
    public init(allowedIDs: Set<String>) {
        self.allowedIDs = allowedIDs
    }

    /// Validates a list ID against the exact-match allowlist.
    ///
    /// - Parameter listID: The list ID to validate.
    /// - Throws: ``EventKitBridgeError.listNotAllowed`` if the ID is not on the allowlist.
    ///
    /// - Note: This performs SET MEMBERSHIP only. No string prefix, suffix,
    ///   or fuzzy matching is performed. This is intentional per FIX-R4A-01.
    public func validate(listID: String) throws {
        guard allowedIDs.contains(listID) else {
            // Do NOT include the listID in the error message (desensitization).
            throw EventKitBridgeError.listNotAllowed
        }
    }

    /// Returns whether a list ID is on the allowlist (non-throwing variant).
    public func isAllowed(listID: String) -> Bool {
        allowedIDs.contains(listID)
    }

    /// Total number of allowlisted IDs.
    public var count: Int { allowedIDs.count }
}
