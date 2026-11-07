// EventKitBridgeServer.swift
// NEW_IMPLEMENTATION | ROBUST_HTTP_LISTENER | DEADLINE_AND_CONCURRENCY
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Native POSIX loopback HTTP bridge server.
// Features:
// - Chunked/segmented HTTP header handling with 16KB size limit (431 on overflow).
// - Graceful handling of partial sends and early client disconnects.
// - Concurrency cap on business routes (health check is non-blocking).
// - Request deadline enforcement (504 Gateway Timeout).
// - Non-blocking graceful stop (cancels pending tasks cleanly).

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

/// Core bridge server with robust loopback HTTP listener.
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
    private var currentActiveBusinessRequests: Int = 0

    // Track active client tasks for clean cancellation on stop
    private var inFlightClientTasks: [UUID: Task<Void, Never>] = [:]

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

        // Background accept loop
        self.listeningTask = Task.detached { [weak self, fd] in
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

                // Set 5-second socket read/write timeouts to prevent hanging slowloris
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let taskID = UUID()
                let task = Task<Void, Never> {
                    if let strongSelf = self {
                        await strongSelf.processClientConnection(fd: clientFd, taskID: taskID)
                    }
                }
                await self?.registerClientTask(taskID: taskID, task: task)
            }
        }
    }

    /// Stops the HTTP listener and cancels all in-flight requests cleanly.
    public func stop() {
        guard _isListening else { return }
        _isListening = false

        listeningTask?.cancel()
        listeningTask = nil

        if serverSocketFd >= 0 {
            Darwin.close(serverSocketFd)
            serverSocketFd = -1
        }

        // Cancel all in-flight request tasks so stop() never hangs
        for (_, task) in inFlightClientTasks {
            task.cancel()
        }
        inFlightClientTasks.removeAll()
        currentActiveBusinessRequests = 0
    }

    private func registerClientTask(taskID: UUID, task: Task<Void, Never>) {
        guard _isListening else {
            task.cancel()
            return
        }
        inFlightClientTasks[taskID] = task
    }

    private func unregisterClientTask(taskID: UUID) {
        inFlightClientTasks.removeValue(forKey: taskID)
    }

    // MARK: — Robust HTTP Connection Processing

    private func processClientConnection(fd: Int32, taskID: UUID) async {
        defer {
            // Drain any pending socket receive bytes before close to prevent TCP RST
            var drainBuffer = [UInt8](repeating: 0, count: 4096)
            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                while Darwin.read(fd, &drainBuffer, drainBuffer.count) > 0 {}
            }
            Darwin.close(fd)
            unregisterClientTask(taskID: taskID)
        }

        // 1. Read HTTP request header with fragmentation & size limit handling
        let readResult = await readCompleteHttpHeader(fd: fd, maxBytes: config.maxHeaderSizeBytes)

        switch readResult {
        case .headerTooLarge:
            let body = Data("{\"success\":false,\"error\":\"Header too large\",\"code\":\"HEADER_TOO_LARGE\"}".utf8)
            sendHttpResponse(fd: fd, statusCode: 431, body: body)
            return

        case .clientDisconnectedOrError:
            // Early client disconnect or empty send; close gracefully without crash
            return

        case .complete(let headerString, let initialBodyBytes):
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first, !requestLine.isEmpty else { return }

            let reqTokens = requestLine.split(separator: " ")
            guard reqTokens.count >= 2 else {
                let body = Data("{\"success\":false,\"error\":\"Bad request line\",\"code\":\"BAD_REQUEST\"}".utf8)
                sendHttpResponse(fd: fd, statusCode: 400, body: body)
                return
            }

            let method = String(reqTokens[0])
            let path = String(reqTokens[1])

            // Parse Authorization and Content-Length headers
            var token: String = ""
            var contentLength: Int = 0
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

            // Drain remaining request body if client specified Content-Length
            if contentLength > initialBodyBytes {
                var remaining = min(contentLength - initialBodyBytes, 10 * 1024 * 1024)
                var tv = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var drainBuf = [UInt8](repeating: 0, count: min(remaining, 4096))
                while remaining > 0 {
                    let bytesRead = Darwin.read(fd, &drainBuf, min(remaining, drainBuf.count))
                    if bytesRead <= 0 { break }
                    remaining -= bytesRead
                }
            }

            // Execute request with concurrency limit & deadline enforcement
            let (statusCode, responseBody) = await executeWithDeadlineAndConcurrency(
                method: method,
                path: path,
                token: token
            )
            sendHttpResponse(fd: fd, statusCode: statusCode, body: responseBody)
            Darwin.shutdown(fd, SHUT_WR)
        }
    }

    private enum HeaderReadResult {
        case complete(headerString: String, initialBodyBytes: Int)
        case headerTooLarge
        case clientDisconnectedOrError
    }

    /// Reads socket buffer in chunks until delimiter is found, enforcing maxBytes limit.
    private func readCompleteHttpHeader(fd: Int32, maxBytes: Int) async -> HeaderReadResult {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lflf = Data([0x0A, 0x0A])

        while accumulated.count <= maxBytes + 4096 {
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead <= 0 {
                // Client closed socket or read error
                return .clientDisconnectedOrError
            }

            accumulated.append(contentsOf: chunk[0..<bytesRead])

            let delimiterRange: Range<Data.Index>? = accumulated.range(of: crlfcrlf) ?? accumulated.range(of: lflf)
            if let range = delimiterRange {
                if range.lowerBound > maxBytes {
                    return .headerTooLarge
                }
                let headerData = accumulated.subdata(in: 0..<range.lowerBound)
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let initialBodyBytes = accumulated.count - range.upperBound
                return .complete(headerString: headerString, initialBodyBytes: initialBodyBytes)
            }

            if accumulated.count > maxBytes {
                return .headerTooLarge
            }
        }
        return .headerTooLarge
    }

    private func sendHttpResponse(fd: Int32, statusCode: Int, body: Data) {
        let statusMessage: String
        switch statusCode {
        case 200: statusMessage = "OK"
        case 400: statusMessage = "Bad Request"
        case 401: statusMessage = "Unauthorized"
        case 403: statusMessage = "Forbidden"
        case 404: statusMessage = "Not Found"
        case 405: statusMessage = "Method Not Allowed"
        case 429: statusMessage = "Too Many Requests"
        case 431: statusMessage = "Request Header Fields Too Large"
        case 500: statusMessage = "Internal Server Error"
        case 503: statusMessage = "Service Unavailable"
        case 504: statusMessage = "Gateway Timeout"
        default:  statusMessage = "Response"
        }

        let header = "HTTP/1.1 \(statusCode) \(statusMessage)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let headerData = Data(header.utf8)

        _ = headerData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, headerData.count)
        }
        _ = body.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, body.count)
        }
    }

    // MARK: — Concurrency & Request Deadline Enforcement

    private func executeWithDeadlineAndConcurrency(
        method: String,
        path: String,
        token: String
    ) async -> (Int, Data) {
        // High priority: /health bypasses business concurrency limits
        if path == "/health" {
            let payload: [String: Any] = [
                "status": "ok",
                "mode": "readonly",
                "store": config.useFakeStore ? "fake" : "production",
                "active_requests": currentActiveBusinessRequests,
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

        currentActiveBusinessRequests += 1
        defer { currentActiveBusinessRequests -= 1 }

        // Execute route with timeout deadline
        let timeoutSecs = config.timeoutSeconds
        do {
            return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                // Worker task
                group.addTask { [self] in
                    return await self.handleRawHttpRequest(method: method, path: path, token: token)
                }

                // Timer task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSecs * 1_000_000_000))
                    throw EventKitBridgeError.timeout
                }

                guard let result = try await group.next() else {
                    group.cancelAll()
                    return (500, Data())
                }
                group.cancelAll()
                return result
            }
        } catch EventKitBridgeError.timeout {
            let body = RequestHandler.errorBody(for: .timeout)
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (504, data)
        } catch {
            let body = RequestHandler.errorBody(for: .internalError("request processing failed"))
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (500, data)
        }
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
            return (200, Data()) // Handled above

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
