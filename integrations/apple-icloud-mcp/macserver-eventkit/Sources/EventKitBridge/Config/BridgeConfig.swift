// BridgeConfig.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Configuration template — NO real credentials, Apple IDs, or tokens.
// All placeholders use <PLACEHOLDER> notation.

import Foundation

/// Runtime configuration for the EventKit bridge server.
///
/// - Important: This struct must NEVER be initialized with real Apple credentials,
///   iCloud account data, or production tokens. Use SESSION_TEMPLATE.md for
///   runtime configuration guidance.
public struct BridgeConfig: Sendable {

    /// Listening port for the local HTTP bridge. Default: 18765.
    public let port: Int

    /// Maximum concurrent requests. Default: 10.
    public let maxConcurrentRequests: Int

    /// Allowed list IDs (exact match). Must be populated from allowlist file, not hardcoded.
    /// Example placeholder value shown — do NOT use real list identifiers here.
    public let allowedListIDs: Set<String>

    /// Allowed iCloud source names for FIX-R4A-02.
    public let allowedSources: Set<String>

    /// Valid bridge token strings. MUST be loaded from secure storage at runtime.
    /// Do NOT hardcode real tokens here.
    public let validTokens: Set<String>

    /// Requests per second rate limit.
    public let rateLimitRPS: Int

    /// Whether to use the FakeEventKitStore (true) or ProductionEventKitStore (false).
    /// Production activation requires human authorization (AGENTS.md §1.3).
    public let useFakeStore: Bool

    /// Default configuration for offline / test use. No real credentials.
    public static var testDefault: BridgeConfig {
        BridgeConfig(
            port: 18765,
            maxConcurrentRequests: 10,
            allowedListIDs: [
                "fake-list-icloud-001",
                "fake-list-icloud-002",
            ],
            allowedSources: ["iCloud"],
            validTokens: ["test-token-001", "test-token-002"],
            rateLimitRPS: 5,
            useFakeStore: true
        )
    }

    /// Production configuration TEMPLATE. All sensitive values are placeholders.
    /// Fill in at runtime from secure config store — never commit real values.
    public static var productionTemplate: BridgeConfig {
        BridgeConfig(
            port: 18765,
            maxConcurrentRequests: 10,
            allowedListIDs: [
                // "<REAL_LIST_ID_1>",   // Load from config file, not here
                // "<REAL_LIST_ID_2>",
            ],
            allowedSources: ["iCloud"],
            validTokens: [
                // "<SESSION_TOKEN>",    // Load from keychain at runtime
            ],
            rateLimitRPS: 5,
            useFakeStore: false   // Set true until production activation authorized
        )
    }

    public init(
        port: Int,
        maxConcurrentRequests: Int,
        allowedListIDs: Set<String>,
        allowedSources: Set<String>,
        validTokens: Set<String>,
        rateLimitRPS: Int,
        useFakeStore: Bool
    ) {
        self.port = port
        self.maxConcurrentRequests = maxConcurrentRequests
        self.allowedListIDs = allowedListIDs
        self.allowedSources = allowedSources
        self.validTokens = validTokens
        self.rateLimitRPS = rateLimitRPS
        self.useFakeStore = useFakeStore
    }
}
