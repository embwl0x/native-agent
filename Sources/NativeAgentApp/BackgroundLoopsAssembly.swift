import Foundation
import Darwin
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import DoctorChecks
import MemoryV2
import PersonaEngine
import PersistenceCore
import ProviderRouting
import DreamREMCycle
import TelegramBot
import ApprovalInbox
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement

// MARK: - Mission planner tool catalog injection
//
// The Missions module cannot import ChatOrchestration (it would create a
// dependency cycle / pull the whole tool stack into the planner), so the real
// tool catalog that makes the planner TOOL-AWARE is injected from the app
// layer here. Without this the planner's availableConnectorActions() returns
// `[]` and missions can ONLY ever emit chat.synthesize steps — they can
// describe work but never DO it (root cause fixed 2026-06-15).
//
// Each entry is `{id, description}` exactly as planMission reads it
// (WorkshopExecution.swift ~L900). Source is SwiftToolDispatcher's own tool schemas —
// the same catalog the chat tool loop sees. Capped to 40 to bound prompt size
// (the planner itself prefixes 30 before rendering the menu).
func makeWorkshopPlannerConnectorActionsProvider(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> @Sendable () async -> [JSONValue] {
    // The dispatcher owns a policy-keyed schema cache and root-exact MemoryV2
    // / knowledge-graph bindings. Rebuilding that graph for every plan threw
    // away the cache and repeated all of the binding work. One captured
    // dispatcher is safe here: schema enumeration still rechecks the current
    // Full Mac access flags and dispatch authority remains effect-time owned.
    //
    // A5.3 (W5#P1-4): building the dispatcher forces the MemoryV2 GRDB sqlite
    // open+migrate+prune (via SwiftNativeMemoryV2.shared). This factory is
    // called SYNCHRONOUSLY from applicationDidFinishLaunching, so constructing
    // eagerly here paid that sqlite cost on the MAIN THREAD at launch. Defer it
    // to a LazyDispatcherHolder: the first (background, async) invocation of the
    // provider builds and caches the one dispatcher off-main, keeping launch's
    // main thread clear. Schema-cache reuse is preserved — the holder returns
    // the same dispatcher on every later call.
    let holder = LazyDispatcherHolder(dataRoot: dataRoot)
    return {
        let dispatcher = await holder.dispatcher()
        let schemas = (try? await dispatcher.listAvailableToolSchemas()) ?? []
        return schemas.prefix(200).map { schema in
            JSONValue.object([
                "id": .string(schema.name),
                "description": .string(workshopPlannerToolDescription(schema)),
            ])
        }
    }
}

/// Lazily builds + caches one `SwiftToolDispatcher` on first use. Isolating the
/// build behind an actor moves the MemoryV2 sqlite open+migrate off the main
/// thread (A5.3): the provider factory can be called at launch on the main
/// actor, but the actual construction runs the first time the (async) provider
/// closure is invoked from a background loop/trigger.
private actor LazyDispatcherHolder {
    private let dataRoot: URL
    private var cached: SwiftToolDispatcher?

    init(dataRoot: URL) { self.dataRoot = dataRoot }

    func dispatcher() -> SwiftToolDispatcher {
        if let cached { return cached }
        let built = SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot()
        )
        cached = built
        return built
    }
}

/// Append the tool's arg names to its description so the mission planner fills
/// the RIGHT args (e.g. shell needs `cmd` — without this the planner emitted a
/// shell step with no cmd → "missing_cmd" failure; 2026-06-15). `*` marks
/// required args.
func workshopPlannerToolDescription(_ schema: LLMToolSchema) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any],
          let props = obj["properties"] as? [String: Any], !props.isEmpty else {
        return schema.description
    }
    let required = Set((obj["required"] as? [String]) ?? [])
    let args = props.keys.sorted().map { required.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
    return "\(schema.description) [args: \(args)]"
}

private struct PersonaBackedBackgroundLLMClient: LLMClient {
    let inner: any LLMClient
    let dataRoot: URL
    let cognitionRuntime: NativeCognitionRuntime

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: "background"),
            model: model
        )
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        surface: String
    ) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: surface),
            model: model,
            surface: surface
        )
    }

    func complete(
        prompt: String,
        system: String?,
        model: String?,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await inner.complete(
            prompt: prompt,
            system: try await personaSystem(existing: system, surface: "background"),
            model: model,
            tools: tools
        )
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await inner.completeMessages(
            messages: messages,
            system: try await personaSystem(existing: system, surface: surface),
            model: model,
            surface: surface,
            tools: tools
        )
    }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let resolvedSystem = try await personaSystem(existing: system, surface: surface)
                    for try await event in inner.streamMessages(
                        messages: messages,
                        system: resolvedSystem,
                        model: model,
                        surface: surface,
                        tools: tools
                    ) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func personaSystem(existing: String?, surface: String) async throws -> String {
        let trimmedExisting = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.containsPersonaContext(trimmedExisting) {
            return trimmedExisting
        }

        let persona = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? SwiftNativePersonaEngine(dataRoot: dataRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
        let packet = try await PersonaCompiler(engine: persona).compile(surface: surface)
        let compiled = packet.compiledSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compiled.isEmpty else {
            throw BackgroundPersonaContextError.emptyCompiledPrompt(surface: surface)
        }
        let organismPosture = await cognitionRuntime.organismBehaviorPosture()?
            .privateRuntimeContext(
                runId: "background",
                sessionId: "background",
                surface: surface,
                fileAccess: "background"
            )
        let boundary = """
        # Background Personality Context
        You are \(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) doing app-owned NativeAgent background work for the user. Keep the same identity, voice, care, and boundaries as normal chat. Preserve each background loop's specific instructions below; do not dispatch actions or mutate identity unless that loop explicitly stages a reviewable proposal.
        """
        var sections = [compiled, boundary]
        if let organismPosture, !organismPosture.isEmpty {
            sections.append(organismPosture)
        }
        if !trimmedExisting.isEmpty {
            sections.append(trimmedExisting)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func containsPersonaContext(_ system: String) -> Bool {
        system.contains("# SOUL") || system.contains("# Background Personality Context")
    }
}

/// Secondary/test roots have no authority to borrow the process-global
/// provider credentials, Codex home, or telemetry owners. They may assemble
/// loops for deterministic inspection, but any unexpected model spend fails
/// loudly at the provider boundary.
struct AlternateRootUnavailableBackgroundLLMClient: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw NSError(
            domain: "BackgroundLoopsAssembly",
            code: 503,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "background providers are unavailable for an alternate data root",
            ]
        )
    }
}

private enum BackgroundPersonaContextError: Error, Sendable, CustomStringConvertible {
    case emptyCompiledPrompt(surface: String)

    var description: String {
        switch self {
        case .emptyCompiledPrompt(let surface):
            return "emptyCompiledPrompt(surface: \(surface))"
        }
    }
}

// MARK: - BackgroundLoopsAssembly
//
// App-side wiring for BackgroundLoops. The loops live in the
// BackgroundLoops module, but each constructor needs concrete
// dependencies the loop module deliberately doesn't import (the real
// SwiftNativeLLMClient with its 3 provider adapters, the JSONL-backed
// memory recaller, etc.). That composition happens here so the app-owned
// manager registers real work through the canonical Core owner.
//
// Core periodic loops:
//   - rem_cycle              (REMCycleLoop, weekly) → REMConsolidator over
//                              DreamDiaryReader + REMTombstoneStore +
//                              GrowthDocManager on persona/
//   - memory_consolidation   (MemoryConsolidationHygieneRunner, weekly) →
//                              the REAL MemoryV2 MemoryConsolidator over
//                              memory.sqlite (U3 wave-1 item 6 retired the
//                              dead memory_embeddings.jsonl adapter wiring)
// No periodic dream wrapper is registered in production;
// TriggerScheduler owns unattended dreams.
//
// BackgroundLoopsManager owns execution in the Swift-only runtime. The wiring
// helpers below are safe to call eagerly because disk-touching work happens
// inside each tick.

enum BackgroundLoopsAssembly {

    /// Shared LLM client used by background REM/self-improvement/reflection
    /// lanes. SwiftNativeLLMClient routes by model-id prefix to the three
    /// real backend adapters (Anthropic / OpenAI / Codex CLI). Default
    /// model resolution falls back to the router's "chat" surface preference.
    /// Resolve the one cognition owner for a loop body. Alternate roots must
    /// never observe or mutate the process-global personal runtime.
    static func cognitionRuntime(
        for dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> NativeCognitionRuntime {
        let standardized = dataRoot.standardizedFileURL
        return standardized == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? .shared
            : NativeCognitionRuntime(dataRoot: standardized)
    }

    static func makeSharedLLMClient(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> any LLMClient {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        guard dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return PersonaBackedBackgroundLLMClient(
                inner: AlternateRootUnavailableBackgroundLLMClient(),
                dataRoot: dataRoot,
                cognitionRuntime: runtime
            )
        }
        let router = SwiftNativeProviderRouting()
        let inner = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            kimiCode: AnthropicAdapter.kimiCode(),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: runtime
        )
        return PersonaBackedBackgroundLLMClient(
            inner: inner,
            dataRoot: dataRoot,
            cognitionRuntime: runtime
        )
    }
    /// Full loop manifest for BackgroundLoopsManager: doctor,
    /// memory, self-improvement, REM, Workshop execution executor, heartbeat, and hooks.
    /// A periodic dream wrapper is intentionally absent from this manifest:
    /// unattended dreams have exactly one owner, the `nativeagent-nightly-dream`
    /// TriggerScheduler job at 03:30 America/Chicago.
    static func assembleAllLoops(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [any LoopRunner] {
        let cognition = cognitionRuntime(for: dataRoot)
        let llm = makeSharedLLMClient(dataRoot: dataRoot, cognitionRuntime: cognition)
        var loops: [any LoopRunner] = [
            makeAutoDoctorLoop(dataRoot: dataRoot),
            makeFullMacExpiryLoop(dataRoot: dataRoot),
            makeTurnTraceRetentionLoop(dataRoot: dataRoot),
            // Tightness round 2 P-M2: weekly prune of terminal evolution proposals
            // (proposals.json had no retention driver). Idempotent.
            makeEvolutionProposalRetentionLoop(dataRoot: dataRoot),
            // Tightness round 2 item 6: daily disk-hygiene watchdog — detects
            // oversized files / an over-budget data/ tree and files ONE inbox
            // card. Detect-never-delete.
            makeDataRootDiskHygieneLoop(dataRoot: dataRoot),
            // NOT registered: the A5.5 stale-artifact sweep. Its `isEnabled` gate
            // reads `staleArtifactSweepEnabled`, a UserDefaults key with no
            // @AppStorage, no Toggle and no `set(forKey:)` anywhere in the repo
            // (verified 2026-08-02) — so the delete leg could never fire, and the
            // registration bought a daily walk of data/ plus an append to
            // logs/maintenance_sweep.jsonl that nothing reads. `StaleArtifactSweep`
            // + `StaleArtifactSweepLoop` and their tests remain; re-register here
            // the day the sweep has a real toggle behind it.
            makeMemoryConsolidationLoop(dataRoot: dataRoot),
            makeWeeklySelfImprovementLoop(dataRoot: dataRoot, llm: llm),
            makeREMCycleLoop(dataRoot: dataRoot, llm: llm, cognitionRuntime: cognition),
            // User-authored scheduler jobs and time/idle triggers use exact
            // persisted deadlines plus config/activity invalidations. Core owns
            // the only lifecycle; the six-hour cadence is missed-event repair.
            makeTriggerSchedulerLoop(dataRoot: dataRoot),
            makeWorkshopExecutorLoopRunner(dataRoot: dataRoot, cognitionRuntime: cognition),
            // Wave B (desk-workshop Phase 1): the Workshop pump. Zero-LLM heart —
            // a quiet day makes no provider call; organism-gated (runs only in a
            // `normal` posture), reserves a Desk slot BEFORE any session, and
            // runs one bounded work session behind the WorkshopToolProfile
            // membrane. Distinct from the mission executor above (Phase 2 re-homes
            // that engine); this is the new self-pursuit work lane.
            makeWorkshopPumpLoop(dataRoot: dataRoot, cognitionRuntime: cognition),
            makeCognitionMaintenanceLoop(runtime: cognition),
            makeCognitionReplayLoop(runtime: cognition),
            makeCognitionReflectionLoop(llm: llm, runtime: cognition),
            // Cue authoring stays available as an explicit/manual seam, but is
            // absent from production scheduling until it has a live consumer.
            // This avoids both unattended model spend and a dead 10-minute wake.
            // U2b wave 3 lane A: interval health heartbeat + self-healing hook.
            makeHeartbeatLoop(dataRoot: dataRoot, llm: llm),
            makeSelfHealingHook(dataRoot: dataRoot, llm: llm),
            // U4 Wave C: autonomy-promotion PROPOSAL loop (cards only; applies
            // human-approved promotions via a re-verifying reconcile).
            makeAutonomyPromotionLoop(dataRoot: dataRoot),
            // NOT registered: the MEASURE v2 golden-eval loop, for the same
            // reason as the sweep above — `goldenEvalEnabled` has no writer
            // anywhere in the repo, so the loop woke weekly forever and could
            // never submit a job. `GoldenEvalLoop`/`GoldenEvalJobs` and the
            // scoreboard's `golden_eval` trigger-source cohort remain intact;
            // re-register here once the cohort has a toggle.
            // Desk notify (2026-06-29): desk-side push when a direct/urgent
            // tracked item changes. A SEPARATE loop from the cognition manifest
            // above — it reads desk state and pings User, never touching the
            // CognitiveSubstrate. Self-gating (no-op unless an item is marked).
            makeDeskNotifyLoop(dataRoot: dataRoot),
            // Configured GitHub projects flow into durable Desk refs/items.
            // The runner is due-driven and change-idempotent; no config or no
            // material remote change means no state write and no notification.
            makeGitHubTrackingLoop(dataRoot: dataRoot),
        ]
        if let tele = makeTelegramPollLoopIfConfigured(dataRoot: dataRoot) {
            loops.append(tele)
        }
        if let slack = makeSlackSocketModeLoopIfConfigured(dataRoot: dataRoot) {
            loops.append(slack)
        }
        return loops
    }
}

// U3 wave-1 item 6 (2026-06-10): JSONLMemoryConsolidationRecaller — the
// adapter that read/deleted against <dataRoot>/memory_embeddings.jsonl —
// was deleted here. The file it read no longer exists post-Swift-native-cutover
// (live store = memory/memory.sqlite); the memory_consolidation slot now
// runs MemoryConsolidationHygieneRunner (the real MemoryV2 consolidator).
