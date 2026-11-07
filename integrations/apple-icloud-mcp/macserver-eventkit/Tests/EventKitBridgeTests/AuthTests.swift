// AuthTests.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Tests for authentication and scope validation.

import XCTest
@testable import EventKitBridge

final class AuthTests: XCTestCase {

    var validator: AuthValidator!

    override func setUp() {
        super.setUp()
        validator = AuthValidator(allowedTokens: ["test-token-001", "test-token-002"])
    }

    // Test 1: Valid token with correct scope passes
    func testValidTokenAndScopePasses() throws {
        let cred = BridgeCredential(token: "test-token-001", scopes: [.listMetadata])
        XCTAssertNoThrow(try validator.validate(credential: cred, requiredScope: .listMetadata))
    }

    // Test 2: Invalid token throws authenticationFailed
    func testInvalidTokenThrows() {
        let cred = BridgeCredential(token: "bad-token-xyz", scopes: [.listMetadata])
        XCTAssertThrowsError(try validator.validate(credential: cred, requiredScope: .listMetadata)) { error in
            if case EventKitBridgeError.authenticationFailed = error {
                // Expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }

    // Test 3: Valid token but missing scope throws unauthorizedScope
    func testValidTokenMissingScopeThrows() {
        let cred = BridgeCredential(token: "test-token-001", scopes: [.listMetadata])
        XCTAssertThrowsError(
            try validator.validate(credential: cred, requiredScope: .reminderRead)
        ) { error in
            XCTAssertEqual(error as? EventKitBridgeError, .unauthorizedScope)
        }
    }

    // Test 4: Empty token is rejected
    func testEmptyTokenRejected() {
        let cred = BridgeCredential(token: "", scopes: [.listMetadata, .reminderRead])
        XCTAssertThrowsError(try validator.validate(credential: cred, requiredScope: .listMetadata)) { error in
            if case EventKitBridgeError.authenticationFailed = error { } else {
                XCTFail("Expected authenticationFailed")
            }
        }
    }

    // Test 5: isKnownToken non-throwing variant
    func testIsKnownToken() {
        XCTAssertTrue(validator.isKnownToken("test-token-001"))
        XCTAssertFalse(validator.isKnownToken("unknown-token"))
    }

    // Test 6: BridgeCredential with both scopes passes for both scope checks
    func testFullScopeCredentialPassesBothScopes() throws {
        let cred = BridgeCredential(token: "test-token-001", scopes: [.listMetadata, .reminderRead])
        XCTAssertNoThrow(try validator.validate(credential: cred, requiredScope: .listMetadata))
        XCTAssertNoThrow(try validator.validate(credential: cred, requiredScope: .reminderRead))
    }

    // Test 7: Server rejects unauthenticated GET request
    func testServerRejectsUnknownToken() async {
        let config = BridgeConfig.testDefault
        let store = FakeEventKitStore(allowedSources: config.allowedSources)
        let server = EventKitBridgeServer(
            store: store,
            authValidator: AuthValidator(allowedTokens: config.validTokens),
            allowlistValidator: AllowlistValidator(allowedIDs: config.allowedListIDs),
            requestLimiter: RequestLimiter(capacity: 100, refillPerSecond: 100),
            config: config
        )
        let badCred = BridgeCredential(token: "attacker-token", scopes: [.listMetadata, .reminderRead])
        let result = await server.handle(method: "GET", path: "/reminders/lists", credential: badCred)
        XCTAssertFalse(result.isSuccess)
        if case .authenticationFailed = result.error { } else {
            XCTFail("Expected authenticationFailed, got \(String(describing: result.error))")
        }
    }

    // Test 8: Server rejects non-allowlisted list ID
    func testServerRejectsNonAllowlistedList() async {
        let config = BridgeConfig.testDefault
        let store = FakeEventKitStore(allowedSources: config.allowedSources)
        let server = EventKitBridgeServer(
            store: store,
            authValidator: AuthValidator(allowedTokens: config.validTokens),
            allowlistValidator: AllowlistValidator(allowedIDs: config.allowedListIDs),
            requestLimiter: RequestLimiter(capacity: 100, refillPerSecond: 100),
            config: config
        )
        let cred = BridgeCredential(token: "test-token-001", scopes: [.listMetadata, .reminderRead])
        let result = await server.handle(
            method: "GET",
            path: "/reminders/lists/NOT-ON-ALLOWLIST/items",
            credential: cred
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .listNotAllowed)
    }

    // Test 9: Server rejects non-iCloud source (FIX-R4A-02 via store)
    func testServerRejectsNonICloudSource() async {
        let config = BridgeConfig.testDefault
        let store = FakeEventKitStore(allowedSources: ["iCloud"])
        let server = EventKitBridgeServer(
            store: store,
            authValidator: AuthValidator(allowedTokens: config.validTokens),
            allowlistValidator: AllowlistValidator(allowedIDs: Set(["fake-list-local-001"] + config.allowedListIDs)),
            requestLimiter: RequestLimiter(capacity: 100, refillPerSecond: 100),
            config: config
        )
        let cred = BridgeCredential(token: "test-token-001", scopes: [.listMetadata, .reminderRead])
        // fake-list-local-001 is Local source — should be rejected by store's FIX-R4A-02 check
        let result = await server.handle(
            method: "GET",
            path: "/reminders/lists/fake-list-local-001/items",
            credential: cred
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .sourceNotAllowed)
    }

    // Test 10: BridgeScope raw values are correct
    func testBridgeScopeRawValues() {
        XCTAssertEqual(BridgeScope.listMetadata.rawValue, "reminders:lists:metadata")
        XCTAssertEqual(BridgeScope.reminderRead.rawValue, "reminders:items:read")
    }
}
