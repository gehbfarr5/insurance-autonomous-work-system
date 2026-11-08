// ProductionEventKitStore.swift
// NEW_IMPLEMENTATION | TIMEOUT_GATED_CALLBACK | FIX-R4A-01 | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// REAL EVENTKIT READONLY ADAPTER — FULLY COMPILED WITH CALLBACK TIMEOUT
//
// Safety Boundaries:
// - Does NOT instantiate a live EKEventStore, request TCC, or touch Apple data by default.
// - Activation is strictly gated behind `isProductionActivated == true` AND an injected
//   authorized store provider closure.
// - All EventKit types, predicates, timeout handling, and mapping logic are fully compiled.

import Foundation

#if canImport(EventKit)
import EventKit
#if canImport(AppKit)
import AppKit
#endif

/// Unified Reminders authorization status across macOS versions.
public enum RemindersAuthorizationStatus: String, Sendable, Codable {
    case notDetermined = "notDetermined"
    case restricted = "restricted"
    case denied = "denied"
    case authorized = "authorized"
    case fullAccess = "fullAccess"
    case writeOnly = "writeOnly"
    case unknown = "unknown"
}

/// Real EventKit read-only store adapter.
///
/// Implements `EventKitStoreProtocol` using native macOS `EventKit` APIs.
/// All code paths are fully compiled. Unactivated instances throw `.permissionDenied`
/// without ever instantiating `EKEventStore` or triggering macOS privacy/TCC prompts.
public actor ProductionEventKitStore: EventKitStoreProtocol {

    private var _contentAccessCount: Int = 0
    private let sourceVerifier: SourceVerifier
    private let requestLimiter: RequestLimiter
    private let callbackTimeoutSeconds: Double

    /// Safety gate: Default is false. Prevents any unvetted runtime access.
    private let isProductionActivated: Bool

    /// Optional injected store instance or provider closure.
    /// When nil or when not activated, EKEventStore is never constructed.
    private let storeProvider: (@Sendable () throws -> EKEventStore)?
    private var cachedStore: EKEventStore?

    /// Optional injected authorization status checker for offline testing without TCC prompts.
    private let authorizationStatusChecker: (@Sendable () -> RemindersAuthorizationStatus)?

    public init(
        isProductionActivated: Bool = false,
        sourceVerifier: SourceVerifier = SourceVerifier(),
        requestLimiter: RequestLimiter = RequestLimiter(),
        callbackTimeoutSeconds: Double = 5.0,
        storeProvider: (@Sendable () throws -> EKEventStore)? = nil,
        authorizationStatusChecker: (@Sendable () -> RemindersAuthorizationStatus)? = nil
    ) {
        self.isProductionActivated = isProductionActivated
        self.sourceVerifier = sourceVerifier
        self.requestLimiter = requestLimiter
        self.callbackTimeoutSeconds = callbackTimeoutSeconds > 0 ? callbackTimeoutSeconds : 5.0
        self.storeProvider = storeProvider
        self.authorizationStatusChecker = authorizationStatusChecker
    }

    /// Checks Reminders authorization status without prompting TCC dialogs.
    public func checkAuthorizationStatus() -> RemindersAuthorizationStatus {
        if let checker = authorizationStatusChecker {
            return checker()
        }
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .fullAccess:    return .fullAccess
        case .writeOnly:     return .writeOnly
        @unknown default:    return .unknown
        }
        #else
        return .denied
        #endif
    }

    // MARK: — EventKitStoreProtocol

    /// FIX-R4A-01: Metadata-only query.
    /// Enumerates reminder calendars and projects ONLY list metadata.
    /// Strictly NEVER queries reminder items or counts.
    /// Unconditionally rejects unauthorized status: never returns [] pretending empty list success!
    public func fetchListsMetadata() async throws -> [RemindersList] {
        guard isProductionActivated, let provider = storeProvider else {
            // Safety guard: Do not trigger TCC or access live store unless authorized.
            throw EventKitBridgeError.permissionDenied
        }

        // TCC Permission verification:
        // NEVER call store.calendars(for: .reminder) if status is not fullAccess/authorized!
        // macOS EventKit returns empty array [] on unauthorized access, which must NEVER
        // masquerade as a successful empty list result.
        let status = checkAuthorizationStatus()
        guard status == .fullAccess || status == .authorized else {
            throw EventKitBridgeError.permissionDenied
        }

        try await requestLimiter.checkLimit()
        let store = try getOrInitStore(provider: provider)

        // Native EventKit call: Get reminder calendars only.
        let calendars = store.calendars(for: .reminder)
        return calendars.map { cal in
            let src = cal.source
            let typeStr = Self.sourceTypeToString(src?.sourceType)
            return RemindersList(
                listID: cal.calendarIdentifier,
                title: cal.title,
                sourceID: src?.sourceIdentifier ?? "unknown-source-id",
                sourceType: typeStr,
                sourceName: src?.title ?? "unknown-source",
                color: cal.hexColorString,
                isImmutable: cal.isImmutable
            )
        }
    }

    /// FIX-R4A-02: Content query with mandatory source verification and callback timeout.
    /// Checks source identity and type BEFORE executing any reminder predicate query.
    public func fetchReminders(listID: String) async throws -> [ReminderItem] {
        guard isProductionActivated, let provider = storeProvider else {
            throw EventKitBridgeError.permissionDenied
        }

        let status = checkAuthorizationStatus()
        guard status == .fullAccess || status == .authorized else {
            throw EventKitBridgeError.permissionDenied
        }

        try await requestLimiter.checkLimit()
        let store = try getOrInitStore(provider: provider)

        guard let calendar = store.calendar(withIdentifier: listID) else {
            throw EventKitBridgeError.listNotFound
        }

        // FIX-R4A-02: Verify source identity, type, and list binding PRIOR to content query
        let src = calendar.source
        let srcType = Self.sourceTypeToString(src?.sourceType)
        try sourceVerifier.verify(
            listID: calendar.calendarIdentifier,
            sourceID: src?.sourceIdentifier ?? "",
            sourceType: srcType,
            sourceTitle: src?.title ?? ""
        )

        _contentAccessCount += 1

        let predicate = store.predicateForReminders(in: [calendar])
        let timeoutNanos = UInt64(callbackTimeoutSeconds * 1_000_000_000)

        let items: [ReminderItem] = try await withCheckedThrowingContinuation { continuation in
            let resumed = StoreAtomicBool(false)

            // Timeout watchdog
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                if resumed.compareAndExchange(expected: false, desired: true) {
                    continuation.resume(throwing: EventKitBridgeError.timeout)
                }
            }

            store.fetchReminders(matching: predicate) { fetched in
                if resumed.compareAndExchange(expected: false, desired: true) {
                    if let reminders = fetched {
                        let mapped = reminders.map { r in
                            let isAllDay = (r.dueDateComponents != nil && r.dueDateComponents?.hour == nil)
                            return ReminderItem(
                                itemID: r.calendarItemIdentifier,
                                title: r.title ?? "",
                                isCompleted: r.isCompleted,
                                dueDate: r.dueDateComponents?.date,
                                priority: r.priority,
                                notes: r.notes,
                                listID: listID,
                                isAllDay: isAllDay,
                                timeZone: r.dueDateComponents?.timeZone?.identifier,
                                completionDate: r.completionDate,
                                creationDate: r.creationDate,
                                lastModifiedDate: r.lastModifiedDate,
                                url: r.url?.absoluteString
                            )
                        }
                        continuation.resume(returning: mapped)
                    } else {
                        continuation.resume(throwing: EventKitBridgeError.timeout)
                    }
                }
            }
        }

        return items
    }

    // MARK: — Private Helpers

    private func getOrInitStore(provider: @Sendable () throws -> EKEventStore) throws -> EKEventStore {
        if let existing = cachedStore {
            return existing
        }
        let created = try provider()
        cachedStore = created
        return created
    }

    private static func sourceTypeToString(_ type: EKSourceType?) -> String {
        guard let type = type else { return "unknown" }
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    // MARK: — Diagnostics

    public var contentAccessCount: Int { _contentAccessCount }
    public func resetCounters() { _contentAccessCount = 0 }
}

/// Real EventKit store provider factory.
/// Default-off: Never invoked unless explicitly authorized at runtime.
/// In this candidate phase, provides the sanctioned closure for real EKEventStore instantiation.
public enum ProductionEventKitProvider {
    /// Factory that produces the live EKEventStore provider closure.
    /// Note: This closure instantiates EKEventStore() when called.
    /// In this offline verification candidate, it is default-off and must NOT be executed without authorization.
    public static func makeLiveEventStoreProvider() -> @Sendable () throws -> EKEventStore {
        return {
            #if canImport(EventKit)
            return EKEventStore()
            #else
            throw BridgeError.backendInternalError(detail: "EventKit framework unavailable on this platform")
            #endif
        }
    }
}

/// Explicit, default-off assembly path for ProductionEventKitStore.
/// Only activated when isAuthorized == true AND authorizedStoreProvider != nil.
public enum ProductionStoreAssembly {
    public static func assemble(
        isAuthorized: Bool,
        sourceVerifier: SourceVerifier,
        requestLimiter: RequestLimiter,
        callbackTimeoutSeconds: Double = 5.0,
        authorizedStoreProvider: (@Sendable () throws -> EKEventStore)? = nil,
        authorizationStatusChecker: (@Sendable () -> RemindersAuthorizationStatus)? = nil
    ) -> ProductionEventKitStore {
        let isFullyAuthorized = isAuthorized && (authorizedStoreProvider != nil)
        return ProductionEventKitStore(
            isProductionActivated: isFullyAuthorized,
            sourceVerifier: sourceVerifier,
            requestLimiter: requestLimiter,
            callbackTimeoutSeconds: callbackTimeoutSeconds,
            storeProvider: isFullyAuthorized ? authorizedStoreProvider : nil,
            authorizationStatusChecker: authorizationStatusChecker
        )
    }
}

private extension EKCalendar {
    var hexColorString: String {
        #if canImport(AppKit)
        if let nsColor = self.color {
            if let rgb = nsColor.usingColorSpace(.deviceRGB) {
                let r = Int(rgb.redComponent * 255)
                let g = Int(rgb.greenComponent * 255)
                let b = Int(rgb.blueComponent * 255)
                return String(format: "#%02X%02X%02X", r, g, b)
            }
        }
        #endif
        return ""
    }
}

#else

// Fallback for non-Darwin environments (e.g. Linux)
public actor ProductionEventKitStore: EventKitStoreProtocol {
    public init(
        isProductionActivated: Bool = false,
        sourceVerifier: SourceVerifier = SourceVerifier(),
        requestLimiter: RequestLimiter = RequestLimiter(),
        callbackTimeoutSeconds: Double = 5.0
    ) {}

    public func fetchListsMetadata() async throws -> [RemindersList] {
        throw EventKitBridgeError.permissionDenied
    }

    public func fetchReminders(listID: String) async throws -> [ReminderItem] {
        throw EventKitBridgeError.permissionDenied
    }

    public var contentAccessCount: Int { 0 }
    public func resetCounters() {}
}

#endif
