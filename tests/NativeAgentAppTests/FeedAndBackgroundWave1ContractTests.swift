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
    func assembleAllLoopsHasThePinnedManifestAndNegativeControls() throws {
        let root = try temporaryRoot("manifest")
        defer { try? FileManager.default.removeItem(at: root) }

        let loops = BackgroundLoopsAssembly.assembleAllLoops(dataRoot: root)
        let ids = loops.map(\.loopId)
        let expected: Set<String> = [
            "doctor_auto_run", "full_mac_expiry", "turn_trace_retention",
            "evolution_proposal_retention", "data_root_disk_hygiene", "memory_consolidation",
            "self_improvement_sweep", "rem_cycle", "trigger_scheduler_due_work",
            "mission_executor", "workshop_pump", "cognition_maintenance", "cognition_replay",
            "cognition_reflection", "heartbeat", "self_healing", "autonomy_promotion_proposals",
            "desk_notify", "delegation_outcome", "github_tracking",
        ]
        #expect(ids.count == expected.count, "a duplicate id overwrites a loop inside the manager")
        #expect(Set(ids) == expected, "a missing manifest id silently deletes its owner from production")
        #expect(!ids.contains("telegram_poll"))
        #expect(!ids.contains("slack_socket_mode"))
        #expect(!ids.contains("dream_cycle"), "the TriggerScheduler owns the nightly dream deadline")
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
