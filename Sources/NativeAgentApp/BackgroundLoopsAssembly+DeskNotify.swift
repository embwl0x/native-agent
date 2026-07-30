import Foundation
import BackgroundLoops
import PersistenceCore

// MARK: - Desk notify loop (desk-side push, NO cognition)
//
// A throttled, desk-local loop that lets the Desk tap User on the shoulder: it
// reads desk state, asks DeskNotifyEvaluator which direct/urgent items changed
// since their last ping (cooldown-gated), fires a Mac banner + paired-device
// push for each, then stamps lastNotifiedAt so a single change can't fan out
// into duplicate pings (Agent's idempotency requirement).
//
// This NEVER touches the CognitiveSubstrate — it's a SEPARATE loop from the
// cognition manifest in assembleAllLoops. The desk reaches out to User; it does
// not live in her head (User's hard line, 2026-06-29). Self-gating: with no
// item marked direct/urgent, every tick is a cheap state-read that returns nil.

extension BackgroundLoopsAssembly {
    static func makeDeskNotifyLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 24 * 60 * 60
    ) -> some LoopRunner {
        DeskNotifyRunner(interval: intervalSeconds, dataRoot: dataRoot)
    }
}

private struct DeskNotifyRunner: EventDeadlineLoopRunner {
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "desk_notify" }
    var tickTimeoutOverride: TimeInterval? { 30 }

    func physiologyEvents() -> AsyncStream<Void> {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: [store.opsPath, store.statePath],
            stores: [.desk]
        )
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() else {
            return nil
        }
        return DeskNotifyEvaluator.nextMeaningfulDeadline(state, after: now)
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do {
            state = try await store.liveState()
        } catch {
            return .failed(error: "Desk notification state read: \(error)")
        }
        let decisions = DeskNotifyEvaluator.decisions(state, now: Date())
        guard !decisions.isEmpty else { return .skipped(reason: "no Desk notification due") }

        var failures: [String] = []
        for decision in decisions {
            // Dual delivery: Mac banner + paired-device push (the same backends
            // mac_notify / mobile_notify use). Best-effort; outcomes logged so a
            // failure isn't silent. v1 marks after attempting; success-gated retry
            // with backoff is a noted refinement (failures here are near-always a
            // permanent notification-setup issue, where retry only spams).
            let macResult = await NativeAgentNotifications.postAndReport(title: decision.title, body: decision.body)
            let mobileOK = (try? await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: decision.title,
                body: decision.body,
                userInfo: ["screen": "inbox", "source": "desk"]
            )) != nil
            // Log BOTH channel outcomes so no failure is silent (Agent review).
            if !macResult.posted {
                NSLog("desk_notify: Mac banner failed for \(decision.handle)")
                failures.append("\(decision.handle) Mac banner")
            }
            if !mobileOK {
                NSLog("desk_notify: paired-device push failed for \(decision.handle)")
                failures.append("\(decision.handle) paired-device push")
            }
            // Stamp lastNotifiedAt via CAS on the NOTIFIED version: if a content
            // change landed during this tick, skip the stamp so the next tick
            // pings the newer state (no lost ping). markNotified does NOT bump
            // updatedAt, so it can never re-trigger itself.
            do {
                _ = try await store.markNotifiedIfUnchanged(decision.handle, expectedUpdatedAt: decision.observedUpdatedAt)
            } catch {
                NSLog("desk_notify: stamp failed for \(decision.handle): \(error) — may re-ping next tick")
                failures.append("\(decision.handle) notification stamp: \(error)")
            }
        }
        if !failures.isEmpty {
            return .failed(error: "Desk notification partial failure: "
                + failures.prefix(5).joined(separator: "; "))
        }
        return .completed(result: "sent \(decisions.count) Desk notification(s)")
    }
}
