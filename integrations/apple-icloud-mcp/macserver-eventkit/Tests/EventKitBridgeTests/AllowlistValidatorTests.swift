// AllowlistValidatorTests.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Tests for AllowlistValidator — exact-match list ID gating (FIX-R4A-01)

import XCTest
@testable import EventKitBridge

final class AllowlistValidatorTests: XCTestCase {

    var validator: AllowlistValidator!

    override func setUp() {
        super.setUp()
        validator = AllowlistValidator(allowedIDs: [
            "fake-list-icloud-001",
            "fake-list-icloud-002",
        ])
    }

    // Test 1: Allowlisted ID passes validation
    func testAllowedIDPasses() throws {
        XCTAssertNoThrow(try validator.validate(listID: "fake-list-icloud-001"))
        XCTAssertNoThrow(try validator.validate(listID: "fake-list-icloud-002"))
    }

    // Test 2: Unknown ID throws listNotAllowed
    func testUnknownIDThrows() {
        XCTAssertThrowsError(try validator.validate(listID: "unknown-list-999")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .listNotAllowed)
        }
    }

    // Test 3: Empty string is not allowed
    func testEmptyStringNotAllowed() {
        XCTAssertThrowsError(try validator.validate(listID: "")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .listNotAllowed)
        }
    }

    // Test 4: Prefix match does NOT pass (exact match required - FIX-R4A-01)
    func testPrefixMatchIsRejected() {
        // "fake-list-icloud" is a prefix of an allowed ID but must NOT pass
        XCTAssertThrowsError(try validator.validate(listID: "fake-list-icloud")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .listNotAllowed)
        }
    }

    // Test 5: Suffix match does NOT pass
    func testSuffixMatchIsRejected() {
        XCTAssertThrowsError(try validator.validate(listID: "icloud-001")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .listNotAllowed)
        }
    }

    // Test 6: Case-sensitive — uppercase variant is rejected
    func testCaseSensitiveRejection() {
        XCTAssertThrowsError(try validator.validate(listID: "FAKE-LIST-ICLOUD-001")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .listNotAllowed)
        }
    }

    // Test 7: isAllowed non-throwing variant
    func testIsAllowedNonThrowing() {
        XCTAssertTrue(validator.isAllowed(listID: "fake-list-icloud-001"))
        XCTAssertFalse(validator.isAllowed(listID: "not-allowed"))
    }

    // Test 8: count returns correct number of allowlisted IDs
    func testCount() {
        XCTAssertEqual(validator.count, 2)
    }

    // Test 9: Validator with empty set rejects everything
    func testEmptyAllowlist() {
        let emptyValidator = AllowlistValidator(allowedIDs: [])
        XCTAssertFalse(emptyValidator.isAllowed(listID: "fake-list-icloud-001"))
        XCTAssertThrowsError(try emptyValidator.validate(listID: "fake-list-icloud-001"))
    }

    // Test 10: Local list ID rejected even if well-formed
    func testLocalListRejected() {
        XCTAssertThrowsError(try validator.validate(listID: "fake-list-local-001")) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .listNotAllowed)
        }
    }
}
