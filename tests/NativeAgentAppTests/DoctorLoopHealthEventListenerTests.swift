import Foundation
import Testing
import BackgroundLoops
@testable import NativeAgentApp

// Sweep R4 item 3, Doctor side. A loop whose event listener has died is still
// "running" and still has no recorded tick error — the two things Doctor used
// to judge on — so it reported green while the loop was event-blind.

private func observation(
    listener: LoopEventListenerHealth?,
    lastRun: Date,
    nextRun: Date
) -> LoopHealthObservation {
    LoopHealthObservation(
        loopId: "physiology",
        lastRun: lastRun,
        nextRun: nextRun,
        lastError: nil,
        running: true,
        eventListener: listener
    )
}

@Suite("Doctor loop health — event listeners")
struct DoctorLoopHealthEventListenerTests {

    @Test("a healthy listener leaves the verdict green")
    func healthyListenerStaysGreen() {
        let now = Date()
        let verdicts = DoctorLoopHealth.evaluate(
            observations: [observation(
                listener: LoopEventListenerHealth(active: true),
                lastRun: now.addingTimeInterval(-60),
                nextRun: now.addingTimeInterval(240)
            )],
            recentFailureDates: [:],
            now: now
        )
        #expect(verdicts.first?.level == .ok)
    }

    @Test("a running loop with a DOWN listener is no longer reported healthy")
    func downListenerBreaksTheGreenVerdict() throws {
        let now = Date()
        let verdicts = DoctorLoopHealth.evaluate(
            observations: [observation(
                listener: LoopEventListenerHealth(
                    active: false,
                    lastEndedAt: now.addingTimeInterval(-30),
                    restartCount: 1,
                    consecutiveEnds: 1,
                    lastError: "event stream ended (1 consecutive); restarting in 1s"
                ),
                lastRun: now.addingTimeInterval(-60),
                nextRun: now.addingTimeInterval(240)
            )],
            recentFailureDates: [:],
            now: now
        )
        let verdict = try #require(verdicts.first)
        #expect(verdict.level == .warn)
        #expect(verdict.detail.contains("Event listener is down"))
        #expect(verdict.detail.contains("1 restart"))
    }

    @Test("a listener that keeps ending escalates to a failure")
    func repeatedEndsEscalate() throws {
        let now = Date()
        let verdicts = DoctorLoopHealth.evaluate(
            observations: [observation(
                listener: LoopEventListenerHealth(
                    active: false,
                    lastEndedAt: now.addingTimeInterval(-10),
                    restartCount: 3,
                    consecutiveEnds: DoctorLoopHealth.eventListenerFailureThreshold,
                    lastError: "event stream ended (3 consecutive); restarting in 30s"
                ),
                lastRun: now.addingTimeInterval(-60),
                nextRun: now.addingTimeInterval(240)
            )],
            recentFailureDates: [:],
            now: now
        )
        #expect(verdicts.first?.level == .fail)
    }

    @Test("a listener warning never downgrades a harder tick-failure verdict")
    func listenerNeverDowngradesAHarderVerdict() throws {
        let now = Date()
        let failing = LoopHealthObservation(
            loopId: "physiology",
            lastRun: now.addingTimeInterval(-60),
            nextRun: now.addingTimeInterval(240),
            lastError: "provider timeout",
            running: true,
            eventListener: LoopEventListenerHealth(
                active: false,
                lastEndedAt: now,
                restartCount: 1,
                consecutiveEnds: 1,
                lastError: "event stream ended"
            )
        )
        let verdicts = DoctorLoopHealth.evaluate(
            observations: [failing],
            recentFailureDates: ["physiology": [
                now.addingTimeInterval(-100),
                now.addingTimeInterval(-200),
                now.addingTimeInterval(-300),
            ]],
            now: now
        )
        #expect(verdicts.first?.level == .fail)
        #expect(verdicts.first?.detail.contains("Failing persistently") == true)
        #expect(verdicts.first?.detail.contains("Event listener") == true)
    }

    @Test("loops with no event lane are judged exactly as before")
    func nonEventLoopsAreUnchanged() {
        let now = Date()
        let verdicts = DoctorLoopHealth.evaluate(
            observations: [observation(
                listener: nil,
                lastRun: now.addingTimeInterval(-60),
                nextRun: now.addingTimeInterval(240)
            )],
            recentFailureDates: [:],
            now: now
        )
        #expect(verdicts.first?.level == .ok)
        #expect(verdicts.first?.detail == "Healthy.")
    }
}
