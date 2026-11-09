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
import ChatTurnContracts

// Blueprint: | `NativeCognitionRuntime+Reflection.swift` | `NativeCognitionRuntime`. |

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
    /// Budget and in-flight refusals keep dream reflection owed; disabled reflection settles with its off reason.
    public enum DreamReflection: Sendable { case judged(CognitiveReflectionReceipt), skipped(String) }

    /// Persist the provider receipt before returning; exact reason identity lets recovery integrate without another production call.
    public func produceDreamReflection(id: UUID, material: [String: CognitiveReflectionCause]) async throws -> DreamReflection {
        await bootstrap()
        guard usesLiveAppBody, !isFlushedForTermination, !Task.isCancelled else {
            throw PersistenceCoreError.ioFailure("dream reflection awaits the running mind")
        }
        if let bootstrapFailure { throw PersistenceCoreError.ioFailure(bootstrapFailure) }
        let reason = "dream:\(id.uuidString)"
        if let receipt = await substrate.reflectionReceiptSnapshot().first(where: {
            $0.request.reason == reason && !$0.cancelled && $0.judgment != nil
        }) {
            try await substrate.checkpointReflectionResultChecked(receipt)
            return .judged(receipt)
        }
        let configuration = await substrate.configurationSnapshot()
        guard configuration.enabled, configuration.reflectiveCallsEnabled else { return .skipped("reflection disabled") }
        guard configuration.persistenceEnabled else {
            throw PersistenceCoreError.ioFailure("dream reflection requires durable inner life")
        }
        let replay = await runEventDrivenReplay(reason: reason, material: nil)
        switch replay {
        case .completed: break
        case .skipped(let detail, _) where detail == "no new replay evidence": break
        case .skipped(let detail, _), .failed(let detail):
            throw PersistenceCoreError.ioFailure("dream reflection awaits replay: \(detail)")
        }
        let outcome = await runReflectionIfDue(
            llm: host.backgroundLLMClient(dataRoot: dataRoot, cognition: self, assembly: .suppliedPersona),
            reason: reason, material: material, retainForDream: true)
        await reportLoopOutcome(loopId: "cognition_reflection", outcome: outcome)
        // Retain produced receipts even when care or mood settlement remains owed.
        if let receipt = await substrate.reflectionReceiptSnapshot().first(where: {
            $0.request.reason == reason && !$0.cancelled && $0.judgment != nil
        }) {
            try await substrate.checkpointReflectionResultChecked(receipt)
            return .judged(receipt)
        }
        switch outcome {
        case .failed(let error): throw PersistenceCoreError.ioFailure("dream reflection failed: \(error)")
        // Switched-off reflection settles with its off reason.
        case .skipped(let reason, _) where reason.hasPrefix(LoopTickOutcome.offPrefix):
            return .skipped(String(reason.dropFirst(LoopTickOutcome.offPrefix.count)))
        // A held slot keeps the reflection owed as busy, not failed.
        case .skipped(let reason, _) where reason.hasPrefix(LoopTickOutcome.busyPrefix):
            throw DreamBusy(String(reason.dropFirst(LoopTickOutcome.busyPrefix.count)))
        case .skipped(let reason, _): throw PersistenceCoreError.ioFailure("dream reflection remains owed: \(reason)")
        case .completed: throw PersistenceCoreError.ioFailure("dream reflection returned no judgment receipt")
        }
    }

    public func integrateDreamReflection(_ receipt: CognitiveReflectionReceipt) async throws -> String? {
        await bootstrap()
        if let bootstrapFailure { throw PersistenceCoreError.ioFailure(bootstrapFailure) }
        guard !isFlushedForTermination, await substrate.configurationSnapshot().persistenceEnabled else {
            throw PersistenceCoreError.ioFailure("dream reflection integration awaits saved inner life")
        }
        let result: Result<Void, Error> = await settle { [self] in
            do { try await substrate.persistReflectionResultChecked(receipt); return .success(()) }
            catch { return .failure(error) }
        }
        try result.get()
        if !Task.isCancelled, !isFlushedForTermination {
            await proposePursuitFromReflectionIfEligible(reason: receipt.request.reason)
        }
        return await substrate.reflectionReceiptSnapshot().first { $0.id == receipt.id }?.integrationSkipped
    }

    /// Reflect only after committed dream/REM replay, retaining source material while joining the existing single flight.
    /// Keep admission inside runReflectionIfDue and provider work restricted to the live app body.
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
            llm: host.backgroundLLMClient(dataRoot: dataRoot, cognition: self, assembly: .suppliedPersona),
            reason: reason,
            material: material
        )
        await reportLoopOutcome(loopId: "cognition_reflection", outcome: outcome)
    }

    /// Dream and replay reflection share admission and retained settlement.
    /// The injected client uses supplied-persona assembly: this owner compiles the reflection system itself.
    @discardableResult
    public func runReflectionIfDue(
        llm: any LLMClient,
        reason: String,
        material: [String: CognitiveReflectionCause]? = nil,
        retainForDream: Bool = false
    ) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return Self.beatReflection(.failed(error: bootstrapFailure)) }
        if let providerRoutingFailure { return Self.beatReflection(.failed(error: providerRoutingFailure)) }
        let request: CognitiveReflectionRequest
        // Acquire the lease before planning so refusal cannot strand an in-flight reservation.
        let lease = host.backgroundWorkLease(dataRoot: dataRoot)
        let now = Date()
        let window = host.backgroundWorkWindow(now)
        guard await lease.tryAcquire(holder: "reflection", window: window) else {
            // A claimed slot is busy and names its holder and the next slot; a lease that cannot be read is a failure, never a hold.
            let held: (holder: String, acquiredAt: String)?
            do { held = try await lease.claim(window: window) }
            catch { return Self.beatReflection(.failed(error: "the background work lease could not be read: \(error.localizedDescription)")) }
            guard let held else {
                return Self.beatReflection(.failed(error: "the background work lease refused window \(window), but no claim on it was read"))
            }
            let opens = NativeTimestampFormat.plainZulu(host.backgroundWorkWindowEnd(now))
            return Self.beatReflection(.busy("\(held.holder) took this two-hour background slot at \(held.acquiredAt); the next slot opens at \(opens)"))
        }
        switch await substrate.planReflectionChecked(
            reason: reason,
            material: material
        ) {
        case .admitted(let planned):
            request = planned
        case .refused(let admission):
            // The refusing gate becomes the typed outcome once, here; its detail carries the spend and reservation evidence.
            _ = await lease.releaseUnused(holder: "reflection", window: window)
            switch admission.reason {
            case CognitiveSubstrate.reflectionRefusalDisabled: return Self.beatReflection(.off("reflection disabled"))
            // The daily ceiling or a reflection already in flight means not now: it stays owed as busy, never failed.
            default: return Self.beatReflection(.busy(admission.detail))
            }
        }
        let reflectionOutcome = await executeReflection(request: request, llm: llm, retainForDream: retainForDream)
        if case .skipped(let why, _) = reflectionOutcome, why != "reflection cancelled" {
            // Return the unused slot if routing refused before provider work; cancellation after dispatch spends it.
            _ = await lease.releaseUnused(holder: "reflection", window: window)
        }
        publishRuntimeChange(reason: "reflection:finished")
        Self.beatReflection(reflectionOutcome)
        if case .completed = reflectionOutcome, !retainForDream, !Task.isCancelled, !isFlushedForTermination {
            await proposePursuitFromReflectionIfEligible(reason: reason)
        }
        return reflectionOutcome
    }

    static let reflectionOrgan = "cognition_reflection"

    /// Dream and replay reflection beat once at their shared admission boundary.
    @discardableResult
    private static func beatReflection(_ outcome: LoopTickOutcome) -> LoopTickOutcome {
        OrganJudge.beat(reflectionOrgan, tick: outcome, cadence: nil)
        return outcome
    }

    /// The proposer is judged after each completed reflection: off without unattended work, failed when the Desk will not read or take the pursuit.
    private func proposePursuitFromReflectionIfEligible(reason: String) async {
        let organ = "pursuit_proposer"
        guard !Task.isCancelled, !isFlushedForTermination else { return }
        guard await host.unattendedWorkAllowed(dataRoot: dataRoot) else {
            OrganJudge.beatOff(organ, because: "unattended work is not allowed")
            return
        }
        let cares = await substrate.caresPressing(for: CognitiveCare.ownerKey, at: Date()).map(\.care)
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do { state = try await store.liveState() }
        catch {
            OrganJudge.beat(organ, .failed, note: "the Desk could not be read: " + error.localizedDescription)
            return
        }
        let open = state.items.filter { $0.isPursuit && !$0.status.isTerminal }
        let citations = state.items.filter { $0.isPursuit && $0.origin == .agent }.flatMap {
            $0.pursuit?.evidence.citations ?? []
        }
        let cited = Set(citations.compactMap { citation -> String? in
            if case .care(let id) = citation { return id }
            return nil
        })
        guard let proposal = AutonomousPursuitProposer.propose(
            cares: cares, openAgentPursuitCount: open.count, citedCareIds: cited) else {
            OrganJudge.beat(organ, .nothing, note: "no care called for a new pursuit (\(open.count) open)")
            return
        }
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
            OrganJudge.beat(organ, .worked, note: "opened a pursuit: " + proposal.title, yield: 1)
        } catch {
            OrganJudge.beat(organ, .failed, note: "the pursuit was not opened: " + error.localizedDescription)
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
        switch await substrate.planReflectionChecked(reason: reason) {
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
            llm: host.backgroundLLMClient(dataRoot: dataRoot, cognition: self, assembly: .suppliedPersona),
            retainForDream: false
        )
        publishRuntimeChange(reason: "reflection:manual_finished")
        return outcome
    }

    @discardableResult
    private func executeReflection(
        request: CognitiveReflectionRequest,
        llm: any LLMClient,
        retainForDream: Bool
    ) async -> LoopTickOutcome {
        let result: CognitiveReflectionJudgment
        // Bind one checked route for both execution and receipt attribution.
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
            guard let effort = route.reasoningEffort else {
                throw ProviderRoutingError.configurationFailed("Reflection's admitted Think level is unavailable.")
            }
            plannedRequest.reasoningEffort = effort
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
            guard let provider = route.providerId, !provider.isEmpty else {
                throw ProviderRoutingError.configurationFailed("The reflection provider is unavailable.")
            }
            let turn = Turn().with(\.envelope, TurnEnvelope.native("reflection", surface: request.surface))
                .with(\.admission, ModelAdmission(provider: provider, model: route.modelId,
                    reasoningEffort: route.reasoningEffort, serviceTier: route.serviceTier))
            let call = LLMCall(turn: turn, surface: request.surface, purpose: "reflection")
            let raw = try await llm.complete(
                prompt: request.prompt, system: system, model: nil,
                tools: nil, call: call)
            result = try JSONDecoder().decode(CognitiveReflectionJudgment.self, from: Data(raw.utf8))
            try result.validate(material: request.material, cares: request.cares)
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
            retainForDream: retainForDream,
            rejection: "reflection result was not accepted by the substrate",
            persistenceFailure: "reflection judgment or effect settlement remains owed"
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
        retainForDream: Bool = false,
        rejection: String,
        persistenceFailure: String
    ) async -> LoopTickOutcome? {
        await settle { [self] in
            await self.persistReflectionSettlement(request: request, resultSummary: resultSummary,
                judgment: judgment, cancelled: cancelled, retainForDream: retainForDream,
                rejection: rejection, persistenceFailure: persistenceFailure)
        }
    }

    private func persistReflectionSettlement(
        request: CognitiveReflectionRequest, resultSummary: String,
        judgment: CognitiveReflectionJudgment?, cancelled: Bool, retainForDream: Bool,
        rejection: String, persistenceFailure: String
    ) async -> LoopTickOutcome? {
        // Use sensory input's coalesced settlement for internal reflection mutations.
        defer { scheduleDirtyMicrocycle(reason: "reflection_result") }
        guard let receipt = await substrate.recordReflectionResult(
            request: request,
            resultSummary: resultSummary,
            provider: request.provider,
            cancelled: cancelled,
            judgment: judgment,
            journalPending: retainForDream
        ) else { return .failed(error: rejection) }
        do {
            try await substrate.checkpointReflectionResultChecked(receipt)
            if !retainForDream { try await substrate.persistReflectionResultChecked(receipt) }
        } catch {
            // Preserve retained judgment and pending effects across failure.
            return .failed(error: "\(persistenceFailure): \(error.localizedDescription)")
        }
        return nil
    }

    private func cognitiveReflectionSystemPrompt(surface: String) async throws -> String {
        let persona = cognitionPersonaEngine()
        let packet: PersonalityPacket
        do {
            let userMemoryCore = try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot)
                ? try await SwiftNativeMemoryV2.userCoreForBackground(dataRoot: dataRoot)
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
