// ProductionEventKitStore.swift
// NEW_IMPLEMENTATION | FIX-R4A-01 | FIX-R4A-02
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// PRODUCTION STUB — COMPILES BUT IS NOT ACTIVATED
//
// This file provides the real EventKit implementation skeleton.
// It is intentionally NOT wired into any active code path.
// Activation requires:
//   1. Explicit TCC authorization (NSRemindersUsageDescription in entitlements)
//   2. Human authorization (see AGENTS.md §1.3)
//   3. MUSE independent verification sign-off
//
// CAUTION: Do not instantiate ProductionEventKitStore without all three authorizations above.

import Foundation
// import EventKit  // Uncomment ONLY after TCC authorization is granted

/// Production EventKit store implementation.
///
/// - Important: This class is a STUB. It compiles but throws `.permissionDenied`
///   on all calls until TCC authorization and human sign-off are obtained.
///
/// FIX-R4A-01: fetchListsMetadata() must NOT call store.calendars(for:) with
///   .reminder and then enumerate reminders — only calendar metadata is fetched.
/// FIX-R4A-02: fetchReminders(listID:) must call SourceVerifier before returning.
public actor ProductionEventKitStore: EventKitStoreProtocol {

    // STUB: private let store = EKEventStore()  // Not activated
    private var _contentAccessCount: Int = 0
    private let sourceVerifier: SourceVerifier
    private let requestLimiter: RequestLimiter

    /// - Parameter sourceVerifier: Verifies iCloud source (FIX-R4A-02).
    /// - Parameter requestLimiter: Enforces rate limits.
    public init(
        sourceVerifier: SourceVerifier = SourceVerifier(),
        requestLimiter: RequestLimiter = RequestLimiter()
    ) {
        self.sourceVerifier = sourceVerifier
        self.requestLimiter = requestLimiter
    }

    // MARK: — EventKitStoreProtocol

    /// FIX-R4A-01: Returns ONLY list metadata. Reminder items MUST NOT be fetched here.
    ///
    /// Production implementation notes (not yet active):
    ///   - Use EKEventStore.calendars(for: .reminder) to get EKCalendar objects.
    ///   - Map to RemindersList using calendarIdentifier, title, source.title, cgColor.
    ///   - Do NOT call EKEventStore.fetchReminders(matching:) here.
    public func fetchListsMetadata() async throws -> [RemindersList] {
        // STUB: TCC authorization required before activating.
        // FIX-R4A-01 enforcement: this method must never call fetchReminders.
        throw EventKitBridgeError.permissionDenied
        /*
        // --- PRODUCTION CODE (activate after TCC auth + human sign-off) ---
        try await requestLimiter.checkLimit()
        let calendars = store.calendars(for: .reminder)
        return calendars.map { cal in
            RemindersList(
                listID: cal.calendarIdentifier,
                title: cal.title,
                sourceName: cal.source.title,
                color: cal.color.hexString,
                isImmutable: cal.isImmutable
            )
        }
        */
    }

    /// FIX-R4A-02: Verifies iCloud source before returning any reminder data.
    ///
    /// Production implementation notes (not yet active):
    ///   - Fetch EKCalendar by identifier.
    ///   - Call sourceVerifier.verify(sourceName: cal.source.title) — throws if not iCloud.
    ///   - Build NSPredicate with EKEventStore.predicateForReminders(in: [cal]).
    ///   - Fetch with EKEventStore.fetchReminders(matching:).
    public func fetchReminders(listID: String) async throws -> [ReminderItem] {
        // STUB: TCC authorization required before activating.
        throw EventKitBridgeError.permissionDenied
        /*
        // --- PRODUCTION CODE (activate after TCC auth + human sign-off) ---
        try await requestLimiter.checkLimit()
        guard let calendar = store.calendar(withIdentifier: listID) else {
            throw EventKitBridgeError.listNotFound
        }
        // FIX-R4A-02: Source verification
        try sourceVerifier.verify(sourceName: calendar.source.title)
        _contentAccessCount += 1
        let predicate = store.predicateForReminders(in: [calendar])
        let ekReminders = try await withCheckedThrowingContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                if let r = reminders { cont.resume(returning: r) }
                else { cont.resume(throwing: EventKitBridgeError.timeout) }
            }
        }
        return ekReminders.map { r in
            ReminderItem(
                itemID: r.calendarItemIdentifier,
                title: r.title ?? "",
                isCompleted: r.isCompleted,
                dueDate: r.dueDateComponents?.date,
                priority: r.priority,
                notes: r.notes,
                listID: listID
            )
        }
        */
    }

    // MARK: — Diagnostics

    public var contentAccessCount: Int { _contentAccessCount }

    public func resetCounters() { _contentAccessCount = 0 }}
