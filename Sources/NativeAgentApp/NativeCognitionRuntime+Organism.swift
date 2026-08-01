// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

extension NativeCognitionRuntime {
    /// Round 3 Wave A2: notable resolutions the body just felt (relief /
    /// earned disappointment) become substrate nodes with real aboutness.
    /// Straight into ingestResident — never back through the somatic bus, so
    /// the body can't loop into itself. Rate-bounded at the source; called
    /// from BOTH kernel-feed paths (bus-driven observe + direct injection).
    func drainFeltResolutionsIntoSubstrate() async {  // internal for actor extensions (move-only Wave C)
        for felt in await organismKernel.drainResolutionFelt() {
            let isRelief = felt.kind == .relief
            let feltEvent = CognitiveEvent(
                id: UUID().uuidString,
                kind: .organismResolutionFelt,
                subject: CognitiveSubjectReference(
                    type: "organism_path",
                    // Distinct id per felt moment: subject-keyed nodes would
                    // otherwise COLLAPSE repeated feelings about one path into
                    // a single re-activated node (the audit-C2 class), and the
                    // A3 pattern read counts moments. The path grouping rides
                    // the label.
                    id: "\(felt.sourceOrgan)#\(UUID().uuidString.prefix(8))",
                    label: felt.pathKind.rawValue
                ),
                sourceClass: .observed,
                occurredAt: felt.occurredAt,
                summary: isRelief
                    ? "Relief — the \(felt.sourceOrgan) path I was braced for landed fine."
                    : "Disappointment — the \(felt.sourceOrgan) path I was counting on fell through.",
                importance: 0.65,
                metadata: [
                    "feltValence": .double(isRelief
                        ? min(0.6, 0.2 + 0.5 * felt.magnitude)
                        : -min(0.6, 0.2 + 0.6 * felt.magnitude)),
                    "feltArousal": .double(isRelief ? 0.15 : 0.45),
                    "resolutionKind": .string(felt.kind.rawValue),
                ]
            )
            if await substrate.ingestResident(feltEvent) {
                scheduleDirtyMicrocycle(
                    reason: "felt_resolution:\(felt.kind.rawValue)",
                    turnClass: InstalledPhysiologySoakRecorder.physiologyTurnClass(feltEvent.turnKind)
                )
            }
        }
    }

    func ingestOrganismSignal(
        kind: SomaticSignalKind,
        sourceOrgan: String,
        intensity: Double = 0.5,
        valence: Double? = nil,
        arousal: Double? = nil,
        metadata: [String: JSONValue] = [:],
        persistSynchronously: Bool = true,
        prewarmContext: Bool = true
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
            persistSynchronously: persistSynchronously,
            prewarmContext: prewarmContext
        )
    }

    /// Ingest a PRE-BUILT somatic signal — the seam the INTEROCEPTION vitals path
    /// uses so a `.providerVitalsShift` CognitiveEvent can be mapped by
    /// `CognitiveSomaticSignalAdapter` (the design's required path) and the
    /// resulting graded signal ride the exact same organism tail as every other
    /// body signal.
    func ingestPreparedOrganismSignal(
        _ signal: SomaticSignal,
        persistSynchronously: Bool = true,
        prewarmContext: Bool = true
    ) async {
        await bootstrap()
        let kind = signal.kind
        await organismKernel.ingest(signal)
        await drainFeltResolutionsIntoSubstrate()
        cachedBodyRead = nil
        if persistSynchronously {
            await persistOrganismContinuity(reason: "somatic:\(kind.rawValue)")
        } else {
            scheduleOrganismContinuityPersistence(reason: "somatic:\(kind.rawValue)")
        }
        await rescheduleResidualRepairDeadline()
        publishRuntimeChange(reason: "somatic:\(kind.rawValue)")
        if prewarmContext && usesLiveAppBody {
            Task {
                await NativeContextFlowRuntime.shared.prewarm(
                    kind: .organism,
                    id: signal.id.uuidString,
                    terms: [kind.rawValue, signal.sourceOrgan] + signal.metadata.keys.sorted()
                )
            }
        }
        // Clause 4: replay is tissue downstream of the canonical dream/REM
        // write, not an hourly poll pretending to notice it. The somatic signal
        // contains no replay payload; runReplay rereads the exact injected-root
        // diary/proposal owners and their durable evidence IDs. The manifest
        // retains one slow daily integrity sweep for out-of-process writes and
        // crash-window event loss.
        if kind == .dreamCompleted || kind == .remIntegrated {
            eventDrivenReplayAttemptCount &+= 1
            let reason = "replay_event:\(kind.rawValue)"
            let outcome = await runEventDrivenReplayWithDeadline(reason: reason)
            await handleEventDrivenReplayOutcome(outcome, reason: reason, allowRetry: true)
            // A4.6: reflection follows the same commit signal, AFTER the replay
            // await above so it reflects on post-replay substrate state. Fire-
            // and-forget with its own single-flight; budget gates stay inside.
            scheduleEventDrivenReflection(reason: "reflection_event:\(kind.rawValue)")
        }
    }

    /// Deterministic visibility for the bounded organism persistence lane.
    /// Production has no caller; accelerated tests use it to prove that a
    /// blocked writer still owns only one drain and one coalesced generation.
    func organismPersistenceStatusForProof() -> (
        requestedGeneration: UInt64,
        completedGeneration: UInt64,
        drainActive: Bool
    ) {
        (
            requestedGeneration: organismPersistenceRequestedGeneration,
            completedGeneration: organismPersistenceCompletedGeneration,
            drainActive: organismPersistenceDrainTask != nil
        )
    }

    /// Durability barrier for work already accepted by the test runtime. It
    /// does not enqueue a synthetic write or create another generation.
    func flushOrganismPersistenceForProof() async -> Bool {
        guard microcycleSchedulingMode == .manuallyFlushed else { return false }
        let generation = organismPersistenceRequestedGeneration
        guard generation > 0 else { return true }
        return await awaitOrganismContinuityPersistence(through: generation)
    }

    func setOrganismKernelEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.organismKernelEnabledKey)
        await refreshConfiguration()
        if enabled {
            organismContinuityRestored = false
            await restoreOrganismContinuityIfAvailable()
            await refreshOrganismBodySchema(reason: "enabled")
            await persistOrganismContinuity(reason: "enabled")
        }
        await rescheduleResidualRepairDeadline()
        publishRuntimeChange(reason: "configuration:organism")
    }

    func setOrganismDebugBodyOverride(
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

    func clearOrganismDebugBodyOverride() async -> OrganismSnapshot {
        organismDebugBodyOverride = nil
        let phoneDelivery = await organismKernel.latestPrediction(ofKind: .phoneDelivery)
        let liveRead = Self.makeOrganismBodyRead(
            dataRoot: dataRoot,
            phoneDeliveryPrediction: phoneDelivery
        )
        await organismKernel.refreshBodySchema(liveRead, integratesChemistry: false)
        let snapshot = await organismKernel.snapshot()
        publishRuntimeChange(reason: "organism:debug_override_cleared")
        return snapshot
    }

    func organismDebugBodyOverrideStatus() async -> OrganismDebugBodyOverrideStatus? {
        guard let override = activeOrganismDebugBodyOverride(now: Date()) else { return nil }
        return OrganismDebugBodyOverrideStatus(
            scenario: override.scenario,
            expiresAt: override.expiresAt
        )
    }

    func organismSnapshot() async -> OrganismSnapshot {
        await refreshOrganismBodySchema(reason: "snapshot")
        return await organismKernel.snapshot()
    }

    func organismBehaviorPosture() async -> OrganismBehaviorPosture? {
        await refreshOrganismBodySchema(reason: "behavior posture")
        return await organismKernel.behaviorPosture()
    }

    func resetOrganismContinuity() async -> OrganismSnapshot {
        await organismKernel.clearTransientState()
        lastInjectedBodyLine = nil
        lastInjectedBodyLineAt = nil
        try? FileManager.default.removeItem(at: organismPersistentStateURL)
        // Audit C1 follow-up: removing the (possibly bad) state file clears the
        // failed-restore freeze — fresh state may persist again.
        organismRestoreFailedHard = false
        await persistOrganismContinuity(reason: "reset")
        let snapshot = await organismKernel.snapshot()
        publishRuntimeChange(reason: "organism:reset")
        return snapshot
    }

    func settleOrganismContinuity() async -> OrganismSnapshot {
        await organismKernel.settleContinuity()
        await persistOrganismContinuity(reason: "settle")
        let snapshot = await organismKernel.snapshot()
        publishRuntimeChange(reason: "organism:settled")
        return snapshot
    }

    func reviewOrganismReflexCandidate(
        id: String,
        decision: OrganismReflexReviewDecision,
        note: String? = nil,
        reviewedBy: String = "operator",
        source: String = "runtime"
    ) async -> OrganismSnapshot {
        await applyOrganismReflexReview(
            id: id,
            decision: decision,
            note: note,
            reviewedBy: reviewedBy,
            source: source
        ).snapshot
    }

    func applyOrganismReflexReview(
        id: String,
        decision: OrganismReflexReviewDecision,
        note: String? = nil,
        reviewedBy: String,
        source: String
    ) async -> OrganismReflexReviewApplyOutcome {
        let beforeSnapshot = await organismKernel.snapshot()
        guard beforeSnapshot.enabled,
              let beforeState = await organismKernel.exportPersistentState()
        else {
            return OrganismReflexReviewApplyOutcome(
                status: .organismDisabled,
                snapshot: beforeSnapshot,
                candidate: nil,
                receipt: nil,
                error: "The organism kernel is disabled."
            )
        }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidateBefore = beforeSnapshot.reflexCandidates.first(where: { $0.id == normalizedID }) else {
            return OrganismReflexReviewApplyOutcome(
                status: .candidateNotFound,
                snapshot: beforeSnapshot,
                candidate: nil,
                receipt: nil,
                error: "No active reflex candidate matched \(normalizedID)."
            )
        }
        guard decision != .approve || candidateBefore.trustClass == .lowRisk else {
            return OrganismReflexReviewApplyOutcome(
                status: .approvalRequiresLowRisk,
                snapshot: beforeSnapshot,
                candidate: candidateBefore,
                receipt: nil,
                error: "Only low-risk reflex candidates can be approved."
            )
        }
        guard let application = await organismKernel.reviewReflexCandidate(
            id: normalizedID,
            decision: decision,
            note: note,
            reviewedBy: reviewedBy,
            source: source
        ) else {
            return OrganismReflexReviewApplyOutcome(
                status: .candidateNotFound,
                snapshot: beforeSnapshot,
                candidate: nil,
                receipt: nil,
                error: "The reflex candidate is no longer reviewable."
            )
        }

        let persisted = await persistOrganismContinuity(reason: "reflex:\(decision.rawValue)")
        guard persisted else {
            await organismKernel.restorePersistentState(beforeState)
            return OrganismReflexReviewApplyOutcome(
                status: .persistenceFailed,
                snapshot: await organismKernel.snapshot(),
                candidate: candidateBefore,
                receipt: nil,
                error: "The reflex review could not be persisted; the in-memory change was rolled back."
            )
        }

        await substrate.recordReceipt(
            kind: "organism.reflex_review",
            payload: .object([
                "receiptId": .string(application.receipt.id),
                "candidateId": .string(application.receipt.candidateID),
                "decision": .string(application.receipt.decision.rawValue),
                "reviewedBy": .string(application.receipt.reviewedBy),
                "source": .string(application.receipt.source),
                "trustClass": .string(application.receipt.trustClass.rawValue),
                "autoActivationAllowed": .bool(application.receipt.autoActivationAllowed),
                "permanentlyDeliberate": .bool(application.receipt.permanentlyDeliberate),
            ])
        )
        publishRuntimeChange(reason: "organism:reflex_review")
        return OrganismReflexReviewApplyOutcome(
            status: .applied,
            snapshot: await organismKernel.snapshot(),
            candidate: application.candidate,
            receipt: application.receipt,
            error: nil
        )
    }

    struct OrganismBodySample {  // internal for actor extensions (move-only Wave C)
        let read: OrganismBodyRead
        let integratesChemistry: Bool
    }

    func refreshOrganismBodySchema(reason _: String) async {  // internal for actor extensions (move-only Wave C)
        let fixedAt = now()
        let sample = await organismBodySample(at: fixedAt)
        let canonicalAffect = await substrate.canonicalAffectProjection(at: fixedAt)
        await organismKernel.refreshBodySchema(
            sample.read,
            integratesChemistry: sample.integratesChemistry,
            canonicalAffect: canonicalAffect
        )
    }

    func organismBodySample(at fixedAt: Date) async -> OrganismBodySample {  // internal for actor extensions (move-only Wave C)
        var liveRead: OrganismBodyRead
        if let cached = cachedBodyRead, fixedAt.timeIntervalSince(cached.at) < 2.0 {
            liveRead = cached.read
        } else {
            let phoneDelivery = await organismKernel.latestPrediction(ofKind: .phoneDelivery)
            liveRead = Self.makeOrganismBodyRead(
                dataRoot: dataRoot,
                now: fixedAt,
                phoneDeliveryPrediction: phoneDelivery
            )
            cachedBodyRead = (liveRead, fixedAt)
        }
        if liveRead.providersAvailable == true {
            liveRead.providerPathBelief = ProviderPathBeliefProjector.project(
                evidence: providerPathEvidence(at: fixedAt),
                now: fixedAt
            )
            // Availability is exact configuration truth; health is derived
            // exclusively from the lifecycle belief above.
            liveRead.providersHealthy = nil
        } else {
            liveRead.providerPathBelief = nil
            liveRead.providersHealthy = false
        }
        let read: OrganismBodyRead
        let integratesChemistry: Bool
        if let override = organismDebugBodyOverride, override.expiresAt > fixedAt {
            read = Self.simulatedOrganismBodyRead(
                base: liveRead,
                scenario: override.scenario,
                now: fixedAt
            )
            integratesChemistry = false
        } else {
            if organismDebugBodyOverride != nil {
                organismDebugBodyOverride = nil
                integratesChemistry = false
            } else {
                integratesChemistry = true
            }
            read = liveRead
        }
        return OrganismBodySample(read: read, integratesChemistry: integratesChemistry)
    }

    private func activeOrganismDebugBodyOverride(now: Date) -> OrganismDebugBodyOverride? {
        guard let override = organismDebugBodyOverride else { return nil }
        guard override.expiresAt > now else {
            organismDebugBodyOverride = nil
            return nil
        }
        return override
    }

    private var organismPersistentStateURL: URL {
        dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
    }

    func restoreOrganismContinuityIfAvailable() async {  // internal for actor extensions (move-only Wave C)
        guard !organismContinuityRestored else { return }
        organismContinuityRestored = true
        let url = organismPersistentStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(OrganismPersistentState.self, from: data)
            await organismKernel.restorePersistentState(state)
            // Audit C1 follow-up (gpt-5.5 MED): a clean decode UNFREEZES organism
            // persistence — a prior failure must not block writes forever once a
            // good restore (or reset) has run.
            organismRestoreFailedHard = false
            await substrate.recordReceipt(
                kind: "organism.restore",
                payload: .object([
                    "path": .string("cognition/organism_state.json"),
                    "schemaVersion": .int(Int64(state.schemaVersion)),
                    "signalCount": .int(Int64(state.signalCount)),
                ])
            )
        } catch {
            // Audit C1 (2026-07-09): a failed decode must FREEZE organism persistence
            // for the session — persistOrganismContinuity would otherwise overwrite
            // organism_state.json with freshly-initialized state, destroying the very
            // continuity this receipt is warning about.
            organismRestoreFailedHard = true
            await substrate.recordReceipt(
                kind: "organism.restore_failed",
                payload: .object([
                    "path": .string("cognition/organism_state.json"),
                    "error": .string(String(describing: error)),
                ])
            )
        }
    }

    @discardableResult
    func persistOrganismContinuity(reason: String) async -> Bool {  // internal for actor extensions (move-only Wave C)
        guard let generation = scheduleOrganismContinuityPersistence(reason: reason) else {
            return false
        }
        return await awaitOrganismContinuityPersistence(through: generation)
    }

    /// Advances the desired durable generation without suspending the caller.
    /// The actor owns exactly one drain task regardless of event burst size.
    @discardableResult
    func scheduleOrganismContinuityPersistence(reason: String) -> UInt64? {  // internal for actor extensions (move-only Wave C)
        // Never write through a failed restore (audit C1) — memory-only until a clean boot.
        guard !organismRestoreFailedHard else { return nil }
        organismPersistenceRequestedGeneration &+= 1
        organismPersistenceLatestReason = String(reason.prefix(120))
        if organismPersistenceDrainTask == nil {
            organismPersistenceDrainTask = Task { [weak self] in
                await self?.drainOrganismContinuityPersistence()
            }
        }
        return organismPersistenceRequestedGeneration
    }

    private func awaitOrganismContinuityPersistence(through generation: UInt64) async -> Bool {
        if organismPersistenceCompletedGeneration >= generation {
            return organismPersistenceLastResult
        }
        return await withCheckedContinuation { continuation in
            organismPersistenceWaiters[generation, default: []].append(continuation)
        }
    }

    /// Serial latest-state drain. If more events arrive while a write is in
    /// flight, they coalesce into one subsequent export/write instead of
    /// allocating one task and one snapshot per event.
    private func drainOrganismContinuityPersistence() async {
        while !Task.isCancelled {
            guard organismPersistenceCompletedGeneration < organismPersistenceRequestedGeneration else {
                organismPersistenceDrainTask = nil
                return
            }
            let generation = organismPersistenceRequestedGeneration
            let reason = organismPersistenceLatestReason
            let succeeded = await writeOrganismContinuitySnapshot(reason: reason)
            organismPersistenceCompletedGeneration = generation
            organismPersistenceLastResult = succeeded
            resumeOrganismPersistenceWaiters(through: generation, result: succeeded)
        }
        organismPersistenceDrainTask = nil
        resumeOrganismPersistenceWaiters(
            through: organismPersistenceRequestedGeneration,
            result: false
        )
    }

    private func resumeOrganismPersistenceWaiters(through generation: UInt64, result: Bool) {
        let completed = organismPersistenceWaiters.keys.filter { $0 <= generation }
        for key in completed {
            let continuations = organismPersistenceWaiters.removeValue(forKey: key) ?? []
            for continuation in continuations {
                continuation.resume(returning: result)
            }
        }
    }

    private func writeOrganismContinuitySnapshot(reason: String) async -> Bool {
        guard let state = await organismKernel.exportPersistentState() else { return false }
        do {
            let url = organismPersistentStateURL
            if let organismPersistenceWriterOverride {
                try await organismPersistenceWriterOverride(state, url)
            } else {
                try await Self.writeOrganismPersistentState(state, to: url)
            }
            return true
        } catch {
            await substrate.recordReceipt(
                kind: "organism.persist_failed",
                payload: .object([
                    "reason": .string(String(reason.prefix(120))),
                    "path": .string("cognition/organism_state.json"),
                    "error": .string(String(describing: error)),
                ])
            )
            return false
        }
    }

    /// Encoding and filesystem work run outside the cognition actor. Awaiting
    /// this detached job keeps write ordering in the sole drain while allowing
    /// new sensory events to enter the actor during a slow disk operation.
    private nonisolated static func writeOrganismPersistentState(
        _ state: OrganismPersistentState,
        to url: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        }.value
    }

    nonisolated static func makeOrganismBodyRead(
        dataRoot: URL,
        now: Date = Date(),
        phoneDeliveryPrediction: OrganismPrediction? = nil
    ) -> OrganismBodyRead {
        let signedPeer = SignedPeerEvidenceStore.load(dataRoot: dataRoot)
        let mobileLastSeen = signedPeer?.observedAt
        let mobileConfigured = hasReadableContent(
            dataRoot.appendingPathComponent("mobile_push", isDirectory: true).appendingPathComponent("tokens.json")
        ) || hasReadableContent(
            dataRoot.appendingPathComponent("notifications", isDirectory: true).appendingPathComponent("push_tokens.json")
        )
        let staleAfter: TimeInterval = 60 * 60 * 36
        let peerPresenceBelief = PeerPresenceBelief(
            generatedAt: now,
            evidence: signedPeer.map {
                [BodyEvidenceReference(
                    id: "signed-peer:\($0.eventID)",
                    evidenceClass: .signedPeerContact,
                    observedAt: $0.peerCreatedAt,
                    // Only this post-HMAC local observation controls freshness.
                    receivedAt: $0.observedAt
                )]
            } ?? [],
            staleAfter: staleAfter
        )
        let notificationDeliveryBelief = notificationDeliveryReading(
            dataRoot: dataRoot,
            now: now,
            configured: mobileConfigured,
            staleAfter: staleAfter,
            phoneDeliveryPrediction: phoneDeliveryPrediction
        )
        let memoryIntegrityReading = makeMemoryIntegrityReading(dataRoot: dataRoot, now: now)
        let dreamIntegrityReading = makeDreamIntegrityReading(dataRoot: dataRoot, now: now)
        let toolCapabilityReading = makeToolCapabilityReading(dataRoot: dataRoot, now: now)
        let approvalPathReading = makeApprovalPathReading(dataRoot: dataRoot, now: now)
        let resourcePressureReading = currentResourcePressureReading(dataRoot: dataRoot, now: now)

        let providersAvailable = hasAnyUsableProvider(dataRoot: dataRoot)
        return OrganismBodyRead(
            macAwake: true,
            iPhoneReachable: peerPresenceBelief.compatibilityReachable,
            iPhoneLastSeenAt: mobileLastSeen,
            iPhoneStaleAfter: staleAfter,
            providersHealthy: nil,
            providersAvailable: providersAvailable,
            peerPresenceBelief: peerPresenceBelief,
            notificationDeliveryBelief: notificationDeliveryBelief,
            memoryIntegrityReading: memoryIntegrityReading,
            dreamIntegrityReading: dreamIntegrityReading,
            toolCapabilityReading: toolCapabilityReading,
            approvalPathReading: approvalPathReading,
            resourcePressureReading: resourcePressureReading,
            memoryHealthy: memoryIntegrityReading.compatibilityHealthy,
            dreamHealthy: dreamIntegrityReading.compatibilityHealthy,
            toolHandsAvailable: toolCapabilityReading.compatibilityAvailable,
            approvalChannelsOpen: approvalPathReading.compatibilityOpen,
            notificationPathHealthy: notificationDeliveryBelief.compatibilityPathHealthy
                ?? peerPresenceBelief.compatibilityReachable,
            resourcePressure: resourcePressureReading.category
        )
    }

    nonisolated static func simulatedOrganismBodyRead(
        base: OrganismBodyRead,
        scenario: OrganismDebugBodyScenario,
        now: Date = Date()
    ) -> OrganismBodyRead {
        var read = base
        switch scenario {
        case .providerBrittle:
            read.providersHealthy = false
            read.toolHandsAvailable = false
            read.providerPathBelief = ProviderPathBeliefProjection(
                generatedAt: now,
                estimate: 0.05,
                freshness: 1,
                uncertainty: 0,
                evidenceCount: 1,
                newestEvidenceAt: now,
                state: .brittle,
                bodySchemaProvidersHealthy: false
            )
            read.toolCapabilityReading = ToolCapabilityReading(
                generatedAt: now,
                configured: false,
                liveCapabilityObserved: false,
                evidence: []
            )
        case .stalePhone:
            read.iPhoneReachable = false
            read.iPhoneLastSeenAt = now.addingTimeInterval(-(read.iPhoneStaleAfter + 60))
            read.notificationPathHealthy = false
            let staleAt = now.addingTimeInterval(-(read.iPhoneStaleAfter + 60))
            read.peerPresenceBelief = PeerPresenceBelief(
                generatedAt: now,
                evidence: [BodyEvidenceReference(
                    id: "debug-stale-peer",
                    evidenceClass: .signedPeerContact,
                    observedAt: staleAt,
                    receivedAt: staleAt
                )],
                staleAfter: read.iPhoneStaleAfter
            )
            read.notificationDeliveryBelief = NotificationDeliveryBelief(
                generatedAt: now,
                transportConfigured: true,
                transportFailed: true,
                evidence: [BodyEvidenceReference(
                    id: "debug-notification-failure",
                    evidenceClass: .notificationTransportFailure,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        case .resourceTight:
            read.resourcePressure = .critical
            read.resourcePressureReading = ResourcePressureReading(
                generatedAt: now,
                thermalPressure: .critical,
                lowPowerMode: false,
                evidence: [BodyEvidenceReference(
                    id: "debug-resource-critical",
                    evidenceClass: .processThermalState,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        case .memoryBrittle:
            read.memoryHealthy = false
            read.memoryIntegrityReading = MemoryIntegrityReading(
                generatedAt: now,
                storeAvailable: true,
                maintenanceSucceeded: false,
                evidence: [BodyEvidenceReference(
                    id: "debug-memory-maintenance-failure",
                    evidenceClass: .maintenanceReceipt,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        case .approvalClosed:
            read.approvalChannelsOpen = false
            read.approvalPathReading = ApprovalPathReading(
                generatedAt: now,
                writable: false,
                evidence: [BodyEvidenceReference(
                    id: "debug-approval-closed",
                    evidenceClass: .approvalStore,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        }
        return read
    }

    private nonisolated static func notificationDeliveryReading(
        dataRoot: URL,
        now: Date,
        configured: Bool,
        staleAfter: TimeInterval,
        phoneDeliveryPrediction: OrganismPrediction?
    ) -> NotificationDeliveryBelief {
        let apnsPath = dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        let apns = lastJSONObjectInJSONL(at: apnsPath)
        let apnsDate = (apns?["createdAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let apnsID = (apns?["apnsId"] as? String) ?? "apns-unknown"
        let status = (apns?["status"] as? String)?.lowercased()
        let httpStatus = (apns?["httpStatus"] as? NSNumber)?.intValue
        let accepted = status == "ok" && httpStatus.map { (200..<300).contains($0) } == true
        let failed = apns != nil && !accepted

        var deviceReceived = false
        var deviceFailed = false
        var deviceOutcomeAt: Date?
        var deviceEvidence: BodyEvidenceReference?
        if let latest = phoneDeliveryPrediction, latest.kind == .phoneDelivery {
            deviceReceived = latest.status == .satisfied
            deviceFailed = latest.status == .violated
            deviceOutcomeAt = latest.lastUpdatedAt
            if latest.status == .satisfied || latest.status == .violated {
                deviceEvidence = BodyEvidenceReference(
                    id: "phone-delivery:\(latest.id):\(latest.status.rawValue)",
                    evidenceClass: latest.status == .satisfied
                        ? .deviceProcessReceipt
                        : .deviceProcessFailure,
                    observedAt: latest.lastUpdatedAt,
                    receivedAt: latest.lastUpdatedAt
                )
            }
        }

        var evidence: [BodyEvidenceReference] = []
        if let apnsDate {
            evidence.append(BodyEvidenceReference(
                id: "apns:\(apnsID):\(status ?? "unknown")",
                evidenceClass: accepted ? .apnsAcceptance : .notificationTransportFailure,
                observedAt: apnsDate,
                receivedAt: apnsDate
            ))
        }
        if let deviceEvidence { evidence.append(deviceEvidence) }
        let latestSuccessAt = [accepted ? apnsDate : nil, deviceReceived ? deviceOutcomeAt : nil]
            .compactMap { $0 }
            .max()
        let latestFailureAt = [failed ? apnsDate : nil, deviceFailed ? deviceOutcomeAt : nil]
            .compactMap { $0 }
            .max()
        let currentlyFailed = latestFailureAt.map { failureAt in
            latestSuccessAt.map { failureAt >= $0 } ?? true
        } ?? false
        return NotificationDeliveryBelief(
            generatedAt: now,
            transportConfigured: configured,
            transportAccepted: accepted,
            deviceReceived: deviceReceived,
            // No canonical display/read receipt exists. Never promote process
            // receipt or APNS acceptance into those stronger claims.
            displayed: false,
            userSeen: false,
            transportFailed: currentlyFailed,
            evidence: evidence,
            staleAfter: staleAfter
        )
    }

    private nonisolated static func makeMemoryIntegrityReading(
        dataRoot: URL,
        now: Date
    ) -> MemoryIntegrityReading {
        let memoryRoot = dataRoot.appendingPathComponent("memory", isDirectory: true)
        let storePaths = [
            memoryRoot.appendingPathComponent("memory.sqlite"),
            memoryRoot.appendingPathComponent("profile.json"),
            memoryRoot.appendingPathComponent("knowledge_graph.json"),
        ]
        let readableStores = storePaths.filter(hasReadableContent)
        let hygienePath = memoryRoot.appendingPathComponent("hygiene_last_run.json")
        let status = stringValue(inJSONAt: hygienePath, key: "status")?.lowercased()
        let maintenanceSucceeded = status.map {
            ["ok", "complete", "completed", "success", "succeeded"].contains($0)
        }
        var evidence = readableStores.compactMap { path -> BodyEvidenceReference? in
            guard let receivedAt = modificationDate(path) else { return nil }
            return BodyEvidenceReference(
                id: "memory-store:\(path.lastPathComponent):\(receivedAt.timeIntervalSince1970)",
                evidenceClass: .localStorePresence,
                observedAt: receivedAt,
                receivedAt: receivedAt
            )
        }
        if let receivedAt = modificationDate(hygienePath) {
            evidence.append(BodyEvidenceReference(
                id: "memory-maintenance:\(receivedAt.timeIntervalSince1970):\(status ?? "unknown")",
                evidenceClass: .maintenanceReceipt,
                observedAt: receivedAt,
                receivedAt: receivedAt
            ))
        }
        return MemoryIntegrityReading(
            generatedAt: now,
            storeAvailable: !readableStores.isEmpty,
            maintenanceSucceeded: maintenanceSucceeded,
            evidence: evidence
        )
    }

    private nonisolated static func makeDreamIntegrityReading(
        dataRoot: URL,
        now: Date
    ) -> DreamIntegrityReading {
        let dreamRoot = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let statePath = dreamRoot.appendingPathComponent(".dream_state.json")
        let stateDate = latestDateValue(inJSONAt: statePath, keys: ["lastdreamedat", "last_dreamed_at"])
        let newestEntryDate = newestFileModificationDate(in: dreamRoot, suffix: ".md")
        let latest = [stateDate, newestEntryDate].compactMap { $0 }.max()
        let evidence: [BodyEvidenceReference] = latest.map {
            [BodyEvidenceReference(
                id: "dream-completion:\($0.timeIntervalSince1970)",
                evidenceClass: .dreamCompletion,
                observedAt: $0,
                receivedAt: $0
            )]
        } ?? []
        let fm = FileManager.default
        let storeAvailable = fm.fileExists(atPath: dreamRoot.path)
            || fm.isWritableFile(atPath: dataRoot.path)
        return DreamIntegrityReading(
            generatedAt: now,
            storeAvailable: storeAvailable,
            completionEvidence: evidence
        )
    }

    private nonisolated static func makeToolCapabilityReading(
        dataRoot: URL,
        now: Date
    ) -> ToolCapabilityReading {
        let configuredPaths = [
            dataRoot.appendingPathComponent("mcp", isDirectory: true).appendingPathComponent("servers.json"),
            dataRoot.appendingPathComponent("mcp", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("tools.json"),
        ]
        let activePath = dataRoot.appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        let activeCatalogExists = FileManager.default.fileExists(atPath: activePath.path)
        let configured = configuredPaths.contains(where: hasReadableContent) || activeCatalogExists
        let tracePath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let liveReceipt = lastJSONObjectInJSONL(
            at: tracePath,
            requiredKind: "tool.dispatch",
            requiredStatus: "ok"
        )
        let liveReceiptAt = (liveReceipt?["createdAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let live = liveReceiptAt.map {
            $0.timeIntervalSince(now) <= 5 && now.timeIntervalSince($0) <= 6 * 60 * 60
        } == true
        var evidence = configuredPaths.compactMap { path -> BodyEvidenceReference? in
            guard hasReadableContent(path), let date = modificationDate(path) else { return nil }
            return BodyEvidenceReference(
                id: "tool-config:\(path.lastPathComponent):\(date.timeIntervalSince1970)",
                evidenceClass: .toolConfiguration,
                observedAt: date,
                receivedAt: date
            )
        }
        if activeCatalogExists {
            let date = modificationDate(activePath) ?? now
            evidence.append(BodyEvidenceReference(
                id: "tool-catalog:\(date.timeIntervalSince1970)",
                evidenceClass: .toolConfiguration,
                observedAt: date,
                receivedAt: date
            ))
        }
        if live, let liveReceiptAt {
            let receiptID = (liveReceipt?["id"] as? String) ?? "tool-success"
            evidence.append(BodyEvidenceReference(
                id: "tool-live:\(receiptID):\(liveReceiptAt.timeIntervalSince1970)",
                evidenceClass: .liveToolCapability,
                observedAt: liveReceiptAt,
                receivedAt: liveReceiptAt
            ))
        }
        return ToolCapabilityReading(
            generatedAt: now,
            configured: configured || live,
            liveCapabilityObserved: live,
            evidence: evidence
        )
    }

    private nonisolated static func makeApprovalPathReading(
        dataRoot: URL,
        now: Date
    ) -> ApprovalPathReading {
        let approvalDir = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
        let inboxDir = dataRoot.appendingPathComponent("notifications", isDirectory: true)
        let fm = FileManager.default
        let writable = fm.fileExists(atPath: approvalDir.path)
            || fm.fileExists(atPath: inboxDir.path)
            || fm.isWritableFile(atPath: dataRoot.path)
        let path = fm.fileExists(atPath: approvalDir.path) ? approvalDir : inboxDir
        let date = modificationDate(path) ?? now
        return ApprovalPathReading(
            generatedAt: now,
            writable: writable,
            evidence: [BodyEvidenceReference(
                id: "approval-path:\(writable):\(date.timeIntervalSince1970)",
                evidenceClass: .approvalStore,
                observedAt: date,
                receivedAt: date
            )]
        )
    }

    private nonisolated static func latestMobileSeenAt(dataRoot: URL) -> Date? {
        SignedPeerEvidenceStore.load(dataRoot: dataRoot)?.observedAt
    }

    /// The only *process-global* sense in the body read: every other reading
    /// above is derived from `dataRoot`. Sampling the host's thermal/low-power
    /// state under a non-default root breaks custom-root hermeticity — and it
    /// is not cosmetic, because `resourcePressure != .nominal` sets
    /// `resourceInhibited` in `OrganismResidualRepair.opportunity`, which nils
    /// `nextWakeAt`/`nextRepairAt` and silently disarms the residual-repair
    /// deadline. A warm build machine would therefore change scheduler
    /// behaviour in any embedded/test body. Only the live app body senses the
    /// host; every other root reads nominal with the same evidence shape.
    private nonisolated static func currentResourcePressureReading(
        dataRoot: URL,
        now: Date
    ) -> ResourcePressureReading {
        let sensesHost = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let thermal: OrganismResourcePressure
        switch sensesHost ? ProcessInfo.processInfo.thermalState : .nominal {
        case .nominal:
            thermal = .nominal
        case .fair:
            thermal = .elevated
        case .serious:
            thermal = .high
        case .critical:
            thermal = .critical
        @unknown default:
            thermal = .elevated
        }
        let lowPower = sensesHost && ProcessInfo.processInfo.isLowPowerModeEnabled
        return ResourcePressureReading(
            generatedAt: now,
            thermalPressure: thermal,
            lowPowerMode: lowPower,
            evidence: [
                BodyEvidenceReference(
                    id: "thermal:\(thermal.rawValue):\(now.timeIntervalSince1970)",
                    evidenceClass: .processThermalState,
                    observedAt: now,
                    receivedAt: now
                ),
                BodyEvidenceReference(
                    id: "low-power:\(lowPower):\(now.timeIntervalSince1970)",
                    evidenceClass: .lowPowerMode,
                    observedAt: now,
                    receivedAt: now
                ),
            ]
        )
    }

    private nonisolated static func moreSevere(
        _ lhs: OrganismResourcePressure,
        _ rhs: OrganismResourcePressure
    ) -> OrganismResourcePressure {
        severity(lhs) >= severity(rhs) ? lhs : rhs
    }

    private nonisolated static func severity(_ pressure: OrganismResourcePressure) -> Int {
        switch pressure {
        case .nominal: return 0
        case .elevated: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    // G-M3: relocated from +ProviderEvidence into the extension that owns its
    // only caller (assembleOrganismProviderEvidence below); now file-private.
    private nonisolated static func hasAnyUsableProvider(dataRoot: URL) -> Bool {
        let providers = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let credentialFiles = [
            "anthropic_oauth_direct.json",
            "anthropic.json",
            "openai_oauth_direct.json",
            "openai.json",
            "openrouter.json",
            "xai_oauth_direct.json",
        ]
        if credentialFiles.contains(where: { hasReadableContent(providers.appendingPathComponent($0)) }) {
            return true
        }

        let rootScopedCodexAuth = dataRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        if hasReadableContent(rootScopedCodexAuth) { return true }

        // Process-global credentials are part of the installed personal app
        // body only. Tests and secondary runtimes with injected roots must not
        // silently inherit ~/.codex, environment keys, or a globally resolvable
        // Codex binary and then report a provider that their root does not own.
        guard dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return false
        }

        let homeCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        if hasReadableContent(homeCodexAuth) { return true }

        let env = ProcessInfo.processInfo.environment
        let keyVars = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "XAI_API_KEY"]
        if keyVars.contains(where: { env[$0]?.isEmpty == false }) { return true }

        // A resolvable codex binary with no auth token cannot serve a turn;
        // counting it here made the organism report providers it cannot use
        // (same defect as the first-run readiness copy, fixed in lockstep).
        return false
    }

    nonisolated static func hasReadableContent(_ url: URL) -> Bool {  // internal for actor extensions (move-only Wave C)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 2
    }

    private nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Reads only a bounded tail and returns the newest complete JSON object.
    /// Receipt files can live for months; a body read must not ingest the full
    /// ledger merely to rebuild one transient delivery belief.
    private nonisolated static func lastJSONObjectInJSONL(
        at url: URL,
        maximumBytes: Int = 128 * 1_024,
        requiredKind: String? = nil,
        requiredStatus: String? = nil
    ) -> [String: Any]? {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumBytes) ?? Data()
        } catch {
            return nil
        }
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !text.hasPrefix("\n"), !lines.isEmpty {
            lines.removeFirst()
        }
        for line in lines.reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let requiredKind,
               (object["kind"] as? String)?.lowercased() != requiredKind.lowercased() {
                continue
            }
            if let requiredStatus,
               (object["status"] as? String)?.lowercased() != requiredStatus.lowercased() {
                continue
            }
            return object
        }
        return nil
    }

    private nonisolated static func stringValue(inJSONAt url: URL, key: String) -> String? {
        guard let object = jsonObject(at: url) as? [String: Any],
              let value = object[key] as? String else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func latestDateValue(inJSONAt url: URL, keys: Set<String>) -> Date? {
        guard let object = jsonObject(at: url) else { return nil }
        return latestDateValue(in: object, keys: keys)
    }

    private nonisolated static func latestDateValue(in object: Any, keys: Set<String>) -> Date? {
        if let array = object as? [Any] {
            return array.compactMap { latestDateValue(in: $0, keys: keys) }.max()
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        var dates: [Date] = []
        for (key, value) in dictionary {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if keys.contains(normalized),
               let string = value as? String,
               let date = parseISODate(string) {
                dates.append(date)
            }
            if let nested = latestDateValue(in: value, keys: keys) {
                dates.append(nested)
            }
        }
        return dates.max()
    }

    private nonisolated static func jsonObject(at url: URL) -> Any? {
        guard hasReadableContent(url),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func parseISODate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: trimmed)
    }

    private nonisolated static func newestFileModificationDate(in directory: URL, suffix: String) -> Date? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
