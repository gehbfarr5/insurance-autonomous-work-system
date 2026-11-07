// EventKitBridgeServer.swift
// NEW_IMPLEMENTATION | REAL_HTTP_LISTENER
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// HTTP bridge server — strictly read-only endpoints, native loopback listener.
// All write-method requests (POST, PUT, PATCH, DELETE) are rejected with 405.

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

/// Core bridge server with integrated POSIX loopback HTTP listener.
public actor EventKitBridgeServer {

    private let store: any EventKitStoreProtocol
    private let authValidator: AuthValidator
    private let allowlistValidator: AllowlistValidator
    private let requestLimiter: RequestLimiter
    private let config: BridgeConfig

    // Networking state
    private var serverSocketFd: Int32 = -1
    private var actualBoundPort: Int = 0
    private var listeningTask: Task<Void, Never>?
    private var _isListening: Bool = false

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

    // MARK: — Lifecycle: Real HTTP Listener

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

        // Determine actual bound port (important when port 0 is requested)
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

        // Spawn background accept loop
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
                    // Socket was closed or error occurred
                    break
                }

                // Set client socket timeout
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                Task {
                    await self?.processClient(fd: clientFd)
                }
            }
        }
    }

    /// Stops the HTTP listener and closes listening sockets.
    public func stop() {
        guard _isListening else { return }
        _isListening = false
        listeningTask?.cancel()
        listeningTask = nil

        if serverSocketFd >= 0 {
            Darwin.close(serverSocketFd)
            serverSocketFd = -1
        }
    }

    // MARK: — HTTP Connection Processing

    private func processClient(fd: Int32) async {
        defer { Darwin.close(fd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let requestString = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return }

        let reqTokens = requestLine.split(separator: " ")
        guard reqTokens.count >= 2 else { return }

        let method = String(reqTokens[0])
        let path = String(reqTokens[1])

        // Parse Authorization header
        var token: String = ""
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("authorization:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let headerVal = parts[1].trimmingCharacters(in: .whitespaces)
                    if headerVal.lowercased().hasPrefix("bearer ") {
                        token = String(headerVal.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // Process request through handler
        let (statusCode, responseBody) = await handleRawHttpRequest(method: method, path: path, token: token)
        sendHttpResponse(fd: fd, statusCode: statusCode, body: responseBody)
    }

    private func sendHttpResponse(fd: Int32, statusCode: Int, body: Data) {
        let statusMessage: String
        switch statusCode {
        case 200: statusMessage = "OK"
        case 401: statusMessage = "Unauthorized"
        case 403: statusMessage = "Forbidden"
        case 404: statusMessage = "Not Found"
        case 405: statusMessage = "Method Not Allowed"
        case 429: statusMessage = "Too Many Requests"
        case 500: statusMessage = "Internal Server Error"
        case 504: statusMessage = "Gateway Timeout"
        default:  statusMessage = "HTTP Response"
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

    // MARK: — Core Request Routing

    private func handleRawHttpRequest(method: String, path: String, token: String) async -> (Int, Data) {
        let upperMethod = method.uppercased()

        // 1. Write isolation: Reject any write verb immediately
        guard upperMethod == "GET" else {
            let errorBody = RequestHandler.errorBody(for: .writeOperationRejected)
            let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
            return (405, data)
        }

        // 2. Health check route (unauthenticated)
        if path == "/health" {
            let payload: [String: Any] = [
                "status": "ok",
                "mode": "readonly",
                "store": config.useFakeStore ? "fake" : "production",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return (200, data)
        }

        // 3. Rate limiting check
        do {
            try await requestLimiter.checkLimit()
        } catch {
            let errorBody = RequestHandler.errorBody(for: .rateLimitExceeded)
            let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
            return (429, data)
        }

        // 4. Route parsing
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
            // FIX-R4A-01: Metadata-only, zero content query
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

    /// Preserved direct in-memory invocation seam for legacy tests.
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
