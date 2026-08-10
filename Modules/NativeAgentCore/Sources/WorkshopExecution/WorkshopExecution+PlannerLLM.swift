import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - Swift-native planner LLM

/// Production planner used by `makeWorkshopRunner`. Connector actions are
/// intentionally empty until the connector action
/// registry is wired in Swift. The LLM call goes through the in-app
/// `SwiftNativeLLMClient`: one checked routing snapshot admits the complete
/// executions provider/model/effort/tier tuple, and the task-local admission is
/// passed through `LLMClient.complete(prompt:system:model:surface:)`. Timeout enforcement (60s in
/// the planner caller) lives inside `runCodex` via `withThrowingTaskGroup`.
/// Any LLM throw, any router throw, any timeout is wrapped as
/// `WorkshopExecutionError.plannerFailure(...)` so the outer `planWorkshopExecution` stub
/// fallback path is hit — byte-for-byte parity with the Python broad-except
/// at the retired daemon. The surface is carried through the final client call
/// so active-provider selection and the surface's Think/Fast controls cannot
/// fall back to chat. CancellationError propagates distinctly from WorkshopExecutionError
/// so a cancelled submit() never lands a stub.
/// Process-global tool catalog for the execution planner. WorkshopExecution
/// can't import ChatOrchestration (the tool-catalog source), so the APP
/// configures this ONCE at launch (BackgroundLoopsManager.start) with a
/// provider built from SwiftToolDispatcher's schemas. Every planner that isn't
/// given an explicit provider — notably the trigger scheduler's
/// makeWorkshopRunner — reads it, so AUTONOMOUS triggered executions get the same
/// real tools as manually-submitted ones. Unconfigured (tests) → empty →
/// synthesis-only, preserving prior behaviour. Set-once-at-launch; lock-guarded.
public enum WorkshopPlannerCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: @Sendable () async -> [JSONValue] = { [] }

    public static func configure(_ p: @escaping @Sendable () async -> [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        provider = p
    }

    /// Synchronous lock-guarded read — keeps the NSLock out of the async
    /// `current()` (Swift 6 bans lock/unlock across suspension points).
    private static func snapshot() -> @Sendable () async -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return provider
    }

    public static func current() async -> [JSONValue] {
        await snapshot()()
    }
}

public struct SwiftNativeWorkshopPlannerLLM: WorkshopPlannerLLM {
    public var directProviderCallCountPerInvocation: Int? { 1 }
    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    /// Where the per-run RunLedger row lands (<root>/runs/runs.json). nil
    /// disables ledger writes — the hermetic-test posture, so a mock-LLM
    /// planner test never appends rows to the developer's live ledger.
    private let runLedgerDataRoot: URL?
    /// Tool-menu source for the planner. WorkshopExecution cannot import
    /// ChatOrchestration (its only tool-catalog source), so the real catalog
    /// is injected from the APP layer. Defaults empty for back-compat — with
    /// an empty list the planner can only ever emit chat.synthesize steps,
    /// which is the pre-2026-06-15 behaviour every test relies on.
    private let connectorActionsProvider: @Sendable () async -> [JSONValue]

    /// A secondary data root is a separate runtime body. It may use the
    /// executable-search and locale portions of the parent process environment,
    /// but it must not inherit provider credentials, agent state selectors, or
    /// the caller's home directory. The canonical app root keeps the complete
    /// environment for backwards-compatible production login behavior.
    nonisolated static func codexEnvironment(
        dataRoot: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        defaultDataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [String: String] {
        let codexHome = dataRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .standardizedFileURL
        var environment: [String: String]
        if dataRoot.standardizedFileURL == defaultDataRoot.standardizedFileURL {
            environment = processEnvironment
        } else {
            environment = [:]
            for key in ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM"] {
                if let value = processEnvironment[key], !value.isEmpty {
                    environment[key] = value
                }
            }
            environment["HOME"] = codexHome.path
        }
        environment["CODEX_HOME"] = codexHome.path
        environment["NATIVE_AGENT_DATA_ROOT"] = dataRoot.standardizedFileURL.path
        return environment
    }

    /// Root-confined construction for tests and secondary runtimes. Unlike the
    /// compatibility initializer below, every credential path, provider
    /// registry read, telemetry append, and RunLedger write is derived from the
    /// supplied root. This is the construction used by `makeWorkshopRunner`.
    public init(
        dataRoot: URL,
        connectorActionsProvider: @escaping @Sendable () async -> [JSONValue] = { await WorkshopPlannerCatalog.current() },
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) {
        let rootedRouter = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let providers = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let codexEnvironment = Self.codexEnvironment(dataRoot: dataRoot)
        let rootedLLM = SwiftNativeLLMClient(
            router: rootedRouter,
            codex: CodexAdapter(processEnvironmentOverride: codexEnvironment),
            anthropic: AnthropicAdapter(
                dataRootOverride: dataRoot,
                telemetryDataRootOverride: dataRoot
            ),
            openAI: OpenAIAdapter(
                dataRootOverride: dataRoot,
                telemetryDataRootOverride: dataRoot
            ),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(
                authPathOverride: dataRoot
                    .appendingPathComponent("codex_home", isDirectory: true)
                    .appendingPathComponent("auth.json"),
                telemetryDataRootOverride: dataRoot
            ),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(
                authPathOverride: providers.appendingPathComponent("anthropic_oauth_direct.json"),
                telemetryDataRootOverride: dataRoot
            ),
            xaiOAuthDirect: XAIOAuthDirectAdapter(
                tokenPathOverride: XAIOAuthDirectAdapter.tokenPath(dataRoot: dataRoot),
                telemetryDataRootOverride: dataRoot
            ),
            moonshot: MoonshotAdapter(
                dataRootOverride: dataRoot,
                telemetryDataRootOverride: dataRoot
            ),
            kimiCode: AnthropicAdapter.kimiCode(
                dataRootOverride: dataRoot,
                telemetryDataRootOverride: dataRoot
            ),
            openRouter: OpenRouterAdapter(dataRootOverride: dataRoot),
            lifecycleObserver: lifecycleObserver,
            moonshotCatalogDataRoot: dataRoot
        )
        self.init(
            llm: rootedLLM,
            router: rootedRouter,
            connectorActionsProvider: connectorActionsProvider,
            lifecycleObserver: lifecycleObserver,
            runLedgerDataRoot: dataRoot
        )
    }

    public init(
        llm: (any LLMClient)? = nil,
        router: (any ProviderRoutingProtocol)? = nil,
        // Default reads the process-global catalog (WorkshopPlannerCatalog),
        // which the APP configures once at launch. This is what makes EVERY
        // planner construction — incl. the trigger scheduler's makeWorkshopRunner
        // and any unwired path — tool-aware, not just the call sites that pass
        // an explicit provider. In tests the global is unconfigured → empty →
        // pre-2026-06-15 synthesis-only behaviour preserved (2026-06-15).
        connectorActionsProvider: @escaping @Sendable () async -> [JSONValue] = { await WorkshopPlannerCatalog.current() },
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        // Default ON at the real data root so every production construction
        // records runs without a call-site change. Tests that drive runCodex
        // with a mock LLM pass nil so they never touch the live ledger.
        runLedgerDataRoot: URL? = PersistenceCore.defaultDataRoot()
    ) {
        self.connectorActionsProvider = connectorActionsProvider
        self.runLedgerDataRoot = runLedgerDataRoot
        let resolvedRouter: any ProviderRoutingProtocol = router ?? SwiftNativeProviderRouting()
        self.router = resolvedRouter
        // WAVE 27 (2026-06-01): wire OpenAIOAuthDirectAdapter as the preferred
        // OpenAI handler. In the user's production environment OPENAI_API_KEY is
        // null and credentials live in `data/codex_home/auth.json::tokens`
        // as a ChatGPT OAuth JWT. The OAuth-direct adapter consults the
        // ChatGPT backend endpoint with the JWT bearer; if it's not
        // configured (no tokens), SwiftNativeLLMClient transparently falls
        // back to the api-key OpenAIAdapter.
        // WAVE 28 (2026-06-01): same OAuth-direct wiring for Anthropic — the user's
        // env has no ANTHROPIC_API_KEY; setup_token lives in
        // data/providers/anthropic_oauth_direct.json. Without this, claude-*
        // executions fail .notConfigured.
        self.llm = llm ?? SwiftNativeLLMClient(
            router: resolvedRouter,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            kimiCode: AnthropicAdapter.kimiCode(),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: lifecycleObserver
        )
    }

    /// Narrow test seam for the root-confinement invariant. It exposes no
    /// credential or prompt content.
    public var _testRunLedgerDataRoot: URL? { runLedgerDataRoot }

    public func availableConnectorActions() async -> [JSONValue] {
        await connectorActionsProvider()
    }

    public func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String) {
        // Admit the complete execution tuple from one checked generation. The
        // shared LLM client may reread authority to detect corruption, but the
        // task-local tuple prevents a valid picker change from splicing a new
        // provider/effort/tier into this already-started planner call.
        // P2-3: the routing vocabulary used to be `missions` and this line
        // translated INTO it. It is `workshop` now, so the translation runs the
        // other way and a caller still passing `missions` lands on the same
        // preference instead of falling through to the chat-surface seed.
        let routingSurface = canonicalRoutingSurface(surface)
        let routingSnapshot: ProviderRoutingSnapshot
        do {
            routingSnapshot = try await router.checkedRoutingSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw WorkshopExecutionError.plannerFailure("provider routing unavailable")
        }
        // Read through the vocabulary bridge, not a raw subscript: a router
        // conformer whose snapshot is still keyed `missions` would otherwise
        // miss and fall back to the CHAT model — a silent wrong-model run, not
        // a failure anyone would notice.
        let preference = ProviderRoutingSurfaceLookup.value(routingSnapshot.preferences, routingSurface)
            ?? routingSnapshot.preferences["chat"]
        guard let preference,
              !preference.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkshopExecutionError.plannerFailure("provider routing unavailable")
        }
        let resolvedModel = preference.model
        let resolvedEffort = preference.reasoningEffort
        let resolvedProvider = ProviderRoutingSurfaceLookup
            .value(routingSnapshot.activeProviders, routingSurface)
            ?? router.inferProviderForModel(resolvedModel)
        let resolvedTier = preference.serviceTier
        // Re-check cancellation between router-prefs resolution and the LLM
        // call — both are `await` points and either could have been cancelled
        // without throwing CancellationError directly.
        try Task.checkCancellation()
        let modelForCall = resolvedModel
        let localLLM = llm
        let timeoutNs = UInt64(max(0, timeoutSeconds)) * 1_000_000_000
        // Runs-ledger row per LLM run (Runs UI + iOS runs snapshot): this is
        // the Swift heir of the daemon's run_codex, which was the original
        // writer of <dataRoot>/runs/runs.json. Success and failure both land a
        // row; cancellation records nothing (the turn was torn down).
        let ledgerStarted = Date()
        do {
            let output: String = try await LLMCallContext.$admittedModel.withValue(resolvedModel) {
            try await LLMCallContext.$providerId.withValue(resolvedProvider) {
            try await LLMCallContext.$reasoningEffort.withValue(resolvedEffort) {
            try await LLMCallContext.$serviceTier.withValue(resolvedTier) {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // Python's _plan_mission does NOT pass a system prompt; the
                    // planner instructions are embedded in `prompt`.
                    if let rootedTraceDataRoot = runLedgerDataRoot {
                        return try await LLMCallContext.$traceDataRootOverride.withValue(
                            rootedTraceDataRoot
                        ) {
                            try await localLLM.complete(
                                prompt: prompt,
                                system: nil,
                                model: modelForCall,
                                surface: routingSurface
                            )
                        }
                    }
                    return try await localLLM.complete(
                        prompt: prompt,
                        system: nil,
                        model: modelForCall,
                        surface: routingSurface
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw WorkshopExecutionError.plannerFailure("timeout after \(timeoutSeconds)s")
                }
                guard let first = try await group.next() else {
                    throw WorkshopExecutionError.plannerFailure("empty result")
                }
                group.cancelAll()
                return first
            }
            }
            }
            }
            }
            if let ledgerRoot = runLedgerDataRoot {
                await RunLedger.append(
                    kind: "mission",
                    status: "succeeded",
                    model: resolvedModel,
                    prompt: prompt,
                    output: output,
                    createdAt: ledgerStarted,
                    durationSeconds: Date().timeIntervalSince(ledgerStarted),
                    dataRoot: ledgerRoot
                )
            }
            return (model: resolvedModel, output: output)
        } catch let e as WorkshopExecutionError {
            if let ledgerRoot = runLedgerDataRoot {
                await RunLedger.append(
                    kind: "mission",
                    status: "failed",
                    model: resolvedModel,
                    prompt: prompt,
                    error: String(describing: e),
                    createdAt: ledgerStarted,
                    durationSeconds: Date().timeIntervalSince(ledgerStarted),
                    dataRoot: ledgerRoot
                )
            }
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Cancellation propagates via typed `CancellationError` (from
            // cooperative `Task.checkCancellation` / `Task.sleep`) or
            // `NSURLErrorDomain` + `NSURLErrorCancelled` (from URLSession
            // cancellation). All other errors map to `WorkshopExecutionError.plannerFailure`.
            // BLOCKING #4 (wave-24-amendment): if the outer task was cancelled
            // but the underlying throw is some other error type, honor the
            // cancellation before wrapping as plannerFailure.
            try Task.checkCancellation()
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            if let ledgerRoot = runLedgerDataRoot {
                await RunLedger.append(
                    kind: "mission",
                    status: "failed",
                    model: resolvedModel,
                    prompt: prompt,
                    error: String(describing: error),
                    createdAt: ledgerStarted,
                    durationSeconds: Date().timeIntervalSince(ledgerStarted),
                    dataRoot: ledgerRoot
                )
            }
            throw WorkshopExecutionError.plannerFailure(String(describing: error))
        }
    }
}

// MARK: - Factory

public func makeWorkshopRunner(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
) -> any WorkshopRunnerClient {
    return SwiftNativeWorkshopRunner(
        root: dataRoot,
        planner: SwiftNativeWorkshopPlannerLLM(
            dataRoot: dataRoot,
            lifecycleObserver: lifecycleObserver
        )
    )
}
