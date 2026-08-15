import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter

/// W1b — model-tool reachability for the three READ-ONLY accessibility
/// perception tools (mac_ax_status / mac_ax_tree / mac_ax_find).
///
/// The organ (MacAccessibilityReader + the ax_status/ax_tree/ax_find
/// sub-actions) is proven by MacControlTests/MacAccessibilityReaderTests.
/// These tests prove the SURFACE: that the model can see the tools when the
/// accessibility category is on, cannot see them when it is off, that each
/// name lands on the matching MacControl action, and that all three are
/// classified read-only (no approval floor, no motor/write side-effect).
///
/// HERMETICITY: every dispatcher/trust type here is constructed with a temp
/// dataRoot. Nothing touches the live app data root.

private func axTempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-ax-tool-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func axWriteTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try policy.serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("policy.json"))
}

/// Full Mac active. `accessibilityAllowed` is the ONE knob under test — every
/// other category stays as given so a flip of that single boolean is the only
/// difference between the ON and OFF cases.
private func axFullMacPolicy(accessibilityAllowed: Bool) -> JSONValue {
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

// W3.5 — mac_view joins this list rather than getting a parallel one: it is
// the same category, the same read tier, the same route and the same
// no-approval contract, so every reachability property asserted here must hold
// for it too. Its own W3.5-specific surface (schema shape, action mapping,
// mark plumbing) is pinned in MacFusedViewToolReachabilityTests.
private let axToolNames = ["mac_ax_status", "mac_ax_tree", "mac_ax_find", "mac_view"]

// MARK: - Catalog reachability

@Test
func macAXReadTools_areVisibleToTheModel_whenAccessibilityCategoryOn() async throws {
    let root = try axTempRoot("catalog-on")
    defer { try? FileManager.default.removeItem(at: root) }
    try axWriteTrustPolicy(root, axFullMacPolicy(accessibilityAllowed: true))

    let tools = SwiftToolDispatcher(dataRoot: root)

    // 1. name catalog (what tool_catalog / listAvailableTools advertises)
    let names = try await tools.listAvailableTools()
    for tool in axToolNames {
        #expect(names.contains(tool), "\(tool) must appear in listAvailableTools() under Full Mac + accessibility")
    }

    // 2. SCHEMA catalog — the surface the provider actually sends to the model.
    //    A name without a schema is not reachable by the model.
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    for tool in axToolNames {
        #expect(schemaNames.contains(tool), "\(tool) must have a model-visible schema under Full Mac + accessibility")
    }

    // 3. tool_catalog discovery block names them as READS, not app control.
    let catalog = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
    guard case .object(let catalogObj) = catalog,
          case .array(let axAvailable)? = catalogObj["mac_accessibility_read_available_tools"] else {
        Issue.record("expected mac_accessibility_read_available_tools array in tool_catalog")
        return
    }
    for tool in axToolNames {
        #expect(axAvailable.contains(.string(tool)), "tool_catalog must list \(tool) as an available accessibility READ tool")
    }
    if case .array(let appTools)? = catalogObj["mac_app_available_tools"] {
        for tool in axToolNames {
            #expect(!appTools.contains(.string(tool)), "\(tool) is perception, not app control — it must not be listed under mac_app_available_tools")
        }
    }
}

@Test
func macAXReadTools_areAbsent_whenAccessibilityCategoryOff() async throws {
    let root = try axTempRoot("catalog-off")
    defer { try? FileManager.default.removeItem(at: root) }
    // Full Mac still ACTIVE — only accessibility_allowed flips. This is the
    // negative control that proves the category gate is what surfaces them,
    // not merely "Full Mac is on".
    try axWriteTrustPolicy(root, axFullMacPolicy(accessibilityAllowed: false))

    let tools = SwiftToolDispatcher(dataRoot: root)
    let names = try await tools.listAvailableTools()
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    for tool in axToolNames {
        #expect(!names.contains(tool), "\(tool) must NOT be catalog-visible when the accessibility category is off")
        #expect(!schemaNames.contains(tool), "\(tool) must NOT have a model-visible schema when the accessibility category is off")
    }
    // And Full Mac itself is genuinely still on — otherwise this test would
    // pass for the wrong reason (everything absent).
    #expect(names.contains("write_file"), "negative control is only meaningful while Full Mac file tools remain visible")
}

@Test
func macAXReadTools_areAbsent_whenFullMacInactive() async throws {
    let root = try axTempRoot("catalog-nofullmac")
    defer { try? FileManager.default.removeItem(at: root) }
    // No trust policy at all → Full Mac inactive, every category closed.
    let tools = SwiftToolDispatcher(dataRoot: root)
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    for tool in axToolNames {
        #expect(!schemaNames.contains(tool), "\(tool) must be invisible with Full Mac inactive")
    }
}

// MARK: - Schema shape

@Test
func macAXReadTools_schemasDeclareTheDocumentedParameters() async throws {
    let root = try axTempRoot("schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let schemas = dispatcher.builtInToolSchemas(includeFullMacAccessibilityReadTools: true)

    func properties(_ name: String) throws -> [String: JSONValue] {
        let schema = try #require(schemas.first { $0.name == name }, "\(name) schema missing")
        // Honesty contract: the description must say it reads the on-screen
        // UI accessibility tree and that it is read-only.
        let desc = schema.description.lowercased()
        #expect(desc.contains("accessibility"), "\(name) description must name the accessibility surface it reads")
        #expect(desc.contains("read-only") || desc.contains("changes nothing") || desc.contains("does not click"),
                "\(name) description must state it is read-only")
        guard case .object(let parsed) = try JSONValue.parse(schema.parametersJSON),
              case .object(let props)? = parsed["properties"] else {
            return [:]
        }
        // No AX read takes a required argument.
        if case .array(let required)? = parsed["required"] {
            #expect(required.isEmpty, "\(name) must not require any argument")
        }
        return props
    }

    #expect(try properties("mac_ax_status").isEmpty, "mac_ax_status takes no parameters")
    let tree = try properties("mac_ax_tree")
    #expect(Set(tree.keys) == ["max_nodes", "max_depth"])
    let find = try properties("mac_ax_find")
    #expect(Set(find.keys) == ["role", "title", "value", "limit"])
}

// MARK: - Dispatch mapping

@Test
func macAXReadTools_dispatchToTheMatchingMacControlAction() async throws {
    let root = try axTempRoot("dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    try axWriteTrustPolicy(root, axFullMacPolicy(accessibilityAllowed: true))
    let tools = SwiftToolDispatcher(dataRoot: root)

    // MacControlResult.toJSON() always carries the action it ran, whether or
    // not the host holds the macOS Accessibility grant — so this pins the
    // tool → action mapping without depending on the test machine's TCC state.
    for (tool, action) in [
        ("mac_ax_status", "ax_status"),
        ("mac_ax_tree", "ax_tree"),
        ("mac_ax_find", "ax_find"),
    ] {
        let result = try await tools.dispatch(
            tool: tool,
            input: tool == "mac_ax_find" ? ["role": .string("AXButton")] : [:],
            surface: "chat"
        )
        guard case .object(let obj) = result else {
            Issue.record("\(tool) did not return an object envelope")
            continue
        }
        #expect(obj["action"] == .string(action), "\(tool) must dispatch MacControl action \(action)")
        #expect(obj["viaSwift"] == .bool(true), "\(tool) must run through the Swift MacControl path")
        // NOTE on operationId: MacControl.dispatch stamps one on EVERY
        // dispatchable action — it is the operation store's idempotency/replay
        // key, not a claim that a motor effect settled. So the read-only
        // proof lives at the ToolCausalBoundary layer (no motor binding), not
        // in this envelope; see
        // macAXReadTools_haveNoMotorOwnerAndSurviveReadOnlyMode.
        #expect(obj["error"] != .string("unknown_action"), "\(tool) must reach a real MacControl handler")
    }
}

@Test
func macAXReadTools_areDeniedWhenAccessibilityCategoryOff() async throws {
    let root = try axTempRoot("dispatch-off")
    defer { try? FileManager.default.removeItem(at: root) }
    try axWriteTrustPolicy(root, axFullMacPolicy(accessibilityAllowed: false))
    let tools = SwiftToolDispatcher(dataRoot: root)

    for tool in axToolNames {
        await #expect(throws: (any Error).self, "\(tool) must be denied when the accessibility category is off") {
            _ = try await tools.dispatch(tool: tool, input: [:], surface: "chat")
        }
    }
}

// MARK: - Read-only classification

@Test
func macAXReadTools_resolveToAutoWithNoApprovalTier() async throws {
    let root = try axTempRoot("autonomy")
    defer { try? FileManager.default.removeItem(at: root) }
    try axWriteTrustPolicy(root, axFullMacPolicy(accessibilityAllowed: true))
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))

    for tool in axToolNames {
        let level = try await gate.autonomyLevel(toolName: tool, surface: "chat", originTrusted: true)
        #expect(level == "auto", "\(tool) is a read — expected auto, got \(level)")
    }
    // The store-level default tier is EXPLICIT, not a fallback: a fresh trust
    // policy already carries the three entries.
    let policyObj = await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicy()
    guard case .object(let autonomy)? = policyObj["toolAutonomy"] else {
        Issue.record("expected toolAutonomy object in the default trust policy")
        return
    }
    for actionId in ["mac.ax_status", "mac.ax_tree", "mac.ax_find", "mac.view"] {
        #expect(autonomy[actionId] == .string("auto"),
                "\(actionId) must carry an explicit auto tier in the Trust Center defaults")
    }
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: mac.focus_app / mac.quit_app carried an
    // explicit send_approval tier and served as the control-tier neighbours
    // here. NEW CONTRACT: the whole mac.* family is auto in the Trust Center
    // defaults, so the contrast row moves to a tier that SURVIVED the cutover.
    #expect(autonomy["mac.focus_app"] == .string("auto"))
    #expect(autonomy["mac.quit_app"] == .string("auto"))
    #expect(autonomy["restart_app"] == .string("confirm"),
            "restart_app kept its confirm tier — teeth against a blanket-auto defaults table")
    #expect(autonomy["self_install"] == .string("confirm"))
}

/// Minimal inner dispatcher: echoes a marker so the wrapper's pass-through is
/// distinguishable from its refusal.
private struct AXEchoDispatcher: ToolDispatchClient, Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object(["reached_inner": .bool(true), "tool": .string(tool)])
    }
    func listAvailableTools() async throws -> [String] {
        axToolNames + ["mac_focus_app", "mac_quit_app", "persona_write", "write_file"]
    }
}

@Test
func macAXReadTools_haveNoMotorOwnerAndSurviveReadOnlyMode() async throws {
    for tool in axToolNames {
        #expect(!ToolCausalBoundary.hasCanonicalMotorOwner(tool: tool),
                "\(tool) mutates nothing — it must not claim a canonical motor owner")
    }

    // fileAccess=read_only PERMITS perception reads.
    //
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: mac_focus_app / mac_quit_app stayed
    // BLOCKED (and unlisted) in this same wrapper, and that pairing was the
    // point. NEW CONTRACT: both were removed from readOnlyBlockedExact, so
    // read_only no longer bears on the Mac control family at all — the
    // accessibility category and the macOS TCC grant are their gates. The mode
    // is still load-bearing for FILE/persona writes, which is where the teeth
    // move to.
    let readOnly = FileAccessGatedDispatcher(inner: AXEchoDispatcher(), fileAccess: "read_only")
    for tool in axToolNames + ["mac_focus_app", "mac_quit_app"] {
        let result = try await readOnly.dispatch(tool: tool, input: [:], surface: "chat")
        #expect(result == .object(["reached_inner": .bool(true), "tool": .string(tool)]),
                "\(tool) passes through fileAccess=read_only post-cutover")
    }
    for tool in ["persona_write", "write_file"] {
        await #expect(throws: (any Error).self, "\(tool) must stay blocked under fileAccess=read_only") {
            _ = try await readOnly.dispatch(tool: tool, input: [:], surface: "chat")
        }
    }
    let visible = try await readOnly.listAvailableTools()
    for tool in axToolNames + ["mac_focus_app", "mac_quit_app"] {
        #expect(visible.contains(tool), "\(tool) must remain listed under fileAccess=read_only")
    }
    #expect(!visible.contains("persona_write"))
    #expect(!visible.contains("write_file"))
}

// MARK: - Bridge route reachability

@Test
func macAXReadActions_areInTheBridgeDispatchableSet() {
    // NativeClient+CutoverSeams' HTTP/iOS-remote route 404s any action outside
    // this set. Gating it on macControlAllActions (daemon parity only) is what
    // made ax_* unreachable on the bridge path.
    for action in ["ax_status", "ax_tree", "ax_find", "view"] {
        #expect(macControlDispatchableActions.contains(action),
                "\(action) must be in macControlDispatchableActions or the bridge route 404s it")
        #expect(!macControlAllActions.contains(action),
                "\(action) has no daemon ancestor — the daemon-parity inventory must stay honest")
    }
}

// MARK: - Catalog wiring integrity

@Test
func macAXReadTools_areRegisteredAsTheirOwnCatalogClass() {
    #expect(SwiftToolDispatcher.fullMacAccessibilityReadToolNames == axToolNames)
    for tool in axToolNames {
        #expect(!SwiftToolDispatcher.fullMacAppToolNames.contains(tool),
                "\(tool) must not ride the app-control list")
        #expect(SwiftToolDispatcher.reservedBuiltInNames.contains(tool),
                "\(tool) must be a reserved built-in so a registry custom tool cannot shadow it")
    }
}
