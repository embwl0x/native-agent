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
    #expect(envelope.hasSideEffects)
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
    #expect(!envelope.hasSideEffects)
    #expect(envelope.rollbackRequired == false)
}

@Test func SecurityCapabilityClassifier_coversEveryEffectVocabulary() {
    let effects = [
        "agent_delegate", "approval_stage", "app_data_write", "browser_interaction",
        "destructive", "evolution_apply_trigger", "evolution_write", "external_send",
        "file_write", "filesystem_delete", "filesystem_write", "image_generation",
        "ledger_write", "mac_control", "memory_write", "money", "network_write",
        "notification", "organism_state_write", "outside_app_data_write",
        "process_spawn", "remote_effect", "shell", "skill_write", "system_control",
        "system_permission_reset", "workshop_write",
    ]
    for effect in effects {
        #expect(SecurityCapabilityClassifier.hasSideEffects([effect]), "missing effect capability: \(effect)")
    }
    for readOrSensitivity in ["tool_call", "safe_read", "catalog_read", "network_read", "secrets", "secret_input"] {
        #expect(!SecurityCapabilityClassifier.hasSideEffects([readOrSensitivity]), "non-effect capability marked mutating: \(readOrSensitivity)")
    }
}
