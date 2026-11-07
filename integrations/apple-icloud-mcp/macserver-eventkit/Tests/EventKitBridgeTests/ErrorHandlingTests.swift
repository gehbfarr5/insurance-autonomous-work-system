// ErrorHandlingTests.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Tests for timeout, permission revocation, missing objects, and desensitized errors.

import XCTest
@testable import EventKitBridge

final class ErrorHandlingTests: XCTestCase {

    // Test 1: timeout error has desensitized description
    func testTimeoutDesensitized() {
        let err = EventKitBridgeError.timeout
        let desc = err.localizedDescription
        XCTAssertFalse(desc.isEmpty)
        // Must not contain any real IDs or account info
        XCTAssertFalse(desc.contains("@"), "Error must not expose email addresses")
        XCTAssertFalse(desc.contains("token"), "Error must not expose token values")
    }

    // Test 2: permissionDenied error
    func testPermissionDeniedDescription() {
        let err = EventKitBridgeError.permissionDenied
        XCTAssertTrue(err.localizedDescription.contains("denied") ||
                      err.localizedDescription.contains("revoked"))
    }

    // Test 3: listNotFound error
    func testListNotFoundDescription() {
        let err = EventKitBridgeError.listNotFound
        XCTAssertFalse(err.localizedDescription.isEmpty)
    }

    // Test 4: sourceNotAllowed error (FIX-R4A-02)
    func testSourceNotAllowedDescription() {
        let err = EventKitBridgeError.sourceNotAllowed
        let desc = err.localizedDescription
        // Must mention source requirement
        XCTAssertTrue(desc.lowercased().contains("source"))
        // Must NOT include the actual rejected source name
        XCTAssertFalse(desc.contains("Local"))
        XCTAssertFalse(desc.contains("Exchange"))
    }

    // Test 5: writeOperationRejected error
    func testWriteOperationRejectedDescription() {
        let err = EventKitBridgeError.writeOperationRejected
        let desc = err.localizedDescription
        XCTAssertTrue(desc.lowercased().contains("write") || desc.lowercased().contains("not permitted"))
    }

    // Test 6: authenticationFailed error (desensitized)
    func testAuthenticationFailedDesensitized() {
        let err = EventKitBridgeError.authenticationFailed(reason: "token not recognized")
        let desc = err.localizedDescription
        // Must not echo back the reason in a way that exposes real data
        XCTAssertFalse(desc.isEmpty)
        XCTAssertFalse(desc.contains("tok"), "Must not expose token details to callers")
    }

    // Test 7: RequestHandler.httpStatus returns correct codes
    func testHTTPStatusCodes() {
        XCTAssertEqual(RequestHandler.httpStatus(for: .authenticationFailed(reason: "x")), 401)
        XCTAssertEqual(RequestHandler.httpStatus(for: .listNotAllowed), 403)
        XCTAssertEqual(RequestHandler.httpStatus(for: .sourceNotAllowed), 403)
        XCTAssertEqual(RequestHandler.httpStatus(for: .writeOperationRejected), 405)
        XCTAssertEqual(RequestHandler.httpStatus(for: .rateLimitExceeded), 429)
        XCTAssertEqual(RequestHandler.httpStatus(for: .timeout), 504)
        XCTAssertEqual(RequestHandler.httpStatus(for: .listNotFound), 404)
    }

    // Test 8: RequestHandler.errorBody contains only success and error keys
    func testErrorBodyKeySafety() {
        let body = RequestHandler.errorBody(for: .permissionDenied)
        XCTAssertEqual(body["success"], "false")
        XCTAssertNotNil(body["error"])
        // Must not contain sensitive key names
        XCTAssertNil(body["token"])
        XCTAssertNil(body["listID"])
        XCTAssertNil(body["apple_id"])
    }

    // Test 9: FakeEventKitStore throws listNotFound for unknown ID
    func testFakeStoreListNotFound() async {
        let store = FakeEventKitStore()
        do {
            _ = try await store.fetchReminders(listID: "does-not-exist")
            XCTFail("Should have thrown listNotFound")
        } catch EventKitBridgeError.listNotFound {
            // Expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // Test 10: ProductionEventKitStore throws permissionDenied (stub not activated)
    func testProductionStoreStubThrowsPermissionDenied() async {
        let store = ProductionEventKitStore()
        do {
            _ = try await store.fetchListsMetadata()
            XCTFail("Should have thrown permissionDenied (stub)")
        } catch EventKitBridgeError.permissionDenied {
            // Expected — stub is not activated
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
