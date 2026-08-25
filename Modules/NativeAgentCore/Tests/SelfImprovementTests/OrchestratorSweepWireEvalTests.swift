import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore
import NativeAgentTestSupport

// MARK: - core.loops eval wave — the pending_actions remove path + its wire
//
// Closes si.orchestrator.runSweepOnce.
//
// `SelfImprovementOrchestrator.sweep()` is the ONLY remove path for terminal
// `improvements/pending_actions.json` entries, and `runSweepOnce()` is the
// zero-arg wrapper its own doc comment says the app calls. Two evals here:
//
//   1. the REMOVE PATH's contract, asserted (state-lifecycle class — every add
//      path needs a remove path, and this one had no test at all);
//   2. a source-conformance pin on the WIRE, because the wrapper has no
//      production caller while a comment in
//      Sources/NativeAgentApp/BackgroundLoopsManagerComposition.swift asserts
//      that "Core's actor answers `.shared.runSweepOnce()` directly".

private func sweepFixture(_ tag: String, entries: [[String: Any]]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("si-sweep-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("improvements", isDirectory: true),
        withIntermediateDirectories: true)
    // selfImprovementAvailable() gates every boundary on a `.git` directory;
    // a bare directory satisfies the existence check without a real repo.
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: entries)
    try data.write(to: root.appendingPathComponent("improvements/pending_actions.json"))
    return root
}

@Suite("core.loops · orchestrator sweep + wire")
struct OrchestratorSweepWireEvalTests {

    /// The remove path's envelope: only TERMINAL entries past the retention
    /// window leave; non-terminal work of any age survives; the report's own
    /// arithmetic is self-consistent (inspected == kept + removed); and the
    /// pruned set is persisted, not just held in memory.
    @Test func sweepRemovesOnlyAgedTerminalEntries_andPersistsTheResult() async throws {
        let fmt = ISO8601DateFormatter()
        // 10 days: past sweep's 7-day terminal cutoff, inside the orchestrator's
        // 14-day pending_actions retention window, so rehydrate expiry cannot be
        // the thing doing the removing.
        let aged = fmt.string(from: Date().addingTimeInterval(-10 * 86_400))
        let fresh = fmt.string(from: Date().addingTimeInterval(-3_600))
        let root = try sweepFixture("terminal", entries: [
            ["id": "old_promoted", "phase": "promoted", "status": "succeeded", "createdAt": aged],
            ["id": "old_reverted", "phase": "reverted", "status": "reverted", "createdAt": aged],
            ["id": "old_staged", "phase": "staged", "status": "staged", "createdAt": aged],
            ["id": "old_running", "phase": "running", "status": "running", "createdAt": aged],
            ["id": "fresh_promoted", "phase": "promoted", "status": "succeeded", "createdAt": fresh],
            ["id": "undateable_promoted", "phase": "promoted", "status": "succeeded"],
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let orch = SelfImprovementOrchestrator(dataRoot: root, repoRoot: root, packagePath: nil)
        let report = try await orch.sweep()

        #expect(report.ok)
        #expect(report.removed == 2, "exactly the two aged TERMINAL entries leave")
        #expect(report.inspected == report.kept + report.removed,
                "the report's own arithmetic must close")

        let surviving = Set(try await orch.listPending().map(\.id))
        #expect(surviving == ["old_staged", "old_running", "fresh_promoted", "undateable_promoted"],
                "non-terminal work of any age, fresh terminal work, and undateable rows all survive")

        // Persisted, not merely in-memory: a fresh actor over the same root
        // must see the pruned set.
        let reread = SelfImprovementOrchestrator(dataRoot: root, repoRoot: root, packagePath: nil)
        let onDisk = Set(try await reread.listPending().map(\.id))
        #expect(onDisk == surviving, "the sweep must rewrite pending_actions.json")

        // Idempotent: a second sweep removes nothing.
        let second = try await orch.sweep()
        #expect(second.removed == 0)
    }

    /// A non-repo install must not silently "sweep" — every boundary degrades
    /// to a shape-matched disabled result rather than reporting work done.
    @Test func sweepFailsClosedWithoutARepo() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("si-sweep-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let orch = SelfImprovementOrchestrator(dataRoot: root, repoRoot: root, packagePath: nil)
        let report = try await orch.sweep()
        #expect(report.ok == false)
        #expect(report.error == "no_git")
        #expect(report.removed == 0)
    }

    /// DEAD-WIRE PIN (source conformance, same shape as
    /// LoopRunnerCatchOverrideGuardTests). `runSweepOnce()` is documented as
    /// the wrapper the app calls, but no production source calls it — so
    /// `sweep()`, the only remove path above, never runs in the shipped app.
    ///
    /// This asserts the CURRENT, dead state on purpose so it is visible in the
    /// suite instead of only in a ledger row. When someone wires the loop, this
    /// test fails — that is the signal to flip the assertion to `>= 1` and mark
    /// si.orchestrator.runSweepOnce covered by a live wire.
    @Test func runSweepOnceStillHasNoProductionCaller() throws {
        let root = try SourceTreeRepoRoot.locate()
        let fm = FileManager.default
        let definitionFile = "Modules/NativeAgentCore/Sources/SelfImprovement/SelfImprovementOrchestrator.swift"

        var callSites: [String] = []
        var commentMentions: [String] = []

        for dir in ["Sources", "Modules"] {
            let base = root.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }
            guard let walker = fm.enumerator(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in walker {
                let name = url.lastPathComponent
                if name == ".build" || name == ".git" || name == "Tests" {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if rel == definitionFile { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard text.contains("runSweepOnce") else { continue }

                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    guard line.contains("runSweepOnce") else { continue }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Line-level comment filter: enough for this narrow probe —
                    // the only mentions in the tree are full-line `//` comments.
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") {
                        commentMentions.append("\(rel):\(offset + 1)")
                    } else {
                        callSites.append("\(rel):\(offset + 1)")
                    }
                }
            }
        }

        #expect(
            callSites.isEmpty,
            "runSweepOnce() now HAS a production caller (\(callSites.joined(separator: ", "))) — the sweep wire landed. Flip this assertion to require >= 1 and update the ledger row si.orchestrator.runSweepOnce."
        )
        #expect(
            !commentMentions.isEmpty,
            "expected the stale source comment that certifies the missing wire; if it is gone, re-check whether the wire itself landed."
        )
    }
}
