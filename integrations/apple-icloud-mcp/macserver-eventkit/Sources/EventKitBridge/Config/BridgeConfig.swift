// BridgeConfig.swift
// NEW_IMPLEMENTATION | PRODUCTION_MODE_VALIDATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Configuration definition, parsing, and production validation.
// Gated: Production mode missing required config MUST throw and reject startup.
// Never silently fall back to test tokens or fake data in production mode.

import Foundation

/// Operational mode of the EventKit bridge.
public enum BridgeOperationMode: String, Sendable, Codable {
    case test = "TEST"
    case production = "PRODUCTION"
}

/// Configuration validation error.
public enum ConfigurationError: Error, Sendable, Equatable {
    case missingRequiredField(String)
    case missingRequiredKey(String)
    case invalidValue(key: String, reason: String)
    case insecureHostConfiguration(String)
    case testTokenInProduction(String)
    case missingListBinding(listID: String)
    case emptyAllowlist
    case emptyTokenSet

    public var localizedDescription: String {
        switch self {
        case .missingRequiredField(let field):
            return "Production configuration error: Missing required field '\(field)'."
        case .missingRequiredKey(let key):
            return "Configuration error: Missing required key '\(key)'."
        case .invalidValue(let key, let reason):
            return "Configuration error for key '\(key)': \(reason)."
        case .insecureHostConfiguration(let host):
            return "Production configuration error: Host '\(host)' is not permitted. Only 127.0.0.1 loopback is allowed."
        case .testTokenInProduction(let token):
            return "Production configuration error: Test token '\(token)' cannot be used in production mode."
        case .missingListBinding(let listID):
            return "Production configuration error: List ID '\(listID)' has no registered SourceIdentity binding."
        case .emptyAllowlist:
            return "Production configuration error: allowedListIDs must not be empty in production mode."
        case .emptyTokenSet:
            return "Production configuration error: validTokens must not be empty in production mode."
        }
    }
}

/// Complete configuration for EventKitBridgeServer.
public struct BridgeConfig: Sendable {

    /// Operating mode (TEST or PRODUCTION).
    public let mode: BridgeOperationMode

    /// Listening host. Strictly enforced loopback ("127.0.0.1").
    public let host: String

    /// Listening port. 0 = dynamic OS allocation. Default: 18765.
    public let port: Int

    /// Request timeout in seconds.
    public let timeoutSeconds: Double

    /// Maximum concurrent business requests (health checks remain unblocked).
    public let maxConcurrentRequests: Int

    /// Maximum concurrent operations permitted to query the Store backend.
    /// Strict resource budget: Hanging operations continue to consume budget until termination.
    public let maxConcurrentStoreOperations: Int

    /// Maximum permitted HTTP header size in bytes (e.g. 16384 = 16KB).
    public let maxHeaderSizeBytes: Int

    /// Total deadline for reading HTTP request headers in seconds.
    public let headerReadTimeoutSeconds: Double

    /// Total deadline for reading/draining request body in seconds.
    public let bodyReadTimeoutSeconds: Double

    /// Maximum permitted HTTP body size in bytes (e.g. 1MB).
    public let maxBodySizeBytes: Int

    /// Total deadline for sending complete HTTP response in seconds.
    public let sendTimeoutSeconds: Double

    /// Allowed list IDs (exact match only).
    public let allowedListIDs: Set<String>

    /// Allowed iCloud source names (e.g. ["iCloud"]).
    public let allowedSources: Set<String>

    /// Allowed underlying source types (e.g. ["caldav"]).
    public let allowedSourceTypes: Set<String>

    /// Mandatory list ID -> SourceIdentity bindings.
    public let listBindings: [String: SourceIdentity]

    /// Authorized bearer tokens.
    public let validTokens: Set<String>

    /// Requests per second rate limit.
    public let rateLimitRPS: Int

    /// Safety flag: true uses FakeEventKitStore; false uses ProductionEventKitStore.
    public let useFakeStore: Bool

    /// Explicit production authorization gate. Default is false.
    public let isProductionAuthorized: Bool

    // Known synthetic test tokens forbidden in production mode
    public static let forbiddenTestTokens: Set<String> = [
        "test-token-001",
        "test-token-002",
        "test-valid-bearer-token",
        "default-test-token"
    ]

    /// Default test configuration (safe offline, fake store, loopback).
    public static var testDefault: BridgeConfig {
        BridgeConfig(
            mode: .test,
            host: "127.0.0.1",
            port: 0,
            timeoutSeconds: 5.0,
            maxConcurrentRequests: 10,
            maxConcurrentStoreOperations: 10,
            maxHeaderSizeBytes: 16384,
            headerReadTimeoutSeconds: 3.0,
            bodyReadTimeoutSeconds: 3.0,
            maxBodySizeBytes: 1_048_576,
            sendTimeoutSeconds: 5.0,
            allowedListIDs: [
                "fake-list-icloud-001",
                "fake-list-icloud-002",
            ],
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: [
                "fake-list-icloud-001": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud"),
                "fake-list-icloud-002": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            validTokens: ["test-token-001", "test-token-002"],
            rateLimitRPS: 50,
            useFakeStore: true,
            isProductionAuthorized: false
        )
    }

    public init(
        mode: BridgeOperationMode = .test,
        host: String = "127.0.0.1",
        port: Int = 18765,
        timeoutSeconds: Double = 5.0,
        maxConcurrentRequests: Int = 10,
        maxConcurrentStoreOperations: Int = 10,
        maxHeaderSizeBytes: Int = 16384,
        headerReadTimeoutSeconds: Double = 3.0,
        bodyReadTimeoutSeconds: Double = 3.0,
        maxBodySizeBytes: Int = 1_048_576,
        sendTimeoutSeconds: Double = 5.0,
        allowedListIDs: Set<String> = [],
        allowedSources: Set<String> = ["iCloud"],
        allowedSourceTypes: Set<String> = ["caldav"],
        listBindings: [String: SourceIdentity] = [:],
        validTokens: Set<String> = [],
        rateLimitRPS: Int = 10,
        useFakeStore: Bool = true,
        isProductionAuthorized: Bool = false
    ) {
        self.mode = mode
        self.host = (host == "127.0.0.1" || host == "localhost") ? "127.0.0.1" : "127.0.0.1"
        self.port = port
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 5.0
        self.maxConcurrentRequests = maxConcurrentRequests > 0 ? maxConcurrentRequests : 10
        self.maxConcurrentStoreOperations = maxConcurrentStoreOperations > 0 ? maxConcurrentStoreOperations : 10
        self.maxHeaderSizeBytes = maxHeaderSizeBytes > 0 ? maxHeaderSizeBytes : 16384
        self.headerReadTimeoutSeconds = headerReadTimeoutSeconds > 0 ? headerReadTimeoutSeconds : 3.0
        self.bodyReadTimeoutSeconds = bodyReadTimeoutSeconds > 0 ? bodyReadTimeoutSeconds : 3.0
        self.maxBodySizeBytes = maxBodySizeBytes > 0 ? maxBodySizeBytes : 1_048_576
        self.sendTimeoutSeconds = sendTimeoutSeconds > 0 ? sendTimeoutSeconds : 5.0
        self.allowedListIDs = allowedListIDs
        self.allowedSources = allowedSources
        self.allowedSourceTypes = allowedSourceTypes
        self.listBindings = listBindings
        self.validTokens = validTokens
        self.rateLimitRPS = rateLimitRPS > 0 ? rateLimitRPS : 10
        self.useFakeStore = useFakeStore
        self.isProductionAuthorized = isProductionAuthorized
    }

    /// Strict production validation. Must throw if any configuration requirement is missing.
    /// Strictly prevents silent fallback to test tokens or fake data in production mode.
    public func validateForProduction() throws {
        guard mode == .production else { return }

        if host != "127.0.0.1" {
            throw ConfigurationError.insecureHostConfiguration(host)
        }

        if validTokens.isEmpty {
            throw ConfigurationError.emptyTokenSet
        }

        // Check for test tokens accidentally left in production config
        for token in validTokens {
            if Self.forbiddenTestTokens.contains(token) {
                throw ConfigurationError.testTokenInProduction(token)
            }
        }

        if allowedListIDs.isEmpty {
            throw ConfigurationError.emptyAllowlist
        }

        // Every allowlisted list must have an explicit source binding
        for listID in allowedListIDs {
            guard let binding = listBindings[listID] else {
                throw ConfigurationError.missingListBinding(listID: listID)
            }
            if binding.sourceID.isEmpty || binding.sourceType.isEmpty || binding.sourceTitle.isEmpty {
                throw ConfigurationError.missingListBinding(listID: listID)
            }
        }

        if allowedSourceTypes.isEmpty {
            throw ConfigurationError.missingRequiredField("allowedSourceTypes")
        }
    }

    /// Parses configuration from environment dictionary with support for bindings and mode.
    public static func load(from environment: [String: String]) throws -> BridgeConfig {
        let modeStr = (environment["EVENTKIT_BRIDGE_MODE"] ?? "TEST").uppercased()
        let mode = (modeStr == "PRODUCTION") ? BridgeOperationMode.production : BridgeOperationMode.test

        let port = Int(environment["EVENTKIT_BRIDGE_PORT"] ?? "") ?? 18765
        let timeout = Double(environment["EVENTKIT_BRIDGE_TIMEOUT"] ?? "") ?? 5.0
        let rps = Int(environment["EVENTKIT_BRIDGE_RATE_LIMIT_RPS"] ?? environment["EVENTKIT_BRIDGE_RPS"] ?? "") ?? 10
        let maxConcurrent = Int(environment["EVENTKIT_BRIDGE_MAX_CONCURRENT"] ?? "") ?? 10

        let allowlistStr = environment["EVENTKIT_BRIDGE_ALLOWED_LIST_IDS"] ?? environment["EVENTKIT_BRIDGE_ALLOWLIST"] ?? ""
        let allowlist = Set(allowlistStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        let tokensStr = environment["EVENTKIT_BRIDGE_BEARER_TOKEN"] ?? environment["EVENTKIT_BRIDGE_TOKENS"] ?? ""
        let tokens = Set(tokensStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        // Parse list bindings: format "listID:sourceID:sourceType:sourceTitle;..." or JSON
        var parsedBindings: [String: SourceIdentity] = [:]
        if let bindingsStr = environment["EVENTKIT_BRIDGE_BINDINGS"], !bindingsStr.isEmpty {
            let entries = bindingsStr.split(separator: ";")
            for entry in entries {
                let parts = entry.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 4 {
                    parsedBindings[parts[0]] = SourceIdentity(
                        sourceID: parts[1],
                        sourceType: parts[2],
                        sourceTitle: parts[3]
                    )
                }
            }
        }

        let useFake = (mode == .test) ? ((environment["EVENTKIT_BRIDGE_USE_FAKE"] ?? environment["EVENTKIT_USE_FAKE"]) != "false") : false
        let isAuthorized = (environment["EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED"] == "true" ||
                            environment["EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED"] == "1" ||
                            environment["EVENTKIT_PRODUCTION_AUTHORIZED"] == "true" ||
                            environment["EVENTKIT_PRODUCTION_AUTHORIZED"] == "1")

        let headerTimeout = Double(environment["EVENTKIT_BRIDGE_HEADER_TIMEOUT"] ?? "") ?? 3.0
        let bodyTimeout = Double(environment["EVENTKIT_BRIDGE_BODY_TIMEOUT"] ?? "") ?? 3.0
        let maxBody = Int(environment["EVENTKIT_BRIDGE_MAX_BODY_SIZE"] ?? "") ?? 1_048_576
        let sendTimeout = Double(environment["EVENTKIT_BRIDGE_SEND_TIMEOUT"] ?? "") ?? 5.0
        let maxStoreOps = Int(environment["EVENTKIT_BRIDGE_MAX_STORE_OPS"] ?? "") ?? maxConcurrent

        let config = BridgeConfig(
            mode: mode,
            host: "127.0.0.1",
            port: port,
            timeoutSeconds: timeout,
            maxConcurrentRequests: maxConcurrent,
            maxConcurrentStoreOperations: maxStoreOps,
            maxHeaderSizeBytes: 16384,
            headerReadTimeoutSeconds: headerTimeout,
            bodyReadTimeoutSeconds: bodyTimeout,
            maxBodySizeBytes: maxBody,
            sendTimeoutSeconds: sendTimeout,
            allowedListIDs: allowlist,
            allowedSources: ["iCloud"],
            allowedSourceTypes: ["caldav"],
            listBindings: parsedBindings,
            validTokens: tokens,
            rateLimitRPS: rps,
            useFakeStore: useFake,
            isProductionAuthorized: isAuthorized
        )

        // If in production mode, validate strictly immediately
        if mode == .production {
            try config.validateForProduction()
        }

        return config
    }

    // MARK: — Canonical LaunchAgent Plist Generation & Parsing

    /// Generates canonical LaunchAgent plist XML directly from configuration fields.
    /// Unifies variable names, file paths, and default configurations.
    public static func generateLaunchAgentPlist(
        label: String = "com.muse.macserver-eventkit",
        binaryPath: String = "/Users/shared/bin/EventKitBridgeServer",
        mode: BridgeOperationMode = .production,
        port: Int = 18765,
        allowedListIDs: [String] = ["TARGET_ICLOUD_LIST_UUID"],
        bindings: [String: SourceIdentity] = [
            "TARGET_ICLOUD_LIST_UUID": SourceIdentity(
                sourceID: "TARGET_ICLOUD_SOURCE_UUID",
                sourceType: "calDAV",
                sourceTitle: "iCloud"
            )
        ],
        bearerToken: String = "GENERATE_SECURE_TOKEN_AT_INSTALL",
        maxConcurrent: Int = 10,
        maxStoreOps: Int = 10,
        timeout: Double = 5.0,
        headerTimeout: Double = 3.0,
        bodyTimeout: Double = 3.0,
        maxBodySize: Int = 1_048_576,
        sendTimeout: Double = 5.0,
        rateLimitRPS: Int = 10,
        isProductionAuthorized: Bool = false,
        stdoutLogPath: String = "/Users/shared/log/macserver-eventkit.stdout.log",
        stderrLogPath: String = "/Users/shared/log/macserver-eventkit.stderr.log"
    ) -> String {
        let bindingsString = bindings.map { "\($0.key):\($0.value.sourceID):\($0.value.sourceType):\($0.value.sourceTitle)" }.joined(separator: ";")
        let allowlistString = allowedListIDs.joined(separator: ",")

        let plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath],
            "EnvironmentVariables": [
                "EVENTKIT_BRIDGE_MODE": mode.rawValue,
                "EVENTKIT_BRIDGE_PORT": String(port),
                "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS": allowlistString,
                "EVENTKIT_BRIDGE_BINDINGS": bindingsString,
                "EVENTKIT_BRIDGE_BEARER_TOKEN": bearerToken,
                "EVENTKIT_BRIDGE_MAX_CONCURRENT": String(maxConcurrent),
                "EVENTKIT_BRIDGE_MAX_STORE_OPS": String(maxStoreOps),
                "EVENTKIT_BRIDGE_TIMEOUT": String(timeout),
                "EVENTKIT_BRIDGE_HEADER_TIMEOUT": String(headerTimeout),
                "EVENTKIT_BRIDGE_BODY_TIMEOUT": String(bodyTimeout),
                "EVENTKIT_BRIDGE_MAX_BODY_SIZE": String(maxBodySize),
                "EVENTKIT_BRIDGE_SEND_TIMEOUT": String(sendTimeout),
                "EVENTKIT_BRIDGE_RATE_LIMIT_RPS": String(rateLimitRPS),
                "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED": isProductionAuthorized ? "true" : "false"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": stdoutLogPath,
            "StandardErrorPath": stderrLogPath
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0),
           let xmlString = String(data: data, encoding: .utf8) {
            return xmlString
        }

        // Fallback formatted XML
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>EVENTKIT_BRIDGE_MODE</key>
                <string>\(mode.rawValue)</string>
                <key>EVENTKIT_BRIDGE_PORT</key>
                <string>\(port)</string>
                <key>EVENTKIT_BRIDGE_ALLOWED_LIST_IDS</key>
                <string>\(allowlistString)</string>
                <key>EVENTKIT_BRIDGE_BINDINGS</key>
                <string>\(bindingsString)</string>
                <key>EVENTKIT_BRIDGE_BEARER_TOKEN</key>
                <string>\(bearerToken)</string>
                <key>EVENTKIT_BRIDGE_MAX_CONCURRENT</key>
                <string>\(maxConcurrent)</string>
                <key>EVENTKIT_BRIDGE_MAX_STORE_OPS</key>
                <string>\(maxStoreOps)</string>
                <key>EVENTKIT_BRIDGE_TIMEOUT</key>
                <string>\(timeout)</string>
                <key>EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED</key>
                <string>\(isProductionAuthorized ? "true" : "false")</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(stdoutLogPath)</string>
            <key>StandardErrorPath</key>
            <string>\(stderrLogPath)</string>
        </dict>
        </plist>
        """
    }

    /// Parses EnvironmentVariables from a LaunchAgent plist XML representation.
    public static func parseEnvironment(fromPlistXML plistXML: String) throws -> [String: String] {
        guard let data = plistXML.data(using: .utf8) else {
            throw ConfigurationError.invalidValue(key: "plistXML", reason: "Cannot encode plist string to UTF-8")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ConfigurationError.invalidValue(key: "plistXML", reason: "Invalid plist XML format")
        }
        guard let envDict = plist["EnvironmentVariables"] as? [String: Any] else {
            throw ConfigurationError.missingRequiredKey("EnvironmentVariables")
        }
        var stringEnv: [String: String] = [:]
        for (k, v) in envDict {
            stringEnv[k] = "\(v)"
        }
        return stringEnv
    }
}
