import Foundation
import Testing
@testable import CognitiveSubstrate

// Sweep item 41 — reflection is admitted by unresolved LOAD, under a hard cost
// ceiling per rolling 24h. The day counter is demoted to that ceiling's ledger:
// it says how much a hard day may ever spend, never that a quiet one should.
private final class AdmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) { self.current = current }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private func makeAdmissionSubstrate(
    clock: AdmissionClock,
    ceiling: Int = 2
) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            observatoryEnabled: true,
            dailyReflectionCallBudget: ceiling
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: { clock.now() },
            makeUUID: { UUID() },
            userName: { "User" }
        )
    )
}

/// A hard day: a standing backlog of seeds worth interrupting for, and an
/// undertone that has actually moved. All three existing signals, no new ones.
private func buildUnresolvedLoad(_ substrate: CognitiveSubstrate, _ clock: AdmissionClock) async {
    for index in 0..<6 {
        _ = await substrate.addThoughtSeed(
            kind: .anomaly,
            text: "the migration path for step \(index) still contradicts what the store reports",
            priority: 0.9
        )
    }
    await substrate.integrateDisposition(tone: -1, at: clock.now())
}

@discardableResult
private func spendOneReflection(
    _ substrate: CognitiveSubstrate,
    reason: String
) async -> CognitiveReflectionReceipt? {
    guard let request = await substrate.planReflection(reason: reason) else { return nil }
    return await substrate.recordReflectionResult(
        request: request,
        resultSummary: "no provider call made in test",
        provider: "test-provider"
    )
}

@Suite("Reflection admission by unresolved load")
struct ReflectionLoadAdmissionTests {

    @Test("a quiet day spends nothing even with the whole ceiling free")
    func zeroLoadRefusesTheCallWhileTheCeilingHasRoom() async throws {
        let clock = AdmissionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = makeAdmissionSubstrate(clock: clock)

        let admission = await substrate.reflectionAdmission(demand: .spontaneous)
        #expect(admission.admitted == false)
        #expect(admission.reason == CognitiveSubstrate.reflectionRefusalLoadBelowThreshold)
        #expect(admission.load == 0)
        // The ceiling is untouched — this is a refusal of DEMAND, not of budget.
        #expect(admission.callsInWindow == 0)
        #expect(admission.ceiling == 2)

        guard case .refused = await substrate.planReflectionChecked(
            reason: "nothing is pressing",
            demand: .spontaneous
        ) else {
            Issue.record("a quiet day planned a reflection anyway")
            return
        }

        // A person asking is never told her seeds are too quiet.
        #expect(await substrate.planReflection(reason: "User pressed the button") != nil)
    }

    @Test("a hard day earns the call")
    func highLoadAdmitsTheCall() async throws {
        let clock = AdmissionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = makeAdmissionSubstrate(clock: clock)
        await buildUnresolvedLoad(substrate, clock)

        let load = await substrate.reflectionUnresolvedLoad(at: clock.now())
        #expect(load.backlog > 0)
        #expect(load.urgency > 0)
        #expect(load.drift > 0)

        let admission = await substrate.reflectionAdmission(demand: .spontaneous)
        #expect(admission.admitted, "load \(admission.load) did not clear \(admission.threshold)")
        #expect(admission.reason == "admitted")

        guard case .admitted = await substrate.planReflectionChecked(
            reason: "the commit signal reached her",
            demand: .spontaneous
        ) else {
            Issue.record("a hard day was refused a reflection")
            return
        }
    }

    @Test("every load in the world cannot spend past the ceiling")
    func ceilingReachedRefusesWithItsOwnReason() async throws {
        let clock = AdmissionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = makeAdmissionSubstrate(clock: clock, ceiling: 2)
        await buildUnresolvedLoad(substrate, clock)

        for index in 0..<2 {
            clock.advance(60)
            let receipt = await spendOneReflection(substrate, reason: "spend \(index)")
            #expect(receipt != nil, "the ceiling refused a call it still had room for")
        }

        let admission = await substrate.reflectionAdmission(demand: .spontaneous)
        #expect(admission.admitted == false)
        #expect(admission.reason == CognitiveSubstrate.reflectionRefusalCeilingReached)
        #expect(admission.callsInWindow == 2)
        // The hard fence outranks demand: an explicit ask is refused too.
        let asked = await substrate.reflectionAdmission(demand: .requested)
        #expect(asked.reason == CognitiveSubstrate.reflectionRefusalCeilingReached)
        #expect(await substrate.planReflection(reason: "ask anyway") == nil)
    }

    @Test("the cost window rolls instead of resetting at midnight")
    func rollingWindowRolls() async throws {
        let clock = AdmissionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = makeAdmissionSubstrate(clock: clock, ceiling: 1)
        await buildUnresolvedLoad(substrate, clock)
        #expect(await spendOneReflection(substrate, reason: "the one call") != nil)

        // Twenty-three hours later the spend is still on the books, whatever the
        // calendar says about it.
        clock.advance(23 * 60 * 60)
        let midWindow = await substrate.reflectionAdmission(demand: .spontaneous)
        #expect(midWindow.reason == CognitiveSubstrate.reflectionRefusalCeilingReached)
        #expect(midWindow.callsInWindow == 1)

        clock.advance(60 * 60 + 60)
        #expect(await substrate.reflectionCallsInCostWindow(at: clock.now()) == 0)
        await buildUnresolvedLoad(substrate, clock)
        let rolled = await substrate.reflectionAdmission(demand: .spontaneous)
        #expect(rolled.admitted, "the rolling window did not free the slot: \(rolled.detail)")
    }
}
