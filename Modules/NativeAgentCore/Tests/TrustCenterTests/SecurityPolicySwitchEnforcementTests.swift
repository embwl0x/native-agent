import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.securityCenter.evaluateTool.killSwitch
//   • core.trust.securityPolicy.toolSigningRequired
//
// The two securityPolicy switches whose ENFORCEMENT nothing drove. Both are
// restore paths: the kill switch is the operator's "stop everything" and
// `toolSigningRequired` was flipped false on 2026-08-12 (USER YOLO), so the
// only thing standing between "an operator turns signing back on" and "nothing
// happens" was a code read nobody had executed.

private func switchTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecurityPolicySwitch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Tool names outside every carve-out, spanning several profile classes so the
/// kill switch is proven TOTAL, not just true for one shape.
private let nonCatalogProbeTools = [
    "read_file", "write_file", "shell", "memory_search",
    "recall_memory", "mac.notify", "browser_status", "email.send",
]

@Test func SecurityCenter_killSwitch_blocksEveryToolOutsideTheCatalogCarveOut() async throws {
    let root = try switchTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(["default": .string("auto")]),
        "securityPolicy": .object(["killSwitchEnabled": .bool(true)]),
    ], at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    for tool in nonCatalogProbeTools {
        let envelope = await center.evaluateTool(
            tool: tool, input: [:], origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.decision == .block, "\(tool) survived the kill switch")
        #expect(!envelope.allowed)
        #expect(envelope.reasons.contains { $0.contains("kill switch") },
                "\(tool) blocked without naming the kill switch: \(envelope.reasons)")
    }

    // The carve-out, by design: catalogue reads stay available so the UI can
    // still tell the user what exists while everything is paused.
    for tool in SwiftNativeSecurityCenter.catalogToolNames.sorted() {
        let envelope = await center.evaluateTool(
            tool: tool, input: [:], origin: SecurityOriginContext(surface: "chat")
        )
        #expect(envelope.decision == .allow, "catalog tool \(tool) was blocked: \(envelope.reasons)")
        #expect(!envelope.reasons.contains { $0.contains("kill switch") })
    }
}

/// The kill switch is only "total" while the exemption set stays catalogue-shaped.
/// Adding a tool to `catalogToolNames` silently narrows the operator's stop
/// button, and nothing else in the tree notices. Pin the membership.
@Test func SecurityCenter_killSwitchExemptionSet_isExactlyTheReadOnlyCatalogTools() {
    #expect(SwiftNativeSecurityCenter.catalogToolNames
            == ["tool_catalog", "list_tools", "tool_load", "tool_result_page"],
            "the kill-switch exemption set changed: \(SwiftNativeSecurityCenter.catalogToolNames.sorted()). Every name here survives an active kill switch — prove the new one is a pure read before widening the carve-out.")
}

@Test func SecurityCenter_killSwitchOff_leavesTheSameToolsRunnable() async throws {
    let root = try switchTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(["default": .string("auto")]),
        "securityPolicy": .object(["killSwitchEnabled": .bool(false)]),
    ], at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    // Negative control: without the switch, none of the probe tools is blocked
    // FOR THAT REASON. (Some still gate for their own reasons — that is fine;
    // what must not happen is a kill-switch block with the switch off.)
    for tool in nonCatalogProbeTools {
        let envelope = await center.evaluateTool(
            tool: tool, input: [:], origin: SecurityOriginContext(surface: "chat")
        )
        #expect(!envelope.reasons.contains { $0.contains("kill switch") },
                "\(tool) reported a kill-switch block while the switch is off")
    }
}

/// `toolSigningRequired = true` must actually block an unsigned high-risk tool.
/// `acme_post_release` is unknown to every carve-out and trips the `post`
/// keyword catcher -> external_send / .high, so it is exactly the shape the
/// gate exists for. The tools registry is left absent (empty registry).
@Test func SecurityCenter_toolSigningRequired_blocksUnsignedHighRiskToolWhenRestored() async throws {
    let root = try switchTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(["default": .string("auto")]),
        "securityPolicy": .object(["toolSigningRequired": .bool(true)]),
    ], at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "acme_post_release",
        input: ["body": .string("ship it")],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.signedToolKnown == false, "probe tool must be unsigned for this to measure anything")
    #expect(envelope.risk == "high" || envelope.risk == "critical",
            "probe tool profiled as \(envelope.risk); the signing gate only fires at >= high")
    #expect(envelope.decision == .block, "restoring tool signing did not block: \(envelope.reasons)")
    #expect(envelope.reasons.contains { $0.contains("unsigned high-risk tool is blocked") })

    // Built-ins / notification / catalog names are signature-known by identity,
    // so restoring signing must not brick her own tools.
    for tool in ["recall_memory", "mac.notify", "tool_catalog"] {
        let known = await center.evaluateTool(
            tool: tool, input: [:], origin: SecurityOriginContext(surface: "chat")
        )
        #expect(known.signedToolKnown, "\(tool) lost its signature-known identity")
        #expect(!known.reasons.contains { $0.contains("unsigned high-risk tool is blocked") },
                "\(tool) was blocked by the signing gate: \(known.reasons)")
    }
}

/// The shipped default is FALSE — the widening direction. Pinned so the note-only
/// behaviour stays visible instead of being mistaken for enforcement.
@Test func SecurityCenter_toolSigningNotRequired_recordsANoteInsteadOfBlocking() async throws {
    let root = try switchTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(["default": .string("auto")]),
        "securityPolicy": .object(["toolSigningRequired": .bool(false)]),
    ], at: root)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "acme_post_release",
        input: ["body": .string("ship it")],
        origin: SecurityOriginContext(surface: "chat")
    )
    #expect(envelope.signedToolKnown == false)
    #expect(!envelope.reasons.contains { $0.contains("unsigned high-risk tool is blocked") })
    #expect(envelope.reasons.contains { $0.contains("tool signature not in registry") },
            "the unsigned tool left no audit note: \(envelope.reasons)")
}
