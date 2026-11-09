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

// Blueprint: | `NativeCognitionRuntime+Organism.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    func startApprovalLifecycleObservationIfNeeded() async {
        guard !isFlushedForTermination, approvalLifecycleObservationTask == nil else { return }
        let stream = await ApprovalLifecycleBus.shared.events()
        guard !isFlushedForTermination, approvalLifecycleObservationTask == nil else { return }
        approvalLifecycleObservationTask = Task { [weak self] in
            // Approval expectations follow both request and decision.
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

    public nonisolated static func careLifeCardCareID(_ record: ApprovalRecord) -> UUID? {
        guard case .object(let payload) = record.payload, case .string(let id)? = payload["careId"] else { return nil }
        return UUID(uuidString: id)
    }

    /// Save an already-life retry before acknowledging approval so live and nightly recovery paths share durable proof.
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

    /// Restore only pending expectations; replaying terminal decisions would create fresh relief.
    /// Preserve correlation across restart and ignore duplicate timestamps.
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
            // Retained continuity already owns a live expectation; replay would inflate evidence and shift its horizon.
            // Rearm only missing or expired rows still pending in the canonical inbox.
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

    /// Ingest notable resolutions directly into substrate, never back through the somatic bus, to prevent a body feedback loop.
    /// Both kernel-feed paths share this source-bounded bridge.
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
                    // Keep distinct felt-event IDs while grouping by path label.
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

    /// Dormant bodies owe no effect; awake bodies acknowledge only durable identity claims so retries cannot sleep twice.
    public func completeDreamSignal(id: UUID, occurredAt: Date, metadata: [String: JSONValue]) async throws -> Bool {
        await bootstrap()
        guard !isFlushedForTermination else {
            throw PersistenceCoreError.ioFailure("dream completion awaits the running mind")
        }
        if let bootstrapFailure { throw PersistenceCoreError.ioFailure(bootstrapFailure) }
        // Dream completion is independent of optional body effects; the journal checkpoint witnesses no-effect settlement.
        if !(await organismKernel.snapshot().enabled) {
            _ = await runEventDrivenReplay(
                reason: "replay_event:\(SomaticSignalKind.dreamCompleted.rawValue)", material: nil)
            return false
        }
        guard !isFlushedForTermination, !organismRestoreFailedHard, organismContinuityReadable else {
            throw PersistenceCoreError.ioFailure("dream completion awaits available body continuity")
        }
        if !(await organismKernel.hasCompletedDream(id)) {
            try Task.checkCancellation()
            let signal = SomaticSignal(id: id, kind: .dreamCompleted, sourceOrgan: "dream",
                occurredAt: occurredAt, intensity: 0.62, valence: 0.35, arousal: 0.12, metadata: metadata)
            // Once admitted, Stop cannot abandon the body mutation's save.
            let saved = await settle { [self] in await self.settleDreamSignal(signal) }
            try saved.get()
        } else {
            guard await persistOrganismContinuity(reason: "dream:\(id.uuidString)") else {
                throw PersistenceCoreError.ioFailure("dream completion body claim is not durable")
            }
        }
        await rescheduleResidualRepairDeadline()
        publishRuntimeChange(reason: "somatic:dreamCompleted")
        _ = await runEventDrivenReplay(reason: "replay_event:dreamCompleted", material: nil)
        return true
    }

    private func settleDreamSignal(_ signal: SomaticSignal) async -> Result<Void, PersistenceCoreError> {
        await organismKernel.ingest(signal, movesFeelings: CognitiveSomaticSignals.movesFeelings(.dreamCompleted))
        await drainFeltResolutionsIntoSubstrate()
        cachedBodyRead = nil
        guard await organismKernel.hasCompletedDream(signal.id),
              await persistOrganismContinuity(reason: "dream:\(signal.id.uuidString)") else {
            return .failure(.ioFailure("dream completion remains owed; body did not persist it"))
        }
        return .success(())
    }

    public func ingestOrganismSignal(
        kind: SomaticSignalKind,
        sourceOrgan: String,
        intensity: Double = 0.5,
        valence: Double? = nil,
        arousal: Double? = nil,
        metadata: [String: JSONValue] = [:],
        reflectionMaterial: [String: CognitiveReflectionCause] = [:],
        persistSynchronously: Bool = true,
        reflectAfterReplay: Bool = true
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
            persistSynchronously: persistSynchronously,
            reflectAfterReplay: reflectAfterReplay
        )
    }

    /// Feed prebuilt vitals signals through the same ordered organism tail as every other body signal.
    func ingestPreparedOrganismSignal(
        _ signal: SomaticSignal,
        reflectionMaterial: [String: CognitiveReflectionCause] = [:],
        persistSynchronously: Bool = true,
        reflectAfterReplay: Bool = true
    ) async {
        await bootstrap()
        await ingestPreparedOrganismSignalAfterBootstrap(
            signal,
            reflectionMaterial: reflectionMaterial,
            persistSynchronously: persistSynchronously,
            reflectAfterReplay: reflectAfterReplay
        )
    }

    private func ingestPreparedOrganismSignalAfterBootstrap(
        _ signal: SomaticSignal,
        reflectionMaterial: [String: CognitiveReflectionCause] = [:],
        persistSynchronously: Bool,
        reflectAfterReplay: Bool = true
    ) async {
        let kind = signal.kind
        await organismKernel.ingest(signal, movesFeelings: CognitiveSomaticSignals.movesFeelings(kind))
        await drainFeltResolutionsIntoSubstrate()
        cachedBodyRead = nil
        if persistSynchronously {
            await persistOrganismContinuity(reason: "somatic:\(kind.rawValue)")
        } else {
            scheduleOrganismContinuityPersistence(reason: "somatic:\(kind.rawValue)")
        }
        await rescheduleResidualRepairDeadline()
        publishRuntimeChange(reason: "somatic:\(kind.rawValue)")
        // Replay follows canonical dream/REM writes and rereads their durable owners; the signal carries no payload.
        // One daily integrity pass covers out-of-process writes and crash-window event loss.
        if kind == .dreamCompleted || kind == .remIntegrated {
            let reason = "replay_event:\(kind.rawValue)"
            // Replay owns flight and terminal accounting; journal acknowledgement prevents duplicate dream reflection.
            _ = await runEventDrivenReplay(reason: reason,
                material: reflectAfterReplay ? reflectionMaterial : nil)
        }
    }

    public func setOrganismKernelEnabled(_ enabled: Bool) async {
        await bootstrap()
        preferenceDefaults.set(enabled, forKey: Self.organismKernelEnabledKey)
        await refreshConfiguration()
        if enabled {
            // Enabling effects cannot reload continuity over the body restored during opening.
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
            mobileConfigured: await checkedPhoneNotificationConfiguration(),
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

    /// Restore a failed reset baseline only while its kernel revision still owns the state, preserving newer events.
    /// Keep substrate and body epochs aligned on every exit so later caring, reaction and correction effects remain admissible.
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
        // Restore before mutation; reset holds the door against folds.
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
        // Reset's new epoch excludes old body effects, never mind effects; failed saves restore damaged-continuity protection.
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

    /// Push quiet-hours invalidation into the body clock; unavailable preferences supply no diurnal input.
    private func refreshOrganismDiurnalClockIfInvalidated(at fixedAt: Date) async {
        guard !isFlushedForTermination, sourceWakes.clockDirty else { return }
        sourceWakes.clockDirty = false
        let window: TurnQuietHoursWindow?
        do { window = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot) }
        catch {
            // Withhold diurnal projection while its preference is unavailable; nil disables this input.
            await organismKernel.configureDiurnalClock(nil)
            return
        }
        await organismKernel.configureDiurnalClock(
            window.flatMap { OrganismDiurnalClock(quietStartHour: $0.startHour, quietEndHour: $0.endHour) }
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
        // Refresh the clock for frozen turn reads as well as background projection.
        await refreshOrganismDiurnalClockIfInvalidated(at: fixedAt)
        var liveRead: OrganismBodyRead
        // Retain the two-second cache only for the composite host/transport gauge, which has no complete push owner.
        if let cached = cachedBodyRead, fixedAt.timeIntervalSince(cached.at) < 2.0 {
            liveRead = cached.read
        } else {
            let phoneDelivery = await organismKernel.latestPrediction(ofKind: .phoneDelivery)
            liveRead = await Self.makeOrganismBodyRead(
                dataRoot: dataRoot,
                mobileConfigured: await checkedPhoneNotificationConfiguration(),
                now: fixedAt,
                phoneDeliveryPrediction: phoneDelivery
            )
            cachedBodyRead = (liveRead, fixedAt)
        }
        if liveRead.providersAvailable == true {
            let providerEvidence = providerPathEvidence(at: fixedAt)
            liveRead.providerPathBelief = ProviderPathBeliefProjector.project(evidence: providerEvidence, now: fixedAt)
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
            // Provider, tool, memory, phone and thermal facts guide operational posture, never feelings.
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
