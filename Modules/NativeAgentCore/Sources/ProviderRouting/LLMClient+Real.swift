import Foundation
import CryptoKit
import NativeAgentShared
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
import Experiences
// Blueprint: | `LLMClient+Real.swift` | `makeResidentProviderLLMClient`, `SwiftNativeLLMClient`, `ProviderToolCapability.checkedWire` |

/// One provider assembly for resident turns and background body work. Routing, credentials, account catalogs and adapter transports have exactly one owner.
public func makeResidentProviderLLMClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    providersRoot: URL? = nil,
    router suppliedRouter: SwiftNativeProviderRouting? = nil,
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    processEnvironmentOverride: [String: String]? = nil
) -> any LLMClient {
    let credentialRoot = providersRoot?.standardizedFileURL
    let router = suppliedRouter ?? SwiftNativeProviderRouting(dataRoot: credentialRoot ?? dataRoot)
    let usesCanonicalBody = credentialRoot != nil
        || dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    let llm: any LLMClient
    if usesCanonicalBody {
        let telemetryRoot: URL? = credentialRoot == nil ? nil : dataRoot
        // Both account-backed adapters resolve the same root as readiness. CodexProcess owns binding its child home to that selected credential.
        llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexProcess(processEnvironmentOverride: processEnvironmentOverride,
                dataRootOverride: credentialRoot ?? dataRoot),
            anthropic: AnthropicTransport(
                session: ProviderHTTP.session,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAI: OpenAITransport(
                session: ProviderHTTP.session,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAIOAuthDirect: ChatGPTTransport(
                session: ChatGPTTransport.productionSession,
                dataRootOverride: credentialRoot ?? dataRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            anthropicOAuthDirect: AnthropicOAuthTransport(
                session: AnthropicOAuthTransport.productionSession,
                authPathOverride: credentialRoot.map {
                    $0.appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("anthropic_oauth_direct.json")
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            xaiOAuthDirect: XAIOAuthTransport(
                session: ProviderHTTP.session,
                tokenPathOverride: credentialRoot.map {
                    XAIOAuthTransport.tokenPath(dataRoot: $0)
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            moonshot: MoonshotTransport(
                session: ProviderHTTP.session,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            kimiCode: AnthropicTransport.kimiCode(
                session: ProviderHTTP.session,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            meta: AnthropicTransport(
                session: ProviderHTTP.session,
                endpoint: URL(string: "https://api.meta.ai/v1/messages"),
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot,
                providerId: "meta",
                credentialConfigFile: "meta.json",
                firstPartyAnthropicToolContract: false
            ),
            openRouter: OpenRouterTransport(session: ProviderHTTP.session, dataRootOverride: credentialRoot),
            diagnosticDataRoot: dataRoot,
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

    func complete(prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?, call: LLMCall) async throws -> String {
        throw unavailable()
    }

    func servingProviderID(model: String?, call: LLMCall) async throws -> String {
        throw unavailable()
    }
}

extension ProviderToolCapability {
    /// Execution distinguishes a known text-only adapter from an unknown route. Missing capability cannot authorize a tool grammar.
    public static func checkedWire(providerID: String) throws -> ProviderToolWire {
        guard let transport = transport(providerID: providerID) else {
            throw LLMError.notConfigured(provider: providerID)
        }
        return transport.toolWire
    }
}
/// The checked explicit route alone selects the transport.
public protocol LLMTransport: Sendable {
    /// Every adapter must declare its tool grammar.
    static var toolWire: ProviderToolWire { get }
    static var carriesImages: Bool { get }
    var providerId: String { get }
    /// Exact wire output cap; zero explicitly declares no output-cap field.
    func requestOutputTokens(model: String, call: LLMCall) throws -> Int
    /// Adapters declare whether native schemas or the text tool protocol can reach the provider; Codex CLI does not carry NativeAgent tools.
    func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) async throws -> String

    /// Structured history stays separate from the turn-level system prompt.
    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) async throws -> String

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>
}

/// Record delivery kind on the call receipt so consumers can distinguish streaming behavior.
public enum LLMMessagesStreamKind: String, Sendable {
    case incremental
    /// Bound by SwiftNativeLLMClient around the adapter's `streamMessages` so the adapter's `llm.call` row carries the kind.
    @TaskLocal public static var current: LLMMessagesStreamKind?
}

extension LLMTransport {
    public static var carriesImages: Bool { true }
}

// MARK: - LLMError

public enum LLMError: Error, Equatable, LocalizedError {
    case failure(ProviderFailure)
    case notConfigured(provider: String)
    /// A fresh provider-owned catalog positively excludes an explicitly selected model. The selection is preserved for user repair; execution must not
    /// substitute a different model or provider.
    case modelUnavailable(provider: String, model: String)
    /// Credential rejection is distinct from missing configuration; retain the provider's cause so repair asks for the right action.
    case authRejected(provider: String, detail: String?)
    case transient(message: String)
    case underlying(message: String)
    case invalidResponse(status: Int)
    /// Mid-stream provider errors stay distinct from pre-stream HTTP failures.
    case providerError(message: String)
    /// Missing terminal evidence is truncation, even for a request that permits a silent answer.
    case streamTruncated(message: String)
    /// Output-budget cuts preserve partial prose and withhold tools.
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

/// Use one checked routing snapshot. Explicit route and admitted model outrank saved choices; missing adapters or incompatible models require repair,
/// never substitution.
public final class SwiftNativeLLMClient: LLMClient {
    private let router: SwiftNativeProviderRouting
    private let codex: any LLMTransport
    private let anthropic: any LLMTransport
    private let openAI: any LLMTransport
    /// An unavailable ChatGPT adapter cannot borrow API-key credentials.
    private let openAIOAuthDirect: (any LLMTransport)?
    /// An unavailable Anthropic OAuth adapter cannot borrow API-key credentials.
    private let anthropicOAuthDirect: (any LLMTransport)?
    private let xaiOAuthDirect: (any LLMTransport)?
    /// Kimi requires its own credentials, endpoint, reasoning replay and discovery identity.
    private let moonshot: (any LLMTransport)?
    /// Kimi Code's exact subscription route reuses the Anthropic Messages wire.
    private let kimiCode: (any LLMTransport)?
    private let meta: (any LLMTransport)?
    /// A missing OpenRouter adapter is notConfigured for that route; it cannot borrow a first-party adapter.
    private let openRouter: (any LLMTransport)?
    private let diagnosticDataRoot: URL?
    private let lifecycleObserver: (any LLMCallLifecycleObserving)?
    /// Catalogs must use this body's exact root so a secondary runtime cannot consult the live user's cache.
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
        meta: (any LLMTransport)? = nil,
        openRouter: (any LLMTransport)? = nil,
        diagnosticDataRoot: URL? = nil,
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
        self.meta = meta
        self.openRouter = openRouter
        self.diagnosticDataRoot = diagnosticDataRoot
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
        reasoningEffort: String?, call: LLMCall
    ) async -> LLMCallLifecycleEvent {
        let event = LLMCallLifecycleEvent(
            id: UUID().uuidString.lowercased(),
            phase: .started,
            providerId: resolution.providerId,
            model: resolution.model,
            surface: surface,
            sessionId: call.session,
            turnId: call.turn?.id,
            reasoningEffort: reasoningEffort,
            streaming: streaming
        )
        if !call.preview { await lifecycleObserver?.observeProviderCall(event) }
        return event
    }

    private func providerLifecycleFinish(
        _ started: LLMCallLifecycleEvent,
        phase: LLMCallLifecyclePhase,
        receipt: OSAllocatedUnfairLock<LLMCallTraceRecorder.Receipt>? = nil,
        streamKind: LLMMessagesStreamKind? = nil,
        error: Error? = nil, call: LLMCall
    ) async {
        guard !call.preview else { return }
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
                                  startedAt: TimeInterval, recorded: OSAllocatedUnfairLock<LLMCallTraceRecorder.Receipt>, call: LLMCall) async -> Error {
        await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
            await LLMCallTraceRecorder(dataRootOverride: diagnosticDataRoot).record(
                call: call, provider: started.providerId, model: started.model, streaming: started.streaming,
                usage: nil, ttftMs: nil,
                durationMs: Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
                status: "failed", errorDetail: ProviderFailure.diagnosticDescription(error))
        }
        // The stream guard's cut, countable on its own beside the failed call, under the provider id its samples carry (the guard's label is prose).
        if case .noReply(_, let seconds, let events, _)? = ProviderFailure.classify(error) {
            await LLMCallTraceRecorder(dataRootOverride: diagnosticDataRoot)
                .recordNoReply(provider: started.providerId, seconds: seconds, events: events, surface: started.surface, call: call)
        }
        if case .outputLengthLimit = error as? LLMError { return error }
        // This owns valid pipe prefixes and exact invalid bytes. A prose-only Diagnostic would discard the evidence needed to repair the encoding.
        if error is CodexOutputEncodingFailure { return error }
        if error is ProviderRecovery.Stopped { return error }
        if ProviderFailure.classify(error) == .contextTooLong { return ProviderFailure.normalize(error) }
        let detail = ProviderFailure.diagnosticDescription(error)
        let repair = ProviderFailure.repair(error, provider: started.providerId, model: started.model, surface: started.surface,
            dataRoot: moonshotCatalogDataRoot, id: "provider-repair:" + started.id, evidence: [.init(source: "provider", id: started.id)], call: call)
        let normalized = ProviderFailure.normalize(error) as? ProviderFailure.Diagnostic
        return ProviderFailure.Diagnostic(cause: ProviderFailure.classify(error) ?? .malformedResponse, detail: detail,
            deadlineExpired: normalized?.deadlineExpired ?? false, admitted: normalized?.admitted ?? false, repair: repair,
            tries: normalized?.tries ?? 1, retryAfter: normalized?.retryAfter)
    }

    private struct AdapterResolution: Sendable {
        let model: String
        let providerId: String
        let familyMismatch: Bool
        let catalogListsModel: Bool
    }

    /// Only the explicit provider pick chooses routing; model spelling validates compatibility.
    private func resolveAdapter(_ admission: TurnRouteAdmission, call: LLMCall) throws -> AdapterResolution {
        let model = admission.modelId
        let requestedProvider = admission.providerId
        guard let activeProvider = requestedProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ProviderToolCapability.transport(providerID: activeProvider) != nil else {
            throw LLMError.notConfigured(provider: requestedProvider.flatMap { $0.isEmpty ? nil : $0 } ?? "router")
        }
        let catalog = SwiftNativeProviderRouting(dataRoot: moonshotCatalogDataRoot).catalogRows(activeProvider, preview: call.preview)
        let listsModel = catalog.fault == nil && catalog.rows.contains {
            $0["id"]?.stringValue?.caseInsensitiveCompare(model) == .orderedSame
        }
        let inferred = listsModel ? nil : SwiftNativeProviderRouting.inferredProviderID(forModel: model, dataRoot: moonshotCatalogDataRoot)
        let mismatch = inferred.map { !SwiftNativeProviderRouting.providerCanServeModel(activeProvider, inferredProvider: $0) } ?? false
        return AdapterResolution(model: model, providerId: activeProvider,
            familyMismatch: mismatch, catalogListsModel: listsModel)
    }

    /// Inspection and dispatch resolve the same held admission.
    public func servingProviderID(model: String?, call: LLMCall) async throws -> String {
        let snapshot = try await checkedRoutingSnapshot(call: call)
        let admission = try snapshot.routeAdmission(for: call.surface, suppliedModel: model ?? "", call: call)
        let resolution = try resolveAdapter(admission, call: call)
        try validateCatalogAvailability(resolution)
        return resolution.providerId
    }

    public func requestOutputTokens(model: String, call: LLMCall) async throws -> Int {
        let snapshot = try await checkedRoutingSnapshot(call: call)
        let admission = try snapshot.routeAdmission(for: call.surface, suppliedModel: model, call: call)
        let resolution = try resolveAdapter(admission, call: call)
        try validateCatalogAvailability(resolution)
        var routedCall = call
        routedCall.admission = try admission.modelAdmission
        return try adapter(for: resolution, tools: nil, call: routedCall)
            .requestOutputTokens(model: resolution.model, call: routedCall)
    }

    /// Exact routes select credentials once; marker-tool admission stays here.
    private func adapter(
        for resolution: AdapterResolution,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) throws -> any LLMTransport {
        let chosen: any LLMTransport
        switch resolution.providerId {
        case "openrouter":
            guard let openRouter else { throw LLMError.notConfigured(provider: "openrouter") }
            chosen = openRouter
        case "anthropic": chosen = anthropic
        case "anthropic_oauth_direct":
            guard let anthropicOAuthDirect else { throw LLMError.notConfigured(provider: "anthropic_oauth_direct") }
            chosen = anthropicOAuthDirect
        case "kimi-code":
            guard let kimiCode else { throw LLMError.notConfigured(provider: "kimi-code") }
            chosen = kimiCode
        case "openai": chosen = openAI
        case "meta":
            guard let meta else { throw LLMError.notConfigured(provider: "meta") }
            chosen = meta
        case "openai_oauth_direct":
            guard let openAIOAuthDirect else { throw LLMError.notConfigured(provider: "openai_oauth_direct") }
            chosen = openAIOAuthDirect
        case "xai_oauth_direct":
            guard let xaiOAuthDirect else { throw LLMError.notConfigured(provider: "xai_oauth_direct") }
            chosen = xaiOAuthDirect
        case "moonshot":
            guard let moonshot else { throw LLMError.notConfigured(provider: "moonshot") }
            chosen = moonshot
        case "codex": chosen = codex
        default: throw LLMError.notConfigured(provider: resolution.providerId)
        }
        // A marker transport (the Claude subscription) is never handed a tools array; reaching here with one is this body's own disagreement, said as such.
        if tools != nil, type(of: chosen).toolWire == .textMarkers {
            let setting = "providers." + (ProviderSurfaceGroups.group(for: call.surface)
                ?? ProviderSurfaceGroups.chat).id + "_model"
            throw ToolFailureError(
                """
                    NativeAgent did not send this call: its dispatch bound a tools array to \(resolution.providerId) · \(resolution.model), whose \
                    transport takes tools as text markers. This is a fault in NativeAgent, not the provider; nothing was sent. \(setting) can move this \
                    work to another model meanwhile.
                    """,
                effects: .none, owner: "NativeAgent provider dispatch",
                nextCall: ToolFailureError.call("app", ["action": .string("setting.get"), "args": .object(["setting": .string(setting)])]))
        }
        return chosen
    }

    private func checkedRoutingSnapshot(call: LLMCall) async throws -> ProviderRoutingSnapshot {
        do {
            let snapshot = try await router.checkedRoutingSnapshot(preview: call.preview)
            if !call.preview {
                RepairOwed.settle(moonshotCatalogDataRoot, operation: "provider.routing.read",
                                 evidence: .init(source: "provider.routing", id: UUID().uuidString))
            }
            return snapshot
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let failure as ToolFailureError {
            let id = "routing-repair:" + UUID().uuidString
            if !call.preview, let owner = failure.owner {
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
        prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(
            collecting: { held in self.streamMessages(messages: [.user(prompt)], system: system,
                model: model, tools: tools, call: held) },
            using: LLMCallTraceRecorder(dataRootOverride: diagnosticDataRoot), call: call)
    }

    public func streamMessages(
        messages: [LLMMessage], system: String?, model: String?, tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lifecycle: LLMCallLifecycleEvent?
                var streamKind: LLMMessagesStreamKind?
                let attemptStartedAt = ProcessInfo.processInfo.systemUptime
                let requestBytes = LLMMessage.inputBytes(messages, system: system, tools: tools ?? [])
                let recorded = OSAllocatedUnfairLock(initialState: LLMCallTraceRecorder.Receipt())
                recorded.withLock { $0.requestBytes = requestBytes }
                // What the provider's prefix cache sees, without the words: the scope and the request's first 2k and 8k bytes, hashed.
                let front = Data(((system ?? "") + messages.flatMap(\.content).compactMap { block -> String? in
                    if case .text(let text) = block { return text }; return nil
                }.joined()).utf8)
                let requestFront = [Data((call.session ?? "").utf8), front.prefix(2_000), front.prefix(8_000)]
                    .map { SHA256.hash(data: $0).prefix(4).map { String(format: "%02x", $0) }.joined() }.joined(separator: ":")
                recorded.withLock { $0.requestFront = requestFront }
                do {
                    if !call.requestShapeUnmeasured, call.conversationRequest {
                        recorded.withLock {
                            $0.requestCharacters = LLMMessage.inputCharacters(messages, system: system, tools: tools ?? [])
                            $0.requestPlan = call.requestPlan
                        }
                    }
                    let routingSnapshot = try await self.checkedRoutingSnapshot(call: call)
                    let admission = try routingSnapshot.routeAdmission(for: call.surface,
                        suppliedModel: model ?? "", call: call)
                    if call.replyWork?.isStopped == true { throw CancellationError() }
                    var routedCall = call
                    routedCall.admission = try admission.modelAdmission
                    if routedCall.traceDataRoot == nil { routedCall.traceDataRoot = self.diagnosticDataRoot }
                    let held = routedCall
                    if let budget = held.turn?.tokenBudget, !budget.beginRequest() {
                        throw LLMError.outputLengthLimit(partial: budget.partialReply)
                    }
                    let resolution = try self.resolveAdapter(admission, call: call)
                    ProviderToolCapability.recordOfferedTools(providerID: resolution.providerId, tools: tools, call: held)
                    let started = await self.providerLifecycleStart(resolution: resolution, surface: held.surface,
                        streaming: true, reasoningEffort: admission.reasoningEffort, call: held)
                    lifecycle = started
                    try self.validateCatalogAvailability(resolution)
                    try await LLMCallTraceRecorder.$requestRecorded.withValue(recorded) {
                        let adapter = try self.adapter(for: resolution, tools: tools, call: held)
                        let kind = LLMMessagesStreamKind.incremental
                        streamKind = kind
                        try await LLMMessagesStreamKind.$current.withValue(kind) {
                        let stream = ProviderStreamGuard.wrap(makeUpstream: { wire in adapter.streamMessages(
                            messages: messages, system: system, model: resolution.model, tools: tools, call: wire) },
                            call: held)
                        try Task.checkCancellation()
                        held.lifetime.dispatched?()
                            for try await event in stream {
                                try Task.checkCancellation()
                                if let budget = held.turn?.tokenBudget {
                                    switch event {
                                    case .textDelta(let delta):
                                        let kept = budget.take(delta)
                                        if !kept.isEmpty { continuation.yield(.textDelta(kept)) }
                                    case .toolCall(let tool):
                                        _ = budget.take(tool.name + String(decoding: tool.inputJSON, as: UTF8.self), visible: false)
                                        if !budget.exhausted { continuation.yield(event) }
                                    case .keepAlive, .callInput, .replyTextSettled, .toolBoundary: continuation.yield(event)
                                    }
                                    if budget.exhausted { throw LLMError.outputLengthLimit(partial: budget.partialReply) }
                                } else { continuation.yield(event) }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    if held.replyWork?.isStopped == true { throw CancellationError() }
                    await self.providerLifecycleFinish(started, phase: .succeeded, receipt: recorded,
                        streamKind: streamKind, call: held)
                    continuation.finish()
                } catch is CancellationError {
                    if let lifecycle { await self.providerLifecycleFinish(lifecycle, phase: .cancelled, call: call) }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let lifecycle {
                        await self.providerLifecycleFinish(lifecycle, phase: .failed, receipt: recorded,
                            streamKind: streamKind, error: error, call: call)
                        let owned = await self.recordFailedCall(lifecycle, error: error,
                            startedAt: attemptStartedAt, recorded: recorded, call: call)
                        continuation.finish(throwing: owned)
                        return
                    }
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
            }
            call.replyWork?.own(task, stop: {})
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}

// MARK: - Credentials resolver

/// One credential source per API-key provider: the Keychain reference Settings saves into `<dataRoot>/providers/<providerConfigFile>`. No environment
/// variable and no other provider's file (the Codex CLI's `auth.json`) is consulted — a key that is not there is `nil`, and the caller fails with
/// `notConfigured` naming the provider.
public enum LLMCredentialResolver {
    /// Missing configuration is distinct from unreadable configuration or a broken Keychain reference. Execution consumes this checked boundary.
    public static func checkedAPIKey(providerConfigFile: String, dataRoot: URL) throws -> String? {
        let path = dataRoot.appendingPathComponent("providers/\(providerConfigFile)")
        do {
            let data: Data
            do { data = try Data(contentsOf: path) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard object["api_key"] == nil else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                    detail: "This provider has plaintext API-key bytes instead of a Keychain reference. Save the key in Providers to repair its storage.")
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

}

extension LLMMessageStreamEvent {
    /// A whole reply is its stream, collected: text, then each complete call as a `<tool_use id name>args</tool_use>` marker. Every provider's buffered
    /// call is this, so a reply is decoded, validated and receipted exactly once, the way a turn's is.
    public static func reply(
        collecting events: @escaping @Sendable (LLMCall) -> AsyncThrowingStream<LLMMessageStreamEvent, Error>,
        using recorder: LLMCallTraceRecorder, call: LLMCall
    ) async throws -> String {
        let work = ProviderReplyWork()
        var ownedCall = call
        ownedCall.replyWork = work
        let held = ownedCall
        return try await work.reply {
            if work.isStopped { throw CancellationError() }
            return try await collect(events(held), using: recorder, work: work, call: held)
        }
    }

    private static func collect(
        _ events: AsyncThrowingStream<LLMMessageStreamEvent, Error>,
        using recorder: LLMCallTraceRecorder,
        work: ProviderReplyWork, call: LLMCall
    ) async throws -> String {
        var text = ""
        var markers: [String] = []
        func output(trimmed: Bool = false) -> String {
            let prose = trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
            return ([prose] + markers).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        do {
            for try await event in events {
                switch event {
                case .textDelta(let delta): text += delta
                case .toolCall(let call):
                    let arguments = String(decoding: call.inputJSON, as: UTF8.self)
                    markers.append("<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(arguments)</tool_use>")
                case .toolBoundary(.outputLimit):
                    // A budget cut cannot authorize calls from this reply.
                    markers.removeAll()
                    throw LLMError.outputLengthLimit(partial: text)
                case .keepAlive, .callInput, .replyTextSettled, .toolBoundary: break
                }
            }
            await work.join()
            if work.isStopped { throw CancellationError() }
            return output(trimmed: true)
        } catch {
            // A decoding failure also joins live work. Never publish a terminal partial while its producer still runs.
            let stoppedByCaller = work.isStopped
            work.stop()
            await work.join()
            let failure: any Error = stoppedByCaller ? CancellationError() : error
            let partial = output()
            // Partial text is evidence beside the failure, never its type. Neither sink throws or checks cancellation: Stop still settles.
            await call.turn?.partialReply?(partial)
            await recorder.recordPartialReply(output: partial, error: failure, call: call)
            throw failure
        }
    }
}
