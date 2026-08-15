import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter
@testable import ApprovalInbox

/// W2/W3-FIX — the four BLOCKING holes an adversarial review found in the first
/// cut of the injection wave, each pinned by a test that FAILS if the hole is
/// reopened.
///
/// The original design carried approval as an in-band JSON key
/// (`__mac_injection_approved`). These tests exist because that is not a
/// boundary: anything that can write a dictionary key can write that one. What
/// replaced it is a `MacInjectionCapability` — private init, no wire form,
/// bound to one action and one body digest, single use, minted at exactly one
/// call site after a resolved human approval.
///
/// HERMETICITY: every dispatcher and trust type gets a temp dataRoot, and the
/// inner dispatcher is a RECORDING FAKE. Nothing here can post a CGEvent; the
/// question every test asks is "did the call reach the inner dispatcher at
/// all", which is the exact moment a real injection would become unstoppable.

// MARK: - Fixtures

private func fenceTempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-inj-fence-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func fenceWriteTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try policy.serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("policy.json"))
}

/// Full Mac active + accessibility on. `toolAutonomy` is the knob under test.
private func fenceFullMacPolicy(
    toolAutonomy: [String: JSONValue] = [:],
    accessibilityAllowed: Bool = true
) -> JSONValue {
    .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "toolAutonomy": .object(toolAutonomy),
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

/// Records every call that got through, AND whether an injection capability was
/// in scope when it did. "Reached inner" is the failure condition for every
/// refusal test in this file: past this point a real dispatcher types.
private actor FenceRecordingDispatcher: ToolDispatchClient {
    struct Call: Sendable {
        let tool: String
        let input: [String: JSONValue]
        let hadCapability: Bool
        let capabilityApprovalID: String?
    }

    private var _calls: [Call] = []
    func calls() -> [Call] { _calls }

    nonisolated func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let capability = MacInjectionCapabilityContext.current
        await record(Call(
            tool: tool,
            input: input,
            hadCapability: capability != nil,
            capabilityApprovalID: capability?.approvalID
        ))
        return .object(["reached_inner": .bool(true), "tool": .string(tool)])
    }

    private func record(_ call: Call) { _calls.append(call) }

    nonisolated func listAvailableTools() async throws -> [String] {
        Array(MacInjectionToolNames.all)
    }
}

private struct FenceResolver: AutonomyResolver {
    let level: String
    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String { level }
}

/// Non-blocking filer that captures exactly what got PERSISTED, so the
/// redaction tests can grep the serialized record rather than trusting a field.
private actor FenceCapturingFiler: NonBlockingApprovalFiler {
    private var _filed: [(toolName: String, payload: JSONValue)] = []
    let approvalID: String

    init(approvalID: String = "fence-approval-1") { self.approvalID = approvalID }

    func filed() -> [(toolName: String, payload: JSONValue)] { _filed }

    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        _filed.append((toolName, payload))
        return approvalID
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision { .approved }

    func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async -> JSONValue {
        .object(["status": .string("waiting_approval"), "approvalId": .string(id)])
    }
}

/// W2/W3-FIX-R2 1 — the filer the production Mac chat path actually uses: it
/// writes a REAL record into the canonical inbox on this data root and resolves
/// it there when the "human" approves. Every fence dispatcher below is wired to
/// a verifier reading that same root, so an approval id only authorizes
/// anything when a record for it genuinely exists.
private actor FenceInboxApprovingFiler: ApprovalFiler {
    let dataRoot: URL
    private var _filed: [(toolName: String, payload: JSONValue)] = []
    private var _approvalIDs: [String] = []
    /// When false the record is staged but never resolved — the "a filer that
    /// merely CLAIMS approval" case.
    private let resolvesIt: Bool

    init(dataRoot: URL, resolvesIt: Bool = true) {
        self.dataRoot = dataRoot
        self.resolvesIt = resolvesIt
    }

    func filed() -> [(toolName: String, payload: JSONValue)] { _filed }
    func approvalIDs() -> [String] { _approvalIDs }

    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        _filed.append((toolName, payload))
        let id = try await fenceStageRecord(
            root: dataRoot, tool: toolName, surface: surface, payload: payload, reason: reason
        )
        _approvalIDs.append(id)
        return id
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision {
        if resolvesIt {
            _ = try await SwiftNativeApprovalInbox(root: dataRoot)
                .resolve(id, decision: .approved, decidedBy: "fence-human")
        }
        return .approved
    }
}

/// Stage one chat_tool_approval record, shaped exactly like
/// `NativeAgentChatApprovalFiler` writes it.
@discardableResult
private func fenceStageRecord(
    root: URL,
    tool: String,
    surface: String,
    payload: JSONValue,
    reason: String = "fence"
) async throws -> String {
    let record = try await SwiftNativeApprovalInbox(root: root).create(.object([
        "title": .string("Approve \(tool)"),
        "action": .string(tool),
        "risk": .string("confirm"),
        "reason": .string(reason),
        "payload": .object([
            "kind": .string("chat_tool_approval"),
            "toolName": .string(tool),
            "surface": .string(surface),
            "input": payload,
        ]),
        "remoteResolvable": .bool(true),
        "localOnly": .bool(false),
    ]))
    return record.id
}

/// Stage + resolve-approved in one step, for the replay tests. `input` is the
/// RAW call; the record stores the redacted form, exactly like production.
private func fenceApprovedRecordID(
    root: URL,
    tool: String,
    surface: String = "chat",
    input: [String: JSONValue]
) async throws -> String {
    let id = try await fenceStageRecord(
        root: root,
        tool: tool,
        surface: surface,
        payload: .object(MacInjectionArgRedaction.redacted(tool: tool, input: input))
    )
    _ = try await SwiftNativeApprovalInbox(root: root)
        .resolve(id, decision: .approved, decidedBy: "fence-human")
    return id
}

private func fenceDispatcher(
    inner: FenceRecordingDispatcher,
    root: URL,
    level: String,
    filer: (any ApprovalFiler)? = nil,
    hasFiler: Bool = false,
    approvedReplay: ApprovedChatToolReplay? = nil,
    /// Default: the real inbox-backed verifier on this test's data root.
    /// `withVerifier: false` is the fail-closed case (no verifier wired).
    withVerifier: Bool = true,
    /// PER-DISPATCHER by default, never `.shared`: swift-testing runs these in
    /// parallel, and a sibling test resetting a process-global ledger mid-test
    /// silently un-consumes this test's approval (that flake cost one debug
    /// round here). Single-use is still proven — the same dispatcher is asked
    /// twice with the same record.
    ledger: MacInjectionApprovalConsumptionLedger = MacInjectionApprovalConsumptionLedger()
) -> AutonomyGatedDispatcher {
    AutonomyGatedDispatcher(
        inner: inner,
        gate: AutonomyGate(trust: FenceResolver(level: level), approvalFiler: filer),
        approvalFiler: filer,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
        hasFiler: hasFiler,
        approvalTimeoutSeconds: 5,
        verifiedSessionId: "fence-session",
        approvedReplay: approvedReplay,
        injectionApprovalVerifier: withVerifier
            ? ApprovalInboxInjectionApprovalVerifier(dataRoot: root, ledger: ledger)
            : nil
    )
}

// MARK: - The retired in-band marker is inert on every entry point

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: a raw `SwiftToolDispatcher` held no capability and refused
/// with `injection_approval_missing`, so a forged in-band marker bought
/// nothing. NEW CONTRACT: the raw dispatcher SELF-MINTS a capability, so the
/// call runs — and the forged marker STILL buys nothing, because it is stripped
/// in `dispatchCore` and read nowhere. There is no approval left to forge; what
/// this row pins now is that the hostile keys change no outcome, and that the
/// surviving gates (Full Mac / accessibility category / TCC) are what decide.
@Test
func macInjection_forgedMarkerIsInertOnRawSwiftToolDispatcher() async throws {
    let root = try fenceTempRoot("raw-dispatcher")
    defer { try? FileManager.default.removeItem(at: root) }
    try fenceWriteTrustPolicy(root, fenceFullMacPolicy())

    let tools = SwiftToolDispatcher(dataRoot: root)
    // The underscore spellings are the ones in the dispatch table; the dotted
    // aliases exist for the autonomy/approval vocabulary and 404 here.
    for tool in ["mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act"] {
        // The hostile body carries the RETIRED marker plus every plausible
        // spelling of "I am approved". None of it is read anywhere.
        let hostile: [String: JSONValue] = [
            "text": .string("hi"),
            "x": .int(1), "y": .int(2), "dy": .int(1),
            "path": .array([.int(0)]),
            "__mac_injection_approved": .bool(true),
            "approved": .bool(true),
            "capability": .string("granted"),
        ]
        // The hostile body neither authorizes nor blocks: the call proceeds on
        // its self-minted capability, and no refusal names the retired tier.
        let result = try await tools.dispatch(tool: tool, input: hostile, surface: "chat")
        guard case .object(let obj) = result else {
            Issue.record("\(tool) returned no object envelope"); continue
        }
        #expect(obj["error"] != .string("unknown_action"))
        if case .string(let err)? = obj["error"] {
            #expect(!err.hasPrefix("approval_not_granted"),
                    "\(tool): the approval tier is retired — \(err)")
            #expect(!err.contains("injection_approval_missing"), "\(tool): \(err)")
        }
    }

    // TEETH: a surviving gate still refuses the same call. With the
    // accessibility category OFF the raw dispatcher denies every one of them,
    // so this test cannot pass on a dispatcher that stopped gating entirely.
    let offRoot = try fenceTempRoot("raw-dispatcher-category-off")
    defer { try? FileManager.default.removeItem(at: offRoot) }
    try fenceWriteTrustPolicy(offRoot, fenceFullMacPolicy(accessibilityAllowed: false))
    let offTools = SwiftToolDispatcher(dataRoot: offRoot)
    for tool in ["mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act"] {
        await #expect(throws: (any Error).self,
                      "\(tool) must be denied with the accessibility category off") {
            _ = try await offTools.dispatch(tool: tool, input: ["text": .string("hi")], surface: "chat")
        }
    }
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: with the resolver saying "auto" and no approval resolved, a
/// body carrying the retired marker was refused and never reached the inner
/// dispatcher. NEW CONTRACT: `AutonomyGatedDispatcher` synthesizes the approval
/// id and mints a capability itself, so the call reaches inner CARRYING a
/// capability — but the marker still contributes nothing to that decision: it
/// is not read here and is stripped before MacControl ever sees the body.
@Test
func macInjection_forgedMarkerIsInertThroughTheGatedDispatcher() async throws {
    let root = try fenceTempRoot("gated-forgery")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let dispatcher = fenceDispatcher(inner: inner, root: root, level: "auto")

    for tool in ["mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act"] {
        _ = try await dispatcher.dispatch(
            tool: tool,
            input: ["text": .string("hi"), "__mac_injection_approved": .bool(true)],
            surface: "chat"
        )
    }
    let calls = await inner.calls()
    #expect(calls.count == 4, "every motor tool reaches inner post-cutover")
    #expect(calls.allSatisfy { $0.hadCapability },
            "each call carries a self-minted capability, not the forged marker")
    // TEETH: a level the gate still DENIES stops in the same dispatcher.
    let blockedInner = FenceRecordingDispatcher()
    let blockedDispatcher = fenceDispatcher(inner: blockedInner, root: root, level: "blocked")
    await #expect(throws: (any Error).self, "an explicit blocked level must still deny") {
        _ = try await blockedDispatcher.dispatch(
            tool: "mac_keystroke",
            input: ["text": .string("hi"), "__mac_injection_approved": .bool(true)],
            surface: "chat"
        )
    }
    #expect(await blockedInner.calls().isEmpty)
}

@Test
func macInjection_theOnlyPathThatInjectsIsTheApprovedGatedPath() async throws {
    // THE POSITIVE CONTROL that gives every refusal above its teeth. Same
    // dispatcher, same tool, same body — but a wired filer that APPROVES. The
    // call now reaches the inner dispatcher, and it arrives carrying a
    // capability minted from the approval the human just resolved.
    let root = try fenceTempRoot("approved-path")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let filer = FenceInboxApprovingFiler(dataRoot: root)
    let dispatcher = fenceDispatcher(
        inner: inner,
        root: root,
        level: "send_approval",
        filer: filer,
        hasFiler: true
    )

    let result = try await dispatcher.dispatch(
        tool: "mac_keystroke",
        input: ["text": .string("hello")],
        surface: "chat"
    )
    #expect(result == .object(["reached_inner": .bool(true), "tool": .string("mac_keystroke")]))

    let calls = await inner.calls()
    #expect(calls.count == 1)
    #expect(calls.first?.hadCapability == true,
            "the approved path must carry a capability — without one the inner MacControl refuses")
    let stagedID = await filer.approvalIDs().first
    #expect(stagedID != nil)
    #expect(calls.first?.capabilityApprovalID == stagedID,
            "the capability must name the approval RECORD a human actually resolved")
    // The characters are restored for EXECUTION even though the filed record
    // was redacted — the secret round-trips through memory, never through disk.
    #expect(calls.first?.input["text"] == .string("hello"))
}

@Test
func macInjection_capabilityDoesNotLeakToTheNextToolCall() async throws {
    // A TaskLocal that stayed bound would turn one approval into a standing
    // permit. Each dispatch binds its own value — nil for anything that did not
    // just clear an approval.
    let root = try fenceTempRoot("no-leak")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let filer = FenceInboxApprovingFiler(dataRoot: root)
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "send_approval", filer: filer, hasFiler: true
    )
    _ = try await dispatcher.dispatch(
        tool: "mac_keystroke", input: ["text": .string("a")], surface: "chat"
    )

    let autoDispatcher = fenceDispatcher(inner: inner, root: root, level: "auto")
    _ = try await autoDispatcher.dispatch(
        tool: "mac_ax_tree", input: [:], surface: "chat"
    )
    let calls = await inner.calls()
    #expect(calls.count == 2)
    #expect(calls[1].hadCapability == false,
            "a later, non-injection tool must not inherit the injection capability")
}

/// Blocking filer that approves immediately, standing in for a human tapping
/// Approve. Returns a stable approval id so the capability binding is checkable.
private actor FenceApprovingFiler: ApprovalFiler {
    let approvalID: String
    private var _filed: [(toolName: String, payload: JSONValue)] = []
    init(approvalID: String) { self.approvalID = approvalID }
    func filed() -> [(toolName: String, payload: JSONValue)] { _filed }

    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        _filed.append((toolName, payload))
        return approvalID
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision { .approved }
}

// MARK: - FIX 3: the hard approval floor is RETIRED

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: a saved `toolAutonomy` entry — exact, dotted, glob, or a
/// permissive `default` — could not promote the injection family below
/// `send_approval`, because a post-resolution clamp re-floored every result.
/// NEW CONTRACT: the clamp is the identity function, so a permissive override
/// resolves exactly as written and the family runs unattended. Override data
/// can still make these tools STRICTER (see
/// `macInjection_overrideCanStillMakeInjectionStricter`), which is the one half
/// of this contract that survived.
@Test
func macInjection_savedAutonomyOverridePromotesToAuto_floorRetired() async throws {
    let overrides: [[String: JSONValue]] = [
        // exact, canonical spelling
        ["mac_keystroke": .string("auto"), "mac_click": .string("auto"),
         "mac_scroll": .string("auto"), "mac_ax_act": .string("auto")],
        // exact, dotted spelling
        ["mac.keystroke": .string("auto"), "mac.click": .string("auto"),
         "mac.scroll": .string("auto"), "mac.ax_act": .string("auto")],
        // glob
        ["mac_*": .string("auto")],
        // the other unattended levels, not just "auto"
        ["mac_keystroke": .string("workspace_autonomous"),
         "mac_click": .string("app_data_autonomous"),
         "mac_scroll": .string("workspace_autonomous"),
         "mac_ax_act": .string("app_data_autonomous")],
        // a permissive default with no per-tool entry at all
        ["default": .string("auto")],
    ]

    for (index, override) in overrides.enumerated() {
        let root = try fenceTempRoot("floor-\(index)")
        defer { try? FileManager.default.removeItem(at: root) }
        try fenceWriteTrustPolicy(root, fenceFullMacPolicy(toolAutonomy: override))
        let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))

        for tool in ["mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act"] {
            let level = try await gate.autonomyLevel(
                toolName: tool, surface: "chat", originTrusted: true
            )
            #expect(MacInjectionToolNames.unattendedAutonomyLevels.contains(level),
                    "override #\(index) resolves \(tool) unattended post-cutover (got \(level))")
            #expect(AutonomyGate.map(level: level) == .allow,
                    "override #\(index): \(tool) maps to allow post-cutover")
        }

        // TEETH: the same override DOES promote a non-injection Mac tool. If
        // this test could pass by clamping everything, this assertion fails.
        if index == 2 {
            let readLevel = try await gate.autonomyLevel(
                toolName: "mac_ax_tree", surface: "chat", originTrusted: true
            )
            #expect(readLevel == "auto",
                    "the mac_* glob must still promote the READ tools — the floor is injection-only")
        }
    }
}

@Test
func macInjection_overrideCanStillMakeInjectionStricter() async throws {
    // The floor is a MINIMUM, not a pin. A user who wants these blocked
    // outright must still be able to say so.
    let root = try fenceTempRoot("floor-stricter")
    defer { try? FileManager.default.removeItem(at: root) }
    try fenceWriteTrustPolicy(root, fenceFullMacPolicy(
        toolAutonomy: ["mac_keystroke": .string("blocked")]
    ))
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))
    let level = try await gate.autonomyLevel(toolName: "mac_keystroke", surface: "chat", originTrusted: true)
    #expect(level == "blocked", "an explicit block must outrank the floor, got \(level)")
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: the dispatcher re-applied the approval floor itself, so even a
/// resolver that returned "auto" was clamped into the approval path — the call
/// came back `waiting_approval`, nothing executed, and one approval was filed.
/// NEW CONTRACT: there is no floor to re-apply. An "auto" resolver goes
/// straight through to the inner dispatcher, and NO approval is filed even
/// though a filer is wired — which is the property that makes the motor tools
/// usable on non-interactive surfaces.
@Test
func macInjection_resolverAutoGoesStraightThrough_noApprovalFiled() async throws {
    let root = try fenceTempRoot("floor-resolver")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let filer = FenceCapturingFiler()
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "auto", filer: filer, hasFiler: true
    )

    _ = try await dispatcher.dispatch(
        tool: "mac_keystroke", input: ["text": .string("hi")], surface: "chat"
    )
    let calls = await inner.calls()
    #expect(calls.count == 1, "an 'auto' resolver dispatches straight to inner")
    #expect(calls.first?.tool == "mac_keystroke")
    #expect(calls.first?.hadCapability == true, "it arrives carrying a self-minted capability")
    #expect(await filer.filed().isEmpty, "no approval may be filed when nothing is gated")

    // TEETH: the wired filer is not dead — a level the gate maps to
    // requireApproval on the SAME dispatcher shape does file one.
    let confirmInner = FenceRecordingDispatcher()
    let confirmFiler = FenceCapturingFiler()
    let confirmDispatcher = fenceDispatcher(
        inner: confirmInner, root: root, level: "confirm", filer: confirmFiler, hasFiler: true
    )
    _ = try? await confirmDispatcher.dispatch(
        tool: "mac_keystroke", input: ["text": .string("hi")], surface: "chat"
    )
    #expect(await confirmFiler.filed().count == 1,
            "a confirm level still files — the filer wiring is live")
}

@Test
func macInjection_areNotApprovalStagingTools() {
    // The staging shortcut in AutonomyGatedDispatcher dispatches WITHOUT an
    // approval (those tools only persist a replay request). If an injection
    // tool were ever added to that set it would become a bypass, so pin the
    // disjointness rather than relying on nobody doing it.
    for tool in MacInjectionToolNames.all {
        #expect(!AutonomyGatedDispatcher.approvalStagingToolNamesForTesting.contains(tool.lowercased()),
                "\(tool) must never be an approval-staging tool")
    }
}

// MARK: - FIX 4: the typed characters never reach a persisted or emitted record

@Test
func macInjection_typedTextIsRedactedFromEveryPersistedAndEmittedRecord() async throws {
    // BLOCKING 4. `mac_keystroke.text` is the literal characters — a password,
    // a 2FA code, a private message. The MacControl RESULT already reduced it
    // to a count, but the approval record and the TurnTrace bus stored the raw
    // string, and the approval record is `remoteResolvable`: it syncs to iOS
    // and is echoed into a Telegram prompt.
    let secret = "hunter2"
    let root = try fenceTempRoot("redaction")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let filer = FenceCapturingFiler(approvalID: "redaction-approval")
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "send_approval", filer: filer, hasFiler: true
    )

    _ = try await dispatcher.dispatch(
        tool: "mac_keystroke",
        input: ["text": .string(secret)],
        surface: "chat"
    )

    // SINK 1 — the approval record, serialized exactly as it is persisted.
    let filed = await filer.filed()
    #expect(filed.count == 1)
    let serializedApproval = String(
        data: try JSONValue.object([
            "kind": .string("chat_tool_approval"),
            "toolName": .string(filed[0].toolName),
            "input": filed[0].payload,
        ]).serializedData(pretty: false),
        encoding: .utf8
    ) ?? ""
    #expect(!serializedApproval.contains(secret),
            "the approval record must not carry the typed characters: \(serializedApproval)")
    #expect(serializedApproval.contains("text_character_count"),
            "the card needs something to show — 'type 7 characters'")
    #expect(serializedApproval.contains("\"text_character_count\": 7"))
    #expect(serializedApproval.contains("text_sha256"),
            "the digest lets a reviewer confirm afterwards that what ran is what was approved")

    // SINK 2 — the TurnTrace bus args. Truncation is not redaction: "hunter2"
    // is seven characters, far under the 500-char preview cap, so it used to
    // ride onto the bus intact.
    let traceArgs = MacInjectionArgRedaction.redacted(
        tool: "mac_keystroke", input: ["text": .string(secret)]
    )
    let serializedTrace = String(
        data: try JSONValue.object(traceArgs).serializedData(pretty: false),
        encoding: .utf8
    ) ?? ""
    #expect(!serializedTrace.contains(secret), "trace args must not carry the typed characters")
    #expect(serializedTrace.contains("text_character_count"))

    // SINK 3 — the MacControl operation store. It is digest-only by design;
    // pin that, because a future "store the body for debugging" change would
    // silently reopen this.
    let digest = try MacControlOperationStore.requestDigest(
        action: "keystroke", body: ["text": .string(secret)]
    )
    #expect(!digest.contains(secret))
    #expect(digest.count == 64, "a SHA-256 hex digest, not a payload")

    // Nothing executed: a non-blocking filer stages the approval and returns.
    // The secret is in the vault, not on disk and not in the record.
    #expect(await inner.calls().isEmpty, "nothing runs before the human decides")

    // SINK 4 — and when it DOES execute (blocking filer, human approves), the
    // real characters reach the executor while the filed record stays redacted.
    // This is the assertion that stops "redaction" from being implemented as
    // "throw the text away".
    let execRoot = try fenceTempRoot("redaction-exec")
    defer { try? FileManager.default.removeItem(at: execRoot) }
    let execInner = FenceRecordingDispatcher()
    let approving = FenceInboxApprovingFiler(dataRoot: execRoot)
    let execDispatcher = fenceDispatcher(
        inner: execInner, root: execRoot, level: "send_approval",
        filer: approving, hasFiler: true
    )
    _ = try await execDispatcher.dispatch(
        tool: "mac_keystroke", input: ["text": .string(secret)], surface: "chat"
    )
    let execCalls = await execInner.calls()
    #expect(execCalls.count == 1)
    #expect(execCalls[0].input["text"] == .string(secret),
            "EXECUTION still gets the real characters — they travel in memory only")
    let execFiled = await approving.filed()
    let serializedExecApproval = String(
        data: try JSONValue.object(["input": execFiled[0].payload]).serializedData(pretty: false),
        encoding: .utf8
    ) ?? ""
    #expect(!serializedExecApproval.contains(secret),
            "the record filed on the executing path must be redacted too: \(serializedExecApproval)")
}

@Test
func macInjection_axActValueIsAlsoRedacted() {
    // `ax_act` with AXSetValue writes a string into a field. That field can be
    // a password box. Same treatment as keystroke.text.
    let redacted = MacInjectionArgRedaction.redacted(
        tool: "mac_ax_act",
        input: ["path": .array([.int(0)]), "action": .string("AXSetValue"),
                "value": .string("hunter2")]
    )
    #expect(redacted["value"] == nil)
    #expect(redacted["value_character_count"] == .int(7))
    #expect(redacted["path"] == .array([.int(0)]), "non-secret args pass through untouched")
    #expect(redacted["action"] == .string("AXSetValue"))
}

@Test
func macInjection_redactionIsIdempotentAndReversibleOnlyWithTheSecret() {
    let original: [String: JSONValue] = ["text": .string("hunter2")]
    let once = MacInjectionArgRedaction.redacted(tool: "mac_keystroke", input: original)
    let twice = MacInjectionArgRedaction.redacted(tool: "mac_keystroke", input: once)
    #expect(once == twice, "every sink redacts for itself; doing it twice must be harmless")
    #expect(MacInjectionArgRedaction.isRedacted(tool: "mac_keystroke", input: once))

    let secrets = MacInjectionArgRedaction.extractSecrets(tool: "mac_keystroke", input: original)
    let restored = MacInjectionArgRedaction.rehydrated(
        tool: "mac_keystroke", input: once, secrets: secrets
    )
    #expect(restored == original, "rehydration must reproduce the approved call exactly")
    #expect(!MacInjectionArgRedaction.isRedacted(tool: "mac_keystroke", input: restored))
}

@Test
func macInjection_replayWithoutTheHeldSecretRefusesRatherThanTypingAPlaceholder() async throws {
    // The vault is in-memory on purpose: a plaintext password on disk is worse
    // than a lost replay. If the app restarted between filing and approval, the
    // replay must REFUSE — typing "" or a digest into whatever is frontmost
    // would be its own incident.
    let root = try fenceTempRoot("vault-miss")
    defer { try? FileManager.default.removeItem(at: root) }

    let inner = FenceRecordingDispatcher()
    let redactedInput = MacInjectionArgRedaction.redacted(
        tool: "mac_keystroke", input: ["text": .string("hunter2")]
    )
    // The record is REAL and approved — this test is about the vault, so the
    // R2-1 verification must pass and the refusal must come from the missing
    // secret, not from unverified evidence.
    let recordID = try await fenceApprovedRecordID(
        root: root, tool: "mac_keystroke", input: ["text": .string("hunter2")]
    )
    let replay = ApprovedChatToolReplay(
        approvalID: recordID,
        tool: "mac_keystroke",
        surface: "chat",
        input: redactedInput,
        verifiedSessionID: "fence-session",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "auto", approvedReplay: replay
    )

    do {
        _ = try await dispatcher.dispatch(
            tool: "mac_keystroke", input: redactedInput, surface: "chat"
        )
        Issue.record("a replay with no held secret must refuse")
    } catch let error as AutonomyGateError {
        #expect("\(error)".contains("injection_secret_unavailable"), "\(error)")
    }
    #expect(await inner.calls().isEmpty)
}

@Test
func macInjection_approvedReplayRehydratesAndInjectsExactlyOnce() async throws {
    // The exemption the floor allows: the EXACT post-approval replay. It is not
    // an autonomy override — it is the second half of one approved call.
    let root = try fenceTempRoot("replay-ok")
    defer { try? FileManager.default.removeItem(at: root) }
    let recordID = try await fenceApprovedRecordID(
        root: root, tool: "mac_keystroke", input: ["text": .string("hunter2")]
    )
    await MacInjectionSecretVault.shared.store(
        approvalID: recordID, secrets: ["text": "hunter2"]
    )

    let inner = FenceRecordingDispatcher()
    let redactedInput = MacInjectionArgRedaction.redacted(
        tool: "mac_keystroke", input: ["text": .string("hunter2")]
    )
    let replay = ApprovedChatToolReplay(
        approvalID: recordID,
        tool: "mac_keystroke",
        surface: "chat",
        input: redactedInput,
        verifiedSessionID: "fence-session",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "auto", approvedReplay: replay
    )

    _ = try await dispatcher.dispatch(
        tool: "mac_keystroke", input: redactedInput, surface: "chat"
    )
    let calls = await inner.calls()
    #expect(calls.count == 1)
    #expect(calls[0].hadCapability == true)
    #expect(calls[0].capabilityApprovalID == recordID)
    #expect(calls[0].input["text"] == .string("hunter2"),
            "the approved characters are restored from memory for execution")

    // Single use, now at the APPROVAL RECORD level (W2/W3-FIX-R2 1) — the same
    // resolved record cannot mint a second capability, so the second attempt
    // never even reaches the vault.
    do {
        _ = try await dispatcher.dispatch(
            tool: "mac_keystroke", input: redactedInput, surface: "chat"
        )
        Issue.record("a replayed approval must not inject twice")
    } catch let error as AutonomyGateError {
        #expect("\(error)".contains("approval_already_consumed"), "\(error)")
    }
    #expect(await inner.calls().count == 1, "the second replay must not reach the inner dispatcher")
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: the replay exemption was keyed on tool + surface + EXACT input
/// + verified origin, and a record matching only the NAME could not exempt a
/// different call — the mismatched call fell back onto the approval floor and
/// was refused. NEW CONTRACT: there is no floor to fall back onto, so a
/// mismatched replay simply does not apply and the call proceeds on its own
/// self-minted capability. The MATCHING half of the exemption is unchanged and
/// still pinned in
/// `macInjection_typedTextIsRedactedFromEveryPersistedAndEmittedRecord`
/// (single-use consumption of the approval record included).
@Test
func macInjection_aMismatchedReplayNoLongerBlocks_thereIsNoFloor() async throws {
    let root = try fenceTempRoot("replay-mismatch")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let replay = ApprovedChatToolReplay(
        approvalID: "approved-something-else",
        tool: "mac_keystroke",
        surface: "chat",
        input: ["text": .string("innocent")],
        verifiedSessionID: "fence-session",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "auto", approvedReplay: replay
    )

    _ = try await dispatcher.dispatch(
        tool: "mac_keystroke",
        input: ["text": .string("rm -rf /")],
        surface: "chat"
    )
    let calls = await inner.calls()
    #expect(calls.count == 1, "the mismatched replay does not apply, and nothing blocks the call")
    #expect(calls.first?.input["text"] == .string("rm -rf /"),
            "the call carries its OWN text — the replay's 'innocent' body was not substituted")
    #expect(calls.first?.capabilityApprovalID != "approved-something-else",
            "the mismatched approval record must not be the one the capability is bound to")
}

// MARK: - Source conformance: the mint sites stay an enumerated set

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: exactly ONE non-test source file could mint an injection
/// capability — the post-approval branch of `AutonomyGatedDispatcher` — because
/// minting was supposed to follow a resolved human approval.
/// NEW CONTRACT: three files mint, and all three self-mint without an approval:
/// the gated dispatcher, the raw `SwiftToolDispatcher` sandbox path, and
/// `SwiftNativeMacControl`'s own entry point. This row keeps its teeth as DRIFT
/// DETECTION rather than as a fence: the set is enumerated exactly, so a FOURTH
/// site — or a mint appearing in a module that has no business injecting — is
/// still a red row someone has to look at.
@Test
func macInjectionCapability_mintSitesAreTheThreeKnownSelfMintPaths() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ChatOrchestrationTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // NativeAgentCore
        .deletingLastPathComponent()  // Modules
        .deletingLastPathComponent()  // repo root
    let searchRoots = [
        repoRoot.appendingPathComponent("Modules/NativeAgentCore/Sources"),
        repoRoot.appendingPathComponent("Sources"),
    ]

    var mintSites: [String] = []
    for searchRoot in searchRoots {
        guard let walker = FileManager.default.enumerator(
            at: searchRoot, includingPropertiesForKeys: nil
        ) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains("MacInjectionCapability.mint(") else { continue }
            mintSites.append(url.lastPathComponent)
        }
    }

    #expect(Set(mintSites) == [
        "ChatOrchestrationClient+DispatchWrappers.swift",  // gated dispatcher
        "SwiftToolDispatcher+Sandbox.swift",               // raw dispatcher self-mint
        "MacControl+Client.swift",                         // entry-point self-mint
    ], "the mint sites must stay exactly the three known self-mint paths, found: \(mintSites.sorted())")
}

@Test
func macInjection_retiredMarkerHasNoReadersLeftInSource() throws {
    // The old in-band key must not be READ anywhere. It may still appear in a
    // comment or a defensive strip, but no code may branch on it.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let searchRoots = [
        repoRoot.appendingPathComponent("Modules/NativeAgentCore/Sources"),
        repoRoot.appendingPathComponent("Sources"),
    ]
    var offenders: [String] = []
    for searchRoot in searchRoots {
        guard let walker = FileManager.default.enumerator(
            at: searchRoot, includingPropertiesForKeys: nil
        ) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("__mac_injection_approved") else { continue }
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                // The one permitted use: defensively DELETING it.
                if trimmed.contains("removeValue(forKey:") { continue }
                offenders.append("\(url.lastPathComponent): \(trimmed)")
            }
        }
    }
    #expect(offenders.isEmpty,
            "no code may read the retired in-band marker: \(offenders)")
}

// MARK: - The reader stays injection-free

@Test
func macAccessibilityReader_remainsFreeOfEveryInjectionSymbol() throws {
    // W1's structural guarantee, re-asserted against the NEW vocabulary: the
    // perception organ must contain no event-posting or capability symbol at
    // all. The actuator is the positive control — if this grep could pass on an
    // organ that DOES inject, the second half of this test fails.
    let macControl = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Modules/NativeAgentCore/Sources/MacControl")
    let reader = try String(
        contentsOf: macControl.appendingPathComponent("MacAccessibilityReader.swift"),
        encoding: .utf8
    )
    let actuator = try String(
        contentsOf: macControl.appendingPathComponent("MacAccessibilityActuator.swift"),
        encoding: .utf8
    )
    // Comment lines are excluded on purpose: the reader's header DOCUMENTS the
    // absence of these symbols ("there is deliberately NO CGEvent, no
    // AXUIElementPerformAction..."), and that documentation is not a call site.
    // The grep is over CODE.
    let readerCode = reader
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    for symbol in ["CGEventPost", "AXUIElementPerformAction", "AXUIElementSetAttributeValue",
                   "MacInjectionCapability", "MacEventSink"] {
        #expect(!readerCode.contains(symbol),
                "the reader must stay injection-free — found \(symbol)")
    }
    #expect(actuator.contains("MacInjectionCapability"),
            "positive control: the ACT organ is where these symbols live")
}

// MARK: - W2/W3-FIX-R2 1: replay evidence is CHECKED against a real record

@Test
func macInjectionR2_forgedReplayEvidenceWithAMadeUpApprovalIDIsRefused() async throws {
    // BLOCKING R2-1. `ApprovedChatToolReplay` is a public value type with a
    // public init, and `makeGatedToolDispatchClient` publicly accepts one. The
    // first cut's exemption test was: nonempty approvalID + the caller's own
    // fields equal the caller's own call. So an in-process caller could WRITE
    // its own approval evidence, take the single floor exemption, and have that
    // unverified string minted straight into a capability. The evidence is now
    // resolved against the inbox before either step.
    let root = try fenceTempRoot("forged-replay")
    defer { try? FileManager.default.removeItem(at: root) }

    let inner = FenceRecordingDispatcher()
    let input: [String: JSONValue] = ["text": .string("rm -rf /")]
    let forged = ApprovedChatToolReplay(
        approvalID: "totally-made-up-approval-id",
        tool: "mac_keystroke",
        surface: "chat",
        input: input,
        verifiedSessionID: "fence-session",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    // The resolver ALSO lies ("auto"), so nothing but the verification stands
    // between this call and the inner dispatcher.
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "auto", approvedReplay: forged
    )

    do {
        _ = try await dispatcher.dispatch(tool: "mac_keystroke", input: input, surface: "chat")
        Issue.record("forged replay evidence must not dispatch")
    } catch let error as AutonomyGateError {
        #expect("\(error)".contains("injection_replay_evidence_unverified"), "\(error)")
        #expect("\(error)".contains("approval_record_not_found"), "\(error)")
    }
    #expect(await inner.calls().isEmpty,
            "a forged approval id must neither exempt the floor nor mint a capability")
}

@Test
func macInjectionR2_everyDefectiveApprovalRecordShapeIsRefused() async throws {
    // The verification is not an existence check: the record must be RESOLVED and
    // APPROVED, for THIS tool, THIS surface, THIS body, and unspent. One case
    // per failure mode, each flipping exactly one field of a known-good record.
    let raw: [String: JSONValue] = ["text": .string("hunter2")]
    let redactedInput = MacInjectionArgRedaction.redacted(tool: "mac_keystroke", input: raw)

    // (a) staged but never resolved — a filer that merely CLAIMS approval.
    do {
        let root = try fenceTempRoot("defect-pending")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await fenceStageRecord(
            root: root, tool: "mac_keystroke", surface: "chat", payload: .object(redactedInput)
        )
        try await fenceExpectReplayRefusal(
            root: root, approvalID: id, tool: "mac_keystroke",
            input: redactedInput, expect: "approval_not_resolved_approved"
        )
    }

    // (b) resolved as DENIED.
    do {
        let root = try fenceTempRoot("defect-denied")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await fenceStageRecord(
            root: root, tool: "mac_keystroke", surface: "chat", payload: .object(redactedInput)
        )
        _ = try await SwiftNativeApprovalInbox(root: root)
            .resolve(id, decision: .denied, decidedBy: "fence-human")
        try await fenceExpectReplayRefusal(
            root: root, approvalID: id, tool: "mac_keystroke",
            input: redactedInput, expect: "approval_not_resolved_approved"
        )
    }

    // (c) an approval for a DIFFERENT tool — the classic privilege swap: get a
    //     harmless approval, replay it as a keystroke.
    do {
        let root = try fenceTempRoot("defect-tool")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await fenceApprovedRecordID(
            root: root, tool: "mac_ax_tree", input: [:]
        )
        try await fenceExpectReplayRefusal(
            root: root, approvalID: id, tool: "mac_keystroke",
            input: redactedInput, expect: "approval_is_for_a_different_tool"
        )
    }

    // (d) an approval for a DIFFERENT body — approved "hi", replayed "hunter2".
    do {
        let root = try fenceTempRoot("defect-body")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await fenceApprovedRecordID(
            root: root, tool: "mac_keystroke", input: ["text": .string("hi")]
        )
        try await fenceExpectReplayRefusal(
            root: root, approvalID: id, tool: "mac_keystroke",
            input: redactedInput, expect: "approval_is_for_a_different_body"
        )
    }

    // (e) an approval for a DIFFERENT surface.
    do {
        let root = try fenceTempRoot("defect-surface")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await fenceApprovedRecordID(
            root: root, tool: "mac_keystroke", surface: "telegram", input: raw
        )
        try await fenceExpectReplayRefusal(
            root: root, approvalID: id, tool: "mac_keystroke",
            input: redactedInput, expect: "approval_is_for_a_different_surface"
        )
    }

    // (f) no verifier wired at all — fail closed, not fail open.
    do {
        let root = try fenceTempRoot("defect-noverifier")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await fenceApprovedRecordID(
            root: root, tool: "mac_keystroke", input: raw
        )
        try await fenceExpectReplayRefusal(
            root: root, approvalID: id, tool: "mac_keystroke",
            input: redactedInput, expect: "approval_verifier_unavailable",
            withVerifier: false
        )
    }
}

/// Drive one replay through a fence dispatcher and require the exact refusal
/// reason, with nothing reaching the inner dispatcher.
private func fenceExpectReplayRefusal(
    root: URL,
    approvalID: String,
    tool: String,
    input: [String: JSONValue],
    expect reason: String,
    withVerifier: Bool = true
) async throws {
    let inner = FenceRecordingDispatcher()
    let replay = ApprovedChatToolReplay(
        approvalID: approvalID,
        tool: tool,
        surface: "chat",
        input: input,
        verifiedSessionID: "fence-session",
        verifiedChatID: nil,
        verifiedUserID: nil
    )
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "auto",
        approvedReplay: replay, withVerifier: withVerifier
    )
    do {
        _ = try await dispatcher.dispatch(tool: tool, input: input, surface: "chat")
        Issue.record("expected \(reason), but the replay dispatched")
    } catch let error as AutonomyGateError {
        #expect("\(error)".contains(reason), "expected \(reason), got \(error)")
    }
    #expect(await inner.calls().isEmpty, "\(reason): nothing may reach the inner dispatcher")
}

@Test
func macInjectionR2_aRecordThatAlreadyExecutedCannotBeReplayed() async throws {
    // Single use has a PERSISTENT half: an approval whose executedAction is
    // already written is spent, and stays spent across a restart that clears
    // the in-process ledger.
    let root = try fenceTempRoot("replay-executed")
    defer { try? FileManager.default.removeItem(at: root) }
    let raw: [String: JSONValue] = ["text": .string("hunter2")]
    let redactedInput = MacInjectionArgRedaction.redacted(tool: "mac_keystroke", input: raw)
    let id = try await fenceApprovedRecordID(root: root, tool: "mac_keystroke", input: raw)

    // Stamp an executedAction the way the post-approval executor does.
    let inbox = SwiftNativeApprovalInbox(root: root)
    var record = try await inbox.get(id)
    record.executedAction = .object([
        "op": .string("chat_tool_approval_replay"),
        "status": .string("succeeded"),
    ])
    try await fenceRewriteRecord(root: root, record: record)

    try await fenceExpectReplayRefusal(
        root: root, approvalID: id, tool: "mac_keystroke",
        input: redactedInput, expect: "approval_already_consumed"
    )
}

/// Rewrite one record in place — the inbox exposes no "annotate" on its
/// protocol, and the app-side annotator lives in the app target.
private func fenceRewriteRecord(root: URL, record: ApprovalRecord) async throws {
    let path = root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
        .appendingPathComponent("requests.json")
    let data = try Data(contentsOf: path)
    guard case .array(let rows) = try JSONValue.parse(data) else {
        throw NSError(domain: "fence", code: 1)
    }
    let updated = rows.map { row -> JSONValue in
        guard case .object(let obj) = row, obj["id"] == .string(record.id) else { return row }
        return record.toJSON()
    }
    try JSONValue.array(updated).serializedData(pretty: false).write(to: path)
}

@Test
func macInjectionR2_aFilerThatOnlyClaimsApprovalCannotMint() async throws {
    // The in-call path has the same root of trust as the replay path. This
    // dispatcher accepts ANY ApprovalFiler, so "the filer returned an id and
    // said .approved" must not by itself authorize a keystroke: here the filer
    // stages a REAL record and never resolves it, then reports approval anyway.
    let root = try fenceTempRoot("lying-filer")
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = FenceRecordingDispatcher()
    let filer = FenceInboxApprovingFiler(dataRoot: root, resolvesIt: false)
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "send_approval", filer: filer, hasFiler: true
    )

    do {
        _ = try await dispatcher.dispatch(
            tool: "mac_keystroke", input: ["text": .string("hunter2")], surface: "chat"
        )
        Issue.record("an unresolved record must not authorize an injection")
    } catch let error as AutonomyGateError {
        #expect("\(error)".contains("injection_approval_unverified"), "\(error)")
        #expect("\(error)".contains("approval_not_resolved_approved"), "\(error)")
    }
    #expect(await inner.calls().isEmpty)
}

@Test
func macInjectionR2_noAlwaysApproveVerifierExistsInSource() throws {
    // The verification is only as strong as the implementations that exist.
    // Exactly one non-test type may conform to `InjectionApprovalVerifying`,
    // and it is the inbox-backed one — a convenience "always verified" stub in
    // the source tree would be the whole fix, undone.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let searchRoots = [
        repoRoot.appendingPathComponent("Modules/NativeAgentCore/Sources"),
        repoRoot.appendingPathComponent("Sources"),
    ]
    var conformers: [String] = []
    for searchRoot in searchRoots {
        guard let walker = FileManager.default.enumerator(
            at: searchRoot, includingPropertiesForKeys: nil
        ) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(": InjectionApprovalVerifying")
                    || trimmed.contains(", InjectionApprovalVerifying") else { continue }
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                conformers.append("\(url.lastPathComponent): \(trimmed)")
            }
        }
    }
    #expect(conformers.count == 1, "found: \(conformers.sorted())")
    #expect(conformers.first?.hasPrefix("InjectionApprovalVerifier.swift") == true,
            "the only verifier must be the inbox-backed one: \(conformers)")
}

// MARK: - W2/W3-FIX-R2 2: the security audit never sees the typed characters

@Test
func macInjectionR2_securityAuditDoesNotContainTheTypedText() async throws {
    // BLOCKING R2-2. `AutonomyGatedDispatcher` evaluated SecurityCenter with the
    // RAW input, and SecurityCenter persists `redactedInputPreview` into
    // security/audit.jsonl. Its redactor only catches secret-NAMED keys and
    // secret-SHAPED strings — "hunter2" under "text" is neither — so the typed
    // characters landed in an unencrypted, long-lived audit file BEFORE the
    // approval filer's redaction ever ran.
    let secret = "hunter2"
    let root = try fenceTempRoot("audit-redaction")
    defer { try? FileManager.default.removeItem(at: root) }

    let inner = FenceRecordingDispatcher()
    let filer = FenceCapturingFiler(approvalID: "audit-approval")
    let dispatcher = fenceDispatcher(
        inner: inner, root: root, level: "send_approval", filer: filer, hasFiler: true
    )
    _ = try await dispatcher.dispatch(
        tool: "mac_keystroke", input: ["text": .string(secret)], surface: "chat"
    )
    // ax_act's written value is the same class of secret and the same sink.
    _ = try await dispatcher.dispatch(
        tool: "mac_ax_act",
        input: ["path": .array([.int(0)]), "action": .string("AXSetValue"),
                "value": .string(secret)],
        surface: "chat"
    )

    let auditPath = root
        .appendingPathComponent("security", isDirectory: true)
        .appendingPathComponent("audit.jsonl")
    let audit = (try? String(contentsOf: auditPath, encoding: .utf8)) ?? ""
    #expect(!audit.isEmpty, "the .ask receipt must actually have been written — else this proves nothing")
    #expect(!audit.contains(secret),
            "security/audit.jsonl must never carry the typed characters: \(audit)")
    #expect(audit.contains("text_character_count") || audit.contains("text_sha256"),
            "the audit row should still describe the argument shape")
    #expect(await inner.calls().isEmpty)
}

@Test
func macInjectionR2_securityCenterRedactsInjectionArgsEvenWhenHandedRawInput() async throws {
    // Defense in depth: the boundary that PERSISTS owns its redaction. A future
    // caller that forgets to redact (or a direct SecurityCenter user) must not
    // be able to put the characters into the audit file.
    let secret = "hunter2"
    let root = try fenceTempRoot("audit-direct")
    defer { try? FileManager.default.removeItem(at: root) }
    let center = SwiftNativeSecurityCenter(dataRoot: root)
    let envelope = await center.evaluateTool(
        tool: "mac_keystroke",
        input: ["text": .string(secret)],
        origin: SecurityOriginContext(surface: "chat", source: "chat_runtime")
    )
    try await center.record(envelope)
    let audit = (try? String(
        contentsOf: root.appendingPathComponent("security/audit.jsonl"), encoding: .utf8
    )) ?? ""
    #expect(!audit.isEmpty)
    #expect(!audit.contains(secret), "\(audit)")
}

// MARK: - W2/W3-FIX-R2 3: the ax_act value never leaves through a preview

@Test
func macInjectionR2_axActResultPreviewsAreRedactedEverywhereTheyArePersisted() async throws {
    // BLOCKING R2-3, the downstream half. MacControl now redacts at the source;
    // these are the independent boundaries — the turn-trace result preview and
    // the approval record's resultPreview — which persist a result they did not
    // produce and must not depend on the producer having redacted.
    let secret = "hunter2"
    let axActResult = JSONValue.object([
        "ok": .bool(true),
        "status": .string("acted"),
        "element": .object(["role": .string("AXTextField"), "value": .string(secret)]),
        "post_state": .object(["role": .string("AXTextField"), "value": .string(secret)]),
    ])
    for tool in ["mac_ax_act", "mac.ax_act", "mac_keystroke"] {
        let redacted = MacInjectionResultRedaction.redacted(tool: tool, result: axActResult)
        let serialized = String(
            data: try redacted.serializedData(pretty: false), encoding: .utf8
        ) ?? ""
        #expect(!serialized.contains(secret), "\(tool): \(serialized)")
    }
    // TEETH: an ordinary tool's result is untouched, so this cannot pass by
    // redacting everything everywhere.
    let readResult = JSONValue.object(["value": .string(secret)])
    #expect(MacInjectionResultRedaction.redacted(tool: "read_file", result: readResult) == readResult)
}

@Test
func macInjectionR2_chatTranscriptToolRowNeverCarriesTheTypedText() async throws {
    // The sink the R2 review did not name but that syncs the furthest: the
    // role="tool" transcript row persists `inputJSON` verbatim into
    // chat/messages/<session>.jsonl, which every surface reads back. Its
    // generic redactor only catches secret-SHAPED strings, and a password is
    // not shaped like anything.
    let secret = "hunter2"
    let argJSON = "{\"text\":\"\(secret)\"}"
    let redactedArgs = SwiftNativeChatOrchestrationClient.injectionRedactedArgJSON(
        tool: "mac_keystroke", json: argJSON
    )
    #expect(!redactedArgs.contains(secret), "\(redactedArgs)")
    #expect(redactedArgs.contains("text_character_count"))

    let resultJSON = "{\"post_state\":{\"value\":\"\(secret)\"}}"
    let redactedResult = SwiftNativeChatOrchestrationClient.injectionRedactedResultJSON(
        tool: "mac_ax_act", json: resultJSON
    )
    #expect(!redactedResult.contains(secret), "\(redactedResult)")

    // TEETH: an ordinary tool's receipt is untouched, so this cannot pass by
    // redacting every transcript row.
    #expect(SwiftNativeChatOrchestrationClient.injectionRedactedArgJSON(
        tool: "read_file", json: argJSON) == argJSON)
    #expect(SwiftNativeChatOrchestrationClient.injectionRedactedResultJSON(
        tool: "read_file", json: resultJSON) == resultJSON)
}

// MARK: - R3: the durable spend — single use has to survive a crash

/// A verifier on this root with its OWN process ledger. Two of these model two
/// PROCESSES: the durable marker is the only state they share.
private func fenceFreshProcessVerifier(root: URL) -> ApprovalInboxInjectionApprovalVerifier {
    ApprovalInboxInjectionApprovalVerifier(
        dataRoot: root,
        ledger: MacInjectionApprovalConsumptionLedger()
    )
}

private func fenceSpendMarker(root: URL, id: String) async -> JSONValue? {
    await SwiftNativeApprovalInbox(root: root).injectionApprovalSpend(id: id)
}

@Test
func macInjectionR3_durableSpendIsWrittenBeforeVerifiedIsReturned() async throws {
    // The spend is the FIRST write of the transaction, not a by-product of the
    // executor's later annotation. After a single `.verified`, the marker is on
    // disk even though nothing has executed yet.
    let root = try fenceTempRoot("spend-written")
    defer { try? FileManager.default.removeItem(at: root) }

    let input: [String: JSONValue] = ["x": .int(10), "y": .int(20)]
    let id = try await fenceApprovedRecordID(root: root, tool: "mac_click", input: input)

    #expect(await fenceSpendMarker(root: root, id: id) == nil,
            "no marker may exist before verification")

    let verdict = await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: id, tool: "mac_click", surface: "chat", input: input
    )
    #expect(verdict == .verified, "legitimate first use must still pass: \(verdict)")

    guard case .object(let marker)? = await fenceSpendMarker(root: root, id: id) else {
        Issue.record("durable spend marker was not written for \(id)")
        return
    }
    #expect(marker["tool"] == .string("mac_click"))
    #expect(marker["surface"] == .string("chat"))
    #expect(marker["digest"] == .string(
        MacInjectionApprovalDigest.digest(tool: "mac_click", input: input) ?? "<none>"
    ))

    // And the executor has NOT run: the record is still un-annotated. This is
    // exactly the state the crash window leaves behind.
    let record = try await SwiftNativeApprovalInbox(root: root).get(id)
    #expect(record.executedAction == nil)
}

@Test
func macInjectionR3_restartReplayIsRefusedAfterTheEffectLanded() async throws {
    // THE FINDING. Sequence: approval verified → click lands → CRASH before the
    // executor writes `executedAction` → relaunch. The new process has an empty
    // consumption ledger and reads a resolved-approved record with no
    // `executedAction`, and a click carries no secret-vault dependency to trip
    // over. Before the durable spend, that record re-fired. Now it is burned.
    let root = try fenceTempRoot("restart-replay")
    defer { try? FileManager.default.removeItem(at: root) }

    let input: [String: JSONValue] = ["x": .int(3), "y": .int(4)]
    let id = try await fenceApprovedRecordID(root: root, tool: "mac_click", input: input)

    let first = await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: id, tool: "mac_click", surface: "chat", input: input
    )
    #expect(first == .verified)

    // ---- crash: no executedAction is ever written ----
    let record = try await SwiftNativeApprovalInbox(root: root).get(id)
    #expect(record.executedAction == nil, "the crash window means NO annotation")
    #expect(record.status == "resolved" && record.decision == "approved")

    // ---- relaunch: fresh process, fresh ledger, same disk ----
    let afterRestart = await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: id, tool: "mac_click", surface: "chat", input: input
    )
    #expect(afterRestart == .alreadyConsumed,
            "an already-spent injection approval must never re-verify after restart: \(afterRestart)")

    // TEETH: the refusal is the SPEND, not a coincidence of this fixture — a
    // second, never-spent approval for the same tool and body still verifies in
    // that same fresh process.
    let fresh = try await fenceApprovedRecordID(root: root, tool: "mac_click", input: input)
    let freshVerdict = await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: fresh, tool: "mac_click", surface: "chat", input: input
    )
    #expect(freshVerdict == .verified, "a genuinely new approval must still pass: \(freshVerdict)")
}

@Test
func macInjectionR3_failedExecutionDoesNotRollBackTheSpend() async throws {
    // DOCUMENTED DECISION: the spend is PERMANENT. If the injection that
    // follows it fails — or the process dies mid-flight — the approval stays
    // burned and Agent has to ask again. Rolling back on failure would reopen
    // the window this closes, because a crash cannot run rollback code, and
    // "the effect did not land" is not observable from the failure alone (a
    // keystroke can half-land). A re-ask costs a sentence.
    let root = try fenceTempRoot("failed-exec")
    defer { try? FileManager.default.removeItem(at: root) }

    let input: [String: JSONValue] = ["dy": .int(-5)]
    let id = try await fenceApprovedRecordID(root: root, tool: "mac_scroll", input: input)

    #expect(await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: id, tool: "mac_scroll", surface: "chat", input: input) == .verified)

    // The executor's failure annotation is written; it is an OUTCOME, not an
    // un-spend. Nothing anywhere clears the marker.
    #expect(await fenceSpendMarker(root: root, id: id) != nil)
    let retry = await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: id, tool: "mac_scroll", surface: "chat", input: input
    )
    #expect(retry == .alreadyConsumed, "a failed injection does not refund its approval: \(retry)")
}

@Test
func macInjectionR3_concurrentVerifiesSpendExactlyOnce() async throws {
    // CAS, not check-then-write. Two verifiers with SEPARATE process ledgers
    // (so the in-memory layer cannot be what serializes them) race on the same
    // record. Exactly one may be told `.verified`.
    let root = try fenceTempRoot("cas-race")
    defer { try? FileManager.default.removeItem(at: root) }

    let input: [String: JSONValue] = ["x": .int(1), "y": .int(2)]
    let id = try await fenceApprovedRecordID(root: root, tool: "mac_click", input: input)

    let a = fenceFreshProcessVerifier(root: root)
    let b = fenceFreshProcessVerifier(root: root)
    async let first = a.verifyInjectionApproval(
        approvalID: id, tool: "mac_click", surface: "chat", input: input)
    async let second = b.verifyInjectionApproval(
        approvalID: id, tool: "mac_click", surface: "chat", input: input)
    let verdicts = await [first, second]

    #expect(verdicts.filter { $0 == .verified }.count == 1,
            "exactly one concurrent verify may win the spend: \(verdicts)")
    #expect(verdicts.filter { $0 == .alreadyConsumed }.count == 1,
            "the loser must be refused as already consumed: \(verdicts)")
}

@Test
func macInjectionR3_unrecordableSpendFailsClosed() async throws {
    // A marker store that exists but cannot be parsed must not silently read as
    // "nothing spent yet" — that would un-spend every approval on disk. It
    // refuses instead, with its own reason code.
    let root = try fenceTempRoot("spend-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }

    let input: [String: JSONValue] = ["x": .int(7), "y": .int(8)]
    let id = try await fenceApprovedRecordID(root: root, tool: "mac_click", input: input)

    let spendPath = root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
        .appendingPathComponent("injection_spends.json")
    try Data("{ not json".utf8).write(to: spendPath)

    let verdict = await fenceFreshProcessVerifier(root: root).verifyInjectionApproval(
        approvalID: id, tool: "mac_click", surface: "chat", input: input
    )
    #expect(verdict == .spendUnavailable,
            "a spend that cannot be recorded must refuse, not proceed: \(verdict)")
}
