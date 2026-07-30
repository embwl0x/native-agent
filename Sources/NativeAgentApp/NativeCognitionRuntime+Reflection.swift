// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

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
    /// reflection sees post-replay substrate state. Single-flight: a signal
    /// arriving while a reflection is in flight is dropped — the material is
    /// durable and the daily integrity sweep (or the next commit) catches it.
    /// Budget/enabled/reservation gating stays inside `runReflectionIfDue`;
    /// this path adds no new unattended-LLM authority. Gated to the live app
    /// body so alternate-root test runtimes never fire provider work (the
    /// override seam bypasses that gate for proofs, mirroring replay's).
    func scheduleEventDrivenReflection(reason: String) {
        guard !isFlushedForTermination else { return }
        guard usesLiveAppBody || eventDrivenReflectionOperationOverride != nil else { return }
        guard reflectionEventTask == nil else { return }
        eventDrivenReflectionAttemptCount &+= 1
        reflectionEventTask = Task { [weak self] in
            await self?.runEventDrivenReflection(reason: reason)
        }
    }

    private func runEventDrivenReflection(reason: String) async {
        defer { reflectionEventTask = nil }
        if let override = eventDrivenReflectionOperationOverride {
            await override(reason)
            return
        }
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        _ = await runReflectionIfDue(
            llm: BackgroundLoopsAssembly.makeSharedLLMClient(
                dataRoot: dataRoot,
                cognitionRuntime: self
            ),
            reason: reason
        )
    }

    func eventDrivenReflectionAttemptCountForProof() -> UInt64 {
        eventDrivenReflectionAttemptCount
    }

    /// Proof seam: await the in-flight event-driven reflection task so tests
    /// can assert on its effects without wall-clock polling.
    func drainEventDrivenReflectionForProof() async {
        await reflectionEventTask?.value
    }

    @discardableResult
    func runReflectionIfDue(llm: any LLMClient, reason: String) async -> CognitiveBackgroundRunOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(bootstrapFailure) }
        if let providerRoutingFailure { return .failed(providerRoutingFailure) }
        switch await backgroundCognitionGate(reason: reason) {
        case .skipped(let reason): return .skipped(reason)
        case .allowed: break
        }
        guard let request = await substrate.planReflection(reason: reason) else {
            return .skipped("reflection disabled, not due, or out of budget")
        }
        let reflectionOutcome = await executeReflection(request: request, llm: llm)
        publishRuntimeChange(reason: "reflection:finished")
        guard case .completed = reflectionOutcome else { return reflectionOutcome }
        // C2 lease PRIORITY (gpt-5.5 LOW): reflection did real expensive-LLM
        // work THIS window → mark the shared green-window lease so a later
        // workshop tick yields to her cognition. Marked here (not in the loop
        // tick) so a not-due reflection never consumes a window for nothing.
        // Result ignored — reflection never gates on the lease. Same dataRoot
        // and window key the pump uses.
        _ = await BackgroundWorkLease(dataRoot: dataRoot)
            .tryAcquire(holder: "reflection", window: WorkshopPump.windowKey(Date()))
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
        guard await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: dataRoot) else { return }

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
        let citedViewIds = Set(openPursuits.flatMap { item -> [String] in
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
            let item = try await store.openPursuit(
                project: proposal.project,
                title: proposal.title,
                pursuit: proposal.pursuit,
                summary: proposal.summary
            )
            // Announce via the desk notify DIGEST surface at DIRECT level (never
            // urgent) — the existing DeskNotify loop fires it once on its next tick.
            _ = try? await store.setNotify(item.handle, policy: NotifyPolicy(
                level: .direct,
                on: ["explicit"],
                notifyReason: "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) opened a self-pursuit: \(proposal.title)"
            ))
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

    func runManualReflection(reason: String = "observatory manual reflection") async {
        await bootstrap()
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
            return
        }
        guard case .allowed = await backgroundCognitionGate(reason: reason) else { return }
        guard let request = await substrate.planReflection(reason: reason) else {
            await substrate.recordReceipt(
                kind: "reflection.skipped",
                payload: .object([
                    "reason": .string(reason),
                    "status": .string("not_enabled_budgeted_or_available"),
                ])
            )
            publishRuntimeChange(reason: "reflection:skipped")
            return
        }
        _ = await executeReflection(
            request: request,
            llm: BackgroundLoopsAssembly.makeSharedLLMClient(
                dataRoot: dataRoot,
                cognitionRuntime: self
            )
        )
        publishRuntimeChange(reason: "reflection:manual_finished")
    }

    @discardableResult
    private func executeReflection(
        request: CognitiveReflectionRequest,
        llm: any LLMClient
    ) async -> CognitiveBackgroundRunOutcome {
        let result: String
        do {
            let system = try await cognitiveReflectionSystemPrompt(surface: request.surface)
            result = try await llm.complete(
                prompt: request.prompt,
                system: system,
                model: request.model,
                surface: request.surface
            )
        } catch let error as CognitiveReflectionPersonaError {
            await substrate.recordReceipt(
                kind: "reflection.persona_load_failed",
                payload: .object([
                    "surface": .string(request.surface),
                    "error": .string(String(describing: error)),
                ])
            )
            guard let receipt = await substrate.recordReflectionResult(
                request: request,
                resultSummary: "reflection failed: persona load failed: \(String(describing: error))",
                provider: request.provider
            ) else {
                scheduleDirtyMicrocycle(reason: "reflection_result")
                return .failed("reflection persona failure was not accepted by the substrate")
            }
            do {
                try await substrate.persistReflectionResultChecked(receipt)
            } catch {
                scheduleDirtyMicrocycle(reason: "reflection_result")
                return .failed("reflection persona failure receipt persistence failed: \(error.localizedDescription)")
            }
            scheduleDirtyMicrocycle(reason: "reflection_result")
            return .failed("reflection persona load failed: \(error.localizedDescription)")
        } catch is CancellationError {
            guard let receipt = await substrate.recordReflectionResult(
                request: request,
                resultSummary: "reflection cancelled",
                provider: request.provider,
                cancelled: true
            ) else {
                scheduleDirtyMicrocycle(reason: "reflection_result")
                return .failed("reflection cancellation was not accepted by the substrate")
            }
            do {
                try await substrate.persistReflectionResultChecked(receipt)
            } catch {
                scheduleDirtyMicrocycle(reason: "reflection_result")
                return .failed("reflection cancellation receipt persistence failed: \(error.localizedDescription)")
            }
            scheduleDirtyMicrocycle(reason: "reflection_result")
            return .skipped("reflection cancelled")
        } catch {
            guard let receipt = await substrate.recordReflectionResult(
                request: request,
                resultSummary: "reflection failed: \(String(describing: error))",
                provider: request.provider
            ) else {
                scheduleDirtyMicrocycle(reason: "reflection_result")
                return .failed("reflection failure was not accepted by the substrate")
            }
            do {
                try await substrate.persistReflectionResultChecked(receipt)
            } catch {
                scheduleDirtyMicrocycle(reason: "reflection_result")
                return .failed("reflection failure receipt persistence failed: \(error.localizedDescription)")
            }
            scheduleDirtyMicrocycle(reason: "reflection_result")
            return .failed("reflection failed: \(error.localizedDescription)")
        }

        guard let receipt = await substrate.recordReflectionResult(
            request: request,
            resultSummary: result,
            provider: request.provider
        ) else {
            scheduleDirtyMicrocycle(reason: "reflection_result")
            return .failed("reflection result was not accepted by the substrate")
        }
        do {
            try await substrate.persistReflectionResultChecked(receipt)
        } catch {
            // The result was integrated exactly once. A persistence failure is
            // evidence failure, not a second reflection result.
            scheduleDirtyMicrocycle(reason: "reflection_result")
            return .failed("reflection integrated but receipt persistence failed: \(error.localizedDescription)")
        }
        // Reflection can create thought seeds and review-bound standing-view
        // proposals without passing through `observe(_:)`. Keep those internal
        // mutations on the same event-coalesced settlement path as sensory input.
        scheduleDirtyMicrocycle(reason: "reflection_result")
        let persistenceEnabled = await substrate.configurationSnapshot().persistenceEnabled
        return .completed(persistenceEnabled
            ? "reflection result and receipt are durable"
            : "reflection result integrated in memory-only mode")
    }

    private func cognitiveReflectionSystemPrompt(surface: String) async throws -> String {
        let persona = cognitionPersonaEngine()
        let packet: PersonalityPacket
        do {
            packet = try await PersonaCompiler(engine: persona).compile(surface: surface)
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
        # Background Cognition Boundary
        You are \(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) in a private NativeAgent background reflection pass. Produce a concise reflection grounded only in the provided runtime state. Do not claim hidden state, mutate identity, dispatch actions, or treat inferred/dreamed content as observed. Any identity, memory, or schema change must remain a proposal for review.
        """
        return [compiled, boundary].joined(separator: "\n\n")
    }

    private func cognitionPersonaEngine() -> SwiftNativePersonaEngine {
        usesLiveAppBody
            ? SwiftNativePersonaEngine(dataRoot: dataRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
    }

    func setReflectionModel(_ model: String) async throws {
        guard usesLiveAppBody else {
            throw NSError(
                domain: "NativeCognitionRuntime",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey:
                    "Alternate-root cognition runtimes cannot mutate the live app's reflection setting."]
            )
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmed.isEmpty ? Self.defaultReflectionModel : trimmed
        let provider = Self.inferredReflectionProvider(for: resolvedModel)
        try await writeReflectionSurface(model: resolvedModel, provider: provider)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection_model")
    }

    func ensureReflectionSurfaceSeed() async {  // internal for actor extensions (move-only Wave C)
        let configuration = configurationOverride ?? Self.loadConfiguration()
        try? await writeReflectionSurface(
            model: configuration.reflectionModel,
            provider: configuration.reflectionProvider,
            overwriteExisting: false
        )
    }

    private func writeReflectionSurface(
        model: String,
        provider: String,
        overwriteExisting: Bool = true
    ) async throws {
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).saveSurfaceConfiguration(
            surface: "cognition_reflection",
            model: model,
            reasoningEffort: "high",
            serviceTier: nil,
            providerId: provider,
            overwriteExisting: overwriteExisting
        )
    }
}
