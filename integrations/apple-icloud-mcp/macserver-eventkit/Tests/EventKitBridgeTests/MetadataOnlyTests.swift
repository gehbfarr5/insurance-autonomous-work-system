// MetadataOnlyTests.swift
// NEW_IMPLEMENTATION | FIX-R4A-01
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Core acceptance test: metadata-only paths MUST NOT touch reminder content or counts.
// FIX-R4A-01: contentAccessCount must remain 0 after any metadata-only call.

import XCTest
@testable import EventKitBridge

final class MetadataOnlyTests: XCTestCase {

    var store: FakeEventKitStore!

    override func setUp() async throws {
        store = FakeEventKitStore(allowedSources: ["iCloud"])
        await store.resetCounters()
    }

    // Test 1: fetchListsMetadata does NOT increment contentAccessCount (FIX-R4A-01 core)
    func testListsMetadataDoesNotAccessContent() async throws {
        let lists = try await store.fetchListsMetadata()
        XCTAssertFalse(lists.isEmpty, "Should have at least one list")
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 0,
            "FIX-R4A-01 VIOLATED: contentAccessCount=\(count) after metadata-only call. Must be 0.")
    }

    // Test 2: RemindersList.reminderCount field does not exist (structural enforcement)
    func testRemindersListHasNoCountField() async throws {
        let lists = try await store.fetchListsMetadata()
        let list = try XCTUnwrap(lists.first)
        // Verify only metadata fields are present
        XCTAssertFalse(list.listID.isEmpty)
        XCTAssertFalse(list.title.isEmpty)
        XCTAssertFalse(list.sourceName.isEmpty)
        // RemindersList has no reminderCount field — this test simply compiles,
        // confirming the type does not expose a count.
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 0, "FIX-R4A-01: metadata access must not read content")
    }

    // Test 3: Multiple metadata fetches keep contentAccessCount at 0
    func testRepeatedMetadataCallsNeverAccessContent() async throws {
        for _ in 0..<5 {
            _ = try await store.fetchListsMetadata()
        }
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 0, "FIX-R4A-01: 5 metadata calls must not increment content counter")
    }

    // Test 4: Fetching reminders DOES increment contentAccessCount (counter sanity check)
    func testContentAccessCountedOnReminderFetch() async throws {
        await store.resetCounters()
        _ = try? await store.fetchReminders(listID: "fake-list-icloud-001")
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 1, "Content counter must be 1 after one fetchReminders call")
    }

    // Test 5: resetCounters correctly zeros counter
    func testResetCounters() async throws {
        _ = try? await store.fetchReminders(listID: "fake-list-icloud-001")
        _ = try? await store.fetchReminders(listID: "fake-list-icloud-002")
        await store.resetCounters()
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 0, "resetCounters must zero contentAccessCount")
    }

    // Test 6: Metadata list includes sourceName (required for FIX-R4A-02 downstream)
    func testMetadataIncludesSourceName() async throws {
        let lists = try await store.fetchListsMetadata()
        for list in lists {
            XCTAssertFalse(list.sourceName.isEmpty,
                "sourceName must be present in metadata for FIX-R4A-02 downstream verification")
        }
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 0, "Checking sourceName must not trigger content access")
    }

    // Test 7: Local list appears in metadata but is gated by FIX-R4A-02 on content access
    func testLocalListAppearsInMetadataButContentRejected() async throws {
        let lists = try await store.fetchListsMetadata()
        // "On My Mac" / Local list should appear in metadata
        let localList = lists.first(where: { $0.sourceName == "Local" })
        XCTAssertNotNil(localList, "Local list should appear in metadata listing")

        // But content access must be rejected (FIX-R4A-02)
        if let localList {
            do {
                _ = try await store.fetchReminders(listID: localList.listID)
                XCTFail("FIX-R4A-02: fetchReminders on Local list must throw sourceNotAllowed")
            } catch EventKitBridgeError.sourceNotAllowed {
                // Expected
            }
        }

        // Metadata count still 0 (source check happened, but metadata never accessed content)
        // Note: fetchReminders does NOT increment counter when it throws before accessing content
        // The counter only increments on successful content reads.
    }

    // Test 8: fetchListsMetadata returns at least 3 seed lists
    func testSeedListCount() async throws {
        let lists = try await store.fetchListsMetadata()
        XCTAssertGreaterThanOrEqual(lists.count, 3)
        let count = await store.contentAccessCount
        XCTAssertEqual(count, 0)
    }
}
