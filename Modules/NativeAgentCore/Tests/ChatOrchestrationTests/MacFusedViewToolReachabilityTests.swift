import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter

/// W3.5 — model-tool reachability and classification for `mac_view`, the fused
/// view (picture + AX structure, elements numbered).
///
/// The ORGAN is proven in MacControlTests/MacScreenViewTests (geometry, mark
/// selection, caps, redaction, staleness, mark→act). This file proves the
/// SURFACE: that the model can see the tool under the accessibility category
/// and not otherwise, that the name lands on the MacControl `view` action, that
/// it is classified READ tier (auto, no motor owner, allowed under read_only),
/// and — the security-critical one — that letting the act tools take a `mark`
/// did not move any injection gate.
///
/// HERMETICITY: every dispatcher/trust type is built on a temp dataRoot.

private func fvTempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-fusedview-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func fvWriteTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try policy.serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("policy.json"))
}

private func fvFullMacPolicy(accessibilityAllowed: Bool) -> JSONValue {
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

// MARK: - Catalog

@Test
func macView_isVisibleOnlyUnderTheAccessibilityCategory() async throws {
    let on = try fvTempRoot("on")
    defer { try? FileManager.default.removeItem(at: on) }
    try fvWriteTrustPolicy(on, fvFullMacPolicy(accessibilityAllowed: true))
    let onTools = SwiftToolDispatcher(dataRoot: on)
    #expect(try await onTools.listAvailableTools().contains("mac_view"))
    #expect(Set(try await onTools.listAvailableToolSchemas().map(\.name)).contains("mac_view"))

    let off = try fvTempRoot("off")
    defer { try? FileManager.default.removeItem(at: off) }
    // Only accessibility_allowed flips; Full Mac stays ACTIVE.
    try fvWriteTrustPolicy(off, fvFullMacPolicy(accessibilityAllowed: false))
    let offTools = SwiftToolDispatcher(dataRoot: off)
    let offNames = try await offTools.listAvailableTools()
    #expect(!offNames.contains("mac_view"))
    #expect(!Set(try await offTools.listAvailableToolSchemas().map(\.name)).contains("mac_view"))
    #expect(offNames.contains("write_file"),
            "negative control is only meaningful while Full Mac itself is still on")

    // Full Mac inactive (no policy at all): invisible for the second reason.
    let none = try fvTempRoot("nofullmac")
    defer { try? FileManager.default.removeItem(at: none) }
    let noneTools = SwiftToolDispatcher(dataRoot: none)
    #expect(!Set(try await noneTools.listAvailableToolSchemas().map(\.name)).contains("mac_view"))
}

// MARK: - Schema

@Test
func macView_schemaTeachesActingByNameAndTellsTheTruthAboutPermissions() async throws {
    let root = try fvTempRoot("schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = SwiftToolDispatcher(dataRoot: root)
        .builtInToolSchemas(includeFullMacAccessibilityReadTools: true)
    let schema = try #require(schemas.first { $0.name == "mac_view" })
    let desc = schema.description.lowercased()

    // Honesty: read-only, and BOTH permissions named — Screen Recording is a
    // separate grant and the model must be able to say so to User.
    #expect(desc.contains("read-only") || desc.contains("changes nothing"))
    #expect(desc.contains("screen recording"))
    #expect(desc.contains("accessibility"))
    // The calling convention is the point of the description: act by number.
    #expect(desc.contains("mark"))
    #expect(desc.contains("mac_ax_act") || desc.contains("mac_click"))
    // …and the staleness rule, so a model does not hoard view ids.
    #expect(desc.contains("most recent") || desc.contains("older view"))

    guard case .object(let parsed) = try JSONValue.parse(schema.parametersJSON),
          case .object(let props)? = parsed["properties"] else {
        Issue.record("mac_view schema has no properties object"); return
    }
    #expect(Set(props.keys) == ["full_screen", "max_marks", "max_text_items", "max_image_bytes", "max_nodes", "max_depth"])
    if case .array(let required)? = parsed["required"] {
        #expect(required.isEmpty, "looking must take no required argument")
    }
}

@Test
func actToolSchemasOfferMarkAndViewSoTheModelCanPointByName() async throws {
    let root = try fvTempRoot("act-schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = SwiftToolDispatcher(dataRoot: root)
        .builtInToolSchemas(includeFullMacAccessibilityInjectionTools: true)
    for tool in ["mac_click", "mac_ax_act"] {
        let schema = try #require(schemas.first { $0.name == tool })
        guard case .object(let parsed) = try JSONValue.parse(schema.parametersJSON),
              case .object(let props)? = parsed["properties"] else {
            Issue.record("\(tool) has no properties"); continue
        }
        #expect(props["mark"] != nil, "\(tool) must accept a mark from the latest view")
        #expect(props["view"] != nil, "\(tool) must require the view id that mark came from")
        // mac_ax_act no longer hard-requires `path` — mark+view is the other
        // legal way to name the target — but it must still say so, not become
        // an argument-free action.
        if tool == "mac_ax_act", case .array(let required)? = parsed["required"] {
            #expect(required.isEmpty, "mark OR path: neither can be schema-required alone")
        }
        #expect(schema.description.lowercased().contains("approval"),
                "\(tool) keeps its approval honesty regardless of how the target is named")
    }
}

// MARK: - Dispatch mapping

@Test
func macView_dispatchesToTheMacControlViewAction() async throws {
    let root = try fvTempRoot("dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    try fvWriteTrustPolicy(root, fvFullMacPolicy(accessibilityAllowed: true))
    let tools = SwiftToolDispatcher(dataRoot: root)

    // MacControlResult.toJSON() carries the action it ran whichever TCC grants
    // this machine holds, so the mapping is pinned without depending on them.
    let result = try await tools.dispatch(tool: "mac_view", input: [:], surface: "chat")
    guard case .object(let obj) = result else {
        Issue.record("mac_view returned no object envelope"); return
    }
    #expect(obj["action"] == .string("view"))
    #expect(obj["viaSwift"] == .bool(true))
    #expect(obj["error"] != .string("unknown_action"))
}

@Test
func macView_isDeniedWhenTheAccessibilityCategoryIsOff() async throws {
    let root = try fvTempRoot("dispatch-off")
    defer { try? FileManager.default.removeItem(at: root) }
    try fvWriteTrustPolicy(root, fvFullMacPolicy(accessibilityAllowed: false))
    let tools = SwiftToolDispatcher(dataRoot: root)
    await #expect(throws: (any Error).self) {
        _ = try await tools.dispatch(tool: "mac_view", input: [:], surface: "chat")
    }
}

// MARK: - Read-tier classification

@Test
func macView_isReadTier_autoNoMotorOwnerAllowedUnderReadOnly() async throws {
    let root = try fvTempRoot("tier")
    defer { try? FileManager.default.removeItem(at: root) }
    try fvWriteTrustPolicy(root, fvFullMacPolicy(accessibilityAllowed: true))

    // 1. No approval tier — it resolves to auto like the other perception reads.
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))
    let level = try await gate.autonomyLevel(toolName: "mac_view", surface: "chat", originTrusted: true)
    #expect(level == "auto", "looking is not acting — expected auto, got \(level)")
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: mac_keystroke was pinned to
    // send_approval here as the control-tier neighbour. NEW CONTRACT: it
    // resolves auto like the reads; the contrast row moves to a floor that
    // SURVIVED the cutover, so "auto everywhere" still cannot pass by accident.
    let injectionLevel = try await gate.autonomyLevel(
        toolName: "mac_keystroke", surface: "chat", originTrusted: true
    )
    #expect(injectionLevel == "auto", "mac_keystroke resolves auto post-cutover (got \(injectionLevel))")
    let flooredLevel = try await gate.autonomyLevel(
        toolName: "self_install", surface: "chat", originTrusted: true
    )
    #expect(flooredLevel != "auto", "self_install kept its floor — teeth for the auto rows above")

    // 2. It sets no external effect, so it claims no motor owner.
    #expect(!ToolCausalBoundary.hasCanonicalMotorOwner(tool: "mac_view"))
    #expect(ToolCausalBoundary.hasCanonicalMotorOwner(tool: "mac_click"),
            "positive control: the act tools DO bind to a motor owner")

    // 3. It is NOT an injection tool — the capability machinery must not treat
    //    it as one. The MEMBERSHIP fact is unchanged and still pinned.
    #expect(!MacInjectionToolNames.isInjectionTool("mac_view"))
    #expect(MacInjectionToolNames.isInjectionTool("mac_click"), "membership itself is unchanged")
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): the post-resolution
    // approval clamp is RETIRED — `clampedAutonomyLevel` is now the identity
    // function for every tool. OLD CONTRACT: it returned send_approval for the
    // injection family. NEW CONTRACT: it returns `resolved` unchanged, so
    // membership no longer changes an autonomy outcome.
    #expect(MacInjectionToolNames.clampedAutonomyLevel(toolName: "mac_view", resolved: "auto") == "auto")
    #expect(MacInjectionToolNames.clampedAutonomyLevel(toolName: "mac_click", resolved: "auto") == "auto")
    #expect(MacInjectionToolNames.clampedAutonomyLevel(toolName: "mac_click", resolved: "blocked") == "blocked",
            "the clamp is the identity function — it neither raises nor lowers")
}

/// Unwraps a `JSONValue` error field to a plain string ("" when absent or not
/// a string) so a refusal REASON can be asserted without a pattern match.
private func fvErrorText(_ value: JSONValue?) -> String {
    if case .string(let s)? = value { return s }
    return ""
}

/// The W3.5 claim at the DISPATCHER layer: a mark is a target reference, so
/// `mac_click{mark:…}` is treated exactly like `mac_click{x,y}`. Both forms take
/// the same path and get the same answer — that symmetry is what this row pins.
///
/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated. OLD CONTRACT: a RAW `SwiftToolDispatcher` (constructed
/// directly by tests and several app paths, below any autonomy gate) held no
/// `MacInjectionCapability` and threw `injection_approval_missing` for both
/// forms. NEW CONTRACT: `SwiftToolDispatcher+Sandbox` self-mints a capability
/// for the call, so neither form is refused for want of an approval — they run
/// on into MacControl, where the accessibility category and the macOS TCC grant
/// are the remaining gates.
@Test
func clickByMark_runsOnARawDispatcher_capabilityIsSelfMinted() async throws {
    let root = try fvTempRoot("mark-gate")
    defer { try? FileManager.default.removeItem(at: root) }
    try fvWriteTrustPolicy(root, fvFullMacPolicy(accessibilityAllowed: true))
    let tools = SwiftToolDispatcher(dataRoot: root)

    for input: [String: JSONValue] in [
        ["mark": .int(1), "view": .string("any-view-id")],
        ["x": .int(10), "y": .int(10)],
    ] {
        // Not a throw, and specifically not the retired approval refusal. The
        // envelope may still report an unhappy `ok` — this test process holds
        // no Accessibility TCC grant — which is exactly the gate that remains.
        let result = try await tools.dispatch(tool: "mac_click", input: input, surface: "chat")
        guard case .object(let obj) = result else {
            Issue.record("mac_click returned no object envelope for \(input)"); continue
        }
        #expect(obj["action"] == .string("click"))
        #expect(obj["error"] != .string("unknown_action"))
        #expect(!fvErrorText(obj["error"]).hasPrefix("approval_not_granted"),
                "the approval tier is retired — a refusal here must name a surviving gate, got \(String(describing: obj["error"]))")
    }
    let acted = try await tools.dispatch(
        tool: "mac_ax_act",
        input: ["mark": .int(1), "view": .string("any-view-id")],
        surface: "chat"
    )
    guard case .object(let actObj) = acted else {
        Issue.record("mac_ax_act returned no object envelope"); return
    }
    #expect(actObj["action"] == .string("ax_act"))
    #expect(!fvErrorText(actObj["error"]).hasPrefix("approval_not_granted"))

    // TEETH: the dispatcher still refuses on a surviving gate — turn the
    // accessibility category OFF and the same call is denied.
    let offRoot = try fvTempRoot("mark-gate-off")
    defer { try? FileManager.default.removeItem(at: offRoot) }
    try fvWriteTrustPolicy(offRoot, fvFullMacPolicy(accessibilityAllowed: false))
    let offTools = SwiftToolDispatcher(dataRoot: offRoot)
    await #expect(throws: (any Error).self,
                  "the accessibility category is a surviving gate — mac_click must be denied with it off") {
        _ = try await offTools.dispatch(tool: "mac_click", input: ["x": .int(10), "y": .int(10)], surface: "chat")
    }
    // Contrast, same dispatcher, same policy: the VIEW itself goes through.
    // That pairing is the proof that the refusals above are about the act tier,
    // not about the dispatcher being broken.
    _ = try await tools.dispatch(tool: "mac_view", input: [:], surface: "chat")
}

// MARK: - Catalog wiring integrity

@Test
func macView_isRegisteredAsAReadToolNotAnActTool() {
    #expect(SwiftToolDispatcher.fullMacAccessibilityReadToolNames.contains("mac_view"))
    #expect(!SwiftToolDispatcher.fullMacAccessibilityInjectionToolNames.contains("mac_view"))
    #expect(!SwiftToolDispatcher.fullMacAppToolNames.contains("mac_view"))
    #expect(SwiftToolDispatcher.reservedBuiltInNames.contains("mac_view"),
            "a registry custom tool must not be able to shadow the fused view")
    // Bridge route: gated on macControlDispatchableActions, so a missing entry
    // 404s the HTTP/iOS path.
    #expect(macControlDispatchableActions.contains("view"))
    #expect(!macControlAllActions.contains("view"),
            "view has no retired-daemon ancestor — the parity inventory stays honest")
}

// MARK: - W3.5-FIX 3 — the PICTURE never rides into a persisted/trace preview

/// A tiny but REAL base64 PNG payload: short enough that the 500-char preview
/// cap cannot be what hides it. If the stripper is removed, these exact bytes
/// appear in the trace — which is what makes this test's failure meaningful
/// rather than a length coincidence.
private let fvImageBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

private func fvViewResult() -> JSONValue {
    .object([
        "ok": .bool(true),
        "action": .string("view"),
        "image": .string(fvImageBase64),
        "image_format": .string("png"),
        "image_bytes": .int(Int64(Data(base64Encoded: fvImageBase64)?.count ?? 0)),
        "image_pixel_size": .object(["w": .int(1600), "h": .int(1200)]),
        "view": .string("view-token"),
        "marks": .array([]),
    ])
}

private struct FVStubDispatchClient: ToolDispatchClient {
    let result: JSONValue
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        result
    }
    func listAvailableTools() async throws -> [String] { ["mac_view"] }
}

/// Wait for the first bus event matching `match`, under a hard deadline — an
/// unbounded `for await` here would wedge the whole suite if the event never
/// fires, and "never fires" is exactly one of the outcomes under test.
private func fvAwaitEvent(
    _ subscription: TurnTraceBus.Subscription,
    timeoutMs: Int = 5_000,
    match: @escaping @Sendable (TurnTraceEvent) -> Bool
) async -> TurnTraceEvent? {
    await withTaskGroup(of: TurnTraceEvent?.self) { group in
        group.addTask {
            for await event in subscription.stream where match(event) { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Test
func macView_imageIsStrippedFromTheTraceButNotFromTheLiveResult() async throws {
    let root = try fvTempRoot("trace-image")
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let subscription = await bus.subscribe()
    let tracer = ChatToolDispatchTracer(
        inner: FVStubDispatchClient(result: fvViewResult()),
        dataRoot: root
    )

    let turnId = TurnTraceContext.mintTurnId()
    async let waited = fvAwaitEvent(subscription) { event in
        guard case .object(let payload) = event.payload else { return false }
        return payload["name"] == .string("mac_view") && payload["phase"] == .string("end")
    }
    let live: JSONValue = try await TurnTraceContext.$bus.withValue(bus) {
        try await TurnTraceContext.$turnId.withValue(turnId) {
            try await tracer.dispatch(tool: "mac_view", input: [:], surface: "test")
        }
    }
    let event = try #require(await waited, "no end event reached the bus")
    guard case .object(let payload) = event.payload,
          case .string(let preview)? = payload["result"] else {
        Issue.record("trace payload carried no result preview"); return
    }

    // THE LEAK: the base64 PNG in a persisted/emitted preview.
    #expect(!preview.contains("iVBORw0KGgo"),
            "mac_view's screenshot rode into the turn-trace preview")
    #expect(!preview.contains(fvImageBase64))
    // What replaces it is an audit trail, not a hole.
    #expect(preview.contains("image_redacted"))
    #expect(preview.contains("image_sha256"))
    #expect(preview.contains("image_pixel_size"))

    // AND THE OTHER HALF: the model still gets the picture. Stripping the
    // preview must not have stripped the perception.
    guard case .object(let liveObject) = live else {
        Issue.record("live result is not an object"); return
    }
    #expect(liveObject["image"] == .string(fvImageBase64),
            "the live result must still carry the full image")
}

/// The persisted transcript row (read back by Mac/iOS/Telegram) takes the same
/// treatment, through the serialized-JSON seam that layer actually gets.
@Test
func macView_imageIsStrippedFromThePersistedToolRow() throws {
    let json = try String(
        data: fvViewResult().serializedData(pretty: false), encoding: .utf8
    ) ?? ""
    #expect(json.contains("iVBORw0KGgo"), "positive control: the raw row DOES carry the image")

    let stripped = SwiftNativeChatOrchestrationClient.screenViewRedactedResultJSON(tool: "mac_view", json: json)
    #expect(!stripped.contains("iVBORw0KGgo"))
    #expect(stripped.contains("image_sha256"))
    #expect(stripped.contains("image_redacted"))
    // Every non-image field survives: the row is still a useful receipt.
    #expect(stripped.contains("view-token"))
    #expect(stripped.contains("image_pixel_size"))

    // Idempotent, and scoped to mac_view — a read_file result is not touched.
    #expect(SwiftNativeChatOrchestrationClient.screenViewRedactedResultJSON(tool: "mac_view", json: stripped)
        == stripped)
    #expect(SwiftNativeChatOrchestrationClient.screenViewRedactedResultJSON(tool: "read_file", json: json)
        == json)
    // The MacControl-side names all answer, so a registry/action spelling of
    // the same tool cannot slip past the sink.
    for name in [
        "mac_view", "mac.view", "view", "MAC_VIEW",
        "mac_attention", "mac.attention", "attention", "MAC_ATTENTION",
    ] {
        #expect(MacScreenViewResultRedaction.carriesImage(tool: name), "\(name) must be recognized")
    }
    let attentionStripped = SwiftNativeChatOrchestrationClient.screenViewRedactedResultJSON(
        tool: "mac_attention",
        json: json
    )
    #expect(!attentionStripped.contains("iVBORw0KGgo"))
    #expect(attentionStripped.contains("image_redacted"))
    #expect(!MacScreenViewResultRedaction.carriesImage(tool: "mac_ax_tree"))
}

// MARK: - W3.5-FIX-R2 — the text half, at the tool surface
//
// The image sink above proves the PICTURE is stripped downstream. The text
// channel is redacted upstream instead — at the builder, so no sink can be
// added un-redacted (see MacScreenViewTextRedaction). These pin the two
// properties that must hold where the chat layer can see them: the shape
// redactor is reachable from this module, and the shapes round two found —
// CVV, spaced card numbers, seed phrases, base64 tokens — are dark BEFORE a
// result ever reaches a sink, while ordinary UI text arrives intact.

@Test
func macView_roundTwoSecretShapesAreDarkBeforeAnySinkSeesThem() throws {
    for (text, reason) in [
        ("CVV: 123", "labeled_cvv"),
        ("4111 1111 1111 1111", "card_number_shape"),
        ("ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble oyster",
         "recovery_phrase_shape"),
        ("aGVsbG8+d29ybGQvZm9vPQ==", "high_entropy_token"),
    ] {
        let rendered = MacScreenViewTextRedaction.redactedLegendString(
            text, valueChars: 256
        )
        guard case .object(let object) = rendered else {
            Issue.record("\(text) reached the tool surface as a raw string"); return
        }
        #expect(object["reason"] == .string(reason))
        let json = try String(data: rendered.serializedData(pretty: false), encoding: .utf8) ?? ""
        #expect(!json.contains(text))
    }

    // The load-bearing other half at this layer: the organ still SEES.
    for text in [
        "Send", "Card number", "Order 12345678 shipped", "(555) 123-4567",
        "Your CVV is the three digit code on the back of your card",
        "the quick brown fox jumps over the lazy dog while we all watch",
        "https://example.com/assets/aGVsbG8+d29ybGQvZm9vPQ==",
    ] {
        #expect(MacScreenViewTextRedaction.redactedLegendString(text, valueChars: 256)
            == .string(text), "\(text) must stay legible at the tool surface")
    }
}

/// The later echo, at this layer: `mac_click{mark}` / `mac_ax_act` results ride
/// the SAME trace/persist/sync sinks as `mac_view`, so the element name they
/// echo has to be redacted too — the read tool covering it is not enough.
@Test
func actToolElementEchoIsRedactedByTheSameShapeTest() throws {
    let echoed = MacScreenViewTextRedaction.redactedElementJSON(
        .object([
            "role": .string("AXButton"),
            "label": .string("482913"),
            "path": .array([.int(0)]),
        ])
    )
    let json = try String(data: echoed.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!json.contains("482913"), "an act result must not re-leak the label mac_view redacted")
    #expect(json.contains("otp_shape"))
    #expect(json.contains("AXButton"), "redacted, not deleted — she still knows what she hit")

    let ordinary = JSONValue.object(["role": .string("AXButton"), "label": .string("Send")])
    #expect(MacScreenViewTextRedaction.redactedElementJSON(ordinary) == ordinary)
}
