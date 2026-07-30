import Testing
import Foundation
@testable import BackgroundLoops

// Tightness round 2 P-M2: EvolutionProposalStore.sweep() had zero production
// callers, so proposals.json never pruned. EvolutionProposalRetentionLoop gives
// it a weekly driver. These pin that the tick invokes the injected sweep and
// reports its outcome honestly.

private final class SweepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let removed: Int
    private let shouldThrow: Bool
    init(removed: Int = 0, shouldThrow: Bool = false) {
        self.removed = removed
        self.shouldThrow = shouldThrow
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func run() throws -> Int {
        lock.lock(); _calls += 1; lock.unlock()
        if shouldThrow {
            throw NSError(domain: "test", code: 1)
        }
        return removed
    }
}

@Test func evolutionRetention_loopId_and_interval() {
    let loop = EvolutionProposalRetentionLoop(sweep: { 0 })
    #expect(loop.loopId == "evolution_proposal_retention")
    #expect(loop.interval == 7 * 24 * 60 * 60)
}

@Test func evolutionRetention_tickInvokesSweep() async {
    let recorder = SweepRecorder(removed: 3)
    let loop = EvolutionProposalRetentionLoop(sweep: { try recorder.run() })
    let outcome = await loop.tickOutcome()
    #expect(recorder.calls == 1)
    #expect(outcome == .completed(result: "evolution proposal sweep removed 3"))
}

@Test func evolutionRetention_sweepFailureIsHonest() async {
    let recorder = SweepRecorder(shouldThrow: true)
    let loop = EvolutionProposalRetentionLoop(sweep: { try recorder.run() })
    let outcome = await loop.tickOutcome()
    #expect(recorder.calls == 1)
    if case .failed = outcome {} else {
        Issue.record("expected .failed, got \(outcome)")
    }
}
