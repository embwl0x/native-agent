import Foundation
import NativeAgentShared
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
    /// Reflection follows the committed dream/REM replay. Each caller retains its
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
    ) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(error: bootstrapFailure) }
        if let providerRoutingFailure { return .failed(error: providerRoutingFailure) }
        let request: CognitiveReflectionRequest
        // Take the lease BEFORE planning: planning sets the in-flight
        // reservation, and a lease refusal after it would strand that
        // reservation and refuse every reflection until it expires.
        let lease = host.backgroundWorkLease(dataRoot: dataRoot)
        let window = host.backgroundWorkWindow(Date())
        guard await lease.tryAcquire(holder: "reflection", window: window) else {
            return .skipped(reason: "background work lease held")
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
            return .skipped(reason: admission.reason == CognitiveSubstrate.reflectionRefusalDisabled
                ? LoopTickOutcome.offPrefix + "reflection disabled" : admission.detail)
        }
        let reflectionOutcome = await executeReflection(request: request, llm: llm)
        if case .skipped(let why, _) = reflectionOutcome, why != "reflection cancelled" {
            // Routing refused before any provider work; return the unused slot.
            // A cancellation came after the provider call began: the slot is spent.
            _ = await lease.releaseUnused(holder: "reflection", window: window)
        }
        publishRuntimeChange(reason: "reflection:finished")
        if case .completed = reflectionOutcome, !Task.isCancelled, !isFlushedForTermination {
            await proposePursuitFromReflectionIfEligible(reason: reason)
        }
        return reflectionOutcome
    }

    private func proposePursuitFromReflectionIfEligible(reason: String) async {
        guard !Task.isCancelled, !isFlushedForTermination,
              await host.unattendedWorkAllowed(dataRoot: dataRoot) else { return }
        let cares = await substrate.caresPressing(for: CognitiveCare.ownerKey, at: Date()).map(\.care)
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        guard let state = try? await store.liveState() else { return }
        let open = state.items.filter { $0.isPursuit && !$0.status.isTerminal }
        let citations = state.items.filter { $0.isPursuit && $0.origin == .agent }.flatMap {
            $0.pursuit?.evidence.citations ?? []
        }
        var cited = Set(citations.compactMap { citation -> String? in
            if case .care(let id) = citation { return id }
            return nil
        })
        let carried = Set(citations.compactMap { citation -> String? in
            if case .standingView(let id) = citation { return id }
            return nil
        })
        for care in cares {
            if case .migrated(let id) = care.origin, carried.contains(id) { cited.insert(care.id.uuidString) }
        }
        guard let proposal = AutonomousPursuitProposer.propose(
            cares: cares, openAgentPursuitCount: open.count, citedCareIds: cited) else { return }
        do {
            guard !Task.isCancelled, !isFlushedForTermination else { return }
            let item = try await store.openPursuit(
                project: proposal.project, title: proposal.title, pursuit: proposal.pursuit, summary: proposal.summary,
                notify: NotifyPolicy(level: .direct, on: ["explicit"],
                    notifyReason: "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) opened a self-pursuit: \(proposal.title)"))
            await substrate.recordReceipt(kind: "workshop.pursuit_proposed", payload: .object([
                "handle": .string(item.handle), "careId": .string(proposal.citedCareId),
                "title": .string(proposal.title), "why": .string(proposal.pursuit.why),
                "rationale": .string(proposal.rationale), "reason": .string(reason),
                "origin": .string(DeskOrigin.agent.rawValue),
            ]))
        } catch {
            await substrate.recordReceipt(kind: "workshop.pursuit_proposal_refused", payload: .object([
                "careId": .string(proposal.citedCareId), "error": .string(String(describing: error)),
                "reason": .string(reason),
            ]))
        }
    }

    @discardableResult
    public func runManualReflection(reason: String = "manual reflection") async -> LoopTickOutcome {
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
            return .skipped(reason: gateReason)
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
            return .skipped(reason: "provider routing unavailable: \(providerRoutingFailure)")
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
            return .skipped(reason: admission.detail)
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
    ) async -> LoopTickOutcome {
        let result: CognitiveReflectionJudgment
        // Bind one checked route for execution and receipt attribution.
        var plannedRequest = request
        let route: TurnRouteAdmission
        do {
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot)
                .checkedRoutingSnapshot()
            guard ProviderRoutingSurfaceLookup.value(snapshot.preferences, request.surface)?
                .model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                await substrate.releaseReflectionReservation(request: request)
                await substrate.recordReceipt(
                    kind: "reflection.model_unresolved",
                    payload: .object(["surface": .string(request.surface)])
                )
                return .skipped(reason: "No model is set up for Memory and mind yet.")
            }
            route = try snapshot.routeAdmission(for: request.surface, choice: nil, inheritChat: false)
            plannedRequest.model = route.modelId
            plannedRequest.provider = route.providerId ?? ""
            plannedRequest.reasoningEffort = route.reasoningEffort
        } catch {
            await substrate.releaseReflectionReservation(request: request)
            await substrate.recordReceipt(
                kind: "reflection.routing_unavailable",
                payload: .object([
                    "surface": .string(request.surface),
                    "error": .string(String(describing: error)),
                ])
            )
            return .skipped(reason: "The saved provider choice could not be read.")
        }
        let request = plannedRequest
        do {
            let system = try await cognitiveReflectionSystemPrompt(surface: request.surface)
            let raw = try await PrivateWorkContextAssembly.$current.withValue(.suppliedPersona) {
                try await route.withModelContext {
                    try await llm.complete(
                        prompt: request.prompt,
                        system: system,
                        model: nil,
                        surface: request.surface, purpose: "reflection", tools: nil
                    )
                }
            }
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
            return .failed(error: "reflection persona load failed: \(error.localizedDescription)")
        } catch is CancellationError {
            if let failure = await settleReflectionResult(
                request: request,
                resultSummary: "reflection cancelled",
                cancelled: true,
                rejection: "reflection cancellation was not accepted by the substrate",
                persistenceFailure: "reflection cancellation receipt persistence failed"
            ) { return failure }
            return .skipped(reason: "reflection cancelled")
        } catch {
            if let failure = await settleReflectionResult(
                request: request,
                resultSummary: "reflection failed: \(String(describing: error))",
                rejection: "reflection failure was not accepted by the substrate",
                persistenceFailure: "reflection failure receipt persistence failed"
            ) { return failure }
            return .failed(error: "reflection failed: \(error.localizedDescription)")
        }

        if let failure = await settleReflectionResult(
            request: request,
            resultSummary: result.reflection,
            judgment: result,
            rejection: "reflection result was not accepted by the substrate",
            persistenceFailure: "reflection integrated but receipt persistence failed"
        ) { return failure }
        let persistenceEnabled = await substrate.configurationSnapshot().persistenceEnabled
        return .completed(result: persistenceEnabled
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
    ) async -> LoopTickOutcome? {
        await settle { [self] in
            await self.persistReflectionSettlement(request: request, resultSummary: resultSummary,
                judgment: judgment, cancelled: cancelled, rejection: rejection, persistenceFailure: persistenceFailure)
        }
    }

    private func persistReflectionSettlement(
        request: CognitiveReflectionRequest, resultSummary: String,
        judgment: CognitiveReflectionJudgment?, cancelled: Bool,
        rejection: String, persistenceFailure: String
    ) async -> LoopTickOutcome? {
        // Internal reflection mutations use the same coalesced settlement as sensory input.
        defer { scheduleDirtyMicrocycle(reason: "reflection_result") }
        guard let receipt = await substrate.recordReflectionResult(
            request: request,
            resultSummary: resultSummary,
            provider: request.provider,
            cancelled: cancelled,
            judgment: judgment
        ) else { return .failed(error: rejection) }
        do {
            try await substrate.persistReflectionResultChecked(receipt)
        } catch {
            // A persistence failure never integrates the result a second time.
            return .failed(error: "\(persistenceFailure): \(error.localizedDescription)")
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
        let boundary = try completionPolicy("reflection", section: "system")
        return [compiled, boundary].joined(separator: "\n\n")
    }

    private func cognitionPersonaEngine() -> SwiftNativePersonaEngine {
        usesLiveAppBody
            ? SwiftNativePersonaEngine(dataRoot: dataRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
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

}
