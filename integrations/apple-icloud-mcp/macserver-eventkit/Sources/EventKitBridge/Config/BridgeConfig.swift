// BridgeConfig.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Configuration template & loader — NO real credentials, Apple IDs, or tokens.
// Defaults strictly to loopback (127.0.0.1) and FakeEventKitStore.

import Foundation

/// Runtime configuration for the EventKit bridge server.
///
/// - Important: This struct must NEVER be initialized with real Apple credentials,
///   iCloud account data, or production tokens.
public struct BridgeConfig: Sendable {

    /// Listening host. Strictly enforced loopback ("127.0.0.1").
    public let host: String

    /// Listening port. 0 means dynamic port allocation by the OS.
    public let port: Int

    /// Request timeout in seconds.
    public let timeoutSeconds: Double

    /// Maximum concurrent requests. Default: 10.
    public let maxConcurrentRequests: Int

    /// Allowed list IDs (exact match). Must be populated from allowlist, not guessed.
    public let allowedListIDs: Set<String>

    /// Allowed iCloud source names.
    public let allowedSources: Set<String>

    /// Allowed source types (e.g. ["caldav"]).
    public let allowedSourceTypes: Set<String>

    /// Explicit list ID to SourceIdentity bindings.
    public let listBindings: [String: SourceIdentity]

    /// Valid bridge token strings.
    public let validTokens: Set<String>

    /// Requests per second rate limit.
    public let rateLimitRPS: Int

    /// Safety flag: defaults to true (FakeEventKitStore).
    /// Must never default to true data access.
    public let useFakeStore: Bool

    /// Default configuration for offline / test use. No real credentials.
    public static var testDefault: BridgeConfig {
        BridgeConfig(
            host: "127.0.0.1",
            port: 0, // Dynamic port for tests
            timeoutSeconds: 5.0,
            maxConcurrentRequests: 10,
            allowedListIDs: [
                "fake-list-icloud-001",
                "fake-list-icloud-002",
            ],
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav", "icloud"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud"),
                "fake-list-icloud-002": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-token-001", "test-token-002"],
            rateLimitRPS: 50,
            useFakeStore: true
        )
    }

    /// Production configuration TEMPLATE. Sensitive values are placeholders.
    public static var productionTemplate: BridgeConfig {
        BridgeConfig(
            host: "127.0.0.1",
            port: 18765,
            timeoutSeconds: 10.0,
            maxConcurrentRequests: 10,
            allowedListIDs: [],
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: [:],
            validTokens: [],
            rateLimitRPS: 10,
            useFakeStore: true // Remains true until authorized
        )
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 18765,
        timeoutSeconds: Double = 5.0,
        maxConcurrentRequests: Int = 10,
        allowedListIDs: Set<String> = [],
        allowedSources: Set<String> = ["iCloud"],
        allowedSourceTypes: Set<String> = ["caldav"],
        listBindings: [String: SourceIdentity] = [:],
        validTokens: Set<String> = [],
        rateLimitRPS: Int = 10,
        useFakeStore: Bool = true
    ) {
        // Enforce loopback strictly
        self.host = (host == "127.0.0.1" || host == "localhost") ? "127.0.0.1" : "127.0.0.1"
        self.port = port
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 5.0
        self.maxConcurrentRequests = maxConcurrentRequests > 0 ? maxConcurrentRequests : 10
        self.allowedListIDs = allowedListIDs
        self.allowedSources = allowedSources
        self.allowedSourceTypes = allowedSourceTypes
        self.listBindings = listBindings
        self.validTokens = validTokens
        self.rateLimitRPS = rateLimitRPS > 0 ? rateLimitRPS : 10
        self.useFakeStore = useFakeStore
    }

    /// Load configuration from environment variables safely.
    public static func load(from environment: [String: String]) -> BridgeConfig {
        let port = Int(environment["EVENTKIT_BRIDGE_PORT"] ?? "") ?? 18765
        let timeout = Double(environment["EVENTKIT_BRIDGE_TIMEOUT"] ?? "") ?? 5.0
        let rps = Int(environment["EVENTKIT_BRIDGE_RPS"] ?? "") ?? 10

        let allowlistStr = environment["EVENTKIT_BRIDGE_ALLOWLIST"] ?? ""
        let allowlist = Set(allowlistStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

        let tokensStr = environment["EVENTKIT_BRIDGE_TOKENS"] ?? ""
        let tokens = Set(tokensStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

        return BridgeConfig(
            host: "127.0.0.1",
            port: port,
            timeoutSeconds: timeout,
            maxConcurrentRequests: 10,
            allowedListIDs: allowlist.isEmpty ? testDefault.allowedListIDs : allowlist,
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: [:],
            validTokens: tokens.isEmpty ? testDefault.validTokens : tokens,
            rateLimitRPS: rps,
            useFakeStore: true
        )
    }
}
