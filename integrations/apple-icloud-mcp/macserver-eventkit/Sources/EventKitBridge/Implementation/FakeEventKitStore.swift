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
    ),
    SeedList(
        listID: "9D9A****03F3",
        title: "M****试",
        sourceID: "src-icloud-test-01",
        sourceType: "calDAV",
        sourceName: "iCloud",
        color: "#007AFF",
        reminders: [
            ReminderItem(
                itemID: "item-swift-01",
                title: "Swift 合成提醒事项 1",
                isCompleted: false,
                dueDate: Date(timeIntervalSinceReferenceDate: 815961600),
                priority: 1,
                notes: "核保附录条款审核",
                listID: "9D9A****03F3"
            ),
            ReminderItem(
                itemID: "item-swift-02",
                title: "Swift 合成提醒事项 2 (无截止日期/无备注)",
                isCompleted: true,
                dueDate: nil,
                priority: 0,
                notes: nil,
                listID: "9D9A****03F3"
            )
        ]
    )
]

// MARK: — Fake store

/// Fake EventKit store with deterministic seed data for testing.
/// Conforms to EventKitStoreProtocol — safe to use in all test targets.
public actor FakeEventKitStore: EventKitStoreProtocol {

    private let sourceVerifier: SourceVerifier
    private let seeds: [SeedList]
    private let isAuthorized: Bool

    // Diagnostic counters (FIX-R4A-01 test assertions)
    private var _contentAccessCount: Int = 0

    // Fault injection for timeout & non-cooperative store tests
    private var _shouldHangIndefinitely: Bool = false
    private var _hangDurationSeconds: Double = 0.0

    public init(
        sourceVerifier: SourceVerifier = SourceVerifier(),
        seeds: [SeedList] = defaultSeedData,
        isAuthorized: Bool = true
    ) {
        self.sourceVerifier = sourceVerifier
        self.seeds = seeds
        self.isAuthorized = isAuthorized
    }

    /// Convenience init taking allowed source names for backward compatibility.
    public init(allowedSources: Set<String>, isAuthorized: Bool = true) {
        self.sourceVerifier = SourceVerifier(allowedSourceTitles: allowedSources, requireExplicitBinding: false)
        self.seeds = defaultSeedData
        self.isAuthorized = isAuthorized
    }

    /// Injects hanging behavior into store calls for chaos testing.
    public func setHanging(indefinitely: Bool = true, durationSeconds: Double = 0.0) {
        self._shouldHangIndefinitely = indefinitely
        self._hangDurationSeconds = durationSeconds
    }

    /// Factory method for large dataset response testing (exercises partial send loop).
    public static func makeWithLargeDataSet(itemCount: Int = 300, sourceVerifier: SourceVerifier? = nil) -> FakeEventKitStore {
        var items: [ReminderItem] = []
        for i in 1...itemCount {
            items.append(
                ReminderItem(
                    itemID: "large-item-\(i)",
                    title: "Large dataset reminder item \(i) with verbose padding to test chunking and partial socket writes across TCP frames.",
                    isCompleted: i % 2 == 0,
                    notes: "Detailed note content for item \(i) containing desensitized synthetic testing payloads.",
                    listID: "fake-list-icloud-001"
                )
            )
        }
        let largeSeed = SeedList(
            listID: "fake-list-icloud-001",
            title: "Personal",
            sourceID: "src-icloud-primary",
            sourceType: "calDAV",
            sourceName: "iCloud",
            color: "#FF2D55",
            reminders: items
        )
        let verifier = sourceVerifier ?? SourceVerifier(
            allowedSourceTypes: ["caldav"],
            allowedSourceTitles: ["iCloud"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            requireExplicitBinding: true
        )
        return FakeEventKitStore(sourceVerifier: verifier, seeds: [largeSeed])
    }

    // MARK: — EventKitStoreProtocol

    /// FIX-R4A-01: Returns ONLY list metadata. Does NOT touch reminders or counts.
    public func fetchListsMetadata() async throws -> [RemindersList] {
        guard isAuthorized else {
            throw EventKitBridgeError.permissionDenied
        }

        while _shouldHangIndefinitely {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if _hangDurationSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(_hangDurationSeconds * 1_000_000_000))
        }

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
        guard isAuthorized else {
            throw EventKitBridgeError.permissionDenied
        }

        while _shouldHangIndefinitely {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if _hangDurationSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(_hangDurationSeconds * 1_000_000_000))
        }

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
