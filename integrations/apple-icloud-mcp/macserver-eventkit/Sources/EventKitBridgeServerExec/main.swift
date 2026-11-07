// main.swift
// EventKitBridgeServerExec — Entry point
// NEW_IMPLEMENTATION
// AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// Minimal entry point for the bridge server executable.
// Runs with FakeEventKitStore by default (no TCC required).
// Production activation requires human authorization per AGENTS.md §1.3.

import Foundation
import EventKitBridge

// Load configuration (test mode default — no real credentials)
let config = BridgeConfig.testDefault

print("EventKitBridgeServer starting...")
print("Mode: \(config.useFakeStore ? "FAKE (test)" : "PRODUCTION")")
print("Port: \(config.port)")
print("Allowlisted list IDs: \(config.allowedListIDs.count)")
print("See SESSION_TEMPLATE.md for stop/resume procedures.")

// In a real deployment, this would start an HTTP listener.
// For now, this is a demonstration stub.
print("Bridge server initialized. (Stub — HTTP listener not active in this candidate.)")
print("Run 'swift test' to validate all acceptance criteria.")
