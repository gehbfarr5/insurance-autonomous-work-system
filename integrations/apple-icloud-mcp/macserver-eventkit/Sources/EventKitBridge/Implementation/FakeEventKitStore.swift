// FakeEventKitStore.swift
// NEW_IMPLEMENTATION | FIX-R4A-01 | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// 100% deterministic Fake implementation of EventKitStoreProtocol.
// No real EventKit framework, no TCC permissions, no network.
//
// FIX-R4A-01: fetchListsMetadata() does NOT access reminders or counts.
// FIX-R4A-02: fetchReminders(listID:) checks sourceName against allowedSources.

import Foundation

// MARK: — Seed data

private struct SeedList {
    let listID: String
    let title: String
    let sourceName: String
    let color: String
    let reminders: [ReminderItem]
}

private let seedData: [SeedList] = [
    SeedList(
        listID: "fake-list-icloud-001",
        title: "Personal",
        sourceName: "iCloud",
        color: "#FF2D55",
        reminders: [
            ReminderItem(itemID: "r-001", title: "Call dentist",   listID: "fake-list-icloud-001"),
            ReminderItem(itemID: "r-002", title: "Pay electricity", listID: "fake-list-icloud-001"),
        ]
    ),
    SeedList(
        listID: "fake-list-icloud-002",
        title: "Work",
        sourceName: "iCloud",
        color: "#007AFF",
        reminders: [
            ReminderItem(itemID: "r-003", title: "Review PR",    isCompleted: true, listID: "fake-list-icloud-002"),
            ReminderItem(itemID: "r-004", title: "Team standup", listID: "fake-list-icloud-002"),
        ]
    ),
    SeedList(
        listID: "fake-list-local-001",
        title: "On My Mac",
        sourceName: "Local",
        color: "#FF9500",
        reminders: [
            ReminderItem(itemID: "r-005", title: "Local task", listID: "fake-list-local-001"),
        ]
    ),
]

// MARK: — Fake store

/// Fake EventKit store with deterministic seed data for testing.
/// Conforms to EventKitStoreProtocol — safe to use in all test targets.
///
/// Thread-safety: actor-isolated for Swift 6 strict concurrency.
public actor FakeEventKitStore: EventKitStoreProtocol {

    /// Sources considered "iCloud" for FIX-R4A-02 verification.
    private let allowedSources: Set<String>

    // Diagnostic counters (FIX-R4A-01 test assertions)
    private var _contentAccessCount: Int = 0

    public init(allowedSources: Set<String> = ["iCloud"]) {
        self.allowedSources = allowedSources
    }

    // MARK: — EventKitStoreProtocol

    /// FIX-R4A-01: Returns ONLY list metadata. Does NOT touch reminders or counts.
    public func fetchListsMetadata() async throws -> [RemindersList] {
        // No increment to _contentAccessCount — metadata only.
        return seedData.map { seed in
            RemindersList(
                listID: seed.listID,
                title: seed.title,
                sourceName: seed.sourceName,
                color: seed.color,
                isImmutable: true
            )
        }
    }

    /// FIX-R4A-02: Verifies source before returning reminders.
    public func fetchReminders(listID: String) async throws -> [ReminderItem] {
        guard let seed = seedData.first(where: { $0.listID == listID }) else {
            throw EventKitBridgeError.listNotFound
        }

        // FIX-R4A-02: Source verification — reject non-iCloud sources.
        guard allowedSources.contains(seed.sourceName) else {
            throw EventKitBridgeError.sourceNotAllowed
        }

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
