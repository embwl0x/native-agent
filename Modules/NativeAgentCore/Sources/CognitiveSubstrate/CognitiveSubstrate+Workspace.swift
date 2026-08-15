// CognitiveSubstrate+Workspace.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

/// Exact read-side ownership for cognition maintenance. Analytic affect, node,
/// and thought-seed reads do not need a checkpoint merely because five minutes
/// elapsed; only discrete lifecycle boundaries do. The app runtime uses this
/// projection to own one cancellable deadline while the periodic loop remains a
/// slow crash/integrity fallback.
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
    public func workspaceSnapshot(currentSessionId: String? = nil) async -> CognitiveWorkspaceSnapshot {
        let now = dependencies.now()
        guard configuration.enabled, configuration.workspaceEnabled else {
            return CognitiveWorkspaceSnapshot(generatedAt: now, items: [])
        }
        let settledNodes = field.snapshot(at: now, configuration: configuration)
        return workspaceSnapshot(
            at: now,
            settledNodes: settledNodes,
            currentSessionId: currentSessionId
        )
    }

    /// Build a workspace from the exact field settlement already owned by the
    /// caller. A microcycle uses this once-settled node set for both selection
    /// and durability, avoiding a second full 256-node decay/sort at the same
    /// timestamp without changing canonical state.
    private func workspaceSnapshot(
        at now: Date,
        settledNodes: [CognitiveNode],
        currentSessionId: String? = nil
    ) -> CognitiveWorkspaceSnapshot {
        guard configuration.workspaceEnabled else {
            return CognitiveWorkspaceSnapshot(generatedAt: now, items: [])
        }
        let sessionId = Self.cleanedSessionId(currentSessionId)
        let turnKindsByNodeID = Dictionary(uniqueKeysWithValues: settledNodes.map {
            ($0.id, field.cachedTurnKind(for: $0))
        })
        let nodes = settledNodes.filter {
            workspaceEligible(
                $0,
                currentSessionId: sessionId,
                at: now,
                turnKind: turnKindsByNodeID[$0.id]
            )
        }
        let associatedNodeIds = field.associatedNodeIDs()
        // Wave C: derive mood ONCE and thread it through scoring/reasons so recall is
        // mood-congruent (a node whose stored feeling matches her mood surfaces a little
        // more readily). Neutral mood + untagged nodes → the mood term is 0 everywhere,
        // so scores/reasons stay byte-identical to pre-Wave-C.
        let mood = derivedMood(at: now)
        let currentAffect = projectedAffect(at: now)
        return makeWorkspaceSnapshot(
            at: now,
            nodes: nodes,
            associatedNodeIds: associatedNodeIds,
            mood: mood,
            affect: currentAffect,
            turnKindsByNodeID: turnKindsByNodeID
        )
    }

    /// Settle one copied continuity field at an explicit timestamp. The
    /// resulting snapshot/workspace may be rendered into a frozen provider
    /// packet without advancing the live field's decay anchors.
    public func frozenRead(
        at fixedAt: Date,
        currentSessionId: String? = nil
    ) async -> CognitiveFrozenRead {
        let frozenConfiguration = configuration
        let fixedAffect = projectedAffect(at: fixedAt)
        let fixedMood = derivedMood(at: fixedAt)
        let fixedThoughtSeeds = projectedThoughtSeeds(at: fixedAt).sorted(by: thoughtSeedPrioritySort)
        let frozenStandingViewInnerLine = activeStandingViewInnerLine()
        let frozenSoundEchoLine = soundEchoLine(at: fixedAt)
        // W4/P2: captured, never recomputed downstream (see CognitiveFeltProxyReads).
        // Curiosity is workspace-relative, so it is captured per branch below where
        // the frozen workspace is known; the other two are workspace-independent.
        let frozenFatigue = substrateFatigueProxy(at: fixedAt)
        let frozenClarity = substrateClarityProxy(affect: fixedAffect, at: fixedAt)
        guard frozenConfiguration.enabled else {
            let empty = CognitiveSubstrateSnapshot(
                generatedAt: fixedAt,
                enabled: false,
                maximumActiveNodes: frozenConfiguration.maximumActiveNodes,
                nodes: [],
                persistenceHealth: persistenceHealth
            )
            return CognitiveFrozenRead(
                fixedAt: fixedAt,
                stateRevision: dirtyRevision,
                thoughtSeedRevision: thoughtSeedRevision,
                configuration: frozenConfiguration,
                snapshot: empty,
                workspace: CognitiveWorkspaceSnapshot(generatedAt: fixedAt, items: []),
                affect: fixedAffect,
                mood: fixedMood,
                thoughtSeeds: fixedThoughtSeeds,
                standingViewInnerLine: frozenStandingViewInnerLine,
                soundEchoLine: frozenSoundEchoLine,
                feltProxies: CognitiveFeltProxyReads(
                    fatigue: frozenFatigue, curiosity: nil, clarity: frozenClarity)
            )
        }
        var copiedField = field
        let settledNodes = copiedField.snapshot(at: fixedAt, configuration: frozenConfiguration)
        let snapshot = CognitiveSubstrateSnapshot(
            generatedAt: fixedAt,
            enabled: true,
            maximumActiveNodes: frozenConfiguration.maximumActiveNodes,
            nodes: settledNodes,
            persistenceHealth: persistenceHealth
        )
        guard frozenConfiguration.workspaceEnabled else {
            return CognitiveFrozenRead(
                fixedAt: fixedAt,
                stateRevision: dirtyRevision,
                thoughtSeedRevision: thoughtSeedRevision,
                configuration: frozenConfiguration,
                snapshot: snapshot,
                workspace: CognitiveWorkspaceSnapshot(generatedAt: fixedAt, items: []),
                affect: fixedAffect,
                mood: fixedMood,
                thoughtSeeds: fixedThoughtSeeds,
                standingViewInnerLine: frozenStandingViewInnerLine,
                soundEchoLine: frozenSoundEchoLine,
                feltProxies: CognitiveFeltProxyReads(
                    fatigue: frozenFatigue, curiosity: nil, clarity: frozenClarity)
            )
        }
        let sessionId = Self.cleanedSessionId(currentSessionId)
        let turnKindsByNodeID = Dictionary(uniqueKeysWithValues: settledNodes.map {
            ($0.id, copiedField.cachedTurnKind(for: $0))
        })
        let eligible = settledNodes.filter {
            workspaceEligible(
                $0,
                currentSessionId: sessionId,
                at: fixedAt,
                turnKind: turnKindsByNodeID[$0.id]
            )
        }
        let associatedNodeIds = copiedField.associatedNodeIDs()
        let workspace = makeWorkspaceSnapshot(
            at: fixedAt,
            nodes: eligible,
            associatedNodeIds: associatedNodeIds,
            mood: fixedMood,
            affect: fixedAffect,
            turnKindsByNodeID: turnKindsByNodeID
        )
        return CognitiveFrozenRead(
            fixedAt: fixedAt,
            stateRevision: dirtyRevision,
            thoughtSeedRevision: thoughtSeedRevision,
            configuration: frozenConfiguration,
            snapshot: snapshot,
            workspace: workspace,
            affect: fixedAffect,
            mood: fixedMood,
            thoughtSeeds: fixedThoughtSeeds,
            standingViewInnerLine: frozenStandingViewInnerLine,
            soundEchoLine: frozenSoundEchoLine,
            feltProxies: CognitiveFeltProxyReads(
                fatigue: frozenFatigue,
                // Curiosity is novelty of what she is HOLDING, so it is captured
                // against the frozen workspace — the same items the capsule
                // renders from.
                curiosity: substrateCuriosityProxy(
                    from: workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) },
                    at: fixedAt),
                clarity: frozenClarity)
        )
    }

    /// Pure mutation sentinel for a frozen epoch.
    public func frozenRevisionToken() -> String {
        "\(dirtyRevision):\(thoughtSeedRevision)"
    }

    private func makeWorkspaceSnapshot(
        at now: Date,
        nodes: [CognitiveNode],
        associatedNodeIds: Set<UUID>,
        mood: CognitiveMoodReading,
        affect currentAffect: CognitiveAffectState,
        turnKindsByNodeID: [UUID: CognitiveTurnKind]
    ) -> CognitiveWorkspaceSnapshot {
        // Score first, then materialize reasons only for selected items. The
        // prior path allocated a complete reason array and copied a full node
        // into a workspace item for all 256 candidates before discarding most
        // of them at the cap.
        let scored = nodes.map { node in
            (
                node: node,
                score: workspaceScore(
                    for: node,
                    mood: mood,
                    affect: currentAffect,
                    turnKind: turnKindsByNodeID[node.id]
                )
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.node.lastActivatedAt != rhs.node.lastActivatedAt {
                return lhs.node.lastActivatedAt > rhs.node.lastActivatedAt
            }
            return lhs.node.id.uuidString < rhs.node.id.uuidString
        }

        var kept: [CognitiveWorkspaceItem] = []
        var inhibited: [UUID] = []
        var seenSubjects: Set<String> = []
        var keptSystemItems = 0
        // Audit C2 follow-up (gpt-5.5 MED, 2026-07-09): user turns are per-turn nodes
        // now (the session-collapse fix), so they bypass the subject de-dupe — a long
        // session could fill the whole workspace and dominate the fingerprint's felt
        // read with one conversation's turns. Cap live user-turn nodes per SESSION at
        // selection; storage stays per-turn (mood/recall still see every turn).
        var userTurnsPerSession: [String: Int] = [:]
        let maximumUserTurnsPerSession = 2
        let maximumSystemItems = max(1, min(3, configuration.maximumWorkspaceItems / 3))
        var processedCount = 0
        for candidate in scored {
            processedCount += 1
            let subjectKey = candidate.node.subjectReference.stableKey
            if seenSubjects.contains(subjectKey) {
                inhibited.append(candidate.node.id)
                continue
            }
            if candidate.node.subjectReference.type == "chat.user_turn" {
                let sessionKey = candidate.node.metadata["sessionId"].flatMap { v -> String? in
                    if case .string(let sid) = v { return sid }
                    return nil
                } ?? "unknown"
                let count = userTurnsPerSession[sessionKey, default: 0]
                if count >= maximumUserTurnsPerSession {
                    inhibited.append(candidate.node.id)
                    continue
                }
                userTurnsPerSession[sessionKey] = count + 1
            }
            if turnKindsByNodeID[candidate.node.id] == .system,
               keptSystemItems >= maximumSystemItems {
                inhibited.append(candidate.node.id)
                continue
            }
            seenSubjects.insert(subjectKey)
            kept.append(CognitiveWorkspaceItem(
                node: candidate.node,
                score: candidate.score,
                reasons: workspaceReasons(
                    for: candidate.node,
                    associatedNodeIds: associatedNodeIds,
                    mood: mood,
                    affect: currentAffect,
                    turnKind: turnKindsByNodeID[candidate.node.id]
                )
            ))
            if turnKindsByNodeID[candidate.node.id] == .system {
                keptSystemItems += 1
            }
            if kept.count >= configuration.maximumWorkspaceItems { break }
        }
        if scored.count > processedCount {
            inhibited.append(contentsOf: scored.dropFirst(processedCount).map { $0.node.id })
        }
        return CognitiveWorkspaceSnapshot(generatedAt: now, items: kept, inhibitedNodeIds: inhibited)
    }

    @discardableResult
    public func runMicrocycle(reason: String) async -> CognitiveWorkspaceSnapshot? {
        try? await runMicrocycleChecked(reason: reason)
    }

    @discardableResult
    public func runMicrocycleChecked(reason: String) async throws -> CognitiveWorkspaceSnapshot? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.backgroundMicrocyclesEnabled else { return nil }
        guard dirtySince != nil else { return nil }
        // R-F2: raise the symmetric commit-exclusion flag for the remainder of
        // this cycle. From here through the persistence commit below, a
        // maintenance pass must not start — its decay would be reverted on disk
        // when this cycle writes its pre-decay seed rows. Set before the first
        // await so nothing can slip in during seed synthesis either.
        maintenanceCommitInFlight = true
        defer { maintenanceCommitInFlight = false }
        let priorDirtySince = dirtySince
        let priorThoughtSeeds = thoughtSeeds
        let priorThoughtSeedRevision = thoughtSeedRevision
        let settledAt = dependencies.now()
        let settledNodes = field.snapshot(at: settledAt, configuration: configuration)
        let workspace = workspaceSnapshot(at: settledAt, settledNodes: settledNodes)
        let currentAffect = projectedAffect(at: workspace.generatedAt)
        // This cycle has consumed the dirty state represented by `workspace`.
        // Clear before any awaiting persistence work: a concurrent event will
        // set it again and must survive this cycle's completion.
        dirtySince = nil
        if configuration.thoughtSeedsEnabled,
           currentAffect.uncertainty > 0.45 || currentAffect.taskPressure > 0.45 {
            _ = await addThoughtSeed(
                kind: currentAffect.uncertainty > currentAffect.taskPressure ? .anomaly : .followUp,
                text: "Re-check high-pressure cognitive state after \(bounded(reason, maxCharacters: 80))",
                priority: min(1, max(currentAffect.uncertainty, currentAffect.taskPressure)),
                sourceNodeIds: workspace.items.prefix(3).map(\.id),
                marksSubstrateDirty: false
            )
        }
        publishAttentionProjection(at: workspace.generatedAt)
        do {
            if configuration.persistenceEnabled {
                // Resident sensory admission defers its per-event affect and
                // node writes here. Affect, thought seeds, nodes, pruning, and
                // the receipt are one canonical SQLite transaction—not four
                // sequential commits for one physiological settlement.
                let artifacts: [CognitiveArtifactWrite] = configuration.affectEnabled
                    ? [CognitiveArtifactWrite(
                        kind: "affect",
                        id: stableArtifactID("affect"),
                        status: "current",
                        score: affect.arousal,
                        payload: affect.toJSON(
                            lastUserPresenceAt: lastUserPresenceAt,
                            lastWarmPresenceAt: lastWarmPresenceAt
                        )
                    )]
                    : []
                let seedRows = configuration.thoughtSeedsEnabled
                    ? thoughtSeeds.values.map {
                        CognitiveArtifactReplacement(
                            id: $0.id,
                            status: "open",
                            score: $0.priority,
                            payload: $0.toJSON()
                        )
                    }
                    : nil
                // R-F2 deterministic interleave seam: nil in production. A test
                // uses it to attempt a maintenance run while this cycle is
                // inside its commit window (see maintenanceCommitInFlight).
                if let probe = microcycleCommitInterleaveProbe {
                    await probe()
                }
                try await persistMaintenanceTransition(
                    nodes: settledNodes,
                    thoughtSeeds: seedRows,
                    artifacts: artifacts,
                    deletedArtifactIDs: [],
                    receipts: [CognitiveReceiptWrite(
                        kind: "microcycle",
                        payload: .object([
                        "reason": .string(bounded(reason, maxCharacters: 120)),
                        "workspaceCount": .int(Int64(workspace.items.count)),
                        "inhibitedCount": .int(Int64(workspace.inhibitedNodeIds.count)),
                        ])
                    )],
                    at: workspace.generatedAt
                )
            }
        } catch {
            if dirtySince == nil { dirtySince = priorDirtySince }
            if thoughtSeedRevision != priorThoughtSeedRevision,
               thoughtSeedRevision == priorThoughtSeedRevision &+ 1 {
                thoughtSeeds = priorThoughtSeeds
                thoughtSeedRevision &+= 1
            }
            throw error
        }
        return workspace
    }

    /// Wave D overnight consolidation self-gate: at most once per ~20h, riding the existing
    /// maintenance cadence (no new loop/timer).
    static let emotionalConsolidationInterval: TimeInterval = 20 * 60 * 60

    public func runMaintenance(reason: String) async {
        _ = try? await runMaintenanceChecked(reason: reason)
    }

    /// Pure, mutation-free deadline projection over the existing cognition
    /// owners. Continuous decay is already analytic at every read. Maintenance
    /// is due only when a thought seed becomes physically removable, a proposed
    /// standing view expires, or the existing 20-hour emotional consolidation
    /// boundary arrives.
    public func maintenanceOpportunity() -> CognitiveMaintenanceOpportunity {
        currentMaintenanceOpportunity(at: dependencies.now())
    }

    @discardableResult
    public func runMaintenanceChecked(reason: String) async throws -> Bool {
        guard configuration.enabled else { return false }
        // R-F2: refuse to start while a microcycle is inside its commit window
        // (maintenanceCommitInFlight). Combined with the microcycle waiting on
        // waitForMaintenanceTransition before it begins, this makes the
        // commit exclusion symmetric — the two can never interleave commits.
        guard !maintenanceRunInFlight, !maintenanceCommitInFlight else { return false }
        let now = dependencies.now()
        guard currentMaintenanceOpportunity(at: now).isDue else { return false }
        beginMaintenanceTransition()
        defer { endMaintenanceTransition() }
        let previousField = field
        let previousAffect = affect
        let previousThoughtSeeds = thoughtSeeds
        let previousStandingViews = standingViews
        let previousConsolidationAt = lastEmotionalConsolidationAt
        let previousDisposition = disposition
        let previousPatternNudgeDay = resolutionPatternNudgeDay
        let initialDirtyRevision = dirtyRevision

        if decayThoughtSeedsInMemory(at: now) {
            thoughtSeedRevision &+= 1
        }
        // One checkpoint operation materializes the same full affect projection
        // that live reads use (base decay + quiet calming + warm-presence floor).
        _ = decayAffectInMemory(to: now)

        var artifacts: [CognitiveArtifactWrite] = []
        var receipts: [CognitiveReceiptWrite] = []
        var stagedTimelineEvents: [CognitiveDevelopmentalTimelineEvent] = []
        if configuration.affectEnabled {
            artifacts.append(CognitiveArtifactWrite(
                kind: "affect",
                id: stableArtifactID("affect"),
                status: "current",
                score: affect.arousal,
                payload: affect.toJSON(
                    lastUserPresenceAt: lastUserPresenceAt,
                    lastWarmPresenceAt: lastWarmPresenceAt
                )
            ))
        }
        if let consolidation = consolidateEmotionalArousalIfDueInMemory(reason: reason, at: now) {
            artifacts.append(contentsOf: consolidation.artifacts)
            receipts.append(contentsOf: consolidation.receipts)
            stagedTimelineEvents.append(contentsOf: consolidation.timelineEvents)
        }

        let staleViews = retireStaleProposedStandingViewsInMemory(at: now)
        for view in staleViews {
            let event = recordTimelineEventInMemory(
                kind: .proposalResolution,
                title: "Standing view retired (stale)",
                summary: "retired (stale): \(view.body)",
                artifactId: view.id,
                lineageId: view.lineageId,
                externalEvidenceIds: []
            )
            stagedTimelineEvents.append(event)
            artifacts.append(CognitiveArtifactWrite(
                kind: "developmental_timeline",
                id: event.id,
                status: "recorded",
                score: 0.5,
                payload: event.toJSON()
            ))
        }

        let nodes = field.snapshot(at: now, configuration: configuration)
        publishAttentionProjection(at: now)
        receipts.append(CognitiveReceiptWrite(
            kind: "maintenance",
            payload: .object([
                "reason": .string(bounded(reason, maxCharacters: 120)),
                "nodeCount": .int(Int64(nodes.count)),
                "retiredStandingViewCount": .int(Int64(staleViews.count)),
            ])
        ))

        guard configuration.persistenceEnabled else { return true }
        let stagedThoughtSeedRevision = thoughtSeedRevision
        do {
            try await persistMaintenanceTransition(
                nodes: nodes,
                thoughtSeeds: configuration.thoughtSeedsEnabled
                    ? thoughtSeeds.values.map {
                        CognitiveArtifactReplacement(
                            id: $0.id,
                            status: "open",
                            score: $0.priority,
                            payload: $0.toJSON()
                        )
                    }
                    : nil,
                artifacts: artifacts,
                deletedArtifactIDs: staleViews.map(\.id),
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
                standingViews = previousStandingViews
                removeTimelineEventsIfMatching(stagedTimelineEvents)
                lastEmotionalConsolidationAt = previousConsolidationAt
                disposition = previousDisposition
                resolutionPatternNudgeDay = previousPatternNudgeDay
            }
            if thoughtSeedRevision == stagedThoughtSeedRevision {
                thoughtSeeds = previousThoughtSeeds
                thoughtSeedRevision &+= 1
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

        if configuration.affectEnabled {
            let consolidationAt = lastEmotionalConsolidationAt?
                .addingTimeInterval(Self.emotionalConsolidationInterval) ?? now
            if consolidationAt <= now {
                dueReasons.append("emotional_consolidation")
            } else {
                futureDeadlines.append(consolidationAt)
            }
        }

        if configuration.thoughtSeedsEnabled {
            for seed in thoughtSeeds.values {
                let currentPriority = effectiveThoughtSeedPriority(seed, at: now)
                if currentPriority < Self.minimumRetainedThoughtSeedPriority {
                    dueReasons.append("thought_seed_expiry")
                    continue
                }
                guard seed.priority > 0 else {
                    dueReasons.append("thought_seed_expiry")
                    continue
                }
                let ratio = seed.priority / Self.minimumRetainedThoughtSeedPriority
                guard ratio.isFinite, ratio > 0 else { continue }
                // Physical deletion uses `< minimum`, so schedule just beyond
                // the exact equality boundary and avoid an immediate no-op loop.
                let seconds = Self.thoughtSeedPriorityHalfLife * log2(ratio)
                guard seconds.isFinite else { continue }
                let expiry = seed.lastUpdatedAt.addingTimeInterval(max(0, seconds) + 0.001)
                if expiry <= now {
                    dueReasons.append("thought_seed_expiry")
                } else {
                    futureDeadlines.append(expiry)
                }
            }
        }

        for view in standingViews.values where view.status == .proposed {
            // Retirement uses `age > maxAge`; the millisecond keeps the exact
            // deadline from firing at equality and re-arming itself immediately.
            let expiry = view.createdAt.addingTimeInterval(
                Self.standingViewProposalMaxAge + 0.001
            )
            if expiry <= now {
                dueReasons.append("standing_view_expiry")
            } else {
                futureDeadlines.append(expiry)
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

    /// Overnight emotional consolidation (Wave D), gated to run once per ~20h on the
    /// existing maintenance cadence. Softens stale high-arousal charges and gently sustains
    /// what keeps recurring — AROUSAL ONLY; valence/warmth/content are never touched. Gated
    /// on `affectEnabled` (with affect off, no tags are ever stamped, so the sweep is a
    /// no-op anyway and mood/emotion stays fully off).
    ///
    /// The sweep runs even when 0 nodes qualify so the cadence tick is observable (gate +
    /// artifact + receipt with zero counts), but the timeline event is skipped on a
    /// zero-count sweep so her timeline carries no noise.
    private func consolidateEmotionalArousalIfDueInMemory(
        reason: String,
        at now: Date
    ) -> EmotionalConsolidationTransition? {
        guard configuration.affectEnabled else { return nil }
        if let last = lastEmotionalConsolidationAt,
           now.timeIntervalSince(last) < Self.emotionalConsolidationInterval {
            return nil
        }
        let previousTick = lastEmotionalConsolidationAt
        let counts = field.consolidateEmotionalArousal(at: now, configuration: configuration)
        lastEmotionalConsolidationAt = now
        // Round 3 Wave A3 — the slow layer learns from resolution PATTERNS.
        // A path that keeps disappointing her (≥3 felt disappointments in
        // 48h) leaves a settled negative undertone; a path she keeps bracing
        // for that keeps landing fine teaches the body the dread was
        // oversized. Routes through the SAME disposition cap + day-scale decay
        // as every other writer, reads only her own felt-resolution nodes, and
        // fires AT MOST ONCE per (path, kind) per day — the growth gate stops
        // the same moments re-nudging, the day claim stops genuine same-day
        // growth from a second nudge (review bf74aecde2fa).
        var artifacts: [CognitiveArtifactWrite] = []
        let dayKey = Self.resolutionPatternDayKey(at: now)
        if let hit = resolutionPatternHit(at: now, newerThan: previousTick),
           resolutionPatternNudgeDay[hit.claimKey] != dayKey {
            let decayed = decayedDispositionValence(at: now)
            let cap = dynamics.dispositionValenceCap
            let next = min(cap, max(-cap, decayed + hit.tone * dynamics.dispositionNudgeMagnitude))
            disposition = CognitiveDisposition(valence: next, updatedAt: now)
            // Claim the day and drop every stale (prior-day) claim so the map
            // stays a handful of entries at most.
            resolutionPatternNudgeDay[hit.claimKey] = dayKey
            resolutionPatternNudgeDay = resolutionPatternNudgeDay.filter { $0.value == dayKey }
            artifacts.append(CognitiveArtifactWrite(
                kind: "disposition",
                id: stableArtifactID("disposition"),
                status: "current",
                score: (next + 1) / 2,
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
        // Only surface a timeline event when the sweep actually moved something (no noise
        // in her Observatory timeline for a zero-count cadence tick). Reuses the existing,
        // currently-unemitted `.replayRun` kind — overnight consolidation IS an offline
        // replay-style reprocessing pass, and every decode site tolerates the kind (it is
        // an existing enum case; the only JSON-rawValue decode, restoreDevelopmentalTimeline,
        // skips unknown kinds, and the Observatory view renders kind.rawValue as plain text).
        var timelineEvents: [CognitiveDevelopmentalTimelineEvent] = []
        if counts.reinforced > 0 || counts.calmed > 0 {
            // The per-run date rides in the summary: the timeline event ID seeds on
            // kind + artifactId + summary, and this sweep's artifact ID is stable —
            // without a per-run token two nights with identical counts would collapse
            // into one upserted event (gpt-5.5 review, 2026-07-02). Human-readable on
            // purpose; it's her Observatory timeline.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
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

    func evictSpentVerificationNodes(before event: CognitiveEvent, at now: Date) -> Int {
        guard verificationNodeMayExist else { return 0 }
        guard event.turnKind == .live,
              let currentSessionId = event.sessionId,
              !currentSessionId.isEmpty else {
            return 0
        }
        let evicted = field.evictNodes { node in
            guard node.turnKind == .verification else { return false }
            let nodeSessionId = node.sessionId
            if let nodeSessionId, !nodeSessionId.isEmpty, nodeSessionId != currentSessionId {
                return true
            }
            return verificationNodeExpired(node, currentSessionId: currentSessionId, at: now)
        }
        if evicted > 0 {
            verificationNodeMayExist = field.containsNode { $0.turnKind == .verification }
        }
        return evicted
    }

    func workspaceEligible(
        _ node: CognitiveNode,
        currentSessionId: String?,
        at now: Date,
        turnKind resolvedTurnKind: CognitiveTurnKind? = nil
    ) -> Bool {
        switch resolvedTurnKind ?? node.turnKind {
        case .live, .system:
            return true
        case .debug, .verification:
            return false
        }
    }

    func capsuleEligibleWorkspaceNode(_ node: CognitiveNode) -> Bool {
        guard node.turnKind == .live else { return false }
        guard !isAssistantAuthoredFocus(node) else { return false }
        switch node.kind {
        case .conversationFocus, .correction:
            return !isCapsuleMetaOrOperationalTrace(node)
        case .toolObservation, .providerHealth, .workshopExecution, .appLifecycle, .feltResolution:
            return false
        }
    }

    private func isAssistantAuthoredFocus(_ node: CognitiveNode) -> Bool {
        if metadataString(node.metadata["role"])?.lowercased() == "assistant" {
            return true
        }
        let subjectType = node.subjectReference.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return subjectType == "chat.assistant_turn"
    }

    private func isCapsuleMetaOrOperationalTrace(_ node: CognitiveNode) -> Bool {
        let signals = [
            node.kind.rawValue,
            node.subjectReference.type,
            node.subjectReference.id,
            node.subjectReference.label ?? "",
            node.summary,
        ] + node.metadata.keys.sorted().flatMap { key -> [String] in
            [key] + jsonStringSignals(from: node.metadata[key] ?? .null)
        }
        let haystack = signals
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let markers = [
            "[cognitivesubstrate]",
            "cognitive capsule:",
            "cognition_microcycle",
            "cognitive_microcycle",
            "context.snapshot",
            "ctx-snapshot",
            "turncontext",
            "capsule injection",
            "cognitive preview",
            "rejectmemoryproposal",
            "memoryproposal rejected",
            "ios rejectmemoryproposal",
            "subconscious context is provisional runtime state",
            "provisional runtime state to read",
        ]
        return markers.contains { haystack.contains($0) }
    }

    private func verificationNodeExpired(
        _ node: CognitiveNode,
        currentSessionId: String?,
        at now: Date
    ) -> Bool {
        if let currentSessionId,
           let nodeSessionId = node.sessionId,
           !currentSessionId.isEmpty,
           !nodeSessionId.isEmpty,
           nodeSessionId != currentSessionId {
            return true
        }
        let age = max(0, now.timeIntervalSince(node.lastActivatedAt))
        return age >= Self.verificationWorkspaceMaxAge
    }

    func workspaceScore(
        for node: CognitiveNode,
        mood: CognitiveMoodReading,
        affect currentAffect: CognitiveAffectState,
        turnKind resolvedTurnKind: CognitiveTurnKind? = nil
    ) -> Double {
        let kindBoost: Double
        switch node.kind {
        case .correction: kindBoost = 0.15
        case .workshopExecution: kindBoost = 0.12
        case .providerHealth, .toolObservation: kindBoost = 0.08
        case .conversationFocus: kindBoost = 0.05
        case .appLifecycle: kindBoost = 0
        case .feltResolution: kindBoost = 0.06
        }
        let affectBoost = configuration.affectEnabled
            ? min(0.12, currentAffect.taskPressure * 0.08 + currentAffect.uncertainty * 0.04)
            : 0
        // Wave C mood-congruent recall — small, gated to felt nodes under a non-neutral
        // mood; 0 otherwise (byte-identical for legacy/neutral).
        let congruence = moodCongruence(for: node, mood: mood)
        let base = node.activation * 0.45 + node.salience * 0.35 + node.confidence * 0.2 + kindBoost + affectBoost + congruence
        let turnKindMultiplier: Double
        switch resolvedTurnKind ?? node.turnKind {
        case .live: turnKindMultiplier = 1
        case .system: turnKindMultiplier = 0.5
        case .debug: turnKindMultiplier = 0.05
        case .verification: turnKindMultiplier = 0.18
        }
        return clamp(base * turnKindMultiplier)
    }

    private func workspaceReasons(
        for node: CognitiveNode,
        associatedNodeIds: Set<UUID>,
        mood: CognitiveMoodReading,
        affect currentAffect: CognitiveAffectState,
        turnKind resolvedTurnKind: CognitiveTurnKind? = nil
    ) -> [String] {
        var reasons = ["activation", "salience"]
        if node.confidence >= 0.8 { reasons.append("high-confidence") }
        if node.kind == .correction { reasons.append("correction-priority") }
        let turnKind = resolvedTurnKind ?? node.turnKind
        if turnKind != .live { reasons.append("turn-\(turnKind.rawValue)") }
        if configuration.affectEnabled && currentAffect.taskPressure > 0.4 { reasons.append("task-pressure") }
        if associatedNodeIds.contains(node.id) { reasons.append("spreading-activation") }
        // Wave C: a meaningful mood-congruent contribution is named so provenance is honest.
        if moodCongruence(for: node, mood: mood) > Self.moodCongruenceReasonThreshold {
            reasons.append("mood-congruent")
        }
        return reasons
    }

}
