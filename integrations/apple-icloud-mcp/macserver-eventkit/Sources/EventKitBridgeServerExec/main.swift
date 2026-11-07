// main.swift
// EventKitBridgeServerExec — Entry point
// NEW_IMPLEMENTATION | EXPLICIT_ASSEMBLY_PATHS
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Native entry point for EventKitBridgeServer.
// Gated: Production mode strictly validates configuration and rejects startup on missing fields.
// Never silently falls back to test tokens or fake data.
// In this offline candidate phase, live EKEventStore instantiation remains deactivated.

import Foundation
import EventKitBridge

@main
struct BridgeServerMain {
    static func main() async {
        let env = ProcessInfo.processInfo.environment

        // 1. Configuration loading and strict production validation
        let config: BridgeConfig
        do {
            config = try BridgeConfig.load(from: env)
        } catch let configError as ConfigurationError {
            print("[EventKitBridge] FATAL CONFIGURATION ERROR: \(configError.localizedDescription)")
            print("[EventKitBridge] Startup aborted. Missing configuration will never fall back to test data in production.")
            exit(1)
        } catch {
            print("[EventKitBridge] FATAL ERROR: Failed to load configuration: \(error)")
            exit(1)
        }

        print("[EventKitBridge] Mode: \(config.mode.rawValue)")
        print("[EventKitBridge] Host: \(config.host):\(config.port)")
        print("[EventKitBridge] Allowlisted List IDs: \(config.allowedListIDs.count)")
        print("[EventKitBridge] Registered Source Bindings: \(config.listBindings.count)")

        // 2. Security layers
        let sourceVerifier = SourceVerifier(
            allowedSourceTypes: config.allowedSourceTypes,
            allowedSourceTitles: config.allowedSources,
            listBindings: config.listBindings,
            requireExplicitBinding: true // Strict binding mandatory
        )

        let authValidator = AuthValidator(allowedTokens: config.validTokens)
        let allowlistValidator = AllowlistValidator(allowedIDs: config.allowedListIDs)
        let requestLimiter = RequestLimiter(capacity: config.rateLimitRPS, refillPerSecond: config.rateLimitRPS)

        // 3. Store Assembly
        let store: any EventKitStoreProtocol
        switch config.mode {
        case .test:
            print("[EventKitBridge] Assembling safe offline FakeEventKitStore...")
            store = FakeEventKitStore(sourceVerifier: sourceVerifier)

        case .production:
            print("[EventKitBridge] Assembling guarded ProductionEventKitStore...")
            // Strictly guarded: isProductionActivated remains false until authorized Gate B deployment.
            // Does NOT instantiate EKEventStore or prompt TCC.
            store = ProductionEventKitStore(
                isProductionActivated: false,
                sourceVerifier: sourceVerifier,
                requestLimiter: requestLimiter,
                callbackTimeoutSeconds: config.timeoutSeconds
            )
        }

        // 4. Server assembly & startup
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
            print("[EventKitBridge] Bound successfully to http://\(config.host):\(bound)")
            print("[EventKitBridge] Read-only candidate ready. Press Ctrl+C to terminate.")

            // Signal handlers for graceful shutdown
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            let isRunning = ManagedAtomicBool(true)
            let shutdownHandler = {
                if isRunning.compareAndExchange(expected: true, desired: false) {
                    print("\n[EventKitBridge] Received termination signal. Stopping listener gracefully...")
                    Task {
                        await server.stop()
                        print("[EventKitBridge] Listener stopped cleanly. Exiting.")
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

            while isRunning.value {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            print("[EventKitBridge] Server startup failed: \(error)")
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
