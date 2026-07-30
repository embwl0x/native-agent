import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// task_ledger_post / task_ledger_list (U6) SecurityCenter profile shapes.
//
// task_ledger_post is a medium-risk cross-agent task ledger WRITE — NOT shell /
// process_spawn / filesystem_write (it appends to an app-data JSONL feed under
// flock). The dedicated `ledger_write` branch pins the shape ("post" trips no
// keyword catcher). task_ledger_list is a low-risk read.

private func hermeticCenter() throws -> SwiftNativeSecurityCenter {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLedgerToolSecurity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SwiftNativeSecurityCenter(dataRoot: root)
}

@Test func SecurityCenter_taskLedgerPost_isMediumRiskLedgerWrite() async throws {
    let center = try hermeticCenter()
    let envelope = await center.evaluateTool(
        tool: "task_ledger_post",
        input: ["kind": .string("created"), "title": .string("x")],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.risk == "medium")
    #expect(envelope.capabilities.contains("ledger_write"))
    #expect(envelope.signedToolKnown)
    #expect(!envelope.capabilities.contains("shell"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(!envelope.capabilities.contains("filesystem_write"))
    #expect(envelope.rollbackRequired == false)
}

@Test func SecurityCenter_taskLedgerList_isLowRiskRead() async throws {
    let center = try hermeticCenter()
    let envelope = await center.evaluateTool(
        tool: "task_ledger_list",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.risk == "low")
    #expect(envelope.capabilities.contains("safe_read"))
    #expect(envelope.signedToolKnown)
    #expect(!envelope.capabilities.contains("ledger_write"))
    #expect(envelope.rollbackRequired == false)
}
