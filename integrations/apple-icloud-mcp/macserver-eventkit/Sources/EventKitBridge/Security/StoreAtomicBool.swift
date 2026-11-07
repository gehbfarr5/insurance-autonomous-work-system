// StoreAtomicBool.swift
// Thread-safe atomic boolean for timeout watchdogs and race guards.
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07

import Foundation

public final class StoreAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    public init(_ value: Bool) {
        self._value = value
    }

    public func compareAndExchange(expected: Bool, desired: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value == expected {
            _value = desired
            return true
        }
        return false
    }

    public func getAndSet(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = _value
        _value = newValue
        return old
    }

    public var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}
