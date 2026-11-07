// main.swift
// EventKitBridgeServerExec — Entry point
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Native entry point for EventKitBridgeServer.
// Defaults strictly to loopback (127.0.0.1) and FakeEventKitStore (no TCC required).
// Supports graceful shutdown on SIGINT/SIGTERM.

import Foundation
import EventKitBridge

@main
struct BridgeServerMain {
    static func main() async {
        let config = BridgeConfig.load(from: ProcessInfo.processInfo.environment)

        print("[EventKitBridge] Starting server on \(config.host):\(config.port)...")
        print("[EventKitBridge] Store Mode: \(config.useFakeStore ? "FAKE (Safe offline)" : "PRODUCTION (Guarded)")")
        print("[EventKitBridge] Allowlisted list IDs: \(config.allowedListIDs.count)")

        let sourceVerifier = SourceVerifier(
            allowedSourceTypes: config.allowedSourceTypes,
            allowedSourceTitles: config.allowedSources,
            listBindings: config.listBindings
        )

        let store: any EventKitStoreProtocol
        if config.useFakeStore {
            store = FakeEventKitStore(sourceVerifier: sourceVerifier)
        } else {
            // Production store remains guarded (isProductionActivated: false)
            store = ProductionEventKitStore(
                isProductionActivated: false,
                sourceVerifier: sourceVerifier
            )
        }

        let authValidator = AuthValidator(allowedTokens: config.validTokens)
        let allowlistValidator = AllowlistValidator(allowedIDs: config.allowedListIDs)
        let requestLimiter = RequestLimiter(capacity: config.rateLimitRPS, refillPerSecond: config.rateLimitRPS)

        let server = EventKitBridgeServer(
            store: store,
            authValidator: authValidator,
            allowlistValidator: allowlistValidator,
            requestLimiter: requestLimiter,
            config: config
        )

        do {
            try await server.start()
            let bound = await server.boundPort
            print("[EventKitBridge] Listening on http://\(config.host):\(bound)")
            print("[EventKitBridge] Ready for read-only requests. Press Ctrl+C to terminate.")

            // Setup signal handling for graceful shutdown
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            let isRunning = ManagedAtomicBool(true)

            let shutdownHandler = {
                if isRunning.compareAndExchange(expected: true, desired: false) {
                    print("\n[EventKitBridge] Received termination signal. Shutting down gracefully...")
                    Task {
                        await server.stop()
                        print("[EventKitBridge] Server stopped cleanly.")
                        exit(0)
                    }
                }
            }

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            sigintSource.setEventHandler(handler: shutdownHandler)
            sigtermSource.setEventHandler(handler: shutdownHandler)

            sigintSource.resume()
            sigtermSource.resume()

            // Keep main loop alive
            while isRunning.value {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            print("[EventKitBridge] Failed to start server: \(error)")
            exit(1)
        }
    }
}

private final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) {
        self._value = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func compareAndExchange(expected: Bool, desired: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value == expected {
            _value = desired
            return true
        }
        return false
    }
}
