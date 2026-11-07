// EventKitBridgeServer.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// HTTP bridge server — read-only endpoints only.
// All write-method requests (POST, PUT, PATCH, DELETE) are rejected at this layer.

import Foundation

/// Route definitions for the EventKit bridge HTTP API.
public enum BridgeRoute: Sendable {
    case listReminders              // GET /reminders/lists
    case getReminders(listID: String) // GET /reminders/lists/{listID}/items

    public static func parse(method: String, path: String) -> BridgeRoute? {
        // Write methods are rejected immediately (write isolation).
        let upperMethod = method.uppercased()
        guard upperMethod == "GET" else { return nil }

        if path == "/reminders/lists" {
            return .listReminders
        }
        // Pattern: /reminders/lists/{listID}/items
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 4,
           parts[0] == "reminders",
           parts[1] == "lists",
           parts[3] == "items" {
            return .getReminders(listID: String(parts[2]))
        }
        return nil
    }
}

/// Response envelope for bridge API responses.
public struct BridgeResponse<T: Codable & Sendable>: Codable, Sendable {
    public let success: Bool
    public let data: T?
    /// Desensitized error message — never includes real IDs or credentials.
    public let error: String?

    public init(data: T) {
        self.success = true
        self.data = data
        self.error = nil
    }

    public init(error: EventKitBridgeError) {
        self.success = false
        self.data = nil
        self.error = error.localizedDescription
    }
}

/// Core bridge server logic.
/// Handles routing, auth, allowlist, source verification, and request limiting.
///
/// - Write isolation: All non-GET methods return writeOperationRejected immediately.
/// - FIX-R4A-01: listReminders route calls fetchListsMetadata() — no content access.
/// - FIX-R4A-02: getReminders route calls SourceVerifier via the store.
public actor EventKitBridgeServer {

    private let store: any EventKitStoreProtocol
    private let authValidator: AuthValidator
    private let allowlistValidator: AllowlistValidator
    private let requestLimiter: RequestLimiter
    private let config: BridgeConfig

    public init(
        store: any EventKitStoreProtocol,
        authValidator: AuthValidator,
        allowlistValidator: AllowlistValidator,
        requestLimiter: RequestLimiter,
        config: BridgeConfig
    ) {
        self.store = store
        self.authValidator = authValidator
        self.allowlistValidator = allowlistValidator
        self.requestLimiter = requestLimiter
        self.config = config
    }

    // MARK: — Request handling

    /// Handle an incoming HTTP-like request.
    ///
    /// - Parameters:
    ///   - method: HTTP method string ("GET", "POST", etc.)
    ///   - path: URL path (e.g. "/reminders/lists")
    ///   - credential: Caller's bridge credential.
    /// - Returns: JSON-serializable result or error envelope.
    public func handle(method: String, path: String, credential: BridgeCredential) async -> BridgeHandlerResult {
        // Write isolation: reject all non-GET methods immediately.
        guard method.uppercased() == "GET" else {
            return .failure(EventKitBridgeError.writeOperationRejected)
        }

        // Rate limiting
        do {
            try await requestLimiter.checkLimit()
        } catch {
            return .failure(EventKitBridgeError.rateLimitExceeded)
        }

        // Route parsing
        guard let route = BridgeRoute.parse(method: method, path: path) else {
            return .failure(EventKitBridgeError.internalError("unknown route"))
        }

        switch route {
        case .listReminders:
            // FIX-R4A-01: metadata only, no content access
            do {
                try authValidator.validate(credential: credential, requiredScope: .listMetadata)
                let lists = try await store.fetchListsMetadata()
                return .lists(lists)
            } catch let e as EventKitBridgeError {
                return .failure(e)
            } catch {
                return .failure(.internalError("unexpected"))
            }

        case .getReminders(let listID):
            // Validate auth scope
            do {
                try authValidator.validate(credential: credential, requiredScope: .reminderRead)
            } catch let e as EventKitBridgeError {
                return .failure(e)
            } catch {
                return .failure(.internalError("auth"))
            }

            // Allowlist validation (FIX-R4A-01 gate)
            do {
                try allowlistValidator.validate(listID: listID)
            } catch let e as EventKitBridgeError {
                return .failure(e)
            } catch {
                return .failure(.internalError("allowlist"))
            }

            // FIX-R4A-02: source verification is performed inside store.fetchReminders
            do {
                let items = try await store.fetchReminders(listID: listID)
                return .items(items)
            } catch let e as EventKitBridgeError {
                return .failure(e)
            } catch {
                return .failure(.internalError("fetch"))
            }
        }
    }
}

/// Result type for bridge handler responses.
public enum BridgeHandlerResult: Sendable {
    case lists([RemindersList])
    case items([ReminderItem])
    case failure(EventKitBridgeError)

    public var isSuccess: Bool {
        switch self {
        case .lists, .items: return true
        case .failure: return false
        }
    }

    public var error: EventKitBridgeError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
