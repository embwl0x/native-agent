// Wave 1 closes formerly reports-only feed/background rows with hermetic
// decisions. These tests deliberately read no developer data root.

import Foundation
import Testing
import BackgroundLoops
import PersistenceCore
@testable import NativeAgentApp

@Suite("Wave 1 feed and background contracts", .serialized)
struct FeedAndBackgroundWave1ContractTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-Wave1-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("the unconditional loop manifest is exact and remote loops stay configuration-gated")
    func assembleAllLoopsHasThePinnedManifestAndNegativeControls() async throws {
        let root = try temporaryRoot("manifest")
        defer { try? FileManager.default.removeItem(at: root) }

        let loops = BackgroundLoopsAssembly.assembleAllLoops(dataRoot: root)
        let ids = loops.map(\.loopId)
        let unconditional: Set<String> = [
            "doctor_auto_run", "turn_trace_retention",
            "evolution_proposal_retention", "data_root_disk_hygiene", "memory_consolidation",
            "self_improvement_sweep", "trigger_scheduler_due_work",
            "mission_executor", "workshop_pump", "cognition_maintenance", "cognition_replay",
            "cognition_reflection", "heartbeat", "self_healing", "autonomy_promotion_proposals",
            "desk_notify", "delegation_outcome", "github_tracking",
        ]
        // C8 (2026-08-28) CHANGED what "configuration-gated" means for the two
        // remote surfaces. They used to be ABSENT from the manifest with no
        // config on disk — which made "off because there is no token" and "we
        // never built it" the same observable state: nothing in `status()`,
        // nothing in Doctor, nothing in the app. They are now always REGISTERED,
        // with a placeholder that skips every tick and never does remote work,
        // so the lane is visible and (past the dormancy bound) flagged.
        //
        // The gate that actually matters is unchanged and is asserted below:
        // with no config, the registered runner must not be the real one.
        let expected = unconditional.union(["telegram_poll", "slack_socket_mode"])
        #expect(ids.count == expected.count, "a duplicate id overwrites a loop inside the manager")
        #expect(Set(ids) == expected, "a missing manifest id silently deletes its owner from production")
        #expect(!ids.contains("dream_cycle"), "the TriggerScheduler owns the nightly dream deadline")
        // Retired 2026-08-31. `nativeagent-weekly-rem` (Sun 04:30 America/Chicago)
        // is the sole owner of weekly REM; a duplicate loop here ticks, produces
        // nothing, and eventually trips Doctor's dormancy bound on a healthy lane.
        #expect(!ids.contains("rem_cycle"), "the TriggerScheduler owns the weekly REM deadline")
        // Negative control for the retirement: the surviving weekly lanes that
        // share rem_cycle's cadence and its stale-looking 2026-08-28 tick stamp
        // are NOT duplicates and must stay registered — memory_consolidation is
        // the only producer of the weekly memory-hygiene approval card, and
        // self_improvement_sweep the only producer of the weekly digest.
        #expect(ids.contains("memory_consolidation"))
        #expect(ids.contains("self_improvement_sweep"))
        #expect(ids.contains("trigger_scheduler_due_work"),
                "the nightly-dream / weekly-REM owner must stay registered")

        for remoteId in ["telegram_poll", "slack_socket_mode"] {
            let runner = try #require(loops.first { $0.loopId == remoteId })
            #expect(
                runner is BackgroundLoopsAssembly.UnconfiguredLaneLoop,
                "\(remoteId) built a REAL remote loop with no configuration on disk"
            )
            guard case .skipped(let reason, _) = await runner.tickOutcome() else {
                Issue.record("\(remoteId) placeholder did not skip")
                continue
            }
            #expect(reason.contains("not configured"))
        }
    }

    @Test("turn-summary vocabulary forces an explicit phone-snapshot decision for every declared kind")
    func turnSummaryVocabularyPartitionsTheInstrumentContract() throws {
        let repo = try AppSourceScraping.repositoryRoot()
        let instrument = try String(contentsOf: repo.appendingPathComponent("script/agent_instrument.swift"), encoding: .utf8)
        guard let start = instrument.range(of: "let declaredTraceKinds: [String: String] = ["),
              let end = instrument[start.upperBound...].range(of: "\n]")
        else {
            Issue.record("could not locate the declared trace-kind contract")
            return
        }
        let body = String(instrument[start.upperBound..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*:\s*"#, options: [.anchorsMatchLines])
        let declared: Set<String> = Set(regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[range])
        })
        #expect(!declared.isEmpty)
        #expect(TurnSummaryComputer.allowedKinds.isDisjoint(with: TurnSummaryComputer.deliberatelyIgnoredKinds),
                "a kind cannot be both serializable and ignored")
        #expect(TurnSummaryComputer.allowedKinds.union(TurnSummaryComputer.deliberatelyIgnoredKinds) == declared,
                "a trace emitter changed without a deliberate iOS snapshot decision")

        // Negative control: an explicitly ignored lifecycle event remains in
        // the bounded `other` bucket, while the allowed tool event keeps its
        // own name and no free-form kind can enter the snapshot.
        #expect(!TurnSummaryComputer.allowedKinds.contains("turn.accepted"))
        #expect(TurnSummaryComputer.deliberatelyIgnoredKinds.contains("turn.accepted"))
        #expect(TurnSummaryComputer.allowedKinds.contains("tool.dispatch"))
    }
}
