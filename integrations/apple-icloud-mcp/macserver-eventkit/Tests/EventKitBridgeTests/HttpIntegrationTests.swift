// HttpIntegrationTests.swift
// NEW_IMPLEMENTATION | EXHAUSTIVE_LOOPBACK_HTTP_TESTS
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Real loopback HTTP integration tests verifying:
// 1. Auth enforcement (401 on missing/bad token)
// 2. Allowlist exact match & prefix rejection (403)
// 3. FIX-R4A-01: Metadata-only returns 0 content, 0 count fields, 0 store content accesses
// 4. FIX-R4A-02: Content query enforces iCloud source before item access
// 5. Write isolation: POST/PUT/DELETE/PATCH all return 405 with 0 store mutations
// 6. Request deadline enforcement and non-blocking health check
// 7. Chunked fragmented header handling and 16KB limit enforcement (431)
// 8. Client early disconnect resilience (no server crash or hang)
// 9. Mandatory Source Rejection Matrix (Unbound, Wrong Source ID, Local, Spoofed Title)
//    - ALL included in allowlist, yet ALL rejected with 403 and ZERO content accesses!
// 10. Strict Production Configuration Validation (rejection on missing fields, zero fallback)

import XCTest
@testable import EventKitBridge

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class HttpIntegrationTests: XCTestCase {

    var store: FakeEventKitStore!
    var authValidator: AuthValidator!
    var allowlistValidator: AllowlistValidator!
    var requestLimiter: RequestLimiter!
    var server: EventKitBridgeServer!
    var config: BridgeConfig!
    var baseURL: URL!
    var boundPort: Int = 0

    override func setUp() async throws {
        try await super.setUp()

        let validTokens: Set<String> = ["test-valid-bearer-token"]

        // Include valid lists AND test rejection targets in the allowlist
        // to strictly prove rejection is caused by source verification, not allowlist!
        let allowedLists: Set<String> = [
            "fake-list-icloud-001",
            "fake-list-icloud-002",
            "fake-list-unbound-001",
            "fake-list-wrong-source-001",
            "fake-list-local-001",
            "fake-list-spoofed-001"
        ]

        config = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0, // Request OS-assigned free ephemeral port
            timeoutSeconds: 3.0,
            maxConcurrentRequests: 10,
            maxHeaderSizeBytes: 16384,
            allowedListIDs: allowedLists,
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud"),
                "fake-list-icloud-002": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud"),
                // Intentionally bind fake-list-wrong-source-001 to expected UUID that will mismatch seed
                "fake-list-wrong-source-001": SourceIdentity(sourceID: "src-expected-clean-uuid", sourceType: "calDAV", sourceTitle: "iCloud"),
                // Intentionally bind fake-list-local-001
                "fake-list-local-001": SourceIdentity(sourceID: "src-local-machine", sourceType: "local", sourceTitle: "Local"),
                // Intentionally bind fake-list-spoofed-001
                "fake-list-spoofed-001": SourceIdentity(sourceID: "src-local-store", sourceType: "calDAV", sourceTitle: "iCloud")
                // fake-list-unbound-001 is deliberately omitted from listBindings!
            ],
            validTokens: validTokens,
            rateLimitRPS: 100,
            useFakeStore: true
        )

        let sourceVerifier = SourceVerifier(
            allowedSourceTypes: config.allowedSourceTypes,
            allowedSourceTitles: config.allowedSources,
            listBindings: config.listBindings,
            requireExplicitBinding: true
        )

        store = FakeEventKitStore(sourceVerifier: sourceVerifier)
        await store.resetCounters()

        authValidator = AuthValidator(allowedTokens: config.validTokens)
        allowlistValidator = AllowlistValidator(allowedIDs: config.allowedListIDs)
        requestLimiter = RequestLimiter(capacity: config.rateLimitRPS, refillPerSecond: config.rateLimitRPS)

        server = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: config
        )

        try await server.start()
        boundPort = await server.boundPort
        XCTAssertGreaterThan(boundPort, 0, "Server must bind to an actual port > 0")
        baseURL = URL(string: "http://127.0.0.1:\(boundPort)")!
    }

    override func tearDown() async throws {
        await server.stop()
        try await super.tearDown()
    }

    // MARK: — 1. Health Check (Non-blocking unauthenticated)

    func testRealHttpHealthCheck() async throws {
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["mode"] as? String, "readonly")
    }

    // MARK: — 2. Auth Enforcement

    func testRealHttpMissingAuthHeaderReturns401() async throws {
        let url = baseURL.appendingPathComponent("reminders/lists")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 401)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "AUTHENTICATION_FAILED")
    }

    func testRealHttpInvalidBearerTokenReturns401() async throws {
        let url = baseURL.appendingPathComponent("reminders/lists")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer completely-invalid-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 401)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "AUTHENTICATION_FAILED")
    }

    // MARK: — 3. FIX-R4A-01: Metadata-Only Zero Content Query

    func testRealHttpMetadataOnlyNeverQueriesReminderContent() async throws {
        let initialAccessCount = await store.contentAccessCount
        XCTAssertEqual(initialAccessCount, 0)

        let url = baseURL.appendingPathComponent("reminders/lists")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)

        let lists = try JSONDecoder().decode([RemindersList].self, from: data)
        XCTAssertFalse(lists.isEmpty)

        // Structure check: Only metadata properties present
        for list in lists {
            XCTAssertFalse(list.listID.isEmpty)
            XCTAssertFalse(list.title.isEmpty)
            XCTAssertFalse(list.sourceID.isEmpty)
            XCTAssertFalse(list.sourceType.isEmpty)
        }

        // CRITICAL ASSERTION: Zero content or count queries
        let finalAccessCount = await store.contentAccessCount
        XCTAssertEqual(finalAccessCount, 0, "FIX-R4A-01: Metadata query touched reminder content!")
    }

    // MARK: — 4. FIX-R4A-02: Content Reading on Legitimate iCloud List

    func testRealHttpContentQuerySucceedsForLegitimateICloudList() async throws {
        let validListURL = baseURL.appendingPathComponent("reminders/lists/fake-list-icloud-001/items")
        var validRequest = URLRequest(url: validListURL)
        validRequest.httpMethod = "GET"
        validRequest.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: validRequest)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        let items = try JSONDecoder().decode([ReminderItem].self, from: data)
        XCTAssertEqual(items.count, 2)

        let countAfterValid = await store.contentAccessCount
        XCTAssertEqual(countAfterValid, 1)
    }

    // MARK: — 5. Allowlist Exact Match Enforcement

    func testRealHttpNonAllowlistedListRejected() async throws {
        let nonWhitelistedURL = baseURL.appendingPathComponent("reminders/lists/unauthorized-list-999/items")
        var request = URLRequest(url: nonWhitelistedURL)
        request.httpMethod = "GET"
        request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 403)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "LIST_NOT_ALLOWED")
    }

    // MARK: — 6. Write Isolation (POST, PUT, DELETE, PATCH return 405 with 0 store writes)

    func testRealHttpWriteOperationsRejectedWith405() async throws {
        let testMethods = ["POST", "PUT", "DELETE", "PATCH"]
        let targetURLs = [
            baseURL.appendingPathComponent("reminders/lists"),
            baseURL.appendingPathComponent("reminders/lists/fake-list-icloud-001/items"),
            baseURL.appendingPathComponent("reminders/items")
        ]

        for method in testMethods {
            for target in targetURLs {
                var request = URLRequest(url: target)
                request.httpMethod = method
                request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")
                request.httpBody = Data("{\"title\": \"Unauthorized write attempt\"}".utf8)

                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

                XCTAssertEqual(httpResponse.statusCode, 405)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(json["code"] as? String, "WRITE_OPERATION_REJECTED")
            }
        }
    }

    // MARK: — 7. Source Rejection Matrix (All whitelisted, yet rejected before content access!)

    func testSourceRejectionMatrixZeroContentAccess() async throws {
        let targets = [
            ("fake-list-unbound-001", "Unbound list"),
            ("fake-list-wrong-source-001", "Wrong source ID list"),
            ("fake-list-local-001", "Local source type list"),
            ("fake-list-spoofed-001", "Spoofed title list")
        ]

        for (listID, description) in targets {
            await store.resetCounters()
            let initialCount = await store.contentAccessCount
            XCTAssertEqual(initialCount, 0)

            let targetURL = baseURL.appendingPathComponent("reminders/lists/\(listID)/items")
            var request = URLRequest(url: targetURL)
            request.httpMethod = "GET"
            request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

            // Must be rejected with 403 Forbidden
            XCTAssertEqual(httpResponse.statusCode, 403, "Target '\(description)' must be rejected with 403")

            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let code = json["code"] as? String
            XCTAssertTrue(code == "SOURCE_MISMATCH" || code == "SOURCE_NOT_ALLOWED",
                          "Target '\(description)' must return source error code, got \(String(describing: code))")

            // CRITICAL VERIFICATION: Content access must be strictly 0!
            let countAfter = await store.contentAccessCount
            XCTAssertEqual(countAfter, 0, "CRITICAL: Target '\(description)' touched reminder content before rejection!")
        }
    }

    // MARK: — 8. Fragmented / Chunked HTTP Header Handling

    func testChunkedHeaderSegmentationHandling() throws {
        // Connect raw TCP socket to test fragmented sending
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(boundPort).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connectRes, 0, "Must connect raw socket to bridge server")

        // Split HTTP request into tiny 5-byte fragments with micro-delays
        let rawHttpRequest = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        let rawData = Array(rawHttpRequest.utf8)

        var offset = 0
        while offset < rawData.count {
            let chunkSize = min(5, rawData.count - offset)
            let chunk = Array(rawData[offset..<(offset + chunkSize)])
            _ = chunk.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress, chunk.count)
            }
            offset += chunkSize
            usleep(1000) // 1ms delay between fragments
        }

        // Read response from socket
        var responseBuffer = [UInt8](repeating: 0, count: 2048)
        let bytesRead = Darwin.read(fd, &responseBuffer, responseBuffer.count)
        XCTAssertGreaterThan(bytesRead, 0)

        let responseStr = String(decoding: responseBuffer[0..<bytesRead], as: UTF8.self)
        XCTAssertTrue(responseStr.contains("HTTP/1.1 200 OK"), "Fragmented request must succeed with 200 OK")
        XCTAssertTrue(responseStr.contains("\"status\":\"ok\""))
    }

    // MARK: — 9. Header Size Limit Enforcement (16KB max -> 431)

    func testHeaderExceeding16KBReturns431() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(boundPort).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connectRes, 0)

        // Send a massive 20KB header
        let padding = String(repeating: "X", count: 20_000)
        let oversizedRequest = "GET /health HTTP/1.1\r\nX-Padding: \(padding)\r\n\r\n"
        let data = Array(oversizedRequest.utf8)

        _ = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, data.count)
        }

        var responseBuffer = [UInt8](repeating: 0, count: 2048)
        let bytesRead = Darwin.read(fd, &responseBuffer, responseBuffer.count)
        XCTAssertGreaterThan(bytesRead, 0)

        let responseStr = String(decoding: responseBuffer[0..<bytesRead], as: UTF8.self)
        XCTAssertTrue(responseStr.contains("431 Request Header Fields Too Large"),
                      "Headers over 16KB must return HTTP 431")
    }

    // MARK: — 10. Client Early Disconnect Resilience

    func testClientEarlyDisconnectHandledGracefully() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(boundPort).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Send half a request line and abruptly close
        let partial = "GET /re"
        _ = partial.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
        Darwin.close(fd)

        // Give server 50ms to process socket close
        usleep(50000)

        // Server must remain completely healthy for next request
        let healthURL = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"

        let expectation = expectation(description: "Health check responds after client disconnect")
        _ = Task {
            do {
                let (_, res) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200)
                expectation.fulfill()
            } catch {
                XCTFail("Health check failed after client disconnect: \(error)")
            }
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: — 11. Production Configuration Validation (Rejection & No Fallback)

    func testProductionConfigurationStrictValidation() {
        // Test A: Production mode with missing valid tokens throws emptyTokenSet
        let missingTokens = BridgeConfig(
            mode: .production,
            host: "127.0.0.1",
            allowedListIDs: ["list-1"],
            listBindings: ["list-1": SourceIdentity(sourceID: "src-1", sourceType: "calDAV", sourceTitle: "iCloud")],
            validTokens: [] // Missing
        )
        XCTAssertThrowsError(try missingTokens.validateForProduction()) { error in
            XCTAssertEqual(error as? ConfigurationError, .emptyTokenSet)
        }

        // Test B: Production mode with test token throws testTokenInProduction
        let testTokenInProd = BridgeConfig(
            mode: .production,
            host: "127.0.0.1",
            allowedListIDs: ["list-1"],
            listBindings: ["list-1": SourceIdentity(sourceID: "src-1", sourceType: "calDAV", sourceTitle: "iCloud")],
            validTokens: ["test-token-001"] // Forbidden test token
        )
        XCTAssertThrowsError(try testTokenInProd.validateForProduction()) { error in
            XCTAssertEqual(error as? ConfigurationError, .testTokenInProduction("test-token-001"))
        }

        // Test C: Production mode with allowlisted list lacking binding throws missingListBinding
        let missingBinding = BridgeConfig(
            mode: .production,
            host: "127.0.0.1",
            allowedListIDs: ["list-unbound-999"],
            listBindings: [:], // Empty bindings
            validTokens: ["prod-secure-token-abcdef"]
        )
        XCTAssertThrowsError(try missingBinding.validateForProduction()) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingListBinding(listID: "list-unbound-999"))
        }
    }

    // MARK: — 12. Fault/Chaos Tests: Slow Headers, Slow Bodies, Hanging Stores, Large Responses, Restarts

    func testSlowRequestHeaderDeadlineEnforced() async throws {
        let tightConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 3.0,
            maxConcurrentRequests: 10,
            maxHeaderSizeBytes: 16384,
            headerReadTimeoutSeconds: 0.8,
            bodyReadTimeoutSeconds: 1.0,
            allowedListIDs: ["fake-list-icloud-001"],
            validTokens: ["test-valid-bearer-token"]
        )
        let tightServer = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: tightConfig
        )
        try await tightServer.start()
        defer { Task { await tightServer.stop() } }
        let port = await tightServer.boundPort

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let partial = "GET /reminders/lists HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        _ = partial.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }

        try await Task.sleep(nanoseconds: 1_100_000_000)

        var buf = [UInt8](repeating: 0, count: 1024)
        let bytesRead = Darwin.read(fd, &buf, buf.count)
        if bytesRead > 0 {
            let resStr = String(decoding: buf[0..<bytesRead], as: UTF8.self)
            XCTAssertTrue(resStr.contains("408") || resStr.contains("REQUEST_TIMEOUT"))
        }

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (_, healthRes) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((healthRes as? HTTPURLResponse)?.statusCode, 200)
    }

    func testSlowRequestBodyDeadlineEnforced() async throws {
        let tightConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 3.0,
            maxConcurrentRequests: 10,
            maxHeaderSizeBytes: 16384,
            headerReadTimeoutSeconds: 3.0,
            bodyReadTimeoutSeconds: 0.8,
            allowedListIDs: ["fake-list-icloud-001"],
            validTokens: ["test-valid-bearer-token"]
        )
        let tightServer = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: tightConfig
        )
        try await tightServer.start()
        defer { Task { await tightServer.stop() } }
        let port = await tightServer.boundPort

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let req = "POST /reminders/lists HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 500\r\n\r\n0123456789"
        _ = req.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }

        try await Task.sleep(nanoseconds: 1_100_000_000)

        var buf = [UInt8](repeating: 0, count: 512)
        let readAfterTimeout = Darwin.read(fd, &buf, buf.count)
        XCTAssertTrue(readAfterTimeout <= 0)

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (_, healthRes) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((healthRes as? HTTPURLResponse)?.statusCode, 200)
    }

    func testUncooperativeHangingStoreDoesNotBlockHttpTimeout() async throws {
        await store.setHanging(indefinitely: true)

        let tightConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 1.0,
            maxConcurrentRequests: 10,
            allowedListIDs: ["fake-list-icloud-001"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-valid-bearer-token"]
        )
        let hangServer = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: tightConfig
        )
        try await hangServer.start()
        defer { Task { await hangServer.stop() } }
        let port = await hangServer.boundPort

        let url = URL(string: "http://127.0.0.1:\(port)/reminders/lists/fake-list-icloud-001/items")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(startTime)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 504, "Hanging store must result in 504 Gateway Timeout")
        XCTAssertLessThan(elapsed, 2.5, "HTTP response must return around 1.0s timeout and not hang")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "TIMEOUT")

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (hData, hRes) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((hRes as? HTTPURLResponse)?.statusCode, 200)

        let hJson = try XCTUnwrap(JSONSerialization.jsonObject(with: hData) as? [String: Any])
        XCTAssertEqual(hJson["active_requests"] as? Int, 0, "Active request count must return to 0 after timeout")
    }

    func testLargeResponseFullSendLoop() async throws {
        let largeStore = FakeEventKitStore.makeWithLargeDataSet(itemCount: 300)
        let largeConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 5.0,
            maxConcurrentRequests: 10,
            allowedListIDs: ["fake-list-icloud-001"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-valid-bearer-token"]
        )
        let largeServer = EventKitBridgeServer(
            store: largeStore,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: largeConfig
        )
        try await largeServer.start()
        defer { Task { await largeServer.stop() } }
        let port = await largeServer.boundPort

        let url = URL(string: "http://127.0.0.1:\(port)/reminders/lists/fake-list-icloud-001/items")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let items = try JSONDecoder().decode([ReminderItem].self, from: data)
        XCTAssertEqual(items.count, 300, "Full send loop must deliver all 300 items across multiple chunks")
    }

    func testStopAndRestartWithInFlightRequestsDoesNotPolluteCounter() async throws {
        await store.setHanging(indefinitely: true)

        let testConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 5.0,
            maxConcurrentRequests: 10,
            allowedListIDs: ["fake-list-icloud-001"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-valid-bearer-token"]
        )
        let stopServer = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: testConfig
        )
        try await stopServer.start()
        let port = await stopServer.boundPort

        let url = URL(string: "http://127.0.0.1:\(port)/reminders/lists/fake-list-icloud-001/items")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        Task {
            _ = try? await URLSession.shared.data(for: request)
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        await stopServer.stop()
        let isListeningAfterStop = await stopServer.isListening
        XCTAssertFalse(isListeningAfterStop)

        try await stopServer.start()
        let isListeningAfterRestart = await stopServer.isListening
        XCTAssertTrue(isListeningAfterRestart)

        let activeCount = await stopServer.activeRequestsCount
        XCTAssertEqual(activeCount, 0, "Restarted server must start with 0 active requests")

        let restartedPort = await stopServer.boundPort
        let healthURL = URL(string: "http://127.0.0.1:\(restartedPort)/health")!
        let (hData, hRes) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((hRes as? HTTPURLResponse)?.statusCode, 200)

        let hJson = try XCTUnwrap(JSONSerialization.jsonObject(with: hData) as? [String: Any])
        XCTAssertEqual(hJson["active_requests"] as? Int, 0)
        XCTAssertGreaterThan(hJson["generation"] as? Int ?? 0, 0, "Server generation must increment on restart")

        await stopServer.stop()
    }

    func testProductionStoreAssemblyExplicitAuthorization() async {
        let sourceVerifier = SourceVerifier()
        let limiter = RequestLimiter()

        let unauthStore = ProductionStoreAssembly.assemble(
            isAuthorized: false,
            sourceVerifier: sourceVerifier,
            requestLimiter: limiter
        )
        do {
            _ = try await unauthStore.fetchListsMetadata()
            XCTFail("Unauthorized store assembly must throw permissionDenied")
        } catch let err as EventKitBridgeError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let authStoreWithoutProvider = ProductionStoreAssembly.assemble(
            isAuthorized: true,
            sourceVerifier: sourceVerifier,
            requestLimiter: limiter,
            authorizedStoreProvider: nil
        )
        do {
            _ = try await authStoreWithoutProvider.fetchListsMetadata()
            XCTFail("Authorized store without injected provider must throw permissionDenied in offline candidate")
        } catch let err as EventKitBridgeError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: — 13. Advanced Lifecycle: Rapid Disconnect Stress, Restart Under Pressure & Store Budget Boundedness

    func testRapidConnectionAndDisconnectStress() async throws {
        let iterations = 25
        let currentPort = boundPort

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    guard fd >= 0 else { return }
                    defer { Darwin.close(fd) }

                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = in_port_t(UInt16(currentPort).bigEndian)
                    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

                    let conn = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    guard conn == 0 else { return }

                    if i % 3 == 0 {
                        // Disconnect immediately after connect
                        Darwin.close(fd)
                    } else if i % 3 == 1 {
                        // Send partial byte and close
                        let b = "G"
                        _ = b.withCString { Darwin.write(fd, $0, 1) }
                        Darwin.close(fd)
                    } else {
                        // Send invalid garbage and close
                        let junk = "INVALID_VERB / HTTP/1.1\r\n\r\n"
                        _ = junk.withCString { Darwin.write(fd, $0, strlen($0)) }
                        Darwin.close(fd)
                    }
                }
            }
        }

        // Allow 100ms for connection teardowns to settle
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify server remains fully healthy and responsive
        let healthURL = baseURL.appendingPathComponent("health")
        let (data, res) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["active_requests"] as? Int, 0)
    }

    func testStopAndRestartUnderPressure() async throws {
        let clientCount = 10
        let reqURL = baseURL.appendingPathComponent("reminders/lists")

        // Fire 10 concurrent requests in flight
        for _ in 0..<clientCount {
            Task { [reqURL] in
                var req = URLRequest(url: reqURL)
                req.httpMethod = "GET"
                req.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        // Stop server under active load
        await server.stop()
        let isStopped = await server.isListening
        XCTAssertFalse(isStopped)

        // Restart server
        try await server.start()
        let isRestarted = await server.isListening
        XCTAssertTrue(isRestarted)

        let newPort = await server.boundPort
        let active = await server.activeRequestsCount
        XCTAssertEqual(active, 0, "Restarted server must reset active request count to 0")

        // Issue request to restarted server to verify operational recovery
        let newHealthURL = URL(string: "http://127.0.0.1:\(newPort)/health")!
        let (data, res) = try await URLSession.shared.data(for: URLRequest(url: newHealthURL))
        XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["active_requests"] as? Int, 0)
    }

    func testStoreResourceBudgetRejectsExcessiveHangingTasks() async throws {
        await store.setHanging(indefinitely: true)

        // Configure server with tight budget: max 2 concurrent store operations, timeout 0.4s
        let budgetConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 0.4,
            maxConcurrentRequests: 10,
            maxConcurrentStoreOperations: 2, // Hard limit of 2 store tasks
            allowedListIDs: ["fake-list-icloud-001"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-valid-bearer-token"]
        )

        let budgetServer = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: budgetConfig
        )
        try await budgetServer.start()
        defer { Task { await budgetServer.stop() } }
        let port = await budgetServer.boundPort

        let url = URL(string: "http://127.0.0.1:\(port)/reminders/lists/fake-list-icloud-001/items")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        // Request 1: Times out at 0.4s, underlying store task remains alive in background
        let (_, res1) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((res1 as? HTTPURLResponse)?.statusCode, 504)

        // Request 2: Times out at 0.4s, 2nd store task remains alive in background
        let (_, res2) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((res2 as? HTTPURLResponse)?.statusCode, 504)

        // Check health: active_store_operations is now 2 (budget exhausted!)
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (hData, hRes) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((hRes as? HTTPURLResponse)?.statusCode, 200)
        let hJson = try XCTUnwrap(JSONSerialization.jsonObject(with: hData) as? [String: Any])
        XCTAssertEqual(hJson["active_store_operations"] as? Int, 2, "Hanging tasks must remain budgeted after HTTP timeout")

        // Request 3: Must be immediately REJECTED with 503 STORE_RESOURCE_LIMIT_EXCEEDED without spawning a 3rd task!
        let startReq3 = Date()
        let (data3, res3) = try await URLSession.shared.data(for: request)
        let elapsedReq3 = Date().timeIntervalSince(startReq3)

        let httpRes3 = try XCTUnwrap(res3 as? HTTPURLResponse)
        XCTAssertEqual(httpRes3.statusCode, 503, "Exhausted store budget must reject new operation with 503")
        XCTAssertLessThan(elapsedReq3, 0.2, "Rejection must happen immediately without waiting for store timeout")

        let json3 = try XCTUnwrap(JSONSerialization.jsonObject(with: data3) as? [String: Any])
        XCTAssertEqual(json3["code"] as? String, "STORE_RESOURCE_LIMIT_EXCEEDED")
    }

    func testStoreResourceBudgetPreservedAcrossMultiRoundStopRestart() async throws {
        await store.setHanging(indefinitely: true)

        let budgetConfig = BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 0.3,
            maxConcurrentRequests: 10,
            maxConcurrentStoreOperations: 2, // Hard limit of 2 store tasks across rounds
            allowedListIDs: ["fake-list-icloud-001"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-valid-bearer-token"]
        )

        let serverInstance = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: budgetConfig
        )

        // --- ROUND 1 ---
        try await serverInstance.start()
        let port1 = await serverInstance.boundPort
        let url1 = URL(string: "http://127.0.0.1:\(port1)/reminders/lists/fake-list-icloud-001/items")!
        var req1 = URLRequest(url: url1)
        req1.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        // Hang -> Timeout (504)
        let (_, res1) = try await URLSession.shared.data(for: req1)
        XCTAssertEqual((res1 as? HTTPURLResponse)?.statusCode, 504)
        let opsAfterReq1 = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAfterReq1, 1)

        // Stop -> Restart
        await serverInstance.stop()
        let opsAfterStop1 = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAfterStop1, 1, "Budget ticket must be preserved across stop")
        try await serverInstance.start()
        let opsAfterRestart1 = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAfterRestart1, 1, "Budget ticket must be preserved across restart")

        // --- ROUND 2 ---
        let port2 = await serverInstance.boundPort
        let url2 = URL(string: "http://127.0.0.1:\(port2)/reminders/lists/fake-list-icloud-001/items")!
        var req2 = URLRequest(url: url2)
        req2.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        // Hang -> Timeout (504)
        let (_, res2) = try await URLSession.shared.data(for: req2)
        XCTAssertEqual((res2 as? HTTPURLResponse)?.statusCode, 504)
        let opsAfterReq2 = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAfterReq2, 2, "Second hanging task consumes 2nd budget slot")

        // Stop -> Restart
        await serverInstance.stop()
        let opsAfterStop2 = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAfterStop2, 2, "Both living tasks must remain budgeted after 2nd stop")
        try await serverInstance.start()
        let opsAfterRestart2 = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAfterRestart2, 2, "Both living tasks must remain budgeted after 2nd restart")

        // --- ROUND 3 (Exhaustion & Cap Check) ---
        let port3 = await serverInstance.boundPort
        let url3 = URL(string: "http://127.0.0.1:\(port3)/reminders/lists/fake-list-icloud-001/items")!
        var req3 = URLRequest(url: url3)
        req3.setValue("Bearer test-valid-bearer-token", forHTTPHeaderField: "Authorization")

        let (data3, res3) = try await URLSession.shared.data(for: req3)
        XCTAssertEqual((res3 as? HTTPURLResponse)?.statusCode, 503, "Must reject operation when cumulative alive tasks hit limit")
        let json3 = try XCTUnwrap(JSONSerialization.jsonObject(with: data3) as? [String: Any])
        XCTAssertEqual(json3["code"] as? String, "STORE_RESOURCE_LIMIT_EXCEEDED")
        let opsAtCap = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsAtCap, 2, "Total living operations must never exceed budget cap of 2")

        // --- RECOVERY ---
        await store.setHanging(indefinitely: false)
        // Give background tasks brief moment to complete and release tickets
        for _ in 0..<20 {
            let current = await serverInstance.activeStoreOperations
            if current == 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let opsRecovered = await serverInstance.activeStoreOperations
        XCTAssertEqual(opsRecovered, 0, "Budget recovers once background store tasks terminate")

        let (_, resRecovered) = try await URLSession.shared.data(for: req3)
        XCTAssertEqual((resRecovered as? HTTPURLResponse)?.statusCode, 200, "Subsequent requests succeed once budget recovered")

        await serverInstance.stop()
    }

    func testLaunchAgentTemplateConsistencyAndProcessLevelStartup() async throws {
        // 1. Generate canonical LaunchAgent plist XML with synthetic test config
        let syntheticBinaryPath = "/Users/shared/bin/EventKitBridgeServer"
        let syntheticToken = "synthetic-secure-test-token-7788"
        let syntheticListID = "synthetic-list-uuid-9900"
        let syntheticSourceID = "synthetic-source-uuid-1122"

        let generatedPlistXML = BridgeConfig.generateLaunchAgentPlist(
            label: "com.muse.macserver-eventkit",
            binaryPath: syntheticBinaryPath,
            mode: .test,
            port: 0,
            allowedListIDs: [syntheticListID],
            bindings: [
                syntheticListID: SourceIdentity(
                    sourceID: syntheticSourceID,
                    sourceType: "calDAV",
                    sourceTitle: "iCloud"
                )
            ],
            bearerToken: syntheticToken,
            maxConcurrent: 8,
            maxStoreOps: 8,
            timeout: 4.5,
            headerTimeout: 2.5,
            bodyTimeout: 2.5,
            maxBodySize: 524_288,
            sendTimeout: 4.0,
            rateLimitRPS: 20,
            isProductionAuthorized: false
        )

        XCTAssertTrue(generatedPlistXML.contains("com.muse.macserver-eventkit"))
        XCTAssertTrue(generatedPlistXML.contains("EVENTKIT_BRIDGE_ALLOWED_LIST_IDS"))
        XCTAssertTrue(generatedPlistXML.contains("EVENTKIT_BRIDGE_BINDINGS"))

        // 2. Parse EnvironmentVariables from generated plist XML
        let parsedEnv = try BridgeConfig.parseEnvironment(fromPlistXML: generatedPlistXML)
        XCTAssertEqual(parsedEnv["EVENTKIT_BRIDGE_MODE"]?.lowercased(), "test")
        XCTAssertEqual(parsedEnv["EVENTKIT_BRIDGE_PORT"], "0")
        XCTAssertEqual(parsedEnv["EVENTKIT_BRIDGE_ALLOWED_LIST_IDS"], syntheticListID)
        XCTAssertEqual(parsedEnv["EVENTKIT_BRIDGE_BEARER_TOKEN"], syntheticToken)

        // 3. Load BridgeConfig from parsed environment
        let loadedConfig = try BridgeConfig.load(from: parsedEnv)
        XCTAssertEqual(loadedConfig.mode, .test)
        XCTAssertEqual(loadedConfig.allowedListIDs, [syntheticListID])
        XCTAssertEqual(loadedConfig.validTokens, [syntheticToken])
        XCTAssertEqual(loadedConfig.maxConcurrentRequests, 8)
        XCTAssertEqual(loadedConfig.maxConcurrentStoreOperations, 8)
        XCTAssertEqual(loadedConfig.timeoutSeconds, 4.5)

        // 4. Process-level server startup verification with parsed config
        let templateVerifier = SourceVerifier(
            allowedSourceTypes: loadedConfig.allowedSourceTypes,
            allowedSourceTitles: loadedConfig.allowedSources,
            listBindings: loadedConfig.listBindings,
            requireExplicitBinding: true
        )
        let templateStore = FakeEventKitStore(sourceVerifier: templateVerifier)
        let templateAuth = AuthValidator(allowedTokens: loadedConfig.validTokens)
        let templateAllowlist = AllowlistValidator(allowedIDs: loadedConfig.allowedListIDs)
        let templateLimiter = RequestLimiter(capacity: loadedConfig.rateLimitRPS, refillPerSecond: loadedConfig.rateLimitRPS)

        let templateServer = EventKitBridgeServer(
            store: templateStore,
            authValidator: templateAuth,
            allowlistValidator: templateAllowlist,
            requestLimiter: templateLimiter,
            config: loadedConfig
        )

        try await templateServer.start()
        let boundPort = await templateServer.boundPort
        XCTAssertGreaterThan(boundPort, 0)

        // Health check
        let healthURL = URL(string: "http://127.0.0.1:\(boundPort)/health")!
        let (hData, hRes) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((hRes as? HTTPURLResponse)?.statusCode, 200)
        let hJson = try XCTUnwrap(JSONSerialization.jsonObject(with: hData) as? [String: Any])
        XCTAssertEqual(hJson["status"] as? String, "ok")

        // Authorized metadata query
        let listsURL = URL(string: "http://127.0.0.1:\(boundPort)/reminders/lists")!
        var listsReq = URLRequest(url: listsURL)
        listsReq.setValue("Bearer \(syntheticToken)", forHTTPHeaderField: "Authorization")
        let (_, listsRes) = try await URLSession.shared.data(for: listsReq)
        XCTAssertEqual((listsRes as? HTTPURLResponse)?.statusCode, 200)

        await templateServer.stop()
    }

    func testProductionEventKitProviderWiringDefaultOff() async throws {
        // 1. Verify live provider factory is constructible
        let providerFactory = ProductionEventKitProvider.makeLiveEventStoreProvider()
        XCTAssertNotNil(providerFactory)

        // 2. Verify ProductionStoreAssembly produces unactivated store when isAuthorized == false
        let unauthStore = ProductionStoreAssembly.assemble(
            isAuthorized: false,
            sourceVerifier: SourceVerifier(listBindings: [:]),
            requestLimiter: RequestLimiter(capacity: 10, refillPerSecond: 10),
            callbackTimeoutSeconds: 5.0,
            authorizedStoreProvider: providerFactory
        )

        do {
            _ = try await unauthStore.fetchListsMetadata()
            XCTFail("Unactivated production store must reject fetchListsMetadata()")
        } catch let err as EventKitBridgeError {
            switch err {
            case .permissionDenied:
                break // Expected!
            default:
                XCTFail("Expected permissionDenied error, got \(err)")
            }
        }
    }
}
