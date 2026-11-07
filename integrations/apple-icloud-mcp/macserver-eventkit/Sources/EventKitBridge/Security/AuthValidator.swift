// AuthValidator.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Identity and scope validation for bridge requests.
// No real credentials are stored. All token validation is against
// a configurable in-memory allow set for offline testing.

import Foundation

/// Token scopes supported by the bridge.
public enum BridgeScope: String, Sendable, CaseIterable {
    /// Allows metadata listing (list IDs, titles, sources).
    case listMetadata = "reminders:lists:metadata"
    /// Allows reading reminder content (gated by FIX-R4A-02 source check).
    case reminderRead = "reminders:items:read"
}

/// A validated credential presented with a bridge request.
public struct BridgeCredential: Sendable {
    public let token: String
    public let scopes: Set<BridgeScope>

    public init(token: String, scopes: Set<BridgeScope>) {
        self.token = token
        self.scopes = scopes
    }
}

/// Validates credentials and scopes for bridge requests.
///
/// In production this would verify a signed JWT or session token.
/// In tests, the allowedTokens set controls which tokens are considered valid.
public struct AuthValidator: Sendable {

    /// Tokens considered valid (hashed/opaque — no real credentials).
    private let allowedTokens: Set<String>

    /// - Parameter allowedTokens: Set of valid token strings.
    ///   In tests, use synthetic tokens like "test-token-001".
    public init(allowedTokens: Set<String>) {
        self.allowedTokens = allowedTokens
    }

    /// Validates a credential against the allowed token set and required scope.
    ///
    /// - Parameters:
    ///   - credential: The presented credential.
    ///   - requiredScope: The scope required for the operation.
    /// - Throws:
    ///   - ``EventKitBridgeError.authenticationFailed`` if the token is not recognized.
    ///   - ``EventKitBridgeError.unauthorizedScope`` if the token lacks the required scope.
    public func validate(credential: BridgeCredential, requiredScope: BridgeScope) throws {
        guard allowedTokens.contains(credential.token) else {
            throw EventKitBridgeError.authenticationFailed(reason: "token not recognized")
        }
        guard credential.scopes.contains(requiredScope) else {
            throw EventKitBridgeError.unauthorizedScope
        }
    }

    /// Returns whether a token is known (non-throwing).
    public func isKnownToken(_ token: String) -> Bool {
        allowedTokens.contains(token)
    }
}
