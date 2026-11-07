// SourceVerifier.swift
// NEW_IMPLEMENTATION | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Verifies that a reminder list's source identity and type meet the iCloud requirements
// and match bound list configurations.
//
// FIX-R4A-02: Content reads MUST call verify(...) before returning data.
//             Lists from Local, Exchange, or with mismatched source IDs are rejected
//             prior to any item retrieval.

import Foundation

/// Verifies that a reminder list's underlying source identity, source type, and list binding
/// satisfy strict iCloud integrity requirements.
///
/// - Upgraded in AG-01: Validates actual source identity (sourceID UUID), source type (e.g. calDAV),
///   and explicit binding to listID, rejecting unknown, local, or inconsistent sources.
public struct SourceVerifier: Sendable {

    /// Permitted underlying source types (e.g. "calDAV", "iCloud"). Case-insensitive.
    private let allowedSourceTypes: Set<String>

    /// Permitted source titles (e.g. "iCloud"). Case-sensitive.
    private let allowedSourceTitles: Set<String>

    /// Permitted explicit source identifiers (UUIDs). If empty, any valid calDAV source is allowed.
    private let allowedSourceIDs: Set<String>

    /// Explicit list ID to expected SourceIdentity binding map.
    private let listBindings: [String: SourceIdentity]

    /// Whether strict list binding is enforced (every accessed list must have a pre-registered binding).
    private let requireExplicitBinding: Bool

    /// Initializes a comprehensive SourceVerifier.
    public init(
        allowedSourceTypes: Set<String> = ["caldav", "icloud"],
        allowedSourceTitles: Set<String> = ["iCloud"],
        allowedSourceIDs: Set<String> = [],
        listBindings: [String: SourceIdentity] = [:],
        requireExplicitBinding: Bool = false
    ) {
        precondition(!allowedSourceTypes.isEmpty, "allowedSourceTypes must not be empty")
        precondition(!allowedSourceTitles.isEmpty, "allowedSourceTitles must not be empty")
        self.allowedSourceTypes = Set(allowedSourceTypes.map { $0.lowercased() })
        self.allowedSourceTitles = allowedSourceTitles
        self.allowedSourceIDs = allowedSourceIDs
        self.listBindings = listBindings
        self.requireExplicitBinding = requireExplicitBinding
    }

    /// Convenience initializer taking allowed source titles for backward compatibility.
    public init(allowedSources: Set<String>) {
        precondition(!allowedSources.isEmpty, "allowedSources must not be empty")
        self.allowedSourceTypes = ["caldav", "icloud"]
        self.allowedSourceTitles = allowedSources
        self.allowedSourceIDs = []
        self.listBindings = [:]
        self.requireExplicitBinding = false
    }

    /// Verifies source identity, source type, and list ID binding before content access.
    public func verify(
        listID: String,
        sourceID: String,
        sourceType: String,
        sourceTitle: String
    ) throws {
        // 1. Check Source Type (calDAV vs local/exchange/etc.)
        let normalizedType = sourceType.lowercased()
        guard allowedSourceTypes.contains(normalizedType) else {
            throw EventKitBridgeError.sourceNotAllowed
        }

        // 2. Check Source Title
        guard allowedSourceTitles.contains(sourceTitle) else {
            throw EventKitBridgeError.sourceNotAllowed
        }

        // 3. Check Source ID allowlist if configured
        if !allowedSourceIDs.isEmpty && !allowedSourceIDs.contains(sourceID) {
            throw EventKitBridgeError.sourceNotAllowed
        }

        // 4. Verify explicit list binding
        if let expectedBinding = listBindings[listID] {
            if expectedBinding.sourceID != sourceID ||
               expectedBinding.sourceType.lowercased() != normalizedType {
                throw EventKitBridgeError.sourceMismatch
            }
        } else if requireExplicitBinding {
            throw EventKitBridgeError.sourceMismatch
        }
    }

    /// Helper verifying a RemindersList value directly.
    public func verify(list: RemindersList) throws {
        try verify(
            listID: list.listID,
            sourceID: list.sourceID,
            sourceType: list.sourceType,
            sourceTitle: list.sourceName
        )
    }

    /// Legacy convenience verification by title only.
    public func verify(sourceName: String) throws {
        guard allowedSourceTitles.contains(sourceName) else {
            throw EventKitBridgeError.sourceNotAllowed
        }
    }

    /// Non-throwing check for source title.
    public func isAllowed(sourceName: String) -> Bool {
        allowedSourceTitles.contains(sourceName)
    }

    /// Non-throwing check for full identity and binding.
    public func isAllowed(
        listID: String,
        sourceID: String,
        sourceType: String,
        sourceTitle: String
    ) -> Bool {
        do {
            try verify(listID: listID, sourceID: sourceID, sourceType: sourceType, sourceTitle: sourceTitle)
            return true
        } catch {
            return false
        }
    }
}
