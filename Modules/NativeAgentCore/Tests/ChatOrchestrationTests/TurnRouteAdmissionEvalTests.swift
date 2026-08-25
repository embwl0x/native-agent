import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger rows closed here:
//   * chat.engine.checkedRouteAdmission        (REPORTS-ONLY → COVERED)
//   * chat.engine.checkedActiveProviderID      (UNCOVERED    → COVERED)
//   * chat.engine.trace.providerAdmissionReused(REPORTS-ONLY → COVERED)
//
// Before this file the ONLY guard on the route-admission branch matrix was
// script/check_architecture_blueprint.swift's source-TEXT presence check for
// the symbol names. The branch that decides which model/effort/provider/
// serviceTier a Telegram/iOS/Workshop turn actually runs on had zero behavior
// tests: a wrong branch silently runs every turn on the chat model and nothing
// reports it (silent-failure class: wrong value).
//
// Hermetic by construction: a fixed-snapshot ProviderRoutingProtocol stub, a
// per-test TurnTraceBus bound through TurnTraceContext.$bus (no writes to the
// live data root), and temp persona roots.

// MARK: - Hermetic router stub

/// Returns ONE fixed `ProviderRoutingSnapshot` and counts how many times the
/// checked read happened — the counter is what proves the admission-reuse fast
/// path actually SKIPPED the preference re-read (a slowdown that is otherwise
/// invisible).
private final class FixedSnapshotRouting: ProviderRoutingProtocol, @unchecked Sendable {
    private let snapshot: ProviderRoutingSnapshot
    // Same convention as the existing StubRouting/ConflictingGenerationRouting
    // in this target: NSLock is unavailable from async contexts, and these
    // stubs are only ever driven from one turn at a time.
    nonisolated(unsafe) private var _checkedCalls = 0

    init(
        preferences: [String: SurfacePreference],
        activeProviders: [String: String] = [:],
        pinnedModels: [String: String] = [:]
    ) {
        self.snapshot = ProviderRoutingSnapshot(
            preferences: preferences,
            activeProviders: activeProviders,
            pinnedModels: pinnedModels
        )
    }

    var checkedCalls: Int { _checkedCalls }

    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] { snapshot.preferences }
    func pinnedModelStringForSurface(_ surface: String) async -> String? {
        ProviderRoutingSurfaceLookup.value(snapshot.pinnedModels, surface)
    }
    func activeProvidersForSurfaces() async -> [String: String] { snapshot.activeProviders }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        _checkedCalls += 1
        return snapshot
    }
    // Deterministic: the real default extension's prefix table must not decide
    // what these assertions see.
    func inferProviderForModel(_ modelId: String) -> String? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "inferred:\(trimmed)"
    }
}

private struct EmptyPersonaStub: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private func makeAdmissionEngine(
    _ router: FixedSnapshotRouting,
    llm: any LLMClient = MockLLMClient(scriptedResponses: ["ok"]),
    tools: any ToolDispatchClient = MockToolDispatchClient(),
    turnTraceBus: TurnTraceBus = .shared
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: EmptyPersonaStub(),
        memory: nil,
        router: router,
        trust: hermeticTrust(),
        llm: llm,
        tools: tools,
        turnTraceBus: turnTraceBus
    )
}

private let admissionPrefs: [String: SurfacePreference] = [
    "chat": SurfacePreference(
        surface: "chat", model: "chat-model", reasoningEffort: "low", serviceTier: "default"
    ),
    "telegram": SurfacePreference(
        surface: "telegram", model: "telegram-model", reasoningEffort: "medium", serviceTier: "priority"
    ),
    // Only the LEGACY spelling is on disk — a 0.3.x install's picker file.
    "missions": SurfacePreference(
        surface: "missions", model: "workshop-model", reasoningEffort: "xhigh", serviceTier: "priority"
    ),
]

// MARK: - chat.engine.checkedRouteAdmission — the 3-way branch matrix

@Test
func admission_activeTransportPresent_ignoresRequestedModelOverride() async throws {
    // (a) active transport present ⇒ configured wins, the request-scoped
    // override is IGNORED. This is the branch that keeps a stale cross-provider
    // model pick from splicing into an admitted transport.
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["telegram": "telegram-provider"]
    )
    let engine = makeAdmissionEngine(router)

    let admitted = try await engine.checkedRouteAdmission(
        for: "telegram", requestedModel: "REQUESTED-OVERRIDE"
    )

    #expect(admitted.modelId == "telegram-model")
    #expect(admitted.modelId != "REQUESTED-OVERRIDE")
    #expect(admitted.providerId == "telegram-provider")
    #expect(admitted.reasoningEffort == "medium")
    #expect(admitted.serviceTier == "priority")
    #expect(admitted.routingSurface == "telegram")
}

@Test
func admission_noActiveTransport_requestedModelWins() async throws {
    // (b) no active transport + non-empty requested ⇒ the request-scoped
    // override is honored (the Mac/test caller contract).
    let router = FixedSnapshotRouting(preferences: admissionPrefs, activeProviders: [:])
    let engine = makeAdmissionEngine(router)

    let admitted = try await engine.checkedRouteAdmission(
        for: "telegram", requestedModel: "  REQUESTED-OVERRIDE  "
    )

    #expect(admitted.modelId == "REQUESTED-OVERRIDE")
    // No active provider for the surface ⇒ the provider is INFERRED from the
    // admitted model, not from the configured one.
    #expect(admitted.providerId == "inferred:REQUESTED-OVERRIDE")
    // Effort/tier still come from the surface preference, not the override.
    #expect(admitted.reasoningEffort == "medium")
    #expect(admitted.serviceTier == "priority")
}

@Test
func admission_noActiveTransportAndNoRequest_usesConfigured() async throws {
    let router = FixedSnapshotRouting(preferences: admissionPrefs, activeProviders: [:])
    let engine = makeAdmissionEngine(router)

    let admitted = try await engine.checkedRouteAdmission(for: "telegram")
    #expect(admitted.modelId == "telegram-model")
    #expect(admitted.providerId == "inferred:telegram-model")
}

@Test
func admission_emptyConfiguredModel_fallsBackToPrimaryModel_neverEmpty() async throws {
    // (c) neither transport nor request, and the configured model is blank
    // (a half-written picker file) ⇒ PRIMARY_MODEL. The silent-failure shape
    // this pins is an EMPTY model id reaching the provider.
    let router = FixedSnapshotRouting(
        preferences: [
            "telegram": SurfacePreference(
                surface: "telegram", model: "   ", reasoningEffort: "medium"
            ),
        ],
        activeProviders: [:]
    )
    let engine = makeAdmissionEngine(router)

    let admitted = try await engine.checkedRouteAdmission(for: "telegram")
    #expect(admitted.modelId == PRIMARY_MODEL)
    #expect(!admitted.modelId.isEmpty)

    // Same blank-configured surface WITH an active transport still lands on
    // PRIMARY_MODEL rather than an empty string.
    let withTransport = FixedSnapshotRouting(
        preferences: [
            "telegram": SurfacePreference(
                surface: "telegram", model: "", reasoningEffort: "medium"
            ),
        ],
        activeProviders: ["telegram": "telegram-provider"]
    )
    let admitted2 = try await makeAdmissionEngine(withTransport)
        .checkedRouteAdmission(for: "telegram")
    #expect(admitted2.modelId == PRIMARY_MODEL)
    #expect(admitted2.providerId == "telegram-provider")
}

@Test
func admission_foldsWorkshopLegacySpelling_bothDirections() async throws {
    // A 0.3.x install's picker file still says `missions`. Both spellings must
    // land on the SAME preference AND report the canonical routing surface —
    // otherwise a Workshop turn silently falls through to the chat model.
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["missions": "workshop-provider"]
    )
    let engine = makeAdmissionEngine(router)

    for spelling in ["workshop", "missions", "  Workshop  ", "MISSIONS"] {
        let admitted = try await engine.checkedRouteAdmission(for: spelling)
        #expect(admitted.routingSurface == "workshop", "surface \(spelling)")
        #expect(admitted.modelId == "workshop-model", "surface \(spelling)")
        #expect(admitted.modelId != "chat-model", "surface \(spelling) fell through to chat")
        #expect(admitted.providerId == "workshop-provider", "surface \(spelling)")
        #expect(admitted.reasoningEffort == "xhigh", "surface \(spelling)")
    }
}

@Test
func admission_unknownSurface_fallsBackToChatPreference_notToDefaults() async throws {
    // An unpinned/unknown surface uses the `chat` preference — pinning the
    // fallback so a rename can't quietly demote a surface to DEFAULT_REASONING_EFFORT.
    let router = FixedSnapshotRouting(preferences: admissionPrefs, activeProviders: [:])
    let engine = makeAdmissionEngine(router)

    let admitted = try await engine.checkedRouteAdmission(for: "a-surface-nobody-pinned")
    #expect(admitted.routingSurface == "a-surface-nobody-pinned")
    #expect(admitted.modelId == "chat-model")
    #expect(admitted.reasoningEffort == "low")
    #expect(admitted.serviceTier == "default")
}

@Test
func admission_noPreferencesAtAll_isPrimaryModelAndDefaultEffort() async throws {
    // Empty snapshot (fresh install / unreadable picker): still a usable route,
    // never an empty model or empty effort.
    let router = FixedSnapshotRouting(preferences: [:], activeProviders: [:])
    let engine = makeAdmissionEngine(router)

    let admitted = try await engine.checkedRouteAdmission(for: "chat")
    #expect(admitted.modelId == PRIMARY_MODEL)
    #expect(admitted.reasoningEffort == DEFAULT_REASONING_EFFORT)
    #expect(admitted.serviceTier == "default")
}

@Test
func admission_requestedReasoningEffortOverridesPreference_blankDoesNot() async throws {
    let router = FixedSnapshotRouting(preferences: admissionPrefs, activeProviders: [:])
    let engine = makeAdmissionEngine(router)

    let overridden = try await engine.checkedRouteAdmission(
        for: "telegram", requestedReasoningEffort: "ultra"
    )
    #expect(overridden.reasoningEffort == "ultra")

    let blank = try await engine.checkedRouteAdmission(
        for: "telegram", requestedReasoningEffort: "   "
    )
    #expect(blank.reasoningEffort == "medium")
}

// MARK: - chat.engine.checkedActiveProviderID — normalization is TOTAL

@Test
func activeProviderID_normalizationIsTotal_acrossCaseWhitespaceAndLegacySpelling() async throws {
    // Silent-failure class: silent zero. nil here is indistinguishable from
    // "no provider configured", and the native-tool-lane gate treats nil as
    // "not native" — quietly demoting kimi-code turns to the text-marker lane.
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["chat": "chat-provider", "workshop": "workshop-provider"]
    )
    let engine = makeAdmissionEngine(router)

    for spelling in ["chat", " Chat ", "CHAT", "\tchat\n"] {
        let id = try await engine.checkedActiveProviderID(for: spelling)
        #expect(id == "chat-provider", "spelling \(spelling.debugDescription) missed")
    }
    // The map is keyed under the CANONICAL spelling; the legacy caller must
    // still resolve (and vice-versa is covered by the admission test above).
    for spelling in ["workshop", "missions", "  MISSIONS "] {
        let id = try await engine.checkedActiveProviderID(for: spelling)
        #expect(id == "workshop-provider", "spelling \(spelling.debugDescription) missed")
    }
}

@Test
func activeProviderID_unknownSurfaceReturnsNil_neverANeighboursProvider() async throws {
    // The `chat` fallback that checkedRouteAdmission applies to PREFERENCES must
    // NOT leak into the active-provider lookup: an unknown surface has no
    // transport, and borrowing chat's would run the turn on the wrong wire.
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["chat": "chat-provider"]
    )
    let engine = makeAdmissionEngine(router)

    let id = try await engine.checkedActiveProviderID(for: "telegram")
    #expect(id == nil)
    let unknown = try await engine.checkedActiveProviderID(for: "not-a-surface")
    #expect(unknown == nil)
}

// MARK: - chat.engine.trace.providerAdmissionReused

/// Collect the `context.summary` trace emitted by buildTurnContext on a
/// per-test bus (shared harness in EvalTraceBusSupport.swift) and return its
/// flags object.
private func contextSummaryFlags(
    _ body: @escaping @Sendable (TurnTraceBus) async throws -> Void
) async throws -> [String: JSONValue] {
    let events = try await withHermeticTraceBus(kinds: ["context.summary"], body)
    guard let event = events.first, case .object(let payload) = event.payload,
          case .object(let flags)? = payload["flags"] else {
        Issue.record("no context.summary trace with a flags object was emitted")
        return [:]
    }
    return flags
}

@Test
func admissionReused_flagTrue_andSnapshotNotReRead_whenLLMCallContextIsBound() async throws {
    // Silent-failure class: slowdown + wrong value, JOINTLY invisible. When the
    // facade's admission is bound, the engine must reuse it; a TaskLocal that
    // stops propagating flips every turn onto the slow re-read path AND can
    // pick a different model, with the flag as the only witness.
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["chat": "chat-provider"]
    )
    let captured = LockedBox<TurnContext?>(nil)

    let flags = try await contextSummaryFlags { bus in
        let engine = makeAdmissionEngine(router, turnTraceBus: bus)
        try await LLMCallContext.$admittedModel.withValue("bound-model") {
            try await LLMCallContext.$reasoningEffort.withValue("bound-effort") {
                try await LLMCallContext.$providerId.withValue("bound-provider") {
                    try await LLMCallContext.$serviceTier.withValue("bound-tier") {
                        let ctx = try await engine.buildTurnContext(
                            surface: "chat", userMessage: "admission reuse"
                        )
                        captured.set(ctx)
                    }
                }
            }
        }
    }

    #expect(flags["provider.admissionReused"] == .bool(true))
    let ctx = try #require(captured.get())
    #expect(ctx.modelId == "bound-model")
    #expect(ctx.reasoningEffort == "bound-effort")
    #expect(ctx.providerId == "bound-provider")
    #expect(ctx.serviceTier == "bound-tier")
    // THE SLOWDOWN ASSERTION: the checked snapshot read was skipped entirely.
    #expect(router.checkedCalls == 0)
}

@Test
func admissionReused_flagFalse_andSnapshotIsRead_whenUnbound() async throws {
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["chat": "chat-provider"]
    )
    let captured = LockedBox<TurnContext?>(nil)

    let flags = try await contextSummaryFlags { bus in
        let engine = makeAdmissionEngine(router, turnTraceBus: bus)
        let ctx = try await engine.buildTurnContext(
            surface: "chat", userMessage: "no admission bound"
        )
        captured.set(ctx)
    }

    #expect(flags["provider.admissionReused"] == .bool(false))
    let ctx = try #require(captured.get())
    #expect(ctx.modelId == "chat-model")
    #expect(ctx.reasoningEffort == "low")
    #expect(ctx.providerId == "chat-provider")
    #expect(router.checkedCalls >= 1)
}

@Test
func admissionReused_partialBinding_doesNotTakeTheFastPath() async throws {
    // Only `admittedModel` bound (no effort): the reuse branch requires BOTH,
    // so this must fall through to the checked re-read rather than pairing a
    // bound model with a stale/blank effort.
    let router = FixedSnapshotRouting(
        preferences: admissionPrefs,
        activeProviders: ["chat": "chat-provider"]
    )
    let flags = try await contextSummaryFlags { bus in
        let engine = makeAdmissionEngine(router, turnTraceBus: bus)
        try await LLMCallContext.$admittedModel.withValue("bound-model-only") {
            _ = try await engine.buildTurnContext(surface: "chat", userMessage: "partial")
        }
    }

    #expect(flags["provider.admissionReused"] == .bool(false))
    #expect(router.checkedCalls >= 1)
}

// MARK: - tiny sendable box

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
