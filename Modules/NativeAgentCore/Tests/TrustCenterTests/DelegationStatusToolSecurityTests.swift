import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// delegation_status (W2, 2026-08-11) SecurityCenter profile shape.
//
// Pure local read of the claude/codex wake-job records under ~/.config: no
// write, no process spawn, no network. It must resolve as a SIGNED built-in
// low-risk safe_read, and it must NOT pick up the notification carve-out —
// that exemption exists for tools whose payload leaves the machine through a
// banner/bridge, and this one only reads files.

private func hermeticCenter() throws -> SwiftNativeSecurityCenter {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DelegationStatusToolSecurity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SwiftNativeSecurityCenter(dataRoot: root)
}

@Test func SecurityCenter_delegationStatus_isLowRiskSignedRead() async throws {
    let center = try hermeticCenter()
    let envelope = await center.evaluateTool(
        tool: "delegation_status",
        input: ["limit": .int(20)],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.risk == "low")
    #expect(envelope.capabilities.contains("safe_read"))
    #expect(envelope.signedToolKnown)
    #expect(!envelope.capabilities.contains("ledger_write"))
    #expect(!envelope.capabilities.contains("filesystem_write"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(!envelope.capabilities.contains("shell"))
    #expect(!envelope.capabilities.contains("network"))
    #expect(envelope.rollbackRequired == false)
}

@Test func SecurityCenter_delegationStatus_isNotNotificationTier() async throws {
    // The notification carve-out exempts a tool from the external_send
    // approval gate. delegation_status must never sit in that set — it is not
    // a send channel, and mis-registering it there would widen the carve-out
    // for no reason.
    #expect(!SwiftNativeSecurityCenter.notificationToolNames.contains("delegation_status"))
    #expect(SwiftNativeSecurityCenter.builtinToolNames.contains("delegation_status"))
}
