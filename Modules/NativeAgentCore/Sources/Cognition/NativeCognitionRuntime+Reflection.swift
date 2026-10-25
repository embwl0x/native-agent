// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import BackgroundLoops
import CognitiveSubstrate
import Context
import DreamREMCycle
import NativeAgentCore
import PersonaEngine
import MemoryV2
import PersistenceCore
import Desk
import ProviderRouting

// Blueprint: | `NativeCognitionRuntime+Reflection.swift` | `NativeCognitionRuntime` reflection: dream/REM-triggered single-flight reflection, budget admission, result settlement and pursuit proposals |

private enum CognitiveReflectionPersonaError: Error, Sendable, CustomStringConvertible {
    case compileFailed(String)
    case emptyCompiledPrompt(surface: String)

    var description: String {
        switch self {
        case .compileFailed(let detail):
            return "compileFailed(\(detail))"
        case .emptyCompiledPrompt(let surface):
            return "emptyCompiledPrompt(surface: \(surface))"
        }
    }
}

extension NativeCognitionRuntime {
    /// A4.6 (clause 4): reflection is tissue downstream of the canonical
    /// dream/REM commit, exactly like replay — not a 6h poll pretending to
    /// notice it. Called from the somatic handler AFTER the replay await, so
    /// reflection sees post-replay substrate state. Each caller retains its
    /// committed material while awaiting the existing single-flight owner.
    /// Budget/enabled/reservation gating stays inside `runReflectionIfDue`;
    /// this path adds no new unattended-LLM authority. Gated to the live app
    /// body so alternate-root runtimes never fire provider work.
    func scheduleEventDrivenReflection(reason: String, material: [String: CognitiveReflectionCause]) async {
        while let task = reflectionEventTask {
            await task.value
            guard !Task.isCancelled else { return }
        }
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        guard usesLiveAppBody else { return }
        reflectionEventTask = Task { [weak self] in
            await self?.runEventDrivenReflection(reason: reason, material: material)
        }
    }

    private func runEventDrivenReflection(reason: String, material: [String: CognitiveReflectionCause]) async {
        defer { reflectionEventTask = nil }
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        let outcome = await runReflectionIfDue(
            llm: host.backgroundLLMClient(dataRoot: dataRoot, cognition: self),
            reason: reason,
            material: material,
            demand: .spontaneous
        )
        await reportLoopOutcome(loopId: "cognition_reflection", outcome: outcome)
    }

    /// `demand` decides what the call has to earn. `.spontaneous` (the loops and
    /// the commit signal) must clear unresolved load; `.requested` — an explicit
    /// call — only has to fit under the rolling cost ceiling.
    @discardableResult
    public func runReflectionIfDue(
        llm: any LLMClient,
        reason: String,
        material: [String: CognitiveReflectionCause]? = nil,
        demand: CognitiveReflectionDemand = .requested,
        sameSourceCooldown: TimeInterval? = nil
    ) async -> CognitiveBackgroundRunOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(bootstrapFailure) }
        if let providerRoutingFailure { return .failed(providerRoutingFailure) }
        let request: CognitiveReflectionRequest
        // Take the lease BEFORE planning: planning sets the in-flight
        // reservation, and a lease refusal after it would strand that
        // reservation and refuse every reflection until it expires.
        let lease = host.backgroundWorkLease(dataRoot: dataRoot)
        let window = host.backgroundWorkWindow(Date())
        guard await lease.tryAcquire(holder: "reflection", window: window) else {
            return .skipped("background work lease held")
        }
        switch await substrate.planReflectionChecked(
            reason: reason,
            demand: demand,
            material: material,
            sameSourceCooldown: sameSourceCooldown
        ) {
        case .admitted(let planned):
            request = planned
        case .refused(let admission):
            // Honest skip: which fence stopped it, and the load reading behind it.
            _ = await lease.releaseUnused(holder: "reflection", window: window)
            return .skipped(admission.reason == CognitiveSubstrate.reflectionRefusalDisabled
                ? LoopTickOutcome.offPrefix + "reflection disabled" : admission.detail)
        }
        let reflectionOutcome = await executeReflection(request: request, llm: llm)
        if case .skipped(let why) = reflectionOutcome, why != "reflection cancelled" {
            // Routing refused before any provider work; return the unused slot.
            // A cancellation came after the provider call began: the slot is spent.
            _ = await lease.releaseUnused(holder: "reflection", window: window)
        }
        publishRuntimeChange(reason: "reflection:finished")
        guard case .completed = reflectionOutcome else { return reflectionOutcome }
        // C2b — volition ignition: after the reflection's normal work, Agent MAY
        // propose ONE new self-pursuit, but ONLY from resolved, un-launderable
        // evidence (a User-approved ACTIVE standing view). No new unattended-LLM
        // path: the proposer does ZERO provider calls, and it rides the SAME
        // backgroundCognitionAllowed gate this method already passed.
        await proposePursuitFromReflectionIfEligible(reason: reason)
        return reflectionOutcome
    }

    /// C2b — the AUTONOMOUS PURSUIT PROPOSAL path (M7 anti-laundering). After a
    /// scheduled reflection, propose at most ONE self-pursuit from an active
    /// standing view. Fail-closed everywhere: an unresolvable / non-active cited
    /// view, an over-cap desk, a duplicate, a store refusal, or a failed desk read
    /// all yield NO pursuit. Gated by the SAME workshop autonomy gate the pump
    /// respects (enableAutonomy) — a proposal is workshop-class autonomous work.
    private func proposePursuitFromReflectionIfEligible(reason: String) async {
        guard await host.unattendedWorkAllowed(dataRoot: dataRoot) else { return }

        // Candidates AND resolver both read the REAL substrate: a view is `.active`
        // ONLY after User's resolveStandingView(approved:true), so an active view is
        // evidence Agent cannot mint in this turn (un-launderable). The resolver
        // spans ALL views (proposed/active/retired) so a non-active id is refused.
        let snapshot = await substrate.standingViewSnapshot()
        guard !snapshot.isEmpty else { return }
        let statusById = Dictionary(
            snapshot.map { ($0.id.uuidString, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = snapshot
            .filter { $0.status == .active }
            .map { StandingViewCandidate(id: $0.id.uuidString, title: $0.title, body: $0.body) }
        guard !candidates.isEmpty else { return }

        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        guard let state = try? await store.liveState() else { return }
        let openPursuits = state.items.filter { $0.isPursuit && !$0.status.isTerminal }
        // Dedup against EVERY pursuit the desk remembers, terminal included
        // (gpt-5.5 review 2026-08-08, blocking): the exhaustion closer cancels
        // a spent pursuit, and an open-only dedup would make its standing view
        // eligible again on the very next reflection — the paraphrase rut,
        // cycling. A view gets ONE auto-pursuit per desk lifetime; pursuing it
        // again is a decision for the user, not the proposer. (Archived rows
        // leave the live feed eventually — accepted residual, months out.)
        let allAgentPursuits = state.items.filter { $0.isPursuit && $0.origin == .agent }
        let citedViewIds = Set(allAgentPursuits.flatMap { item -> [String] in
            (item.pursuit?.evidence.citations ?? []).compactMap { citation in
                if case .standingView(let id) = citation { return id }
                return nil
            }
        })

        guard let proposal = AutonomousPursuitProposer.propose(
            candidates: candidates,
            openAgentPursuitCount: openPursuits.count,
            standingViewIdsWithOpenPursuit: citedViewIds,
            resolveStatus: { statusById[$0] }
        ) else { return }

        do {
            // openPursuit re-validates STRUCTURALLY under the flock (fields +
            // dossier + open-pursuit cap) — the store owns the invariant, not this.
            let notify = NotifyPolicy(
                level: .direct,
                on: ["explicit"],
                notifyReason: "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) opened a self-pursuit: \(proposal.title)"
            )
            let item = try await store.openPursuit(
                project: proposal.project,
                title: proposal.title,
                pursuit: proposal.pursuit,
                summary: proposal.summary,
                notify: notify
            )
            // The create and its direct-level announcement policy share one
            // durable op, so a crash cannot leave an unannounced pursuit.
            // Honest receipt: which standing view, why proposed.
            await substrate.recordReceipt(
                kind: "workshop.pursuit_proposed",
                payload: .object([
                    "handle": .string(item.handle),
                    "standingViewId": .string(proposal.citedStandingViewId),
                    "title": .string(proposal.title),
                    "why": .string(proposal.pursuit.why),
                    "rationale": .string(proposal.rationale),
                    "reason": .string(reason),
                    "origin": .string(DeskOrigin.agent.rawValue),
                ])
            )
        } catch {
            // Fail-closed: a store refusal (cap/dossier) records an honest receipt
            // and opens NO pursuit.
            await substrate.recordReceipt(
                kind: "workshop.pursuit_proposal_refused",
                payload: .object([
                    "standingViewId": .string(proposal.citedStandingViewId),
                    "error": .string(String(describing: error)),
                    "reason": .string(reason),
                ])
            )
        }
    }

    @discardableResult
    public func runManualReflection(reason: String = "observatory manual reflection") async -> CognitiveBackgroundRunOutcome {
        await bootstrap()
        let configuration = await substrate.configurationSnapshot()
        guard configuration.enabled && configuration.reflectiveCallsEnabled else {
            let gateReason = "reflection is disabled"
            await substrate.recordReceipt(
                kind: "reflection.skipped",
                payload: .object([
                    "reason": .string(reason),
                    "status": .string("gate_denied"),
                    "error": .string(gateReason),
                ])
            )
            publishRuntimeChange(reason: "reflection:gate_denied")
            return .skipped(gateReason)
        }
        if let providerRoutingFailure {
            await substrate.recordReceipt(
                kind: "reflection.skipped",
                payload: .object([
                    "reason": .string(reason),
                    "status": .string("provider_routing_unavailable"),
                    "error": .string(providerRoutingFailure),
                ])
            )
            publishRuntimeChange(reason: "reflection:provider_unavailable")
            return .skipped("provider routing unavailable: \(providerRoutingFailure)")
        }
        let request: CognitiveReflectionRequest
        switch await substrate.planReflectionChecked(reason: reason, demand: .requested) {
        case .admitted(let planned):
            request = planned
        case .refused(let admission):
            await substrate.recordReceipt(
                kind: "reflection.skipped",
                payload: .object([
                    "reason": .string(reason),
                    "status": .string(admission.reason),
                    "detail": .string(admission.detail),
                ])
            )
            publishRuntimeChange(reason: "reflection:skipped")
            return .skipped(admission.detail)
        }
        let outcome = await executeReflection(
            request: request,
            llm: host.backgroundLLMClient(dataRoot: dataRoot, cognition: self)
        )
        publishRuntimeChange(reason: "reflection:manual_finished")
        return outcome
    }

    @discardableResult
    private func executeReflection(
        request: CognitiveReflectionRequest,
        llm: any LLMClient
    ) async -> CognitiveBackgroundRunOutcome {
        let result: CognitiveReflectionJudgment
        // User, 2026-09-13: every model-consuming lane resolves through its
        // Providers group. Reflection used to call on `CognitiveConfiguration`'s
        // stored model — a hardcoded Anthropic id — which is a route chosen in
        // code, not at the picker. The Memory and mind group's answer is the
        // only answer now, read through the CHECKED seam: corrupt provider
        // authority is unavailable, not an excuse to invent a model.
        let routedModel: String
        do {
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot)
                .checkedRoutingSnapshot()
            let resolved = ProviderRoutingSurfaceLookup
                .value(snapshot.preferences, request.surface)?.model
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !resolved.isEmpty else {
                await substrate.releaseReflectionReservation(request: request)
                await substrate.recordReceipt(
                    kind: "reflection.model_unresolved",
                    payload: .object(["surface": .string(request.surface)])
                )
                return .skipped("No model is set up for Memory and mind yet.")
            }
            routedModel = resolved
        } catch {
            await substrate.releaseReflectionReservation(request: request)
            await substrate.recordReceipt(
                kind: "reflection.routing_unavailable",
                payload: .object([
                    "surface": .string(request.surface),
                    "error": .string(String(describing: error)),
                ])
            )
            return .skipped("The saved provider choice could not be read.")
        }
        do {
            let system = try await cognitiveReflectionSystemPrompt(surface: request.surface)
            let raw = try await PrivateWorkContextAssembly.$current.withValue(.suppliedPersona) {
                try await llm.complete(
                    prompt: request.prompt,
                    system: system,
                    model: routedModel,
                    surface: request.surface, purpose: "reflection"
                )
            }
            try Task.checkCancellation()
            result = try JSONDecoder().decode(CognitiveReflectionJudgment.self, from: Data(raw.utf8))
            try result.validate(material: request.material)
        } catch let error as CognitiveReflectionPersonaError {
            await substrate.recordReceipt(
                kind: "reflection.persona_load_failed",
                payload: .object([
                    "surface": .string(request.surface),
                    "error": .string(String(describing: error)),
                ])
            )
            if let failure = await settleReflectionResult(
                request: request,
                resultSummary: "reflection failed: persona load failed: \(String(describing: error))",
                rejection: "reflection persona failure was not accepted by the substrate",
                persistenceFailure: "reflection persona failure receipt persistence failed"
            ) { return failure }
            return .failed("reflection persona load failed: \(error.localizedDescription)")
        } catch is CancellationError {
            if let failure = await settleReflectionResult(
                request: request,
                resultSummary: "reflection cancelled",
                cancelled: true,
                rejection: "reflection cancellation was not accepted by the substrate",
                persistenceFailure: "reflection cancellation receipt persistence failed"
            ) { return failure }
            return .skipped("reflection cancelled")
        } catch {
            if let failure = await settleReflectionResult(
                request: request,
                resultSummary: "reflection failed: \(String(describing: error))",
                rejection: "reflection failure was not accepted by the substrate",
                persistenceFailure: "reflection failure receipt persistence failed"
            ) { return failure }
            return .failed("reflection failed: \(error.localizedDescription)")
        }

        if let failure = await settleReflectionResult(
            request: request,
            resultSummary: result.reflection,
            judgment: result,
            rejection: "reflection result was not accepted by the substrate",
            persistenceFailure: "reflection integrated but receipt persistence failed"
        ) { return failure }
        let persistenceEnabled = await substrate.configurationSnapshot().persistenceEnabled
        return .completed(persistenceEnabled
            ? "reflection result and receipt are durable"
            : "reflection result integrated in memory-only mode")
    }

    private func settleReflectionResult(
        request: CognitiveReflectionRequest,
        resultSummary: String,
        judgment: CognitiveReflectionJudgment? = nil,
        cancelled: Bool = false,
        rejection: String,
        persistenceFailure: String
    ) async -> CognitiveBackgroundRunOutcome? {
        // Internal reflection mutations use the same coalesced settlement as sensory input.
        defer { scheduleDirtyMicrocycle(reason: "reflection_result") }
        guard let receipt = await substrate.recordReflectionResult(
            request: request,
            resultSummary: resultSummary,
            provider: request.provider,
            cancelled: cancelled,
            judgment: judgment
        ) else { return .failed(rejection) }
        do {
            try await substrate.persistReflectionResultChecked(receipt)
        } catch {
            // A persistence failure never integrates the result a second time.
            return .failed("\(persistenceFailure): \(error.localizedDescription)")
        }
        return nil
    }

    private func cognitiveReflectionSystemPrompt(surface: String) async throws -> String {
        let persona = cognitionPersonaEngine()
        let packet: PersonalityPacket
        do {
            let userMemoryCore = MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot)
                ? await SwiftNativeMemoryV2.userCoreForBackground(dataRoot: dataRoot)
                : []
            packet = try await PersonaCompiler(engine: persona).compile(
                surface: surface, userMemoryCore: userMemoryCore
            )
        } catch {
            throw CognitiveReflectionPersonaError.compileFailed(String(describing: error))
        }
        let compiled = packet.compiledSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compiled.isEmpty else {
            throw CognitiveReflectionPersonaError.emptyCompiledPrompt(surface: surface)
        }
        await substrate.recordReceipt(
            kind: "reflection.persona_context",
            payload: .object([
                "surface": .string(packet.surface),
                "personaId": .string(packet.personaId),
                "personaKind": .string(packet.personaKind),
                "fingerprint": .string(packet.fingerprint),
                "docCount": .int(Int64(packet.activeDocs.count)),
            ])
        )
        let boundary = """
        # Private reflection
        Reflect as yourself on the supplied runtime evidence. Be concise. Do not claim hidden state, dispatch actions, change identity, memory or schemas, or treat inferred or dreamed content as observed. Use only the standing-view path stated in the task.
        """
        return [compiled, boundary].joined(separator: "\n\n")
    }

    private func cognitionPersonaEngine() -> SwiftNativePersonaEngine {
        usesLiveAppBody
            ? SwiftNativePersonaEngine(dataRoot: dataRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
    }

    public func setReflectionSelection(model: String, provider: String) async throws {
        guard usesLiveAppBody else {
            throw NSError(
                domain: "NativeCognitionRuntime",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey:
                    "Alternate-root cognition runtimes cannot mutate the live app's reflection setting."]
            )
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "NativeCognitionRuntime",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Choose a model for Memory and mind."]
            )
        }
        let resolvedModel = trimmed
        let resolvedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedProvider.isEmpty else {
            throw NSError(
                domain: "NativeCognitionRuntime",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Reflection provider is missing."]
            )
        }
        try await writeReflectionSurface(model: resolvedModel, provider: resolvedProvider)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection_model")
    }

    public func reflectionRouteStatus() async -> NativeReflectionRouteStatus {
        do {
            let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
            let snapshot = try await router.checkedRoutingSnapshot()
            let surface = "cognition_reflection"
            guard let preference = snapshot.preferences[surface] else {
                return NativeReflectionRouteStatus(
                    model: "",
                    providerID: "",
                    providerReady: false,
                    modelKnown: nil,
                    detail: "No reflection route is configured."
                )
            }
            let providerID = snapshot.activeProviders[surface] ?? ""
            let providers = try await router.listProviders()
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                return NativeReflectionRouteStatus(
                    model: preference.model,
                    providerID: providerID,
                    providerReady: false,
                    modelKnown: nil,
                    detail: "The selected reflection provider is unavailable."
                )
            }
            let providerReady = provider.configured == true
            let modelKnown: Bool? = {
                if providerID == "openrouter" {
                    switch OpenRouterModelCatalog.cachedAvailability(
                        of: preference.model,
                        dataRoot: dataRoot
                    ) {
                    case .available: return true
                    case .unavailable: return false
                    case .unknown: return nil
                    }
                }
                guard case .array(let rows)? = provider.modelCatalog else { return nil }
                let ids = Set(rows.compactMap { row -> String? in
                    guard case .object(let object) = row,
                          case .string(let id)? = object["id"] else { return nil }
                    return id
                })
                return ids.isEmpty ? nil : ids.contains(preference.model)
            }()
            let detail: String
            if !providerReady {
                detail = provider.lastError ?? "Connect \(provider.displayName ?? providerID) before reflection can run."
            } else if modelKnown == false {
                detail = "\(provider.displayName ?? providerID) no longer offers \(preference.model). Choose a replacement."
            } else if modelKnown == nil {
                detail = "Provider credentials are ready; model availability has not been freshly verified."
            } else {
                detail = "Reflection route is ready."
            }
            return NativeReflectionRouteStatus(
                model: preference.model,
                providerID: providerID,
                providerReady: providerReady,
                modelKnown: modelKnown,
                detail: detail
            )
        } catch {
            return NativeReflectionRouteStatus(
                model: "",
                providerID: "",
                providerReady: false,
                modelKnown: nil,
                detail: "Reflection routing is unavailable: \(error.localizedDescription)"
            )
        }
    }

    /// Deliberately does nothing since 2026-09-13. It used to seed a
    /// `cognition_reflection` row at startup from the cognitive configuration —
    /// an override nobody asked for, written before a person had chosen
    /// anything, which then split Memory and mind. Reflection resolves through
    /// the group; there is nothing to seed.
    func ensureReflectionSurfaceSeed() async {  // internal for actor extensions (move-only Wave C)
    }

    /// 2026-09-13 review: this used to write `cognition_reflection` alone, which
    /// is precisely the per-surface override the group rule exists to prevent —
    /// one lane of Memory and mind pointed somewhere its group-mates are not.
    /// The separate reflection control now writes the GROUP's override: every
    /// member of Memory and mind, the same thing the Providers page writes.
    private func writeReflectionSurface(
        model: String,
        provider: String,
        overwriteExisting: Bool = true
    ) async throws {
        let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
        for surface in ProviderSurfaceGroups.mind.surfaces {
            try await routing.saveSurfaceConfiguration(
                surface: surface,
                model: model,
                reasoningEffort: "high",
                serviceTier: nil,
                providerId: provider,
                overwriteExisting: overwriteExisting
            )
        }
    }
}
