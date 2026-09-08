import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import MacControl
import MacIntegration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import WorkshopExecution
import StandingBots

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
    /// Production uses the shared persisted authority; injected dispatchers
    /// may carry a hermetic real store without replacing the gate itself.
    private let macIntegrationPermissionStore: MacIntegrationPermissionStore
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
            // Item 26: one exit, through the router. Owner-waiting (an
            // explicitly invoked notify IS Agent reaching for User), but PINNED
            // to the phone: this tool's name is its contract, and a real APNS
            // receipt is what the caller gets back. Payload unchanged.
            let outcome = try await AttentionRouter.shared.route(
                eventId: userInfo["itemId"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? "mobile_notify:\(AttentionRouter.stableDigest(title + "|" + body))",
                importance: .ownerWaiting,
                title: title,
                body: body,
                userInfo: userInfo,
                pinnedTo: .phone
            )
            return try outcome.requireReceipt()
        },
        macNotificationSender: @escaping @Sendable (String, String) async throws -> NativeAgentNotificationPostResult = { title, body in
            await NativeAgentNotifications.postAndReport(title: title, body: body)
        },
        macIntegrationPermissionStore: MacIntegrationPermissionStore = .shared,
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
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
        self.browserActionRunner = browserActionRunner ?? Self.defaultBrowserActionRunner
        self.doctorStatusProvider = doctorStatusProvider ?? Self.defaultDoctorStatusProvider
        self.telegramStatusProvider = telegramStatusProvider ?? Self.defaultTelegramStatusProvider
        self.reflexReviewHandler = reflexReviewHandler
        self.organismPostureProvider = organismPostureProvider
        self.contextPrewarm = contextPrewarm
        self.motorOutcomeObserver = motorOutcomeObserver
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // 2026-09-06: the bridge canonicalizes `mobile.notify` to `mobile_notify`
        // before this dispatcher sees it, and the fence matched the dotted
        // spelling only — so on a synthetic root the call fell through to
        // `runMobileNotify` and attempted a real push. Fence the canonical
        // notification name too.
        let canonicalNotification = Self.canonicalNotificationToolName(tool)
        if !includeAppOwnedTools,
           Self.appToolNames.contains(tool)
            || canonicalNotification.map({ Self.appToolNames.contains($0) }) == true {
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
        // Composed chat and approved replay resolve asks in the outer approval
        // membrane. Recheck hard blocks here without asking a second time.
        guard envelope.decision != .block,
              !enforceAutonomySecurity || !envelope.requiresApproval else {
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
            let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMobile, mode: .write)
            guard allowed else {
                return Self.macIntegrationDeniedEnvelope(integration: MacIntegrationID.notifyMobile, mode: "write")
            }
            return try await runMobileNotify(input: input, surface: surface)
        case "mac.notify":
            let allowed = await macIntegrationPermissionStore.allows(MacIntegrationID.notifyMac, mode: .write)
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
        var userInfo = [
            "screen": screen,
            "source": source,
            "urgency": urgency,
            "surface": surface,
        ]
        if screen == "chat",
           let sessionId = ChatToolSessionContext.verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
            userInfo["sessionId"] = sessionId
        }
        let receipt = try await mobileNotificationSender(title, message, userInfo)
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
        let internalNames = try await listAvailableTools()
        let names = SwiftToolDispatcher.modelVisibleCatalogToolNames(Set(internalNames)).sorted()
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
        let modelVisibleTurnScoped = SwiftToolDispatcher.modelVisibleCatalogToolNames(turnScoped)
        let sessionActive = persistedActive.union(turnScoped)
        let appNameSet = Set(Self.appToolNames)
        let loadedAppTools = appNameSet.intersection(sessionActive)
        let discoveryAppTools = appNameSet.subtracting(sessionActive)
        var loadedNames = Self.jsonStringArray(obj["currently_loaded"])
        var discoveryNames = Self.jsonStringArray(obj["discovery_only_tools"])
        Self.mergeStrings(loadedAppTools, into: &loadedNames)
        Self.mergeStrings(discoveryAppTools, into: &discoveryNames)
        loadedNames = SwiftToolDispatcher.modelVisibleCatalogToolNames(Set(loadedNames)).sorted()
        discoveryNames = SwiftToolDispatcher.modelVisibleCatalogToolNames(Set(discoveryNames)).sorted()
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
            rowObj["side_effects"] = .bool(envelope.hasSideEffects)
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
        obj["turn_active_tools"] = .array(modelVisibleTurnScoped.sorted().map { .string($0) })
        // Treat every Core capability summary as model-facing discovery. The
        // inner dispatcher already filters these, but the app boundary owns
        // the final cross-surface catalog and must not re-advertise a retired
        // implementation tool from an older/custom inner client.
        for key in [
            "mac_app_available_tools", "mac_app_policy_locked_tools",
            "mac_accessibility_read_available_tools", "mac_accessibility_read_policy_locked_tools",
            "mac_nudge_available_tools", "mac_nudge_policy_locked_tools",
            "mac_accessibility_act_available_tools", "mac_accessibility_act_policy_locked_tools",
        ] {
            let filtered = SwiftToolDispatcher.modelVisibleCatalogToolNames(
                Set(Self.jsonStringArray(obj[key]))
            )
            obj[key] = .array(filtered.sorted().map { .string($0) })
        }
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
        var sessionPinned: Set<String> = []
        var loadedNow = loaded
        var alreadyActive: [String] = []
        var turnActive: [String] = []
        var sessionActiveCount = sessionActive.count
        var status = unavailable.isEmpty ? "loaded" : "partial"
        if let sessionId, !sessionId.isEmpty {
            let existingState = await activeToolsStore.load(sessionId: sessionId)
            let existing = existingState.activeTools
            let turnScoped = LLMCallContext.turnActiveTools ?? []
            let effectiveExisting = existing.union(turnScoped)
            alreadyActive = loaded.filter { effectiveExisting.contains($0) }
            turnActive = loaded.filter { turnScoped.contains($0) }
            loadedNow = loaded.filter { !effectiveExisting.contains($0) }
            if loadedNow.isEmpty {
                sessionActive = existing
                sessionPinned = Set(existingState.pinnedSchemas.keys)
            } else {
                let state = try await activeToolsStore.addLoaded(
                    sessionId: sessionId,
                    names: Set(loadedNow)
                )
                sessionActive = state.activeTools
                sessionPinned = Set(state.pinnedSchemas.keys)
            }
            sessionActiveCount = sessionActive.count
        } else {
            status = unavailable.isEmpty ? "ok" : "partial"
        }
        let activeForTurn = sessionActive.union(LLMCallContext.turnActiveTools ?? [])
        // Agent, 2026-09-06: this list reported names tool_catalog never
        // offered — loading doctor_status and telegram_status came back with
        // mac_focus_app and mac_quit_app active, because an older session row
        // still pinned the internal mac_* organs. tool_catalog's available set
        // is `modelVisibleCatalogToolNames(listAvailableTools())`; one
        // inventory means this passes the same boundary, exactly as
        // agent_introspect's active_tools already does.
        //
        // 2026-09-06: the availability snapshot ALONE was too narrow. The
        // session contract deliberately keeps advertising a loaded tool from
        // its pinned descriptor when this turn's catalog is missing it
        // (`applyLazyToolFilter`, ChatOrchestrationClient+StructuredChat), so
        // during a readiness or policy-catalog flap the model still had the
        // tool while this receipt said it was gone. Same rule as the contract:
        // available NOW or pinned by this session. The mac_* organs stay out
        // either way — they are pinned like anything else in the load order
        // (`commitTurnStartContract` freezes a descriptor from the eager
        // catalog, which still carries them), so it is the model-visibility
        // boundary, not the pin, that keeps them off this list.
        let catalogNames = SwiftToolDispatcher.modelVisibleCatalogToolNames(
            available.union(sessionPinned)
        )
        let activeTools = SwiftToolDispatcher.alwaysOnCoreNames
            .union(activeForTurn)
            .intersection(catalogNames)
            .sorted()
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
            // Same one inventory as the app-only path above: never report a
            // name tool_catalog does not offer (Agent, 2026-09-06), and
            // available-now OR pinned-by-this-session, so a flap does not make
            // the receipt disagree with the contract (2026-09-06).
            let state = await activeToolsStore.load(sessionId: sessionId)
            let catalogNames = SwiftToolDispatcher.modelVisibleCatalogToolNames(
                Set((try? await listAvailableTools()) ?? [])
                    .union(state.pinnedSchemas.keys)
            )
            let active = SwiftToolDispatcher.alwaysOnCoreNames
                .union(state.activeTools)
                .union(LLMCallContext.turnActiveTools ?? [])
                .intersection(catalogNames)
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
        "browser.chrome_renew",
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

    /// App-owned dispatch cases participate in the same typed catalog
    /// contract as the core dispatcher. Keep this adjacent to the actual
    /// dispatch registration lists so a newly registered app tool has to pick
    /// a visible category before the catalog coverage eval can pass.
    static var catalogRegisteredToolNames: Set<String> {
        Set(appToolNames)
    }

    static func catalogBucket(forRegisteredToolNamed name: String) -> ChatToolCatalogBucket? {
        guard catalogRegisteredToolNames.contains(name) else { return nil }
        if notificationToolNames.contains(name) { return .macIntegration }
        if browserToolNames.contains(name) { return .browser }
        if healthToolNames.contains(name) { return .system }
        if organismToolNames.contains(name) { return .core }
        return nil
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
        case "browser.chrome_renew", "browser_chrome_renew", "chrome.renew", "chrome_renew":
            return "browser.chrome_renew"
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
            "catalog_bucket": .string(
                catalogBucket(forRegisteredToolNamed: schema.name)?.rawValue
                    ?? ChatToolCatalogBucket.unclassified.rawValue
            ),
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
            case .double(let value): return Int(exactly: value.rounded(.towardZero))
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
        case "browser.chrome_renew":
            effect = .renew
            payload = [
                "leaseId": .string(string("lease_id") ?? ""),
                "expectedUserSequence": .int(Int64(integer("expected_user_sequence") ?? -1)),
            ]
            if let value = integer("lease_duration_ms") { payload["leaseDurationMs"] = .int(Int64(value)) }
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
        // ITEM 10b. The extension already builds a per-action receipt with
        // outcome / verification / retry and it was being handed back as raw
        // JSON and nothing else — never admitted as a motor consequence the
        // way MacControl and Browser are. Same seam, same call.
        if let model = chromeReceiptMotorActionReadModel(result) {
            await NativeCognitionRuntime.shared.observeMotorActionState(model)
        }
        return result
    }

    /// The Chrome per-action receipt, in the shared motor vocabulary.
    ///
    /// `domainState` keeps the extension's exact word, because the phase
    /// vocabulary has no "partially completed" and collapsing that into either
    /// succeeded or failed would erase the one distinction the receipt exists
    /// to make.
    static func chromeReceiptMotorActionReadModel(_ result: JSONValue) -> MotorActionReadModel? {
        guard case .object(let payload) = result,
              case .object(let receipt)? = payload["receipt"],
              case .string(let actionIdentity)? = receipt["id"],
              !actionIdentity.isEmpty,
              case .string(let outcome)? = receipt["outcome"] else { return nil }
        // The phases are MacControl's own mapping, deliberately
        // (`MacControlOperationStore.motorPhase`): refused is `.blocked`, and
        // an unknown outcome is `.waitingExternal` — evidence is owed, the act
        // is not finished. `.unknown` is NOT available here: the cognitive
        // event factory returns nil for it, which would silently drop the very
        // receipts this fix exists to admit.
        let phase: MotorActionPhase
        switch outcome {
        case "succeeded": phase = .succeeded
        case "refused": phase = .blocked
        default: phase = .waitingExternal
        }
        let verification: MotorVerificationState
        switch receipt["verification"] {
        // 2026-09-06: `page_acknowledged` is the page saying it received the
        // act, not anybody observing that it happened — the extension's own
        // protocol keeps the two apart. A click on a control that ignored it
        // acknowledges just as loudly, so this is evidence still owed
        // (`.pending`), never verification satisfied.
        case .string("page_acknowledged"): verification = .pending
        case .string("not_verified"):
            // 2026-09-06: `not_quiet` is a navigation that was still moving
            // when the wait's deadline arrived — evidence still OWED, not a
            // checked negative. `.pending`, so the turn reads it as unfinished
            // and looks again rather than concluding the page did not settle.
            verification = outcome == "not_quiet" ? .pending : .unverified
        default: verification = .unknown
        }
        let expectedNextEvidence: String
        switch receipt["retry"] {
        case .string("never_automatic"):
            expectedNextEvidence = "A human look at the page. This outcome is unknown and must "
                + "never be retried automatically."
        case .string("fresh_snapshot_then_remaining_text_only"):
            expectedNextEvidence = "A fresh Chrome snapshot, then only the characters that did "
                + "not land."
        default:
            expectedNextEvidence = "A fresh Chrome snapshot; node ids from the old one are stale."
        }
        var updatedAt: String?
        if case .string(let completedAt)? = receipt["completedAt"] { updatedAt = completedAt }
        return MotorActionReadModel(
            domain: "chrome_control",
            // Hashed, like every other domain's identity: the cognitive event
            // factory only accepts a 64-char digest, and the raw receipt id is
            // a UUID. Handing it over unhashed would have been dropped in
            // silence — the same failure with a longer path.
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(actionIdentity),
            phase: phase,
            domainState: outcome,
            verification: verification,
            expectedNextEvidence: expectedNextEvidence,
            updatedAt: updatedAt
        )
    }

    private static func defaultDoctorStatusProvider() async throws -> JSONValue {
        let client = NativeClient(baseURL: "")
        let report = try await client.runDoctor(repair: false)
        let dataRoot = PersistenceCore.defaultDataRoot()
        let surface = ChatTurnRuntimeContext.current?.surface ?? "chat"
        let router = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        )
        let configuredProviderID = try? await router.checkedRoutingSnapshot().activeProviders
        let activeProviderID = ChatTurnRuntimeContext.current?.providerID
            ?? configuredProviderID.flatMap { ProviderRoutingSurfaceLookup.value($0, surface) }
        let providers = try? await client.listProviders(
            dataRoot: dataRoot,
            authEnvironment: ProcessInfo.processInfo.environment
        )
        let activeProviderReady = activeProviderID.flatMap { providerID in
            providers?
                .first(where: { $0.provider_id == providerID })
                .map { $0.auth_status.state.lowercased() == "ready" }
        }
        return doctorStatusEnvelope(
            report: report,
            activeProviderID: activeProviderID,
            activeProviderReady: activeProviderReady
        )
    }

    /// Agent, 2026-09-06: a doctor detail was cut with a bare `prefix(600)`, so
    /// Prompt Prefix Cache ended at "so the rate i" and Subconscious Vitals at
    /// "so earlier turns" — mid-word, with nothing saying anything was missing.
    /// Same 600-character cap; the cut lands on a word boundary and says so.
    static func boundedDoctorDetail(_ detail: String, limit: Int = 600) -> String {
        guard detail.count > limit else { return detail }
        let ellipsis = "…"
        let head = detail.prefix(limit - ellipsis.count)
        // Only honour a boundary in the last part of the budget — one very long
        // unbroken token must not shrink the detail to a few words.
        if let boundary = head.lastIndex(where: { $0 == " " || $0.isNewline }),
           head.distance(from: head.startIndex, to: boundary) > head.count / 2 {
            let trimmed = head[..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed + ellipsis }
        }
        return String(head) + ellipsis
    }

    static func doctorStatusEnvelope(
        report: DoctorReport,
        activeProviderID: String?,
        activeProviderReady: Bool?
    ) -> JSONValue {
        let checks = report.checks.map { check in
            JSONValue.object([
                "id": .string(check.id),
                "title": .string(check.title),
                "status": .string(check.status),
                "detail": .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(check.detail))),
                "repair_available": .bool(check.repair?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            ])
        }
        let maintenanceIDs = Set(["oauth_token_expiry"])
        let activeProviderIsReady = activeProviderReady == true
        let maintenanceChecks = report.checks.filter { check in
            if maintenanceIDs.contains(check.id) { return true }
            return check.id == "live.providers"
                && check.status.lowercased() == "warn"
                && activeProviderIsReady
        }
        let maintenanceCheckIDs = Set(maintenanceChecks.map(\.id))
        let activeChecks = report.checks.filter { !maintenanceCheckIDs.contains($0.id) }
        let activePathStatus = NativeClient.doctorRollup(activeChecks.map(\.status))
        let maintenanceStatus = NativeClient.doctorRollup(maintenanceChecks.map(\.status))
        let providerStatus: String = switch activeProviderReady {
        case true: "ready"
        case false: "not_ready"
        case nil: "unknown"
        }
        return .object([
            "status": .string(report.status),
            "active_path_status": .string(activePathStatus),
            "maintenance_status": .string(maintenanceStatus),
            "active_provider_id": activeProviderID.map(JSONValue.string) ?? .null,
            "active_provider_status": .string(providerStatus),
            "status_scope_note": .string("status is the global Doctor rollup; active_path_status is the independently classified path serving this surface; maintenance warnings remain visible in checks"),
            "repaired": .bool(report.repaired),
            "check_count": .int(Int64(checks.count)),
            "active_path_check_count": .int(Int64(activeChecks.count)),
            "maintenance_check_count": .int(Int64(maintenanceChecks.count)),
            "maintenance_check_ids": .array(maintenanceChecks.map { .string($0.id) }),
            "checks": .array(checks),
        ])
    }

    private static func defaultTelegramStatusProvider() async throws -> JSONValue {
        let status = try await NativeClient(baseURL: "").getTelegramStatus()
        return telegramStatusEnvelope(status: status, now: Date())
    }

    static func telegramStatusEnvelope(status: TelegramStatus, now: Date) -> JSONValue {
        let lastSuccessfulPoll = telegramDiagnosticDate(status.lastPollAt)
        let datedErrors = status.errors.compactMap { event in
            telegramDiagnosticDate(event.at).map { (event.at, $0) }
        }
        let datedBlocked = status.blocked.compactMap { event in
            telegramDiagnosticDate(event.at).map { (event.at, $0) }
        }
        let errorsAfterLastSuccessfulPoll = lastSuccessfulPoll.map { pollAt in
            datedErrors.filter { $0.1 > pollAt }.count
        }
        let latestError = datedErrors.max(by: { $0.1 < $1.1 })
        let latestBlocked = datedBlocked.max(by: { $0.1 < $1.1 })
        let errorHistoryStatus: String
        if status.actionableError != nil {
            errorHistoryStatus = "active_error"
        } else if let errorsAfterLastSuccessfulPoll, errorsAfterLastSuccessfulPoll > 0 {
            errorHistoryStatus = "newer_than_last_successful_poll"
        } else if status.errors.isEmpty {
            errorHistoryStatus = "empty"
        } else {
            errorHistoryStatus = "recovered_history"
        }
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
            "error_history_status": .string(errorHistoryStatus),
            "error_entries_since_last_successful_poll": errorsAfterLastSuccessfulPoll
                .map { .int(Int64($0)) } ?? .null,
            "error_entries_with_unreadable_timestamp": .int(Int64(status.errors.count - datedErrors.count)),
            "blocked_history_status": .string(status.blocked.isEmpty ? "empty" : "historical_policy_events"),
            "blocked_entries_with_unreadable_timestamp": .int(Int64(status.blocked.count - datedBlocked.count)),
            "ledger_scope_note": .string("error and blocked ledger counts are bounded history, not current failure counts; active_error and errors since the last successful poll carry current-health meaning; blocked rows are policy decisions, not transport failures"),
            "active_error": .bool(status.actionableError != nil),
            "poll_retry_transient": .bool(status.isTransientPollInterruption),
            "consecutive_poll_failures": .int(Int64(status.pollBackoffFailures ?? 0)),
        ]
        object["model"] = status.model.map { .string($0) } ?? .null
        object["reasoning_effort"] = status.reasoningEffort.map { .string($0) } ?? .null
        object["last_seen_at"] = status.lastSeenAt.map { .string($0) } ?? .null
        object["last_reply_at"] = status.lastReplyAt.map { .string($0) } ?? .null
        object["last_successful_poll_at"] = status.lastPollAt.map { .string($0) } ?? .null
        object["latest_error_at"] = latestError.map { .string($0.0) } ?? .null
        object["latest_error_age_seconds"] = latestError.map {
            .int(Int64(max(0, now.timeIntervalSince($0.1))))
        } ?? .null
        object["latest_blocked_at"] = latestBlocked.map { .string($0.0) } ?? .null
        object["latest_blocked_age_seconds"] = latestBlocked.map {
            .int(Int64(max(0, now.timeIntervalSince($0.1))))
        } ?? .null
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

    private static func telegramDiagnosticDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
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
/// in the loop — the reflection/dream/REM background loops, Slack, and iOS —
/// pass `false`, so those clients return a `bridge_not_wired`
/// envelope rather than reaching the store/stager. The claude/codex bridge
/// `/claude/message` path
/// keeps the default `true` as of the user's 2026-06-13 "open the bridges" call: it
/// IS Claude/codex collaborating as a team, and self_install there still only
/// STAGES a local-only confirm card the user resolves (never auto-installs). Genuine
/// local Mac desktop chat also keeps the default `true`. Telegram keeps the
/// bridge so authenticated Full Mac YOLO turns can use read-only
/// `evolution_status`; mutation tools still cross the ordinary TrustCenter and
/// approval floors before this backend can run.
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
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    innerTools: (any ToolDispatchClient)? = nil
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
    let standingBotRunEnqueue: (@Sendable (UUID) throws -> UUID)?
    if usesLiveAppBody {
        standingBotRunEnqueue = { id in
            try BotRunQueue(dataRoot: dataRoot).enqueueRequest(bot: id)
        }
    } else {
        standingBotRunEnqueue = nil
    }
    // Keep the injection seam below AppChatToolDispatcher. Hermetic boundary
    // tests can replace the core tool body without bypassing app-owned
    // interception, SecurityCenter, or the bridge factory's wrapper order.
    let inner: any ToolDispatchClient = innerTools ?? SwiftToolDispatcher(
        dataRoot: dataRoot,
        activeToolsStore: activeToolsStore,
        allowProcessGlobalTools: usesLiveAppBody,
        providerLifecycleObserver: usesLiveAppBody ? NativeCognitionRuntime.shared : nil,
        swarmApprovalFiler: swarmApprovalFiler,
        macIntegrationBridge: usesLiveAppBody ? MacIntegrationBridgeImpl() : nil,
        evolutionBridge: evolutionBridge,
        standingBotRunEnqueue: standingBotRunEnqueue
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
                case .agentBridge:
                    let row = DelegationStatusProjector().allJobs(now: Date()).first {
                        $0.id == reference.ownerActionID
                    }
                    if let row {
                        model = BackgroundLoopsAssembly.delegationJobSnapshot(from: row)
                            .motorActionReadModel()
                    } else {
                        // The durable inbox receipt can become visible a few
                        // milliseconds before the wake-job writer. Preserve
                        // the exact owner identity without inventing progress.
                        model = MotorActionReadModel(
                            domain: "agent_bridge",
                            actionIdentity: reference.actionIdentity,
                            phase: .waitingExternal,
                            domainState: "accepted",
                            verification: .pending,
                            expectedNextEvidence: "A canonical bridge job record tied to this message id.",
                            updatedAt: nil
                        )
                    }
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
    appInnerTools: (any ToolDispatchClient)? = nil,
    fileAccess: String = "read_only",
    approvalFiler: (any ApprovalFiler)? = nil,
    approvalTimeoutSeconds: Double = 30,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    trust: (any AutonomyResolver)? = nil,
    verifiedSessionId: String? = nil
) -> any ToolDispatchClient {
    let tools = makeNativeAgentAppToolDispatchClient(
        includeEvolutionBridge: NativeAgentAppChatSurfaceProfile.bridge.includesEvolutionBridge,
        denyExternalMcp: false,
        dataRoot: dataRoot,
        innerTools: appInnerTools
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
    // 2026-09-06: canonicalize outside the deny guard as well — `tool.catalog`
    // used to reach `tool_catalog` without the external-MCP name scrub.
    return CanonicalToolNameDispatcher(inner: ClaudeBridgeDenyDispatcher(inner: gated))
}

private func makeNativeAgentAppChatOrchestrationClient(
    includeEvolutionBridge: Bool = true,
    denyExternalMcp: Bool = false,
    approvalFiler: (any ApprovalFiler)? = nil,
    toolLoopMaxIterations: Int? = nil,
    turnWallClockSeconds: TimeInterval? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> SwiftNativeChatOrchestrationClient {
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
    return makeNativeAgentAppChatOrchestrationClient(
        tools: tools,
        approvalFiler: approvalFiler,
        toolLoopMaxIterations: toolLoopMaxIterations,
        turnWallClockSeconds: turnWallClockSeconds,
        dataRoot: dataRoot
    )
}

/// Bind any purpose-built dispatcher to the same app-owned mind/body assembly
/// used by Mac, iOS, Telegram, Slack, bridge, and background turns. Restricted
/// Workshop dispatchers keep their own smaller tool inventory while cognition,
/// ContextFlow, memory projection, and provider lifecycle remain one shared
/// contract instead of being rebuilt at each caller. Public first-run safety
/// stays with the canonical ContextFlow and cognition owners.
func makeNativeAgentAppChatOrchestrationClient(
    tools: any ToolDispatchClient,
    approvalFiler: (any ApprovalFiler)? = nil,
    toolLoopMaxIterations: Int? = nil,
    turnWallClockSeconds: TimeInterval? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> SwiftNativeChatOrchestrationClient {
    let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
    let cognition = usesLiveAppBody ? NativeCognitionRuntime.shared : nil
    return makeChatOrchestrationClient(
        tools: tools,
        dataRoot: dataRoot,
        toolLoopMaxIterations: toolLoopMaxIterations,
        turnWallClockSeconds: turnWallClockSeconds,
        approvalFiler: approvalFiler,
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition,
        providerLifecycleObserver: cognition,
        contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil,
        // App-side memory-record → atom-id translation; owner string stays here.
        memoryAtomTranslator: usesLiveAppBody
            ? NativeContextFlowRuntime.memoryRecordAtomID(forRecordID:)
            : nil
    )
}

/// Surface-profiled entry point used by every production chat surface.
func makeNativeAgentAppChatOrchestrationClient(
    profile: NativeAgentAppChatSurfaceProfile,
    approvalFiler: (any ApprovalFiler)? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> SwiftNativeChatOrchestrationClient {
    let resolvedApprovalFiler: (any ApprovalFiler)? = approvalFiler
        ?? (profile.filesApprovalsByDefault
            ? NativeAgentChatApprovalFiler(dataRoot: dataRoot)
            : nil)
    return makeNativeAgentAppChatOrchestrationClient(
        includeEvolutionBridge: profile.includesEvolutionBridge,
        denyExternalMcp: profile.deniesExternalMCP,
        // User conversation surfaces get the same durable nonblocking inbox.
        // Telegram supplies its inline-button wrapper. Background execution
        // has no user at the trigger and therefore fails confirm-tier work
        // closed unless a caller explicitly supplies a filer.
        approvalFiler: resolvedApprovalFiler,
        toolLoopMaxIterations: profile.toolLoopMaxIterations,
        turnWallClockSeconds: profile.turnWallClockSeconds,
        dataRoot: dataRoot
    )
}
