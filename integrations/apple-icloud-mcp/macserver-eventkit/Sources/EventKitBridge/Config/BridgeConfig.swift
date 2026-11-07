// BridgeConfig.swift
// NEW_IMPLEMENTATION | PRODUCTION_MODE_VALIDATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Configuration definition, parsing, and production validation.
// Gated: Production mode missing required config MUST throw and reject startup.
// Never silently fall back to test tokens or fake data in production mode.

import Foundation

/// Operational mode of the EventKit bridge.
public enum BridgeOperationMode: String, Sendable, Codable {
    case test = "TEST"
    case production = "PRODUCTION"
}

/// Configuration validation error.
public enum ConfigurationError: Error, Sendable, Equatable {
    case missingRequiredField(String)
    case insecureHostConfiguration(String)
    case testTokenInProduction(String)
    case missingListBinding(listID: String)
    case emptyAllowlist
    case emptyTokenSet

    public var localizedDescription: String {
        switch self {
        case .missingRequiredField(let field):
            return "Production configuration error: Missing required field '\(field)'."
        case .insecureHostConfiguration(let host):
            return "Production configuration error: Host '\(host)' is not permitted. Only 127.0.0.1 loopback is allowed."
        case .testTokenInProduction(let token):
            return "Production configuration error: Test token '\(token)' cannot be used in production mode."
        case .missingListBinding(let listID):
            return "Production configuration error: List ID '\(listID)' has no registered SourceIdentity binding."
        case .emptyAllowlist:
            return "Production configuration error: allowedListIDs must not be empty in production mode."
        case .emptyTokenSet:
            return "Production configuration error: validTokens must not be empty in production mode."
        }
    }
}

/// Complete configuration for EventKitBridgeServer.
public struct BridgeConfig: Sendable {

    /// Operating mode (TEST or PRODUCTION).
    public let mode: BridgeOperationMode

    /// Listening host. Strictly enforced loopback ("127.0.0.1").
    public let host: String

    /// Listening port. 0 = dynamic OS allocation. Default: 18765.
    public let port: Int

    /// Request timeout in seconds.
    public let timeoutSeconds: Double

    /// Maximum concurrent business requests (health checks remain unblocked).
    public let maxConcurrentRequests: Int

    /// Maximum permitted HTTP header size in bytes (e.g. 16384 = 16KB).
    public let maxHeaderSizeBytes: Int

    /// Allowed list IDs (exact match only).
    public let allowedListIDs: Set<String>

    /// Allowed iCloud source names (e.g. ["iCloud"]).
    public let allowedSources: Set<String>

    /// Allowed underlying source types (e.g. ["caldav"]).
    public let allowedSourceTypes: Set<String>

    /// Mandatory list ID -> SourceIdentity bindings.
    public let listBindings: [String: SourceIdentity]

    /// Authorized bearer tokens.
    public let validTokens: Set<String>

    /// Requests per second rate limit.
    public let rateLimitRPS: Int

    /// Safety flag: true uses FakeEventKitStore; false uses ProductionEventKitStore.
    public let useFakeStore: Bool

    // Known synthetic test tokens forbidden in production mode
    public static let forbiddenTestTokens: Set<String> = [
        "test-token-001",
        "test-token-002",
        "test-valid-bearer-token",
        "default-test-token"
    ]

    /// Default test configuration (safe offline, fake store, loopback).
    public static var testDefault: BridgeConfig {
        BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 5.0,
            maxConcurrentRequests: 10,
            maxHeaderSizeBytes: 16384,
            allowedListIDs: [
                "fake-list-icloud-001",
                "fake-list-icloud-002",
            ],
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud"),
                "fake-list-icloud-002": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-token-001", "test-token-002"],
            rateLimitRPS: 50,
            useFakeStore: true
        )
    }

    public init(
        mode: BridgeOperationMode = .test,
        host: String = "127.0.0.1",
        port: Int = 18765,
        timeoutSeconds: Double = 5.0,
        maxConcurrentRequests: Int = 10,
        maxHeaderSizeBytes: Int = 16384,
        allowedListIDs: Set<String> = [],
        allowedSources: Set<String> = ["iCloud"],
        allowedSourceTypes: Set<String> = ["caldav"],
        listBindings: [String: SourceIdentity] = [:],
        validTokens: Set<String> = [],
        rateLimitRPS: Int = 10,
        useFakeStore: Bool = true
    ) {
        self.mode = mode
        self.host = (host == "127.0.0.1" || host == "localhost") ? "127.0.0.1" : "127.0.0.1"
        self.port = port
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 5.0
        self.maxConcurrentRequests = maxConcurrentRequests > 0 ? maxConcurrentRequests : 10
        self.maxHeaderSizeBytes = maxHeaderSizeBytes > 0 ? maxHeaderSizeBytes : 16384
        self.allowedListIDs = allowedListIDs
        self.allowedSources = allowedSources
        self.allowedSourceTypes = allowedSourceTypes
        self.listBindings = listBindings
        self.validTokens = validTokens
        self.rateLimitRPS = rateLimitRPS > 0 ? rateLimitRPS : 10
        self.useFakeStore = useFakeStore
    }

    /// Strict production validation. Must throw if any configuration requirement is missing.
    /// Strictly prevents silent fallback to test tokens or fake data in production mode.
    public func validateForProduction() throws {
        guard mode == .production else { return }

        if host != "127.0.0.1" {
            throw ConfigurationError.insecureHostConfiguration(host)
        }

        if validTokens.isEmpty {
            throw ConfigurationError.emptyTokenSet
        }

        // Check for test tokens accidentally left in production config
        for token in validTokens {
            if Self.forbiddenTestTokens.contains(token) {
                throw ConfigurationError.testTokenInProduction(token)
            }
        }

        if allowedListIDs.isEmpty {
            throw ConfigurationError.emptyAllowlist
        }

        // Every allowlisted list must have an explicit source binding
        for listID in allowedListIDs {
            guard let binding = listBindings[listID] else {
                throw ConfigurationError.missingListBinding(listID: listID)
            }
            if binding.sourceID.isEmpty || binding.sourceType.isEmpty || binding.sourceTitle.isEmpty {
                throw ConfigurationError.missingListBinding(listID: listID)
            }
        }

        if allowedSourceTypes.isEmpty {
            throw ConfigurationError.missingRequiredField("allowedSourceTypes")
        }
    }

    /// Parses configuration from environment dictionary with support for bindings and mode.
    public static func load(from environment: [String: String]) throws -> BridgeConfig {
        let modeStr = (environment["EVENTKIT_BRIDGE_MODE"] ?? "TEST").uppercased()
        let mode = (modeStr == "PRODUCTION") ? BridgeOperationMode.production : BridgeOperationMode.test

        let port = Int(environment["EVENTKIT_BRIDGE_PORT"] ?? "") ?? 18765
        let timeout = Double(environment["EVENTKIT_BRIDGE_TIMEOUT"] ?? "") ?? 5.0
        let rps = Int(environment["EVENTKIT_BRIDGE_RPS"] ?? "") ?? 10
        let maxConcurrent = Int(environment["EVENTKIT_BRIDGE_MAX_CONCURRENT"] ?? "") ?? 10

        let allowlistStr = environment["EVENTKIT_BRIDGE_ALLOWLIST"] ?? ""
        let allowlist = Set(allowlistStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        let tokensStr = environment["EVENTKIT_BRIDGE_TOKENS"] ?? ""
        let tokens = Set(tokensStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        // Parse list bindings: format "listID:sourceID:sourceType:sourceTitle;..." or JSON
        var parsedBindings: [String: SourceIdentity] = [:]
        if let bindingsStr = environment["EVENTKIT_BRIDGE_BINDINGS"], !bindingsStr.isEmpty {
            let entries = bindingsStr.split(separator: ";")
            for entry in entries {
                let parts = entry.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 4 {
                    parsedBindings[parts[0]] = SourceIdentity(
                        sourceID: parts[1],
                        sourceType: parts[2],
                        sourceTitle: parts[3]
                    )
                }
            }
        }

        let useFake = (mode == .test) ? (environment["EVENTKIT_USE_FAKE"] != "false") : false

        let config = BridgeConfig(
            mode: mode,
            host: "127.0.0.1",
            port: port,
            timeoutSeconds: timeout,
            maxConcurrentRequests: maxConcurrent,
            maxHeaderSizeBytes: 16384,
            allowedListIDs: allowlist,
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: parsedBindings,
            validTokens: tokens,
            rateLimitRPS: rps,
            useFakeStore: useFake
        )

        // If in production mode, validate strictly immediately
        if mode == .production {
            try config.validateForProduction()
        }

        return config
    }
}
