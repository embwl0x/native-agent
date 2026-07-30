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
