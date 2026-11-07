// swift-tools-version: 6.0
// Package.swift
// EventKitBridge — MacServer EventKit Read-Only Candidate
// NEW_IMPLEMENTATION | AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07
//
// SECURITY POSTURE:
//   - Read-only: no write operations on any EventKit store
//   - FIX-R4A-01: metadata-only paths never fetch reminder content or counts
//   - FIX-R4A-02: content reads verify iCloud source before returning data
//   - ProductionEventKitStore compiles but requires explicit TCC authorization to activate

import PackageDescription

let package = Package(
    name: "EventKitBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "EventKitBridge",
            targets: ["EventKitBridge"]
        ),
        .executable(
            name: "EventKitBridgeServer",
            targets: ["EventKitBridgeServerExec"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "EventKitBridge",
            path: "Sources/EventKitBridge"
        ),
        .executableTarget(
            name: "EventKitBridgeServerExec",
            dependencies: ["EventKitBridge"],
            path: "Sources/EventKitBridgeServerExec"
        ),
        .testTarget(
            name: "EventKitBridgeTests",
            dependencies: ["EventKitBridge"],
            path: "Tests/EventKitBridgeTests"
        ),
    ]
)
