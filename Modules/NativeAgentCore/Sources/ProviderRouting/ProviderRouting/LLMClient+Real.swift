import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import SenseCore
// Blueprint: | `LLMClient+Real.swift` | ProviderRegistry profiles and root-bound transport dispatch |

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
        let registry = ProviderRegistry(dataRoot: dataRoot, credentials: credentialRoot, telemetry: telemetryRoot,
            processEnvironment: processEnvironmentOverride)
        llm = SwiftNativeLLMClient(
            router: router, registry: registry,
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

public struct ProviderRegistry: Sendable {
    fileprivate let transports: [String: any LLMTransport]

    struct Roots: Sendable {
        let data: URL
        let credentials: URL?
        let telemetry: URL?
        let processEnvironment: [String: String]?
    }

    struct ProviderProfile: Sendable {
        let id: String
        let capabilities: any ProviderTransportCapabilities.Type
        let make: @Sendable (Roots) -> any LLMTransport

        init(_ id: String, _ capabilities: any ProviderTransportCapabilities.Type,
             make: @escaping @Sendable (Roots) -> any LLMTransport) {
            self.id = id
            self.capabilities = capabilities
            self.make = make
        }
    }

    static let profiles = [
        ProviderProfile("codex", CodexProcess.self) { root in
            CodexProcess(processEnvironmentOverride: root.processEnvironment, dataRootOverride: root.credentials ?? root.data)
        },
        ProviderProfile("openai", OpenAITransport.self) {
            OpenAITransport(dataRootOverride: $0.credentials, telemetryDataRootOverride: $0.telemetry)
        },
        ProviderProfile("openai_oauth_direct", ChatGPTTransport.self) {
            ChatGPTTransport(dataRootOverride: $0.credentials ?? $0.data, telemetryDataRootOverride: $0.telemetry).transport
        },
        ProviderProfile("anthropic", AnthropicTransport.self) {
            AnthropicTransport(dataRootOverride: $0.credentials, telemetryDataRootOverride: $0.telemetry).transport
        },
        ProviderProfile("anthropic_oauth_direct", AnthropicOAuthTransport.self) {
            AnthropicOAuthTransport(authPathOverride: $0.credentials?.appendingPathComponent("providers/anthropic_oauth_direct.json"),
                telemetryDataRootOverride: $0.telemetry).transport
        },
        ProviderProfile("xai_oauth_direct", XAIOAuthTransport.self) {
            XAIOAuthTransport(tokenPathOverride: $0.credentials.map { XAIOAuthTransport.tokenPath(dataRoot: $0) },
                telemetryDataRootOverride: $0.telemetry).transport
        },
        ProviderProfile("moonshot", MoonshotTransport.self) {
            MoonshotTransport(dataRootOverride: $0.credentials, telemetryDataRootOverride: $0.telemetry).transport
        },
        ProviderProfile("kimi-code", AnthropicTransport.self) {
            AnthropicTransport.kimiCode(dataRootOverride: $0.credentials, telemetryDataRootOverride: $0.telemetry).transport
        },
        ProviderProfile("meta", AnthropicTransport.self) {
            AnthropicTransport(endpoint: URL(string: "https://api.meta.ai/v1/messages"), dataRootOverride: $0.credentials,
                telemetryDataRootOverride: $0.telemetry, providerId: "meta", credentialConfigFile: "meta.json",
                firstPartyAnthropicToolContract: false).transport
        },
        ProviderProfile("openrouter", OpenRouterTransport.self) { OpenRouterTransport(dataRootOverride: $0.credentials).transport },
    ]

    public init(dataRoot: URL, credentials: URL?, telemetry: URL?, processEnvironment: [String: String]?) {
        let roots = Roots(data: dataRoot, credentials: credentials, telemetry: telemetry, processEnvironment: processEnvironment)
        transports = Dictionary(uniqueKeysWithValues: Self.profiles.map { ($0.id, $0.make(roots)) })
    }
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
    var providerId: String { get }
    /// Receipts for whole-reply collection; every adapter that collects its own stream names the recorder it writes to.
    var telemetry: LLMCallTraceRecorder { get }
    /// Exact wire output cap; zero explicitly declares no output-cap field. A transport that writes a cap takes it, while a run's budget is bound,
    /// from `FirstPartyExecutionControls.budgetedOutputTokens`: min(remaining budget, effective ceiling).
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

    /// Collect a whole reply from the adapter's stream.
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: call)
    }

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        call: LLMCall
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: messages, system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }
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
}

// MARK: - SwiftNativeLLMClient

/// Use one checked routing snapshot. Explicit route and admitted model outrank saved choices; missing adapters or incompatible models require repair,
/// never substitution.
public final class SwiftNativeLLMClient: LLMClient {
    private let router: SwiftNativeProviderRouting
    private let registry: ProviderRegistry
    private let diagnosticDataRoot: URL?
    private let lifecycleObserver: (any LLMCallLifecycleObserving)?
    /// Catalogs must use this body's exact root so a secondary runtime cannot consult the live user's cache.
    private let moonshotCatalogDataRoot: URL

    public init(
        router: SwiftNativeProviderRouting,
        registry: ProviderRegistry,
        diagnosticDataRoot: URL? = nil,
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        moonshotCatalogDataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.router = router
        self.registry = registry
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
        receipt: LLMCallTraceRecorder.Tally<LLMCallTraceRecorder.Receipt>? = nil,
        streamKind: LLMMessagesStreamKind? = nil,
        error: Error? = nil, call: LLMCall
    ) async {
        guard !call.preview else { return }
        var noReply = false
        if case .noReply? = error.flatMap(ProviderFailure.classify) { noReply = true }
        guard let terminal = started.terminal(
            phase, firstOutputMs: receipt?.withLock { $0.ttftMs }, streamKind: streamKind?.rawValue, noReply: noReply,
            requestBytes: receipt?.withLock { $0.requestBytes }) else { return }
        await lifecycleObserver?.observeProviderCall(terminal)
        if phase == .succeeded {
            RepairOwed.settle(moonshotCatalogDataRoot, operation: "model.call:" + started.providerId + ":" + started.model,
                             evidence: .init(source: "provider", id: started.id))
        }
    }

    private func recordAnswer(
        _ sent: SentCredential?,
        of started: LLMCallLifecycleEvent,
        failure: Error?,
        answeredAt: Date,
        call: LLMCall
    ) async {
        guard !call.preview, let credential = sent?.fingerprint else { return }
        let answer: LLMProviderStatusFeed.Answer
        if let failure {
            guard ProviderFailure.classify(failure) == .authExpired else { return }
            answer = .rejected(ProviderFailure.diagnosticDescription(failure))
        } else { answer = .answered }
        await LLMProviderStatusFeed.recordAnswer(
            answer, providerID: started.providerId, model: started.model,
            credential: credential, dataRoot: router.dataRoot, answeredAt: answeredAt
        )
    }

    /// Written under the request's identity: no row when the adapter's came first.
    private func recordFailedCall(_ started: LLMCallLifecycleEvent, error: Error,
                                  startedAt: TimeInterval, recorded: LLMCallTraceRecorder.Tally<LLMCallTraceRecorder.Receipt>, call: LLMCall) async -> Error {
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
        let requestedProvider = admission.providerId
        guard let activeProvider = requestedProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ProviderToolCapability.transport(providerID: activeProvider) != nil else {
            throw LLMError.notConfigured(provider: requestedProvider.flatMap { $0.isEmpty ? nil : $0 } ?? "router")
        }
        // What the person chose is what is sent: the pick itself when the provider listed that spelling, else its listed spelling of the same model.
        let model = FirstPartyModelCatalog.listedSpelling(admission.modelId, providerID: activeProvider, dataRoot: moonshotCatalogDataRoot)
            ?? admission.modelId
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
        guard let chosen = registry.transports[resolution.providerId] else {
            throw LLMError.notConfigured(provider: resolution.providerId)
        }
        // A marker transport (the Claude subscription) is never handed a tools array; reaching here with one is this body's own disagreement, said as such.
        if tools != nil, ProviderToolCapability.wire(providerID: resolution.providerId) == .textMarkers {
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

    private struct StreamStopTarget: Sendable {
        var task: Task<Void, Never>?
        var cancellable = false
        var stopped = false
        var finished = false
    }

    public func streamMessages(
        messages: [LLMMessage], system: String?, model: String?, tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let stopTarget = LLMCallTraceRecorder.Tally(StreamStopTarget())
            let allowStopCancel: @Sendable () -> Void = {
                stopTarget.withLock { state -> Task<Void, Never>? in
                    state.cancellable = true
                    return state.stopped ? state.task : nil
                }?.cancel()
            }
            let task = Task {
                defer {
                    stopTarget.withLock {
                        $0.finished = true
                        $0.task = nil
                    }
                }
                var lifecycle: LLMCallLifecycleEvent?
                var streamKind: LLMMessagesStreamKind?
                // A caller that brings its own sent-credential evidence (the connection check) records that verdict itself.
                let sent = call.sentCredential == nil ? SentCredential() : nil
                let attemptStartedAt = ProcessInfo.processInfo.systemUptime
                let requestBytes = LLMMessage.inputBytes(messages, system: system, tools: tools ?? [])
                let recorded = LLMCallTraceRecorder.Tally(LLMCallTraceRecorder.Receipt())
                recorded.withLock { $0.requestBytes = requestBytes }
                // What the provider's prefix cache sees, without the words: the scope and the request's first 2k and 8k bytes, hashed.
                let front = Data(((system ?? "") + messages.flatMap(\.content).compactMap { block -> String? in
                    if case .text(let text) = block { return text }; return nil
                }.joined()).utf8)
                let prefixFingerprint = [front.prefix(2_000), front.prefix(8_000)]
                    .map(LLMCallTraceRecorder.fingerprint).joined(separator: ":")
                recorded.withLock {
                    $0.cacheScopeFingerprint = LLMCallTraceRecorder.fingerprint(Data((call.session ?? "").utf8))
                    $0.requestPrefixFingerprint = prefixFingerprint
                }
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
                    if let sent { routedCall.sentCredential = sent }
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
                                // Any event from a turn that runs under a call (a helper, a part's thought), a keep-alive included, is life of that call.
                                held.turn?.enclosingCall?.moved()
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
                    let answeredAt = Date()
                    await self.providerLifecycleFinish(started, phase: .succeeded, receipt: recorded,
                        streamKind: streamKind, call: held)
                    allowStopCancel()
                    await self.recordAnswer(sent, of: started, failure: nil, answeredAt: answeredAt, call: held)
                    continuation.finish()
                } catch is CancellationError {
                    if let lifecycle { await self.providerLifecycleFinish(lifecycle, phase: .cancelled, call: call) }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let lifecycle {
                        let answeredAt = Date()
                        await self.providerLifecycleFinish(lifecycle, phase: .failed, receipt: recorded,
                            streamKind: streamKind, error: error, call: call)
                        let owned = await self.recordFailedCall(lifecycle, error: error,
                            startedAt: attemptStartedAt, recorded: recorded, call: call)
                        allowStopCancel()
                        await self.recordAnswer(sent, of: lifecycle, failure: error, answeredAt: answeredAt, call: call)
                        continuation.finish(throwing: owned)
                        return
                    }
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
            }
            stopTarget.withLock { state -> Task<Void, Never>? in
                guard !state.finished else { return nil }
                state.task = task
                return state.cancellable && state.stopped ? task : nil
            }?.cancel()
            call.replyWork?.own(task, stop: {
                stopTarget.withLock { state -> Task<Void, Never>? in
                    state.stopped = true
                    return state.cancellable ? state.task : nil
                }?.cancel()
            })
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
            await recorder.recordPartialReply(output: output(), error: failure, call: call)
            throw failure
        }
    }
}
