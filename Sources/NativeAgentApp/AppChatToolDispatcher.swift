import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import MacControl
import MacIntegration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import TrustCenter
import WorkshopExecution

/// App-owned tool shim for chat surfaces.
///
/// Core's SwiftToolDispatcher intentionally knows nothing about Mac app
/// singletons such as MacSyncEngine. This wrapper keeps those executors in the
/// app target while letting the Swift chat loop expose them as normal tools.
final class AppChatToolDispatcher: ToolDispatchClient, ActiveToolsStoreProviding, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    let activeToolsStore: ActiveToolsStore
    private let securityCenter: SwiftNativeSecurityCenter
    private let mobileNotificationSender: @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt
    private let macNotificationSender: @Sendable (String, String) async throws -> NativeAgentNotificationPostResult
    private let browserActionRunner: @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    private let doctorStatusProvider: @Sendable () async throws -> JSONValue
    private let telegramStatusProvider: @Sendable () async throws -> JSONValue
    private let reflexReviewHandler: @Sendable (
        String,
        OrganismReflexReviewDecision,
        String?,
        String
    ) async -> OrganismReflexReviewApplyOutcome
    private let organismPostureProvider: @Sendable () async -> OrganismBehaviorPosture?
    private let contextPrewarm: @Sendable (ContextPrewarmHintKind, String, [String]) async -> Void
    private let motorOutcomeObserver: @Sendable (ToolCausalBoundary.MotorReference) async -> Void
    private let enforceAutonomySecurity: Bool
    private let includeAppOwnedTools: Bool
    /// Off-dispatch-path, order-preserving delivery for context prewarm hints.
    /// One chain per dispatcher instance — see `schedulePrewarmAfterToolResult`.
    private let prewarmRelay = SerialDetachedRelay(label: "AppChatToolDispatcher.prewarm")

    static func defaultReflexReviewerIdentity(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
    }

    init(
        inner: any ToolDispatchClient = SwiftToolDispatcher(),
        activeToolsStore: ActiveToolsStore = .shared,
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        enforceAutonomySecurity: Bool = true,
        includeAppOwnedTools: Bool = true,
        mobileNotificationSender: @escaping @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt = { title, body, userInfo in
            try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: title,
                body: body,
                userInfo: userInfo
            )
        },
        macNotificationSender: @escaping @Sendable (String, String) async throws -> NativeAgentNotificationPostResult = { title, body in
            await NativeAgentNotifications.postAndReport(title: title, body: body)
        },
        browserActionRunner: (@Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue)? = nil,
        doctorStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        telegramStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        reflexReviewHandler: @escaping @Sendable (
            String,
            OrganismReflexReviewDecision,
            String?,
            String
        ) async -> OrganismReflexReviewApplyOutcome = { candidateID, decision, note, surface in
            await NativeCognitionRuntime.shared.applyOrganismReflexReview(
                id: candidateID,
                decision: decision,
                note: note,
                reviewedBy: AppChatToolDispatcher.defaultReflexReviewerIdentity(),
                source: "reflex_review:\(surface)"
            )
        },
        organismPostureProvider: @escaping @Sendable () async -> OrganismBehaviorPosture? = {
            await NativeCognitionRuntime.shared.organismBehaviorPosture()
        },
        contextPrewarm: @escaping @Sendable (
            ContextPrewarmHintKind,
            String,
            [String]
        ) async -> Void = { _, _, _ in },
        motorOutcomeObserver: @escaping @Sendable (ToolCausalBoundary.MotorReference) async -> Void = { _ in }
    ) {
        self.inner = inner
        self.activeToolsStore = activeToolsStore
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.includeAppOwnedTools = includeAppOwnedTools
        self.mobileNotificationSender = mobileNotificationSender
        self.macNotificationSender = macNotificationSender
        self.browserActionRunner = browserActionRunner ?? Self.defaultBrowserActionRunner
        self.doctorStatusProvider = doctorStatusProvider ?? Self.defaultDoctorStatusProvider
        self.telegramStatusProvider = telegramStatusProvider ?? Self.defaultTelegramStatusProvider
        self.reflexReviewHandler = reflexReviewHandler
        self.organismPostureProvider = organismPostureProvider
        self.contextPrewarm = contextPrewarm
        self.motorOutcomeObserver = motorOutcomeObserver
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if !includeAppOwnedTools, Self.appToolNames.contains(tool) {
            return .object([
                "status": .string("failed"),
                "reason": .string("canonical_body_unavailable"),
                "tool": .string(tool),
            ])
        }
        var canonicalInput = input
        let macOperationID: String?
        if tool == "mac_focus_app" || tool == "mac_quit_app" {
            let supplied: String? = switch canonicalInput["operationId"] ?? canonicalInput["operation_id"] {
            case .string(let value): value.isEmpty ? nil : value
            default: nil
            }
            let operationID = supplied ?? UUID().uuidString.lowercased()
            canonicalInput["operationId"] = .string(operationID)
            macOperationID = operationID
        } else {
            macOperationID = nil
        }
        let result: JSONValue
        do {
            result = try await dispatchWithoutOrganismPosture(
                tool: tool,
                input: canonicalInput,
                surface: surface
            )
        } catch {
            // MacControl can durably settle a failed operation before its client
            // throws. Preserve the identity we supplied and let the canonical
            // operation store return that exact terminal consequence.
            if let macOperationID,
               let reference = ToolCausalBoundary.motorReference(
                   tool: tool,
                   ownerActionID: macOperationID
               ) {
                await motorOutcomeObserver(reference)
            }
            throw error
        }
        let enriched = await resultByAddingOrganismPosture(result, tool: tool, surface: surface)
        schedulePrewarmAfterToolResult(
            tool: tool,
            input: canonicalInput,
            result: enriched,
            surface: surface
        )
        await observeMotorOutcomeIfNeeded(tool: tool, result: enriched)
        return enriched
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
        surface: String
    ) {
        let hints = Self.prewarmHints(
            tool: tool,
            input: input,
            result: result,
            surface: surface
        )
        guard !hints.isEmpty else { return }
        let prewarm = self.contextPrewarm
        prewarmRelay.enqueue {
            for hint in hints {
                await prewarm(hint.kind, hint.id, hint.terms)
            }
        }
    }

    struct ContextPrewarmHint: Sendable {
        var kind: ContextPrewarmHintKind
        var id: String
        var terms: [String]
    }

    /// Pure function of the settled tool call — same inputs, same hints, in the
    /// same order as the old inline `await` pair emitted them.
    static func prewarmHints(
        tool: String,
        input: [String: JSONValue],
        result: JSONValue,
        surface: String
    ) -> [ContextPrewarmHint] {
        let canonical = Self.canonicalAppToolName(tool) ?? tool
        let terms = [canonical, surface]
            + input.keys.sorted()
            + Self.resultKeys(result)
        let kind: ContextPrewarmHintKind
        let id: String
        if canonical.hasPrefix("desk_") {
            kind = .desk
            id = "agent-desk"
        } else if Self.fileContextTools.contains(canonical) {
            kind = .file
            id = Self.inputString(input["path"]) ?? canonical
        } else {
            kind = .toolResult
            id = canonical
        }
        var hints = [ContextPrewarmHint(kind: kind, id: id, terms: terms)]
        if case .object(let object) = result, object["organism_posture"] != nil {
            hints.append(ContextPrewarmHint(kind: .organism, id: "tool-posture", terms: terms))
        }
        return hints
    }

    /// Wait for every prewarm hint enqueued so far to reach the coordinator.
    /// Tests and shutdown only — the dispatch path must never call this.
    func drainPendingContextPrewarm() async {
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
        let securityTool = Self.canonicalAppToolName(tool) ?? tool
        let envelope = await securityCenter.evaluateTool(
            tool: securityTool,
            input: input,
            origin: Self.securityOrigin(input: input, surface: surface),
            enforceAutonomy: enforceAutonomySecurity
        )
        try? await securityCenter.record(envelope)
        guard envelope.allowed else {
            return Self.securityGateResponse(envelope)
        }

        // B5 (tightness-sweep 2026-07-17) — SINGLE OWNER of notify on wrapped
        // chat surfaces. Core's SwiftToolDispatcher also has `mac_notify` /
        // `mobile_notify` cases, and BOTH ultimately reach the identical
        // backends: `NativeAgentNotifications.postAndReport` (Mac) and
        // `MacSyncEngine.shared.sendNotificationToPairedDevices` (iOS) — the
        // shim via its injected senders, core via the injected
        // `MacIntegrationBridgeImpl`. There is no second device registry; the
        // finding's "two backends" is really two code paths to one backend.
        //
        // On any surface wrapped by this dispatcher, this interception returns
        // BEFORE `inner.dispatch`, so core's cases are shadowed and never run.
        // That makes the shim the canonical owner here — it also canonicalizes
        // the provider-safe aliases (mobile_notify / iphone.notify / apns.notify
        // / push.notify → mobile.notify; mac_notify / native.notify →
        // mac.notify), which core's exact-string cases would miss. Core's cases
        // are retained for the unwrapped path (a bare SwiftToolDispatcher with a
        // bridge injected but no app shim). Do NOT add notify logic to only one
        // side — keep the backends and the permission gate in sync across both.
        // Proven by `appChatToolDispatcher_notifyIsSingleOwner_innerNeverReached`
        // (NativeAgentAppTests) and MacIntegrationBridgeImpl.macNotify/mobileNotify.
        switch Self.canonicalNotificationToolName(tool) {
        case "mobile.notify":
            // gpt-5.5 review BLOCKING: this path bypasses the Core dispatcher's
            // MacIntegration gate. Check the gate here so the user's "iPhone
            // Notifications" Write toggle actually denies the call.
            let allowed = await MacIntegrationPermissionStore.shared.allows(MacIntegrationID.notifyMobile, mode: .write)
            guard allowed else {
                return Self.macIntegrationDeniedEnvelope(integration: MacIntegrationID.notifyMobile, mode: "write")
            }
            return try await runMobileNotify(input: input, surface: surface)
        case "mac.notify":
            let allowed = await MacIntegrationPermissionStore.shared.allows(MacIntegrationID.notifyMac, mode: .write)
            guard allowed else {
                return Self.macIntegrationDeniedEnvelope(integration: MacIntegrationID.notifyMac, mode: "write")
            }
            return try await runMacNotify(input: input, surface: surface)
        default:
            break
        }
        if let browserTool = Self.canonicalBrowserToolName(tool) {
            return try await runBrowserTool(actionId: browserTool, input: input, surface: surface)
        }
        if let healthTool = Self.canonicalHealthToolName(tool) {
            return try await runHealthStatusTool(tool: healthTool, surface: surface)
        }
        if Self.canonicalReflexToolName(tool) == "reflex_review" {
            return await runReflexReview(input: input, surface: surface)
        }

        switch tool {
        case "tool_catalog", "list_tools":
            return try await toolCatalog(input: input, surface: surface)
        case "tool_load":
            if Self.hasResearchCategory(input) {
                var appInput = input
                appInput["names"] = .array(Self.browserToolNames.map { .string($0) })
                appInput["category"] = nil
                return try await toolLoad(input: appInput)
            }
            if Self.isAppToolLoadRequest(input) {
                let requested = Self.requestedToolLoadNames(input)
                let app = requested.compactMap { Self.canonicalAppToolName($0) }
                let other = requested.filter { Self.canonicalAppToolName($0) == nil }
                if other.isEmpty {
                    // Pure app-tool load — app loader handles it fully.
                    return try await toolLoad(input: input)
                }
                // MIXED batch (loop-C finding 2026-06-13). The old code
                // short-circuited the WHOLE call into the notification-only
                // loader on ANY notification name, so non-notification tools
                // (e.g. read_file) in the same batch were silently dropped and
                // never registered. Split: load the app-tool subset via the
                // app bridge, forward the rest to the core dispatcher, merge.
                return try await dispatchMixedToolLoad(input: input, app: app, other: other, surface: surface)
            }
        default:
            break
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    private func resultByAddingOrganismPosture(_ result: JSONValue, tool: String, surface: String) async -> JSONValue {
        guard case .object(var object) = result,
              object["organism_posture"] == nil,
              let posture = await organismPostureProvider()
        else {
            return result
        }
        object["organism_posture"] = posture.toolResultJSON(tool: tool, surface: surface)
        return .object(object)
    }

    func listAvailableTools() async throws -> [String] {
        var names = try await inner.listAvailableTools()
        guard includeAppOwnedTools else { return names.sorted() }
        let existing = Set(names)
        names.append(contentsOf: Self.appToolNames.filter { !existing.contains($0) })
        return names.sorted()
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        var schemas = try await inner.listAvailableToolSchemas()
        guard includeAppOwnedTools else { return schemas.sorted { $0.name < $1.name } }
        let existing = Set(schemas.map(\.name))
        schemas.append(contentsOf: Self.appToolSchemas().filter { !existing.contains($0.name) })
        return schemas.sorted { $0.name < $1.name }
    }

    private func runMacNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let title = NativeAgentNotificationDefaults.title(Self.inputString(input["title"]))
        let message = try Self.requiredMessage(input, toolName: "mac.notify")
        let result = try await macNotificationSender(title, message)
        var obj = result.deliveryFields()
        obj.merge([
            "tool": .string("mac.notify"),
            "surface": .string(surface),
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    private func runMobileNotify(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let title = NativeAgentNotificationDefaults.title(Self.inputString(input["title"]))
        let message = try Self.requiredMessage(input, toolName: "mobile.notify")
        let screen = Self.inputString(input["screen"]) ?? "inbox"
        let source = Self.inputString(input["source"]) ?? "chat_tool"
        let urgency = Self.inputString(input["urgency"]) ?? "normal"
        let receipt = try await mobileNotificationSender(title, message, [
            "screen": screen,
            "source": source,
            "urgency": urgency,
            "surface": surface,
        ])
        var obj = receipt.deliveryFields()
        obj.merge([
            "tool": .string("mobile.notify"),
            "surface": .string(surface),
            "screen": .string(screen),
            "source": .string(source),
            "urgency": .string(urgency),
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    private func runBrowserTool(actionId: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let dryRun = Self.inputBool(input["dryRun"] ?? input["dry_run"], default: false)
        let result = try await browserActionRunner(actionId, dryRun, input)
        guard case .object(var obj) = result else {
            return result
        }
        obj["tool"] = .string(actionId)
        obj["provider_alias"] = .string(Self.providerAlias(for: actionId))
        obj["surface"] = .string(surface)
        return .object(obj)
    }

    private func runHealthStatusTool(tool: String, surface: String) async throws -> JSONValue {
        let result: JSONValue
        switch tool {
        case "doctor_status":
            result = try await doctorStatusProvider()
        case "telegram_status":
            result = try await telegramStatusProvider()
        default:
            // Unreachable: the only caller gates on `canonicalHealthToolName`,
            // which maps exclusively to doctor_status / telegram_status. Assert
            // the invariant in debug; still fail closed with an honest envelope
            // in release rather than crashing a chat turn.
            assertionFailure("runHealthStatusTool reached with non-health tool \(tool); canonicalHealthToolName should gate this")
            return .object([
                "status": .string("error"),
                "error": .string("unsupported_health_tool"),
                "tool": .string(tool),
            ])
        }
        guard case .object(var object) = result else { return result }
        object["tool"] = .string(tool)
        object["runtime"] = .string("swift-native")
        object["surface"] = .string(surface)
        object["read_only"] = .bool(true)
        return .object(object)
    }

    private func runReflexReview(input: [String: JSONValue], surface: String) async -> JSONValue {
        let candidateID = Self.inputString(input["candidate_id"] ?? input["candidateId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidateID.isEmpty else {
            return Self.reflexReviewError(
                status: "invalid_input",
                candidateID: nil,
                decision: nil,
                message: "reflex_review requires candidate_id"
            )
        }
        let rawDecision = Self.inputString(input["decision"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard let decision = OrganismReflexReviewDecision(rawValue: rawDecision),
              decision == .approve || decision == .hold || decision == .reject
        else {
            return Self.reflexReviewError(
                status: "invalid_input",
                candidateID: candidateID,
                decision: rawDecision.isEmpty ? nil : rawDecision,
                message: "decision must be approve, hold, or reject"
            )
        }
        let note = Self.inputString(input["note"])
        let outcome = await reflexReviewHandler(candidateID, decision, note, surface)
        guard outcome.applied,
              let receipt = outcome.receipt,
              let candidate = outcome.candidate
        else {
            return Self.reflexReviewError(
                status: outcome.status.rawValue,
                candidateID: candidateID,
                decision: decision.rawValue,
                message: outcome.error ?? "The reflex review was not applied."
            )
        }
        return .object([
            "status": .string("reviewed"),
            "applied": .bool(true),
            "runtime": .string("swift-native"),
            "candidate_id": .string(candidate.id),
            "decision": .string(decision.rawValue),
            "candidate": Self.reflexCandidateJSON(candidate),
            "receipt": Self.reflexReviewReceiptJSON(receipt),
        ])
    }

    private func toolCatalog(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let fullDetail = Self.inputString(input["detail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "full"
        let innerCatalog = try await inner.dispatch(tool: "tool_catalog", input: input, surface: surface)
        let names = try await listAvailableTools()
        var obj: [String: JSONValue]
        if case .object(let base) = innerCatalog {
            obj = base
        } else {
            obj = [
                "status": .string("ok"),
                "runtime": .string("swift-native"),
            ]
        }

        var rows: [JSONValue] = []
        var rowNames: Set<String> = []
        if case .array(let existing)? = obj["tools"] {
            rows = existing
            for row in existing {
                if case .object(let rowObj) = row,
                   case .string(let name)? = rowObj["name"] {
                    rowNames.insert(name)
                }
            }
        }
        let sessionId = Self.extractSessionId(input)
        let persistedActive: Set<String> = sessionId.isEmpty
            ? []
            : await activeToolsStore.load(sessionId: sessionId).activeTools
        let turnScoped = LLMCallContext.turnActiveTools ?? []
        let sessionActive = persistedActive.union(turnScoped)
        let appNameSet = Set(Self.appToolNames)
        let loadedAppTools = appNameSet.intersection(sessionActive)
        let discoveryAppTools = appNameSet.subtracting(sessionActive)
        var loadedNames = Self.jsonStringArray(obj["currently_loaded"])
        var discoveryNames = Self.jsonStringArray(obj["discovery_only_tools"])
        Self.mergeStrings(loadedAppTools, into: &loadedNames)
        Self.mergeStrings(discoveryAppTools, into: &discoveryNames)
        let loadedSet = Set(loadedNames)

        if fullDetail {
            for schema in Self.appToolSchemas() where !rowNames.contains(schema.name) {
                rows.append(Self.toolCatalogRow(schema))
            }
            rows = rows.map { row in
                guard case .object(var rowObj) = row,
                      case .string(let name)? = rowObj["name"],
                      appNameSet.contains(name)
                else { return row }
                rowObj["load_state"] = .string(loadedSet.contains(name) ? "loaded" : "discovery_only")
                return .object(rowObj)
            }
        } else {
            rows.removeAll(keepingCapacity: false)
        }

        var capabilityRows: [JSONValue] = []
        capabilityRows.reserveCapacity(rows.count)
        let sideEffectCapabilities: Set<String> = [
            "approval_stage", "app_data_write", "evolution_apply_trigger",
            "evolution_write", "external_send", "file_write", "mac_control",
            "money", "network_write", "notification", "outside_app_data_write",
            "shell", "skill_write", "system_control",
        ]
        for row in rows {
            guard case .object(var rowObj) = row,
                  case .string(let name)? = rowObj["name"] else {
                capabilityRows.append(row)
                continue
            }
            let securityTool = Self.canonicalAppToolName(name) ?? name
            let envelope = await securityCenter.evaluateTool(
                tool: securityTool,
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
            rowObj["side_effects"] = .bool(
                !sideEffectCapabilities.isDisjoint(with: envelope.capabilities)
            )
            rowObj["available_now"] = .bool(envelope.decision != .block)
            rowObj["input_schema"] = rowObj["parameters"] ?? .object([:])
            capabilityRows.append(.object(rowObj))
        }
        rows = capabilityRows

        obj["status"] = .string("ok")
        obj["runtime"] = .string("swift-native")
        obj["catalog_detail"] = .string(fullDetail ? "full" : "compact")
        let groupIndex = ToolPreloadHeuristics.groupIndex(
            availableToolNames: Set(names)
        )
        obj["tool_groups"] = .object(groupIndex.mapValues { names in
            .array(names.map { .string($0) })
        })
        obj["app_tools"] = .bool(true)
        // 2026-06-08 lazy-tool-skill-loading bug: this wrapper was previously
        // overwriting lazy_load → false AND currently_loaded → ALL names, which
        // trashed the filtered values the inner SwiftToolDispatcher.impl_tool_catalog
        // had just computed. Let inner's values win for those two fields.
        // The app-side overlay adds app-owned tools to the same lazy-load
        // fields as core: available_tools/tools, plus app-tool entries in
        // currently_loaded or discovery_only_tools based on this session's
        // ActiveToolsStore state.
        obj["permission_source"] = obj["permission_source"] ?? .string("trust/policy.json")
        obj["notification_tools"] = .array(Self.notificationToolNames.map { .string($0) })
        obj["browser_tools"] = .array(Self.browserToolNames.map { .string($0) })
        obj["health_tools"] = .array(Self.healthToolNames.map { .string($0) })
        obj["organism_tools"] = .array(Self.organismToolNames.map { .string($0) })
        obj["currently_loaded"] = .array(loadedNames.sorted().map { .string($0) })
        obj["turn_active_tools"] = .array(turnScoped.sorted().map { .string($0) })
        obj["discovery_only_tools"] = .array(discoveryNames.sorted().map { .string($0) })
        obj["available_tools"] = .array(names.map { .string($0) })
        obj["tools"] = .array(rows)
        return .object(obj)
    }

    private func toolLoad(input: [String: JSONValue]) async throws -> JSONValue {
        let requested = Self.appToolLoadNames(input)
        let available = Set(try await listAvailableTools())
        let loaded = requested.filter { available.contains($0) }.sorted()
        let unavailable = requested.filter { !available.contains($0) }.sorted()
        let sessionId = Self.inputString(input["session_id"] ?? input["__session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sessionActive: Set<String> = Set(loaded)
        var loadedNow = loaded
        var alreadyActive: [String] = []
        var turnActive: [String] = []
        var sessionActiveCount = sessionActive.count
        var status = unavailable.isEmpty ? "loaded" : "partial"
        if let sessionId, !sessionId.isEmpty {
            let existing = await activeToolsStore.load(sessionId: sessionId).activeTools
            let turnScoped = LLMCallContext.turnActiveTools ?? []
            let effectiveExisting = existing.union(turnScoped)
            alreadyActive = loaded.filter { effectiveExisting.contains($0) }
            turnActive = loaded.filter { turnScoped.contains($0) }
            loadedNow = loaded.filter { !effectiveExisting.contains($0) }
            if loadedNow.isEmpty {
                sessionActive = existing
            } else {
                let state = try await activeToolsStore.addLoaded(
                    sessionId: sessionId,
                    names: Set(loadedNow)
                )
                sessionActive = state.activeTools
            }
            sessionActiveCount = sessionActive.count
        } else {
            status = unavailable.isEmpty ? "ok" : "partial"
        }
        let activeForTurn = sessionActive.union(LLMCallContext.turnActiveTools ?? [])
        let activeTools = SwiftToolDispatcher.alwaysOnCoreNames.union(activeForTurn).sorted()
        let schemasAdded = Self.appToolSchemas()
            .filter { loadedNow.contains($0.name) }
            .map { schema -> JSONValue in
                var row: [String: JSONValue] = [
                    "name": .string(schema.name),
                    "description": .string(schema.description),
                ]
                if let parsed = try? JSONValue.parse(schema.parametersJSON) {
                    row["parameters"] = parsed
                }
                return .object(row)
            }
        return .object([
            "status": .string(status),
            "runtime": .string("swift-native"),
            "mode": .string(sessionId?.isEmpty == false ? "persisted_session_load" : "sessionless_preview"),
            "category": .string(Self.appToolLoadCategory(input: input, loaded: loaded)),
            "session_id": sessionId.map { .string($0) } ?? .null,
            "requested": .array(requested.map { .string($0) }),
            "loaded_now": .array(loadedNow.map { .string($0) }),
            "loaded": .array(loaded.map { .string($0) }),
            "unavailable": .array(unavailable.map { .string($0) }),
            "already_active": .array(alreadyActive.map { .string($0) }),
            "turn_active": .array(turnActive.map { .string($0) }),
            "session_active_count": .int(Int64(sessionActiveCount)),
            "active_tools": .array(activeTools.map { .string($0) }),
            "schemas_added": .array(schemasAdded),
            "next_turn_note": .string(loadedNow.isEmpty && !turnActive.isEmpty
                ? "Requested app-tool schemas are already available for this turn; no session loadout changed."
                : "These app-tool schemas will be available in the next response's tool list."),
            "message": .string("App tools route through the Mac app bridge. Browser tools use the visible NativeAgent WKWebView and keep navigation/read/screenshot receipts."),
        ])
    }

    /// Mixed `tool_load` (app-tool + non-app names in one call):
    /// load the app-tool subset via the app bridge AND forward the rest to
    /// the core dispatcher, then merge both response envelopes. Both writers
    /// persist their own subset to the SAME session store under its flock, so
    /// the session's active set ends up the union regardless of order.
    private func dispatchMixedToolLoad(
        input: [String: JSONValue],
        app: [String],
        other: [String],
        surface: String
    ) async throws -> JSONValue {
        let sessionId = Self.inputString(input["session_id"] ?? input["__session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // App-tool subset → app loader. Build a clean names-only input so the
        // loader sees exactly these app-tool names and excludes delegated core
        // names. An app category is carried through so category loads such as
        // "browser" still load the whole group.
        var appInput: [String: JSONValue] = [:]
        if let sessionId, !sessionId.isEmpty { appInput["session_id"] = .string(sessionId) }
        if !app.isEmpty { appInput["names"] = .array(app.map { .string($0) }) }
        if Self.hasAppToolCategory(input), let cat = input["category"] { appInput["category"] = cat }
        let appEnv = try await toolLoad(input: appInput)
        // Non-app subset → core dispatcher. Names-only; the singular
        // `name` and any category are stripped so nothing leaks across.
        var innerInput = input
        innerInput["names"] = .array(other.map { .string($0) })
        innerInput["name"] = nil
        innerInput["category"] = nil
        let innerEnv = try await inner.dispatch(tool: "tool_load", input: innerInput, surface: surface)
        var merged = Self.mergeToolLoadEnvelopes(appEnv, innerEnv)
        // Authoritative active_tools: core tool_load does NOT echo active_tools
        // (gpt-5.5 review), so the two-envelope union would omit the forwarded
        // tools. Re-read the session store for the true active set.
        if let sessionId, !sessionId.isEmpty, case .object(var obj) = merged {
            let active = SwiftToolDispatcher.alwaysOnCoreNames
                .union(await activeToolsStore.load(sessionId: sessionId).activeTools)
                .union(LLMCallContext.turnActiveTools ?? [])
                .sorted()
            obj["active_tools"] = .array(active.map { .string($0) })
            merged = .object(obj)
        }
        return merged
    }

    /// Merge two `tool_load` response envelopes: union the string-array fields
    /// and the schemas, and report "partial" if either side was partial or
    /// listed anything unavailable.
    private static func mergeToolLoadEnvelopes(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        guard case .object(let ao) = a else { return b }
        guard case .object(let bo) = b else { return a }
        func strArray(_ o: [String: JSONValue], _ k: String) -> [String] {
            guard case .array(let arr)? = o[k] else { return [] }
            return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        func unionSorted(_ k: String) -> JSONValue {
            var seen = Set<String>()
            var out: [String] = []
            for s in strArray(ao, k) + strArray(bo, k) where seen.insert(s).inserted { out.append(s) }
            return .array(out.sorted().map { .string($0) })
        }
        func statusString(_ o: [String: JSONValue]) -> String? {
            if case .string(let s)? = o["status"] { return s }
            return nil
        }
        func mergedSchemas() -> JSONValue {
            var seen = Set<String>()
            var out: [JSONValue] = []
            for env in [ao, bo] {
                guard case .array(let arr)? = env["schemas_added"] else { continue }
                for row in arr {
                    if case .object(let r) = row, case .string(let n)? = r["name"] {
                        if seen.insert(n).inserted { out.append(row) }
                    } else {
                        out.append(row)
                    }
                }
            }
            return .array(out)
        }
        // Any non-ok status (failed/partial/unknown) on either side, or any
        // unavailable name, degrades the merged result — a delegated failure
        // (e.g. core "failed: missing_session_id") must NOT read as "loaded"
        // (gpt-5.5 review).
        func nonOk(_ s: String?) -> Bool {
            guard let s else { return false }
            return s != "loaded" && s != "ok"
        }
        let degraded = !strArray(ao, "unavailable").isEmpty
            || !strArray(bo, "unavailable").isEmpty
            || nonOk(statusString(ao))
            || nonOk(statusString(bo))
        var merged = bo
        merged["status"] = .string(degraded ? "partial" : "loaded")
        merged["runtime"] = .string("swift-native")
        merged["category"] = .string("mixed")
        merged["requested"] = unionSorted("requested")
        merged["loaded"] = unionSorted("loaded")
        merged["loaded_now"] = unionSorted("loaded_now")
        merged["unavailable"] = unionSorted("unavailable")
        merged["already_active"] = unionSorted("already_active")
        merged["turn_active"] = unionSorted("turn_active")
        merged["active_tools"] = unionSorted("active_tools")
        merged["schemas_added"] = mergedSchemas()
        // Surface a failure reason/fix from either side rather than swallowing
        // it. merged starts as `bo`, so bo's keys are already present; only
        // pull from `ao` when bo carried none.
        if merged["reason"] == nil, case .string(let r)? = ao["reason"] {
            merged["reason"] = .string(r)
        }
        if merged["fix"] == nil, case .string(let f)? = ao["fix"] {
            merged["fix"] = .string(f)
        }
        merged["message"] = .string("Mixed tool_load: app tools loaded via the Mac app bridge; other tools via the core dispatcher.")
        return .object(merged)
    }

    private static let notificationToolNames = ["mac.notify", "mobile.notify"]
    private static let browserToolNames = [
        "browser.status",
        "browser.open_url",
        "browser.navigate",
        "browser.read_text",
        "browser.read_links",
        "browser.screenshot",
        "browser.chrome_acquire",
        "browser.chrome_navigate",
        "browser.chrome_snapshot",
        "browser.chrome_click",
        "browser.chrome_fill",
        "browser.chrome_type",
        "browser.chrome_select",
        "browser.chrome_keypress",
        "browser.chrome_set_checked",
        "browser.chrome_double_click",
        "browser.chrome_wait",
        "browser.chrome_scroll",
        "browser.chrome_release",
    ]
    private static let healthToolNames = ["doctor_status", "telegram_status"]
    private static let organismToolNames = ["reflex_review"]
    private static var appToolNames: [String] {
        notificationToolNames + browserToolNames + healthToolNames + organismToolNames
    }

    /// Same envelope shape the Core dispatcher's MacIntegration permission
    /// gate produces — keeps the surface uniform regardless of which path
    /// caught the call.
    private static func macIntegrationDeniedEnvelope(integration: String, mode: String) -> JSONValue {
        .object([
            "status": .string("denied"),
            "reason": .string("integration_permission_denied"),
            "integration": .string(integration),
            "mode": .string(mode),
            "fix": .string("Toggle \(mode.capitalized) ON for \(integration) in Settings → Mac Integration."),
        ])
    }

    private static let notificationCategoryNames: Set<String> = [
        "notification", "notifications", "notify",
        "mobile", "ios", "iphone", "apns", "push", "push_notifications",
    ]
    private static let browserCategoryNames: Set<String> = [
        "browser", "browsing", "visible_browser", "visible-browser", "web", "webpage", "page",
    ]
    private static let researchCategoryNames: Set<String> = [
        "research", "web_search", "search", "news",
    ]
    private static let healthCategoryNames: Set<String> = [
        "health", "diagnostics", "system_health", "runtime_health",
    ]
    private static let organismCategoryNames: Set<String> = [
        "organism", "reflex", "reflexes", "reflex_review",
    ]

    private static func canonicalNotificationToolName(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mobile.notify", "mobile_notify", "iphone.notify", "iphone_notify", "ios.notify", "ios_notify", "apns.notify", "apns_notify", "push.notify", "push_notify":
            return "mobile.notify"
        case "mac.notify", "mac_notify", "native.notify", "native_notify":
            return "mac.notify"
        default:
            return nil
        }
    }

    private static func canonicalBrowserToolName(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "browser.status", "browser_status", "browser.get_status", "browser_get_status":
            return "browser.status"
        case "browser.open_url", "browser_open_url", "browser.open", "browser_open":
            return "browser.open_url"
        case "browser.navigate", "browser_navigate", "navigate_browser":
            return "browser.navigate"
        case "browser.read_text", "browser_read_text", "browser.text", "browser_text", "browser_get_text", "browser.dom_text", "browser_dom_text":
            return "browser.read_text"
        case "browser.read_links", "browser_read_links", "browser.links", "browser_links":
            return "browser.read_links"
        case "browser.screenshot", "browser_screenshot", "browser.capture_screenshot", "browser_capture_screenshot":
            return "browser.screenshot"
        case "browser.chrome_acquire", "browser_chrome_acquire", "chrome.acquire", "chrome_acquire":
            return "browser.chrome_acquire"
        case "browser.chrome_navigate", "browser_chrome_navigate", "chrome.navigate", "chrome_navigate":
            return "browser.chrome_navigate"
        case "browser.chrome_snapshot", "browser_chrome_snapshot", "chrome.snapshot", "chrome_snapshot":
            return "browser.chrome_snapshot"
        case "browser.chrome_click", "browser_chrome_click", "chrome.click", "chrome_click":
            return "browser.chrome_click"
        case "browser.chrome_fill", "browser_chrome_fill", "chrome.fill", "chrome_fill":
            return "browser.chrome_fill"
        case "browser.chrome_type", "browser_chrome_type", "chrome.type", "chrome_type":
            return "browser.chrome_type"
        case "browser.chrome_select", "browser_chrome_select", "chrome.select", "chrome_select":
            return "browser.chrome_select"
        case "browser.chrome_keypress", "browser_chrome_keypress", "chrome.keypress", "chrome_keypress":
            return "browser.chrome_keypress"
        case "browser.chrome_set_checked", "browser_chrome_set_checked", "chrome.set_checked", "chrome_set_checked":
            return "browser.chrome_set_checked"
        case "browser.chrome_double_click", "browser_chrome_double_click", "chrome.double_click", "chrome_double_click":
            return "browser.chrome_double_click"
        case "browser.chrome_wait", "browser_chrome_wait", "chrome.wait", "chrome_wait":
            return "browser.chrome_wait"
        case "browser.chrome_scroll", "browser_chrome_scroll", "chrome.scroll", "chrome_scroll":
            return "browser.chrome_scroll"
        case "browser.chrome_release", "browser_chrome_release", "chrome.release", "chrome_release":
            return "browser.chrome_release"
        default:
            return nil
        }
    }

    private static func canonicalHealthToolName(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "doctor_status", "doctor.status":
            return "doctor_status"
        case "telegram_status", "telegram.status":
            return "telegram_status"
        default:
            return nil
        }
    }

    private static func canonicalReflexToolName(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "reflex_review", "reflex.review":
            return "reflex_review"
        default:
            return nil
        }
    }

    private static func canonicalAppToolName(_ raw: String) -> String? {
        canonicalNotificationToolName(raw)
            ?? canonicalBrowserToolName(raw)
            ?? canonicalHealthToolName(raw)
            ?? canonicalReflexToolName(raw)
    }

    /// All raw requested tool names from a `tool_load` input — both the `names`
    /// array AND the schema-supported singular `name` — un-canonicalized and
    /// trimmed (empties dropped). Mirrors core impl_tool_load, which reads both
    /// (gpt-5.5 review); used to detect mixed batches and the non-notif subset.
    private static func requestedToolLoadNames(_ input: [String: JSONValue]) -> [String] {
        var out: [String] = []
        if case .array(let vals)? = input["names"] {
            out.append(contentsOf: vals
                .compactMap { inputString($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }
        if let single = inputString(input["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !single.isEmpty {
            out.append(single)
        }
        return out
    }

    private static func extractSessionId(_ input: [String: JSONValue]) -> String {
        for key in ["__session_id", "session_id", "sessionId"] {
            if let raw = inputString(input[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return ""
    }

    private static func jsonStringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { inputString($0) }
    }

    private static func mergeStrings(_ values: Set<String>, into output: inout [String]) {
        var seen = Set(output)
        for value in values where seen.insert(value).inserted {
            output.append(value)
        }
    }

    private static func hasNotificationCategory(_ input: [String: JSONValue]) -> Bool {
        guard let category = inputString(input["category"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return notificationCategoryNames.contains(category)
    }

    private static func hasBrowserCategory(_ input: [String: JSONValue]) -> Bool {
        guard let category = inputString(input["category"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return browserCategoryNames.contains(category)
    }

    private static func hasResearchCategory(_ input: [String: JSONValue]) -> Bool {
        guard let category = inputString(input["category"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return researchCategoryNames.contains(category)
    }

    private static func hasOrganismCategory(_ input: [String: JSONValue]) -> Bool {
        guard let category = inputString(input["category"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return organismCategoryNames.contains(category)
    }

    private static func hasHealthCategory(_ input: [String: JSONValue]) -> Bool {
        guard let category = inputString(input["category"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return healthCategoryNames.contains(category)
    }

    private static func hasAppToolCategory(_ input: [String: JSONValue]) -> Bool {
        hasNotificationCategory(input)
            || hasBrowserCategory(input)
            || hasHealthCategory(input)
            || hasOrganismCategory(input)
    }

    private static func isAppToolLoadRequest(_ input: [String: JSONValue]) -> Bool {
        if hasAppToolCategory(input) { return true }
        return requestedToolLoadNames(input).contains { canonicalAppToolName($0) != nil }
    }

    private static func appToolLoadNames(_ input: [String: JSONValue]) -> [String] {
        var requested: [String] = []
        if case .array(let vals)? = input["names"] {
            for value in vals {
                guard let raw = inputString(value),
                      let canonical = canonicalAppToolName(raw) else { continue }
                requested.append(canonical)
            }
        }
        if let single = inputString(input["name"]),
           let canonical = canonicalAppToolName(single) {
            requested.append(canonical)
        }
        if let category = inputString(input["category"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           notificationCategoryNames.contains(category) {
            requested.append(contentsOf: notificationToolNames)
        }
        if let category = inputString(input["category"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           browserCategoryNames.contains(category) {
            requested.append(contentsOf: browserToolNames)
        }
        if let category = inputString(input["category"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           healthCategoryNames.contains(category) {
            requested.append(contentsOf: healthToolNames)
        }
        if let category = inputString(input["category"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           organismCategoryNames.contains(category) {
            requested.append(contentsOf: organismToolNames)
        }
        if requested.isEmpty {
            requested = appToolNames
        }
        var seen: Set<String> = []
        return requested.filter { seen.insert($0).inserted }
    }

    private static func appToolLoadCategory(input: [String: JSONValue], loaded: [String]) -> String {
        if hasNotificationCategory(input), !hasBrowserCategory(input) { return "notifications" }
        if hasBrowserCategory(input), !hasNotificationCategory(input) { return "browser" }
        let loadedSet = Set(loaded)
        if loadedSet.isSubset(of: Set(notificationToolNames)) { return "notifications" }
        if loadedSet.isSubset(of: Set(browserToolNames)) { return "browser" }
        if loadedSet.isSubset(of: Set(healthToolNames)) { return "health" }
        if loadedSet.isSubset(of: Set(organismToolNames)) { return "organism" }
        return "app"
    }

    private static func securityOrigin(input: [String: JSONValue], surface: String) -> SecurityOriginContext {
        let _ = input
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        // Prefer the transport-verified chatId (covers UUID telegram sessions
        // where the id can't be parsed from the session string); fall back to
        // the legacy `telegram:<chatId>` session form. Mirrors the authoritative
        // gate's resolution so both reach the same trust. See ChatToolSessionContext.
        let verifiedChatId = ChatToolSessionContext.verifiedChatId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChatId = (verifiedChatId?.isEmpty == false)
            ? verifiedChatId
            : telegramChatId(fromSessionId: usableSessionId)
        return SecurityOriginContext(
            surface: surface,
            sessionId: usableSessionId,
            userId: ChatToolSessionContext.verifiedUserId,
            chatId: resolvedChatId,
            deviceId: nil,
            source: "app_chat_tool_dispatcher",
            isRemote: ["telegram", "slack", "ios", "mobile", "remote", "watch"].contains(normalizedSurface),
            commandSignatureVerified: ChatToolSessionContext.commandSignatureVerified
        )
    }

    private static func telegramChatId(fromSessionId sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("telegram:") else { return nil }
        return String(trimmed.dropFirst("telegram:".count))
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
            "reason": .string(primarySecurityReason(envelope.reasons)),
            "reasons": .array(envelope.reasons.map { .string($0) }),
            "capabilities": .array(envelope.capabilities.map { .string($0) }),
            "message": .string(envelope.requiresApproval ? "Security Center requires approval before running this tool." : "Security Center blocked this tool before execution."),
        ])
    }

    private static func primarySecurityReason(_ reasons: [String]) -> String {
        reasons.first { !$0.hasPrefix("autonomy:") }
            ?? reasons.first
            ?? "security policy denied tool execution"
    }

    private static func appToolSchemas() -> [LLMToolSchema] {
        func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
            var d: [String: JSONValue] = [:]
            for (k, v) in pairs { d[k] = v }
            return .object(d)
        }
        func strSchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("string")),
                ("description", .string(desc)),
            ])
        }
        func boolSchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("boolean")),
                ("description", .string(desc)),
            ])
        }
        func intSchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("integer")),
                ("description", .string(desc)),
            ])
        }
        func enumStringSchema(_ values: [String], _ desc: String) -> JSONValue {
            obj([
                ("type", .string("string")),
                ("enum", .array(values.map { .string($0) })),
                ("description", .string(desc)),
            ])
        }
        func stringArraySchema(_ desc: String) -> JSONValue {
            obj([
                ("type", .string("array")),
                ("items", .object(["type": .string("string")])),
                ("minItems", .int(1)),
                ("maxItems", .int(100)),
                ("description", .string(desc)),
            ])
        }
        func params(properties: [(String, JSONValue)], required: [String]) -> Data {
            let v = obj([
                ("type", .string("object")),
                ("properties", obj(properties)),
                ("required", .array(required.map { .string($0) })),
            ])
            return (try? v.serializedData(pretty: false)) ?? Data("{}".utf8)
        }
        return [
            LLMToolSchema(
                name: "mac.notify",
                description: "Post a local macOS notification to the user. Use this only when a short visible Mac alert is useful.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Short notification title. Defaults to the configured assistant name.")),
                        ("message", strSchema("Short notification body.")),
                    ],
                    required: ["message"]
                )
            ),
            LLMToolSchema(
                name: "mobile.notify",
                description: "Send the user a paired-iPhone notification. Public CloudKit builds queue an Apple-presented visual push that does not require the companion app to be open; configured direct APNS remains an optional parallel route. Provider-safe alias: mobile_notify. Use for short attention-worthy updates, not long prose.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Short notification title. Defaults to the configured assistant name.")),
                        ("message", strSchema("Short notification body.")),
                        ("screen", strSchema("iOS screen to open, such as inbox or activity. Defaults to inbox.")),
                        ("source", strSchema("Source label for audit metadata. Defaults to chat_tool.")),
                        ("urgency", strSchema("Urgency label such as normal or urgent. Defaults to normal.")),
                    ],
                    required: ["message"]
                )
            ),
            LLMToolSchema(
                name: "reflex_review",
                description: "Review one live organism reflex candidate through NativeAgent's in-process runtime owner. Approve activates only a low-risk candidate as soft posture bias; hold leaves it inactive while evidence accrues; reject makes it permanently deliberate so it cannot re-propose. Returns a durable reviewer receipt.",
                parametersJSON: params(
                    properties: [
                        ("candidate_id", strSchema("Exact reflex candidate id from organism state, such as tool:tool-grep.")),
                        ("decision", enumStringSchema(
                            ["approve", "hold", "reject"],
                            "Review decision. Approve is low-risk-only; reject is permanent."
                        )),
                        ("note", strSchema("Optional bounded reason recorded with the audit receipt.")),
                    ],
                    required: ["candidate_id", "decision"]
                )
            ),
            LLMToolSchema(
                name: "doctor_status",
                description: "Run NativeAgent's read-only Doctor checks without repairs and return the bounded check results. Use this to verify runtime, storage, persona, memory, iCloud, and installed-app health.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "telegram_status",
                description: "Return a bounded read-only summary of NativeAgent's Telegram configuration and live poller health. Tokens, chat IDs, user IDs, and message contents are never returned.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.status",
                description: "Return visible NativeAgent Browser status and recent browser run receipts. Provider-safe alias: browser_status.",
                parametersJSON: params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.open_url",
                description: "Open an http/https URL in the visible NativeAgent Browser and record a browser run receipt. Provider-safe alias: browser_open_url.",
                parametersJSON: params(
                    properties: [
                        ("url", strSchema("HTTP or HTTPS URL to open.")),
                        ("capture_source", boolSchema("After navigation, capture visible page text to a source receipt. Defaults false.")),
                        ("capture_screenshot", boolSchema("After navigation, capture a PNG screenshot receipt. Defaults false.")),
                        ("dry_run", boolSchema("If true, only record a dry-run browser receipt. Defaults false.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.navigate",
                description: "Navigate the visible NativeAgent Browser to an http/https URL and record a browser run receipt. Provider-safe alias: browser_navigate.",
                parametersJSON: params(
                    properties: [
                        ("url", strSchema("HTTP or HTTPS URL to navigate to.")),
                        ("capture_source", boolSchema("After navigation, capture visible page text to a source receipt. Defaults false.")),
                        ("capture_screenshot", boolSchema("After navigation, capture a PNG screenshot receipt. Defaults false.")),
                        ("dry_run", boolSchema("If true, only record a dry-run browser receipt. Defaults false.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.read_text",
                description: "Read visible page text from the current NativeAgent Browser page and persist a source receipt. Current page must be http/https. Provider-safe alias: browser_read_text.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without reading the page. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.read_links",
                description: "Read links from the current NativeAgent Browser page and persist a link-source receipt. Current page must be http/https. Provider-safe alias: browser_read_links.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without reading links. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.screenshot",
                description: "Capture a PNG screenshot from the current NativeAgent Browser page and persist a screenshot receipt. Current page must be http/https. Provider-safe alias: browser_screenshot.",
                parametersJSON: params(
                    properties: [
                        ("dry_run", boolSchema("If true, record a dry-run receipt without capturing an image. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_acquire",
                description: "Acquire a short-lived real Chrome tab lease. Creates an inactive background tab by default; claiming requires an exact tab id, URL, and title. Chrome control must be on in Trust Center.",
                parametersJSON: params(
                    properties: [
                        ("mode", enumStringSchema(["create", "claim"], "Create an inactive tab or claim an exact existing tab. Defaults create.")),
                        ("initial_url", strSchema("Optional HTTP(S) URL for a created background tab.")),
                        ("tab_id", intSchema("Exact Chrome tab id for claim mode.")),
                        ("expected_url", strSchema("Exact current URL for claim mode.")),
                        ("expected_title", strSchema("Exact current title for claim mode.")),
                        ("lease_duration_ms", intSchema("Lease duration from 30000 through 300000 milliseconds. Defaults 60000.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                description: "Navigate an already-leased real Chrome background tab without activating it.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease; normally 0.")),
                        ("url", strSchema("HTTP(S) destination.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "url"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_snapshot",
                description: "Read a structured agent-friendly snapshot of a leased real Chrome page. Returns bounded readable text and actionable node IDs; password values are omitted.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("max_nodes", intSchema("Maximum structured nodes, 1 through 500.")),
                        ("max_text_chars", intSchema("Maximum readable text characters, 1 through 50000.")),
                    ],
                    required: ["lease_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_click",
                description: "Click one actionable node from the exact structured Chrome snapshot that exposed it.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact snapshot id.")),
                        ("node_id", strSchema("Exact actionable node id.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                description: "Scroll the leased real Chrome page or a scrollable node from a structured snapshot.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Snapshot id when targeting a node.")),
                        ("target_node_id", strSchema("Optional scrollable node id.")),
                        ("delta_x", intSchema("Horizontal scroll delta.")),
                        ("delta_y", intSchema("Vertical scroll delta.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "delta_x", "delta_y"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_fill",
                description: "Replace the value of an editable non-password node from the exact current Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Editable node id that advertised fill.")),
                        ("value", strSchema("Replacement text, at most 50000 characters.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "value"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_type",
                description: "Append text sequentially to an editable non-password node from the exact current Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Editable node id that advertised type.")),
                        ("text", strSchema("Text to append, at most 50000 characters.")),
                        ("delay_ms", intSchema("Optional delay between characters, 0 through 250 milliseconds.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "text"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_select",
                description: "Select one or more exact option values on a native select node from the current frame-aware Chrome snapshot. Returns one outcome receipt.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Select node id that advertised select.")),
                        ("values", stringArraySchema("One or more exact option values; single-select nodes require exactly one.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "values"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_keypress",
                description: "Press one bounded key or chord on a non-password node from the exact current frame-aware Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Node id that advertised keypress.")),
                        ("key", enumStringSchema([
                            "Enter", "Tab", "Shift+Tab", "Escape", "ArrowDown", "ArrowUp",
                            "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown",
                            "Backspace", "Delete", "Space", "Control+A", "Meta+A"
                        ], "Bounded key or chord.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "key"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_set_checked",
                description: "Idempotently set a checkbox, radio, or switch node from the exact current frame-aware Chrome snapshot. Returns one outcome receipt.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Checkable node id that advertised set_checked.")),
                        ("checked", boolSchema("Exact checked state to apply.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id", "checked"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_double_click",
                description: "Double-click one node that advertised double_click in the exact current frame-aware Chrome snapshot. Returns one outcome receipt and never retries an ambiguous dispatch.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("snapshot_id", strSchema("Exact current snapshot id.")),
                        ("node_id", strSchema("Node id that advertised double_click.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "snapshot_id", "node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_wait",
                description: "Wait a bounded time for a current snapshot node state or for leased-tab navigation to settle. Returns one observational outcome receipt.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id from browser.chrome_acquire.")),
                        ("expected_user_sequence", intSchema("User sequence from the lease.")),
                        ("condition", enumStringSchema(["element_state", "navigation_settled"], "Wait condition.")),
                        ("snapshot_id", strSchema("Exact current snapshot id for element_state.")),
                        ("node_id", strSchema("Node id that advertised wait for element_state.")),
                        ("state", enumStringSchema(["visible", "hidden", "enabled", "disabled"], "Required element state.")),
                        ("timeout_ms", intSchema("Bounded timeout from 100 through 10000 milliseconds. Defaults 5000.")),
                        ("settle_ms", intSchema("Extra navigation quiet interval from 0 through 2000 milliseconds.")),
                    ],
                    required: ["lease_id", "expected_user_sequence", "condition"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_release",
                description: "Release a real Chrome tab lease. Claimed and active tabs remain open; an untouched inactive agent-created tab closes by default.",
                parametersJSON: params(
                    properties: [
                        ("lease_id", strSchema("Lease id to release.")),
                        ("close_created_tab", boolSchema("Close an inactive agent-created tab. Defaults true.")),
                    ],
                    required: ["lease_id"]
                )
            ),
        ]
    }

    private static func toolCatalogRow(_ schema: LLMToolSchema) -> JSONValue {
        let category: String
        if browserToolNames.contains(schema.name) {
            category = "browser"
        } else if healthToolNames.contains(schema.name) {
            category = "health"
        } else if organismToolNames.contains(schema.name) {
            category = "organism"
        } else {
            category = "notifications"
        }
        var row: [String: JSONValue] = [
            "name": .string(schema.name),
            "description": .string(schema.description),
            "dispatchable_via": .string("nativeagent_app_tool_dispatcher"),
            "category": .string(category),
            "provider_alias": .string(providerAlias(for: schema.name)),
        ]
        if let params = try? JSONValue.parse(schema.parametersJSON) {
            row["parameters"] = params
        }
        return .object(row)
    }

    private static func providerAlias(for name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    private static func reflexReviewError(
        status: String,
        candidateID: String?,
        decision: String?,
        message: String
    ) -> JSONValue {
        .object([
            "status": .string("error"),
            "applied": .bool(false),
            "runtime": .string("swift-native"),
            "error": .string(status),
            "candidate_id": candidateID.map { .string($0) } ?? .null,
            "decision": decision.map { .string($0) } ?? .null,
            "message": .string(message),
        ])
    }

    private static func reflexCandidateJSON(_ candidate: OrganismReflexCandidate) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return .object([
            "id": .string(candidate.id),
            "pattern": .string(candidate.pattern),
            "trust_class": .string(candidate.trustClass.rawValue),
            "evidence_count": .int(Int64(candidate.evidenceCount)),
            "success_count": .int(Int64(candidate.successCount)),
            "failure_count": .int(Int64(candidate.failureCount)),
            "confidence": .double(candidate.confidence),
            "review_required": .bool(candidate.reviewRequired),
            "auto_activation_allowed": .bool(candidate.autoActivationAllowed),
            "permanently_deliberate": .bool(candidate.isPermanentlyDeliberate),
            "approved_at": candidate.approvedAt.map { .string(iso.string(from: $0)) } ?? .null,
            "rejected_at": candidate.rejectedAt.map { .string(iso.string(from: $0)) } ?? .null,
        ])
    }

    private static func reflexReviewReceiptJSON(_ receipt: OrganismReflexReviewReceipt) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return .object([
            "id": .string(receipt.id),
            "candidate_id": .string(receipt.candidateID),
            "pattern": .string(receipt.pattern),
            "trust_class": .string(receipt.trustClass.rawValue),
            "decision": .string(receipt.decision.rawValue),
            "reviewed_at": .string(iso.string(from: receipt.reviewedAt)),
            "reviewed_by": .string(receipt.reviewedBy),
            "source": .string(receipt.source),
            "note": receipt.note.map { .string($0) } ?? .null,
            "evidence_count": .int(Int64(receipt.evidenceCount)),
            "success_count": .int(Int64(receipt.successCount)),
            "failure_count": .int(Int64(receipt.failureCount)),
            "confidence": .double(receipt.confidence),
            "auto_activation_allowed": .bool(receipt.autoActivationAllowed),
            "permanently_deliberate": .bool(receipt.permanentlyDeliberate),
        ])
    }

    private static func defaultBrowserActionRunner(
        actionId: String,
        dryRun: Bool,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        let client = NativeClient(baseURL: "")
        if actionId.hasPrefix("browser.chrome_") {
            guard !dryRun else {
                return .object(["status": .string("dry_run"), "action": .string(actionId)])
            }
            return try await runChromeControlTool(actionId: actionId, input: input)
        }
        if actionId == "browser.status" {
            let status = try await client.getBrowserStatus()
            return try encodableJSON(status)
        }
        let receipt = try await client.runNativeAction(
            id: actionId,
            dryRun: dryRun,
            input: try jsonObjectToAny(input)
        )
        return try encodableJSON(receipt)
    }

    private static func runChromeControlTool(
        actionId: String,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        let effect: ChromeControlEffect
        var payload: [String: JSONValue] = [:]
        func string(_ key: String) -> String? { inputString(input[key]) }
        func integer(_ key: String) -> Int? {
            switch input[key] {
            case .int(let value): return Int(value)
            case .double(let value): return Int(value)
            case .string(let value): return Int(value)
            default: return nil
            }
        }
        switch actionId {
        case "browser.chrome_acquire":
            effect = .acquire
            let mode = string("mode") ?? "create"
            payload["mode"] = .string(mode)
            if let value = string("initial_url") { payload["initialUrl"] = .string(value) }
            if let value = integer("lease_duration_ms") { payload["leaseDurationMs"] = .int(Int64(value)) }
            if mode == "claim" {
                if let value = integer("tab_id") { payload["tabId"] = .int(Int64(value)) }
                payload["expectedTab"] = .object([
                    "url": .string(string("expected_url") ?? ""),
                    "title": .string(string("expected_title") ?? ""),
                ])
            }
        case "browser.chrome_navigate":
            effect = .navigate
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "url": .string(string("url") ?? ""),
            ]
        case "browser.chrome_snapshot":
            effect = .snapshot
            payload["leaseId"] = .string(string("lease_id") ?? "")
            if let value = integer("max_nodes") { payload["maxNodes"] = .int(Int64(value)) }
            if let value = integer("max_text_chars") { payload["maxTextChars"] = .int(Int64(value)) }
        case "browser.chrome_click":
            effect = .click
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
            ]
        case "browser.chrome_fill":
            effect = .fill
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "value": .string(string("value") ?? ""),
            ]
        case "browser.chrome_type":
            effect = .type
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "text": .string(string("text") ?? ""),
            ]
            if let value = integer("delay_ms") { payload["delayMs"] = .int(Int64(value)) }
        case "browser.chrome_select":
            effect = .select
            let values: [JSONValue]
            if case .array(let supplied)? = input["values"] {
                values = supplied.compactMap { value in
                    guard case .string = value else { return nil }
                    return value
                }
            } else {
                values = []
            }
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "values": .array(values),
            ]
        case "browser.chrome_keypress":
            effect = .keypress
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "key": .string(string("key") ?? ""),
            ]
        case "browser.chrome_set_checked":
            effect = .setChecked
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
                "checked": .bool(inputBool(input["checked"], default: false)),
            ]
        case "browser.chrome_double_click":
            effect = .doubleClick
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "snapshotId": .string(string("snapshot_id") ?? ""),
                "nodeId": .string(string("node_id") ?? ""),
            ]
        case "browser.chrome_wait":
            effect = .wait
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "condition": .string(string("condition") ?? ""),
            ]
            if let value = string("snapshot_id") { payload["snapshotId"] = .string(value) }
            if let value = string("node_id") { payload["nodeId"] = .string(value) }
            if let value = string("state") { payload["state"] = .string(value) }
            if let value = integer("timeout_ms") { payload["timeoutMs"] = .int(Int64(value)) }
            if let value = integer("settle_ms") { payload["settleMs"] = .int(Int64(value)) }
        case "browser.chrome_scroll":
            effect = .scroll
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
                "deltaX": .int(Int64(integer("delta_x") ?? 0)),
                "deltaY": .int(Int64(integer("delta_y") ?? 0)),
            ]
            if let value = string("snapshot_id") { payload["snapshotId"] = .string(value) }
            if let value = string("target_node_id") { payload["targetNodeId"] = .string(value) }
        case "browser.chrome_release":
            effect = .release
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "closeCreatedTab": .bool(inputBool(input["close_created_tab"], default: true)),
            ]
        default:
            throw ChromeControlRuntimeError.invalidResponse
        }
        let response = try await ChromeControlRuntime.shared.perform(effect, payload: payload)
        guard case .object(let object) = response,
              let result = object["result"] else { throw ChromeControlRuntimeError.invalidResponse }
        return result
    }

    private static func defaultDoctorStatusProvider() async throws -> JSONValue {
        let report = try await NativeClient(baseURL: "").runDoctor(repair: false)
        let checks = report.checks.map { check in
            JSONValue.object([
                "id": .string(check.id),
                "title": .string(check.title),
                "status": .string(check.status),
                "detail": .string(NativeAppSecretRedactor.redactText(String(check.detail.prefix(600)))),
                "repair_available": .bool(check.repair?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            ])
        }
        return .object([
            "status": .string(report.status),
            "repaired": .bool(false),
            "check_count": .int(Int64(checks.count)),
            "checks": .array(checks),
        ])
    }

    private static func defaultTelegramStatusProvider() async throws -> JSONValue {
        let status = try await NativeClient(baseURL: "").getTelegramStatus()
        var object: [String: JSONValue] = [
            "status": .string(status.isOperational ? "ok" : "attention"),
            "enabled": .bool(status.enabled),
            "token_configured": .bool(status.tokenConfigured),
            "poller_running": .bool(status.pollerEnabled),
            "require_mention": .bool(status.requireMention),
            "allowed_chat_count": .int(Int64(status.allowedChatIds.count)),
            "allowed_user_count": .int(Int64(status.allowedUserIds.count)),
            "recent_receipt_ledger_entries": .int(Int64(status.receipts.count)),
            "recent_blocked_ledger_entries": .int(Int64(status.blocked.count)),
            "recent_error_ledger_entries": .int(Int64(status.errors.count)),
            "active_error": .bool(status.actionableError != nil),
            "poll_retry_transient": .bool(status.isTransientPollInterruption),
            "consecutive_poll_failures": .int(Int64(status.pollBackoffFailures ?? 0)),
        ]
        object["model"] = status.model.map { .string($0) } ?? .null
        object["reasoning_effort"] = status.reasoningEffort.map { .string($0) } ?? .null
        object["last_seen_at"] = status.lastSeenAt.map { .string($0) } ?? .null
        object["last_reply_at"] = status.lastReplyAt.map { .string($0) } ?? .null
        object["last_error"] = status.lastError.map {
            .string(NativeAppSecretRedactor.redactText(String($0.prefix(600))))
        } ?? .null
        if let voice = status.voiceTranscription {
            object["voice_transcription"] = .object([
                "enabled": .bool(voice.enabled),
                "backend": .string(voice.backend),
                "model": .string(voice.model),
                "backend_supported": .bool(voice.backendSupported),
                "key_configured": .bool(voice.keyConfigured),
            ])
        }
        return .object(object)
    }

    private static func encodableJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONValue.parse(data)
    }

    private static func jsonObjectToAny(_ input: [String: JSONValue]) throws -> [String: Any] {
        let data = try JSONValue.object(input).serializedData(pretty: false)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func requiredMessage(_ input: [String: JSONValue], toolName: String) throws -> String {
        let message = inputString(input["message"])
            ?? inputString(input["body"])
            ?? inputString(input["text"])
            ?? ""
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppNotificationToolError.missingMessage(toolName)
        }
        return message
    }

    private static func inputString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s):
            return s
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        default:
            return nil
        }
    }

    private static func inputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        switch raw {
        case .bool(let b):
            return b
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                return defaultValue
            }
        case .int(let i):
            return i != 0
        case .double(let d):
            return d != 0
        default:
            return defaultValue
        }
    }
}

private enum AppNotificationToolError: LocalizedError {
    case missingMessage(String)

    var errorDescription: String? {
        switch self {
        case .missingMessage(let tool):
            return "\(tool) requires message"
        }
    }
}

/// Canonical app-owned chat wiring for each production conversation surface.
///
/// Keep these policy choices in one place so a new call site cannot silently
/// drift from its siblings by relying on the factory's Boolean defaults. This
/// is only construction policy: authority remains owned by SecurityCenter,
/// TrustCenter, and the per-turn gated dispatcher.
/// Build the app's chat orchestration client.
///
/// `includeEvolutionBridge` (2026-06-11, U4 Wave D): the self-evolution chat
/// tools (evolution_propose / evolution_status / self_install) reach their
/// backend only when this is true. FULLY-AUTONOMOUS turns with no human anywhere
/// in the loop — the reflection/dream/REM background loops, Slack, Telegram,
/// and iOS — pass `false`, so those clients return a `bridge_not_wired`
/// envelope rather than reaching the store/stager. The claude/codex bridge
/// `/claude/message` path
/// keeps the default `true` as of the user's 2026-06-13 "open the bridges" call: it
/// IS Claude/codex collaborating as a team, and self_install there still only
/// STAGES a local-only confirm card the user resolves (never auto-installs). Genuine
/// local Mac desktop chat also keeps the default `true`.
///
/// `denyExternalMcp` (2026-06-13): on human-OUT-of-the-loop bridge clients the
/// external MCP namespace (`mcp__*` — third-party connectors, including a wired
/// real-money brokerage) must stay closed. A bridge turn has no human at the
/// trigger and those connectors run side effects we cannot gate from here, so
/// pass `true` to wrap the tool set in `ClaudeBridgeDenyDispatcher` (now an
/// mcp__-only guard). NativeAgent-NATIVE tools — builder (shell/git/…),
/// integration-send, self-evolution — are FULLY available on the bridge per
/// the user's 2026-06-13 call ("the bridges should be open"); they stay gated by the
/// SAME yolo window / Trust Center / self_install card path as local Mac chat,
/// not by a bridge-specific fence. Genuine local Mac chat (NativeClient) keeps
/// the default `false`: MCP tools available, consent-gated, the user present.
func makeNativeAgentAppToolDispatchClient(
    includeEvolutionBridge: Bool = true,
    denyExternalMcp: Bool = false,
    enforceAppAutonomy: Bool = true,
    swarmApprovalFiler: (any ApprovalFiler)? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any ToolDispatchClient {
    let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
    let activeToolsStore: ActiveToolsStore = usesLiveAppBody
        ? .shared
        : ActiveToolsStore(dataRoot: dataRoot)
    // Wire the MacIntegrationToolBridge so the 5 Phase-1 Mac integration
    // chat tools (calendar/reminders/notify/mobile-notify/spotlight) reach
    // their app-side backends instead of returning `bridge_not_wired`.
    let evolutionBridge: (any EvolutionToolBridge)? = includeEvolutionBridge
        ? EvolutionToolBridgeImpl(dataRoot: dataRoot)
        : nil
    let inner = SwiftToolDispatcher(
        dataRoot: dataRoot,
        activeToolsStore: activeToolsStore,
        allowProcessGlobalTools: usesLiveAppBody,
        providerLifecycleObserver: usesLiveAppBody ? NativeCognitionRuntime.shared : nil,
        swarmApprovalFiler: swarmApprovalFiler,
        macIntegrationBridge: usesLiveAppBody ? MacIntegrationBridgeImpl() : nil,
        evolutionBridge: evolutionBridge
    )
    let appTools: AppChatToolDispatcher
    if usesLiveAppBody {
        appTools = AppChatToolDispatcher(
            inner: inner,
            activeToolsStore: activeToolsStore,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
            enforceAutonomySecurity: enforceAppAutonomy,
            contextPrewarm: { kind, id, terms in
                await NativeContextFlowRuntime.shared.prewarm(kind: kind, id: id, terms: terms)
            },
            motorOutcomeObserver: { reference in
                let model: MotorActionReadModel?
                switch reference.domain {
                case .workshopExecution:
                    let runner = SwiftNativeWorkshopRunner(root: dataRoot)
                    if let record = await runner.getWorkshopExecution(reference.ownerActionID) {
                        model = SwiftNativeWorkshopRunner.motorActionReadModel(record: record)
                    } else {
                        model = nil
                    }
                case .macControl:
                    model = try? await MacControlOperationStore(dataRoot: dataRoot)
                        .motorActionReadModel(actionId: reference.ownerActionID)
                case .externalSend:
                    model = try? await ExternalSendMotorActionReadModelProvider(
                        dataRoot: dataRoot
                    ).motorActionReadModel(actionId: reference.ownerActionID)
                case .browser:
                    // BrowserActionRunner already rereads the Browser owner
                    // and returns its canonical consequence to cognition.
                    model = nil
                }
                guard let model else { return }
                await NativeCognitionRuntime.shared.observeMotorActionState(model)
            }
        )
    } else {
        // A synthetic root has no Mac/iPhone body. Keep the same root-scoped
        // autonomy membrane, expose no app-owned schemas, and never consult
        // the live organism or Context projections.
        appTools = AppChatToolDispatcher(
            inner: inner,
            activeToolsStore: activeToolsStore,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
            enforceAutonomySecurity: enforceAppAutonomy,
            includeAppOwnedTools: false,
            organismPostureProvider: { nil },
            contextPrewarm: { _, _, _ in }
        )
    }
    // Bridge clients pass denyExternalMcp:true so the external `mcp__*`
    // namespace is stripped at dispatch AND in the catalog; everything
    // NativeAgent-native passes straight through to the normal gated chain.
    return denyExternalMcp
        ? ClaudeBridgeDenyDispatcher(inner: appTools)
        : appTools
}

/// Build the raw bridge tool RPC from the same app-owned tool composition used
/// by chat, then add the bridge's conservative read-only/autonomy envelope.
/// `ClaudeBridgeDenyDispatcher` intentionally stays outermost: external MCP
/// names are rejected before they can probe TrustCenter or the inner catalog.
func makeNativeAgentBridgeToolDispatchClient(
    baseTools: (any ToolDispatchClient)? = nil,
    fileAccess: String = "read_only",
    approvalFiler: (any ApprovalFiler)? = nil,
    approvalTimeoutSeconds: Double = 30,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    trust: (any AutonomyResolver)? = nil,
    verifiedSessionId: String? = nil
) -> any ToolDispatchClient {
    let tools = baseTools ?? makeNativeAgentAppToolDispatchClient(
        includeEvolutionBridge: NativeAgentAppChatSurfaceProfile.bridge.includesEvolutionBridge,
        denyExternalMcp: false,
        dataRoot: dataRoot
    )
    let gated = makeGatedToolDispatchClient(
        tools: tools,
        fileAccess: fileAccess,
        approvalFiler: approvalFiler,
        approvalTimeoutSeconds: approvalTimeoutSeconds,
        dataRoot: dataRoot,
        trust: trust,
        verifiedSessionId: verifiedSessionId
    )
    return ClaudeBridgeDenyDispatcher(inner: gated)
}

func makeNativeAgentAppChatOrchestrationClient(
    includeEvolutionBridge: Bool = true,
    denyExternalMcp: Bool = false,
    approvalFiler: (any ApprovalFiler)? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> SwiftNativeChatOrchestrationClient {
    let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
    let tools = makeNativeAgentAppToolDispatchClient(
        includeEvolutionBridge: includeEvolutionBridge,
        denyExternalMcp: denyExternalMcp,
        // The shared ChatOrchestration membrane resolves autonomy once, after
        // SecurityCenter authenticates the exact origin, and owns approval
        // filing/replay. Keep the inner app dispatcher on hard SecurityCenter
        // checks without re-running the autonomy decision from a reconstructed
        // origin. Direct/raw app-tool clients retain the factory default `true`.
        enforceAppAutonomy: false,
        swarmApprovalFiler: approvalFiler,
        dataRoot: dataRoot
    )
    let cognition = usesLiveAppBody ? NativeCognitionRuntime.shared : nil
    return makeChatOrchestrationClient(
        tools: tools,
        dataRoot: dataRoot,
        approvalFiler: approvalFiler,
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition,
        providerLifecycleObserver: cognition,
        contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil,
        // App-side memory-record → atom-id translation; owner string stays here.
        memoryAtomTranslator: usesLiveAppBody
            ? NativeContextFlowRuntime.memoryRecordAtomID(forRecordID:)
            : nil,
        publicSafeMode: NativeAgentPublicSafety.isPublicSafeMode(
            environment: ProcessInfo.processInfo.environment
        )
    )
}

/// Surface-profiled entry point used by every production chat surface.
func makeNativeAgentAppChatOrchestrationClient(
    profile: NativeAgentAppChatSurfaceProfile,
    approvalFiler: (any ApprovalFiler)? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> SwiftNativeChatOrchestrationClient {
    makeNativeAgentAppChatOrchestrationClient(
        includeEvolutionBridge: profile.includesEvolutionBridge,
        denyExternalMcp: profile.deniesExternalMCP,
        // Every user conversation surface gets the same durable nonblocking
        // ApprovalInbox projection. Telegram supplies its specialized wrapper
        // for inline buttons; all other profiles use the shared app filer.
        approvalFiler: approvalFiler ?? NativeAgentChatApprovalFiler(dataRoot: dataRoot),
        dataRoot: dataRoot
    )
}
