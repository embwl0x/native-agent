import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import NativeAgentCore

@Test("process-tree signals reject stale PID start identity")
func processTreeSignalRejectsReusedPIDIdentity() throws {
    #if canImport(Darwin)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    let live = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
    let identity = try #require(live.rootIdentity)
    let stale = ProcessTreeIdentity(
        pid: identity.pid,
        startSeconds: identity.startSeconds &+ 1,
        startMicroseconds: identity.startMicroseconds
    )
    ProcessTreeReaper.signal(
        ProcessTreeSnapshot(
            rootPID: identity.pid,
            rootIdentity: stale,
            descendants: [stale]
        ),
        signal: SIGKILL
    )

    #expect(process.isRunning, "a stale PID identity must never receive a signal")
    #endif
}

// REPORTS-ONLY -> executable boundary checks (Wave 1):
// core.misc / core.processTreeReaper
@Test("process-tree snapshot reaches a real background descendant")
func processTreeSnapshotFindsLiveDescendant() throws {
    #if canImport(Darwin)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 30 & wait"]
    try process.run()
    defer {
        let snapshot = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
        ProcessTreeReaper.quiesceAndKill(snapshot)
        if process.isRunning { process.waitUntilExit() }
    }

    var snapshot = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
    let deadline = Date().addingTimeInterval(2)
    while snapshot.descendants.isEmpty, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
        snapshot = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
    }
    #expect(snapshot.rootIdentity != nil)
    #expect(!snapshot.descendants.isEmpty, "a shell background child escaped the tree snapshot")
    #expect(ProcessTreeReaper.hasLiveDescendant(in: snapshot))
    #endif
}

@Test("process-tree quiesce kills the observed tree without leaving a live descendant")
func processTreeQuiesceSettlesObservedDescendants() throws {
    #if canImport(Darwin)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 30 & wait"]
    try process.run()
    defer {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    var snapshot = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
    let deadline = Date().addingTimeInterval(2)
    while snapshot.descendants.isEmpty, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
        snapshot = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
    }
    #expect(!snapshot.descendants.isEmpty)
    let frozen = ProcessTreeReaper.quiesceAndKill(snapshot)
    process.waitUntilExit()
    #expect(!ProcessTreeReaper.hasLiveDescendant(in: frozen))
    #endif
}
