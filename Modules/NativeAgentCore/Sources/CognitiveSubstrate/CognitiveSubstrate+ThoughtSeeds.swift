// CognitiveSubstrate+ThoughtSeeds.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    static let thoughtSeedPriorityHalfLife: TimeInterval = 24 * 60 * 60
    static let minimumRetainedThoughtSeedPriority = 0.05

    @discardableResult
    public func addThoughtSeed(
        kind: CognitiveThoughtSeedKind,
        text: String,
        priority: Double,
        sourceNodeIds: [UUID] = []
    ) async -> CognitiveThoughtSeed? {
        await waitForMaintenanceTransition()
        return await addThoughtSeed(
            kind: kind,
            text: text,
            priority: priority,
            sourceNodeIds: sourceNodeIds,
            marksSubstrateDirty: true
        )
    }

    /// The microcycle may synthesize a seed while settling the dirty state it
    /// already consumed. That internal mutation is persisted by the same cycle
    /// and must not manufacture another pending settle. All external callers use
    /// the public overload above and continue to mark the substrate dirty.
    func addThoughtSeed(
        kind: CognitiveThoughtSeedKind,
        text: String,
        priority: Double,
        sourceNodeIds: [UUID],
        marksSubstrateDirty: Bool
    ) async -> CognitiveThoughtSeed? {
        guard configuration.enabled, configuration.thoughtSeedsEnabled else { return nil }
        let trimmed = bounded(text.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 240)
        guard !trimmed.isEmpty, configuration.maximumThoughtSeeds > 0 else { return nil }
        let now = dependencies.now()
        let key = thoughtSeedKey(kind: kind, text: trimmed)
        if let existingID = thoughtSeeds.values.first(where: { thoughtSeedKey(kind: $0.kind, text: $0.text) == key })?.id,
           var existing = thoughtSeeds[existingID] {
            let previous = thoughtSeeds
            // Merge against the priority that is true now. Without this, an old
            // unmaterialized seed can retain its stale high checkpoint merely
            // because the five-minute maintenance loop did not run first.
            existing.priority = min(1, max(effectiveThoughtSeedPriority(existing, at: now), priority))
            existing.lastUpdatedAt = now
            existing.sourceNodeIds = unique(existing.sourceNodeIds + sourceNodeIds)
            thoughtSeeds[existingID] = existing
            if marksSubstrateDirty { markDirty(at: now) }
            thoughtSeedRevision &+= 1
            if !marksSubstrateDirty {
                // The dirty microcycle folds this family into its one canonical
                // cognition transaction. Do not open a competing SQLite write
                // for the same transition.
                return existing
            }
            let revision = thoughtSeedRevision
            do {
                try await persistThoughtSeedFamily()
            } catch {
                if thoughtSeedRevision == revision {
                    thoughtSeeds = previous
                    thoughtSeedRevision &+= 1
                }
                return thoughtSeeds[existingID]
            }
            return existing
        }

        let previous = thoughtSeeds
        let seed = CognitiveThoughtSeed(
            id: dependencies.makeUUID(),
            kind: kind,
            text: trimmed,
            priority: priority,
            createdAt: now,
            lastUpdatedAt: now,
            sourceNodeIds: unique(sourceNodeIds)
        )
        thoughtSeeds[seed.id] = seed
        if marksSubstrateDirty { markDirty(at: now) }
        enforceThoughtSeedCap(at: now)
        thoughtSeedRevision &+= 1
        if !marksSubstrateDirty {
            return thoughtSeeds[seed.id]
        }
        let revision = thoughtSeedRevision
        do {
            try await persistThoughtSeedFamily()
        } catch {
            if thoughtSeedRevision == revision {
                thoughtSeeds = previous
                thoughtSeedRevision &+= 1
            }
            return nil
        }
        return thoughtSeeds[seed.id]
    }

    public func decayThoughtSeeds() async {
        await waitForMaintenanceTransition()
        // Review round 2 (MED): this public entry persists the thought-seed
        // family, so it must also respect the MICROCYCLE's commit window
        // (R-F2's maintenanceCommitInFlight), not just the maintenance gate —
        // otherwise it can reproduce the exact seed-family disk race R-F2
        // closes. No production caller hits this today; skip-and-let-the-next-
        // pass-decay matches how maintenance itself yields to the window.
        guard !maintenanceCommitInFlight else { return }
        guard configuration.enabled, configuration.thoughtSeedsEnabled else { return }
        let now = dependencies.now()
        let previous = thoughtSeeds
        let changed = decayThoughtSeedsInMemory(at: now)
        guard changed else { return }
        thoughtSeedRevision &+= 1
        let revision = thoughtSeedRevision
        do {
            try await persistThoughtSeedFamily()
        } catch {
            if thoughtSeedRevision == revision {
                thoughtSeeds = previous
                thoughtSeedRevision &+= 1
            }
        }
    }

    /// Await-free maintenance primitive. The public lifecycle helper retains
    /// its checked family write; the full maintenance pass folds this exact
    /// mutation into its larger SQLite transaction instead.
    @discardableResult
    func decayThoughtSeedsInMemory(at now: Date) -> Bool {
        guard configuration.enabled, configuration.thoughtSeedsEnabled else { return false }
        var changed = false
        for id in thoughtSeeds.keys {
            guard var seed = thoughtSeeds[id] else { continue }
            let elapsed = max(0, now.timeIntervalSince(seed.lastUpdatedAt))
            guard elapsed > 0 else { continue }
            changed = true
            seed.priority = effectiveThoughtSeedPriority(seed, at: now)
            seed.lastUpdatedAt = now
            if seed.priority < Self.minimumRetainedThoughtSeedPriority {
                thoughtSeeds.removeValue(forKey: id)
            } else {
                thoughtSeeds[id] = seed
            }
        }
        return changed
    }

    public func thoughtSeedSnapshot() async -> [CognitiveThoughtSeed] {
        projectedThoughtSeeds(at: dependencies.now()).sorted(by: thoughtSeedPrioritySort)
    }

    public func thoughtSuggestionSnapshot(
        surface: String = "observatory",
        limit: Int = 5,
        minimumInterruptionScore: Double = 0.45
    ) async -> [CognitiveThoughtSuggestion] {
        guard configuration.enabled, configuration.thoughtSeedsEnabled, limit > 0 else { return [] }
        let boundedSurface = bounded(surface.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 80)
        let workspace = await workspaceSnapshot()
        let now = workspace.generatedAt
        let activeWorkspaceNodeIds = Set(workspace.items.map(\.node.id))
        let currentAffect = projectedAffect(at: now)
        return projectedThoughtSeeds(at: now).compactMap { seed in
            let workspaceNodeIds = seed.sourceNodeIds.filter { activeWorkspaceNodeIds.contains($0) }
            let score = interruptionScore(
                for: seed,
                workspaceNodeIds: workspaceNodeIds,
                affect: currentAffect,
                at: now
            )
            guard score >= (minimumInterruptionScore).clamped01() else { return nil }
            return CognitiveThoughtSuggestion(
                id: stableArtifactID("thought_suggestion|\(seed.id.uuidString)|\(boundedSurface)"),
                seedId: seed.id,
                kind: seed.kind,
                text: seed.text,
                interruptionScore: score,
                priority: seed.priority,
                createdAt: now,
                surface: boundedSurface.isEmpty ? "observatory" : boundedSurface,
                reason: thoughtSuggestionReason(
                    for: seed,
                    workspaceNodeIds: workspaceNodeIds,
                    affect: currentAffect
                ),
                sourceNodeIds: seed.sourceNodeIds,
                workspaceNodeIds: workspaceNodeIds
            )
        }
        .sorted { lhs, rhs in
            if lhs.interruptionScore != rhs.interruptionScore { return lhs.interruptionScore > rhs.interruptionScore }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.seedId.uuidString < rhs.seedId.uuidString
        }
        .prefix(limit)
        .map { $0 }
    }

    func thoughtSeedPrioritySort(_ lhs: CognitiveThoughtSeed, _ rhs: CognitiveThoughtSeed) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Priority at an explicit instant without changing the seed's persisted
    /// anchor. Every read/selection path uses this one law; maintenance merely
    /// materializes the same value when a durable checkpoint is warranted.
    func effectiveThoughtSeedPriority(_ seed: CognitiveThoughtSeed, at now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(seed.lastUpdatedAt))
        let factor = pow(0.5, elapsed / Self.thoughtSeedPriorityHalfLife)
        return (seed.priority * factor).clamped01()
    }

    /// Pure bounded family projection. Expired seeds disappear from live reads
    /// immediately even if their physical deletion waits for maintenance.
    func projectedThoughtSeeds(at now: Date) -> [CognitiveThoughtSeed] {
        guard configuration.enabled, configuration.thoughtSeedsEnabled else { return [] }
        return thoughtSeeds.values.compactMap { stored in
            var projected = stored
            projected.priority = effectiveThoughtSeedPriority(stored, at: now)
            guard projected.priority >= Self.minimumRetainedThoughtSeedPriority else { return nil }
            return projected
        }
    }

    func isUsefulThoughtSeed(_ seed: CognitiveThoughtSeed) -> Bool {
        let lower = seed.text.lowercased()
        guard !isOperationalSubconsciousNoise(lower) else { return false }
        if seed.kind != .reflectionTakeaway, isRuntimeMetaStatement(lower) {
            return false
        }
        return !isConversationalPresenceStatement(lower)
    }

    private func enforceThoughtSeedCap(at now: Date) {
        guard thoughtSeeds.count > configuration.maximumThoughtSeeds else { return }
        let victims = thoughtSeeds.values
            .sorted { lhs, rhs in
                let lhsPriority = effectiveThoughtSeedPriority(lhs, at: now)
                let rhsPriority = effectiveThoughtSeedPriority(rhs, at: now)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt < rhs.lastUpdatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(thoughtSeeds.count - configuration.maximumThoughtSeeds)
            .map(\.id)
        for victim in victims { thoughtSeeds.removeValue(forKey: victim) }
    }

    private func interruptionScore(
        for seed: CognitiveThoughtSeed,
        workspaceNodeIds: [UUID],
        affect currentAffect: CognitiveAffectState,
        at now: Date
    ) -> Double {
        let ageHours = max(0, now.timeIntervalSince(seed.lastUpdatedAt) / 3_600)
        let recency = max(0, 1 - min(ageHours / 48, 1))
        let workspaceBoost = workspaceNodeIds.isEmpty ? 0 : 0.14
        let pressureBoost = currentAffect.taskPressure * 0.07
        let uncertaintyBoost = currentAffect.uncertainty * 0.06
        let score = seed.priority * 0.62
            + thoughtSeedKindBoost(seed.kind)
            + workspaceBoost
            + recency * 0.06
            + pressureBoost
            + uncertaintyBoost
        return clamp(score)
    }

    private func thoughtSeedKindBoost(_ kind: CognitiveThoughtSeedKind) -> Double {
        switch kind {
        case .reflectionTakeaway:
            return 0.16
        case .anomaly:
            return 0.14
        case .followUp:
            return 0.10
        case .openQuestion:
            return 0.04
        }
    }

    private func thoughtSuggestionReason(
        for seed: CognitiveThoughtSeed,
        workspaceNodeIds: [UUID],
        affect currentAffect: CognitiveAffectState
    ) -> String {
        var parts: [String] = []
        switch seed.kind {
        case .reflectionTakeaway:
            parts.append("reflection takeaway")
        case .anomaly:
            parts.append("anomaly")
        case .followUp:
            parts.append("follow-up")
        case .openQuestion:
            parts.append("open question")
        }
        if !workspaceNodeIds.isEmpty {
            parts.append("active workspace evidence")
        }
        if currentAffect.taskPressure >= 0.35 {
            parts.append("task pressure")
        }
        if currentAffect.uncertainty >= 0.35 {
            parts.append("uncertainty")
        }
        return bounded(parts.joined(separator: ", "), maxCharacters: 160)
    }

    private func thoughtSeedKey(kind: CognitiveThoughtSeedKind, text: String) -> String {
        "\(kind.rawValue)|\(text.lowercased().split(separator: " ").joined(separator: " "))"
    }

    func restoreThoughtSeeds(from payloads: [JSONValue]) {
        thoughtSeeds.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let kindRaw = stringValue(object["kind"]),
                  let kind = CognitiveThoughtSeedKind(rawValue: kindRaw),
                  let text = stringValue(object["text"]),
                  let priority = doubleValue(object["priority"]),
                  let createdAt = dateValue(object["createdAt"]),
                  let lastUpdatedAt = dateValue(object["lastUpdatedAt"]) else {
                continue
            }
            thoughtSeeds[id] = CognitiveThoughtSeed(
                id: id,
                kind: kind,
                text: text,
                priority: priority,
                createdAt: createdAt,
                lastUpdatedAt: lastUpdatedAt,
                sourceNodeIds: uuidArrayValue(object["sourceNodeIds"])
            )
        }
        enforceThoughtSeedCap(at: dependencies.now())
        thoughtSeedRevision &+= 1
    }
}
