// ManagedSocketHandle.swift
// Thread-safe socket handle guaranteeing idempotent, exactly-once shutdown and close.
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class ManagedSocketHandle: @unchecked Sendable {
    private let fd: Int32
    private let isClosed = StoreAtomicBool(false)

    public init(fd: Int32) {
        self.fd = fd
    }

    public var rawFd: Int32 { fd }

    public var isSocketClosed: Bool { isClosed.current }

    /// Closes socket cleanly exactly once.
    /// Drains any pending receive bytes in non-blocking mode to prevent TCP RST on close.
    public func closeSafely() {
        guard !isClosed.getAndSet(true) else { return }

        // Drain any pending receive bytes before closing to prevent kernel TCP RST
        var drainBuffer = [UInt8](repeating: 0, count: 4096)
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            while Darwin.read(fd, &drainBuffer, drainBuffer.count) > 0 {}
        }

        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
