import Foundation
import NativeAgentCore
import ChatOrchestration
import TelegramBot
import ProviderRouting
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore

/// Account-catalog observation supplied by the concrete platform client.
public struct TelegramAccountModelCatalogPort: Sendable {
    let isAccountBackedProvider: @Sendable (String) -> Bool
    let chatGPTOAuthCacheCandidate: @Sendable (URL) -> URL?
    let load: @Sendable (String, URL?, Bool) -> [TelegramModelChoice]

    public init(
        isAccountBackedProvider: @escaping @Sendable (String) -> Bool,
        chatGPTOAuthCacheCandidate: @escaping @Sendable (URL) -> URL?,
        load: @escaping @Sendable (String, URL?, Bool) -> [TelegramModelChoice]
    ) {
        self.isAccountBackedProvider = isAccountBackedProvider
        self.chatGPTOAuthCacheCandidate = chatGPTOAuthCacheCandidate
        self.load = load
    }
}

public struct TelegramProviderRoutingBridge: ProviderRoutingRef, Sendable {
    let routing: SwiftNativeProviderRouting
    let dataRoot: URL
    let accountCatalog: TelegramAccountModelCatalogPort

    public init(
        routing: SwiftNativeProviderRouting,
        dataRoot: URL,
        accountCatalog: TelegramAccountModelCatalogPort
    ) {
        self.routing = routing
        self.dataRoot = dataRoot
        self.accountCatalog = accountCatalog
    }

    public func modelForSurface(_ surface: String) async -> (model: String, provider: String)? {
        guard let snapshot = try? await routing.checkedRoutingSnapshot(),
              let pref = snapshot.preferences[surface] else {
            return nil
        }
        let provider = snapshot.activeProviders[surface]
            ?? routing.inferProviderForModel(pref.model)
            ?? "unknown"
        return (pref.model, provider)
    }

    public func saveModelConfig(surface: String, key: String, value: String) async throws {
        var body: [String: JSONValue] = ["surface": .string(surface)]
        switch key {
        case "reasoning_effort", "reasoningEffort":
            body["reasoningEffort"] = .string(value)
        case "service_tier", "serviceTier":
            body["serviceTier"] = .string(value)
        case "model":
            // S12a: the model only; the surface keeps its chosen route.
            body["model"] = .string(value)
        default:
            body[key] = .string(value)
        }
        _ = try await routing.saveModelConfig(.object(body))
    }

    public func saveModelSelection(surface: String, provider: String?, model: String) async throws {
        // S12a: an explicit account, or none — the surface keeps its chosen
        // route rather than taking one guessed from the model's name.
        let explicitProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admittedProvider = explicitProvider?.isEmpty == false ? explicitProvider : nil
        try await routing.saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: admittedProvider
        )
    }

    public func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? {
        guard let snapshot = try? await routing.checkedRoutingSnapshot(),
              let preference = snapshot.preferences[surface] else {
            return nil
        }
        let current = (
            model: preference.model,
            provider: snapshot.activeProviders[surface]
                ?? routing.inferProviderForModel(preference.model)
                ?? "unknown"
        )
        let currentProvider = current.provider
        guard let providers = try? await routing.listProviders() else {
            return nil
        }

        let choices = providers
            .filter { Self.isSelectableProvider($0, currentProvider: currentProvider) }
            .map { provider in
                let isCurrent = Self.providerIdsMatch(provider.id, currentProvider)
                var models = Self.modelChoices(
                    from: provider,
                    currentModel: current.model,
                    isCurrentProvider: isCurrent
                )
                if accountCatalog.isAccountBackedProvider(provider.id) {
                    var seen = Set(models.map(\.id))
                    let isDirectOAuth = provider.id == "openai_oauth_direct"
                    let cacheURL = isDirectOAuth
                        ? accountCatalog.chatGPTOAuthCacheCandidate(dataRoot)
                        : nil
                    let discovered = accountCatalog.load(provider.id, cacheURL, !isDirectOAuth).compactMap { model -> TelegramModelChoice? in
                        guard seen.insert(model.id).inserted else { return nil }
                        return TelegramModelChoice(
                            id: model.id,
                            name: model.name,
                            isCurrent: isCurrent && model.id == current.model,
                            supportedReasoningEfforts: model.supportedReasoningEfforts,
                            supportsFast: model.supportsFast
                        )
                    }
                    models = discovered + models
                }
                if isCurrent,
                   !models.contains(where: { $0.id == current.model }) {
                    let descriptor = FirstPartyModelCatalog.descriptor(
                        for: current.model,
                        providerID: provider.id
                    )
                    models.insert(
                        TelegramModelChoice(
                            id: current.model,
                            name: current.model,
                            isCurrent: true,
                            supportedReasoningEfforts: descriptor?.supportedReasoningEfforts ?? [],
                            supportsFast: descriptor?.supportsFast ?? false
                        ),
                        at: 0
                    )
                }
                return TelegramModelProviderChoice(
                    id: provider.id,
                    displayName: provider.displayName ?? Self.displayName(for: provider.id),
                    isCurrent: isCurrent,
                    models: models
                )
            }
            .filter { !$0.models.isEmpty }

        return TelegramModelMenu(
            surface: surface,
            currentModel: current.model,
            currentProvider: currentProvider,
            providers: choices
        )
    }

    static func providerIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeProviderId(lhs) == normalizeProviderId(rhs)
    }

    private static func normalizeProviderId(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai_oauth_direct"
        case "moonshot", "kimi":
            return "moonshot"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func isSelectableProvider(_ provider: Provider, currentProvider: String) -> Bool {
        if provider.id == "codex" { return true }
        if providerIdsMatch(provider.id, currentProvider) { return true }
        if provider.configured == true || provider.active == true { return true }
        if case .object(let obj)? = provider.oauthStatus,
           case .string(let state)? = obj["state"],
           state == "ready" {
            return true
        }
        if case .object(let extras)? = provider.extras,
           case .object(let status)? = extras["auth_status"],
           case .string(let state)? = status["state"],
           state == "ready" {
            return true
        }
        return false
    }

    private static func modelChoices(
        from provider: Provider,
        currentModel: String,
        isCurrentProvider: Bool
    ) -> [TelegramModelChoice] {
        var out: [TelegramModelChoice] = []
        var seen: Set<String> = []
        for object in modelObjects(from: provider) {
            guard let id = firstString(object, keys: ["id", "model_id", "model"]),
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let name = firstString(object, keys: ["name", "display_name", "displayName"]) ?? id
            if seen.insert(id).inserted {
                out.append(TelegramModelChoice(
                    id: id,
                    name: name,
                    isCurrent: isCurrentProvider && id == currentModel,
                    supportedReasoningEfforts: stringArray(
                        object,
                        keys: ["supported_reasoning_efforts", "supportedReasoningEfforts"]
                    ),
                    supportsFast: firstBool(
                        object,
                        keys: ["supports_fast", "supportsFast"]
                    ) ?? false
                ))
            }
        }
        return out
    }

    private static func modelObjects(from provider: Provider) -> [[String: JSONValue]] {
        if case .array(let items)? = provider.modelCatalog {
            let models = items.compactMap { item -> [String: JSONValue]? in
                guard case .object(let obj) = item else { return nil }
                return obj
            }
            if !models.isEmpty { return models }
        }
        if case .object(let extras)? = provider.extras,
           case .array(let items)? = extras["models"] {
            return items.compactMap { item in
                guard case .object(let obj) = item else { return nil }
                return obj
            }
        }
        return []
    }

    private static func firstString(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let str):
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int):
                return String(int)
            case .double(let double):
                return String(double)
            case .bool(let bool):
                return bool ? "true" : "false"
            case .null, .array, .object:
                continue
            }
        }
        return nil
    }

    private static func stringArray(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> [String] {
        for key in keys {
            guard case .array(let values)? = object[key] else { continue }
            return values.compactMap { value in
                guard case .string(let string) = value else { return nil }
                return string
            }
        }
        return []
    }

    private static func firstBool(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard case .bool(let value)? = object[key] else { continue }
            return value
        }
        return nil
    }

    private static func displayName(for providerId: String) -> String {
        switch normalizeProviderId(providerId) {
        case "anthropic": return "Anthropic"
        case "openai": return "ChatGPT / OpenAI"
        case "codex": return "Codex CLI"
        case "xai": return "xAI Grok"
        case "moonshot": return "Moonshot AI (Kimi)"
        case "openrouter": return "OpenRouter"
        default: return providerId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

}

public struct TelegramMemoryWriterBridge: TelegramMemoryWriteRef, Sendable {
    let dataRoot: URL
    let memory: SwiftNativeMemoryV2

    public init(
        dataRoot: URL,
        memory: SwiftNativeMemoryV2? = nil
    ) {
        self.dataRoot = dataRoot
        if let memory {
            self.memory = memory
        } else {
            self.memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        }
    }

    public func remember(text: String, source: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramBotError.invalidRequest }
        let record = try await memory.store(
            content: trimmed,
            source: source,
            metadata: .object([
                "surface": .string("telegram"),
                "command": .string("/remember"),
            ])
        )
        return record.id
    }

    public func note(text: String, kind: String, source: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramBotError.invalidRequest }
        let resolvedKind = kind.isEmpty ? "telegram_note" : kind
        let record = try await memory.store(
            content: trimmed,
            source: source,
            metadata: .object([
                "note_kind": .string(resolvedKind),
                "tags": .array([.string("telegram")]),
                "confidence": .double(0.8),
                "importance": .double(0.5),
                "surface": .string("telegram"),
                "command": .string("/note"),
            ])
        )
        return record.id
    }
}

// MARK: - TelegramRestartBridge (2026-06-10)
//
// Routes the owner-gated /restart into AppRestartCoordinator — the SAME
// core routine the chat `restart_app` tool dispatches through, so cooldown
// stamp, audit trail, relauncher, and grace-period terminate exist exactly
// once. The TelegramBot module can't see AppKit; this bridge is the
// injection point, mirroring TelegramMemoryWriterBridge.
/// Core adapter for the Telegram restart capability and injected platform handoff.  A successful
/// coordinator envelope is not enough to acknowledge a restart: Telegram
/// also needs the deferred termination handoff so the committed relaunch can
/// actually make progress after the reply is delivered.
public struct TelegramRestartBridge: TelegramRestartRef, Sendable {
    public typealias DeferredRestart = @Sendable (
        _ reason: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?)

    let dataRoot: URL
    private let deferredRestart: DeferredRestart

    public init(dataRoot: URL, deferredRestart: @escaping DeferredRestart) {
        self.dataRoot = dataRoot
        self.deferredRestart = deferredRestart
    }

    public func ownerChatIds() async -> Set<Int64> {
        // Owner = the on-disk Telegram allowlist. Re-read per call (not
        // cached at assembly) so an allowlist edit takes effect without an
        // app restart. Empty/missing config fails the gate closed.
        TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.allowedChatIds ?? []
    }

    public func requestRestart(reason: String) async -> TelegramRestartOutcome {
        // Deferred-terminate variant (blocker fix 2026-06-10): the
        // coordinator commits the restart (cooldown → audit → stamp →
        // relauncher) but does NOT arm termination here. The armTerminate
        // closure rides back to the poll loop, which invokes it AFTER the
        // reply send attempt instead of racing sendMessage against the app
        // termination timer.
        let (envelope, armTerminate) = await deferredRestart(reason)
        guard case .object(let obj) = envelope else {
            return TelegramRestartOutcome(
                reply: "Restart failed: unexpected coordinator response."
            )
        }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key] { return s }
            return nil
        }
        if str("status") == "restarting", let armTerminate {
            return TelegramRestartOutcome(
                reply: "Restarting NativeAgent — back in under a minute. \(str("note") ?? "")",
                armTerminate: armTerminate
            )
        }
        if str("status") == "restarting" {
            // A relauncher stamp without the post-reply exit handoff leaves
            // the old process running and makes the Telegram acknowledgement
            // a lie. Treat this malformed primitive outcome as a refusal.
            return TelegramRestartOutcome(
                reply: "Restart failed: restart handoff was incomplete; NativeAgent is still running."
            )
        }
        if str("reason") == "cooldown" {
            let retry: String = {
                if case .double(let n)? = obj["retryAfterSeconds"],
                   let seconds = Int(exactly: n.rounded(.towardZero)) { return String(seconds) }
                return "?"
            }()
            return TelegramRestartOutcome(
                reply: "Restart refused: a tool-initiated restart fired within the last 10 minutes. Retry in \(retry)s."
            )
        }
        return TelegramRestartOutcome(
            reply: "Restart failed: \(str("reason") ?? "unknown"). \(str("detail") ?? "")"
        )
    }
}
