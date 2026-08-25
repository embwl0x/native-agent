import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

// MARK: - core.loops eval wave (ledger fence core.loops, 2026-08-23)
//
// Closes the crash-recovery + freshness-gate reads over
// `improvements/runs.json` that shipped with ZERO test references:
//   si.listImprovementsLocal            (silent zero)
//   si.markStaleImprovementsLocal       (state-lifecycle: the only remove path
//   si.client.markStaleImprovementsLocal  for a run wedged in `running`)
//   si.reconcileTransientPhasesLocal    (stuck state after a crash)
//   si.client.reconcileTransientPhasesLocal
//   si.improvementsCommitSeqLocal       (stale UI: freshness sentinel)
//   si.client.improvementsCommitSeqLocal
//   si.listImprovementsVerified         (present-null misclass: nil != [])
//
// Every case asserts an ENVELOPE property — ordering, which rows moved, which
// rows are byte-identical afterwards, which sentinel means "cannot prove
// freshness" — never a rendered string. Hermetic: each fixture pins its own
// temp dataRoot; nothing reads the live data root.

private struct ImprovementsFixture {
    let root: URL

    static func make(_ tag: String) throws -> ImprovementsFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("si-loops-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("improvements", isDirectory: true),
            withIntermediateDirectories: true
        )
        return ImprovementsFixture(root: root)
    }

    var runsPath: URL { root.appendingPathComponent("improvements/runs.json") }
    var commitPath: URL { root.appendingPathComponent("improvements/runs.commit") }

    func writeRuns(_ raw: String) throws {
        try Data(raw.utf8).write(to: runsPath, options: .atomic)
    }

    func writeCommit(_ raw: String) throws {
        try Data(raw.utf8).write(to: commitPath, options: .atomic)
    }

    /// Raw on-disk rows, so "untouched" can be proven against the bytes rather
    /// than against a re-decoded model (which would hide dropped unknown keys).
    func rawRuns() throws -> [[String: Any]] {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: runsPath))
        return (obj as? [[String: Any]]) ?? []
    }

    func client() -> SwiftNativeSelfImprovement {
        SwiftNativeSelfImprovement(dataRoot: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("core.loops · improvements local store")
struct ImprovementsLocalStoreEvalTests {

    // MARK: si.listImprovementsLocal

    /// ORDER is the contract: raw file order REVERSED, never re-sorted by
    /// `createdAt` (the daemon does not, and Swift parity matters). The fixture
    /// stores rows whose createdAt order DISAGREES with file order, so a secret
    /// re-sort — the plausible "helpful" regression — fails here.
    @Test func listImprovementsLocal_isFileOrderReversed_andSkipsUndecodableRows() async throws {
        let f = try ImprovementsFixture.make("list")
        defer { f.cleanup() }
        try f.writeRuns("""
        [
          {"id":"a","createdAt":"2026-01-03T00:00:00Z"},
          "not-an-object",
          {"id":"b","createdAt":"2026-01-01T00:00:00Z"},
          {"id":"c","createdAt":"2026-01-02T00:00:00Z"}
        ]
        """)

        let runs = try await f.client().listImprovementsLocal()
        #expect(
            runs.map(\.id) == ["c", "b", "a"],
            "must be raw file order REVERSED; sorting by createdAt would give [a, c, b]"
        )
    }

    /// SILENT-ZERO PIN. Absent, not-an-array, and torn-mid-write all collapse
    /// to the same empty list — three different facts rendered as "no
    /// improvement runs" with no error channel anywhere. This pins the gap so
    /// that adding a distinguishable failure is a deliberate change (see
    /// productionSeamNeeded on si.listImprovementsLocal), and so a future
    /// refactor cannot make the collapse *worse* unnoticed.
    @Test func listImprovementsLocal_absentCorruptAndTorn_areIndistinguishablyEmpty() async throws {
        let absent = try ImprovementsFixture.make("absent")
        defer { absent.cleanup() }
        let absentRuns = try await absent.client().listImprovementsLocal()
        #expect(absentRuns.isEmpty)

        let notArray = try ImprovementsFixture.make("notarray")
        defer { notArray.cleanup() }
        try notArray.writeRuns(#"{"runs":[{"id":"a"}]}"#)
        let notArrayRuns = try await notArray.client().listImprovementsLocal()
        #expect(notArrayRuns.isEmpty, "a JSON object where an array is expected reads as zero runs")

        let torn = try ImprovementsFixture.make("torn")
        defer { torn.cleanup() }
        try torn.writeRuns(#"[{"id":"a"},{"#)
        let tornRuns = try await torn.client().listImprovementsLocal()
        #expect(tornRuns.isEmpty, "a truncated file reads as zero runs, not as an error")
    }

    // MARK: si.markStaleImprovementsLocal / si.client.markStaleImprovementsLocal

    /// The ONLY remove path for a run wedged in `running` after a hard restart.
    /// Envelope: exactly the running rows move, the count returned equals the
    /// number moved, every other row survives BYTE-IDENTICAL (unknown keys
    /// included), and a second cold start is a no-op.
    @Test func markStaleImprovementsLocal_flipsOnlyRunningRows_andLeavesOthersByteIdentical() async throws {
        let f = try ImprovementsFixture.make("stale")
        defer { f.cleanup() }
        try f.writeRuns("""
        [
          {"id":"done","status":"succeeded","phase":"staged","summary":"kept","futureKey":"keep-me"},
          {"id":"live","status":"running","phase":"running","summary":"in flight"},
          {"id":"other","status":"staged","phase":"staged"}
        ]
        """)
        let before = try f.rawRuns()

        let changed = try await f.client().markStaleImprovementsLocal()
        #expect(changed == 1)

        let after = try f.rawRuns()
        #expect(after.count == before.count, "no row may be added or dropped")

        for id in ["done", "other"] {
            let b = try #require(before.first { $0["id"] as? String == id })
            let a = try #require(after.first { $0["id"] as? String == id })
            #expect(
                NSDictionary(dictionary: b).isEqual(to: a),
                "\(id) must survive verbatim — unknown/future keys included"
            )
        }

        let flipped = try #require(after.first { $0["id"] as? String == "live" })
        #expect(flipped["status"] as? String == "interrupted")
        #expect(flipped["phase"] as? String == "interrupted")
        #expect(
            (flipped["summary"] as? String) != "in flight",
            "the restart sentinel summary must replace the stale in-flight one"
        )
        #expect((flipped["summary"] as? String)?.isEmpty == false)

        let second = try await f.client().markStaleImprovementsLocal()
        #expect(second == 0, "a second cold start must not re-report work it did not do")
    }

    // MARK: si.reconcileTransientPhasesLocal / si.client.*

    /// Pins the NARROWER-THAN-DAEMON contract deliberately: only `phase` moves.
    /// `status`, `summary`, and any recovery flags are left alone and NO git
    /// state is recovered — a crash mid-promote still leaves an un-popped
    /// `nativeagent-promote-<id8>` stash behind. Keeping that gap asserted in
    /// the suite (instead of only in a doc comment) means the day someone
    /// widens or narrows the contract, this fails loudly.
    @Test func reconcileTransientPhasesLocal_mapsThreePhases_andRewritesNothingElse() async throws {
        let f = try ImprovementsFixture.make("reconcile")
        defer { f.cleanup() }
        try f.writeRuns("""
        [
          {"id":"p","phase":"promoting","status":"running","summary":"mid-promote"},
          {"id":"r","phase":"reverting","status":"running"},
          {"id":"d","phase":"discarding","status":"running"},
          {"id":"s","phase":"staged","status":"staged"},
          {"id":"u","phase":"who-knows","status":"running"}
        ]
        """)

        let changed = try await f.client().reconcileTransientPhasesLocal()
        #expect(changed == 3, "exactly the three transient phases move")

        let after = try f.rawRuns()
        var byId: [String: [String: Any]] = [:]
        for row in after {
            if let id = row["id"] as? String { byId[id] = row }
        }
        #expect(byId["p"]?["phase"] as? String == "staged")
        #expect(byId["r"]?["phase"] as? String == "promoted")
        #expect(byId["d"]?["phase"] as? String == "staged")
        #expect(byId["s"]?["phase"] as? String == "staged", "a terminal phase is left untouched")
        #expect(byId["u"]?["phase"] as? String == "who-knows", "an unknown phase is left untouched")

        // Documented divergence from the retired daemon — asserted, not assumed.
        #expect(byId["p"]?["status"] as? String == "running", "status is NOT rewritten to interrupted")
        #expect(byId["p"]?["summary"] as? String == "mid-promote", "summary is NOT rewritten")
        #expect(byId["p"]?.keys.contains("recoveryRequired") == false,
                "no recoveryRequired flag is set — the git-state gap stays visible")
        #expect(byId["p"]?.keys.contains("recoveryHint") == false)

        let second = try await f.client().reconcileTransientPhasesLocal()
        #expect(second == 0, "second pass must be a no-op")
    }

    // MARK: si.improvementsCommitSeqLocal / si.listImprovementsVerified

    /// The freshness gate whose WRITER is gone (the daemon stamped
    /// `runs.commit`; the daemon is retired and the file is absent live). The
    /// sentinel 0 must never masquerade as a passed freshness check: a
    /// verified read has to come back `nil` (unavailable), which is a
    /// different fact from `[]` (verified, none). That distinction is the whole
    /// point of the `[ImprovementRun]?` return type.
    @Test func verifiedRead_failsClosedOnEverySeqThatCannotProveFreshness() async throws {
        // (a) no marker at all — today's LIVE state.
        let absent = try ImprovementsFixture.make("seq-absent")
        defer { absent.cleanup() }
        try absent.writeRuns(#"[{"id":"a"}]"#)
        let absentClient = absent.client()
        let absentSeq = await absentClient.improvementsCommitSeqLocal()
        #expect(absentSeq == 0)
        let absentVerified = try await absentClient.listImprovementsVerified()
        #expect(absentVerified == nil, "seq 0 must read NOT-verified, never verified-at-zero")
        let absentPlain = try await absentClient.listImprovementsLocal()
        #expect(absentPlain.count == 1,
                "the unverified read still serves rows — nil and [] are different facts")

        // (b) ODD seq — a writer is mid-replace; runs.json may be torn.
        let odd = try ImprovementsFixture.make("seq-odd")
        defer { odd.cleanup() }
        try odd.writeRuns(#"[{"id":"a"}]"#)
        try odd.writeCommit(#"{"seq":3}"#)
        let oddClient = odd.client()
        let oddSeq = await oddClient.improvementsCommitSeqLocal()
        #expect(oddSeq == 3)
        let oddVerified = try await oddClient.listImprovementsVerified()
        #expect(oddVerified == nil, "an ODD seq means a write is in flight — must fail closed")

        // (c) seq 1 — mid-FIRST-write, still below the >= 2 floor.
        let first = try ImprovementsFixture.make("seq-one")
        defer { first.cleanup() }
        try first.writeRuns(#"[{"id":"a"}]"#)
        try first.writeCommit(#"{"seq":1}"#)
        let firstVerified = try await first.client().listImprovementsVerified()
        #expect(firstVerified == nil)

        // (d) EVEN >= 2 — quiescent; the local read is trusted and served in
        //     the SAME file-order-reversed order as the unverified read.
        let ok = try ImprovementsFixture.make("seq-even")
        defer { ok.cleanup() }
        try ok.writeRuns(#"[{"id":"a"},{"id":"b"}]"#)
        try ok.writeCommit(#"{"seq":4}"#)
        let okVerified = try await ok.client().listImprovementsVerified()
        let served = try #require(okVerified)
        #expect(served.map(\.id) == ["b", "a"])

        // (e) empty-but-verified is [] — the case that must NOT collapse to nil.
        let none = try ImprovementsFixture.make("seq-empty")
        defer { none.cleanup() }
        try none.writeRuns("[]")
        try none.writeCommit(#"{"seq":2}"#)
        let noneVerified = try await none.client().listImprovementsVerified()
        #expect(noneVerified != nil, "verification available with zero runs must be [], not nil")
        #expect(noneVerified?.isEmpty == true)
    }

    /// The seq reader's own envelope: anything it cannot prove is the SAME
    /// sentinel 0, and 0 is never a legal "fresh" value.
    @Test func improvementsCommitSeqLocal_collapsesEveryUnprovableMarkerToZero() async throws {
        let cases: [(String, String)] = [
            ("negative", #"{"seq":-4}"#),
            ("zero", #"{"seq":0}"#),
            ("string", #"{"seq":"7"}"#),
            ("missing-key", #"{"other":9}"#),
            ("not-an-object", #"[2]"#),
            ("garbage", "not json at all"),
        ]
        for (tag, body) in cases {
            let f = try ImprovementsFixture.make("seq-\(tag)")
            defer { f.cleanup() }
            try f.writeCommit(body)
            let seq = await f.client().improvementsCommitSeqLocal()
            #expect(seq == 0, "\(tag) marker must collapse to the not-provably-fresh sentinel")
        }

        // A real even marker is the only shape that reads through.
        let good = try ImprovementsFixture.make("seq-good")
        defer { good.cleanup() }
        try good.writeCommit(#"{"seq":6}"#)
        let goodSeq = await good.client().improvementsCommitSeqLocal()
        #expect(goodSeq == 6)
    }
}
