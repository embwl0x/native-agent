import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

@Test func SecurityCenter_saveSkill_isKnownLowRiskGuidanceWrite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SaveSkillSecurity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let envelope = await SwiftNativeSecurityCenter(dataRoot: root).evaluateTool(
        tool: "save_skill",
        input: [
            "name": .string("Concise Handoff"),
            "description": .string("A reusable response procedure."),
            "content": .string("# Concise Handoff\n\nUse this when closing verified work.\n"),
        ],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.risk == "low")
    #expect(envelope.capabilities.contains("skill_write"))
    #expect(envelope.signedToolKnown)
    #expect(!envelope.capabilities.contains("filesystem_write"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(envelope.rollbackRequired == false)
}
