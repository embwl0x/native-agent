import Foundation
import Testing
@testable import NativeAgentApp

/// The probe exists to answer the 04:05 pin's open question — WHICH rows the
/// transcript's layout time goes to. An instrument that silently records
/// nothing would answer it with a confident, empty ledger, so its arithmetic
/// and its off-switch are pinned here.
private let TranscriptLayoutProbeLedgerCap = TranscriptLayoutLedger.maximumRowsPerWindowForTesting

@Suite("Transcript layout probe", .serialized)
struct TranscriptLayoutProbeTests {

    @Test func theProbeIsOffUnlessTheEnvironmentTurnsItOn() {
        // A measuring instrument wired into every transcript row must not be
        // something a release build pays for. The modifier returns `content`
        // untouched when this is false.
        #expect(TranscriptLayoutProbe.isEnabled ==
                (ProcessInfo.processInfo.environment["NATIVEAGENT_TRANSCRIPT_LAYOUT_PROBE"] == "1"))
    }

    @Test func theDisabledModifierAddsNoLayoutNode() throws {
        // The meter is a real `Layout`; inserting one changes the view tree.
        // Off must mean absent, not present-and-idle.
        let source = try AppSourceScraping.appSource("TranscriptLayoutProbe.swift")
        #expect(source.contains("if TranscriptLayoutProbe.isEnabled {"))
        #expect(source.contains("} else {\n            self\n        }"))
    }

    @Test func theMeterPassesTheProposalStraightThrough() throws {
        // The instrument must not become the thing it measures: it returns the
        // child's own size and places it at the origin with the same proposal,
        // so a probed transcript lays out identically to an unprobed one.
        let source = try AppSourceScraping.appSource("TranscriptLayoutProbe.swift")
        #expect(source.contains("let size = subview.sizeThatFits(proposal)"))
        #expect(source.contains("anchor: .topLeading"))
        #expect(source.contains("proposal: proposal"))
    }

    @Test func theLedgerAccumulatesPerRowAndRanksByTotalTime() throws {
        // One row measured eighty times and eighty rows measured once are the
        // two competing explanations for 3,393 `sizeThatFits` frames in one
        // sample. The ledger has to be able to tell them apart.
        let ledger = TranscriptLayoutLedger.shared
        ledger.flush()  // start from a clean window

        for _ in 0..<80 { ledger.record(rowID: "hot", kind: "bubble", nanos: 1_000_000) }
        ledger.record(rowID: "cold", kind: "bubble", nanos: 2_000_000)

        let window = try #require(ledger.snapshotForTesting())
        let hot = try #require(window["hot"])
        let cold = try #require(window["cold"])

        #expect(hot.measures == 80)
        #expect(hot.totalNanos == 80_000_000)
        #expect(hot.maxNanos == 1_000_000)
        // Ranked by TOTAL, not by worst single measure — the pin is death by a
        // thousand cheap re-measures, which a max-only ledger would hide.
        #expect(hot.totalNanos > cold.totalNanos)
        #expect(cold.maxNanos > hot.maxNanos)

        ledger.flush()
        #expect(ledger.snapshotForTesting()?.isEmpty != false)
    }

    @Test func theLedgerRefusesToGrowWithoutBound() {
        // A dictionary keyed by row id, written from the layout hot path, is
        // its own leak if nothing caps it.
        let ledger = TranscriptLayoutLedger.shared
        ledger.flush()
        for index in 0..<(TranscriptLayoutProbeLedgerCap + 50) {
            ledger.record(rowID: "row-\(index)", kind: "bubble", nanos: 1_000)
        }
        // The invariant is the CAP, not an exact count: `record` also flushes
        // on a five-second boundary, so a window may legitimately have rolled
        // over mid-loop. What must never happen is unbounded growth.
        let window = ledger.snapshotForTesting() ?? [:]
        #expect(window.count <= TranscriptLayoutProbeLedgerCap)
        #expect(window.count > 0)
        ledger.flush()
    }
}
