// FakeEventKitStore.swift
// NEW_IMPLEMENTATION | FIX-R4A-01 | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// 100% deterministic Fake implementation of EventKitStoreProtocol.
// No real EventKit framework, no TCC permissions, no network.
//
// FIX-R4A-01: fetchListsMetadata() does NOT access reminders or counts.
// FIX-R4A-02: fetchReminders(listID:) checks source identity & type against SourceVerifier.

import Foundation

// MARK: — Seed data

public struct SeedList: Sendable {
    public let listID: String
    public let title: String
    public let sourceID: String
    public let sourceType: String
    public let sourceName: String
    public let color: String
    public let reminders: [ReminderItem]

    public init(
        listID: String,
        title: String,
        sourceID: String = "src-icloud-primary",
        sourceType: String = "calDAV",
        sourceName: String = "iCloud",
        color: String = "#007AFF",
        reminders: [ReminderItem] = []
    ) {
        self.listID = listID
        self.title = title
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.sourceName = sourceName
        self.color = color
        self.reminders = reminders
    }
}

public let defaultSeedData: [SeedList] = [
    SeedList(
        listID: "fake-list-icloud-001",
        title: "Personal",
        sourceID: "src-icloud-primary",
        sourceType: "calDAV",
        sourceName: "iCloud",
        color: "#FF2D55",
        reminders: [
            ReminderItem(itemID: "r-001", title: "Call dentist", listID: "fake-list-icloud-001"),
            ReminderItem(itemID: "r-002", title: "Pay electricity", listID: "fake-list-icloud-001"),
        ]
    ),
    SeedList(
        listID: "fake-list-icloud-002",
        title: "Work",
        sourceID: "src-icloud-primary",
        sourceType: "calDAV",
        sourceName: "iCloud",
        color: "#007AFF",
        reminders: [
            ReminderItem(itemID: "r-003", title: "Review PR", isCompleted: true, listID: "fake-list-icloud-002"),
            ReminderItem(itemID: "r-004", title: "Team standup", listID: "fake-list-icloud-002"),
        ]
    ),
    SeedList(
        listID: "fake-list-local-001",
        title: "On My Mac",
        sourceID: "src-local-machine",
        sourceType: "local",
        sourceName: "Local",
        color: "#FF9500",
        reminders: [
            ReminderItem(itemID: "r-005", title: "Local task", listID: "fake-list-local-001"),
        ]
    ),
    SeedList(
        listID: "fake-list-unbound-001",
        title: "Unbound List",
        sourceID: "src-icloud-primary",
        sourceType: "calDAV",
        sourceName: "iCloud",
        color: "#5856D6",
        reminders: [
            ReminderItem(itemID: "r-006", title: "Unbound secret item", listID: "fake-list-unbound-001")
        ]
    ),
    SeedList(
        listID: "fake-list-wrong-source-001",
        title: "Wrong Source ID List",
        sourceID: "src-attacker-modified-id",
        sourceType: "calDAV",
        sourceName: "iCloud",
        color: "#AF52DE",
        reminders: [
            ReminderItem(itemID: "r-007", title: "Wrong source secret item", listID: "fake-list-wrong-source-001")
        ]
    ),
    SeedList(
        listID: "fake-list-spoofed-001",
        title: "Spoofed Title List",
        sourceID: "src-local-store",
        sourceType: "local",
        sourceName: "iCloud", // Spoofed name
        color: "#FF3B30",
        reminders: [
            ReminderItem(itemID: "r-008", title: "Spoofed title secret item", listID: "fake-list-spoofed-001")
        ]
    )
]

// MARK: — Fake store

/// Fake EventKit store with deterministic seed data for testing.
/// Conforms to EventKitStoreProtocol — safe to use in all test targets.
public actor FakeEventKitStore: EventKitStoreProtocol {

    private let sourceVerifier: SourceVerifier
    private let seeds: [SeedList]

    // Diagnostic counters (FIX-R4A-01 test assertions)
    private var _contentAccessCount: Int = 0

    public init(
        sourceVerifier: SourceVerifier = SourceVerifier(),
        seeds: [SeedList] = defaultSeedData
    ) {
        self.sourceVerifier = sourceVerifier
        self.seeds = seeds
    }

    /// Convenience init taking allowed source names for backward compatibility.
    public init(allowedSources: Set<String>) {
        self.sourceVerifier = SourceVerifier(allowedSourceTitles: allowedSources, requireExplicitBinding: false)
        self.seeds = defaultSeedData
    }

    // MARK: — EventKitStoreProtocol

    /// FIX-R4A-01: Returns ONLY list metadata. Does NOT touch reminders or counts.
    public func fetchListsMetadata() async throws -> [RemindersList] {
        // Explicitly does NOT increment _contentAccessCount.
        return seeds.map { seed in
            RemindersList(
                listID: seed.listID,
                title: seed.title,
                sourceID: seed.sourceID,
                sourceType: seed.sourceType,
                sourceName: seed.sourceName,
                color: seed.color,
                isImmutable: true
            )
        }
    }

    /// FIX-R4A-02: Verifies source identity, type, and binding before returning reminders.
    public func fetchReminders(listID: String) async throws -> [ReminderItem] {
        guard let seed = seeds.first(where: { $0.listID == listID }) else {
            throw EventKitBridgeError.listNotFound
        }

        // FIX-R4A-02: Comprehensive source verification — reject non-iCloud or mismatched sources
        // PRIOR to touching reminder content.
        try sourceVerifier.verify(
            listID: seed.listID,
            sourceID: seed.sourceID,
            sourceType: seed.sourceType,
            sourceTitle: seed.sourceName
        )

        // Increment content access counter (for FIX-R4A-01 assertion).
        _contentAccessCount += 1
        return seed.reminders
    }

    // MARK: — Diagnostics

    public var contentAccessCount: Int {
        _contentAccessCount
    }

    public func resetCounters() {
        _contentAccessCount = 0
    }
}
