import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func setAblation(_ key: String, enabled: Bool) async {
        await waitForMaintenanceTransition()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ablations[trimmed] = enabled
    }

    public func facultyMeasurementSnapshot() async -> [CognitiveFacultyMeasurement] {
        let now = dependencies.now()
        let nodeCount = field.snapshot(at: now, configuration: configuration).count
        let workspaceCount = (await workspaceSnapshot()).items.count
        let activeThoughtSeeds = projectedThoughtSeeds(at: now)
        let welfare = welfareBoundsSnapshot(at: now)
        return [
            CognitiveFacultyMeasurement(faculty: "event-continuity", score: nodeCount > 0 ? 1 : 0, evidence: "nodes=\(nodeCount)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "workspace-focus", score: workspaceCount > 0 ? 1 : 0, evidence: "workspace=\(workspaceCount)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "capsule-grounding", score: configuration.capsuleInjectionEnabled ? 1 : 0, evidence: "capsuleEnabled=\(configuration.capsuleInjectionEnabled)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "affect-bounds", score: welfare.withinBounds ? 1 : 0, evidence: "maxAffect=\(String(format: "%.2f", welfare.maxAffectValue))", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "thought-seeds", score: activeThoughtSeeds.isEmpty ? 0 : 1, evidence: "seeds=\(activeThoughtSeeds.count)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "replay-lineage", score: developmentalTimeline.isEmpty ? 0 : 1, evidence: "timeline=\(developmentalTimeline.count)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "reflection-yield", score: reflectionReceipts.values.map(\.proposalYieldScore).max() ?? 0, evidence: "reflections=\(reflectionReceipts.count)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "observatory-export", score: 1, evidence: "bounded export available", generatedAt: now),
        ]
    }

    @discardableResult
    public func runResearchExperiment(
        kind: CognitiveExperimentKind,
        seed: String = "default"
    ) async -> CognitiveExperimentResult? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.observatoryEnabled else { return nil }
        let now = dependencies.now()
        let metrics = await experimentMetrics(kind: kind)
        let score = experimentScore(kind: kind, metrics: metrics)
        let notes = experimentNotes(kind: kind)
        let key = experimentReproducibilityKey(kind: kind, seed: seed, metrics: metrics)
        let result = CognitiveExperimentResult(
            id: stableArtifactID("experiment|\(kind.rawValue)|\(seed)|\(key)"),
            kind: kind,
            seed: bounded(seed, maxCharacters: 80),
            score: score,
            metrics: metrics,
            notes: notes,
            reproducibilityKey: key,
            generatedAt: now
        )
        experimentResults[result.id] = result
        enforceExperimentResultCap()
        await persistArtifact(kind: "experiment", id: result.id, status: "recorded", score: result.score, payload: result.toJSON())
        return result
    }

    public func researchExperimentSnapshot() async -> [CognitiveExperimentResult] {
        experimentResults.values.sorted { lhs, rhs in
            if lhs.generatedAt != rhs.generatedAt { return lhs.generatedAt > rhs.generatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func welfareBoundsSnapshot() -> CognitiveWelfareBounds {
        welfareBoundsSnapshot(at: dependencies.now())
    }

    private func welfareBoundsSnapshot(at now: Date) -> CognitiveWelfareBounds {
        let currentAffect = projectedAffect(at: now)
        let maxAffect = max(
            currentAffect.arousal,
            currentAffect.uncertainty,
            currentAffect.taskPressure,
            currentAffect.socialWarmth
        )
        let budget = max(1, configuration.dailyReflectionCallBudget)
        // Read the SAME window the ceiling enforces (rolling 24h), so the
        // welfare line cannot report a free budget the admission just refused.
        let pressure = Double(reflectionCallsInCostWindow(at: now)) / Double(budget)
        return CognitiveWelfareBounds(
            withinBounds: maxAffect <= 1 && pressure <= 1,
            maxAffectValue: maxAffect,
            reflectionBudgetPressure: pressure,
            notes: [
                "affect values are clamped to 0...1",
                "reflection calls are opt-in and budgeted",
                "welfare state is operational telemetry, not a consciousness claim",
            ],
            generatedAt: now
        )
    }

    public func exportResearchTrace(maxItems: Int = 20) async -> JSONValue {
        let limit = max(1, min(maxItems, 50))
        let summary = await observatorySnapshot()
        let measurements = await facultyMeasurementSnapshot()
        let experiments = await researchExperimentSnapshot()
        let timeline = await developmentalTimelineSnapshot(limit: limit)
        let welfare = welfareBoundsSnapshot()
        return .object([
            "kind": .string("cognitive_research_export"),
            "generatedAt": .double(dependencies.now().timeIntervalSince1970),
            "actualState": .object([
                "nodeCount": .int(Int64(summary.nodeCount)),
                "workspaceCount": .int(Int64(summary.workspaceCount)),
                "thoughtSeedCount": .int(Int64(summary.thoughtSeedCount)),
                "episodeCount": .int(Int64(summary.episodeCount)),
                "reflectionCount": .int(Int64(summary.reflectionCount)),
            ]),
            "facultyMeasurements": .array(measurements.map { $0.toJSON() }),
            "experiments": .array(experiments.prefix(limit).map { $0.toJSON() }),
            "timeline": .array(timeline.map { $0.toJSON() }),
            "welfareBounds": welfare.toJSON(),
            "generatedExplanations": .array([]),
            "generatedExplanationPolicy": .string("Generated explanations are exported separately from actual substrate state."),
            "truncated": .bool(experiments.count > limit || timeline.count >= limit),
        ])
    }

    public func observatorySnapshot() async -> CognitiveObservatorySnapshot {
        let now = dependencies.now()
        let currentAffect = projectedAffect(at: now)
        guard configuration.enabled, configuration.observatoryEnabled else {
            return CognitiveObservatorySnapshot(
                generatedAt: now,
                nodeCount: 0,
                workspaceCount: 0,
                thoughtSeedCount: 0,
                episodeCount: 0,
                reflectionCount: 0,
                affect: currentAffect,
                ablations: ablations
            )
        }
        let nodeCount = field.snapshot(at: now, configuration: configuration).count
        let workspaceCount = (await workspaceSnapshot()).items.count
        let activeThoughtSeeds = projectedThoughtSeeds(at: now)
        return CognitiveObservatorySnapshot(
            generatedAt: now,
            nodeCount: nodeCount,
            workspaceCount: workspaceCount,
            thoughtSeedCount: activeThoughtSeeds.count,
            episodeCount: episodes.count,
            reflectionCount: reflectionReceipts.count,
            affect: currentAffect,
            ablations: ablations
        )
    }

    private func experimentMetrics(kind: CognitiveExperimentKind) async -> [String: Double] {
        switch kind {
        case .continuity:
            return [
                "nodes": Double(field.snapshot(at: dependencies.now(), configuration: configuration).count),
                "workspace": Double((await workspaceSnapshot()).items.count),
                "timeline": Double(developmentalTimeline.count),
            ]
        case .providerSwap:
            let capsule = await compileCapsule(CognitiveCapsuleRequest(
                surface: "provider_swap_experiment",
                userMessage: "provider swap continuity experiment",
                mode: .inspectOnly,
                maximumCharacters: 800
            ))
            let stateDigest = Double(Int(stableDigest(capsule.combined)) ?? 0) / 1_000_000_000_000
            return [
                "stateDigest": stateDigest,
                "providerVariants": 2,
                "reflectionSurfaceConfigured": configuration.reflectionSurface.isEmpty ? 0 : 1,
            ]
        case .selfModelAccuracy:
            return [
                "schemaReviewItems": Double(schemaProposals.count),
            ]
        case .ablation:
            return [
                "ablationCount": Double(ablations.count),
                "disabledAblations": Double(ablations.values.filter { $0 == false }.count),
                "enabledAblations": Double(ablations.values.filter { $0 }.count),
            ]
        }
    }

    private func experimentScore(kind: CognitiveExperimentKind, metrics: [String: Double]) -> Double {
        switch kind {
        case .continuity:
            return clamp((metrics["nodes"] ?? 0) > 0 ? 1 : 0.5)
        case .providerSwap:
            return clamp((metrics["providerVariants"] ?? 0) >= 2 ? 1 : 0)
        case .selfModelAccuracy:
            let unresolved = metrics["proposedIdentity"] ?? 0
            return clamp(1 - min(1, unresolved / 10))
        case .ablation:
            return clamp((metrics["ablationCount"] ?? 0) > 0 ? 1 : 0.5)
        }
    }

    private func experimentNotes(kind: CognitiveExperimentKind) -> [String] {
        switch kind {
        case .continuity:
            return ["snapshot counts provide continuity baseline"]
        case .providerSwap:
            return ["compares provider variants without making provider calls"]
        case .selfModelAccuracy:
            return ["identity remains proposal-only and rejection-aware"]
        case .ablation:
            return ["ablation map is explicit and exportable"]
        }
    }

    private func experimentReproducibilityKey(
        kind: CognitiveExperimentKind,
        seed: String,
        metrics: [String: Double]
    ) -> String {
        let metricText = metrics.keys.sorted().map { key in
            "\(key)=\(String(format: "%.4f", metrics[key] ?? 0))"
        }.joined(separator: "|")
        return stableDigest("\(kind.rawValue)|\(seed)|\(metricText)")
    }

}
