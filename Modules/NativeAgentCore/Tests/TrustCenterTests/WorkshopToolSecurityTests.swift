import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// workshop_submit / workshop_status (U5 W-I) SecurityCenter profile shapes.
//
// workshop_submit is a medium-risk Workshop execution queue WRITE (a thin shim into the
// Workshop execution queue; the executor's own gates apply downstream) — NOT shell /
// process_spawn / filesystem_write. The name contains "submit", which trips no
// keyword catcher, so the explicit workshop_write branch pins the shape.
// workshop_status is a low-risk read. Asserted through the public evaluateTool
// envelope.

private func hermeticCenter() throws -> (SwiftNativeSecurityCenter, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MissionToolSecurity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (SwiftNativeSecurityCenter(dataRoot: root), root)
}

@Test func SecurityCenter_workshopSubmit_isMediumRiskWorkshopExecutionWrite() async throws {
    let (center, _) = try hermeticCenter()
    let envelope = await center.evaluateTool(
        tool: "workshop_submit",
        input: ["text": .string("Draft the weekly summary")],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.risk == "medium")
    #expect(envelope.capabilities.contains("workshop_write"))
    #expect(envelope.signedToolKnown)
    // Must NOT inherit the privileged shell-class shapes.
    #expect(!envelope.capabilities.contains("shell"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(!envelope.capabilities.contains("filesystem_write"))
    // A queue write is not a filesystem mutation requiring rollback.
    #expect(envelope.rollbackRequired == false)
}

@Test func SecurityCenter_workshopStatus_isLowRiskRead() async throws {
    let (center, _) = try hermeticCenter()
    let envelope = await center.evaluateTool(
        tool: "workshop_status",
        input: [:],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.risk == "low")
    #expect(envelope.capabilities.contains("safe_read"))
    #expect(envelope.signedToolKnown)
    #expect(!envelope.capabilities.contains("workshop_write"))
    #expect(!envelope.capabilities.contains("shell"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(envelope.rollbackRequired == false)
}
