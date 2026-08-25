import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

// MARK: - core.loops eval wave — improvement diff read
//
// Closes si.improvementDiffLocal + si.diff.improvementDiffLocal. This is the
// diff a human reads before approving a self-change, and nothing exercised the
// function that builds it: DiffTouchesSwiftTests covers `diffTouchesSwift`, a
// different function. The injectable `DiffGitProbe` seam exists precisely so
// this can be tested without a real git repo — and had zero users.
//
// Silent mode: `DiffGitProbe.live`'s closures are NON-THROWING and collapse any
// git failure (spawn error, timeout) to "". The reviewer then sees a
// well-formed payload with worktreeExists:true, diffText:"" and files:[] — "no
// changes" — for a run that really does have a diff, and approves blind.

private final class RecordingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private func note(_ name: String) { lock.lock(); calls.append(name); lock.unlock() }

    let diffText: String
    let numstatText: String
    let porcelainText: String
    let exists: Bool
    let onDiskReceipt: String?

    init(
        diffText: String = "",
        numstat: String = "",
        porcelain: String = "",
        exists: Bool = true,
        onDiskReceipt: String? = nil
    ) {
        self.diffText = diffText
        self.numstatText = numstat
        self.porcelainText = porcelain
        self.exists = exists
        self.onDiskReceipt = onDiskReceipt
    }

    func probe() -> SwiftNativeSelfImprovement.DiffGitProbe {
        SwiftNativeSelfImprovement.DiffGitProbe(
            diffCached: { [self] _ in note("diffCached"); return diffText },
            numstat: { [self] _ in note("numstat"); return numstatText },
            statusPorcelain: { [self] _ in note("statusPorcelain"); return porcelainText },
            directoryExists: { [self] _ in note("directoryExists"); return exists },
            receipt: { [self] _ in note("receipt"); return onDiskReceipt }
        )
    }
}

private struct DiffFixture {
    let root: URL

    static func make(_ tag: String, runs: String) throws -> DiffFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("si-diff-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("improvements", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(runs.utf8).write(
            to: root.appendingPathComponent("improvements/runs.json"), options: .atomic)
        return DiffFixture(root: root)
    }

    func client() -> SwiftNativeSelfImprovement { SwiftNativeSelfImprovement(dataRoot: root) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let oneRun = """
[
  {"id":"run-a","objective":"tighten the loop","phase":"staged","status":"succeeded",
   "worktree":"/tmp/does-not-matter/run-a","autonomyReceipt":"stored receipt"}
]
"""

@Suite("core.loops · improvement diff local")
struct ImprovementDiffLocalEvalTests {

    /// A missing run is a TYPED absence, not an empty diff. This is the one
    /// failure this surface reports honestly today, so pin it.
    @Test func unknownRunIdThrowsTypedNotFound() async throws {
        let f = try DiffFixture.make("notfound", runs: oneRun)
        defer { f.cleanup() }
        let recorder = RecordingProbe()

        do {
            _ = try await f.client().improvementDiffLocal(runId: "nope", probe: recorder.probe())
            Issue.record("a missing run must throw, not return an empty diff")
        } catch let error as ImprovementRunNotFound {
            #expect(error.runId == "nope", "the typed error must carry the id that was asked for")
        }
        #expect(recorder.calls.isEmpty, "a missing run must not touch the worktree at all")
    }

    /// Worktree absent: the git probes are never invoked and the receipt falls
    /// back to the STORED field. `worktreeExists:false` is the one signal that
    /// separates "nothing to show" from "could not look".
    @Test func absentWorktreeReportsFalse_skipsGitProbes_andKeepsStoredReceipt() async throws {
        let f = try DiffFixture.make("noworktree", runs: oneRun)
        defer { f.cleanup() }
        let recorder = RecordingProbe(exists: false)

        let payload = try await f.client().improvementDiffLocal(runId: "run-a", probe: recorder.probe())

        #expect(payload.worktreeExists == false)
        #expect(payload.diffText.isEmpty)
        #expect(payload.files.isEmpty)
        #expect(payload.receipt == "stored receipt")
        #expect(payload.runId == "run-a")
        #expect(payload.objective == "tighten the loop")
        #expect(payload.phase == "staged")
        #expect(payload.status == "succeeded")
        #expect(recorder.calls == ["directoryExists"],
                "no git subprocess may run against a worktree that is not there")
    }

    /// SILENT-EMPTY PIN. Every git probe fails (the `.live` closures return ""
    /// on spawn failure AND on timeout). The payload comes back as a
    /// well-formed SUCCESS: worktreeExists true, empty diff, zero files — and
    /// the payload type carries NO channel that could say otherwise. The
    /// structural half of this assertion is what bites: the day a
    /// reason/error/degraded field is added to ImprovementDiffPayload, this
    /// fails and the ledger row si.diff.improvementDiffLocal gets revisited.
    @Test func failedGitProbesRenderAsACleanDiffWithNoWayToTellThemApart() async throws {
        let f = try DiffFixture.make("silentempty", runs: oneRun)
        defer { f.cleanup() }
        let recorder = RecordingProbe(diffText: "", numstat: "", porcelain: "", exists: true)

        let payload = try await f.client().improvementDiffLocal(runId: "run-a", probe: recorder.probe())

        #expect(payload.worktreeExists == true)
        #expect(payload.diffText.isEmpty)
        #expect(payload.files.isEmpty)
        #expect(recorder.calls.contains("diffCached"))
        #expect(recorder.calls.contains("numstat"))
        #expect(recorder.calls.contains("statusPorcelain"))

        let fields = Set(Mirror(reflecting: payload).children.compactMap(\.label))
        #expect(
            fields == [
                "runId", "objective", "phase", "status", "worktree",
                "worktreeExists", "receipt", "diffText", "files",
            ],
            "ImprovementDiffPayload has no failure channel — a probe failure and a truly clean worktree are the same bytes. See productionSeamNeeded on si.diff.improvementDiffLocal; when a reason field lands, update this pin."
        )
    }

    /// The numstat/porcelain parse is what the reviewer's per-file counts come
    /// from. Envelope: one entry per numstat row, in numstat order, status
    /// joined from porcelain with an "M" default, binary rows ("-") counted as
    /// 0/0, and a malformed count pair collapsing BOTH sides to 0 rather than
    /// half-reporting.
    @Test func numstatAndPorcelainJoinIntoPerFileCounts() async throws {
        let f = try DiffFixture.make("parse", runs: oneRun)
        defer { f.cleanup() }
        let recorder = RecordingProbe(
            diffText: "diff --git a/Sources/A.swift b/Sources/A.swift\n+added\n",
            numstat: "12\t3\tSources/A.swift\n-\t-\tassets/logo.png\n0\t9\tdocs/B.md\nxx\t3\tSources/C.swift\n",
            porcelain: "A  Sources/A.swift\n?? assets/logo.png\n M docs/B.md\n",
            exists: true
        )

        let payload = try await f.client().improvementDiffLocal(runId: "run-a", probe: recorder.probe())

        #expect(payload.diffText.contains("Sources/A.swift"))
        #expect(payload.files.map(\.path)
                == ["Sources/A.swift", "assets/logo.png", "docs/B.md", "Sources/C.swift"],
                "one entry per numstat row, in numstat order")

        let byPath = Dictionary(uniqueKeysWithValues: payload.files.map { ($0.path, $0) })
        #expect(byPath["Sources/A.swift"]?.additions == 12)
        #expect(byPath["Sources/A.swift"]?.deletions == 3)
        #expect(byPath["Sources/A.swift"]?.status == "A")
        #expect(byPath["assets/logo.png"]?.additions == 0, "a binary '-' row counts as 0, not dropped")
        #expect(byPath["assets/logo.png"]?.deletions == 0)
        #expect(byPath["assets/logo.png"]?.status == "??")
        #expect(byPath["docs/B.md"]?.additions == 0)
        #expect(byPath["docs/B.md"]?.deletions == 9)
        #expect(byPath["docs/B.md"]?.status == "M")
        #expect(byPath["Sources/C.swift"]?.additions == 0,
                "a malformed count pair zeroes BOTH sides — never half-reports")
        #expect(byPath["Sources/C.swift"]?.deletions == 0)
        #expect(byPath["Sources/C.swift"]?.status == "M",
                "a path absent from porcelain defaults to M")
    }

    /// The on-disk AUTONOMY_RECEIPT.md wins over the stored field when the
    /// worktree is readable — the receipt the approver reads must be the one
    /// the run actually wrote.
    @Test func onDiskReceiptOverridesStoredReceipt() async throws {
        let f = try DiffFixture.make("receipt", runs: oneRun)
        defer { f.cleanup() }
        let recorder = RecordingProbe(exists: true, onDiskReceipt: "fresh from the worktree")

        let payload = try await f.client().improvementDiffLocal(runId: "run-a", probe: recorder.probe())
        #expect(payload.receipt == "fresh from the worktree")

        // Absent on-disk receipt keeps the stored one rather than blanking it.
        let noReceipt = RecordingProbe(exists: true, onDiskReceipt: nil)
        let fallback = try await f.client().improvementDiffLocal(runId: "run-a", probe: noReceipt.probe())
        #expect(fallback.receipt == "stored receipt")
    }
}
