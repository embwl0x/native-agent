import Foundation
import NativeAgentShared
import MemoryV2
import ApprovalInbox
import AuthoredCapabilities
import ChatTurnRuntime
import CognitiveSubstrate
import Context
import ContextFlow
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import TurnTrace

// Blueprint: | `NativeCognitionRuntime+Organism.swift` | `NativeCognitionRuntime` live organism integration: approval lifecycle expectations, somatic ingestion, felt resolutions and live body projections |

extension NativeCognitionRuntime {
    func startApprovalLifecycleObservationIfNeeded() async {
        guard !isFlushedForTermination, approvalLifecycleObservationTask == nil else { return }
        let stream = await ApprovalLifecycleBus.shared.events()
        guard !isFlushedForTermination, approvalLifecycleObservationTask == nil else { return }
        approvalLifecycleObservationTask = Task { [weak self] in
            // Approval expectations follow the request and the person's decision.
            for await event in stream where event.phase == .requested || event.phase == .resolved {
                guard !Task.isCancelled else { return }
                await self?.ingestApprovalLifecycleEvent(event)
                if event.phase == .resolved, event.record.action == CognitiveSubstrate.careLifeApprovalAction,
                   event.record.decision == "approved" {
                    await self?.applyCareLifeApproval(event.record)
                }
            }
        }
    }

    /// The care a life card names, read from its payload.
    public nonisolated static func careLifeCardCareID(_ record: ApprovalRecord) -> UUID? {
        guard case .object(let payload) = record.payload, case .string(let id)? = payload["careId"] else { return nil }
        return UUID(uuidString: id)
    }

    /// An approved life card: the care becomes part of who she is, and the
    /// approval says so. Called live on the resolution and again by the night
    /// for one the live path missed; an already-life retry saves before acknowledging.
    public func applyCareLifeApproval(_ record: ApprovalRecord) async {
        guard record.decision == "approved", let id = Self.careLifeCardCareID(record) else { return }
        guard await substrateForIntegration().deepenCareToLife(id, source: "approval:\(record.id)") else { return }
        do {
            try await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                record.id, executedAction: .object(["op": .string("care_life"), "careId": .string(id.uuidString),
                                                    "applied": .bool(true)]),
                detail: "It is part of who I am now (life depth).")
        } catch {
            nativeLog("[cares] life card %@ saved but not annotated: %@", record.id, error.localizedDescription)
        }
    }

    /// Restore only still-pending expectations. Old terminal decisions are not
    /// replayed as fresh relief, while a pending approval survives restart as
    /// the same correlated expectation. Duplicate timestamps are ignored by
    /// the predictive ledger.
    func reconcilePendingApprovalExpectationsAtBootstrap() async {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        guard let pending = try? await inbox.list(filter: .pending) else { return }
        for record in pending {
            let source = Self.approvalLifecycleSource(for: record)
            let existing = await organismKernel.prediction(
                ofKind: .approvalResolution,
                sourceOrgan: source,
                correlationID: record.id
            )
            // Continuity already owns this live expectation. Replaying it on
            // every launch would inflate evidence and keep shifting its due
            // horizon. An expired or missing row is re-armed because the
            // canonical inbox still says a human decision is outstanding.
            if existing?.status == .pending { continue }
            await ingestApprovalLifecycleEvent(
                ApprovalLifecycleEvent(phase: .requested, record: record),
                persistSynchronously: false,
                occurredAtOverride: now(),
                bootstrapIfNeeded: false
            )
        }
    }

    private func ingestApprovalLifecycleEvent(
        _ event: ApprovalLifecycleEvent,
        persistSynchronously: Bool = false,
        occurredAtOverride: Date? = nil,
        bootstrapIfNeeded: Bool = true
    ) async {
        guard !isFlushedForTermination else { return }
        let record = event.record
        let timestamp = occurredAtOverride ?? Self.approvalLifecycleDate(
            event.phase == .resolved ? record.resolvedAt : record.createdAt
        ) ?? now()
        let source = Self.approvalLifecycleSource(for: record)
        let signal = SomaticSignal(
            id: UUID(),
            kind: event.phase == .requested ? .approvalRequested : .approvalResolved,
            sourceOrgan: source,
            occurredAt: timestamp,
            intensity: event.phase == .requested ? 0.45 : 0.6,
            valence: event.phase == .resolved ? 0.2 : nil,
            arousal: event.phase == .requested ? 0.4 : nil,
            metadata: [
                "predictionCorrelationId": .string(record.id),
                "approvalAction": .string(record.action),
                "approvalDecision": .string(record.decision ?? "pending"),
            ]
        )
        if bootstrapIfNeeded {
            await ingestPreparedOrganismSignal(
                signal,
                persistSynchronously: persistSynchronously
            )
        } else {
            await ingestPreparedOrganismSignalAfterBootstrap(
                signal,
                persistSynchronously: persistSynchronously
            )
        }
    }

    private nonisolated static func approvalLifecycleDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    private nonisolated static func approvalLifecycleSource(for record: ApprovalRecord) -> String {
        "approval.\(record.action.isEmpty ? "unknown" : record.action)"
    }

    /// Notable resolutions the body just felt (relief /
    /// earned disappointment) become substrate nodes with real aboutness.
    /// Straight into ingestResident — never back through the somatic bus, so
    /// the body can't loop into itself. Rate-bounded at the source; called
    /// from BOTH kernel-feed paths (bus-driven observe + direct injection).
    func drainFeltResolutionsIntoSubstrate() async {
        for felt in await organismKernel.drainResolutionFelt() {
            let isRelief = felt.kind == .relief
            var metadata: [String: JSONValue] = [
                "feltValence": .double(isRelief
                    ? min(0.6, 0.2 + 0.5 * felt.magnitude)
                    : -min(0.6, 0.2 + 0.6 * felt.magnitude)),
                "feltArousal": .double(isRelief ? 0.15 : 0.45),
                "resolutionKind": .string(felt.kind.rawValue),
            ]
            if let scope = felt.semanticScope {
                metadata[OrganismSemanticExpectation.mintMetadataKey] = .object([
                    OrganismSemanticExpectation.sessionField: .string(scope.sessionID),
                    OrganismSemanticExpectation.turnField: .string(scope.turnID),
                ])
            }
            let feltEvent = CognitiveEvent(
                id: UUID().uuidString,
                kind: .organismResolutionFelt,
                subject: CognitiveSubjectReference(
                    type: "organism_path",
                    // Distinct IDs retain each felt moment; the label groups its path.
                    id: "\(felt.sourceOrgan)#\(UUID().uuidString.prefix(8))",
                    label: felt.pathKind.rawValue
                ),
                sourceClass: .observed,
                occurredAt: felt.occurredAt,
                summary: isRelief
                    ? "Relief — the \(felt.sourceOrgan) path I was braced for landed fine."
                    : "Disappointment — the \(felt.sourceOrgan) path I was counting on fell through.",
                importance: 0.65,
                metadata: metadata
            )
            if await substrate.ingestResident(feltEvent).accepted {
                scheduleDirtyMicrocycle(
                    reason: "felt_resolution:\(felt.kind.rawValue)"
                )
            }
        }
    }

    public func ingestOrganismSignal(
        kind: SomaticSignalKind,
        sourceOrgan: String,
        intensity: Double = 0.5,
        valence: Double? = nil,
        arousal: Double? = nil,
        metadata: [String: JSONValue] = [:],
        reflectionMaterial: [String: CognitiveReflectionCause] = [:],
        persistSynchronously: Bool = true
    ) async {
        let signal = SomaticSignal(
            id: UUID(),
            kind: kind,
            sourceOrgan: sourceOrgan,
            occurredAt: now(),
            intensity: intensity,
            valence: valence,
            arousal: arousal,
            metadata: metadata
        )
        await ingestPreparedOrganismSignal(
            signal,
            reflectionMaterial: reflectionMaterial,
            persistSynchronously: persistSynchronously
        )
    }

    /// Ingest a PRE-BUILT somatic signal — the seam the INTEROCEPTION vitals path
    /// uses so a `.providerVitalsShift` CognitiveEvent can be mapped by
    /// `CognitiveSomaticSignals` (the design's required path) and the
    /// resulting graded signal ride the exact same organism tail as every other
    /// body signal.
    func ingestPreparedOrganismSignal(
        _ signal: SomaticSignal,
        reflectionMaterial: [String: CognitiveReflectionCause] = [:],
        persistSynchronously: Bool = true
    ) async {
        await bootstrap()
        await ingestPreparedOrganismSignalAfterBootstrap(
            signal,
            reflectionMaterial: reflectionMaterial,
            persistSynchronously: persistSynchronously
        )
    }

    private func ingestPreparedOrganismSignalAfterBootstrap(
        _ signal: SomaticSignal,
        reflectionMaterial: [String: CognitiveReflectionCause] = [:],
        persistSynchronously: Bool
    ) async {
        let kind = signal.kind
        await organismKernel.ingest(signal, movesFeelings: CognitiveSomaticSignals.movesFeelings(kind))
        // A committed diary is a new Reach source even after a clean scan.
        if kind == .dreamCompleted { sourceWakes.reachDirty = true }
        await drainFeltResolutionsIntoSubstrate()
        cachedBodyRead = nil
        if persistSynchronously {
            await persistOrganismContinuity(reason: "somatic:\(kind.rawValue)")
        } else {
            scheduleOrganismContinuityPersistence(reason: "somatic:\(kind.rawValue)")
        }
        await rescheduleResidualRepairDeadline()
        publishRuntimeChange(reason: "somatic:\(kind.rawValue)")
        // Clause 4: replay is tissue downstream of the canonical dream/REM
        // write, not an hourly poll pretending to notice it. The somatic signal
        // contains no replay payload; runReplay rereads the exact injected-root
        // diary/proposal owners and their durable evidence IDs. The manifest
        // retains one slow daily integrity sweep for out-of-process writes and
        // crash-window event loss.
        if kind == .dreamCompleted || kind == .remIntegrated {
            let reason = "replay_event:\(kind.rawValue)"
            let outcome = await runEventDrivenReplayWithDeadline(reason: reason)
            await handleEventDrivenReplayOutcome(outcome, reason: reason, allowRetry: true)
            await reportLoopOutcome(loopId: "cognition_replay", outcome: outcome)
            // Reflection follows the same commit signal, AFTER the replay
            // await above so it reflects on post-replay substrate state. Fire-
            // and-forget after the previous flight; budget gates stay inside.
            await scheduleEventDrivenReflection(reason: "reflection_event:\(kind.rawValue)", material: reflectionMaterial)
        }
    }

    public func setOrganismKernelEnabled(_ enabled: Bool) async {
        await bootstrap()
        preferenceDefaults.set(enabled, forKey: Self.organismKernelEnabledKey)
        await refreshConfiguration()
        if enabled {
            // The body was restored at the opening whether or not its effects
            // were on (dormant); enabling never reloads the file over it.
            await refreshOrganismBodySchema(reason: "enabled")
            await persistOrganismContinuity(reason: "enabled")
        }
        await rescheduleResidualRepairDeadline()
        publishRuntimeChange(reason: "configuration:organism")
    }

    public func setOrganismDebugBodyOverride(
        scenario rawScenario: String,
        ttlSeconds: TimeInterval = 120
    ) async throws -> OrganismSnapshot {
        let normalized = rawScenario.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let scenario = OrganismDebugBodyScenario(rawValue: normalized) else {
            throw OrganismDebugBodyOverrideError.unknownScenario(rawScenario)
        }
        let ttl = min(600, max(5, ttlSeconds))
        organismDebugBodyOverride = OrganismDebugBodyOverride(
            scenario: scenario,
            expiresAt: Date().addingTimeInterval(ttl)
        )
        await refreshOrganismBodySchema(reason: "debug override")
        let snapshot = await organismKernel.snapshot()
        publishRuntimeChange(reason: "organism:debug_override")
        return snapshot
    }

    public func clearOrganismDebugBodyOverride() async -> OrganismSnapshot {
        organismDebugBodyOverride = nil
        let phoneDelivery = await organismKernel.latestPrediction(ofKind: .phoneDelivery)
        let liveRead = await Self.makeOrganismBodyRead(
            dataRoot: dataRoot,
            mobileConfigured: (try? await host.phoneNotificationTargetCount(dataRoot: dataRoot)).map { $0 > 0 } == true,
            phoneDeliveryPrediction: phoneDelivery
        )
        await organismKernel.refreshBodySchema(liveRead, integratesChemistry: false)
        let snapshot = await organismKernel.snapshot()
        publishRuntimeChange(reason: "organism:debug_override_cleared")
        return snapshot
    }

    public func organismDebugBodyOverrideStatus() async -> OrganismDebugBodyOverrideStatus? {
        guard let override = activeOrganismDebugBodyOverride(now: Date()) else { return nil }
        return OrganismDebugBodyOverrideStatus(
            scenario: override.scenario,
            expiresAt: override.expiresAt
        )
    }

    public func organismSnapshot() async -> OrganismSnapshot {
        await refreshOrganismBodySchema(reason: "snapshot")
        return await organismKernel.snapshot()
    }

    public func organismBehaviorPosture() async -> OrganismBehaviorPosture? {
        await refreshOrganismBodySchema(reason: "behavior posture")
        return await organismKernel.behaviorPosture()
    }

    /// A failed reset restores its baseline only while it still owns the
    /// kernel revision. Newer events survive a partial persistence failure.
    /// The substrate stamps turns with the body's epoch; it follows the kernel
    /// on every exit of reset, settle and clear, so a failed or rolled-back
    /// forgetting can never leave the two disagreeing (which would refuse
    /// every later caring dose, reaction and correction cause).
    func syncBodyEpoch() async {
        let read = await organismKernel.epochAtRevision()
        await substrate.adoptBodyEpoch(read.epoch, revision: read.revision)
    }

    public func resetOrganismContinuityChecked() async -> OrganismContinuityApplyOutcome {
        await applyOrganismContinuityChecked(reset: true)
    }

    public func settleOrganismContinuityChecked() async -> OrganismContinuityApplyOutcome {
        await applyOrganismContinuityChecked(reset: false)
    }

    private func applyOrganismContinuityChecked(reset: Bool) async -> OrganismContinuityApplyOutcome {
        let outcome = await applyOrganismContinuity(reset: reset)
        await syncBodyEpoch()
        return outcome
    }

    private func applyOrganismContinuity(reset: Bool) async -> OrganismContinuityApplyOutcome {
        // Restore precedes mutation; reset alone holds the door against folds.
        await bootstrap()
        if reset { await enterDoor() }
        defer { if reset { leaveDoor() } }
        guard let mutation = await organismKernel.beginContinuityMutation(reset: reset) else {
            return OrganismContinuityApplyOutcome(
                status: .organismDisabled,
                snapshot: await organismKernel.snapshot(),
                error: "The organism kernel is disabled."
            )
        }
        // Reset's new body epoch refuses old in-flight body effects, not mind effects.
        // Only reset may replace damaged continuity; a failed save restores its freeze.
        let wasRestoreFrozen = organismRestoreFailedHard
        if reset { organismRestoreFailedHard = false }
        let action = reset ? "reset" : "settle"
        guard await persistOrganismContinuity(reason: action) else {
            if reset { organismRestoreFailedHard = wasRestoreFrozen }
            let restored = await organismKernel.rollbackContinuityMutation(mutation)
            return OrganismContinuityApplyOutcome(
                status: .persistenceFailed,
                snapshot: await organismKernel.snapshot(),
                error: restored
                    ? "The \(action) was not saved; the previous organism state was restored."
                    : "The \(action) was not saved completely; newer organism events were preserved."
            )
        }
        if reset {
            lastInjectedBodyLine = nil
            lastInjectedBodyLineAt = nil
            organismRestoreFailedHard = false
        }
        let snapshot = await organismKernel.snapshot()
        publishRuntimeChange(reason: reset ? "organism:reset" : "organism:settled")
        return OrganismContinuityApplyOutcome(status: .applied, snapshot: snapshot, error: nil)
    }

    /// Preference/clock invalidation pushes the turn engine's quiet-hours window
    /// into the body clock; a missing window retains the default 4 AM trough.
    private func refreshOrganismDiurnalClockIfInvalidated(at fixedAt: Date) async {
        guard !isFlushedForTermination, sourceWakes.clockDirty else { return }
        sourceWakes.clockDirty = false
        let window = TurnQuietHoursWindow.read(dataRoot: dataRoot)
        await organismKernel.configureDiurnalClock(
            OrganismDiurnalClock(
                quietStartHour: window?.startHour,
                quietEndHour: window?.endHour
            )
        )
    }

    func refreshOrganismBodySchema(reason _: String) async {
        let fixedAt = now()
        let sample = await organismBodySample(at: fixedAt)
        let canonicalAffect = await substrate.canonicalAffectProjection(at: fixedAt)
        await organismKernel.refreshBodySchema(
            sample,
            integratesChemistry: false,
            canonicalAffect: canonicalAffect
        )
    }

    func organismBodySample(at fixedAt: Date) async -> OrganismBodyRead {
        // The frozen per-turn read (`refreshBodySchemaAndFrozenRead`) enters
        // here too, so the clock is fresh for the capsule as well as for the
        // background refresh above.
        await refreshOrganismDiurnalClockIfInvalidated(at: fixedAt)
        var liveRead: OrganismBodyRead
        // This composite host/transport gauge has no complete push owner. Keep
        // its two-second sampled cache; source-owned preferences
        // above no longer rescan on this cadence.
        if let cached = cachedBodyRead, fixedAt.timeIntervalSince(cached.at) < 2.0 {
            liveRead = cached.read
        } else {
            let phoneDelivery = await organismKernel.latestPrediction(ofKind: .phoneDelivery)
            liveRead = await Self.makeOrganismBodyRead(
                dataRoot: dataRoot,
                mobileConfigured: (try? await host.phoneNotificationTargetCount(dataRoot: dataRoot)).map { $0 > 0 } == true,
                now: fixedAt,
                phoneDeliveryPrediction: phoneDelivery
            )
            cachedBodyRead = (liveRead, fixedAt)
        }
        if liveRead.providersAvailable == true {
            let providerEvidence = providerPathEvidence(at: fixedAt)
            liveRead.providerPathBelief = if providerEvidence.isEmpty {
                Self.providerCapabilityFallbackProjection(
                    await organismKernel.capabilityBelief(ofKind: .providerCompletion),
                    now: fixedAt
                ) ?? ProviderPathBeliefProjector.project(evidence: [], now: fixedAt)
            } else {
                ProviderPathBeliefProjector.project(evidence: providerEvidence, now: fixedAt)
            }
        } else {
            liveRead.providerPathBelief = nil
        }
        if let override = organismDebugBodyOverride, override.expiresAt > fixedAt {
            return Self.simulatedOrganismBodyRead(
                base: liveRead,
                scenario: override.scenario,
                now: fixedAt
            )
        } else {
            organismDebugBodyOverride = nil
            // Provider, tool, memory, phone and thermal facts are
            // health for the ops posture, never a feeling.
            return liveRead
        }
    }

    private func activeOrganismDebugBodyOverride(now: Date) -> OrganismDebugBodyOverride? {
        guard let override = organismDebugBodyOverride else { return nil }
        guard override.expiresAt > now else {
            organismDebugBodyOverride = nil
            return nil
        }
        return override
    }
}
