// RequestLimiter.swift
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Token-bucket rate limiter for EventKit bridge requests.

import Foundation

/// Enforces a per-second request rate limit on EventKit bridge calls.
///
/// Uses a simple token-bucket algorithm with a configurable capacity and
/// refill rate. Thread-safe via actor isolation (Swift 6).
public actor RequestLimiter {

    private let capacity: Int
    private let refillPerSecond: Int
    private var tokens: Int
    private var lastRefillTime: Date

    /// - Parameters:
    ///   - capacity: Maximum burst capacity (default: 20 requests).
    ///   - refillPerSecond: Tokens added per second (default: 5).
    public init(capacity: Int = 20, refillPerSecond: Int = 5) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefillTime = Date()
    }

    /// Checks whether a request is within the rate limit.
    ///
    /// - Throws: ``EventKitBridgeError.rateLimitExceeded`` if the token bucket is empty.
    public func checkLimit() throws {
        refill()
        guard tokens > 0 else {
            throw EventKitBridgeError.rateLimitExceeded
        }
        tokens -= 1
    }

    // MARK: — Private

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefillTime)
        let newTokens = Int(elapsed) * refillPerSecond
        if newTokens > 0 {
            tokens = min(capacity, tokens + newTokens)
            lastRefillTime = now
        }
    }

    /// Resets the limiter to full capacity (for testing).
    public func reset() {
        tokens = capacity
        lastRefillTime = Date()
    }

    /// Current token count (for testing assertions).
    public var currentTokens: Int { tokens }
}
