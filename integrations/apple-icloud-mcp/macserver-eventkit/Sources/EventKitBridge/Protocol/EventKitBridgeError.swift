// EventKitBridgeError.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Canonical error type for all EventKitBridge failures.
// All errors are desensitized — no real IDs, tokens, or Apple account data
// appear in localizedDescription.

import Foundation

/// All errors that can be thrown by EventKitBridge components.
public enum EventKitBridgeError: Error, Sendable, Equatable {

    // MARK: — Auth / Permission

    /// TCC permission not granted or was revoked.
    case permissionDenied

    /// Authentication failed: invalid token, missing token, or scope mismatch.
    case authenticationFailed(reason: String)

    /// The session or request is not authorized for the requested scope.
    case unauthorizedScope

    // MARK: — Allowlist (FIX-R4A-01 / FIX-R4A-02)

    /// The requested list ID is not on the exact-match allowlist.
    case listNotAllowed

    /// The list's source does not match the required iCloud source.
    /// FIX-R4A-02: returned when source verification fails.
    case sourceNotAllowed

    // MARK: — Not Found / Missing

    /// The requested list ID was not found in the EventKit store.
    case listNotFound

    /// The requested reminder item was not found.
    case itemNotFound

    // MARK: — Write Rejection

    /// A write operation was attempted. This bridge is read-only.
    case writeOperationRejected

    // MARK: — Rate Limiting

    /// The request rate limit has been exceeded.
    case rateLimitExceeded

    // MARK: — Infrastructure

    /// The underlying EventKit store timed out.
    case timeout

    /// An unexpected internal error. Message is desensitized.
    case internalError(String)

    // MARK: — Desensitized description

    public var localizedDescription: String {
        switch self {
        case .permissionDenied:
            return "EventKit access permission was denied or revoked."
        case .authenticationFailed:
            return "Authentication failed. Check your credentials."
        case .unauthorizedScope:
            return "Request is not authorized for the required scope."
        case .listNotAllowed:
            return "The specified list is not on the allowlist."
        case .sourceNotAllowed:
            return "The list source does not meet the iCloud source requirement."
        case .listNotFound:
            return "The specified reminder list was not found."
        case .itemNotFound:
            return "The specified reminder item was not found."
        case .writeOperationRejected:
            return "Write operations are not permitted on this bridge."
        case .rateLimitExceeded:
            return "Request rate limit exceeded. Please retry after a delay."
        case .timeout:
            return "The EventKit store request timed out."
        case .internalError(let msg):
            return "Internal error: \(msg)"
        }
    }
}
