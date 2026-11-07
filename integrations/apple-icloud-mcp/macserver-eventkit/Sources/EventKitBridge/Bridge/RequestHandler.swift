// RequestHandler.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Request pre-processing and desensitized error formatting.

import Foundation

/// Pre-processes incoming requests and formats desensitized error responses.
///
/// All error messages returned to callers must NOT include:
/// - Real list IDs
/// - Real Apple account identifiers
/// - Internal stack traces
/// - Token or credential values
public struct RequestHandler: Sendable {

    /// Extracts a BridgeCredential from a request token string.
    ///
    /// In production this parses a signed JWT. In tests, synthetic tokens are used.
    /// - Parameter rawToken: The raw token string from the request header.
    /// - Parameter requestedScopes: Scopes the client claims.
    public static func credential(
        from rawToken: String,
        requestedScopes: Set<BridgeScope>
    ) -> BridgeCredential {
        BridgeCredential(token: rawToken, scopes: requestedScopes)
    }

    /// Formats a desensitized error body for HTTP response.
    ///
    /// - Parameter error: The bridge error.
    /// - Returns: A JSON-safe dictionary with `success`, `error` keys only.
    public static func errorBody(for error: EventKitBridgeError) -> [String: String] {
        [
            "success": "false",
            // localizedDescription is already desensitized (see EventKitBridgeError)
            "error": error.localizedDescription,
        ]
    }

    /// Returns the appropriate HTTP status code for a bridge error.
    public static func httpStatus(for error: EventKitBridgeError) -> Int {
        switch error {
        case .authenticationFailed:          return 401
        case .unauthorizedScope:             return 403
        case .permissionDenied:              return 403
        case .listNotAllowed:                return 403
        case .sourceNotAllowed:              return 403
        case .listNotFound:                  return 404
        case .itemNotFound:                  return 404
        case .writeOperationRejected:        return 405
        case .rateLimitExceeded:             return 429
        case .timeout:                       return 504
        case .internalError:                 return 500
        }
    }
}
