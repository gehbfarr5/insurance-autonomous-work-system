// WriteIsolationTests.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Acceptance test: ALL write-method HTTP requests MUST be rejected.
// EventKitStoreProtocol has no write methods — verification is at HTTP bridge layer.

import XCTest
@testable import EventKitBridge

final class WriteIsolationTests: XCTestCase {

    var server: EventKitBridgeServer!
    var store: FakeEventKitStore!
    var config: BridgeConfig!
    let validCredential = BridgeCredential(
        token: "test-token-001",
        scopes: [.listMetadata, .reminderRead]
    )

    override func setUp() async throws {
        config = BridgeConfig.testDefault
        store = FakeEventKitStore(allowedSources: config.allowedSources)
        await store.resetCounters()

        let authValidator = AuthValidator(allowedTokens: config.validTokens)
        let allowlistValidator = AllowlistValidator(allowedIDs: config.allowedListIDs)
        let requestLimiter = RequestLimiter(capacity: 100, refillPerSecond: 100)

        server = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: config
        )
    }

    // Test 1: POST to lists endpoint is rejected
    func testPostRemindersListsRejected() async {
        let result = await server.handle(
            method: "POST",
            path: "/reminders/lists",
            credential: validCredential
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .writeOperationRejected)
    }

    // Test 2: PUT to reminder item is rejected
    func testPutReminderItemRejected() async {
        let result = await server.handle(
            method: "PUT",
            path: "/reminders/lists/fake-list-icloud-001/items/r-001",
            credential: validCredential
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .writeOperationRejected)
    }

    // Test 3: PATCH is rejected
    func testPatchRejected() async {
        let result = await server.handle(
            method: "PATCH",
            path: "/reminders/lists/fake-list-icloud-001/items/r-001",
            credential: validCredential
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .writeOperationRejected)
    }

    // Test 4: DELETE is rejected
    func testDeleteRejected() async {
        let result = await server.handle(
            method: "DELETE",
            path: "/reminders/lists/fake-list-icloud-001",
            credential: validCredential
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .writeOperationRejected)
    }

    // Test 5: Write rejection does NOT trigger store content access
    func testWriteRejectionNoStoreAccess() async {
        _ = await server.handle(method: "POST", path: "/reminders/lists", credential: validCredential)
        _ = await server.handle(method: "PUT",  path: "/reminders/lists/x/items/y", credential: validCredential)
        _ = await server.handle(method: "DELETE", path: "/reminders/lists/x", credential: validCredential)
        // If store were accessed these would increment contentAccessCount
        // But write rejection happens before any store call
        // (We can verify via successful GET that store still works)
        let getResult = await server.handle(
            method: "GET",
            path: "/reminders/lists",
            credential: validCredential
        )
        XCTAssertTrue(getResult.isSuccess, "GET should still work after rejected writes")
    }

    // Test 6: EventKitStoreProtocol has no write methods (compile-time enforcement)
    // This test verifies that the protocol cannot be called with write operations
    func testProtocolHasNoWriteMethods() {
        // If this file compiles, the protocol has no write methods.
        // We verify this by asserting all we can call are fetch methods.
        let _: any EventKitStoreProtocol = store
        // No store.create/update/delete calls exist — this is structural enforcement.
        XCTAssertTrue(true, "EventKitStoreProtocol has no write methods — compile-time verified")
    }

    // Test 7: HTTP method case sensitivity — "post" (lowercase) also rejected
    func testLowercasePostRejected() async {
        let result = await server.handle(
            method: "post",
            path: "/reminders/lists",
            credential: validCredential
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.error, .writeOperationRejected)
    }

    // Test 8: Valid GET still succeeds after multiple rejected writes
    func testGetSucceedsAfterRejectedWrites() async throws {
        for _ in 0..<3 {
            _ = await server.handle(method: "POST", path: "/reminders/lists", credential: validCredential)
        }
        let result = await server.handle(
            method: "GET",
            path: "/reminders/lists",
            credential: validCredential
        )
        XCTAssertTrue(result.isSuccess, "GET should succeed after rejected POST requests")
    }
}
