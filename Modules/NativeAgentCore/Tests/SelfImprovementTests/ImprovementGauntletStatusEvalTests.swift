import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

// MARK: - core.loops eval wave — gauntlet status read
//
// Closes si.improvementGauntletStatusLocal + si.gauntlet.improvementGauntletStatusLocal.
// A SHIPPED read surface (live caller: Sources/NativeAgentApp/NativeClient+SwiftRuntime.swift)
// with a UI destination and — before this file — no test anywhere.
//
// Two silent modes it guards:
//   1. DANGEROUS DEFAULT. `autoPromote` + `requiredChecks` are the gate that
//      decides whether an improvement promotes without a human. An absent or
//      corrupt gauntlet file degrading to a permissive table would be
//      invisible; here it is asserted fail-closed.
//   2. WRONG RUN / FABRICATED STATUS. `latest` is `runs[-1]` in RAW FILE ORDER
//      (NOT newest-by-timestamp, NOT reversed like list_improvements), and a
//      PRESENT-but-null status must stay nil rather than falling back to
//      "ready". Get either backwards and the panel shows the wrong run or a
//      status the file never said.

private struct GauntletFixture {
    let root: URL

    static func make(_ tag: String) throws -> GauntletFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("si-gauntlet-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("improvements/gauntlet", isDirectory: true),
            withIntermediateDirectories: true
        )
        return GauntletFixture(root: root)
    }

    func writeRuns(_ raw: String) throws {
        try Data(raw.utf8).write(
            to: root.appendingPathComponent("improvements/gauntlet/runs.json"),
            options: .atomic
        )
    }

    func client() -> SwiftNativeSelfImprovement { SwiftNativeSelfImprovement(dataRoot: root) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func stringField(_ value: JSONValue?, _ key: String) -> String? {
    guard case .object(let obj)? = value, case .string(let s)? = obj[key] else { return nil }
    return s
}

@Suite("core.loops · improvement gauntlet status")
struct ImprovementGauntletStatusEvalTests {

    /// `latestRun` is the LAST array element in raw file order. The fixture's
    /// last element is the OLDEST by `createdAt`, so a "sort by timestamp"
    /// or "reverse like list_improvements" regression picks a different run
    /// and fails. A present `status: null` stays nil — not "ready".
    @Test func latestRunIsLastFileElement_andPresentNullStatusStaysNil() async throws {
        let f = try GauntletFixture.make("order")
        defer { f.cleanup() }
        try f.writeRuns("""
        [
          {"id":"g1","createdAt":"2026-05-03T00:00:00Z","status":"passed"},
          {"id":"g2","createdAt":"2026-05-02T00:00:00Z","status":"failed"},
          {"id":"g3","createdAt":"2026-05-01T00:00:00Z","status":null}
        ]
        """)

        let status = await f.client().improvementGauntletStatusLocal(now: { "PINNED" })

        #expect(stringField(status.latestRun, "id") == "g3",
                "latestRun must be runs[-1] in raw file order, not newest-by-createdAt (g1) and not reversed-first (g1)")
        #expect(status.status == nil,
                "a PRESENT status:null must decode to nil — never fabricated as \"ready\"")
        #expect(status.runCount == 3)
        #expect(status.createdAt == "PINNED", "the timestamp source is injectable and used")
    }

    /// `runCount` is `len(runs)` over the RAW array — non-object junk entries
    /// are counted, not silently filtered. A count that quietly shrinks is the
    /// "dropped row" mode for this surface.
    @Test func runCountCountsRawArrayIncludingNonObjectEntries() async throws {
        let f = try GauntletFixture.make("count")
        defer { f.cleanup() }
        try f.writeRuns("""
        [{"id":"g1"}, 42, "junk", null, {"id":"g2","status":"passed"}]
        """)

        let status = await f.client().improvementGauntletStatusLocal(now: { "PINNED" })
        #expect(status.runCount == 5, "every raw element counts, junk included")
        #expect(status.status == "passed")
        #expect(stringField(status.latestRun, "id") == "g2")
    }

    /// Absent-key fallback: only a MISSING status key yields "ready".
    @Test func absentStatusKeyOnLastRunFallsBackToReady() async throws {
        let f = try GauntletFixture.make("absentkey")
        defer { f.cleanup() }
        try f.writeRuns(#"[{"id":"g1","status":"failed"},{"id":"g2"}]"#)

        let status = await f.client().improvementGauntletStatusLocal(now: { "PINNED" })
        #expect(status.status == "ready")
        #expect(stringField(status.latestRun, "id") == "g2")
    }

    /// FAIL-CLOSED GATE. Absent file, corrupt file, and an empty array all
    /// produce the SAME empty envelope — and, critically, the promotion-class
    /// table is the static 5-entry one in every case: an unreadable file can
    /// never widen `autoPromote` or empty out `requiredChecks`.
    @Test func absentCorruptAndEmpty_allYieldTheEmptyEnvelopeWithTheFailClosedTable() async throws {
        let absent = try GauntletFixture.make("absent")
        defer { absent.cleanup() }

        let corrupt = try GauntletFixture.make("corrupt")
        defer { corrupt.cleanup() }
        try corrupt.writeRuns(#"{"runs":[{"id":"g1","status":"passed"}]}"#)

        let torn = try GauntletFixture.make("torn")
        defer { torn.cleanup() }
        try torn.writeRuns(#"[{"id":"g1","#)

        let empty = try GauntletFixture.make("empty")
        defer { empty.cleanup() }
        try empty.writeRuns("[]")

        for f in [absent, corrupt, torn, empty] {
            let status = await f.client().improvementGauntletStatusLocal(now: { "PINNED" })
            #expect(status.runCount == 0)
            #expect(status.latestRun == nil)
            #expect(status.status == "ready", "the empty-state envelope, not a fabricated run status")
            assertFailClosedPromotionTable(status.promotionClasses)
        }
    }

    /// The promotion-class table is STATIC and does not depend on file
    /// contents — a populated file must not be able to move a gate either.
    @Test func promotionTableIsStaticAcrossFileContents() async throws {
        let f = try GauntletFixture.make("table")
        defer { f.cleanup() }
        try f.writeRuns("""
        [{"id":"g1","status":"passed","promotionClasses":[{"id":"swift","autoPromote":true,"requiredChecks":[]}]}]
        """)

        let status = await f.client().improvementGauntletStatusLocal(now: { "PINNED" })
        assertFailClosedPromotionTable(status.promotionClasses)
        #expect(status.promotionClasses == SwiftNativeSelfImprovement.staticGauntletPromotionClasses)
    }

    /// The gate envelope: exactly five classes, in a load-bearing order, with
    /// human-review REQUIRED for every class that can execute code (tool /
    /// daemon / swift), and no class ever carrying an empty check list.
    private func assertFailClosedPromotionTable(_ classes: [GauntletPromotionClass]) {
        #expect(classes.count == 5)
        #expect(classes.map(\.id) == ["prompt", "skill", "tool", "daemon", "swift"],
                "order is load-bearing for wire parity")
        for entry in classes {
            #expect(!entry.requiredChecks.isEmpty,
                    "\(entry.id) must never promote with zero required checks")
        }
        let autoPromoting = Set(classes.filter(\.autoPromote).map(\.id))
        #expect(autoPromoting == ["prompt", "skill"],
                "only prompt/skill may auto-promote; tool/daemon/swift require a human")
    }
}
