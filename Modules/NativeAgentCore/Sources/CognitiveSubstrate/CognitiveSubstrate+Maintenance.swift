import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Maintenance.swift` | `CognitiveSubstrate`: microcycle settlement, maintenance deadlines and emotional consolidation |

/// Mutation-free maintenance deadline; analytic reads need no checkpoint.
public struct CognitiveMaintenanceOpportunity: Sendable, Equatable {
    public var generatedAt: Date
    public var dueReasons: [String]
    public var nextMaintenanceAt: Date?

    public init(
        generatedAt: Date,
        dueReasons: [String] = [],
        nextMaintenanceAt: Date? = nil
    ) {
        self.generatedAt = generatedAt
        self.dueReasons = Array(Set(dueReasons)).sorted()
        self.nextMaintenanceAt = nextMaintenanceAt
    }

    public var isDue: Bool { !dueReasons.isEmpty }
}

extension CognitiveSubstrate {
    @discardableResult
    public func runMicrocycleChecked(reason: String) async throws -> CognitiveWorkspaceSnapshot? {
        await waitForMaintenanceTransition()
        // The existing commit exclusion also single-flights microcycles. Hand
        // ownership directly to a waiting caller so its dirty follow-up is not
        // dropped and maintenance cannot enter between holders.
        if maintenanceCommitInFlight {
            await withCheckedContinuation { microcycleWaiters.append($0) }
        } else {
            maintenanceCommitInFlight = true
        }
        defer {
            if microcycleWaiters.isEmpty { maintenanceCommitInFlight = false }
            else { microcycleWaiters.removeFirst().resume() }
        }
        guard configuration.enabled, configuration.backgroundMicrocyclesEnabled else { return nil }
        guard dirtySince != nil else { return nil }
        let startedAt = ContinuousClock.now
        let priorDirtySince = dirtySince
        let settledAt = dependencies.now()
        let settledNodes = field.snapshot(at: settledAt, configuration: configuration)
        let workspace = workspaceSnapshot(at: settledAt, settledNodes: settledNodes)
        // This cycle has consumed the dirty state represented by `workspace`.
        // Clear before any awaiting persistence work: a concurrent event will
        // set it again and must survive this cycle's completion.
        dirtySince = nil
        publishAttentionProjection(at: workspace.generatedAt)
        var flushedPresentation = false
        do {
            if configuration.persistenceEnabled {
                // Resident sensory admission defers its per-event affect and
                // node writes here. Affect, consumed residue, nodes, pruning
                // and the receipt settle in one canonical SQLite transaction.
                var artifacts = affectCheckpoint(at: settledAt)
                // The resident ingest's accepted-turn tick (and any unflushed
                // cadence move) rides the same transaction.
                if capsulePresentationDirty {
                    capsulePresentationDirty = false
                    flushedPresentation = true
                    artifacts.append(CognitiveArtifactWrite(
                        kind: "capsule_presentation",
                        id: stableArtifactID("capsule_presentation"),
                        status: "current",
                        score: 0,
                        payload: capsulePresentationArtifactPayload(at: workspace.generatedAt)
                    ))
                }
                try await persistMaintenanceTransition(
                    nodes: settledNodes,
                    artifacts: artifacts,
                    deletedArtifactIDs: [],
                    receipts: [CognitiveReceiptWrite(
                        kind: "microcycle",
                        payload: .object([
                        "reason": .string(bounded(reason, maxCharacters: 120)),
                        "workspaceCount": .int(Int64(workspace.items.count)),
                        "inhibitedCount": .int(Int64(workspace.inhibitedNodeIds.count)),
                        ]),
                        startedAt: startedAt
                    )],
                    at: workspace.generatedAt
                )
            }
        } catch {
            if dirtySince == nil { dirtySince = priorDirtySince }
            if flushedPresentation { capsulePresentationDirty = true }
            throw error
        }
        return workspace
    }

    /// Overnight consolidation runs at most once per 20 hours on the maintenance cadence.
    static let emotionalConsolidationInterval: TimeInterval = 20 * 60 * 60

    public func runMaintenance(reason: String) async {
        _ = try? await runMaintenanceChecked(reason: reason)
    }

    /// Pure, mutation-free deadline projection over the existing cognition
    /// owners. Continuous decay is already analytic at every read. Maintenance
    /// is due at the existing 20-hour emotional consolidation boundary.
    public func maintenanceOpportunity() -> CognitiveMaintenanceOpportunity {
        currentMaintenanceOpportunity(at: dependencies.now())
    }

    @discardableResult
    public func runMaintenanceChecked(reason: String) async throws -> Bool {
        guard configuration.enabled else { return false }
        // Maintenance and microcycles exclude each other across their commits.
        guard !maintenanceRunInFlight, !maintenanceCommitInFlight else { return false }
        let now = dependencies.now()
        guard currentMaintenanceOpportunity(at: now).isDue else { return false }
        beginMaintenanceTransition()
        defer { endMaintenanceTransition() }
        let previousField = field
        let previousAffect = affect
        let previousConsolidationAt = lastEmotionalConsolidationAt
        let previousDisposition = disposition
        let previousDispositionTransitions = dispositionTransitions
        let previousPatternNudgeDay = resolutionPatternNudgeDay
        let initialDirtyRevision = dirtyRevision

        // One checkpoint operation materializes the same full affect projection
        // that live reads use (base decay + quiet calming + warm-presence floor).
        _ = decayAffectInMemory(to: now)

        var artifacts = affectCheckpoint(at: now)
        var receipts: [CognitiveReceiptWrite] = []
        var stagedTimelineEvents: [CognitiveDevelopmentalTimelineEvent] = []
        if let consolidation = consolidateEmotionalArousalIfDueInMemory(reason: reason, at: now) {
            artifacts.append(contentsOf: consolidation.artifacts)
            receipts.append(contentsOf: consolidation.receipts)
            stagedTimelineEvents.append(contentsOf: consolidation.timelineEvents)
        }

        let nodes = field.snapshot(at: now, configuration: configuration)
        publishAttentionProjection(at: now)
        receipts.append(CognitiveReceiptWrite(
            kind: "maintenance",
            payload: .object([
                "reason": .string(bounded(reason, maxCharacters: 120)),
                "nodeCount": .int(Int64(nodes.count)),
            ])
        ))

        guard configuration.persistenceEnabled else { return true }
        do {
            try await persistMaintenanceTransition(
                nodes: nodes,
                artifacts: artifacts,
                deletedArtifactIDs: [],
                receipts: receipts,
                at: now
            )
        } catch {
            // The SQLite transaction has already rolled back. Revert the
            // bounded in-memory transition only when no reentrant live event
            // changed that family while the store actor was committing.
            if dirtyRevision == initialDirtyRevision {
                field = previousField
                affect = previousAffect
                removeTimelineEventsIfMatching(stagedTimelineEvents)
                lastEmotionalConsolidationAt = previousConsolidationAt
                disposition = previousDisposition
                dispositionTransitions = previousDispositionTransitions
                resolutionPatternNudgeDay = previousPatternNudgeDay
            }
            publishAttentionProjection(at: dependencies.now())
            throw error
        }
        return true
    }

    private func currentMaintenanceOpportunity(at now: Date) -> CognitiveMaintenanceOpportunity {
        guard configuration.enabled else {
            return CognitiveMaintenanceOpportunity(generatedAt: now)
        }
        var dueReasons: [String] = []
        var futureDeadlines: [Date] = []

        if configuration.enabled {
            let consolidationAt = lastEmotionalConsolidationAt?
                .addingTimeInterval(Self.emotionalConsolidationInterval) ?? now
            if consolidationAt <= now {
                dueReasons.append("emotional_consolidation")
            } else {
                futureDeadlines.append(consolidationAt)
            }
        }

        return CognitiveMaintenanceOpportunity(
            generatedAt: now,
            dueReasons: dueReasons,
            nextMaintenanceAt: dueReasons.isEmpty ? futureDeadlines.min() : now
        )
    }

    private struct EmotionalConsolidationTransition {
        var artifacts: [CognitiveArtifactWrite]
        var receipts: [CognitiveReceiptWrite]
        var timelineEvents: [CognitiveDevelopmentalTimelineEvent]
    }

    /// Consolidates arousal only every ~20h with affect enabled; zero-count sweeps omit timeline events.
    private func consolidateEmotionalArousalIfDueInMemory(
        reason: String,
        at now: Date
    ) -> EmotionalConsolidationTransition? {
        guard configuration.enabled else { return nil }
        if let last = lastEmotionalConsolidationAt,
           now.timeIntervalSince(last) < Self.emotionalConsolidationInterval {
            return nil
        }
        let previousTick = lastEmotionalConsolidationAt
        let counts = field.consolidateEmotionalArousal(at: now, configuration: configuration)
        lastEmotionalConsolidationAt = now
        // Resolution patterns share disposition caps and day-scale decay;
        // growth admits new evidence, with at most one nudge per path/kind/day.
        var artifacts: [CognitiveArtifactWrite] = []
        let dayKey = Self.resolutionPatternDayKey(at: now)
        if let hit = resolutionPatternHit(at: now, newerThan: previousTick),
           resolutionPatternNudgeDay[hit.claimKey] != dayKey {
            integrateDispositionInMemory(tone: hit.tone, at: now, source: "resolution_pattern")
            // Claim the day and drop every stale (prior-day) claim so the map
            // stays a handful of entries at most.
            resolutionPatternNudgeDay[hit.claimKey] = dayKey
            resolutionPatternNudgeDay = resolutionPatternNudgeDay.filter { $0.value == dayKey }
            artifacts.append(CognitiveArtifactWrite(
                kind: "disposition",
                id: stableArtifactID("disposition"),
                status: "current",
                score: (disposition.valence + 1) / 2,
                payload: dispositionArtifactPayload(at: now)
            ))
        }
        artifacts.append(CognitiveArtifactWrite(
            kind: "emotional_consolidation",
            id: stableArtifactID("emotional_consolidation"),
            status: "current",
            score: Double(counts.reinforced + counts.calmed),
            payload: .object([
                "ranAt": .double(now.timeIntervalSince1970),
                "reinforced": .int(Int64(counts.reinforced)),
                "calmed": .int(Int64(counts.calmed)),
            ])
        ))
        let receipts = [CognitiveReceiptWrite(
            kind: "emotional_consolidation",
            payload: .object([
                "reason": .string(bounded(reason, maxCharacters: 120)),
                "reinforced": .int(Int64(counts.reinforced)),
                "calmed": .int(Int64(counts.calmed)),
            ])
        )]
        // Record a replayRun timeline event only when consolidation moved something.
        var timelineEvents: [CognitiveDevelopmentalTimelineEvent] = []
        if counts.reinforced > 0 || counts.calmed > 0 {
            // The summary's per-run date keeps timeline event IDs distinct across identical sweeps.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
            let event = recordTimelineEventInMemory(
                kind: .replayRun,
                title: "Overnight emotional consolidation",
                summary: "softened \(counts.calmed), sustained \(counts.reinforced) · \(formatter.string(from: now))",
                artifactId: stableArtifactID("emotional_consolidation"),
                lineageId: "emotional_consolidation",
                externalEvidenceIds: []
            )
            timelineEvents.append(event)
            artifacts.append(CognitiveArtifactWrite(
                kind: "developmental_timeline",
                id: event.id,
                status: "recorded",
                score: 0.5,
                payload: event.toJSON()
            ))
        }
        return EmotionalConsolidationTransition(
            artifacts: artifacts,
            receipts: receipts,
            timelineEvents: timelineEvents
        )
    }
}
