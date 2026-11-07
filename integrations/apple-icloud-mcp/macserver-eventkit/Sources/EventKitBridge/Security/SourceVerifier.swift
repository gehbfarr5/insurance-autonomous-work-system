// SourceVerifier.swift
// NEW_IMPLEMENTATION | STRICT_IDENTITY_BINDING | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Enforces exact list-to-source identity bindings.
// Name-only fallback is strictly prohibited. Missing bindings, unknown sources,
// or changed source UUIDs trigger immediate rejection prior to content access.

import Foundation

/// Verifies that a reminder list possesses an explicit, verified SourceIdentity binding
/// and satisfies strict iCloud CalDAV protocol requirements.
///
/// - Important: Name-only fallback is explicitly removed. Every list accessed for content
///   MUST have an explicit pre-registered binding matching sourceID, sourceType, and title.
public struct SourceVerifier: Sendable {

    /// Permitted underlying source types (e.g. "caldav"). Case-insensitive.
    private let allowedSourceTypes: Set<String>

    /// Permitted source titles (e.g. "iCloud"). Case-sensitive.
    private let allowedSourceTitles: Set<String>

    /// Explicit list ID to expected SourceIdentity binding map.
    private let listBindings: [String: SourceIdentity]

    /// Enforces that EVERY list accessed must have an explicit pre-registered binding.
    /// In production and offline verification, this is strictly true.
    private let requireExplicitBinding: Bool

    /// Initializes a strict SourceVerifier.
    ///
    /// - Parameters:
    ///   - allowedSourceTypes: Permitted types (defaults to `["caldav"]`).
    ///   - allowedSourceTitles: Permitted titles (defaults to `["iCloud"]`).
    ///   - listBindings: Mandatory mapping of listID -> expected SourceIdentity.
    ///   - requireExplicitBinding: Defaults to `true`. Disallows unmapped lists.
    public init(
        allowedSourceTypes: Set<String> = ["caldav"],
        allowedSourceTitles: Set<String> = ["iCloud"],
        listBindings: [String: SourceIdentity] = [:],
        requireExplicitBinding: Bool = true
    ) {
        precondition(!allowedSourceTypes.isEmpty, "allowedSourceTypes must not be empty")
        precondition(!allowedSourceTitles.isEmpty, "allowedSourceTitles must not be empty")
        self.allowedSourceTypes = Set(allowedSourceTypes.map { $0.lowercased() })
        self.allowedSourceTitles = allowedSourceTitles
        self.listBindings = listBindings
        self.requireExplicitBinding = requireExplicitBinding
    }

    /// Verifies that a list has an exact, registered SourceIdentity binding and that
    /// its presented source properties strictly match the binding.
    ///
    /// - Parameters:
    ///   - listID: The list's identifier.
    ///   - sourceID: The UUID/identifier of the source (e.g. EKSource.sourceIdentifier).
    ///   - sourceType: The underlying source type (e.g. "calDAV", "local").
    ///   - sourceTitle: The human-readable title (e.g. "iCloud").
    /// - Throws:
    ///   - ``EventKitBridgeError.sourceMismatch`` if binding is missing or source properties deviate.
    ///   - ``EventKitBridgeError.sourceNotAllowed`` if type or title is inherently disallowed.
    public func verify(
        listID: String,
        sourceID: String,
        sourceType: String,
        sourceTitle: String
    ) throws {
        // 1. Enforce explicit binding presence (no implicit unmapped access)
        guard let expected = listBindings[listID] else {
            if requireExplicitBinding {
                throw EventKitBridgeError.sourceMismatch
            }
            // If explicit binding not required, basic sanity check
            let normType = sourceType.lowercased()
            guard allowedSourceTypes.contains(normType), allowedSourceTitles.contains(sourceTitle) else {
                throw EventKitBridgeError.sourceNotAllowed
            }
            return
        }

        // 2. Strict exact binding match
        let normalizedType = sourceType.lowercased()
        let expectedNormType = expected.sourceType.lowercased()

        // Source ID check
        guard expected.sourceID == sourceID else {
            throw EventKitBridgeError.sourceMismatch
        }

        // Source type check (e.g. must be calDAV, not local or exchange)
        guard expectedNormType == normalizedType && allowedSourceTypes.contains(normalizedType) else {
            throw EventKitBridgeError.sourceMismatch
        }

        // Source title check
        guard expected.sourceTitle == sourceTitle && allowedSourceTitles.contains(sourceTitle) else {
            throw EventKitBridgeError.sourceMismatch
        }
    }

    /// Verifies a RemindersList directly using its embedded metadata.
    public func verify(list: RemindersList) throws {
        try verify(
            listID: list.listID,
            sourceID: list.sourceID,
            sourceType: list.sourceType,
            sourceTitle: list.sourceName
        )
    }

    /// Non-throwing verification predicate.
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
