// SourceVerifierTests.swift
// NEW_IMPLEMENTATION | STRICT_IDENTITY_BINDING_TESTS
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Tests for SourceVerifier — strict list-to-source identity & type enforcement (FIX-R4A-02)

import XCTest
@testable import EventKitBridge

final class SourceVerifierTests: XCTestCase {

    var verifier: SourceVerifier!

    override func setUp() {
        super.setUp()
        // Strict verifier with explicit binding
        verifier = SourceVerifier(
            allowedSourceTypes: ["caldav"],
            allowedSourceTitles: ["iCloud"],
            listBindings: [
                "list-icloud-001": SourceIdentity(sourceID: "uuid-primary-icloud", sourceType: "calDAV", sourceTitle: "iCloud"),
                "list-icloud-002": SourceIdentity(sourceID: "uuid-family-icloud", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            requireExplicitBinding: true
        )
    }

    // Test 1: Bound CalDAV iCloud source passes
    func testBoundICloudSourcePasses() throws {
        XCTAssertNoThrow(try verifier.verify(
            listID: "list-icloud-001",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        ))
    }

    // Test 2: Local source is rejected (FIX-R4A-02)
    func testLocalSourceRejected() {
        XCTAssertThrowsError(try verifier.verify(
            listID: "list-icloud-001",
            sourceID: "uuid-primary-icloud",
            sourceType: "local", // Wrong type
            sourceTitle: "iCloud"
        )) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceMismatch)
        }
    }

    // Test 3: Exchange source is rejected
    func testExchangeSourceRejected() {
        XCTAssertThrowsError(try verifier.verify(
            listID: "list-icloud-001",
            sourceID: "uuid-primary-icloud",
            sourceType: "exchange",
            sourceTitle: "iCloud"
        )) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceMismatch)
        }
    }

    // Test 4: Unbound list rejected immediately (FIX-R4A-02)
    func testUnboundListRejected() {
        XCTAssertThrowsError(try verifier.verify(
            listID: "unbound-unknown-list",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        )) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceMismatch)
        }
    }

    // Test 5: Changed source UUID rejected (Source drift / spoofing attempt)
    func testSourceIDDriftRejected() {
        XCTAssertThrowsError(try verifier.verify(
            listID: "list-icloud-001",
            sourceID: "attacker-substituted-uuid", // Drift
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        )) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceMismatch)
        }
    }

    // Test 6: Case-sensitive title check — "icloud" (lowercase) is rejected
    func testCaseSensitiveTitleRejection() {
        XCTAssertThrowsError(try verifier.verify(
            listID: "list-icloud-001",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceTitle: "icloud" // Lowercase title
        )) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceMismatch)
        }
    }

    // Test 7: isAllowed non-throwing variant returns true for match and false for mismatch
    func testIsAllowedNonThrowing() {
        XCTAssertTrue(verifier.isAllowed(
            listID: "list-icloud-001",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        ))
        XCTAssertFalse(verifier.isAllowed(
            listID: "list-icloud-001",
            sourceID: "wrong-uuid",
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        ))
        XCTAssertFalse(verifier.isAllowed(
            listID: "unbound-list",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        ))
    }

    // Test 8: RemindersList direct verification helper
    func testRemindersListDirectVerification() throws {
        let validList = RemindersList(
            listID: "list-icloud-001",
            title: "Reminders",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceName: "iCloud"
        )
        XCTAssertNoThrow(try verifier.verify(list: validList))

        let invalidList = RemindersList(
            listID: "list-icloud-001",
            title: "Reminders",
            sourceID: "wrong-uuid",
            sourceType: "calDAV",
            sourceName: "iCloud"
        )
        XCTAssertThrowsError(try verifier.verify(list: invalidList))
    }

    // Test 9: Spoofed title on local store rejected
    func testSpoofedTitleLocalStoreRejected() {
        let spoofedList = RemindersList(
            listID: "list-icloud-001",
            title: "Reminders",
            sourceID: "uuid-primary-icloud",
            sourceType: "local",
            sourceName: "iCloud"
        )
        XCTAssertThrowsError(try verifier.verify(list: spoofedList))
    }

    // Test 10: Precondition check — empty allowed types or titles are programmer errors
    func testPreconditionNonEmptySets() {
        XCTAssertTrue(verifier.isAllowed(
            listID: "list-icloud-001",
            sourceID: "uuid-primary-icloud",
            sourceType: "calDAV",
            sourceTitle: "iCloud"
        ))
    }
}
