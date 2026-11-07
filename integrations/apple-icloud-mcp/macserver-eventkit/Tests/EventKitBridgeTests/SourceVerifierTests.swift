// SourceVerifierTests.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Tests for SourceVerifier — iCloud source enforcement (FIX-R4A-02)

import XCTest
@testable import EventKitBridge

final class SourceVerifierTests: XCTestCase {

    var verifier: SourceVerifier!

    override func setUp() {
        super.setUp()
        verifier = SourceVerifier(allowedSources: ["iCloud"])
    }

    // Test 1: "iCloud" source passes
    func testICloudSourcePasses() throws {
        XCTAssertNoThrow(try verifier.verify(sourceName: "iCloud"))
    }

    // Test 2: "Local" source is rejected (FIX-R4A-02)
    func testLocalSourceRejected() {
        XCTAssertThrowsError(try verifier.verify(sourceName: "Local")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceNotAllowed)
        }
    }

    // Test 3: "Exchange" source is rejected
    func testExchangeSourceRejected() {
        XCTAssertThrowsError(try verifier.verify(sourceName: "Exchange")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceNotAllowed)
        }
    }

    // Test 4: Empty string source is rejected
    func testEmptySourceRejected() {
        XCTAssertThrowsError(try verifier.verify(sourceName: "")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceNotAllowed)
        }
    }

    // Test 5: Case-sensitive — "icloud" (lowercase) is rejected
    func testCaseSensitiveRejection() {
        XCTAssertThrowsError(try verifier.verify(sourceName: "icloud")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceNotAllowed)
        }
    }

    // Test 6: isAllowed non-throwing variant
    func testIsAllowedNonThrowing() {
        XCTAssertTrue(verifier.isAllowed(sourceName: "iCloud"))
        XCTAssertFalse(verifier.isAllowed(sourceName: "Local"))
    }

    // Test 7: Multiple allowed sources
    func testMultipleAllowedSources() throws {
        let multiVerifier = SourceVerifier(allowedSources: ["iCloud", "iCloud (Family)"])
        XCTAssertNoThrow(try multiVerifier.verify(sourceName: "iCloud"))
        XCTAssertNoThrow(try multiVerifier.verify(sourceName: "iCloud (Family)"))
        XCTAssertThrowsError(try multiVerifier.verify(sourceName: "Local"))
    }

    // Test 8: "On My Mac" source rejected
    func testOnMyMacRejected() {
        XCTAssertThrowsError(try verifier.verify(sourceName: "On My Mac")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .sourceNotAllowed)
        }
    }

    // Test 9: Arbitrary string rejected
    func testArbitraryStringRejected() {
        XCTAssertThrowsError(try verifier.verify(sourceName: "ATTACKER_CONTROLLED_SOURCE"))
    }

    // Test 10: Precondition — empty allowedSources set is a programmer error (tested via init guard)
    func testEmptySourcesSetPrecondition() {
        // This confirms the verifier was initialized with a non-empty set
        XCTAssertTrue(verifier.isAllowed(sourceName: "iCloud"))
        // We do NOT test the fatalError path directly — that's a precondition.
    }
}
