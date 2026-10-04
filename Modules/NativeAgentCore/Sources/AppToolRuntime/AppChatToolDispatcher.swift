import Foundation
import Agents
import ChatOrchestration
import ChromeControl
import Cognition
import CognitiveSubstrate
import Context
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import WorkshopExecution
import StandingBots
import ToolRegistry

/// Core's composed gate in front of the tool router on chat surfaces.
///
/// Every tool — Core's and the app's own — is listed, catalogued, loaded and
/// lazily gated by Core; the app's executors reach Core's catalog through the
/// engine's port (`AppToolExecutor`). This owner keeps the composed side of the
/// call: the Security Center gate, trust on the full catalog, the live-body
/// routes a result hands back (self-window, desktop and Grok sends), and
/// the settled-result observers (context prewarm, motor outcomes).
public final class AppChatToolDispatcher: ToolDispatchClient, PreApprovalToolValidating, BuiltInAgentLaneProviding, @unchecked Sendable {
    private let interactions: any ToolInteractionResolving
    private let platform: ChatToolPlatformPort
    private let inner: any ToolDispatchClient
    public func builtInAgentLaneUsable(_ name: String) -> Bool {
        (inner as? any BuiltInAgentLaneProviding)?.builtInAgentLaneUsable(name) == true
    }
    private let securityCenter: SwiftNativeSecurityCenter
    /// The app's own tool executors: here only for the self-window handoff an
    /// `act`/`go`/`screen` result asks this process to finish.
    private let appTools: AppToolExecutor?
    private let organismPostureProvider: @Sendable () async -> OrganismBehaviorPosture?
    private let contextPrewarm: @Sendable (ContextPrewarmHintKind, String, [String]) async -> Void
    private let motorOutcomeObserver: @Sendable (ToolCausalBoundary.MotorReference) async -> Void
    private let enforceAutonomySecurity: Bool
    private let includeAppOwnedTools: Bool
    /// Off-dispatch-path, order-preserving delivery for context prewarm hints.
    /// One chain per dispatcher instance — see `schedulePrewarmAfterToolResult`.
    private let prewarmRelay = SerialDetachedRelay(label: "AppChatToolDispatcher.prewarm")

    public init(
        inner: any ToolDispatchClient = SwiftToolDispatcher(
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(
                dataRoot: PersistenceCore.defaultDataRoot()
            )
        ),
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        enforceAutonomySecurity: Bool = true,
        includeAppOwnedTools: Bool = true,
        appTools: AppToolExecutor? = nil,
        organismPostureProvider: @escaping @Sendable () async -> OrganismBehaviorPosture?,
        contextPrewarm: @escaping @Sendable (
            ContextPrewarmHintKind,
            String,
            [String]
        ) async -> Void = { _, _, _ in },
        motorOutcomeObserver: @escaping @Sendable (ToolCausalBoundary.MotorReference) async -> Void = { _ in },
        interactions: any ToolInteractionResolving,
        platform: ChatToolPlatformPort
    ) {
        self.interactions = interactions
        self.platform = platform
        self.inner = inner
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.includeAppOwnedTools = includeAppOwnedTools
        self.appTools = appTools
        self.organismPostureProvider = organismPostureProvider
        self.contextPrewarm = contextPrewarm
        self.motorOutcomeObserver = motorOutcomeObserver
    }

    /// Core's pre-approval rules — its lazy-load gate covers every tool, the
    /// app's own among them — carried to the approval membrane, which only
    /// ever sees this wrapper.
    public func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        if let validating = inner as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
        }
        return await (inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
    }

    public func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        guard let validating = inner as? any PreApprovalToolValidating else { return nil }
        return await validating.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Walk 3: her natural guess for Back is a tool of its own — it is navigate url:"back".
        let bare = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "browser.", with: "").replacingOccurrences(of: "browser_", with: "")
            .replacingOccurrences(of: ".", with: "_")
        if let direction = ["chrome_back": "back", "chrome_go_back": "back",
                            "chrome_forward": "forward", "chrome_go_forward": "forward"][bare] {
            var go = input
            go["url"] = .string(direction)
            return try await dispatch(tool: "browser.chrome_navigate", input: go, surface: surface)
        }
        return ChatToolOutcome.normalizedFailure(try await withToolArguments(tool: tool, input: input) { input in
            try await dispatchNormalized(tool: tool, input: input, surface: surface)
        }, tool: tool)
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // 2026-09-06: the bridge canonicalizes `mobile.notify` to `mobile_notify`
        // before this dispatcher sees it, and the fence matched the dotted
        // spelling only — so on a synthetic root the call fell through to
        // `runMobileNotify` and attempted a real push. Fence the canonical
        // notification name too. 2026-09-26: aliases resolve before this
        // dispatcher (ToolNameAliases); the other app tools are simply absent
        // from a body with no app executor.
        if !includeAppOwnedTools, ["mac_notify", "mobile_notify"].contains(tool) {
            return .object([
                "status": .string("failed"),
                "reason": .string("canonical_body_unavailable"),
                "tool": .string(tool),
            ])
        }
        var canonicalInput = input
        // Bind the same session as Core before any route.
        let taskSession = [ChatToolSessionContext.verifiedSessionId, LLMCallContext.sessionId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let taskSession {
            canonicalInput["__session_id"] = .string(taskSession)
        }
        let result = try await dispatchWithoutOrganismPosture(
            tool: tool,
            input: canonicalInput,
            surface: surface
        )
        // 2026-09-22 WHY: the posture already rides the prompt's
        // [OrganismBehavior] block; stamping it on every result cost ~1K
        // tokens a turn and crowded real data out of trimmed results.
        let organismActive = await organismPostureProvider() != nil
        schedulePrewarmAfterToolResult(
            tool: tool,
            input: canonicalInput,
            result: result,
            surface: surface,
            organismActive: organismActive
        )
        await observeMotorOutcomeIfNeeded(tool: tool, result: result)
        return result
    }

    private func observeMotorOutcomeIfNeeded(tool: String, result: JSONValue) async {
        guard let reference = ToolCausalBoundary.motorReference(tool: tool, output: result) else {
            return
        }
        await motorOutcomeObserver(reference)
    }

    /// Hand the prewarm hints for a settled tool result to the off-path relay.
    ///
    /// Deliberately NOT `async`: nothing on the current turn reads the prewarm
    /// result (`NativeContextFlowRuntime.prewarm` discards the receipt), but
    /// the work itself lowercases every atom body in the active generation on
    /// the `ContextFlowCoordinator` actor — the same actor the NEXT turn's
    /// `prepareTurn` has to enter. Awaiting it here charged that scan to
    /// user-visible tool latency, once per tool call.
    ///
    /// The hints themselves are computed synchronously and by value, so the
    /// planner still sees byte-identical `(kind, id, terms)` for the exact
    /// result this call returned — a later mutation of anything can't drift
    /// them. Only the delivery moves; ordering is preserved by the relay.
    private func schedulePrewarmAfterToolResult(
        tool: String,
        input: [String: JSONValue],
        result: JSONValue,
        surface: String,
        organismActive: Bool
    ) {
        let hints = Self.prewarmHints(
            tool: tool,
            input: input,
            result: result,
            surface: surface,
            organismActive: organismActive
        )
        guard !hints.isEmpty else { return }
        let prewarm = self.contextPrewarm
        prewarmRelay.enqueue {
            for hint in hints {
                await prewarm(hint.kind, hint.id, hint.terms)
            }
        }
    }

    public struct ContextPrewarmHint: Sendable {
        var kind: ContextPrewarmHintKind
        var id: String
        var terms: [String]
    }

    /// Pure function of the settled tool call — same inputs, same hints, in the
    /// same order as the old inline `await` pair emitted them.
    public static func prewarmHints(
        tool: String,
        input: [String: JSONValue],
        result: JSONValue,
        surface: String,
        organismActive: Bool = false
    ) -> [ContextPrewarmHint] {
        let terms = [tool, surface]
            + input.keys.sorted()
            + Self.resultKeys(result)
        let kind: ContextPrewarmHintKind
        let id: String
        if tool.hasPrefix("desk_") {
            kind = .desk
            id = "agent-desk"
        } else if Self.fileContextTools.contains(tool) {
            kind = .file
            id = AppToolExecutor.inputString(input["path"]) ?? tool
        } else {
            kind = .toolResult
            id = tool
        }
        var hints = [ContextPrewarmHint(kind: kind, id: id, terms: terms)]
        if organismActive {
            hints.append(ContextPrewarmHint(kind: .organism, id: "tool-posture", terms: terms))
        }
        return hints
    }

    /// Wait for every prewarm hint enqueued so far to reach the coordinator.
    /// Tests and shutdown only — the dispatch path must never call this.
    public func drainPendingContextPrewarm() async {
        await prewarmRelay.drain()
    }

    private static let fileContextTools: Set<String> = [
        "read_file", "list_dir", "file_excerpt", "grep", "write_file",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
    ]

    private static func resultKeys(_ result: JSONValue) -> [String] {
        guard case .object(let object) = result else { return [] }
        return object.keys.sorted()
    }

    private func dispatchWithoutOrganismPosture(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let envelope = await securityCenter.evaluateTool(
            tool: tool,
            input: input,
            origin: Self.securityOrigin(input: input, surface: surface),
            enforceAutonomy: enforceAutonomySecurity
        )
        try? await securityCenter.record(envelope)
        // Composed chat and approved replay resolve asks in the outer approval
        // membrane. Recheck hard blocks here without asking a second time.
        guard envelope.decision != .block,
              !enforceAutonomySecurity || !envelope.requiresApproval else {
            return Self.securityGateResponse(envelope)
        }
        let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        // An ask for something already set up raises no card: a card that
        // reads as its receipt from the start would leave the turn waiting on
        // nobody. The owner's answer goes back instead, and she carries on.
        if includeAppOwnedTools, tool == InlineInteractionWire.toolName,
           let need = InlineInteractionNeed.interaction(in: result),
           let done = await interactions.liveOutcomeSummary(need, dataRoot: PersistenceCore.defaultDataRoot()) {
            return .object([
                "status": .string("ok"),
                "already_done": .bool(true),
                "summary": .string(done),
                "note": .string("Already set up, so no card was shown. Carry on."),
            ])
        }
        if includeAppOwnedTools, ["agent_connect", "agent_message"].contains(tool),
           case .object(let plan) = result,
           [JSONValue.string("grok_setup"), .string("grok_disconnect"), .string("grok_send")].contains(plan["status"] ?? .null) {
            return await platform.grok(plan, PersistenceCore.defaultDataRoot(), inner, surface)
        }
        if includeAppOwnedTools, tool == "agent_message", case .object(let plan) = result,
           plan["status"] == .string("desktop_chat_send") {
            return await platform.desktopChat(plan, PersistenceCore.defaultDataRoot())
        }
        if includeAppOwnedTools, let appTools, ["act", "go", "screen"].contains(tool) {
            // Her-screen 09-24: a workspace call never takes the self route; it
            // would read her own pages, the Chat page among them.
            if WorkspaceMacCall.active, case .object(let payload) = result, case .object(let detail)? = payload["detail"],
               detail["status"] == .string("in_process_route") { return WorkspaceMacCall.refusal }
            return await AppToolExecutor.performMacSelfAppRoute(result) { input in
                await appTools.runSelfAppRoute(input: input, surface: surface)
            }
        }
        // Desktop contacts are send-only: `agent_read` no longer opens or
        // inspects the other app, so only a send reaches the desktop route.
        if includeAppOwnedTools, tool == "agent_message",
           case .object(let plan) = result, plan["transport"] == .string("desktop"),
           plan["status"] == .string("requires_interaction") {
            let sent = await platform.desktop(plan, inner, surface)
            return await GrokDesktopReply.follow(sent, dataRoot: PersistenceCore.defaultDataRoot())
        }
        return result
    }

    /// Each full-catalog row carries what the Security Center would decide for
    /// it right now — the Tools page reads this. Core's rows say what a tool
    /// is; this gate says whether it may run here.
    /// The Tools page's manifest with each row's Trust decision here. Not a
    /// tool call: nothing is dispatched, gated or loaded.
    public func toolManifest(detail: String? = nil, surface: String = "chat") async throws -> JSONValue {
        guard let swift = inner as? SwiftToolDispatcher else {
            return .object(["status": .string("unavailable"), "tools": .array([])])
        }
        return await withTrust(catalog: try await swift.toolManifest(detail: detail, surface: surface), surface: surface)
    }

    private func withTrust(catalog: JSONValue, surface: String) async -> JSONValue {
        guard case .object(var object) = catalog, case .array(let rows)? = object["tools"], !rows.isEmpty else {
            return catalog
        }
        var capabilityRows: [JSONValue] = []
        capabilityRows.reserveCapacity(rows.count)
        for row in rows {
            guard case .object(var rowObj) = row,
                  case .string(let name)? = rowObj["name"] else {
                capabilityRows.append(row)
                continue
            }
            let envelope = await securityCenter.evaluateTool(
                tool: name,
                input: [:],
                origin: Self.securityOrigin(input: [:], surface: surface),
                enforceAutonomy: enforceAutonomySecurity
            )
            let effectiveAutonomy: String
            switch envelope.decision {
            case .allow: effectiveAutonomy = "auto"
            case .ask: effectiveAutonomy = "confirm"
            case .block: effectiveAutonomy = "blocked"
            }
            rowObj["autonomy"] = .string(envelope.autonomyLevel)
            rowObj["effective_autonomy"] = .string(effectiveAutonomy)
            rowObj["autonomy_source"] = .string("trust_center")
            rowObj["side_effects"] = .bool(envelope.hasSideEffects)
            rowObj["available_now"] = .bool(envelope.decision != .block)
            rowObj["input_schema"] = rowObj["parameters"] ?? .object([:])
            capabilityRows.append(.object(rowObj))
        }
        object["tools"] = .array(capabilityRows)
        return .object(object)
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().sorted()
    }

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names).sorted { $0.name < $1.name }
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().sorted { $0.name < $1.name }
    }

    public static func securityOrigin(input: [String: JSONValue], surface: String) -> SecurityOriginContext {
        let _ = input
        // Read the per-turn session bound by the authoritative AutonomyGatedDispatcher
        // upstream (ChatToolSessionContext). Without it this gate hardcoded
        // sessionId: nil, so a TRUSTED remote surface (allowlisted Telegram) could
        // not resolve its chatId, failed the allowlist match, and false-blocked an
        // invoke the upstream gate had already approved. Threading the session lets
        // this gate resolve the SAME trust. Nil for standalone uses (catalog
        // refresh), which carry no remote session — correct.
        let sessionId = ChatToolSessionContext.verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableSessionId = (sessionId?.isEmpty == false) ? sessionId : nil
        // PARSE SITE 5 of 5, DELETED (one-thread-many-surfaces plan §1.2). The
        // `telegram:<chatId>` session-string fallback that used to stand here
        // is gone; the session id is a storage key, not evidence.
        //
        // This gate MIRRORS `AutonomyGatedDispatcher.securityOrigin` field for
        // field, and for the same reason: the projection is the TURN ENVELOPE's,
        // not the dispatch `surface`'s. An adapter that binds an envelope for a
        // remote surface while dispatching under the shared "chat" tool surface
        // must reach the same — remote, allowlist-gated — verdict in BOTH gates,
        // or the weaker one becomes the way in.
        let envelope = TurnEnvelope.current(surface: surface)
        let remote = ConversationSurfaceProfile(envelope.surface).isRemote
            || envelope.declaredRemote == true
        return SecurityOriginContext(
            surface: envelope.surface,
            sessionId: usableSessionId,
            userId: envelope.verifiedUserId,
            chatId: envelope.verifiedChatId,
            deviceId: nil,
            source: "app_chat_tool_dispatcher",
            isRemote: remote,
            commandSignatureVerified: envelope.commandSignatureVerified
        )
    }

    private static func securityGateResponse(_ envelope: SecurityToolEnvelope) -> JSONValue {
        .object([
            "status": .string(envelope.requiresApproval ? "pending_approval" : "blocked"),
            "runtime": .string("swift-native"),
            "tool": .string(envelope.tool),
            "surface": .string(envelope.surface),
            "decision": .string(envelope.decision.rawValue),
            "risk": .string(envelope.risk),
            "allowed": .bool(false),
            "requires_approval": .bool(envelope.requiresApproval),
            "origin_trusted": .bool(envelope.originTrusted),
            "reason": .string(envelope.primaryReason),
            "reasons": .array(envelope.reasons.map { .string($0.persistedValue) }),
            "capabilities": .array(envelope.capabilities.map { .string($0) }),
            "message": .string(envelope.requiresApproval ? "Security Center requires approval before running this tool." : "Security Center blocked this tool before execution."),
        ])
    }
}
