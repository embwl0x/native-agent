import Foundation
import NativeAgentShared
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
import Experiences
// Blueprint: | `LLMClient+Real.swift` | `makeResidentProviderLLMClient` owns the nine-transport assembly for resident, planner and swarm calls; `SwiftNativeLLMClient` shared routing and non-streaming execution envelope, stream guard admission before adapter creation, and failed-call telemetry before error normalization |

/// One provider assembly for resident turns and background body work. Routing,
/// credentials, account catalogs and adapter transports have exactly one owner.
public func makeResidentProviderLLMClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    providersRoot: URL? = nil,
    router suppliedRouter: SwiftNativeProviderRouting? = nil,
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    streamGuard: ProviderStreamGuardConfig = .fromEnvironment(),
    processEnvironmentOverride: [String: String]? = nil,
    stallOnlyTransport: Bool? = nil
) -> any LLMClient {
    let credentialRoot = providersRoot?.standardizedFileURL
    let router = suppliedRouter ?? SwiftNativeProviderRouting(dataRoot: credentialRoot ?? dataRoot)
    let usesCanonicalBody = credentialRoot != nil
        || dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    let llm: any LLMClient
    if usesCanonicalBody {
        let telemetryRoot: URL? = credentialRoot == nil ? nil : dataRoot
        let stallSession = (stallOnlyTransport ?? (streamGuard.wallTimeout == 0))
            ? ProviderStreamGuard.stallOnlySession : nil
        // Both account-backed adapters resolve the same root as readiness.
        // CodexProcess owns binding its child home to that selected credential.
        llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexProcess(processEnvironmentOverride: processEnvironmentOverride,
                dataRootOverride: credentialRoot ?? dataRoot),
            anthropic: AnthropicTransport(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAI: OpenAITransport(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAIOAuthDirect: ChatGPTTransport(
                session: stallSession ?? ChatGPTTransport.productionSession,
                dataRootOverride: credentialRoot ?? dataRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            anthropicOAuthDirect: AnthropicOAuthTransport(
                session: stallSession ?? AnthropicOAuthTransport.productionSession,
                authPathOverride: credentialRoot.map {
                    $0.appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("anthropic_oauth_direct.json")
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            xaiOAuthDirect: XAIOAuthTransport(
                session: stallSession ?? .shared,
                tokenPathOverride: credentialRoot.map {
                    XAIOAuthTransport.tokenPath(dataRoot: $0)
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            moonshot: MoonshotTransport(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            kimiCode: AnthropicTransport.kimiCode(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openRouter: OpenRouterTransport(session: stallSession ?? .shared, dataRootOverride: credentialRoot),
            streamGuardConfig: streamGuard,
            lifecycleObserver: lifecycleObserver,
            moonshotCatalogDataRoot: credentialRoot ?? PersistenceCore.defaultDataRoot()
        )
    } else {
        // An unnamed alternate credential root cannot borrow the live body.
        llm = AlternateRootUnavailableChatLLMClient()
    }
    return llm
}

private struct AlternateRootUnavailableChatLLMClient: LLMClient {
    private func unavailable() -> NSError {
        NSError(
            domain: "ChatOrchestration",
            code: 503,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "default provider adapters are unavailable for an alternate data root",
            ]
        )
    }

    func complete(prompt: String, system: String?, model: String?, surface: String,
                  purpose: String, tools: [LLMToolSchema]?) async throws -> String {
        throw unavailable()
    }
}
/// One provider transport, selected by the call's checked explicit provider route.
public protocol LLMTransport: Sendable {
    /// How this transport carries tools; required, so a new adapter has to say.
    static var toolWire: ProviderToolWire { get }
    static var carriesImages: Bool { get }
    var providerId: String { get }
    /// Adapters declare whether native schemas or the text tool protocol
    /// can reach the provider; Codex CLI does not carry NativeAgent tools.
    func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// Structured multi-turn variant. `messages` is the conversation; the
    /// system prompt stays in `system:`.
    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String

    /// Structured streaming delivers provider output incrementally.
    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>
}

/// How an adapter's `streamMessages` delivers a reply. Recorded on the
/// `llm.call` row as `streamKind`.
public enum LLMMessagesStreamKind: String, Sendable {
    /// Provider text deltas and tool calls are yielded as they arrive.
    case incremental
    /// Bound by SwiftNativeLLMClient around the adapter's `streamMessages`
    /// so the adapter's `llm.call` row carries the kind.
    @TaskLocal public static var current: LLMMessagesStreamKind?
}

extension LLMTransport {
    public static var carriesImages: Bool { true }
}

// MARK: - LLMError

public enum LLMError: Error, Equatable, LocalizedError {
    case failure(ProviderFailure)
    case notConfigured(provider: String)
    /// A fresh provider-owned catalog positively excludes an explicitly
    /// selected model. The selection is preserved for user repair; execution
    /// must not substitute a different model or provider.
    case modelUnavailable(provider: String, model: String)
    /// The provider POSITIVELY REJECTED the credentials we sent — an HTTP 401,
    /// or a 403 that means "this key/token is not authorized" (as opposed to a
    /// genuinely-missing key, which stays `.notConfigured`). `detail` carries
    /// the provider's own error-body message when we could parse one, so a
    /// stranger with a revoked or wrong key sees the real cause (reconnect /
    /// check billing) instead of the misleading "you never configured it".
    case authRejected(provider: String, detail: String?)
    case transient(message: String)
    case underlying(message: String)
    case invalidResponse(status: Int)
    /// Provider emitted an explicit error mid-stream (e.g. Anthropic
    /// `event: error` SSE frame with overloaded / rate-limit body). Distinct
    /// from `.transient` so callers can tell pre-stream HTTP errors apart
    /// from mid-stream protocol errors.
    case providerError(message: String)
    /// Stream ended without the provider's documented terminal event
    /// (Anthropic `message_stop`, OpenAI `[DONE]` sentinel), OR ended cleanly
    /// (exit-0 / `[DONE]`) but produced ZERO reply content. Indicates a
    /// truncated / empty reply — a silent EOF or an empty string would
    /// otherwise look like a legitimate clean end.
    case streamTruncated(message: String)
    /// The provider ended at its output budget. Retain prose, withhold tools,
    /// Standalone completions and helper-owned token budgets retain partial prose.
    case outputLengthLimit(partial: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your model in Settings to continue."
        case .modelUnavailable: return "The selected model is unavailable; choose another model."
        case .outputLengthLimit: return "The provider reached its output length limit."
        default: return ProviderFailure.classify(self)?.errorDescription
        }
    }

    public static let retryAfterMaxSeconds = 3600

    public static func rateLimited(message: String, retryAfterSeconds: Int?) -> LLMError {
        .failure(.rateLimited(retryAfter: retryAfterSeconds.flatMap {
            $0 > 0 ? min($0, retryAfterMaxSeconds) : nil
        }))
    }

    public var retryAfterSeconds: Int? {
        guard case .rateLimited(let delay) = ProviderFailure.classify(self) else { return nil }
        return delay
    }

}

// MARK: - SwiftNativeLLMClient

/// Routes completions and streams using one checked `ProviderRoutingSnapshot`
/// for the surface's provider, model preferences and execution controls.
///
/// A selected provider is required. Model families and account catalogs validate
/// compatibility with that explicit route; they do not choose a backend.
/// Missing adapters, unavailable routing and provider/model mismatches fail
/// without substituting a compatible model or another credential route.
///
/// An admitted turn's model takes precedence over the literal `model` argument.
/// With neither, the model comes from the same snapshot's surface preferences,
/// using Chat preferences when the surface has no entry.
public final class SwiftNativeLLMClient: LLMClient {
    private let router: SwiftNativeProviderRouting
    private let codex: any LLMTransport
    private let anthropic: any LLMTransport
    private let openAI: any LLMTransport
    /// Adapter for the explicit ChatGPT OAuth route. Reads the bound root's
    /// credentials and calls the ChatGPT Codex Responses backend. If absent,
    /// that route fails as not configured; it never borrows the API-key route.
    private let openAIOAuthDirect: (any LLMTransport)?
    /// Adapter for the explicit Anthropic OAuth route, including streaming.
    /// If absent, that route fails as not configured; it never borrows the
    /// API-key route.
    private let anthropicOAuthDirect: (any LLMTransport)?
    /// NativeAgent-owned xAI OAuth provider for first-party Grok models: it
    /// calls api.x.ai as a model provider after an xAI OAuth login.
    private let xaiOAuthDirect: (any LLMTransport)?
    /// Moonshot API-key adapter for Kimi models. Kept separate from the
    /// generic OpenAI adapter so provider identity, credentials, endpoint,
    /// K3 reasoning preservation, and live model discovery cannot collapse.
    private let moonshot: (any LLMTransport)?
    /// Kimi Code's exact subscription route reuses the Anthropic Messages wire.
    private let kimiCode: (any LLMTransport)?
    /// OpenRouter adapter for slash-namespaced model ids (`anthropic/claude-...`,
    /// `openai/...`, `meta-llama/...`, etc). Optional so existing tests and
    /// non-production wirings keep compiling — when nil, an `openrouter` route
    /// fails `notConfigured(provider: "openrouter")`.
    private let openRouter: (any LLMTransport)?
    private let streamGuardConfig: ProviderStreamGuardConfig
    private let lifecycleObserver: (any LLMCallLifecycleObserving)?
    /// Exact root for provider-owned rebuildable model catalogs. The public
    /// initializer label retains its older Moonshot-specific name for source
    /// compatibility; OpenRouter retirement checks now use the same root so a
    /// secondary body cannot consult the live user's cache.
    private let moonshotCatalogDataRoot: URL

    public init(
        router: SwiftNativeProviderRouting,
        codex: any LLMTransport,
        anthropic: any LLMTransport,
        openAI: any LLMTransport,
        openAIOAuthDirect: (any LLMTransport)? = nil,
        anthropicOAuthDirect: (any LLMTransport)? = nil,
        xaiOAuthDirect: (any LLMTransport)? = nil,
        moonshot: (any LLMTransport)? = nil,
        kimiCode: (any LLMTransport)? = nil,
        openRouter: (any LLMTransport)? = nil,
        streamGuardConfig: ProviderStreamGuardConfig = .fromEnvironment(),
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        moonshotCatalogDataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.router = router
        self.codex = codex
        self.anthropic = anthropic
        self.openAI = openAI
        self.openAIOAuthDirect = openAIOAuthDirect
        self.anthropicOAuthDirect = anthropicOAuthDirect
        self.xaiOAuthDirect = xaiOAuthDirect
        self.moonshot = moonshot
        self.kimiCode = kimiCode
        self.openRouter = openRouter
        self.streamGuardConfig = streamGuardConfig
        self.lifecycleObserver = lifecycleObserver
        self.moonshotCatalogDataRoot = moonshotCatalogDataRoot
    }

    /// Entitlement belongs to the selected route's catalog, not model spelling.
    private static let firstPartyOAuthDirectProviderIDs: Set<String> = [
        "anthropic_oauth_direct",
        "openai_oauth_direct",
    ]

    private func validateCatalogAvailability(_ resolution: AdapterResolution) throws {
        if resolution.familyMismatch {
            throw LLMError.modelUnavailable(
                provider: resolution.providerId,
                model: resolution.model
            )
        }
        if Self.firstPartyOAuthDirectProviderIDs.contains(resolution.providerId), !resolution.catalogListsModel {
            throw LLMError.modelUnavailable(provider: resolution.providerId, model: resolution.model)
        }
        guard resolution.providerId == "openrouter" else { return }
        if OpenRouterModelCatalog.cachedAvailability(
            of: resolution.model,
            dataRoot: moonshotCatalogDataRoot
        ) == .unavailable {
            throw LLMError.modelUnavailable(
                provider: "openrouter",
                model: resolution.model
            )
        }
    }

    private func providerLifecycleStart(
        resolution: AdapterResolution,
        surface: String,
        streaming: Bool,
        reasoningEffort: String?
    ) async -> LLMCallLifecycleEvent {
        let event = LLMCallLifecycleEvent(
            id: UUID().uuidString.lowercased(),
            phase: .started,
            providerId: resolution.providerId,
            model: resolution.model,
            surface: surface,
            sessionId: LLMCallContext.sessionId,
            turnId: TurnTraceContext.turnId,
            reasoningEffort: reasoningEffort,
            streaming: streaming
        )
        await lifecycleObserver?.observeProviderCall(event)
        return event
    }

    private func providerLifecycleFinish(
        _ started: LLMCallLifecycleEvent,
        phase: LLMCallLifecyclePhase,
        receipt: OSAllocatedUnfairLock<LLMCallTraceRecorder.Receipt>? = nil,
        streamKind: LLMMessagesStreamKind? = nil,
        error: Error? = nil
    ) async {
        var noReply = false
        if case .noReply? = error.flatMap(ProviderFailure.classify) { noReply = true }
        guard let terminal = started.terminal(
            phase, firstOutputMs: receipt?.withLock(\.ttftMs), streamKind: streamKind?.rawValue, noReply: noReply,
            requestBytes: receipt?.withLock(\.requestBytes)) else { return }
        await lifecycleObserver?.observeProviderCall(terminal)
        if phase == .succeeded {
            RepairOwed.settle(moonshotCatalogDataRoot, operation: "model.call:" + started.providerId + ":" + started.model,
                             evidence: .init(source: "provider", id: started.id))
        }
    }

    /// Written under the request's identity: no row when the adapter's came first.
    private func recordFailedCall(_ started: LLMCallLifecycleEvent, error: Error,
                                  startedAt: TimeInterval, recorded: OSAllocatedUnfairLock<LLMCallTraceRecorder.Receipt>) async -> Error {
        await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
        await LLMCallContext.$surface.withValue(started.surface) {
            await LLMCallTraceRecorder(dataRootOverride: LLMCallContext.traceDataRootOverride).record(
                provider: started.providerId, model: started.model, streaming: started.streaming,
                usage: nil, ttftMs: nil,
                durationMs: Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
                status: "failed", errorDetail: ProviderFailure.diagnosticDescription(error))
        }
        }
        // The stream guard's cut, countable on its own beside the failed call,
        // under the provider id its samples carry (the guard's label is prose).
        if case .noReply(_, let seconds, let events, _)? = ProviderFailure.classify(error) {
            await LLMCallTraceRecorder(dataRootOverride: LLMCallContext.traceDataRootOverride)
                .recordNoReply(provider: started.providerId, seconds: seconds, events: events, surface: started.surface)
        }
        if case .outputLengthLimit = error as? LLMError { return error }
        if ProviderFailure.classify(error) == .contextTooLong { return ProviderFailure.normalize(error) }
        let detail = ProviderFailure.diagnosticDescription(error)
        let repair = ProviderFailure.repair(error, provider: started.providerId, model: started.model, surface: started.surface,
            dataRoot: moonshotCatalogDataRoot, id: "provider-repair:" + started.id, evidence: [.init(source: "provider", id: started.id)])
        let normalized = ProviderFailure.normalize(error) as? ProviderFailure.Diagnostic
        return ProviderFailure.Diagnostic(cause: ProviderFailure.classify(error) ?? .malformedResponse, detail: detail,
            deadlineExpired: normalized?.deadlineExpired ?? false, admitted: normalized?.admitted ?? false, repair: repair,
            tries: normalized?.tries ?? 1)
    }

    private struct AdapterResolution {
        let model: String
        let providerId: String
        /// The selected route cannot serve the model's family.
        let familyMismatch: Bool
        let catalogListsModel: Bool
    }

    /// Single source of truth for routing: the explicit provider pick for the
    /// call. A model name is checked against it, never used to choose it.
    private func resolveAdapter(_ admission: TurnRouteAdmission) throws -> AdapterResolution {
        let model = admission.modelId
        let requestedProvider = admission.providerId
        guard let activeProvider = requestedProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ProviderToolCapability.transport(providerID: activeProvider) != nil else {
            throw LLMError.notConfigured(provider: requestedProvider.flatMap { $0.isEmpty ? nil : $0 } ?? "router")
        }
        let catalog = SwiftNativeProviderRouting(dataRoot: moonshotCatalogDataRoot).catalogRows(activeProvider)
        let listsModel = catalog.fault == nil && catalog.rows.contains {
            $0["id"]?.stringValue?.caseInsensitiveCompare(model) == .orderedSame
        }
        let inferred = listsModel ? nil : SwiftNativeProviderRouting.inferredProviderID(forModel: model, dataRoot: moonshotCatalogDataRoot)
        let mismatch = inferred.map { !SwiftNativeProviderRouting.providerCanServeModel(activeProvider, inferredProvider: $0) } ?? false
        return AdapterResolution(model: model, providerId: activeProvider,
            familyMismatch: mismatch, catalogListsModel: listsModel)
    }

    /// The provider `streamMessages` resolves for this call — the same
    /// snapshot, requested-model and adapter resolution, under the caller's
    /// bound `LLMCallContext`. Nil when the call itself would fail there first.
    /// An admitted route already names its provider, so it answers without a
    /// second picker read; dispatch still revalidates it against the snapshot.
    public func servingProviderID(model: String?, surface: String) async -> String? {
        if let bound = LLMCallContext.providerId?.trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty {
            return ProviderToolCapability.transport(providerID: bound.lowercased()) == nil ? nil : bound.lowercased()
        }
        guard let routingSnapshot = try? await checkedRoutingSnapshot(),
              let admission = try? routingSnapshot.routeAdmission(for: surface,
                suppliedModel: model ?? "", inheritingCall: true)
        else { return nil }
        return (try? resolveAdapter(admission))?.providerId
    }

    /// Exact routes select credentials once; marker-tool admission stays here.
    private func adapter(
        for resolution: AdapterResolution,
        tools: [LLMToolSchema]?
    ) throws -> (adapter: any LLMTransport, label: String) {
        let chosen: (adapter: any LLMTransport, label: String)
        switch resolution.providerId {
        case "openrouter":
            guard let openRouter else { throw LLMError.notConfigured(provider: "openrouter") }
            chosen = (openRouter, "openrouter")
        case "anthropic": chosen = (anthropic, "anthropic")
        case "anthropic_oauth_direct":
            guard let anthropicOAuthDirect else { throw LLMError.notConfigured(provider: "anthropic_oauth_direct") }
            chosen = (anthropicOAuthDirect, "anthropic_oauth_direct")
        case "kimi-code":
            guard let kimiCode else { throw LLMError.notConfigured(provider: "kimi-code") }
            chosen = (kimiCode, "kimi-code")
        case "openai": chosen = (openAI, "openai")
        case "openai_oauth_direct":
            guard let openAIOAuthDirect else { throw LLMError.notConfigured(provider: "openai_oauth_direct") }
            chosen = (openAIOAuthDirect, "openai_oauth_direct")
        case "xai_oauth_direct":
            guard let xaiOAuthDirect else { throw LLMError.notConfigured(provider: "xai_oauth_direct") }
            chosen = (xaiOAuthDirect, "xai")
        case "moonshot":
            guard let moonshot else { throw LLMError.notConfigured(provider: "moonshot") }
            chosen = (moonshot, "moonshot")
        case "codex": chosen = (codex, "codex")
        default: throw LLMError.notConfigured(provider: resolution.providerId)
        }
        // A marker transport (the Claude subscription) is never handed a tools
        // array; reaching here with one is this body's own disagreement, said as such.
        if tools != nil, type(of: chosen.adapter).toolWire == .textMarkers {
            let setting = "providers." + (ProviderSurfaceGroups.group(for: LLMCallContext.surface ?? "chat")
                ?? ProviderSurfaceGroups.chat).id + "_model"
            throw ToolFailureError(
                "NativeAgent did not send this call: its dispatch bound a tools array to \(resolution.providerId) · \(resolution.model), whose transport takes tools as text markers. This is a fault in NativeAgent, not the provider; nothing was sent. \(setting) can move this work to another model meanwhile.",
                effects: .none, owner: "NativeAgent provider dispatch",
                nextCall: ToolFailureError.call("app", ["action": .string("setting.get"), "args": .object(["setting": .string(setting)])]))
        }
        return chosen
    }

    /// Non-streaming completions need their own wall deadline; the stream guard covers only streams.
    private func withCompletionWall<T: Sendable>(
        _ label: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // One wall for every route: a provider's name never shortens its clock.
        let wall = streamGuardConfig.wallTimeout
        let admittedWork: @Sendable () async throws -> T = {
            try await LLMCallContext.$wallOwned.withValue(true) { try await work() }
        }
        guard wall > 0 else {
            return try await ProviderStreamContext.$stallOnly.withValue(true) { try await admittedWork() }
        }
        let workTask = Task { try await admittedWork() }
        return try await withTaskCancellationHandler {
            do {
                return try await TurnDeadline.withThrowingDeadline(seconds: wall, clock: .wallClock) {
                    try await workTask.value
                }
            } catch {
                workTask.cancel()
                // The response clock may end first; the effect's settlement
                // still owns its result until the real child and drains exit.
                let settled = await settle { await workTask.result }
                if Task.isCancelled, case .success(let value) = settled { return value }
                if error is TurnDeadline.DeadlineExceeded {
                    throw ProviderFailure.Diagnostic(cause: .network,
                        detail: "\(label) completion wall timeout after \(Int(wall))s", deadlineExpired: true)
                }
                throw error
            }
        } onCancel: { workTask.cancel() }
    }

    private func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        do {
            let snapshot = try await router.checkedRoutingSnapshot()
            RepairOwed.settle(moonshotCatalogDataRoot, operation: "provider.routing.read",
                             evidence: .init(source: "provider.routing", id: UUID().uuidString))
            return snapshot
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let failure as ToolFailureError {
            let id = "routing-repair:" + UUID().uuidString
            if let owner = failure.owner {
                RepairOwed.owe(moonshotCatalogDataRoot, id: id, kind: .act, operation: "provider.routing.read",
                    owner: owner, words: failure.message, nextCall: failure.nextCall, tap: failure.tap)
            }
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable, detail: failure.message, repair: failure)
        }
        catch {
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                detail: "\(moonshotCatalogDataRoot.appendingPathComponent("providers").path): \(ProviderFailure.diagnosticDescription(error))")
        }
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String,
        purpose: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await LLMCallContext.$purpose.withValue(purpose) {
            if LLMCallContext.turnTokenBudget != nil {
                var result = ""
                for try await event in streamMessages(messages: [.user(prompt)], system: system, model: model, surface: surface, tools: tools) {
                    switch event {
                    case .textDelta(let text): result += text
                    case .toolCall(let call):
                        let args = String(decoding: call.inputJSON, as: UTF8.self)
                        result += "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
                    case .keepAlive, .replyTextSettled, .toolBoundary: break
                    }
                }
                return result
            }
            return try await executeCompletion(model: model, surface: surface, tools: tools) { adapter, effectiveModel in
                try await adapter.complete(prompt: prompt, system: system, model: effectiveModel, tools: tools)
            }
        }
    }

    private func executeCompletion(
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?,
        operation: @escaping @Sendable (any LLMTransport, String) async throws -> String
    ) async throws -> String {
        let routingSnapshot = try await checkedRoutingSnapshot()
        let admission = try routingSnapshot.routeAdmission(for: surface,
            suppliedModel: model ?? "", inheritingCall: true)
        let resolution = try resolveAdapter(admission)
        ProviderToolCapability.recordOfferedTools(providerID: resolution.providerId, tools: tools)
        let attemptStartedAt = ProcessInfo.processInfo.systemUptime
        let lifecycle = await providerLifecycleStart(
            resolution: resolution,
            surface: surface,
            streaming: false,
            reasoningEffort: admission.reasoningEffort
        )
        let recorded = OSAllocatedUnfairLock(initialState: LLMCallTraceRecorder.Receipt())
        do {
            try validateCatalogAvailability(resolution)
            let result = try await withCompletionWall(resolution.providerId) { [self] in
                    try await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
                        try await LLMCallContext.$surface.withValue(surface) {
                            try await LLMCallContext.$reasoningEffort.withValue(admission.reasoningEffort) {
                                try await LLMCallContext.$serviceTier.withValue(admission.serviceTier) {
                                    try await operation(adapter(for: resolution, tools: tools).adapter, resolution.model)
                                }
                            }
                        }
                    }
            }
            await providerLifecycleFinish(lifecycle, phase: Task.isCancelled ? .cancelled : .succeeded)
            return result
        } catch is CancellationError {
            await providerLifecycleFinish(lifecycle, phase: .cancelled)
            throw CancellationError()
        } catch {
            await providerLifecycleFinish(lifecycle, phase: .failed)
            throw await recordFailedCall(lifecycle, error: error, startedAt: attemptStartedAt, recorded: recorded)
        }
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        // Bind the calling surface inside the worker task for its full lifetime.
        AsyncThrowingStream { continuation in
            let task = Task {
                await LLMCallContext.$surface.withValue(surface) {
                var lifecycle: LLMCallLifecycleEvent?
                var streamKind: LLMMessagesStreamKind?
                let attemptStartedAt = ProcessInfo.processInfo.systemUptime
                let requestBytes = LLMMessage.inputBytes(messages, system: system, tools: tools ?? [])
                let recorded = OSAllocatedUnfairLock(initialState: LLMCallTraceRecorder.Receipt())
                recorded.withLock { $0.requestBytes = requestBytes }
                do {
                    let routingSnapshot = try await self.checkedRoutingSnapshot()
                    let admission = try routingSnapshot.routeAdmission(for: surface,
                        suppliedModel: model ?? "", inheritingCall: true)

                    var streamGuardConfig = self.streamGuardConfig

                    func forward(
                        makeStream: @escaping @Sendable () -> AsyncThrowingStream<LLMMessageStreamEvent, Error>,
                        providerLabel: String
                    ) async throws {
                    let guardedStream = ProviderStreamGuard.wrap(
                            makeUpstream: { LLMCallContext.$wallOwned.withValue(true) { makeStream() } },
                            config: streamGuardConfig,
                            providerLabel: providerLabel,
                            isOutput: { _ in true }
                        )
                        // The request is sent as the guarded stream is first read.
                        try Task.checkCancellation()
                        ProviderStreamContext.dispatched?()
                        for try await event in guardedStream {
                            try Task.checkCancellation()
                            if let budget = LLMCallContext.turnTokenBudget {
                                switch event {
                                case .textDelta(let delta):
                                    let kept = budget.take(delta)
                                    if !kept.isEmpty { continuation.yield(.textDelta(kept)) }
                                case .toolCall(let call):
                                    _ = budget.take(call.name + String(decoding: call.inputJSON, as: UTF8.self), visible: false)
                                    if !budget.exhausted { continuation.yield(event) }
                                case .keepAlive, .replyTextSettled, .toolBoundary: continuation.yield(event)
                                }
                                if budget.exhausted { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                            } else { continuation.yield(event) }
                        }
                    }

                    if let budget = LLMCallContext.turnTokenBudget, !budget.beginRequest() { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                    let resolution = try self.resolveAdapter(admission)
                    ProviderToolCapability.recordOfferedTools(providerID: resolution.providerId, tools: tools)
                    let effectiveModel = resolution.model
                    let started = await self.providerLifecycleStart(
                        resolution: resolution,
                        surface: surface,
                        streaming: true,
                        reasoningEffort: admission.reasoningEffort
                    )
                    lifecycle = started
                    try self.validateCatalogAvailability(resolution)
                    try await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
                    try await LLMCallContext.$reasoningEffort.withValue(admission.reasoningEffort) {
                    try await LLMCallContext.$serviceTier.withValue(admission.serviceTier) {
                    let (adapter, providerLabel) = try self.adapter(for: resolution, tools: tools)
                    let kind = LLMMessagesStreamKind.incremental
                    streamKind = kind
                    if let deadline = await self.lifecycleObserver?.firstOutputDeadline(
                        provider: resolution.providerId, model: effectiveModel, streamKind: kind.rawValue, requestBytes: requestBytes) {
                        streamGuardConfig.firstOutput = deadline
                    }
                    try await ProviderStreamContext.$stallOnly.withValue(streamGuardConfig.wallTimeout == 0) {
                    try await LLMMessagesStreamKind.$current.withValue(kind) {
                    try await forward(makeStream: { adapter.streamMessages(
                        messages: messages, system: system, model: effectiveModel, tools: tools
                    ) }, providerLabel: providerLabel)
                    }
                    }
                    }
                    }
                    }
                    // EOF can arrive as nil after cancellation; check before recording success.
                    try Task.checkCancellation()
                    await self.providerLifecycleFinish(started, phase: .succeeded, receipt: recorded,
                                                       streamKind: streamKind)
                    continuation.finish()
                } catch is CancellationError {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .cancelled)
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .failed, receipt: recorded,
                                                           streamKind: streamKind, error: error)
                        let owned = await self.recordFailedCall(lifecycle, error: error, startedAt: attemptStartedAt, recorded: recorded)
                        continuation.finish(throwing: owned)
                        return
                    }
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}

// MARK: - Credentials resolver

/// One credential source per API-key provider: the Keychain reference Settings
/// saves into `<dataRoot>/providers/<providerConfigFile>` (or a legacy api_key). No environment
/// variable and no other provider's file (the Codex CLI's `auth.json`) is
/// consulted — a key that is not there is `nil`, and the caller fails with
/// `notConfigured` naming the provider.
public enum LLMCredentialResolver {
    /// Missing configuration is distinct from unreadable configuration or a
    /// broken Keychain reference. Execution consumes this checked boundary.
    public static func checkedAPIKey(providerConfigFile: String, dataRoot: URL) throws -> String? {
        let path = dataRoot.appendingPathComponent("providers/\(providerConfigFile)")
        do {
            let data: Data
            do { data = try Data(contentsOf: path) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try checkedAPIKey(providerConfigObject: object)
        } catch {
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                detail: "\(path.path): \(ProviderFailure.diagnosticDescription(error))")
        }
    }

    public static func checkedAPIKey(providerConfigObject: [String: Any]?) throws -> String? {
        guard let object = providerConfigObject else { return nil }
        if let value = object[ProviderAPIKeyStore.referenceField] {
            guard let reference = value as? String else { throw CocoaError(.fileReadCorruptFile) }
            guard let key = try ProviderAPIKeyStore.read(reference) else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable, detail: "Referenced provider Keychain item is missing.")
            }
            return key
        }
        if let value = object["api_key"], !(value is String) { throw CocoaError(.fileReadCorruptFile) }
        let key = (object["api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    public static func resolveAPIKey(providerConfigFile: String, dataRoot: URL) -> String? {
        try? checkedAPIKey(providerConfigFile: providerConfigFile, dataRoot: dataRoot)
    }

    /// Use the caller's locked config snapshot so readiness and defaults use the same bytes.
    public static func resolveAPIKey(providerConfigObject: [String: Any]?) -> String? {
        try? checkedAPIKey(providerConfigObject: providerConfigObject)
    }
}

extension LLMMessageStreamEvent {
    /// A whole reply is its stream, collected: text, then each complete call as a
    /// `<tool_use id name>args</tool_use>` marker. Every provider's buffered call is this,
    /// so a reply is decoded, validated and receipted exactly once, the way a turn's is.
    public static func reply(collecting events: AsyncThrowingStream<LLMMessageStreamEvent, Error>) async throws -> String {
        var text = ""
        var markers: [String] = []
        for try await event in events {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall(let call):
                let arguments = String(decoding: call.inputJSON, as: UTF8.self)
                markers.append("<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(arguments)</tool_use>")
            case .toolBoundary(.outputLimit): throw LLMError.outputLengthLimit(partial: text)
            case .keepAlive, .replyTextSettled, .toolBoundary: break
            }
        }
        try Task.checkCancellation()
        return ([text.trimmingCharacters(in: .whitespacesAndNewlines)] + markers)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
