// SessionConfig.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// User session resident configuration for the EventKit bridge.
// No real credentials. See SESSION_TEMPLATE.md for runtime setup.

import Foundation

/// Persistent session configuration for the bridge process.
///
/// This is loaded once at startup and remains resident for the bridge process lifetime.
/// All fields that accept real credentials must be loaded from keychain or secure config
/// at runtime — never committed to source control.
public struct SessionConfig: Sendable, Codable {

    /// Session identifier (opaque, used for logging correlation — not a secret).
    public let sessionID: String

    /// ISO 8601 timestamp when this session config was created.
    public let createdAt: String

    /// Username label for this session (non-sensitive display label, not an Apple ID).
    /// Example: "work-mac", "home-mac". Not used for auth.
    public let machineLabelName: String

    /// Whether the session is in test mode (uses FakeEventKitStore).
    public let isTestMode: Bool

    /// Maximum session duration in seconds before re-authorization required. Default: 3600.
    public let maxSessionDurationSeconds: Int

    /// How to stop and resume this session. See SESSION_TEMPLATE.md.
    public var stopCommand: String {
        "# See SESSION_TEMPLATE.md for stop/resume procedures"
    }

    /// Template session config for documentation purposes.
    public static var template: SessionConfig {
        SessionConfig(
            sessionID: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            machineLabelName: "<YOUR_MACHINE_LABEL>",
            isTestMode: true,
            maxSessionDurationSeconds: 3600
        )
    }

    public init(
        sessionID: String,
        createdAt: String,
        machineLabelName: String,
        isTestMode: Bool,
        maxSessionDurationSeconds: Int
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.machineLabelName = machineLabelName
        self.isTestMode = isTestMode
        self.maxSessionDurationSeconds = maxSessionDurationSeconds
    }
}
