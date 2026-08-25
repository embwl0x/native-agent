import Foundation
import Testing
@testable import ChatOrchestration

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.trace.attentionStageAllowlist (silent zero by allowlist)
//   * chat.trace.attentionRecorder       (silent zero — an uninstalled recorder
//                                         is indistinguishable from a fast turn)
//
// `CognitiveAttentionTraceRecorder.recordElapsed` drops any stage name not in a
// five-element literal with no return value, no log and no counter. A rename in
// the caller therefore makes that stage's timing vanish from every snapshot
// while `totalMilliseconds` keeps growing — a slowdown nobody can attribute.
@Suite("eval: attention trace stage allowlist")
struct EvalAttentionStageAllowlistTests {

    /// The five names the turn engine's abandon-latch snapshot is allowed to
    /// carry. Held here as a frozen manifest ON PURPOSE: this list and the one
    /// inside the recorder are the two ends of the contract, so a one-sided
    /// edit fails here instead of quietly shortening every snapshot.
    private static let permittedStages = [
        "actorAdmission", "bootstrap", "substrate", "organism", "pursuit",
    ]

    @Test func everyPermittedStageSurvivesIntoTheSnapshot() {
        let recorder = CognitiveAttentionTraceRecorder()
        let start = DispatchTime.now().uptimeNanoseconds
        for stage in Self.permittedStages {
            recorder.recordElapsed(stage, since: start)
        }
        let snapshot = recorder.snapshot()
        #expect(Set(snapshot.stagesMilliseconds.keys) == Set(Self.permittedStages))
        #expect(snapshot.stagesMilliseconds.values.allSatisfy { $0 >= 0 })
    }

    /// `recordAdmission()` is the one stage the recorder names for itself; it
    /// must be inside its own allowlist or the very first measurement of every
    /// turn is dropped.
    @Test func theRecordersOwnAdmissionStageIsInsideItsAllowlist() {
        let recorder = CognitiveAttentionTraceRecorder()
        recorder.recordAdmission()
        #expect(recorder.snapshot().stagesMilliseconds["actorAdmission"] != nil)
    }

    /// THE FAILURE MODE, pinned: a renamed / misspelled / newly added stage is
    /// dropped in total silence — no throw, no counter, no marker key — while
    /// total time keeps accruing. Anyone who changes this behaviour (e.g. by
    /// adding the droppedStageCount the ledger asks for) will land here.
    @Test func anUnlistedStageIsDroppedWithNoObservableTrace() {
        let recorder = CognitiveAttentionTraceRecorder()
        let start = DispatchTime.now().uptimeNanoseconds
        recorder.recordElapsed("substrate", since: start)
        let before = recorder.snapshot()

        for renamed in ["resident", "Substrate", "substrate ", "cognitive.substrate", ""] {
            recorder.recordElapsed(renamed, since: start)
        }
        let after = recorder.snapshot()

        // The dictionary is byte-identical: nothing anywhere says five stages
        // were thrown away.
        #expect(after.stagesMilliseconds == before.stagesMilliseconds)
        #expect(after.stagesMilliseconds.count == 1)
        // ...and total time keeps ticking independently, which is exactly the
        // shape of an unattributable slowdown.
        #expect(after.totalMilliseconds >= before.totalMilliseconds)
        #expect(after.completed == false)
        #expect(after.cancellationObserved == false)
    }

    /// The recorder's own silent-zero: a turn where nobody installed a recorder
    /// and a turn where the provider recorded nothing produce the SAME snapshot.
    /// This is the evidence gap behind "cognitive stages all read 0ms" — the
    /// test exists so that ambiguity is a stated contract, not a discovery.
    @Test func aNeverRecordedTurnIsIndistinguishableFromAnUninstalledRecorder() {
        let neverInstalled = CognitiveAttentionTraceRecorder().snapshot()
        let installedButSilent = CognitiveAttentionTraceRecorder()
        installedButSilent.recordElapsed("a-stage-nobody-allowlisted", since: DispatchTime.now().uptimeNanoseconds)
        let silent = installedButSilent.snapshot()

        #expect(neverInstalled.stagesMilliseconds.isEmpty)
        #expect(silent.stagesMilliseconds.isEmpty)
        #expect(neverInstalled.completed == silent.completed)
        #expect(neverInstalled.cancellationObserved == silent.cancellationObserved)
    }

    /// The abandon-latch evidence fields must be settable and readable — they
    /// are the only proof the 250ms ResumeGuard bit rather than the read simply
    /// being fast.
    @Test func latchEvidenceFieldsAreCarriedThroughTheSnapshot() {
        let recorder = CognitiveAttentionTraceRecorder()
        recorder.markCancellationObserved()
        recorder.markCompleted()
        let snapshot = recorder.snapshot()
        #expect(snapshot.cancellationObserved)
        #expect(snapshot.completed)
    }
}
