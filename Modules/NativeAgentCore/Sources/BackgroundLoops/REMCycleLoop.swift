import Foundation
import NativeAgentCore
import PersistenceCore
import DreamREMCycle

// REM-approval cutover (2026-06-10): the snake_case side-store at
// `<dataRoot>/harness/rem_proposals.jsonl` is RETIRED. The canonical store is
// `<dataRoot>/rem_proposals.jsonl` (camelCase `REMProposalRow`, owned by
// `REMProposalStore` in DreamREMCycle) — the same file the full pipeline
// appends to, the approval-resolve executor flips, and the rem_pins.json
// emitter derives from. The legacy file is imported once and renamed to
// `.migrated` by `importLegacyHarnessFileIfNeeded`.

/// Weekly REM consolidation loop. Once per ~7d, runs SwiftNativeREMConsolidator
/// over the last week of dream-diary entries, filters out tombstoned proposals,
/// triggers GROWTH.md eviction if the doc is near cap, and appends surviving
/// proposals to the canonical `<dataRoot>/rem_proposals.jsonl` store via the
/// shared flock'd appender, staging one approval record per new row.
///
/// tick() is non-throwing by LoopRunner contract — any error (consolidator
/// throw, IO failure) is caught and surfaced via stderr.
public struct REMCycleLoop: LoopRunner {
    public let loopId: String = "rem_cycle"
    public let interval: TimeInterval
    /// U5 W-D (2026-06-11): a tick runs the weekly REM consolidation — an
    /// LLM distillation over a week of dream-diary entries plus LLM-backed
    /// GROWTH eviction. The scheduler's default 300s budget cancels long
    /// LLM passes mid-call with no user-visible trace (audit 2026-06-09 —
    /// same lesson as telegram_poll / mission_executor).
    public var tickTimeoutOverride: TimeInterval? { 3600 }
    private let consolidator: SwiftNativeREMConsolidator
    private let tombstones: REMTombstoneStore
    private let growth: GrowthDocManager
    private let dataRoot: URL
    // BUG-C FIX: persona root is now an injected URL instead of always
    // `<dataRoot>/persona`. The default mirrors the canonical
    // PersistenceCore.defaultPersonaRoot resolution, while tests pin a tmpdir.
    private let personaRoot: URL
    private let dryRun: Bool
    private let clock: @Sendable () -> Date
    /// App-wired approval stager (ApprovalInbox record + inbox card). nil →
    /// appended proposals stay unstamped until a stager-carrying pass runs.
    private let stageApproval: REMApprovalStager?
    /// PATCH-2026-06-03 F5 fix #3+#4: when injected, tick() delegates to the
    /// full weekly REM pipeline (evidence floor, per-doc cap, REM-pins index
    /// emission, GROWTH eviction, 14-day archival). Default-nil keeps the
    /// existing tombstone-only path so the suite that pins the legacy shape
    /// stays green; BackgroundLoopsAssembly wires the full one in production.
    private let fullConsolidator: REMConsolidator?
    /// Advisory post-commit wake for derived cognition. The sink receives no
    /// proposal content and fires only after a successful tick durably adds
    /// replay-relevant canonical proposal evidence.
    private let replaySourceCommitted: (@Sendable () async -> Void)?

    /// Hard cap fed to GrowthDocManager.evictionCandidates when eviction trips.
    static let growthMaxBytes: Int = 50_000
    /// Size threshold above which the eviction path is taken.
    static let growthEvictThreshold: Int = 40_000

    public init(
        interval: TimeInterval = 604_800,
        consolidator: SwiftNativeREMConsolidator,
        tombstones: REMTombstoneStore,
        growth: GrowthDocManager,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        personaRoot: URL? = nil,
        dryRun: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() },
        fullConsolidator: REMConsolidator? = nil,
        stageApproval: REMApprovalStager? = nil,
        replaySourceCommitted: (@Sendable () async -> Void)? = nil
    ) {
        self.interval = interval
        self.consolidator = consolidator
        self.tombstones = tombstones
        self.growth = growth
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot ?? PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        self.dryRun = dryRun
        self.clock = clock
        self.fullConsolidator = fullConsolidator
        self.stageApproval = stageApproval
        self.replaySourceCommitted = replaySourceCommitted
    }

    public func tickOutcome() async -> LoopTickOutcome {
        // Canonical store open — the pipeline's first open on the tick path
        // triggers the one-time legacy import, and the staging catch-up
        // sweeps any pending row left unstamped by an earlier failed stage
        // (or just imported). Both idempotent; neither failure stops the tick.
        let store = REMProposalStore(dataRoot: dataRoot)
        // The report's generated count describes accepted model output, not
        // necessarily newly appended canonical rows. Snapshot opaque IDs so
        // the post-commit wake is tied to an actual source-of-truth delta.
        let replayEvidenceIDsBefore = Set(store.loadAll().map(\.id))
        var setupFailure: String?
        do {
            let imported = try await store.importLegacyHarnessFileIfNeeded()
            if imported > 0 {
                FileHandle.standardError.write(Data(
                    "REMCycleLoop: imported \(imported) legacy proposals\n".utf8
                ))
            }
            if let stageApproval {
                _ = try await store.stagePendingApprovals(stageApproval)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "REMCycleLoop: legacy import/staging failed: \(error)\n".utf8
            ))
            setupFailure = String(describing: error)
        }
        // PATCH-2026-06-03 F5 fix #3+#4: full pipeline wins when injected.
        // runWeeklyREM applies the evidence floor + per-doc cap, emits
        // rem_pins.json (the index buildTurnContext reads), and triggers
        // dream-diary archival. Trust-gate failure surfaces as a thrown
        // DreamREMCycleError and is logged via stderr just like any other
        // tick error; the loop never propagates.
        if let full = fullConsolidator {
            do {
                let report = try await full.runWeeklyREM()
                FileHandle.standardError.write(Data(
                    "REMCycleLoop[full]: proposals=\(report.proposalsGenerated) tomb=\(report.tombstoneSkips) evicted=\(report.growthMDEvicted) archived=\(report.archivedEntries)\n".utf8
                ))
                if let setupFailure {
                    return .failed(error: "REM setup: \(setupFailure)")
                }
                let replayEvidenceChanged = store.loadAll().contains {
                    !replayEvidenceIDsBefore.contains($0.id)
                }
                if replayEvidenceChanged {
                    await replaySourceCommitted?()
                }
                return .completed(result: "REM generated \(report.proposalsGenerated) proposal(s)")
            } catch {
                FileHandle.standardError.write(Data("REMCycleLoop[full]: tick failed: \(error)\n".utf8))
                return .failed(error: String(describing: error))
            }
        }
        do {
            let since = clock().addingTimeInterval(-7 * 86_400)
            let personaDocs = loadPersonaDocs()
            let proposals = try await consolidator.consolidate(since: since, personaDocs: personaDocs)
            if proposals.isEmpty {
                // Mirror the full pipeline's loud-drop diagnostics (gpt-5.5
                // review LOW, 2026-07-03): this legacy fallback used to return
                // silently, reproducing the write-only-counters failure the
                // repair exists to kill. Production assembly injects
                // fullConsolidator, so this only fires on the fallback path.
                let parseErrors = await consolidator.lastParseErrors
                let evidenceDrops = await consolidator.lastEvidenceDateDrops
                let targetDrops = await consolidator.lastTargetMismatchDrops
                if !parseErrors.isEmpty || evidenceDrops > 0 || targetDrops > 0 {
                    let msg = "REMCycleLoop[legacy]: zero proposals — parseErrors=\(parseErrors.count) "
                        + "evidenceDateDrops=\(evidenceDrops) targetMismatchDrops=\(targetDrops)\n"
                        + parseErrors.map { "  parse: \($0)\n" }.joined()
                    FileHandle.standardError.write(Data(msg.utf8))
                }
                if let setupFailure {
                    return .failed(error: "REM setup: \(setupFailure)")
                }
                return .skipped(reason: "REM produced no proposals")
            }

            var kept: [REMProposal] = []
            for p in proposals {
                let tomb = (try? await tombstones.isTombstoned(p)) ?? false
                if !tomb { kept.append(p) }
            }
            if kept.isEmpty {
                return .skipped(reason: "all REM proposals tombstoned")
            }
            if dryRun { return .skipped(reason: "REM dry run") }

            // GROWTH cap eviction (caller-side; helper returns the slice to drop).
            let size = await growth.growthSize()
            if size > Self.growthEvictThreshold {
                let slice = (try? await growth.evictionCandidates(maxBytes: Self.growthMaxBytes)) ?? ""
                if !slice.isEmpty {
                    try? await growth.deleteSlice(slice)
                }
            }

            // Canonical append: camelCase rows at <dataRoot>/rem_proposals.jsonl
            // via the shared flock'd, id-deduped appender — the same store the
            // full pipeline, the approval-resolve executor, and the pins
            // emitter agree on. Then stage ONE approval record per new row;
            // the stamp makes a re-run unable to double-stage the same id.
            let appended = try await store.appendPending(kept)
            var stagingFailure: String?
            if let stageApproval {
                do {
                    _ = try await store.stagePendingApprovals(stageApproval)
                } catch {
                    FileHandle.standardError.write(Data(
                        "REMCycleLoop: approval staging failed: \(error)\n".utf8
                    ))
                    stagingFailure = String(describing: error)
                }
            }
            FileHandle.standardError.write(Data("REMCycleLoop: appended \(appended) proposals\n".utf8))
            // EVALFIX2/R4: emit the rem_pins.json index after every legacy
            // tick so ChatOrchestration's per-turn REM-pin injection sees
            // freshly-approved entries. The full-pipeline path already does
            // this internally via runWeeklyREM step (8); the legacy path
            // wasn't, leaving rem_pins.json stale forever.
            try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
            if let setupFailure {
                return .failed(error: "REM setup: \(setupFailure)")
            }
            if let stagingFailure {
                return .failed(error: "REM approval staging: \(stagingFailure)")
            }
            let replayEvidenceChanged = store.loadAll().contains {
                !replayEvidenceIDsBefore.contains($0.id)
            }
            if replayEvidenceChanged {
                await replaySourceCommitted?()
            }
            return .completed(result: "REM appended \(appended) proposal(s)")
        } catch {
            FileHandle.standardError.write(Data("REMCycleLoop: tick failed: \(error)\n".utf8))
            return .failed(error: String(describing: error))
        }
    }

    /// BUG-C FIX: read persona docs from the resolved persona root, NOT
    /// `<dataRoot>/persona`. REM approval proposals are GROWTH-only; the
    /// full consolidator path still reads SOUL/VOICE/USER as read-only
    /// bypass context.
    private func loadPersonaDocs() -> [String: String] {
        var out: [String: String] = [:]
        for name in ["GROWTH"] {
            let url = personaRoot.appendingPathComponent("\(name).md")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out[name] = text
        }
        return out
    }
}
