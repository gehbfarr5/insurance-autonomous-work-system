// EventKitBridgeServer.swift
// NEW_IMPLEMENTATION | NON_BLOCKING_ASYNC_ENGINE | FULL_SEND_LOOP | BOUNDED_STORE_BUDGET
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Native POSIX loopback HTTP bridge server.
// Architectural Highlights:
// 1. Connection registration occurs prior to starting Worker tasks.
// 2. Centralized fd lifecycle via ManagedSocketHandle guarantees idempotent, zero double-close cleanup.
// 3. Raw socket I/O is completely decoupled from the server Actor into non-blocking workers.
// 4. Chunked/fragmented HTTP header handling with overall deadline and 16KB limit (431 on overflow).
// 5. Request body draining with overall deadline and 1MB capacity limit (413 on overflow).
// 6. Full send loop handling partial writes, EINTR retries, client disconnects, and SO_NOSIGPIPE.
// 7. Bounded Store Resource Budget: Hanging Store operations continue to be accounted in the
//    resource budget until actual termination. When budget is exhausted, new operations are rejected (503),
//    preventing unbounded background task accumulation.
// 8. Graceful stop and restart: Closes all active connection sockets idempotently, terminates client tasks,
//    and uses server generation tracking so old requests never pollute restarted counters.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Route definitions for the EventKit bridge HTTP API.
public enum BridgeRoute: Sendable, Equatable {
    case health                       // GET /health
    case listReminders                // GET /reminders/lists
    case getReminders(listID: String) // GET /reminders/lists/{listID}/items

    public static func parse(method: String, path: String) -> BridgeRoute? {
        let upperMethod = method.uppercased()
        guard upperMethod == "GET" else { return nil }

        let cleanPath = path.components(separatedBy: "?").first ?? path
        if cleanPath == "/health" {
            return .health
        }
        if cleanPath == "/reminders/lists" {
            return .listReminders
        }

        let parts = cleanPath.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 4,
           parts[0] == "reminders",
           parts[1] == "lists",
           parts[3] == "items" {
            return .getReminders(listID: String(parts[2]))
        }
        return nil
    }
}

/// Core bridge server with robust loopback HTTP listener and decoupled socket I/O.
public actor EventKitBridgeServer {

    private let store: any EventKitStoreProtocol
    private let authValidator: AuthValidator
    private let allowlistValidator: AllowlistValidator
    private let requestLimiter: RequestLimiter
    private let config: BridgeConfig

    // Networking & Concurrency state
    private var serverSocketFd: Int32 = -1
    private var actualBoundPort: Int = 0
    private var listeningTask: Task<Void, Never>?
    private var _isListening: Bool = false
    private var serverGeneration: Int = 0
    private var currentActiveBusinessRequests: Int = 0

    // Strict Store Resource Budget tracking across generations and restarts
    private var activeStoreOperationIDs: Set<UUID> = []

    // Active connection tracking for idempotent teardown on stop
    private var activeConnections: [UUID: ManagedSocketHandle] = [:]
    private var activeClientTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        store: any EventKitStoreProtocol,
        authValidator: AuthValidator,
        allowlistValidator: AllowlistValidator,
        requestLimiter: RequestLimiter,
        config: BridgeConfig
    ) {
        self.store = store
        self.authValidator = authValidator
        self.allowlistValidator = allowlistValidator
        self.requestLimiter = requestLimiter
        self.config = config
    }

    public var isListening: Bool { _isListening }
    public var boundPort: Int { actualBoundPort }
    public var activeRequestsCount: Int { currentActiveBusinessRequests }
    public var activeStoreOperations: Int { activeStoreOperationIDs.count }
    public var generation: Int { serverGeneration }

    // MARK: — Lifecycle

    /// Starts the real HTTP listener on loopback.
    public func start() throws {
        guard !_isListening else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EventKitBridgeError.internalError("Failed to create socket")
        }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(config.port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(fd)
            throw EventKitBridgeError.internalError("Failed to bind socket on 127.0.0.1:\(config.port)")
        }

        guard listen(fd, 128) == 0 else {
            Darwin.close(fd)
            throw EventKitBridgeError.internalError("Failed to listen on socket")
        }

        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &actualLen)
            }
        }
        self.actualBoundPort = Int(UInt16(bigEndian: actualAddr.sin_port))
        self.serverSocketFd = fd
        self._isListening = true
        self.currentActiveBusinessRequests = 0
        // NOTE: We intentionally preserve activeStoreOperationIDs across restarts!
        // Living Store operations in the background continue to occupy budget until they release.

        let currentGen = self.serverGeneration
        let capturedConfig = self.config

        // Background accept loop detached outside actor
        self.listeningTask = Task.detached { [weak self, fd, currentGen, capturedConfig] in
            while !Task.isCancelled {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.accept(fd, sockPtr, &clientLen)
                    }
                }

                if clientFd < 0 {
                    break
                }

                guard let server = self else {
                    Darwin.close(clientFd)
                    break
                }

                let socketHandle = ManagedSocketHandle(fd: clientFd)
                let taskID = UUID()

                // Step 1: Register connection with server actor FIRST
                let accepted = await server.registerIncomingConnection(connectionID: taskID, handle: socketHandle)
                guard accepted else {
                    // Registration refused (server stopping); handle was closed safely
                    continue
                }

                // Step 2: Connection registered, now start Worker task
                let worker = SocketConnectionWorker(
                    socketHandle: socketHandle,
                    taskID: taskID,
                    generationID: currentGen,
                    config: capturedConfig
                )

                let clientTask = Task<Void, Never> {
                    await worker.run(server: server)
                }

                await server.attachConnectionTask(connectionID: taskID, task: clientTask)
            }
        }
    }

    /// Stops the HTTP listener, closes active client sockets idempotently, and cancels all pending tasks.
    public func stop() {
        guard _isListening else { return }
        _isListening = false
        serverGeneration += 1
        currentActiveBusinessRequests = 0
        // NOTE: We intentionally preserve activeStoreOperationIDs across stop()!
        // Living Store operations in the background continue to occupy budget until they release.

        listeningTask?.cancel()
        listeningTask = nil

        if serverSocketFd >= 0 {
            Darwin.close(serverSocketFd)
            serverSocketFd = -1
        }

        // Close all active connections idempotently via ManagedSocketHandle
        for (_, handle) in activeConnections {
            handle.closeSafely()
        }
        activeConnections.removeAll()

        // Cancel all connection handler tasks
        for (_, task) in activeClientTasks {
            task.cancel()
        }
        activeClientTasks.removeAll()
    }

    // MARK: — Connection Registration (Centralized Lifecycle)

    public func registerIncomingConnection(connectionID: UUID, handle: ManagedSocketHandle) -> Bool {
        guard _isListening else {
            handle.closeSafely()
            return false
        }
        activeConnections[connectionID] = handle
        return true
    }

    public func attachConnectionTask(connectionID: UUID, task: Task<Void, Never>) {
        guard _isListening, activeConnections[connectionID] != nil else {
            task.cancel()
            return
        }
        activeClientTasks[connectionID] = task
    }

    public func unregisterConnection(connectionID: UUID) {
        activeConnections.removeValue(forKey: connectionID)
        activeClientTasks.removeValue(forKey: connectionID)
    }

    public func releaseStoreOperation(_ opID: UUID) {
        activeStoreOperationIDs.remove(opID)
    }

    public func decrementStoreOperation(generationID: Int) async {
        if !activeStoreOperationIDs.isEmpty {
            activeStoreOperationIDs.remove(activeStoreOperationIDs.first!)
        }
    }

    // MARK: — Request Execution (Inside Actor)

    /// Executes the business logic for an HTTP request with concurrency and deadline enforcement.
    public func executeRequest(
        method: String,
        path: String,
        token: String,
        generationID: Int
    ) async -> (Int, Data) {
        // Drop requests belonging to an old server generation or if stopped
        guard _isListening, self.serverGeneration == generationID else {
            let body = RequestHandler.errorBody(for: .internalError("Server stopped or restarted"))
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (503, data)
        }

        // High priority: /health bypasses business concurrency limits
        if path == "/health" {
            let payload: [String: Any] = [
                "status": "ok",
                "mode": "readonly",
                "store": config.useFakeStore ? "fake" : "production",
                "active_requests": currentActiveBusinessRequests,
                "active_store_operations": activeStoreOperationIDs.count,
                "max_store_operations": config.maxConcurrentStoreOperations,
                "generation": self.serverGeneration,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return (200, data)
        }

        // Business route concurrency cap check
        guard currentActiveBusinessRequests < config.maxConcurrentRequests else {
            let err = [
                "success": "false",
                "error": "Server busy. Concurrency limit reached.",
                "code": "CONCURRENCY_LIMIT_EXCEEDED"
            ]
            let data = (try? JSONSerialization.data(withJSONObject: err)) ?? Data()
            return (503, data)
        }

        // Bounded Store Resource Budget check across all living operations (across restarts)
        guard activeStoreOperationIDs.count < config.maxConcurrentStoreOperations else {
            let err = [
                "success": "false",
                "error": "Store resource budget exceeded. Background operations quarantined.",
                "code": "STORE_RESOURCE_LIMIT_EXCEEDED"
            ]
            let data = (try? JSONSerialization.data(withJSONObject: err)) ?? Data()
            return (503, data)
        }

        let opID = UUID()
        activeStoreOperationIDs.insert(opID)
        currentActiveBusinessRequests += 1

        defer {
            if self.serverGeneration == generationID {
                currentActiveBusinessRequests = max(0, currentActiveBusinessRequests - 1)
            }
        }

        let timeoutSecs = config.timeoutSeconds

        // Execute route with deadline enforcement.
        // Worker task runs Store operation; its completion releases the unique opID budget ticket.
        // If the Store hangs, HTTP 504 is returned immediately to the client at timeoutSecs,
        // while activeStoreOperationIDs continues to track the hanging background task until termination!
        let response: (Int, Data) = await withCheckedContinuation { continuation in
            let isResumed = StoreAtomicBool(false)

            let workerTask = Task { [self] in
                defer {
                    Task { [self] in
                        await self.releaseStoreOperation(opID)
                    }
                }
                let res = await self.handleRawHttpRequest(method: method, path: path, token: token)
                if !isResumed.getAndSet(true) {
                    continuation.resume(returning: res)
                }
            }

            // Watchdog timer
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSecs * 1_000_000_000))
                if !isResumed.getAndSet(true) {
                    workerTask.cancel()
                    let body = RequestHandler.errorBody(for: .timeout)
                    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
                    continuation.resume(returning: (504, data))
                }
            }
        }

        return response
    }

    // MARK: — Business Route Processing

    private func handleRawHttpRequest(method: String, path: String, token: String) async -> (Int, Data) {
        let upperMethod = method.uppercased()

        // 1. Write isolation: Reject all write verbs with 405
        guard upperMethod == "GET" else {
            let errorBody = RequestHandler.errorBody(for: .writeOperationRejected)
            let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
            return (405, data)
        }

        // 2. Rate limiting check
        do {
            try await requestLimiter.checkLimit()
        } catch {
            let errorBody = RequestHandler.errorBody(for: .rateLimitExceeded)
            let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
            return (429, data)
        }

        // 3. Route parsing
        guard let route = BridgeRoute.parse(method: method, path: path) else {
            let errorBody = RequestHandler.errorBody(for: .internalError("unknown route"))
            let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
            return (404, data)
        }

        let credential = BridgeCredential(token: token, scopes: [.listMetadata, .reminderRead])

        switch route {
        case .health:
            return (200, Data())

        case .listReminders:
            // FIX-R4A-01: Metadata-only query. Strictly never touches reminder content or counts.
            do {
                try authValidator.validate(credential: credential, requiredScope: .listMetadata)
                let lists = try await store.fetchListsMetadata()
                let encoder = JSONEncoder()
                let data = try encoder.encode(lists)
                return (200, data)
            } catch let e as EventKitBridgeError {
                let status = RequestHandler.httpStatus(for: e)
                let body = RequestHandler.errorBody(for: e)
                let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
                return (status, data)
            } catch {
                let body = RequestHandler.errorBody(for: .internalError("unexpected error"))
                let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
                return (500, data)
            }

        case .getReminders(let listID):
            do {
                try authValidator.validate(credential: credential, requiredScope: .reminderRead)
                try allowlistValidator.validate(listID: listID)

                // FIX-R4A-02: Content query with source verification inside store
                let items = try await store.fetchReminders(listID: listID)
                let encoder = JSONEncoder()
                let data = try encoder.encode(items)
                return (200, data)
            } catch let e as EventKitBridgeError {
                let status = RequestHandler.httpStatus(for: e)
                let body = RequestHandler.errorBody(for: e)
                let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
                return (status, data)
            } catch {
                let body = RequestHandler.errorBody(for: .internalError("unexpected error"))
                let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
                return (500, data)
            }
        }
    }

    /// Preserved direct in-memory invocation seam.
    public func handle(method: String, path: String, credential: BridgeCredential) async -> BridgeHandlerResult {
        guard method.uppercased() == "GET" else {
            return .failure(EventKitBridgeError.writeOperationRejected)
        }

        do {
            try await requestLimiter.checkLimit()
        } catch {
            return .failure(EventKitBridgeError.rateLimitExceeded)
        }

        guard let route = BridgeRoute.parse(method: method, path: path) else {
            return .failure(EventKitBridgeError.internalError("unknown route"))
        }

        switch route {
        case .health:
            return .lists([])
        case .listReminders:
            do {
                try authValidator.validate(credential: credential, requiredScope: .listMetadata)
                let lists = try await store.fetchListsMetadata()
                return .lists(lists)
            } catch let e as EventKitBridgeError {
                return .failure(e)
            } catch {
                return .failure(.internalError("unexpected"))
            }
        case .getReminders(let listID):
            do {
                try authValidator.validate(credential: credential, requiredScope: .reminderRead)
                try allowlistValidator.validate(listID: listID)
                let items = try await store.fetchReminders(listID: listID)
                return .items(items)
            } catch let e as EventKitBridgeError {
                return .failure(e)
            } catch {
                return .failure(.internalError("fetch"))
            }
        }
    }
}

// MARK: — Decoupled Socket Connection Worker (Non-Actor POSIX Network Engine)

struct SocketConnectionWorker: Sendable {
    let socketHandle: ManagedSocketHandle
    let taskID: UUID
    let generationID: Int
    let config: BridgeConfig

    var clientFd: Int32 { socketHandle.rawFd }

    func run(server: EventKitBridgeServer) async {
        defer {
            // Idempotent safe close guarantees no double-close even if server.stop() also closes
            socketHandle.closeSafely()
            Task {
                await server.unregisterConnection(connectionID: taskID)
            }
        }

        // 1. Configure socket: SO_NOSIGPIPE to prevent SIGPIPE signal crashes on broken pipe
        var one: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // Set socket-level read/write timeouts (500ms chunk timeout)
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // 2. Read HTTP headers with overall deadline & capacity limit
        let headerResult = await readHeadersWithDeadline()
        guard case .complete(let headerString, let initialBodyBytes) = headerResult else {
            if case .headerTooLarge = headerResult {
                let errBody = Data("{\"success\":false,\"error\":\"Header too large\",\"code\":\"HEADER_TOO_LARGE\"}".utf8)
                _ = Self.sendHttpResponseFull(fd: clientFd, statusCode: 431, body: errBody, timeoutSeconds: config.sendTimeoutSeconds)
            } else if case .timedOut = headerResult {
                let errBody = Data("{\"success\":false,\"error\":\"Header read timed out\",\"code\":\"REQUEST_TIMEOUT\"}".utf8)
                _ = Self.sendHttpResponseFull(fd: clientFd, statusCode: 408, body: errBody, timeoutSeconds: config.sendTimeoutSeconds)
            }
            return
        }

        // 3. Parse request line & headers
        guard let request = parseHttpRequest(headerString) else {
            let errBody = Data("{\"success\":false,\"error\":\"Bad request line\",\"code\":\"BAD_REQUEST\"}".utf8)
            _ = Self.sendHttpResponseFull(fd: clientFd, statusCode: 400, body: errBody, timeoutSeconds: config.sendTimeoutSeconds)
            return
        }

        // 4. Handle request body with deadline & capacity limit if Content-Length present
        if request.contentLength > 0 {
            if request.contentLength > config.maxBodySizeBytes {
                let errBody = Data("{\"success\":false,\"error\":\"Payload too large\",\"code\":\"PAYLOAD_TOO_LARGE\"}".utf8)
                _ = Self.sendHttpResponseFull(fd: clientFd, statusCode: 413, body: errBody, timeoutSeconds: config.sendTimeoutSeconds)
                return
            }
            let bodySuccess = await drainBodyWithDeadline(
                contentLength: request.contentLength,
                initialBodyBytes: initialBodyBytes
            )
            if !bodySuccess {
                return
            }
        }

        // 5. Delegate business processing to server Actor
        let (statusCode, responseBody) = await server.executeRequest(
            method: request.method,
            path: request.path,
            token: request.token,
            generationID: generationID
        )

        // 6. Send HTTP response using full send loop (handling partial writes, EINTR, broken pipes)
        _ = Self.sendHttpResponseFull(
            fd: clientFd,
            statusCode: statusCode,
            body: responseBody,
            timeoutSeconds: config.sendTimeoutSeconds
        )

        Darwin.shutdown(clientFd, SHUT_WR)
    }

    // MARK: — Header and Body Reading

    private enum HeaderReadResult {
        case complete(headerString: String, initialBodyBytes: Int)
        case headerTooLarge
        case timedOut
        case clientDisconnectedOrError
    }

    private func readHeadersWithDeadline() async -> HeaderReadResult {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lflf = Data([0x0A, 0x0A])
        let deadline = Date().addingTimeInterval(config.headerReadTimeoutSeconds)

        while accumulated.count <= config.maxHeaderSizeBytes + 4096 {
            if Date() > deadline {
                return .timedOut
            }

            let bytesRead = Darwin.read(clientFd, &chunk, chunk.count)
            if bytesRead <= 0 {
                let err = errno
                if bytesRead < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                    if Date() > deadline {
                        return .timedOut
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                return .clientDisconnectedOrError
            }

            accumulated.append(contentsOf: chunk[0..<bytesRead])

            let delimiterRange: Range<Data.Index>? = accumulated.range(of: crlfcrlf) ?? accumulated.range(of: lflf)
            if let range = delimiterRange {
                if range.lowerBound > config.maxHeaderSizeBytes {
                    return .headerTooLarge
                }
                let headerData = accumulated.subdata(in: 0..<range.lowerBound)
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let initialBodyBytes = accumulated.count - range.upperBound
                return .complete(headerString: headerString, initialBodyBytes: initialBodyBytes)
            }

            if accumulated.count > config.maxHeaderSizeBytes {
                return .headerTooLarge
            }
        }
        return .headerTooLarge
    }

    private func drainBodyWithDeadline(contentLength: Int, initialBodyBytes: Int) async -> Bool {
        if contentLength <= initialBodyBytes {
            return true
        }
        var remaining = min(contentLength - initialBodyBytes, config.maxBodySizeBytes)
        let deadline = Date().addingTimeInterval(config.bodyReadTimeoutSeconds)
        var drainBuf = [UInt8](repeating: 0, count: min(remaining, 4096))

        while remaining > 0 {
            if Date() > deadline {
                return false
            }
            let bytesRead = Darwin.read(clientFd, &drainBuf, min(remaining, drainBuf.count))
            if bytesRead > 0 {
                remaining -= bytesRead
            } else if bytesRead < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    if Date() > deadline {
                        return false
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                return false
            } else {
                return false
            }
        }
        return true
    }

    // MARK: — Request Parsing

    private struct ParsedHttpRequest {
        let method: String
        let path: String
        let token: String
        let contentLength: Int
    }

    private func parseHttpRequest(_ headerString: String) -> ParsedHttpRequest? {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }

        let reqTokens = requestLine.split(separator: " ")
        guard reqTokens.count >= 2 else { return nil }

        let method = String(reqTokens[0])
        let path = String(reqTokens[1])

        var token = ""
        var contentLength = 0

        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("authorization:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let headerVal = parts[1].trimmingCharacters(in: .whitespaces)
                    if headerVal.lowercased().hasPrefix("bearer ") {
                        token = String(headerVal.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    }
                }
            } else if lower.hasPrefix("content-length:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    contentLength = len
                }
            }
        }

        return ParsedHttpRequest(
            method: method,
            path: path,
            token: token,
            contentLength: contentLength
        )
    }

    // MARK: — Full Response Sending Loop (Handles Partial Writes, EINTR, Broken Pipes)

    public static func sendHttpResponseFull(
        fd: Int32,
        statusCode: Int,
        body: Data,
        timeoutSeconds: Double = 5.0
    ) -> Bool {
        let statusMessage: String
        switch statusCode {
        case 200: statusMessage = "OK"
        case 400: statusMessage = "Bad Request"
        case 401: statusMessage = "Unauthorized"
        case 403: statusMessage = "Forbidden"
        case 404: statusMessage = "Not Found"
        case 405: statusMessage = "Method Not Allowed"
        case 408: statusMessage = "Request Timeout"
        case 413: statusMessage = "Payload Too Large"
        case 429: statusMessage = "Too Many Requests"
        case 431: statusMessage = "Request Header Fields Too Large"
        case 500: statusMessage = "Internal Server Error"
        case 503: statusMessage = "Service Unavailable"
        case 504: statusMessage = "Gateway Timeout"
        default:  statusMessage = "Response"
        }

        let header = "HTTP/1.1 \(statusCode) \(statusMessage)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var fullData = Data(header.utf8)
        fullData.append(body)

        let totalBytes = fullData.count
        var totalWritten = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        return fullData.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }

            while totalWritten < totalBytes {
                if Date() > deadline {
                    return false
                }

                let ptr = baseAddress.advanced(by: totalWritten)
                let remaining = totalBytes - totalWritten
                let bytesWritten = Darwin.write(fd, ptr, remaining)

                if bytesWritten > 0 {
                    totalWritten += bytesWritten
                } else if bytesWritten < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        usleep(5000)
                        continue
                    }
                    if err == EPIPE || err == ECONNRESET || err == ENOTCONN || err == EBADF {
                        return false
                    }
                    return false
                } else {
                    return false
                }
            }
            return totalWritten == totalBytes
        }
    }
}

/// Result type for in-memory bridge handler responses.
public enum BridgeHandlerResult: Sendable {
    case lists([RemindersList])
    case items([ReminderItem])
    case failure(EventKitBridgeError)

    public var isSuccess: Bool {
        switch self {
        case .lists, .items: return true
        case .failure: return false
        }
    }

    public var error: EventKitBridgeError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
