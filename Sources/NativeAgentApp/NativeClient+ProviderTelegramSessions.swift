import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

extension NativeClient {
    func getModelCatalog(refresh: Bool) async throws -> ModelCatalogResponse {
        try await getModelCatalog(
            refresh: refresh,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    func getModelCatalog(
        refresh: Bool,
        dataRoot: URL,
        codexCacheURL: URL? = nil
    ) async throws -> ModelCatalogResponse {
        // Swift-native cutover native impl (2026-06-02): was GET /v1/models. When
        // `<dataRoot>/providers/models.json` is present, decode it. When
        // missing, synthesize a baseline catalog (status=ok) so the
        // Providers UI has a non-empty selectable list. Surface prefs come
        // from `<dataRoot>/providers/surfaces.json` if present.
        let resolvedCodexCacheURL = codexCacheURL ?? (
            dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
                ? nil
                : dataRoot.appendingPathComponent("codex_home", isDirectory: true)
                    .appendingPathComponent("models_cache.json")
        )
        let codexSelectableModels = CodexSelectableModelCatalog.modelCatalogItems(
            cacheURL: resolvedCodexCacheURL
        )
        let firstPartyModels = (
            FirstPartyModelCatalog.publicOpenAIModels
            + FirstPartyModelCatalog.anthropicModels
            + FirstPartyModelCatalog.xAIModels
        ).enumerated().map { index, model in
            ModelCatalogItem(
                id: model.id,
                displayName: model.name,
                description: nil,
                defaultReasoningEffort: model.defaultReasoningEffort,
                supportedReasoningEfforts: model.supportedReasoningEfforts,
                supportsFast: model.supportsFast,
                priority: 100 + index
            )
        }
        let openRouterCatalogModels = await OpenRouterModelCatalog.models(dataRoot: dataRoot, refresh: refresh)
            .enumerated()
            .map { index, model in
                ModelCatalogItem(
                    id: model.id,
                    displayName: model.name,
                    description: nil,
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                    supportsFast: false,
                    priority: 1_000 + index
                )
            }
        func withDiscoveredModels(_ catalog: ModelCatalogResponse) -> ModelCatalogResponse {
            var merged = catalog
            // The on-disk models.json file is a compatibility cache, not an
            // authority for first-party capabilities. Replace matching rows
            // with the verified/current catalogs so a stale persisted entry
            // cannot hide Sonnet 5/Grok 4.5 or resurrect obsolete Think/Fast
            // flags. Account-backed GPT rows intentionally win duplicate ids
            // in this provider-neutral fallback; provider-scoped pickers use
            // listProviders() and retain their exact transport contract.
            let discoveredIDs = Set(
                (codexSelectableModels + firstPartyModels + openRouterCatalogModels).map(\.id)
            )
            merged.models.removeAll { discoveredIDs.contains($0.id) }
            var seen = Set(merged.models.map(\.id))
            for model in codexSelectableModels where seen.insert(model.id).inserted {
                merged.models.append(model)
            }
            for model in firstPartyModels where seen.insert(model.id).inserted {
                merged.models.append(model)
            }
            for model in openRouterCatalogModels where seen.insert(model.id).inserted {
                merged.models.append(model)
            }
            var seenEfforts = Set(merged.reasoningEfforts.map(\.id))
            let labels = ["none": "None", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"]
            for effort in (codexSelectableModels + firstPartyModels)
                .flatMap({ $0.supportedReasoningEfforts ?? [] })
                where seenEfforts.insert(effort).inserted {
                merged.reasoningEfforts.append(ReasoningEffortOption(
                    id: effort,
                    label: labels[effort] ?? effort.capitalized,
                    description: nil
                ))
            }
            merged.models.sort {
                let lhsPriority = $0.priority ?? 10_000
                let rhsPriority = $1.priority ?? 10_000
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return $0.displayName < $1.displayName
            }
            return merged
        }
        let modelsURL = dataRoot.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("models.json")
        if FileManager.default.fileExists(atPath: modelsURL.path),
           let data = try? Data(contentsOf: modelsURL),
           let decoded = try? JSONDecoder.nativeAgent.decode(ModelCatalogResponse.self, from: data) {
            return withDiscoveredModels(decoded)
        }

        let defaultModel = nativeAgentPrimaryModel
        var seenBaseline = Set<String>()
        let baseline = (codexSelectableModels + firstPartyModels + openRouterCatalogModels)
            .filter { seenBaseline.insert($0.id).inserted }
        let efforts = [
            ReasoningEffortOption(id: "none", label: "None", description: nil),
            ReasoningEffortOption(id: "low", label: "Low", description: nil),
            ReasoningEffortOption(id: "medium", label: "Medium", description: nil),
            ReasoningEffortOption(id: "high", label: "High", description: nil),
            ReasoningEffortOption(id: "xhigh", label: "XHigh", description: nil),
            ReasoningEffortOption(id: "max", label: "Max", description: nil),
            ReasoningEffortOption(id: "ultra", label: "Ultra", description: nil)
        ]

        let surfacesURL = dataRoot.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("surfaces.json")
        var surfacePrefs: [String: ModelSurfacePreference] = [:]
        if let data = try? Data(contentsOf: surfacesURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj {
                guard let entry = v as? [String: Any] else { continue }
                let model = (entry["model"] as? String) ?? defaultModel
                let effort = (entry["reasoningEffort"] as? String) ?? "medium"
                let serviceTier = (entry["serviceTier"] as? String)
                    ?? (entry["service_tier"] as? String)
                    ?? "default"
                surfacePrefs[k] = ModelSurfacePreference(
                    surface: k,
                    model: model,
                    reasoningEffort: effort,
                    serviceTier: serviceTier,
                    source: nil,
                    modelKnown: nil
                )
            }
        }
        func pref(_ s: String) -> ModelSurfacePreference {
            surfacePrefs[s] ?? ModelSurfacePreference(
                surface: s,
                model: defaultModel,
                reasoningEffort: "medium",
                serviceTier: "default",
                source: nil,
                modelKnown: nil
            )
        }
        let current = ModelRoutingCurrent(
            chat: pref("chat"),
            telegram: pref("telegram"),
            ios: surfacePrefs["ios"],
            executions: ProviderRoutingSurfaceLookup.value(surfacePrefs, WorkshopSurfaceVocabulary.canonical),
            autonomy: surfacePrefs["autonomy"],
            swarms: surfacePrefs["swarms"],
            dream: surfacePrefs["dream"],
            training: surfacePrefs["training"]
        )
        return ModelCatalogResponse(
            status: "ok",
            source: "first_party_capabilities_plus_signed_codex_and_openrouter",
            defaultModel: defaultModel,
            fallbackModels: ["claude-sonnet-5"],
            models: baseline,
            reasoningEfforts: efforts,
            current: current,
            updatedAt: nil
        )
    }

    func getModelPreferences() async throws -> SurfaceModelPreferencesResponse {
        try await getModelPreferences(dataRoot: PersistenceCore.defaultDataRoot())
    }

    func getModelPreferences(dataRoot: URL) async throws -> SurfaceModelPreferencesResponse {
        let path = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("surfaces.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return SurfaceModelPreferencesResponse(preferences: []) }

        let preferences = obj.keys.sorted().compactMap { surface -> SurfaceModelPreferenceEntry? in
            let raw = obj[surface]
            if let inner = raw as? [String: Any] {
                let model = inner["model"] as? String ?? ""
                guard !model.isEmpty else { return nil }
                let effort = inner["reasoningEffort"] as? String ?? inner["reasoning_effort"] as? String ?? ""
                let serviceTier = inner["serviceTier"] as? String ?? inner["service_tier"] as? String
                return SurfaceModelPreferenceEntry(
                    surface: surface,
                    model: model,
                    reasoningEffort: effort,
                    serviceTier: serviceTier
                )
            }
            if let flat = raw as? String, !flat.isEmpty {
                return SurfaceModelPreferenceEntry(surface: surface, model: flat, reasoningEffort: "")
            }
            return nil
        }
        return SurfaceModelPreferencesResponse(preferences: preferences)
    }

    /// Read Codex auth status directly from disk. Mirrors the old route shape:
    /// `active` reflects whether OAuth tokens are usable, `appOwnedLoggedIn` /
    /// `sharedLoggedIn` distinguish the two storage paths.
    func getCodexAuthStatus() async throws -> CodexAuthStatus {
        let env = ProcessInfo.processInfo.environment
        return try await getCodexAuthStatus(
            dataRoot: PersistenceCore.defaultDataRoot(),
            environment: env,
            allowEnvironmentOverride: true
        )
    }

    func getCodexAuthStatus(
        dataRoot: URL,
        environment: [String: String] = [:],
        allowEnvironmentOverride: Bool = false
    ) async throws -> CodexAuthStatus {
        let codexHome: String = {
            if allowEnvironmentOverride,
               let h = environment["CODEX_HOME"], !h.isEmpty {
                return (h as NSString).expandingTildeInPath
            }
            return dataRoot
                .appendingPathComponent("codex_home", isDirectory: true).path
        }()
        let path = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        var loggedIn = false
        var detail = "no auth.json on disk"
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = obj["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            loggedIn = true
            detail = "OAuth tokens present"
        } else if (try? Data(contentsOf: path)) != nil {
            detail = "auth.json present but tokens missing"
        }
        return CodexAuthStatus(
            active: loggedIn ? "oauth" : "none",
            appOwnedLoggedIn: loggedIn,
            sharedLoggedIn: loggedIn,
            codexHome: codexHome,
            detail: detail
        )
    }

    // Swift-owned Codex device-auth subprocess lifecycle.
    func getCodexDeviceLoginStatus() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.status(codexHome: Self.codexDeviceLoginHome())
    }

    func getSetupQuestions() async throws -> [SetupQuestion] {
        // The native setup screen gets readiness from health/auth/config tiles.
        // There is no separate setup-question ledger yet.
        return []
    }

    func getTelegramStatus() async throws -> TelegramStatus {
        // DAEMON KILLED 2026-06-02. Native Telegram status: read the saved
        // config and surface every field the UI binds to (chat ids, user
        // ids, require_mention). Token itself is NOT echoed back for safety.
        let cfg = TelegramBot.TelegramConfig.loadFromDisk()
        let dataRoot = PersistenceCore.defaultDataRoot()
        let telegramBrain = try? await SwiftNativeProviderRouting()
            .computeModelPreferences()["telegram"]
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        let stateURL = telegramDir.appendingPathComponent("state.json")
        var lastSeenUpdateId: Int?
        var lastSeenAt: String?
        var lastReplyAt: String?
        var lastError: String?
        var pollBackoffFailures: Int?
        var lastPollAt: String?
        if let data = try? Data(contentsOf: stateURL),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let i = raw["lastSeenUpdateId"] as? Int {
                lastSeenUpdateId = i
            } else if let d = raw["lastSeenUpdateId"] as? Double {
                lastSeenUpdateId = Int(d)
            } else if let i = raw["lastUpdateId"] as? Int {
                lastSeenUpdateId = i
            } else if let d = raw["lastUpdateId"] as? Double {
                lastSeenUpdateId = Int(d)
            }
            lastSeenAt = raw["lastSeenAt"] as? String
            lastReplyAt = raw["lastReplyAt"] as? String
            lastError = raw["lastError"] as? String
            if let i = raw["pollBackoffFailures"] as? Int {
                pollBackoffFailures = i
            } else if let d = raw["pollBackoffFailures"] as? Double {
                pollBackoffFailures = Int(d)
            }
            lastPollAt = raw["lastPollAt"] as? String
        }
        let receipts: [TelegramReceipt] = tailJSONL(
            path: telegramDir.appendingPathComponent("receipts.jsonl"),
            limit: 50
        )
        let blocked: [TelegramBlockedEvent] = tailJSONL(
            path: telegramDir.appendingPathComponent("blocked.jsonl"),
            limit: 50
        )
        let errors: [TelegramErrorEvent] = tailJSONL(
            path: telegramDir.appendingPathComponent("errors.jsonl"),
            limit: 50
        )
        let chatIds = cfg?.allowedChatIds.sorted().map { String($0) } ?? []
        let userIds = cfg?.allowedUserIds.sorted().map { String($0) } ?? []
        let voiceBackend = cfg?.voiceTranscriptionBackend ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionBackend
        let voiceModel = cfg?.voiceTranscriptionModel ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionModel
        let voiceSupported = TelegramVoiceTranscriptionBackends.isSupported(voiceBackend)
        let voiceRequiresAPIKey = TelegramVoiceTranscriptionBackends.requiresAPIKey(voiceBackend)
        let voiceKeyConfigured = voiceSupported && (
            !voiceRequiresAPIKey || LLMCredentialResolver.resolveAPIKey(
                envVar: "OPENAI_API_KEY",
                providerConfigFile: "openai.json",
                dataRoot: dataRoot
            ) != nil
        )
        let voiceStatus = TelegramVoiceTranscriptionStatus(
            enabled: cfg?.voiceTranscriptionEnabled ?? TelegramBot.TelegramConfig.defaultVoiceTranscriptionEnabled,
            backend: voiceBackend,
            model: voiceModel,
            maxBytes: cfg?.voiceMaxBytes ?? TelegramBot.TelegramConfig.defaultVoiceMaxBytes,
            backendSupported: voiceSupported,
            keyConfigured: voiceKeyConfigured,
            requiresAPIKey: voiceRequiresAPIKey
        )
        // F4 fix-6: pollerEnabled reports ACTUAL loop-running state from the
        // BackgroundLoopsManager — registered AND its runtime is running —
        // not just config.enabled. Config-says-on / loop-not-running is the
        // exact regression the UI used to hide (status panel looked healthy
        // while the poller was dead).
        let loopStatuses = await BackgroundLoopsManager.shared.status()
        let pollerRunning = loopStatuses.contains(where: { $0.loopId == "telegram_poll" && $0.running })
        return TelegramStatus(
            enabled: cfg?.enabled ?? false,
            tokenConfigured: (cfg?.botToken.isEmpty == false),
            allowedChatIds: chatIds,
            allowedUserIds: userIds,
            requireMention: cfg?.requireMention ?? false,
            model: telegramBrain?.model,
            reasoningEffort: telegramBrain?.reasoningEffort,
            pollerEnabled: pollerRunning,
            lastSeenUpdateId: lastSeenUpdateId,
            lastSeenAt: lastSeenAt,
            lastReplyAt: lastReplyAt,
            lastError: lastError ?? (cfg == nil ? "No bot token saved — paste one to enable." : nil),
            pollBackoffFailures: pollBackoffFailures,
            lastPollAt: lastPollAt,
            voiceTranscription: voiceStatus,
            receipts: receipts,
            blocked: blocked,
            errors: errors
        )
    }

    func getChatSessions() async throws -> [ChatSession] {
        try await Self.getChatSessions(dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func getChatSessions(dataRoot: URL) async throws -> [ChatSession] {
        // Swift-native cutover port P2: was GET /v1/chat/sessions. The daemon stored
        // chat sessions as a single JSON list at `<dataRoot>/chat/sessions.json`
        // — same file `SessionHistoryReader.session(id:)` reads. Decode into
        // the Mac UI's NativeAgentShared.ChatSession (file-scope typealias).
        // Missing file → `[]`.
        let url = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let persistence = SwiftNativePersistenceCore()
        let data = try await persistence.withFileLock(url) {
            _ = try ChatSessionRetention.enforce(
                dataRoot: dataRoot,
                now: Date()
            )
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: url)
            return try ChatSessionIndexFile.serializedData(for: rows)
        }
        return try JSONDecoder.nativeAgent.decode([ChatSession].self, from: data)
    }

    func getChatMessages(sessionId: String) async throws -> [ChatMessage] {
        try await Self.getChatMessages(
            sessionId: sessionId,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    static func getChatMessages(
        sessionId: String,
        dataRoot: URL
    ) async throws -> [ChatMessage] {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return []
        }
        // Swift-native cutover: read messages directly via the native SessionHistoryReader.
        // The daemon used to read `<dataRoot>/chat/messages/<id>.jsonl`; the Swift
        // reader (ChatOrchestration+SessionHistory.swift) reads the same file.
        let reader = ChatOrchestration.SessionHistoryReader(dataRoot: dataRoot)
        // Eval fix (2026-06-03): preserve id, runId, source, and metadata
        // when remapping. Without these, getChatMessages drops the tool-pill
        // metadata (kind/toolName/inputJSON/resultSummary) the streaming
        // tool-loop persists, so the UI never renders pills. Path: serialize
        // the raw JSONL row (co.extras) and decode via the Mac
        // ChatMessage.init(from:) which already lifts every field including
        // ChatMessageMetadata.
        let decoder = JSONDecoder.nativeAgent
        let coMessages = try await reader.messages(forSessionId: safeSessionId)
        return coMessages.map { co -> ChatMessage in
            if let extras = co.extras,
               case .object = extras,
               let data = try? extras.serializedData(pretty: false),
               var decoded = try? decoder.decode(ChatMessage.self, from: data) {
                if decoded.sessionId == nil { decoded.sessionId = safeSessionId }
                return decoded
            }
            return ChatMessage(
                sessionId: safeSessionId,
                role: co.role,
                content: co.content,
                createdAt: co.timestamp
            )
        }
    }

    func getLatestContextReceipt(sessionId: String) async throws -> ContextReceipt {
        try await Self.getLatestContextReceipt(
            sessionId: sessionId,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    static func getLatestContextReceipt(
        sessionId: String,
        dataRoot: URL
    ) async throws -> ContextReceipt {
        // Swift-native cutover port P2: was GET /v1/context/latest. Tail-scan
        // `<dataRoot>/context/receipts.jsonl` (append-only, newest-last),
        // return the newest entry whose sessionId matches; if no sessionId
        // filter hits, fall back to the absolute newest. Missing file or
        // empty → synthesized empty receipt (ContextReceipt's custom
        // init(from:) decodeIfPresent's every key, so `{}` is valid).
        let url = dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return try JSONDecoder.nativeAgent.decode(ContextReceipt.self, from: Data("{}".utf8))
        }
        let decoder = JSONDecoder.nativeAgent
        var newestForSession: ContextReceipt? = nil
        var newestAny: ContextReceipt? = nil
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let row = try? decoder.decode(ContextReceipt.self, from: lineData) else { continue }
            newestAny = row
            if row.sessionId == sessionId { newestForSession = row }
        }
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSessionId.isEmpty {
            if let receipt = newestForSession { return receipt }
            return try decoder.decode(ContextReceipt.self, from: Data("{}".utf8))
        }
        if let receipt = newestAny { return receipt }
        return try decoder.decode(ContextReceipt.self, from: Data("{}".utf8))
    }

    func createChatSession(title: String, sourceKey: String? = nil, forceNew: Bool = false) async throws -> ChatSession {
        try await Self.createChatSession(
            title: title,
            sourceKey: sourceKey,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    static func createChatSession(
        title: String,
        sourceKey: String? = nil,
        dataRoot: URL
    ) async throws -> ChatSession {
        // DAEMON KILLED 2026-06-02. Write a new session directly to
        // <dataRoot>/chat/sessions.json under flock.
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        var sessionRow: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "source": .string("app"),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "archived": .bool(false),
            "messageCount": .int(0),
        ]
        if let sourceKey, !sourceKey.isEmpty { sessionRow["sourceKey"] = .string(sourceKey) }
        let rowToInsert = sessionRow
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let sessionData = try JSONValue.object(sessionRow).serializedData(pretty: false)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(sessionsPath) {
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            sessions.insert(rowToInsert, at: 0)
            let out = try ChatSessionIndexFile.serializedData(for: sessions)
            try out.write(to: sessionsPath, options: .atomic)
            _ = try? ChatSessionRetention.enforce(dataRoot: dataRoot, now: Date())
        }
        return try JSONDecoder.nativeAgent.decode(ChatSession.self, from: sessionData)
    }

    func updateChatSession(id: String, title: String?, archived: Bool?) async throws -> ChatSession {
        try await Self.updateChatSession(
            id: id,
            title: title,
            archived: archived,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    static func updateChatSession(
        id: String,
        title: String?,
        archived: Bool?,
        dataRoot: URL
    ) async throws -> ChatSession {
        // DAEMON KILLED 2026-06-02. Mutate <dataRoot>/chat/sessions.json
        // directly under flock; find the entry by id, patch title/archived,
        // write back. Mirrors the createChatSession write path above.
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let persistence = SwiftNativePersistenceCore()
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let updatedData: Data? = try await persistence.withFileLock(sessionsPath) { () -> Data? in
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            var found: Data? = nil
            for (idx, original) in sessions.enumerated() {
                guard case .string(let rowId)? = original["id"],
                      rowId == id else { continue }
                var row = original
                if let title { row["title"] = .string(title) }
                if let archived { row["archived"] = .bool(archived) }
                row["updatedAt"] = .string(nowIso)
                sessions[idx] = row
                found = try JSONValue.object(row).serializedData(pretty: false)
                break
            }
            guard found != nil else { return nil }
            let out = try ChatSessionIndexFile.serializedData(for: sessions)
            try out.write(to: sessionsPath, options: .atomic)
            return found
        }
        guard let updatedData else {
            throw NSError(domain: "NativeAgent", code: -404,
                          userInfo: [NSLocalizedDescriptionKey: "chat session \(id) not found"])
        }
        return try JSONDecoder.nativeAgent.decode(ChatSession.self, from: updatedData)
    }

    func verifyCodex() async throws -> CodexCheckResponse {
        try await Self.verifyCodex(dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func verifyCodex(dataRoot: URL) async throws -> CodexCheckResponse {
        // fix2/F6 (2026-06-02): the prior stub returned `ok: true` unconditionally,
        // which is the lie this fix is meant to eliminate — a user with no codex
        // CLI session was being told "verified". Now we actually check
        // `<dataRoot>/codex_home/auth.json` for a non-empty `tokens.access_token`,
        // matching the source-3 codex-auth probe in `getProviders`.
        let codexAuthPath = dataRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: codexAuthPath), !data.isEmpty else {
            return CodexCheckResponse(ok: false, model: "no codex auth.json or empty access_token")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexCheckResponse(ok: false, model: "no codex auth.json or empty access_token")
        }
        // Accept either {tokens: {access_token}} (new codex schema) or a top-level
        // access_token key (older schema). Both shapes appear in the wild; either
        // a non-empty access_token string counts as verified.
        let nested = (obj["tokens"] as? [String: Any])?["access_token"] as? String
        let flat = obj["access_token"] as? String
        let token = (nested?.isEmpty == false) ? nested : flat
        if let token, !token.isEmpty {
            return CodexCheckResponse(ok: true, model: "codex auth.json verified")
        }
        return CodexCheckResponse(ok: false, model: "no codex auth.json or empty access_token")
    }

    func openCodexLoginInBrowser() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.start(codexHome: Self.codexDeviceLoginHome(), openBrowser: true)
    }

    @discardableResult
    func cancelCodexDeviceLogin() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.cancel(codexHome: Self.codexDeviceLoginHome())
    }

    @discardableResult
    func codexDeviceLoginClear() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.clear(codexHome: Self.codexDeviceLoginHome())
    }

    static func codexDeviceLoginHome() -> URL {
        codexDeviceLoginHome(dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func codexDeviceLoginHome(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("codex_home", isDirectory: true)
    }

    func getCompiledPersonality(surface: String) async throws -> CompiledPersonality {
        // WAVE 35 W01 (§6.116 prereq #1): missing-doc default-value
        // PERSISTENCE on the compiled-packet path. The daemon's
        // `compiled_personality_packet`
        // calls `personality_doc_contents(create_missing=True)`, which
        // atomically WRITES the default body for any missing mutable fixed doc
        // once SOUL.md exists — BEFORE reading the file back to build the
        // packet. USER.md is skipped here because MemoryV2 owns it.
        //
        // The Swift `compiledPacket` read path (PersonaEngine+CompiledPacket.swift
        // `readPersonaDocContents`) is pure: a missing doc reads as "",
        // so its fingerprint diverges from the daemon's whenever SOUL.md
        // exists but a sibling doc is absent (documented divergence at
        // PersonaEngine+CompiledPacket.swift L115-124). Wave 34 W05 closed
        // this same gap on the `/v1/personality/docs` path; this mirrors
        // it on `/v1/personality/compiled`.
        //
        // Gate the WRITE on the dedicated `.personaEngineWrites` flag (NOT
        // the read flag `.personaEngine`), exactly as W05 does: a read must
        // never mutate disk while only the read flag is live. Scaffold
        // first, then build the packet, so the fingerprint reflects the
        // just-persisted default body — matching the daemon's
        // write-then-read order. A scaffold IO failure PROPAGATES (not
        // `try?`-swallowed): the daemon's `personality_doc_contents` calls
        // `_atomic_write_text` with no try/except, so a failed write fails
        // the compiled read; mirror that rather than silently returning an
        // in-memory packet over an un-scaffolded disk (which would let the
        // next daemon read scaffold UNLOCKED, the race this closes). When
        // the write flag is OFF the scaffold never runs and the compiled
        // read stays pure (production read-flag-only path unchanged).
        do {
            let writer = makePersonaEngineWriter()
            try await writer.scaffoldMissingDocs()
        }
        return try await swiftCompiledPersonality(surface: surface)
    }

    // Wave 3 fixup: Core now exposes `listPersonaDocSpecs()` returning the
    // wire-shape DTO (id/title/filename/path/content/updatedAt), so the
    // .personaEngine flag covers doc listing too. The NativeClient adapter
    // (`swiftPersonalityDocs`) is a trivial field-for-field map from
    // PersonaDocSpec to NativeAgentShared.PersonalityDoc.
    func getPersonalityDocs() async throws -> PersonalityDocsResponse {
        // WAVE 34 W05: missing-doc default-value PERSISTENCE. The daemon's
        // `personality_docs()` calls `personality_doc_contents(create_missing=True)`,
        // which atomically WRITES the default body for any missing mutable fixed
        // doc once SOUL.md exists. USER.md is skipped because MemoryV2 owns it.
        // The Swift READ path only renders those defaults in-memory
        // (updatedAt nil) and never persists — so a
        // flipped write subsystem would leave the next DAEMON read to
        // scaffold them UNLOCKED, reopening the split-writer race. Mirror
        // the daemon's scaffold-on-read here, but gate the WRITE on the
        // dedicated `.personaEngineWrites` flag so it stays DORMANT on the
        // production read flag `.personaEngine` (a read must never mutate
        // disk while only the read flag is live). Scaffold first, then list,
        // so the returned `updatedAt` reflects the just-persisted file —
        // matching the daemon's read-then-stat order. A scaffold IO failure
        // PROPAGATES (not `try?`-swallowed): the daemon's
        // `personality_doc_contents` calls `_atomic_write_text` with no
        // try/except, so a failed write fails the `/v1/personality/docs`
        // read — we mirror that exactly rather than silently returning
        // in-memory defaults while leaving the disk un-scaffolded (which
        // would let the next daemon read scaffold UNLOCKED, the very race
        // this closes). When the write flag is OFF, the scaffold never runs
        // and the read is pure (production read-flag-only path unchanged).
        do {
            let writer = makePersonaEngineWriter()
            try await writer.scaffoldMissingDocs()
        }
        return try await swiftPersonalityDocs()
    }

    // WAVE 33 W06: write gate. When `.personaEngineWrites` is ON, route the
    // persona doc write through the native
    // `SwiftNativePersonaEngine.savePersonalityDoc` (PersonaEngine+Writes.swift)
    // instead of POST /v1/personality/docs. The native path enforces the SAME
    // onboarding-sentinel gate + 30K cap + atomic write, holds a cross-process
    // flock on the doc file, and returns the identical
    // `{**spec, path, content, updatedAt}` shape.
    //
    // DEDICATED WRITE FLAG (NOT `.personaEngine`): the read gates
    // (getPersonality / getPersonalityDocs) gate on `.personaEngine`, which is
    // already FLAG_FLIPPED / live in production (CUTOVER §6.55 W17). Gating the
    // WRITE path on `.personaEngine` too would make the native write LIVE the
    // instant the read flag is in the user's env — going live while pre-flip prereqs
    // are still OPEN. `.personaEngineWrites` is a SEPARATE default-OFF flag so
    // the write stays genuinely DORMANT until those prereqs close (CUTOVER §6.96):
    //   (1) all-writer flock — the 3 MUTATION writers (`persona_write`,
    //       `persona_append_section`, `append_personality_growth`) now share the
    //       cross-process lock (CLOSED this wave); RESIDUAL unlocked writers
    //       remain (`Runtime.personality()` rewrites profile.json unlocked on
    //       every read; doc auto-scaffold; Swift onboarding writes) — named as a
    //       pre-flip prereq in §6.96, NOT yet closed;
    //   (2) the W33-W03 NFKC persona-write-guard co-requisite (must land on the
    //       same integration branch);
    //   (3) the §6.76 item-B side-effect parity gap (`record_activity` Mac-side
    //       emission for the doc save) — still OPEN.
    // Persona writes now route through the Swift writer directly; unsupported
    // inputs fail closed inside PersonaEngine.
    func savePersonalityDoc(id: String, content: String) async throws -> PersonalityDoc {
        let engine = makePersonaEngineWriter()
        let spec = try await engine.savePersonalityDoc(id: id, content: content)
        return PersonalityDoc(
            id: spec.id,
            title: spec.title,
            filename: spec.filename,
            path: spec.path,
            content: spec.content,
            updatedAt: spec.updatedAt
        )
    }

    func getPrivacyMap(includeInventory: Bool = true) async throws -> PrivacyMap {
        let dataRoot = PersistenceCore.defaultDataRoot()
        return PrivacyMap(
            dataRoot: dataRoot.path,
            categories: Self.privacyCategories(
                dataRoot: dataRoot,
                includeInventory: includeInventory
            ),
            generatedAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

    /// Build the Support Snapshot.
    ///
    /// 2026-07-23 B2.6d: `reusing` lets the caller hand in a still-fresh
    /// `DoctorReport` so we DON'T re-run the full offline Doctor pass just to
    /// compute the rollup. The reuse path reproduces the identical offline
    /// rollup by excluding exactly the app-added live-coverage checks (`live.*`)
    /// that `runAll` never produces — so the snapshot content is byte-identical
    /// to a cold run. The export path (and any stale-cache caller) passes
    /// nil → full run.
    func getSupportDiagnostics(reusing report: DoctorReport? = nil) async throws -> SupportDiagnostics {
        let doctorStatus: String
        if let report {
            doctorStatus = Self.supportSnapshotOfflineRollup(report.checks)
        } else {
            let impl = makeDoctorChecks()
            let statuses = try await impl.runAll(repair: false, checkLLM: false).map(\.status)
            doctorStatus = Self.supportSnapshotRollup(statuses)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return SupportDiagnostics(
            app: "NativeAgent",
            version: version,
            doctorStatus: doctorStatus,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// fail > warn > ok, matching the original inline Support Snapshot rollup.
    static func supportSnapshotRollup(_ statuses: [String]) -> String {
        if statuses.contains(where: { $0 == "fail" }) { return "fail" }
        if statuses.contains(where: { $0 == "warn" }) { return "warn" }
        return "ok"
    }

    /// Rollup for the reuse path. `runDoctor` builds its report as
    /// `runAll(...)` (the offline core pass) PLUS the app's live-coverage
    /// checks (`live.*`). The cold Support Snapshot uses `runAll` alone, so
    /// dropping exactly the `live.*` checks reproduces its rollup byte-for-byte
    /// — NOTE the core `runAll` ignores its `checkLLM` flag (the `llm` check is
    /// always part of the offline pass), so it must NOT be excluded here (B2.6d).
    static func supportSnapshotOfflineRollup(_ checks: [DoctorCheck]) -> String {
        supportSnapshotRollup(
            checks
                .filter { !$0.id.hasPrefix("live.") }
                .map(\.status)
        )
    }

    // Wave 16 (2026-06-01): ChatOrchestration cutover. chat() and chatStream()
    // go straight through SwiftNativeChatOrchestrationClient.
    //
    // CARVES (documented):
    //  * Persona (per-chat pick via UserDefaults["chatPersona"]) is RECORDED on
    //    the persisted assistant turn's metadata.persona for downstream
    //    consolidation, but does NOT change which compiled persona the LLM sees
    //    on this turn. Default-persona users see no regression.
    //  * personaFingerprint = first-16-hex of sha256(profile.name|profile.personaKind).
    //  * contextFingerprint = first-16-hex of sha256(sorted recalledIds join),
    //    nil when empty — opaque comparator, never raw record identity
    //    (packet-provenance 2026-07-11).
    //  * Tool dispatches: SwiftToolDispatcher refuses execution with a clear
    //    "not yet wired" error — the tool loop records the rejection rather
    //    than tearing down the turn (this matches the Swift module's docs).
    //  * If the Swift path throws, we rethrow — do NOT fall back to HTTP
    //    because the daemon is the wedge we're bypassing.

    static func adaptAttachments(_ shared: [NativeAgentShared.MultimodalAttachment]) -> [ChatOrchestration.MultimodalAttachment] {
        return shared.map { ChatOrchestration.MultimodalAttachment(id: $0.id, type: $0.type, base64: $0.base64, mime: $0.mime, name: $0.name, byteSize: $0.byteSize, path: $0.path) }
    }

    static func adaptOutputAttachments(_ co: [ChatOrchestration.MultimodalAttachment]?) -> [NativeAgentShared.MultimodalAttachment]? {
        guard let co, !co.isEmpty else { return nil }
        return co.map {
            NativeAgentShared.MultimodalAttachment(
                id: $0.id,
                type: $0.type,
                base64: $0.base64,
                mime: $0.mime,
                name: $0.name,
                byteSize: $0.byteSize,
                path: $0.path
            )
        }
    }

    func adaptChatResponse(_ co: ChatOrchestration.ChatResponse) -> ChatResponse {
        return ChatResponse(
            runId: co.runId,
            model: co.model,
            requestedModel: co.requestedModel,
            reasoningEffort: co.reasoningEffort,
            output: co.output,
            sessionId: co.sessionId,
            attachments: Self.adaptOutputAttachments(co.attachments),
            message: nil,
            messages: nil,
            personaFingerprint: co.personaFingerprint,
            contextFingerprint: co.contextFingerprint
        )
    }

}
