import Foundation
import Testing
@testable import NativeAgentApp
import ChatOrchestration
import CognitiveSubstrate
import Context
import MacIntegration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import TrustCenter

private final class StubInnerToolDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let fixedResults: [String: JSONValue]
    private let activeToolsStore: ActiveToolsStore

    init(fixedResults: [String: JSONValue] = [:], activeToolsStore: ActiveToolsStore = .shared) {
        self.fixedResults = fixedResults
        self.activeToolsStore = activeToolsStore
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if let fixed = fixedResults[tool] { return fixed }
        if tool == "tool_load" {
            // Mimic core impl_tool_load just enough for the mixed-batch test:
            // persist the requested names (names[] + singular name) to the
            // session store and return a core-shaped envelope that, like the
            // real one, does NOT echo `active_tools`.
            var names: [String] = []
            if case .array(let vals)? = input["names"] {
                names.append(contentsOf: vals.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
            }
            if case .string(let single)? = input["name"], !single.isEmpty { names.append(single) }
            let sessionId: String? = {
                if case .string(let s)? = (input["session_id"] ?? input["__session_id"]) { return s }
                return nil
            }()
            if let sessionId, !sessionId.isEmpty, !names.isEmpty {
                _ = try? await activeToolsStore.addLoaded(sessionId: sessionId, names: Set(names))
            }
            return .object([
                "status": .string("loaded"),
                "delegated": .bool(true),
                "loaded": .array(names.map { .string($0) }),
            ])
        }
        return .object([
            "tool": .string(tool),
            "surface": .string(surface),
            "delegated": .bool(true),
        ])
    }

    func listAvailableTools() async throws -> [String] {
        ["read_file", "tool_catalog", "tool_load", "x_search"]
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [
            LLMToolSchema(
                name: "read_file",
                description: "Read a file.",
                parametersJSON: Data(#"{"type":"object","properties":{},"required":[]}"#.utf8)
            ),
            LLMToolSchema(
                name: "x_search",
                description: "Search recent public X posts.",
                parametersJSON: Data(#"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#.utf8)
            ),
        ]
    }
}

private enum ThrowingToolDispatcherError: Error, Equatable { case failed }

private struct LegacyMacCatalogStub: ToolDispatchClient {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object([
            "status": .string("ok"),
            "currently_loaded": .array([.string("mac_focus_app"), .string("act")]),
            "turn_active_tools": .array([.string("mac_quit_app"), .string("go")]),
            "mac_app_available_tools": .array([.string("mac_focus_app"), .string("mac_quit_app")]),
            "mac_app_policy_locked_tools": .array([.string("mac_focus_app")]),
            "mac_accessibility_read_available_tools": .array([.string("mac_look"), .string("mac_view"), .string("screen")]),
            "mac_accessibility_read_policy_locked_tools": .array([.string("mac_ax_find"), .string("wait")]),
            "mac_accessibility_act_available_tools": .array([.string("mac_act"), .string("act")]),
            "mac_accessibility_act_policy_locked_tools": .array([.string("mac_click"), .string("go")]),
            "available_tools": .array([.string("mac_focus_app"), .string("act"), .string("tool_catalog")]),
            "tools": .array([]),
        ])
    }

    func listAvailableTools() async throws -> [String] {
        ["mac_focus_app", "mac_quit_app", "act", "go", "tool_catalog", "tool_load"]
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Test
func defaultReflexReviewerUsesConfiguredAgentIdentity() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("reflex-reviewer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    try Data(#"{"name":"CustomAgent"}"#.utf8)
        .write(to: memory.appendingPathComponent("profile.json"))

    #expect(AppChatToolDispatcher.defaultReflexReviewerIdentity(dataRoot: root) == "CustomAgent")
}

private actor ThrowingMacToolDispatcher: ToolDispatchClient {
    private(set) var receivedOperationID: String?

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if case .string(let operationID)? = input["operationId"] {
            receivedOperationID = operationID
        }
        throw ThrowingToolDispatcherError.failed
    }

    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

private actor NotificationCapture {
    var mobile: [(title: String, body: String, userInfo: [String: String])] = []
    var mac: [(title: String, body: String)] = []

    func recordMobile(title: String, body: String, userInfo: [String: String]) {
        mobile.append((title, body, userInfo))
    }

    func recordMac(title: String, body: String) {
        mac.append((title, body))
    }
}

private actor BrowserToolCapture {
    var calls: [(actionId: String, dryRun: Bool, input: [String: JSONValue])] = []

    func record(actionId: String, dryRun: Bool, input: [String: JSONValue]) {
        calls.append((actionId, dryRun, input))
    }
}

private actor ContextPrewarmCapture {
    var hints: [(ContextPrewarmHintKind, String, [String])] = []

    func record(_ kind: ContextPrewarmHintKind, id: String, terms: [String]) {
        hints.append((kind, id, terms))
    }
}

@Test
func everyRegisteredAppToolReachesItsAppOwnedDispatchBoundary() async throws {
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "app-tool-gauntlet",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "app-tool-gauntlet",
                status: "completed",
                delivery: "test",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        browserActionRunner: { actionID, dryRun, _ in
            .object([
                "status": .string("ok"),
                "actionId": .string(actionID),
                "dryRun": .bool(dryRun),
            ])
        },
        doctorStatusProvider: { .object(["status": .string("ok")]) },
        telegramStatusProvider: { .object(["status": .string("ok")]) },
        organismPostureProvider: { nil }
    )

    let names = AppChatToolDispatcher.catalogRegisteredToolNames
    #expect(names.count >= 20)
    for name in names.sorted() {
        do {
            let result = try await dispatcher.dispatch(tool: name, input: [:], surface: "chat")
            guard case .object(let object) = result else { continue }
            #expect(object["delegated"] != .bool(true), "\(name) fell through to the Core dispatcher")
        } catch {
            let rendered = String(describing: error).lowercased()
            #expect(!rendered.contains("unknown tool"), "\(name) is registered but not dispatched: \(error)")
        }
    }
}

private actor MotorOutcomeCapture {
    var references: [ToolCausalBoundary.MotorReference] = []

    func record(_ reference: ToolCausalBoundary.MotorReference) {
        references.append(reference)
    }
}

@Test
func appChatToolDispatcherReturnsCanonicalWorkshopAndMacOutcomesToObservers() async throws {
    let capture = MotorOutcomeCapture()
    let workshopID = String(repeating: "a", count: 64)
    let macID = "11111111-1111-4111-8111-111111111111"
    let approvalID = "22222222-2222-4222-8222-222222222222"
    let bridgeID = "44444444-4444-4444-8444-444444444444"
    let dataRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppChatMotorObserver-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "securityPolicy": .object(["toolSigningRequired": .bool(false)]),
        ]),
        to: dataRoot.appendingPathComponent("trust/policy.json")
    )
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(fixedResults: [
            "workshop_submit": .object([
                "status": .string("queued"),
                "id": .string(workshopID),
            ]),
            "mac_focus_app": .object([
                "ok": .bool(true),
                "operationId": .string(macID),
                "operationState": .string("completed"),
                "verification": .string("satisfied"),
            ]),
            "agentmail_send": .object([
                "status": .string("approval_required"),
                "approvalId": .string(approvalID),
            ]),
            "codex_message": .object([
                "status": .string("queued"),
                "messageId": .string(bridgeID),
            ]),
        ]),
        securityCenter: SwiftNativeSecurityCenter(
            dataRoot: dataRoot,
            persistence: persistence
        ),
        enforceAutonomySecurity: false,
        organismPostureProvider: { nil },
        motorOutcomeObserver: { await capture.record($0) }
    )

    _ = try await dispatcher.dispatch(tool: "workshop_submit", input: [:], surface: "chat")
    _ = try await dispatcher.dispatch(tool: "mac_focus_app", input: [:], surface: "chat")
    let externalResult = try await dispatcher.dispatch(tool: "agentmail_send", input: [:], surface: "chat")
    _ = try await dispatcher.dispatch(tool: "codex_message", input: [:], surface: "chat")
    let canonicalApprovalID: String? = {
        guard case .object(let object) = externalResult,
              case .string(let value)? = object["approvalId"] ?? object["approval_id"] else {
            return nil
        }
        return value
    }()
    let references = await capture.references
    #expect(canonicalApprovalID != nil)
    #expect(references.map(\.domain) == [.workshopExecution, .macControl, .externalSend, .agentBridge])
    #expect(references.map(\.ownerActionID) == [workshopID, macID, canonicalApprovalID, bridgeID].compactMap { $0 })
    #expect(references.allSatisfy {
        $0.actionIdentity == CausalTransitionEvidence.opaqueIdentity($0.ownerActionID)
    })
}

@Test
func appChatToolDispatcherObservesCanonicalMacFailureEvenWhenInnerThrows() async throws {
    let inner = ThrowingMacToolDispatcher()
    let capture = MotorOutcomeCapture()
    let operationID = "33333333-3333-4333-8333-333333333333"
    let dataRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppChatMacFailureObserver-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "securityPolicy": .object(["toolSigningRequired": .bool(false)]),
        ]),
        to: dataRoot.appendingPathComponent("trust/policy.json")
    )
    let dispatcher = AppChatToolDispatcher(
        inner: inner,
        securityCenter: SwiftNativeSecurityCenter(
            dataRoot: dataRoot,
            persistence: persistence
        ),
        enforceAutonomySecurity: false,
        organismPostureProvider: { nil },
        motorOutcomeObserver: { await capture.record($0) }
    )

    do {
        _ = try await dispatcher.dispatch(
            tool: "mac_quit_app",
            input: ["operationId": .string(operationID)],
            surface: "chat"
        )
        Issue.record("expected inner Mac dispatcher to throw")
    } catch {
        #expect(error as? ThrowingToolDispatcherError == .failed)
    }

    #expect(await inner.receivedOperationID == operationID)
    let references = await capture.references
    #expect(references.map(\.domain) == [.macControl])
    #expect(references.map(\.ownerActionID) == [operationID])
}

private actor ReflexReviewCapture {
    var calls: [(candidateID: String, decision: OrganismReflexReviewDecision, note: String?, surface: String)] = []

    func record(
        candidateID: String,
        decision: OrganismReflexReviewDecision,
        note: String?,
        surface: String
    ) {
        calls.append((candidateID, decision, note, surface))
    }
}

@Test
func appChatToolDispatcher_exposesAndDispatchesBoundedHealthTools() async throws {
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        doctorStatusProvider: {
            .object([
                "status": .string("ok"),
                "check_count": .int(3),
            ])
        },
        telegramStatusProvider: {
            .object([
                "status": .string("ok"),
                "enabled": .bool(true),
                "poller_running": .bool(true),
            ])
        },
        organismPostureProvider: { nil }
    )

    let names = try await dispatcher.listAvailableTools()
    #expect(names.contains("doctor_status"))
    #expect(names.contains("telegram_status"))

    let load = try await dispatcher.dispatch(
        tool: "tool_load",
        input: ["category": .string("health")],
        surface: "codex"
    )
    #expect(Set(jsonStringArray(load, key: "loaded")).isSuperset(of: ["doctor_status", "telegram_status"]))

    let doctor = try await dispatcher.dispatch(tool: "doctor.status", input: [:], surface: "codex")
    #expect(jsonString(doctor, key: "status") == "ok")
    #expect(jsonString(doctor, key: "tool") == "doctor_status")
    #expect(jsonString(doctor, key: "surface") == "codex")
    #expect(jsonBool(doctor, key: "read_only") == true)
    #expect(jsonInt(doctor, key: "check_count") == 3)

    let telegram = try await dispatcher.dispatch(tool: "telegram.status", input: [:], surface: "telegram")
    #expect(jsonString(telegram, key: "status") == "ok")
    #expect(jsonString(telegram, key: "tool") == "telegram_status")
    #expect(jsonBool(telegram, key: "poller_running") == true)

    let catalog = try await dispatcher.dispatch(tool: "tool_catalog", input: [:], surface: "codex")
    #expect(Set(jsonStringArray(catalog, key: "health_tools")) == ["doctor_status", "telegram_status"])
    #expect(jsonString(catalog, key: "catalog_detail") == "compact")
    #expect(jsonObjectArray(catalog, key: "tools").isEmpty)
    guard case .object(let catalogObject) = catalog,
          case .object(let groups)? = catalogObject["tool_groups"] else {
        Issue.record("expected compact tool group index")
        return
    }
    #expect(groups["browser"] != nil)
}

@Test
func appChatToolCatalog_doesNotReadvertiseRetiredMacImplementationTools() async throws {
    let dispatcher = AppChatToolDispatcher(
        inner: LegacyMacCatalogStub(),
        enforceAutonomySecurity: false,
        organismPostureProvider: { nil }
    )

    let result = try await dispatcher.dispatch(
        tool: "tool_catalog",
        input: [:],
        surface: "chat"
    )

    let available = Set(jsonStringArray(result, key: "available_tools"))
    #expect(available.contains("act"))
    #expect(available.contains("go"))
    #expect(!available.contains("mac_focus_app"))
    #expect(!available.contains("mac_quit_app"))
    let turnActive = Set(jsonStringArray(result, key: "turn_active_tools"))
    #expect(turnActive.isEmpty)
    #expect(Set(jsonStringArray(result, key: "currently_loaded")) == ["act"])
    let discoveryOnly = Set(jsonStringArray(result, key: "discovery_only_tools"))
    #expect(!discoveryOnly.contains("mac_look"))
    #expect(!discoveryOnly.contains("mac_view"))
    #expect(jsonStringArray(result, key: "mac_app_available_tools").isEmpty)
    #expect(jsonStringArray(result, key: "mac_app_policy_locked_tools").isEmpty)
    #expect(jsonStringArray(result, key: "mac_accessibility_read_available_tools") == ["screen"])
    #expect(jsonStringArray(result, key: "mac_accessibility_read_policy_locked_tools") == ["wait"])
    #expect(jsonStringArray(result, key: "mac_accessibility_act_available_tools") == ["act"])
    #expect(jsonStringArray(result, key: "mac_accessibility_act_policy_locked_tools") == ["go"])
    guard case .object(let object) = result,
          case .object(let groups)? = object["tool_groups"] else {
        Issue.record("expected compact tool group index")
        return
    }
    let grouped = groups.values.flatMap { value -> [String] in
        guard case .array(let values) = value else { return [] }
        return values.compactMap { if case .string(let name) = $0 { return name } else { return nil } }
    }
    #expect(!grouped.contains("mac_focus_app"))
    #expect(!grouped.contains("mac_quit_app"))
}

@Test
func doctorStatusEnvelope_separatesConfirmedActivePathFromDormantMaintenance() {
    let report = DoctorReport(
        status: "warn",
        repaired: false,
        checks: [
            DoctorCheck(id: "storage", title: "Storage", status: "ok", detail: "ready", repair: nil),
            DoctorCheck(id: "oauth_token_expiry", title: "OAuth", status: "warn", detail: "Dormant token expired", repair: nil),
            DoctorCheck(id: "live.providers", title: "Providers", status: "warn", detail: "One stale historical check", repair: nil),
        ]
    )

    let result = AppChatToolDispatcher.doctorStatusEnvelope(
        report: report,
        activeProviderID: "openai_oauth_direct",
        activeProviderReady: true
    )

    #expect(jsonString(result, key: "status") == "warn")
    #expect(jsonString(result, key: "active_path_status") == "ok")
    #expect(jsonString(result, key: "maintenance_status") == "warn")
    #expect(jsonString(result, key: "active_provider_id") == "openai_oauth_direct")
    #expect(jsonString(result, key: "active_provider_status") == "ready")
    #expect(jsonInt(result, key: "active_path_check_count") == 1)
    #expect(jsonInt(result, key: "maintenance_check_count") == 2)
    #expect(Set(jsonStringArray(result, key: "maintenance_check_ids")) == ["oauth_token_expiry", "live.providers"])
}

@Test
func doctorStatusEnvelope_keepsProviderWarningOnUnconfirmedActivePath() {
    let report = DoctorReport(
        status: "warn",
        repaired: false,
        checks: [
            DoctorCheck(id: "storage", title: "Storage", status: "ok", detail: "ready", repair: nil),
            DoctorCheck(id: "oauth_token_expiry", title: "OAuth", status: "warn", detail: "Dormant token expired", repair: nil),
            DoctorCheck(id: "live.providers", title: "Providers", status: "warn", detail: "No ready provider", repair: nil),
        ]
    )

    let result = AppChatToolDispatcher.doctorStatusEnvelope(
        report: report,
        activeProviderID: "openai_oauth_direct",
        activeProviderReady: false
    )

    #expect(jsonString(result, key: "active_path_status") == "warn")
    #expect(jsonString(result, key: "active_provider_status") == "not_ready")
    #expect(jsonInt(result, key: "active_path_check_count") == 2)
    #expect(jsonInt(result, key: "maintenance_check_count") == 1)
    #expect(jsonStringArray(result, key: "maintenance_check_ids") == ["oauth_token_expiry"])
}

@Test
func telegramStatusEnvelope_separatesRecoveredLedgerHistoryFromCurrentHealth() throws {
    let status = TelegramStatus(
        enabled: true,
        tokenConfigured: true,
        allowedChatIds: ["redacted"],
        allowedUserIds: ["redacted"],
        requireMention: false,
        model: "gpt-5.6-sol",
        reasoningEffort: "high",
        pollerEnabled: true,
        lastSeenUpdateId: 12,
        lastSeenAt: "2026-08-29T10:00:00.000Z",
        lastReplyAt: "2026-08-29T10:00:10.000Z",
        lastError: nil,
        pollBackoffFailures: 0,
        lastPollAt: "2026-08-29T10:05:00.000Z",
        lastDiagnosticsClearedAt: nil,
        voiceTranscription: nil,
        receipts: [],
        blocked: [
            TelegramBlockedEvent(eventId: "b1", at: "2026-08-28T10:00:00.000Z", reason: "policy", chatId: nil, userId: nil, updateId: nil, textPreview: nil),
        ],
        errors: [
            TelegramErrorEvent(eventId: "e1", at: "2026-08-29T10:04:00.000Z", context: "poll", error: "unavailable"),
        ]
    )
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-29T10:06:00Z"))

    let result = AppChatToolDispatcher.telegramStatusEnvelope(status: status, now: now)

    #expect(jsonString(result, key: "status") == "ok")
    #expect(jsonString(result, key: "error_history_status") == "recovered_history")
    #expect(jsonInt(result, key: "error_entries_since_last_successful_poll") == 0)
    #expect(jsonString(result, key: "latest_error_at") == "2026-08-29T10:04:00.000Z")
    #expect(jsonInt(result, key: "latest_error_age_seconds") == 120)
    #expect(jsonString(result, key: "blocked_history_status") == "historical_policy_events")
    #expect(jsonInt(result, key: "latest_blocked_age_seconds") == 86_760)
    #expect(jsonBool(result, key: "active_error") == false)
}

@Test
func telegramStatusEnvelope_doesNotCallPostPollErrorsRecovered() throws {
    let status = TelegramStatus(
        enabled: true,
        tokenConfigured: true,
        allowedChatIds: [],
        allowedUserIds: [],
        requireMention: false,
        model: nil,
        reasoningEffort: nil,
        pollerEnabled: true,
        lastSeenUpdateId: nil,
        lastSeenAt: nil,
        lastReplyAt: nil,
        lastError: nil,
        pollBackoffFailures: 0,
        lastPollAt: "2026-08-29T10:05:00.000Z",
        lastDiagnosticsClearedAt: nil,
        voiceTranscription: nil,
        receipts: [],
        blocked: [],
        errors: [
            TelegramErrorEvent(eventId: "e2", at: "2026-08-29T10:05:30.000Z", context: "send", error: "failed"),
        ]
    )
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-29T10:06:00Z"))

    let result = AppChatToolDispatcher.telegramStatusEnvelope(status: status, now: now)

    #expect(jsonString(result, key: "error_history_status") == "newer_than_last_successful_poll")
    #expect(jsonInt(result, key: "error_entries_since_last_successful_poll") == 1)
}

@Test
func appChatToolDispatcher_exposesAndDispatchesLazyReflexReviewWithReceipt() async throws {
    let capture = ReflexReviewCapture()
    let reviewedAt = Date(timeIntervalSince1970: 8_000)
    let candidate = OrganismReflexCandidate(
        id: "tool:tool-grep",
        pattern: "Prefer the bounded grep path.",
        trustClass: .lowRisk,
        evidenceCount: 9,
        successCount: 9,
        confidence: 0.92,
        reviewRequired: false,
        autoActivationAllowed: true,
        firstSeenAt: reviewedAt.addingTimeInterval(-100),
        lastUpdatedAt: reviewedAt,
        approvedAt: reviewedAt,
        permanentlyDeliberate: false,
        lastReviewDecision: .approve,
        lastReviewedAt: reviewedAt,
        lastReviewedBy: "agent",
        reviewNote: "User approved"
    )
    let receipt = OrganismReflexReviewReceipt(
        id: "receipt-grep",
        candidateID: candidate.id,
        pattern: candidate.pattern,
        trustClass: candidate.trustClass,
        decision: .approve,
        reviewedAt: reviewedAt,
        reviewedBy: "agent",
        source: "reflex_review:codex",
        note: "User approved",
        evidenceCount: 9,
        successCount: 9,
        failureCount: 0,
        confidence: 0.92,
        autoActivationAllowed: true,
        permanentlyDeliberate: false
    )
    let snapshot = OrganismSnapshot(
        generatedAt: reviewedAt,
        enabled: true,
        chemicalState: .neutral,
        bodySchema: .neutral,
        reflexSummary: OrganismReflexSummary(candidateCount: 1, approvedLowRiskCount: 1, lowRiskCount: 1, reviewReceiptCount: 1),
        reflexCandidates: [candidate],
        reflexReviewReceipts: [receipt],
        signalCount: 9,
        lastSignalAt: reviewedAt
    )
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        reflexReviewHandler: { candidateID, decision, note, surface in
            await capture.record(candidateID: candidateID, decision: decision, note: note, surface: surface)
            return OrganismReflexReviewApplyOutcome(
                status: .applied,
                snapshot: snapshot,
                candidate: candidate,
                receipt: receipt,
                error: nil
            )
        },
        organismPostureProvider: { nil }
    )

    let names = try await dispatcher.listAvailableTools()
    #expect(names.contains("reflex_review"))
    let schemas = try await dispatcher.listAvailableToolSchemas()
    let schema = try #require(schemas.first { $0.name == "reflex_review" })
    #expect(String(decoding: schema.parametersJSON, as: UTF8.self).contains("reject"))

    let load = try await dispatcher.dispatch(
        tool: "tool_load",
        input: ["category": .string("organism")],
        surface: "codex"
    )
    #expect(jsonStringArray(load, key: "loaded").contains("reflex_review"))

    let result = try await dispatcher.dispatch(
        tool: "reflex_review",
        input: [
            "candidate_id": .string(candidate.id),
            "decision": .string("approve"),
            "note": .string("User approved"),
        ],
        surface: "codex"
    )
    #expect(jsonString(result, key: "status") == "reviewed")
    #expect(jsonBool(result, key: "applied") == true)
    guard case .object(let resultObject) = result,
          case .object(let receiptObject)? = resultObject["receipt"] else {
        Issue.record("reflex_review receipt missing")
        return
    }
    #expect(receiptObject["id"] == .string("receipt-grep"))
    #expect(receiptObject["reviewed_by"] == .string("agent"))
    #expect(receiptObject["auto_activation_allowed"] == .bool(true))

    let calls = await capture.calls
    #expect(calls.count == 1)
    #expect(calls.first?.candidateID == candidate.id)
    #expect(calls.first?.decision == .approve)
    #expect(calls.first?.surface == "codex")
}

@Test
func appChatToolDispatcher_reflexReviewRejectsUnknownDecisionBeforeRuntime() async throws {
    let capture = ReflexReviewCapture()
    let snapshot = OrganismSnapshot(
        generatedAt: .distantPast,
        enabled: true,
        chemicalState: .neutral,
        bodySchema: .neutral,
        signalCount: 0,
        lastSignalAt: nil
    )
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        reflexReviewHandler: { candidateID, decision, note, surface in
            await capture.record(candidateID: candidateID, decision: decision, note: note, surface: surface)
            return OrganismReflexReviewApplyOutcome(
                status: .candidateNotFound,
                snapshot: snapshot,
                candidate: nil,
                receipt: nil,
                error: "not found"
            )
        },
        organismPostureProvider: { nil }
    )

    let result = try await dispatcher.dispatch(
        tool: "reflex_review",
        input: [
            "candidate_id": .string("tool:tool-bash"),
            "decision": .string("retire"),
        ],
        surface: "codex"
    )
    #expect(jsonString(result, key: "status") == "error")
    #expect(jsonString(result, key: "error") == "invalid_input")
    let calls = await capture.calls
    #expect(calls.isEmpty)
}

@Test
func appChatToolDispatcher_emitsBoundedOwnerPrewarmHints() async throws {
    let capture = ContextPrewarmCapture()
    let posture = OrganismBehaviorPosture(
        generatedAt: .distantPast,
        enabled: true,
        posture: "steady",
        claimDiscipline: .normal,
        toolStrategy: .normal,
        directives: []
    )
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        organismPostureProvider: { posture },
        contextPrewarm: { kind, id, terms in
            await capture.record(kind, id: id, terms: terms)
        }
    )

    _ = try await dispatcher.dispatch(
        tool: "read_file",
        input: ["path": .string("docs/map.md")],
        surface: "chat"
    )
    _ = try await dispatcher.dispatch(tool: "desk_read", input: [:], surface: "chat")
    _ = try await dispatcher.dispatch(tool: "x_search", input: [:], surface: "telegram")

    // Prewarm delivery is off the dispatch path now, so the assertions below
    // are about what EVENTUALLY reaches the planner, not what has landed by
    // the time dispatch returns. See the timing tests further down.
    await dispatcher.drainPendingContextPrewarm()

    let hints = await capture.hints
    #expect(hints.contains { $0.0 == .file && $0.1 == "docs/map.md" })
    #expect(hints.contains { $0.0 == .desk && $0.1 == "agent-desk" })
    #expect(hints.contains { $0.0 == .toolResult && $0.1 == "x_search" })
    #expect(hints.contains { $0.0 == .organism })
    #expect(hints.allSatisfy { !$0.2.isEmpty && $0.2.count <= 32 })
}

/// A prewarm sink that blocks until the test releases it, and records exactly
/// when each hint arrived relative to the dispatch that produced it.
private actor GatedPrewarmSink {
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var hints: [(ContextPrewarmHintKind, String)] = []
    private(set) var startedCount = 0

    func record(_ kind: ContextPrewarmHintKind, id: String) async {
        startedCount += 1
        if !opened {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate = continuation
            }
        }
        hints.append((kind, id))
    }

    func open() {
        opened = true
        gate?.resume()
        gate = nil
    }

    func waitUntilStarted() async {
        while startedCount == 0 {
            await Task.yield()
        }
    }
}

/// FIX-A ordering probe: the tool result must be returned to the turn BEFORE
/// any prewarm work runs. The old code awaited `prewarmAfterToolResult` inline,
/// which meant a full lowercase-and-rank pass over every atom in the active
/// context generation — on the ContextFlowCoordinator actor the next turn needs
/// — sat between the tool finishing and the model seeing its result.
@Test
func appChatToolDispatcher_returnsToolResultWithoutAwaitingPrewarm() async throws {
    let sink = GatedPrewarmSink()
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        organismPostureProvider: { nil },
        contextPrewarm: { kind, id, _ in
            await sink.record(kind, id: id)
        }
    )

    // The sink is wedged: any dispatch that awaited prewarm would deadlock
    // here and the test would time out rather than fail.
    let result = try await dispatcher.dispatch(
        tool: "x_search",
        input: ["query": .string("q")],
        surface: "telegram"
    )

    // Byte-identical result, delivered while prewarm is still blocked.
    #expect(result == .object([
        "tool": .string("x_search"),
        "surface": .string("telegram"),
        "delegated": .bool(true),
    ]))
    let landed = await sink.hints
    #expect(landed.isEmpty)

    // ...and it still eventually populates once the sink unblocks.
    await sink.waitUntilStarted()
    await sink.open()
    await dispatcher.drainPendingContextPrewarm()
    let after = await sink.hints
    #expect(after.count == 1)
    #expect(after[0].0 == .toolResult)
    #expect(after[0].1 == "x_search")
}

/// The relay is serial on purpose: prewarm hints carry a monotonic revision and
/// dedupe by event id, so bare per-call `Task.detached` would let a turn's tool
/// results reach the planner out of order. This pins submission order.
@Test
func appChatToolDispatcher_prewarmHintsReachThePlannerInDispatchOrder() async throws {
    let capture = ContextPrewarmCapture()
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        organismPostureProvider: { nil },
        contextPrewarm: { kind, id, terms in
            // Uneven work per hint — a racing implementation reorders here.
            try? await Task.sleep(nanoseconds: id == "read_file" ? 5_000_000 : 100_000)
            await capture.record(kind, id: id, terms: terms)
        }
    )

    _ = try await dispatcher.dispatch(tool: "read_file", input: [:], surface: "chat")
    _ = try await dispatcher.dispatch(tool: "x_search", input: [:], surface: "chat")
    _ = try await dispatcher.dispatch(tool: "desk_read", input: [:], surface: "chat")
    await dispatcher.drainPendingContextPrewarm()

    let hints = await capture.hints
    #expect(hints.map { $0.1 } == ["read_file", "x_search", "agent-desk"])
}

/// Both hints for one tool result (the primary hint and the organism-posture
/// follow-up) must stay adjacent and ordered — they were two sequential awaits
/// in the same function before, and the planner keys on that pairing.
@Test
func appChatToolDispatcher_organismPostureHintFollowsItsPrimaryHint() async throws {
    let capture = ContextPrewarmCapture()
    let posture = OrganismBehaviorPosture(
        generatedAt: .distantPast,
        enabled: true,
        posture: "steady",
        claimDiscipline: .normal,
        toolStrategy: .normal,
        directives: []
    )
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        organismPostureProvider: { posture },
        contextPrewarm: { kind, id, terms in
            await capture.record(kind, id: id, terms: terms)
        }
    )

    _ = try await dispatcher.dispatch(tool: "x_search", input: [:], surface: "chat")
    _ = try await dispatcher.dispatch(tool: "desk_read", input: [:], surface: "chat")
    await dispatcher.drainPendingContextPrewarm()

    let hints = await capture.hints
    #expect(hints.map { $0.0 } == [.toolResult, .organism, .desk, .organism])
    // Both hints of a pair carry the identical term vector, as they did when
    // one function body emitted them back to back.
    #expect(hints[0].2 == hints[1].2)
    #expect(hints[2].2 == hints[3].2)
}

/// The hints are computed synchronously from the settled result, so what the
/// planner receives is a pure function of the dispatch — the relay only moves
/// WHEN it is delivered, never WHAT.
@Test
func appChatToolDispatcher_prewarmHintsAreAPureFunctionOfTheSettledCall() {
    let result: JSONValue = .object([
        "tool": .string("read_file"),
        "surface": .string("chat"),
        "delegated": .bool(true),
    ])
    let hints = AppChatToolDispatcher.prewarmHints(
        tool: "read_file",
        input: ["path": .string("docs/map.md"), "limit": .int(10)],
        result: result,
        surface: "chat"
    )
    #expect(hints.count == 1)
    #expect(hints[0].kind == .file)
    #expect(hints[0].id == "docs/map.md")
    #expect(Array(hints[0].terms.prefix(4)) == ["read_file", "chat", "limit", "path"])

    let again = AppChatToolDispatcher.prewarmHints(
        tool: "read_file",
        input: ["path": .string("docs/map.md"), "limit": .int(10)],
        result: result,
        surface: "chat"
    )
    #expect(again.map(\.terms) == hints.map(\.terms))
    #expect(again.map(\.id) == hints.map(\.id))
}

@Test
func appChatToolDispatcher_addsOrganismPostureToObjectResults() async throws {
    let posture = OrganismBehaviorPosture(
        generatedAt: Date(timeIntervalSince1970: 7_000),
        enabled: true,
        posture: "careful",
        claimDiscipline: .verifyBeforeCompletion,
        toolStrategy: .verifyBeforeRetry,
        directives: ["After provider or tool brittleness, verify before saying the work is done."],
        reviewSignals: ["9 reflex candidate(s) require review"],
        approvedReflexBiases: ["Soft preference: use the bounded path."],
        reviewRequiredReflexCount: 9,
        approvedLowRiskReflexTotalCount: 5
    )
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        organismPostureProvider: { posture }
    )

    let result = try await dispatcher.dispatch(tool: "x_search", input: [:], surface: "telegram")
    guard case .object(let object) = result,
          case .object(let organismPosture)? = object["organism_posture"] else {
        Issue.record("organism_posture missing from object-shaped tool result")
        return
    }

    #expect(organismPosture["posture"] == .string("careful"))
    #expect(organismPosture["tool_claims"] == .string("verifyBeforeCompletion"))
    #expect(organismPosture["tool_strategy"] == .string("verifyBeforeRetry"))
    #expect(organismPosture["surface"] == .string("telegram"))
    #expect(organismPosture["directive_count"] == .int(1))
    #expect(organismPosture["review_required_reflex_count"] == .int(9))
    #expect(organismPosture["approved_low_risk_reflex_total_count"] == .int(5))
    #expect(organismPosture["approved_reflex_bias_sample_count"] == .int(1))
    #expect(organismPosture["approved_reflex_biases_are_sampled"] == .bool(true))
    #expect(organismPosture["directives"] == nil)
    #expect(organismPosture["review_signals"] == nil)
    #expect(organismPosture["approved_reflex_biases"] == nil)
}

@Test
func appChatToolDispatcher_exposesNotificationToolsAndDispatchesMobileNotify() async throws {
    let capture = NotificationCapture()
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        mobileNotificationSender: { title, body, userInfo in
            await capture.recordMobile(title: title, body: body, userInfo: userInfo)
            return MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: ["APNS disabled in test"]
            )
        },
        macNotificationSender: { title, body in
            await capture.recordMac(title: title, body: body)
            return NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        }
    )

    let names = try await dispatcher.listAvailableTools()
    #expect(names.contains("mobile.notify"))
    #expect(names.contains("mac.notify"))

    let schemas = try await dispatcher.listAvailableToolSchemas()
    #expect(schemas.map(\.name).contains("mobile.notify"))
    #expect(schemas.map(\.name).contains("mac.notify"))

    let load = try await dispatcher.dispatch(
        tool: "tool_load",
        input: ["category": .string("apns")],
        surface: "telegram"
    )
    let loaded = jsonStringArray(load, key: "loaded")
    #expect(loaded.contains("mobile.notify"))
    #expect(loaded.contains("mac.notify"))

    let catalog = try await dispatcher.dispatch(
        tool: "tool_catalog",
        input: [:],
        surface: "telegram"
    )
    #expect(jsonBool(catalog, key: "delegated") == true)
    #expect(jsonStringArray(catalog, key: "available_tools").contains("mobile.notify"))
    #expect(jsonStringArray(catalog, key: "notification_tools").contains("mac.notify"))

    let result = try await dispatcher.dispatch(
        tool: "mobile.notify",
        input: [
            "title": .string("Build update"),
            "message": .string("short ping"),
            "screen": .string("activity"),
            "urgency": .string("urgent"),
        ],
        surface: "telegram"
    )

    #expect(jsonString(result, key: "status") == "queued")
    #expect(jsonString(result, key: "delivery") == "queued_to_icloud_bridge")
    #expect(jsonBool(result, key: "bridgeQueued") == true)
    #expect(jsonBool(result, key: "apnsSent") == false)
    #expect(jsonString(result, key: "bridgeMessageId") == "bridge-test")

    let mobile = await capture.mobile
    #expect(mobile.count == 1)
    #expect(mobile.first?.title == "Build update")
    #expect(mobile.first?.body == "short ping")
    #expect(mobile.first?.userInfo["screen"] == "activity")
    #expect(mobile.first?.userInfo["surface"] == "telegram")
    #expect(mobile.first?.userInfo["urgency"] == "urgent")

    let macResult = try await dispatcher.dispatch(
        tool: "mac.notify",
        input: [
            "title": .string("Build update"),
            "message": .string("mac ping"),
        ],
        surface: "telegram"
    )
    #expect(jsonString(macResult, key: "status") == "completed")
    #expect(jsonString(macResult, key: "delivery") == "posted_to_macos_notification_center")
    #expect(jsonBool(macResult, key: "posted") == true)
    #expect(jsonBool(macResult, key: "visibleAlertsEnabled") == true)

    let mac = await capture.mac
    #expect(mac.count == 1)
    #expect(mac.first?.title == "Build update")
    #expect(mac.first?.body == "mac ping")
}

// Eval coverage ledger — `tools.macIntegrationNotifyGate`.
@Test
func appChatToolDispatcher_notifyPermissionGateAllowsWriteAndSuppressesBothDeniedEffects() async throws {
    let root = try makeDispatcherTestRoot("notify-permission-boundary")
    defer { try? FileManager.default.removeItem(at: root) }
    let permissions = MacIntegrationPermissionStore(dataRoot: root)
    for integration in [MacIntegrationID.notifyMobile, MacIntegrationID.notifyMac] {
        try await permissions.set(integrationId: integration, read: false, write: true)
    }
    let capture = NotificationCapture()
    let activeToolsStore = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        activeToolsStore: activeToolsStore,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
        enforceAutonomySecurity: false,
        mobileNotificationSender: { title, body, userInfo in
            await capture.recordMobile(title: title, body: body, userInfo: userInfo)
            return MobileNotificationDeliveryReceipt(
                bridgeMessageID: "allowed-mobile",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { title, body in
            await capture.recordMac(title: title, body: body)
            return NativeAgentNotificationPostResult(
                identifier: "allowed-mac",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        macIntegrationPermissionStore: permissions,
        organismPostureProvider: { nil }
    )

    let allowedMobile = try await dispatcher.dispatch(
        tool: "mobile.notify",
        input: ["title": .string("Allowed mobile"), "message": .string("deliver once")],
        surface: "telegram"
    )
    let allowedMac = try await dispatcher.dispatch(
        tool: "mac.notify",
        input: ["title": .string("Allowed Mac"), "message": .string("deliver once")],
        surface: "telegram"
    )
    #expect(jsonString(allowedMobile, key: "bridgeMessageId") == "allowed-mobile")
    #expect(jsonString(allowedMac, key: "notificationId") == "allowed-mac")
    #expect(await capture.mobile.count == 1)
    #expect(await capture.mac.count == 1)

    // Negative control: read remains enabled while write is revoked. Both
    // aliases must return the denial envelope before either injected effect.
    for integration in [MacIntegrationID.notifyMobile, MacIntegrationID.notifyMac] {
        try await permissions.set(integrationId: integration, read: true, write: false)
    }
    let deniedMobile = try await dispatcher.dispatch(
        tool: "mobile_notify",
        input: ["title": .string("Denied mobile"), "message": .string("must not deliver")],
        surface: "telegram"
    )
    let deniedMac = try await dispatcher.dispatch(
        tool: "mac_notify",
        input: ["title": .string("Denied Mac"), "message": .string("must not deliver")],
        surface: "telegram"
    )
    for (result, integration) in [
        (deniedMobile, MacIntegrationID.notifyMobile),
        (deniedMac, MacIntegrationID.notifyMac),
    ] {
        #expect(jsonString(result, key: "status") == "denied")
        #expect(jsonString(result, key: "reason") == "integration_permission_denied")
        #expect(jsonString(result, key: "integration") == integration)
        #expect(jsonString(result, key: "mode") == "write")
    }
    #expect(await capture.mobile.count == 1,
            "mobile permission denial must not invoke the injected sender")
    #expect(await capture.mac.count == 1,
            "Mac permission denial must not invoke the injected notifier")
}

@Test
func mobileNotificationReceiptDescribesCloudKitVisualDeliveryWithoutForegroundRequirement() {
    let receipt = MobileNotificationDeliveryReceipt(
        bridgeMessageID: "cloudkit-message",
        bridgeError: nil,
        apnsReceipts: [],
        apnsErrors: ["Direct APNS unavailable"],
        eventID: String(repeating: "a", count: 64),
        cloudKitVisualPushEligible: true
    )
    let fields = receipt.deliveryFields()

    #expect(receipt.status == "queued")
    #expect(receipt.route == "cloudkit_visual_notification")
    #expect(receipt.delivery == "queued_to_cloudkit_visual_notification")
    #expect(fields["requiresIOSAppActiveForBridge"] == .bool(false))
    #expect(fields["cloudKitVisualPushEligible"] == .bool(true))
    #expect(fields["providerAcceptanceOnly"] == .bool(false))
    #expect(fields["lockScreenDisplayVerified"] == .bool(false))
    #expect(fields["deliveryVerification"] == .string("device_display_unverified"))
}

@Test
func mobileNotificationReceiptNeverClaimsLockScreenDisplayFromAPNSAcceptance() {
    let receipt = MobileNotificationDeliveryReceipt(
        bridgeMessageID: nil,
        bridgeError: nil,
        apnsReceipts: [
            SwiftNativeAPNSReceipt(
                apnsId: "provider-receipt",
                createdAt: "2026-07-29T10:10:42Z",
                status: "ok",
                httpStatus: 200,
                response: "",
                tokenSuffix: "12345678",
                deviceId: "ios",
                tokenSource: "test",
                tokenUpdatedAt: "2026-07-29T10:00:00Z",
                tokenAgeSeconds: 642,
                environment: "production",
                topic: "io.github.embwl0x.nativeagent.ios",
                error: nil
            )
        ],
        apnsErrors: [],
        eventID: String(repeating: "b", count: 64),
        cloudKitVisualPushEligible: true
    )
    let fields = receipt.deliveryFields()

    #expect(receipt.apnsAccepted)
    #expect(fields["providerAcceptanceOnly"] == .bool(true))
    #expect(fields["lockScreenDisplayVerified"] == .bool(false))
    #expect(
        fields["deliveryVerification"]
            == .string("provider_accepted_device_display_unverified")
    )
}

/// Records every tool name it is asked to dispatch, so a test can prove the
/// app shim intercepts notify BEFORE delegating to core.
private actor RecordingInnerToolDispatcher: ToolDispatchClient {
    struct Call: Sendable {
        let tool: String
        let input: [String: JSONValue]
        let surface: String
    }

    private(set) var dispatchedTools: [String] = []
    private(set) var calls: [Call] = []

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        dispatchedTools.append(tool)
        calls.append(Call(tool: tool, input: input, surface: surface))
        return .object([
            "tool": .string(tool),
            "surface": .string(surface),
            "delegated": .bool(true),
        ])
    }

    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

/// The app shell must not reinterpret provider-materialized optional fields.
/// Mac, Telegram, Slack, and iOS all reach the same core memory dispatcher;
/// this pins the wrapper seam that sits between every surface and that owner.
@Test
func appChatToolDispatcher_preservesStrictCommitMemoryPayloadAcrossSurfaces() async throws {
    let inner = RecordingInnerToolDispatcher()
    let dispatcher = AppChatToolDispatcher(
        inner: inner,
        enforceAutonomySecurity: false,
        organismPostureProvider: { nil },
        contextPrewarm: { _, _, _ in }
    )
    let strictPayload: [String: JSONValue] = [
        "text": .string("User prefers a warm conversational tone."),
        "kind": .string("preference"),
        "tags": .array([]),
        "confidence": .double(0.8),
        "importance": .double(0.5),
        "corrects": .string(""),
        "correction_reason": .string(""),
        "context_topics": .array([]),
    ]
    let surfaces = ["chat", "telegram", "slack", "ios"]

    for surface in surfaces {
        _ = try await dispatcher.dispatch(
            tool: "commit_memory",
            input: strictPayload,
            surface: surface
        )
    }

    let calls = await inner.calls
    #expect(calls.count == surfaces.count)
    #expect(calls.map(\.tool) == Array(repeating: "commit_memory", count: surfaces.count))
    #expect(calls.map(\.surface) == surfaces)
    for call in calls {
        #expect(call.input == strictPayload)
    }
}

/// B5 (tightness-sweep 2026-07-17): the app shim is the SINGLE owner of
/// mac_notify / mobile_notify on wrapped chat surfaces. Core's SwiftToolDispatcher
/// carries its own `mac_notify` / `mobile_notify` cases; this proves they are
/// shadowed — `inner.dispatch` is never reached for the notify tools, including
/// the provider-safe underscore aliases (`mobile_notify` / `mac_notify`) whose
/// names collide exactly with core's cases. The injected senders (the same
/// NativeAgentNotifications + MacSyncEngine backends core would reach) fire, and
/// the result envelope is the shim's shape, not the delegated marker.
@Test
func appChatToolDispatcher_notifyIsSingleOwner_innerNeverReached() async throws {
    let capture = NotificationCapture()
    let inner = RecordingInnerToolDispatcher()
    let dispatcher = AppChatToolDispatcher(
        inner: inner,
        enforceAutonomySecurity: false,
        mobileNotificationSender: { title, body, userInfo in
            await capture.recordMobile(title: title, body: body, userInfo: userInfo)
            return MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: ["APNS disabled in test"]
            )
        },
        macNotificationSender: { title, body in
            await capture.recordMac(title: title, body: body)
            return NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        }
    )

    // Underscore provider aliases — the exact names core's cases match.
    let mobileResult = try await dispatcher.dispatch(
        tool: "mobile_notify",
        input: ["message": .string("ping")],
        surface: "telegram"
    )
    let macResult = try await dispatcher.dispatch(
        tool: "mac_notify",
        input: ["message": .string("ping")],
        surface: "telegram"
    )

    // Shim owned both: senders fired, and the shim's envelope shape came back
    // (never the delegated marker `inner` returns).
    #expect(await capture.mobile.count == 1)
    #expect(await capture.mac.count == 1)
    #expect(jsonString(mobileResult, key: "status") == "queued")
    #expect(jsonBool(mobileResult, key: "delegated") != true)
    #expect(jsonString(macResult, key: "status") == "completed")
    #expect(jsonBool(macResult, key: "delegated") != true)

    // Core's mac_notify / mobile_notify cases are shadowed: inner never saw them.
    let seen = await inner.dispatchedTools
    #expect(!seen.contains("mobile_notify"))
    #expect(!seen.contains("mac_notify"))
    #expect(!seen.contains("mobile.notify"))
    #expect(!seen.contains("mac.notify"))
}

@Test
func appChatToolDispatcher_exposesVisibleBrowserToolsAndDispatchesStatusAlias() async throws {
    let capture = BrowserToolCapture()
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        browserActionRunner: { actionId, dryRun, input in
            await capture.record(actionId: actionId, dryRun: dryRun, input: input)
            return .object([
                "status": .string("ready"),
                "actionId": .string(actionId),
                "dryRun": .bool(dryRun),
            ])
        }
    )

    let names = try await dispatcher.listAvailableTools()
    #expect(names.contains("browser.status"))
    #expect(names.contains("browser.navigate"))
    #expect(names.contains("browser.read_text"))
    #expect(names.contains("browser.read_links"))
    #expect(names.contains("browser.screenshot"))
    #expect(names.contains("browser.chrome_acquire"))
    #expect(names.contains("browser.chrome_renew"))
    #expect(names.contains("browser.chrome_navigate"))
    #expect(names.contains("browser.chrome_snapshot"))
    #expect(names.contains("browser.chrome_click"))
    #expect(names.contains("browser.chrome_fill"))
    #expect(names.contains("browser.chrome_type"))
    #expect(names.contains("browser.chrome_select"))
    #expect(names.contains("browser.chrome_keypress"))
    #expect(names.contains("browser.chrome_set_checked"))
    #expect(names.contains("browser.chrome_double_click"))
    #expect(names.contains("browser.chrome_wait"))
    #expect(names.contains("browser.chrome_scroll"))
    #expect(names.contains("browser.chrome_release"))

    let schemas = try await dispatcher.listAvailableToolSchemas()
    #expect(schemas.map(\.name).contains("browser.status"))
    #expect(schemas.map(\.name).contains("browser.navigate"))
    #expect(schemas.map(\.name).contains("browser.chrome_snapshot"))
    #expect(schemas.map(\.name).contains("browser.chrome_click"))
    #expect(schemas.map(\.name).contains("browser.chrome_fill"))
    #expect(schemas.map(\.name).contains("browser.chrome_type"))
    #expect(schemas.map(\.name).contains("browser.chrome_select"))
    #expect(schemas.map(\.name).contains("browser.chrome_keypress"))
    #expect(schemas.map(\.name).contains("browser.chrome_set_checked"))
    #expect(schemas.map(\.name).contains("browser.chrome_double_click"))
    #expect(schemas.map(\.name).contains("browser.chrome_wait"))

    let catalog = try await dispatcher.dispatch(
        tool: "tool_catalog",
        input: ["detail": .string("full")],
        surface: "chat"
    )
    #expect(jsonStringArray(catalog, key: "browser_tools").contains("browser.status"))
    let rows = jsonObjectArray(catalog, key: "tools")
    #expect(rows.contains { row in
        jsonString(.object(row), key: "name") == "browser.status"
            && jsonString(.object(row), key: "provider_alias") == "browser_status"
    })

    let result = try await dispatcher.dispatch(
        tool: "browser_status",
        input: [:],
        surface: "chat"
    )
    #expect(jsonString(result, key: "status") == "ready")
    #expect(jsonString(result, key: "tool") == "browser.status")
    #expect(jsonString(result, key: "provider_alias") == "browser_status")

    let calls = await capture.calls
    #expect(calls.count == 1)
    #expect(calls.first?.actionId == "browser.status")
    #expect(calls.first?.dryRun == false)
}

@Test
func everyRegisteredBrowserToolMapsValidInputToTheAppRunner() async throws {
    let capture = BrowserToolCapture()
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        enforceAutonomySecurity: false,
        browserActionRunner: { actionId, dryRun, input in
            await capture.record(actionId: actionId, dryRun: dryRun, input: input)
            return .object([
                "status": .string("fixture"),
                "runner_action": .string(actionId),
            ])
        },
        organismPostureProvider: { nil }
    )
    let stable: [String: JSONValue] = [
        "lease_id": .string("lease-fixture"),
        "expected_user_sequence": .int(0),
        "snapshot_id": .string("snapshot-fixture"),
        "node_id": .string("node-fixture"),
    ]
    let cases: [(String, [String: JSONValue])] = [
        ("browser.status", [:]),
        ("browser.open_url", ["url": .string("https://example.com/"), "dry_run": .bool(true)]),
        ("browser.navigate", ["url": .string("https://example.com/next"), "dry_run": .bool(true)]),
        ("browser.read_text", ["dry_run": .bool(true)]),
        ("browser.read_links", ["dry_run": .bool(true)]),
        ("browser.screenshot", ["dry_run": .bool(true)]),
        ("browser.chrome_acquire", ["mode": .string("create"), "initial_url": .string("https://example.com/")]),
        // 2026-09-06: browser.chrome_renew joined the catalog (c9687dec) — a
        // lease has a hard 60s ceiling without it.
        ("browser.chrome_renew", [
            "lease_id": .string("lease-fixture"),
            "expected_user_sequence": .int(0),
            "lease_duration_ms": .int(60000),
        ]),
        ("browser.chrome_navigate", stable.merging(["url": .string("https://example.com/next")]) { _, new in new }),
        ("browser.chrome_snapshot", ["lease_id": .string("lease-fixture"), "max_nodes": .int(20)]),
        ("browser.chrome_click", stable),
        ("browser.chrome_fill", stable.merging(["value": .string("replacement")]) { _, new in new }),
        ("browser.chrome_type", stable.merging(["text": .string(" appended"), "delay_ms": .int(0)]) { _, new in new }),
        ("browser.chrome_select", stable.merging(["values": .array([.string("pro")])]) { _, new in new }),
        ("browser.chrome_keypress", stable.merging(["key": .string("Enter")]) { _, new in new }),
        ("browser.chrome_set_checked", stable.merging(["checked": .bool(true)]) { _, new in new }),
        ("browser.chrome_double_click", stable),
        ("browser.chrome_wait", stable.merging([
            "condition": .string("element_state"),
            "state": .string("visible"),
            "timeout_ms": .int(100),
        ]) { _, new in new }),
        ("browser.chrome_scroll", stable.merging(["delta_x": .int(0), "delta_y": .int(240)]) { _, new in new }),
        ("browser.chrome_release", ["lease_id": .string("lease-fixture"), "close_created_tab": .bool(false)]),
    ]

    #expect(Set(cases.map(\.0)) == Set(
        AppChatToolDispatcher.catalogRegisteredToolNames.filter { $0.hasPrefix("browser.") }
    ))
    for (tool, input) in cases {
        let result = try await dispatcher.dispatch(tool: tool, input: input, surface: "chat")
        #expect(jsonString(result, key: "tool") == tool)
        #expect(jsonString(result, key: "runner_action") == tool)
        #expect(jsonString(result, key: "surface") == "chat")
    }
    let calls = await capture.calls
    #expect(calls.map(\.actionId) == cases.map(\.0))
    #expect(calls.map(\.input) == cases.map(\.1))
}

@Test
func nativeActionReceiptDecodesBrowserTextSummaryFields() throws {
    let json = """
    {
      "id": "browser-text-test",
      "actionId": "browser.read_text",
      "name": "Read Browser Text",
      "kind": "browser",
      "status": "completed",
      "dryRun": false,
      "approvalId": null,
      "url": "https://swift.org",
      "pngPath": "/tmp/browser-shot.png",
      "textPath": "/tmp/browser-text.txt",
      "textPreview": "Swift concurrency diagnostics",
      "textChars": 29,
      "linksPath": "/tmp/browser-links.json",
      "linkCount": 2,
      "linksPreview": [
        {
          "url": "https://swift.org/blog/",
          "text": "Swift Blog"
        },
        {
          "url": "https://swift.org/download/",
          "text": "Download Swift"
        }
      ],
      "createdAt": "2026-06-20T10:00:00Z"
    }
    """.data(using: .utf8)!
    let receipt = try JSONDecoder.nativeAgent.decode(NativeActionReceipt.self, from: json)
    #expect(receipt.actionId == "browser.read_text")
    #expect(receipt.url == "https://swift.org")
    #expect(receipt.pngPath == "/tmp/browser-shot.png")
    #expect(receipt.textPath == "/tmp/browser-text.txt")
    #expect(receipt.textPreview == "Swift concurrency diagnostics")
    #expect(receipt.textChars == 29)
    #expect(receipt.linksPath == "/tmp/browser-links.json")
    #expect(receipt.linkCount == 2)
    #expect(receipt.linksPreview?.map(\.text) == ["Swift Blog", "Download Swift"])
    #expect(receipt.linksPreview?.first?.url == "https://swift.org/blog/")
}

@Test
func appChatToolDispatcher_toolLoadBrowserCategoryPersistsSessionActiveTools() async throws {
    let root = try makeDispatcherTestRoot("browser-category")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        browserActionRunner: { actionId, dryRun, _ in
            .object(["status": .string("ok"), "actionId": .string(actionId), "dryRun": .bool(dryRun)])
        }
    )
    let sessionId = "browser-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("browser"),
        ],
        surface: "chat"
    )

    #expect(jsonString(result, key: "status") == "loaded")
    #expect(jsonString(result, key: "category") == "browser")
    let activeTools = jsonStringArray(result, key: "active_tools")
    #expect(activeTools.contains("browser.status"))
    #expect(activeTools.contains("browser.navigate"))
    #expect(activeTools.contains("browser.screenshot"))
    let schemas = jsonObjectArray(result, key: "schemas_added")
    #expect(schemas.contains { jsonString(.object($0), key: "name") == "browser.status" })
    #expect(schemas.contains { jsonString(.object($0), key: "name") == "browser.navigate" })

    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.contains("browser.status"))
    #expect(state.activeTools.contains("browser.navigate"))
    #expect(state.activeTools.contains("browser.read_links"))

    let catalog = try await dispatcher.dispatch(
        tool: "tool_catalog",
        input: [
            "session_id": .string(sessionId),
            "detail": .string("full"),
        ],
        surface: "chat"
    )
    #expect(jsonStringArray(catalog, key: "currently_loaded").contains("browser.status"))
    #expect(jsonStringArray(catalog, key: "currently_loaded").contains("browser.navigate"))
    #expect(!jsonStringArray(catalog, key: "discovery_only_tools").contains("browser.status"))
    let rows = jsonObjectArray(catalog, key: "tools")
    #expect(rows.contains { row in
        jsonString(.object(row), key: "name") == "browser.status"
            && jsonString(.object(row), key: "load_state") == "loaded"
    })
}

@Test
func appChatToolDispatcher_toolLoadBrowserCategorySkipsPersistingTurnActiveTools() async throws {
    let root = try makeDispatcherTestRoot("browser-turn-active")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        browserActionRunner: { actionId, dryRun, _ in
            .object(["status": .string("ok"), "actionId": .string(actionId), "dryRun": .bool(dryRun)])
        }
    )
    let sessionId = "browser-turn-active-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")

    // 2026-09-06: was a hand-copied list, which went stale the moment
    // browser.chrome_renew joined the category (c9687dec) — the new tool showed
    // up in `loaded_now` and the test read as a persistence regression. The
    // premise being set up is "the whole browser category is ALREADY turn-active",
    // so take the category from the dispatcher that defines it.
    let browserTurnTools: Set<String> = Set(
        AppChatToolDispatcher.catalogRegisteredToolNames.filter {
            AppChatToolDispatcher.catalogBucket(forRegisteredToolNamed: $0) == .browser
        }
    )
    let result = try await LLMCallContext.$turnActiveTools.withValue(browserTurnTools) {
        try await dispatcher.dispatch(
            tool: "tool_load",
            input: [
                "session_id": .string(sessionId),
                "category": .string("browser"),
            ],
            surface: "chat"
        )
    }

    #expect(jsonString(result, key: "status") == "loaded")
    #expect(jsonStringArray(result, key: "loaded_now").isEmpty)
    #expect(jsonStringArray(result, key: "already_active").contains("browser.navigate"))
    #expect(jsonStringArray(result, key: "turn_active").contains("browser.navigate"))
    #expect(jsonStringArray(result, key: "active_tools").contains("browser.navigate"))
    #expect(jsonObjectArray(result, key: "schemas_added").isEmpty)
    #expect(jsonString(result, key: "next_turn_note")?.contains("no session loadout changed") == true)
    #expect(jsonString(result, key: "mode") == "persisted_session_load")
    #expect(jsonString(result, key: "category") == "browser")
    #expect(jsonInt(result, key: "session_active_count") == 0)

    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: activePath.path))

    let catalog = try await LLMCallContext.$turnActiveTools.withValue(browserTurnTools) {
        try await dispatcher.dispatch(
            tool: "tool_catalog",
            input: ["session_id": .string(sessionId)],
            surface: "chat"
        )
    }
    #expect(jsonStringArray(catalog, key: "currently_loaded").contains("browser.navigate"))
    #expect(jsonStringArray(catalog, key: "turn_active_tools").contains("browser.navigate"))
    #expect(!jsonStringArray(catalog, key: "discovery_only_tools").contains("browser.navigate"))
}

@Test
func appChatToolDispatcher_toolLoadResearchCategoryLoadsBrowserOnly() async throws {
    let root = try makeDispatcherTestRoot("research-category")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        browserActionRunner: { actionId, dryRun, _ in
            .object(["status": .string("ok"), "actionId": .string(actionId), "dryRun": .bool(dryRun)])
        }
    )
    let sessionId = "research-\(UUID().uuidString)"

    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("research"),
        ],
        surface: "chat"
    )

    #expect(jsonString(result, key: "status") == "loaded")
    #expect(jsonString(result, key: "category") == "browser")
    let loaded = jsonStringArray(result, key: "loaded")
    #expect(loaded.contains("browser.open_url"))
    #expect(loaded.contains("browser.read_links"))
    #expect(!loaded.contains("x_search"))
    let activeTools = jsonStringArray(result, key: "active_tools")
    #expect(activeTools.contains("browser.open_url"))
    #expect(activeTools.contains("browser.read_text"))
    #expect(!activeTools.contains("x_search"))

    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.contains("browser.open_url"))
    #expect(state.activeTools.contains("browser.read_links"))
    #expect(!state.activeTools.contains("x_search"))
}

@Test
func appChatToolDispatcher_delegatesNonAppToolsToInnerDispatcher() async throws {
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(),
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        }
    )

    let result = try await dispatcher.dispatch(
        tool: "read_file",
        input: ["path": .string("persona/SOUL.md")],
        surface: "chat"
    )
    #expect(jsonBool(result, key: "delegated") == true)
    #expect(jsonString(result, key: "tool") == "read_file")
}

@Test
func appChatToolDispatcher_mixedToolLoadForwardsBrowserAndCoreTools() async throws {
    let root = try makeDispatcherTestRoot("mixed-browser")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        },
        browserActionRunner: { actionId, dryRun, _ in
            .object(["status": .string("ok"), "actionId": .string(actionId), "dryRun": .bool(dryRun)])
        }
    )
    let sessionId = "mixed-browser-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "names": .array([.string("browser_status"), .string("read_file")]),
        ],
        surface: "chat"
    )

    #expect(jsonBool(result, key: "delegated") == true)
    #expect(jsonString(result, key: "category") == "mixed")
    let active = jsonStringArray(result, key: "active_tools")
    #expect(active.contains("browser.status"))
    #expect(active.contains("read_file"))

    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.contains("browser.status"))
    #expect(state.activeTools.contains("read_file"))
}

@Test
func appChatToolDispatcher_toolLoadNotificationsPersistsSessionActiveTools() async throws {
    let root = try makeDispatcherTestRoot("notify-category")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test",
                bridgeError: nil,
                apnsReceipts: [],
                apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test",
                status: "completed",
                delivery: "posted_to_macos_notification_center",
                posted: true,
                visibleAlertsEnabled: true,
                authorizationStatus: "authorized",
                alertSetting: "enabled",
                soundSetting: "enabled",
                badgeSetting: "enabled",
                error: nil
            )
        }
    )
    let sessionId = "notify-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "category": .string("notifications"),
        ],
        surface: "chat"
    )

    #expect(jsonString(result, key: "status") == "loaded")
    #expect(jsonString(result, key: "mode") == "persisted_session_load")
    let activeTools = jsonStringArray(result, key: "active_tools")
    #expect(activeTools.contains("mac.notify"))
    #expect(activeTools.contains("mobile.notify"))
    #expect(!activeTools.contains("read_file"))
    let schemas = jsonObjectArray(result, key: "schemas_added")
    #expect(schemas.contains { jsonString(.object($0), key: "name") == "mac.notify" })
    #expect(schemas.contains { jsonString(.object($0), key: "name") == "mobile.notify" })

    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.contains("mac.notify"))
    #expect(state.activeTools.contains("mobile.notify"))
}

@Test
func appChatToolDispatcher_mixedToolLoadForwardsNonNotificationToInner() async throws {
    // loop-C regression: a tool_load batch mixing a notification tool with a
    // normal tool used to short-circuit into the notification-only loader and
    // SILENTLY DROP the normal tool. The split must load the notification
    // subset locally AND forward the rest to the inner dispatcher.
    let root = try makeDispatcherTestRoot("mixed-notify")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test", bridgeError: nil, apnsReceipts: [], apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test", status: "completed",
                delivery: "posted_to_macos_notification_center", posted: true,
                visibleAlertsEnabled: true, authorizationStatus: "authorized",
                alertSetting: "enabled", soundSetting: "enabled", badgeSetting: "enabled", error: nil
            )
        }
    )
    let sessionId = "mixed-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "names": .array([.string("mobile.notify"), .string("read_file")]),
        ],
        surface: "chat"
    )

    // The non-notification subset (read_file) reached the inner dispatcher —
    // the stub stamps delegated:true on whatever it handles. Before the fix
    // this key was absent because inner was never invoked.
    #expect(jsonBool(result, key: "delegated") == true)
    #expect(jsonString(result, key: "category") == "mixed")
    // Authoritative active_tools (re-read from the store) reflects BOTH the
    // notification tool AND the forwarded read_file — core tool_load doesn't
    // echo active_tools, so the merge must re-read the store.
    let active = jsonStringArray(result, key: "active_tools")
    #expect(active.contains("mobile.notify"))
    #expect(active.contains("read_file"))
    // Both subsets persisted to the session store.
    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.contains("mobile.notify"))
    #expect(state.activeTools.contains("read_file"))
}

@Test
func appChatToolDispatcher_mixedToolLoadHandlesSingularNameField() async throws {
    // tool_load also accepts a singular `name` (core reads it). A notif tool in
    // `names` + a normal tool in `name` is still a mixed batch and must not
    // drop the singular one (gpt-5.5 review).
    let root = try makeDispatcherTestRoot("singular-name")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test", bridgeError: nil, apnsReceipts: [], apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test", status: "completed",
                delivery: "posted_to_macos_notification_center", posted: true,
                visibleAlertsEnabled: true, authorizationStatus: "authorized",
                alertSetting: "enabled", soundSetting: "enabled", badgeSetting: "enabled", error: nil
            )
        }
    )
    let sessionId = "singular-\(UUID().uuidString)"
    let activePath = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("active_tools", isDirectory: true)
        .appendingPathComponent("\(sessionId).json")
    defer { try? FileManager.default.removeItem(at: activePath) }

    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionId),
            "names": .array([.string("mobile.notify")]),
            "name": .string("read_file"),
        ],
        surface: "chat"
    )
    #expect(jsonString(result, key: "category") == "mixed")
    let state = await store.load(sessionId: sessionId)
    #expect(state.activeTools.contains("mobile.notify"))
    #expect(state.activeTools.contains("read_file"))
}

@Test
func appChatToolDispatcher_pureSingularNotificationNameLoadsOnlyThatTool() async throws {
    // Pure notification load via the singular `name` must honor it, not fall
    // through to the load-both default (gpt-5.5 review r2).
    let root = try makeDispatcherTestRoot("pure-singular")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    let dispatcher = AppChatToolDispatcher(
        inner: StubInnerToolDispatcher(activeToolsStore: store),
        activeToolsStore: store,
        mobileNotificationSender: { _, _, _ in
            MobileNotificationDeliveryReceipt(
                bridgeMessageID: "bridge-test", bridgeError: nil, apnsReceipts: [], apnsErrors: []
            )
        },
        macNotificationSender: { _, _ in
            NativeAgentNotificationPostResult(
                identifier: "mac-test", status: "completed",
                delivery: "posted_to_macos_notification_center", posted: true,
                visibleAlertsEnabled: true, authorizationStatus: "authorized",
                alertSetting: "enabled", soundSetting: "enabled", badgeSetting: "enabled", error: nil
            )
        }
    )
    let sessionId = "singname-\(UUID().uuidString)"
    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: ["session_id": .string(sessionId), "name": .string("mobile.notify")],
        surface: "chat"
    )
    let loaded = jsonStringArray(result, key: "loaded")
    #expect(loaded.contains("mobile.notify"))
    #expect(!loaded.contains("mac.notify"))
}

@Test
func cloudKitAccountProbe_requiresExplicitOptIn() {
    #expect(nativeAgentCloudKitAccountProbeEnabled(environment: [:]) == false)
    #expect(nativeAgentCloudKitAccountProbeEnabled(environment: ["NATIVE_AGENT_ENABLE_CLOUDKIT": "0"]) == false)
    #expect(nativeAgentCloudKitAccountProbeEnabled(
        environment: ["NATIVE_AGENT_ENABLE_CLOUDKIT": "true"],
        hasCloudKitEntitlement: { false }
    ) == false)
    #expect(nativeAgentCloudKitAccountProbeEnabled(
        environment: ["NATIVE_AGENT_ENABLE_CLOUDKIT": " yes "],
        hasCloudKitEntitlement: { true }
    ) == true)
}

@Test
func liveMobileNotify_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_MOBILE_NOTIFY_TEST"] == "1" else {
        return
    }
    let receipt = try await MacSyncEngine.shared.sendNotificationToPairedDevices(
        title: "NativeAgent",
        body: "Codex live push test through Swift APNS.",
        userInfo: [
            "screen": "activity",
            "source": "codex_live_test",
            "urgency": "normal",
        ]
    )
    let receiptData = try JSONValue.object(receipt.deliveryFields()).serializedData(pretty: true)
    print("liveMobileNotify receipt: \(String(decoding: receiptData, as: UTF8.self))")
    #expect(receipt.apnsSent || receipt.bridgeQueued)
}

@Test
func liveAppChatStream_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_APP_CHAT_STREAM_TEST"] == "1" else {
        return
    }
    let client = makeNativeAgentAppChatOrchestrationClient(profile: .mac)
    let sessionId = "nativeagent-app-test-\(UUID().uuidString.prefix(8))"
    var output = ""
    var finalReply: String?
    var errorMessage: String?
    for try await event in client.chatStream(
        message: "codex live app stream probe",
        sessionId: sessionId,
        model: "gpt-5.5",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        persona: nil,
        surface: "chat",
        suppressUserAppend: false
    ) {
        switch event {
        case .delta(let text):
            output += text
        case .final(let result):
            finalReply = result.reply
        case .error(let message):
            errorMessage = message
        case .toolUse, .toolResult, .notice:
            break
        }
    }
    if let errorMessage {
        Issue.record("live app chat stream error: \(errorMessage)")
    }
    let reply = finalReply ?? output
    #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test
func appChatToolFactoryPersistsLazyLoadOnlyUnderInjectedRoot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-chat-factory-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "root-isolation-\(UUID().uuidString)"
    let relative = "chat/active_tools/\(sessionID).json"
    let injectedPath = root.appendingPathComponent(relative)
    // 2026-07-21 audit: the live path is asserted read-only — a leak must
    // stay on disk as failure evidence; tests never delete under the live
    // data root.
    let livePath = PersistenceCore.defaultDataRoot().appendingPathComponent(relative)

    let dispatcher = makeNativeAgentAppToolDispatchClient(
        includeEvolutionBridge: false,
        enforceAppAutonomy: false,
        dataRoot: root
    )
    let result = try await dispatcher.dispatch(
        tool: "tool_load",
        input: [
            "session_id": .string(sessionID),
            "names": .array([.string("read_file")]),
        ],
        surface: "chat"
    )

    #expect(jsonString(result, key: "status") == "loaded")
    #expect(FileManager.default.fileExists(atPath: injectedPath.path))
    #expect(!FileManager.default.fileExists(atPath: livePath.path))
    let names = try await dispatcher.listAvailableTools()
    #expect(!names.contains("mobile.notify"))
    #expect(!names.contains("browser.open_url"))
    #expect(!names.contains("doctor_status"))
    #expect(!names.contains("telegram_status"))
    #expect(!names.contains("reflex_review"))
    #expect(!names.contains("restart_app"))
    #expect(!names.contains("x_status"))
    let blocked = try await dispatcher.dispatch(
        tool: "restart_app", input: [:], surface: "chat"
    )
    // REBASELINED for the settled YOLO gate model (947c6a7c, USER YOLO
    // 2026-08-12): criticalRequiresDeveloperMode is false by design, so the
    // Developer-Mode refusal no longer fires. The guarantee this test pins is
    // unchanged — a bare chat dispatch of a critical lifecycle action is
    // REFUSED before reaching any process-global owner — the refusal now
    // comes from the canonical-body confinement one layer deeper.
    #expect(jsonString(blocked, key: "status") == "failed")
    #expect(jsonString(blocked, key: "reason") == "canonical_body_unavailable")
}

@Test
func liveProviderList_openAIOAuthVisible_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_PROVIDER_LIST_TEST"] == "1" else {
        return
    }
    let providers = try await NativeClient(baseURL: "").listProviders()
    let states = providers.map { "\($0.provider_id)=\($0.auth_status.state)" }.joined(separator: ", ")
    print("live provider states: \(states)")
    let openAI = try #require(providers.first(where: { $0.provider_id == "openai_oauth_direct" }))
    let astra = try #require(openAI.models.first { $0.id == "gpt-6-astra" })
    #expect(astra.default_reasoning_effort == "medium")
    #expect(astra.supported_reasoning_efforts == ["low", "medium", "high", "xhigh", "max", "ultra"])
    #expect(astra.supports_fast == true)
    #expect(openAI.auth_status.state == "ready")
    let gpt56 = openAI.models.filter { $0.id.hasPrefix("gpt-5.6-") }
    print("live ChatGPT OAuth GPT-5.6 models: \(gpt56.map(\.id).joined(separator: ", "))")
    #expect(Set(gpt56.map(\.id)).isSuperset(of: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]))
    let sol = try #require(gpt56.first { $0.id == "gpt-5.6-sol" })
    let terra = try #require(gpt56.first { $0.id == "gpt-5.6-terra" })
    let luna = try #require(gpt56.first { $0.id == "gpt-5.6-luna" })
    #expect(sol.supported_reasoning_efforts == ["low", "medium", "high", "xhigh", "max", "ultra"])
    #expect(terra.supported_reasoning_efforts == ["low", "medium", "high", "xhigh", "max", "ultra"])
    #expect(luna.supported_reasoning_efforts == ["low", "medium", "high", "xhigh", "max"])
    #expect([sol, terra, luna].allSatisfy { $0.supports_fast == true })

    let apiKey = try #require(providers.first(where: { $0.provider_id == "openai" }))
    #expect(apiKey.models.contains { $0.id == "gpt-6-astra" } == false)
    let publicSol = try #require(apiKey.models.first { $0.id == "gpt-5.6-sol" })
    #expect(publicSol.supported_reasoning_efforts == ["none", "low", "medium", "high", "xhigh", "max"])
    #expect(publicSol.supported_reasoning_efforts?.contains("ultra") == false)

    let anthropic = try #require(providers.first(where: { $0.provider_id == "anthropic_oauth_direct" }))
    let sonnet5 = try #require(anthropic.models.first { $0.id == "claude-sonnet-5" })
    #expect(sonnet5.context_length == 1_000_000)
    #expect(sonnet5.supported_reasoning_efforts == ["low", "medium", "high", "xhigh", "max"])

    let xai = try #require(providers.first(where: { $0.provider_id == "xai_oauth_direct" }))
    let grok45 = try #require(xai.models.first { $0.id == "grok-4.5" })
    #expect(grok45.context_length == 500_000)
    #expect(grok45.supported_reasoning_efforts == ["low", "medium", "high"])
    #expect(grok45.supports_fast == true)
}

// 2026-07-21 audit: hermetic temp root for the dispatcher tests below — the
// session active-tools store must never read, sweep, or delete under the LIVE
// data root.
private func makeDispatcherTestRoot(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-chat-dispatcher-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func jsonString(_ value: JSONValue, key: String) -> String? {
    guard case .object(let obj) = value,
          case .string(let s)? = obj[key] else { return nil }
    return s
}

private func jsonBool(_ value: JSONValue, key: String) -> Bool? {
    guard case .object(let obj) = value,
          case .bool(let b)? = obj[key] else { return nil }
    return b
}

private func jsonInt(_ value: JSONValue, key: String) -> Int? {
    guard case .object(let obj) = value,
          case .int(let i)? = obj[key] else { return nil }
    return Int(i)
}

private func jsonStringArray(_ value: JSONValue, key: String) -> [String] {
    guard case .object(let obj) = value,
          case .array(let arr)? = obj[key] else { return [] }
    return arr.compactMap { item in
        if case .string(let s) = item { return s }
        return nil
    }
}

private func jsonObjectArray(_ value: JSONValue, key: String) -> [[String: JSONValue]] {
    guard case .object(let obj) = value,
          case .array(let arr)? = obj[key] else { return [] }
    return arr.compactMap { item in
        if case .object(let row) = item { return row }
        return nil
    }
}
