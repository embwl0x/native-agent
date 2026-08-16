import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter

/// W2/W3 — model-tool reachability AND the gate teeth for the four INJECTION
/// tools (mac_keystroke / mac_click / mac_scroll / mac_ax_act).
///
/// The executor itself is proven by MacControlTests/MacAccessibilityActuatorTests
/// and the three-gate refusals by SwiftNativeMacControlTests. These prove the
/// SURFACE: the model can see and call them when it should, cannot when it
/// shouldn't, they keep an approval floor that an active Full Mac YOLO window
/// does NOT flatten, they are blocked in restricted file-access modes, and they
/// carry a motor owner (unlike the reads).
///
/// HERMETICITY: every dispatcher/trust type is constructed with a temp
/// dataRoot. Nothing touches the live app data root, and no test here can reach
/// a real CGEvent — dispatch stops at a gate or at the TCC grant.

private func injTempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-ax-inject-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func injWriteTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try policy.serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("policy.json"))
}

/// Full Mac active. `accessibilityAllowed` is the ONE knob under test.
private func injFullMacPolicy(accessibilityAllowed: Bool) -> JSONValue {
    .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(accessibilityAllowed),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ])
}

/// W6 adds `mac_wake` to this list rather than to the READ list, even though
/// most of its result is a `mac_view`: it posts a HID mouse move, so it must
/// clear every gate the other four do. Everything below runs over it unchanged
/// — catalog visibility, schema honesty, the category and Full-Mac denials, the
/// approval floor a YOLO window cannot flatten, the read_only block and the
/// motor owner. It is deliberately absent from the one loop that EXECUTES
/// (`macInjectionTools_dispatchToTheMatchingMacControlAction`), which builds a
/// production MacControl with the live CGEvent sink; wake's execution path is
/// proven hermetically in MacControlTests/MacWakeTests.swift instead.
private let injToolNames = ["mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act", "mac_wake"]

// MARK: - Catalog reachability

@Test
func macInjectionTools_areVisibleToTheModel_whenAccessibilityCategoryOn() async throws {
    let root = try injTempRoot("catalog-on")
    defer { try? FileManager.default.removeItem(at: root) }
    try injWriteTrustPolicy(root, injFullMacPolicy(accessibilityAllowed: true))

    let tools = SwiftToolDispatcher(dataRoot: root)
    let names = try await tools.listAvailableTools()
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    for tool in injToolNames {
        #expect(names.contains(tool), "\(tool) must appear in listAvailableTools()")
        #expect(schemaNames.contains(tool), "\(tool) must have a model-visible schema — a name without one is unreachable")
    }

    // The discovery block names them as ACTS, not as reads and not as app
    // control. A surface that mislabels injection is how a user ends up
    // approving something they think is a read.
    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
    guard case .object(let obj) = catalog,
          case .array(let acts)? = obj["mac_accessibility_act_available_tools"] else {
        Issue.record("expected mac_accessibility_act_available_tools in tool_catalog")
        return
    }
    for tool in injToolNames {
        #expect(acts.contains(.string(tool)), "tool_catalog must list \(tool) as an accessibility ACT tool")
    }
    if case .array(let reads)? = obj["mac_accessibility_read_available_tools"] {
        for tool in injToolNames {
            #expect(!reads.contains(.string(tool)), "\(tool) types/clicks — it must never be listed as a read")
        }
    }
}

@Test
func macInjectionTools_areAbsent_whenAccessibilityCategoryOff() async throws {
    let root = try injTempRoot("catalog-off")
    defer { try? FileManager.default.removeItem(at: root) }
    // Full Mac still ACTIVE — only accessibility_allowed flips.
    try injWriteTrustPolicy(root, injFullMacPolicy(accessibilityAllowed: false))

    let tools = SwiftToolDispatcher(dataRoot: root)
    let names = try await tools.listAvailableTools()
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    for tool in injToolNames {
        #expect(!names.contains(tool), "\(tool) must not be catalog-visible with the category off")
        #expect(!schemaNames.contains(tool), "\(tool) must not have a schema with the category off")
    }
    // Negative control: Full Mac itself is genuinely still on, so this cannot
    // pass for the wrong reason.
    #expect(names.contains("write_file"))
}

@Test
func macInjectionTools_areAbsent_whenFullMacInactive() async throws {
    let root = try injTempRoot("catalog-nofullmac")
    defer { try? FileManager.default.removeItem(at: root) }
    // No trust policy at all → Full Mac inactive.
    let tools = SwiftToolDispatcher(dataRoot: root)
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    for tool in injToolNames {
        #expect(!schemaNames.contains(tool), "\(tool) must be invisible with Full Mac inactive")
    }
}

// MARK: - Schema honesty

@Test
func macInjectionTools_schemasSayPlainlyWhatTheyDo() async throws {
    let root = try injTempRoot("schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let schemas = dispatcher.builtInToolSchemas(includeFullMacAccessibilityInjectionTools: true)

    func schema(_ name: String) throws -> LLMToolSchema {
        try #require(schemas.first { $0.name == name }, "\(name) schema missing")
    }

    for name in injToolNames {
        let desc = try schema(name).description.lowercased()
        // Every injection tool must say it needs approval, so the model cannot
        // reason "this is a quiet helper".
        #expect(desc.contains("approval"), "\(name) description must state that it requires approval")
        #expect(desc.contains("accessibility"), "\(name) description must name the accessibility gate")
    }
    // And each must name its ACTUAL mechanism — no euphemism.
    #expect(try schema("mac_keystroke").description.lowercased().contains("physical keyboard"))
    #expect(try schema("mac_keystroke").description.lowercased().contains("frontmost"))
    #expect(try schema("mac_click").description.lowercased().contains("physical mouse"))
    #expect(try schema("mac_scroll").description.lowercased().contains("scroll"))
    let axAct = try schema("mac_ax_act").description.lowercased()
    #expect(axAct.contains("mac_ax_find") || axAct.contains("mac_ax_tree"),
            "mac_ax_act must tell the model where a path comes from")
    #expect(axAct.contains("fall") && axAct.contains("click"),
            "mac_ax_act must disclose the synthesized-click fallback")

    // Parameter shape.
    func properties(_ name: String) throws -> [String: JSONValue] {
        guard case .object(let parsed) = try JSONValue.parse(try schema(name).parametersJSON),
              case .object(let props)? = parsed["properties"] else { return [:] }
        return props
    }
    let attentionTokenKeys: Set<String> = ["attention_session", "attention_user_sequence"]
    #expect(Set(try properties("mac_keystroke").keys)
        == Set(["text", "keys"]).union(attentionTokenKeys))
    #expect(Set(try properties("mac_click").keys)
        == Set(["x", "y", "button", "count", "double", "from", "to", "duration_ms", "mark", "view"])
            .union(attentionTokenKeys))
    #expect(Set(try properties("mac_scroll").keys)
        == Set(["dx", "dy", "x", "y", "units"]).union(attentionTokenKeys))
    #expect(Set(try properties("mac_wake").keys)
        == Set(["key_tap", "settle_ms", "full_screen"]).union(attentionTokenKeys))
    // W3.5: `mark`+`view` is the second legal way to name the target, so the
    // property set grew — and `path` stopped being schema-required, because a
    // mark is the preferred form. The handler still refuses a call that names
    // NEITHER (SwiftNativeMacControlTests.axActRejectsAMalformedPath and
    // MacScreenViewTests.axActRefusesAMarkAndAConflictingPathInTheSameCall).
    #expect(Set(try properties("mac_ax_act").keys)
        == Set(["path", "action", "value", "mark", "view"]).union(attentionTokenKeys))
    // Acting on an unspecified element must still be impossible — but since
    // W3.5 there are TWO ways to specify it (mark+view, or path), so neither
    // can be schema-required alone. The requirement moved into the handler,
    // which refuses a call naming neither, a malformed path, or a mark and a
    // conflicting path (SwiftNativeMacControlTests.axActRejectsAMalformedPath,
    // MacScreenViewTests.axActRefusesAMarkAndAConflictingPathInTheSameCall).
    guard case .object(let axParsed) = try JSONValue.parse(try schema("mac_ax_act").parametersJSON),
          case .array(let required)? = axParsed["required"] else {
        Issue.record("mac_ax_act schema has no required array")
        return
    }
    #expect(required.isEmpty)
}

// MARK: - Dispatch mapping + category gate

@Test
func macInjectionTools_dispatchToTheMatchingMacControlAction() async throws {
    let root = try injTempRoot("dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    try injWriteTrustPolicy(root, injFullMacPolicy(accessibilityAllowed: true))
    let tools = SwiftToolDispatcher(dataRoot: root)

    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated.
    //
    // OLD CONTRACT: a RAW `SwiftToolDispatcher` had no capability in scope and
    // refused with `injection_approval_missing`; the mapping could only be
    // pinned through an explicitly minted capability.
    // NEW CONTRACT: `SwiftToolDispatcher+Sandbox` self-mints for the call, so
    // the raw path reaches MacControl too. Both paths are exercised below and
    // both must name the same action — that equality IS the mapping assertion,
    // and it now also pins that the self-mint binds the RIGHT action.
    for (tool, action) in [
        ("mac_keystroke", "keystroke"),
        ("mac_click", "click"),
        ("mac_scroll", "scroll"),
        ("mac_ax_act", "ax_act"),
    ] {
        let input: [String: JSONValue]
        switch tool {
        case "mac_keystroke": input = ["text": .string("x")]
        case "mac_click": input = ["x": .int(1), "y": .int(2)]
        case "mac_scroll": input = ["dy": .int(-1)]
        default: input = ["path": .array([.int(0)])]
        }
        // RAW: reaches MacControl on a self-minted capability, naming the
        // action the tool maps to.
        let rawResult = try await tools.dispatch(tool: tool, input: input, surface: "chat")
        guard case .object(let rawObj) = rawResult else {
            Issue.record("\(tool) did not return an object envelope from the raw dispatcher")
            continue
        }
        #expect(rawObj["action"] == .string(action),
                "\(tool) self-mints a capability bound to \(action)")
        #expect(rawObj["error"] != .string("approval_not_granted: \(action) requires an approved injection request"),
                "\(tool): the approval tier is retired — no approval refusal may remain")

        // EXPLICIT CAPABILITY: a capability minted for THIS action lets the call through
        // to MacControl, and the envelope names the action the tool maps to.
        guard let capability = MacInjectionCapability.mint(
            approvalID: "reachability-approval",
            action: action,
            body: input
        ) else {
            Issue.record("could not mint a capability for \(action)")
            continue
        }
        let result = try await MacInjectionCapabilityContext.$current.withValue(capability) {
            try await tools.dispatch(tool: tool, input: input, surface: "chat")
        }
        guard case .object(let obj) = result else {
            Issue.record("\(tool) did not return an object envelope")
            continue
        }
        #expect(obj["action"] == .string(action), "\(tool) must dispatch MacControl action \(action)")
        #expect(obj["viaSwift"] == .bool(true))
        // Past the approval gate. On a CI host with no Accessibility grant it
        // stops at the TCC precondition, which is a DIFFERENT refusal — that
        // difference is what proves the approval gate is what opened.
        #expect(obj["error"] != .string("approval_not_granted: \(action) requires an approved injection request"),
                "\(tool) with a valid capability must clear the approval gate")
    }
}

@Test
func macInjectionTools_areDeniedWhenAccessibilityCategoryOff() async throws {
    let root = try injTempRoot("dispatch-off")
    defer { try? FileManager.default.removeItem(at: root) }
    try injWriteTrustPolicy(root, injFullMacPolicy(accessibilityAllowed: false))
    let tools = SwiftToolDispatcher(dataRoot: root)

    for tool in injToolNames {
        await #expect(throws: (any Error).self, "\(tool) must be denied with the category off") {
            _ = try await tools.dispatch(tool: tool, input: [:], surface: "chat")
        }
    }
}

@Test
func macInjectionTools_areDeniedWhenFullMacIsInactive() async throws {
    let root = try injTempRoot("dispatch-nofullmac")
    defer { try? FileManager.default.removeItem(at: root) }
    // No trust policy → Full Mac inactive, so `appControlAllowed` is false.
    let tools = SwiftToolDispatcher(dataRoot: root)
    for tool in injToolNames {
        await #expect(throws: (any Error).self, "\(tool) must be denied with Full Mac inactive") {
            _ = try await tools.dispatch(tool: tool, input: [:], surface: "chat")
        }
    }
}

// MARK: - The approval floor is RETIRED under an active Full Mac YOLO window

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: the injection family kept a hard `send_approval` floor even
/// under an active Full Mac YOLO window — enforced in three stacked places
/// (the YOLO exclusion list, the post-resolution clamp, the Trust Center
/// defaults). NEW CONTRACT: all three were removed/flipped, so the family
/// resolves `auto` exactly like the perception reads. Full Mac being active,
/// the accessibility category, and the macOS TCC grant are what remain.
@Test
func macInjectionTools_resolveAutoUnderFullMac_approvalFloorRetired() async throws {
    let root = try injTempRoot("autonomy")
    defer { try? FileManager.default.removeItem(at: root) }
    try injWriteTrustPolicy(root, injFullMacPolicy(accessibilityAllowed: true))
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))

    for tool in injToolNames {
        let level = try await gate.autonomyLevel(toolName: tool, surface: "chat", originTrusted: true)
        #expect(level == "auto", "\(tool) resolves auto post-cutover (got \(level))")
    }

    // TEETH: this is not a blanket-auto resolver — a floor that SURVIVED the
    // cutover still comes back non-auto in the same fixture.
    let floored = try await gate.autonomyLevel(toolName: "self_install", surface: "chat", originTrusted: true)
    #expect(floored == "confirm", "self_install kept its floor (got \(floored))")

    // The read tools and the app-control pair resolve to auto in the SAME
    // fixture, as they always did.
    for tool in ["mac_ax_status", "mac_ax_tree", "mac_ax_find"] {
        let level = try await gate.autonomyLevel(toolName: tool, surface: "chat", originTrusted: true)
        #expect(level == "auto", "\(tool) is a read — it must stay auto, got \(level)")
    }
    let focus = try await gate.autonomyLevel(toolName: "mac_focus_app", surface: "chat", originTrusted: true)
    #expect(focus == "auto", "mac_focus_app resolves auto under Full Mac — the contrast is the point")

    // The tier is EXPLICIT in the defaults, under both spellings, not a
    // fallback: `autonomyForTool` matches override keys literally, and the gate
    // is asked about `mac_keystroke` while the approval card speaks
    // `mac.keystroke`.
    let policyObj = await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicy()
    guard case .object(let autonomy)? = policyObj["toolAutonomy"] else {
        Issue.record("expected toolAutonomy in the default trust policy")
        return
    }
    for key in ["mac.keystroke", "mac.click", "mac.scroll", "mac.ax_act",
                "mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act"] {
        #expect(autonomy[key] == .string("auto"),
                "\(key) carries an explicit auto tier in the Trust Center defaults post-cutover")
    }
    #expect(autonomy["restart_app"] == .string("confirm"),
            "teeth: the defaults table is not blanket-auto")
    #expect(autonomy["mac.ax_tree"] == .string("auto"), "read tier is unchanged")
}

// MARK: - Restricted file-access modes

private struct InjEchoDispatcher: ToolDispatchClient, Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object(["reached_inner": .bool(true), "tool": .string(tool)])
    }
    func listAvailableTools() async throws -> [String] {
        injToolNames + ["mac_ax_tree", "persona_write"]
    }
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: the injection family was blocked (and unlisted) under both
/// `fileAccess=read_only` and `fileAccess=none`, on the reasoning that a
/// synthesized keystroke is a route to arbitrary file access. NEW CONTRACT: the
/// family was removed from BOTH blocklists so the bridge and other
/// non-interactive surfaces can drive them; file-access mode no longer bears on
/// Mac motor tools at all. It still bears on file/persona writes, which is
/// where the teeth move to.
@Test
func macInjectionTools_passReadOnlyAndNoFileAccessModes_blocklistRetired() async throws {
    for mode in ["read_only", "none"] {
        let gated = FileAccessGatedDispatcher(inner: InjEchoDispatcher(), fileAccess: mode)
        for tool in injToolNames {
            let result = try await gated.dispatch(tool: tool, input: [:], surface: "chat")
            #expect(result == .object(["reached_inner": .bool(true), "tool": .string(tool)]),
                    "\(tool) passes through fileAccess=\(mode) post-cutover")
        }
        let visible = try await gated.listAvailableTools()
        for tool in injToolNames {
            #expect(visible.contains(tool), "\(tool) is listed under fileAccess=\(mode) post-cutover")
        }
        // TEETH: the mode is still a real gate — a persona WRITE is blocked and
        // unlisted in the same wrapper, in both modes.
        await #expect(throws: (any Error).self, "persona_write must stay blocked under fileAccess=\(mode)") {
            _ = try await gated.dispatch(tool: "persona_write", input: [:], surface: "chat")
        }
        #expect(!visible.contains("persona_write"), "persona_write must not be listed under fileAccess=\(mode)")
        // The AX READ passes through the same wrapper in the same mode.
        let read = try await gated.dispatch(tool: "mac_ax_tree", input: [:], surface: "chat")
        #expect(read == .object(["reached_inner": .bool(true), "tool": .string("mac_ax_tree")]),
                "mac_ax_tree is a read and must still pass under fileAccess=\(mode)")
    }
}

// MARK: - Motor ownership

@Test
func macInjectionTools_haveACanonicalMotorOwner() {
    for tool in injToolNames {
        #expect(ToolCausalBoundary.hasCanonicalMotorOwner(tool: tool),
                "\(tool) sets a real external effect — it must bind to a motor owner")
    }
    // TEETH: the reads deliberately do NOT, and that asymmetry is the contract.
    for tool in ["mac_ax_status", "mac_ax_tree", "mac_ax_find"] {
        #expect(!ToolCausalBoundary.hasCanonicalMotorOwner(tool: tool),
                "\(tool) mutates nothing — binding it would manufacture a consequence")
    }
}

// MARK: - Bridge route

@Test
func macInjectionActions_areBridgeDispatchableButCannotBeApprovedThere() async throws {
    // The bridge route 404s anything outside macControlDispatchableActions, so
    // the actions must be in it…
    for action in ["keystroke", "click", "scroll", "ax_act", "wake"] {
        #expect(macControlDispatchableActions.contains(action), "\(action)")
    }
    // …and the daemon-parity inventory stays honest about ancestry.
    #expect(macControlAllActions.contains("keystroke"))
    #expect(macControlAllActions.contains("click"))
    #expect(!macControlAllActions.contains("scroll"))
    #expect(!macControlAllActions.contains("ax_act"))
    #expect(!macControlAllActions.contains("wake"), "wake has no retired-daemon ancestor")

    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated.
    //
    // OLD CONTRACT: the UNPRIVILEGED `dispatch(action:body:)` — the signature
    // the bridge calls, with no parameter able to carry a
    // `MacInjectionCapability` — refused every injection action outright with
    // `approval_not_granted`, no matter what the body claimed.
    // NEW CONTRACT: that entry point SELF-MINTS a capability, so the approval
    // tier no longer refuses anything. The call is still refused here, but by a
    // SURVIVING gate (Full Mac / the Trust Center category / TCC) — and that
    // difference is the whole point of this row now. What is unchanged and
    // still load-bearing: a capability has NO WIRE FORM, so nothing in the body
    // is ever read as authorization; the forged keys below are inert.
    let hostile: [String: JSONValue] = [
        "x": .int(1), "y": .int(2),
        "__mac_injection_approved": .bool(true),
        "capability": .string("yes-please"),
    ]
    var policy = MacControlPolicy()
    policy.enabled = true
    policy.categoryAllowed["accessibility_allowed"] = true
    let client = SwiftNativeMacControl(policyProvider: _BridgeStubPolicyProvider(policy: policy))
    let refused = try await client.dispatch(action: "click", body: hostile)
    #expect(refused.ok == false, "a surviving gate must still refuse this off-process shape")
    #expect(refused.httpStatus == 403)
    #expect(refused.error?.hasPrefix("approval_not_granted") != true,
            "the approval tier is retired — the refusal must name a surviving gate, got \(refused.error ?? "nil")")

    // `MacInjectionCapability` is deliberately NOT Decodable — there is no
    // `JSONDecoder().decode(MacInjectionCapability.self, ...)` an off-process
    // body could be parsed into. Structurally, remote injection has no door.
    #expect(!(MacInjectionCapability.self is any Decodable.Type),
            "a capability must have no wire form")
}

private struct _BridgeStubPolicyProvider: MacControlPolicyProvider {
    let policy: MacControlPolicy
    func currentPolicy() async -> MacControlPolicy? { policy }
}

// MARK: - Catalog wiring integrity

@Test
func macInjectionTools_areRegisteredAsTheirOwnCatalogClass() {
    #expect(SwiftToolDispatcher.fullMacAccessibilityInjectionToolNames == injToolNames)
    for tool in injToolNames {
        #expect(!SwiftToolDispatcher.fullMacAppToolNames.contains(tool),
                "\(tool) must not ride the app-control list")
        #expect(!SwiftToolDispatcher.fullMacAccessibilityReadToolNames.contains(tool),
                "\(tool) must not ride the READ list — that list has no approval floor")
        #expect(SwiftToolDispatcher.reservedBuiltInNames.contains(tool),
                "\(tool) must be reserved so a registry custom tool cannot shadow it")
    }
}

@Test
func macInjectionActions_areRegisteredWithHighRiskAndApproval() {
    let byId = Dictionary(
        uniqueKeysWithValues: connectorActionDescriptors().map { ($0.id, $0) }
    )
    for id in ["mac.keystroke", "mac.click", "mac.scroll", "mac.ax_act"] {
        guard let descriptor = byId[id] else {
            Issue.record("\(id) missing from the connector actions registry")
            continue
        }
        #expect(descriptor.category == "accessibility", "\(id)")
        #expect(descriptor.requiresApproval, "\(id) must require approval")
        #expect(descriptor.risk == "high", "\(id) must be high risk, got \(descriptor.risk)")
        #expect(!descriptor.dryRunAvailable, "\(id) has no dry run — a synthesized event cannot be rehearsed")
    }
    // TEETH: the reads in the same registry are low-risk and approval-free.
    #expect(byId["mac.ax_tree"]?.requiresApproval == false)
    #expect(byId["mac.ax_tree"]?.risk == "low")
}
