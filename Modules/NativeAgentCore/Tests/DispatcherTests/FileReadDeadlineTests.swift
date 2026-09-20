import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Dispatcher

@Test func fileReadDeadlineReturnsWhileFolderAccessIsBlocked() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let registry = LocalConnectorActions(handlers: ["list_dir": { _, _ in
        _ = release.wait(timeout: .now() + 5)
        return .object(["ok": .bool(true)])
    }], trivialVerify: ["list_dir"])
    let dispatcher = SwiftNativeDispatcher(
        timeout: 0.05,
        ledger: DispatchLedger(ledgerPath: root.appendingPathComponent("events.jsonl")),
        localActions: registry
    )
    let started = Date()
    let result = try await dispatcher.dispatch(
        tool: "list_dir", input: [:], ctx: .defaultForSurface("native_actions"), dryRun: false
    )
    #expect(Date().timeIntervalSince(started) < 2)
    #expect(!result.ok)
    #expect(result.error?.code == "timeout")
    #expect(result.verifyPassed != true)
}
