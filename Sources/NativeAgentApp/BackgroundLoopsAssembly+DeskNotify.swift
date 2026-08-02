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
        let notify = DeskNotifyEvaluator.nextMeaningfulDeadline(state, after: now)
        // Nag lane deadlines (mute end / earliest in-scope defer end) share the
        // tick — load() is the same read-only, file-creating-nothing call the
        // nag pass uses for its inertness pre-check.
        let nag = DeskNagEvaluator.nextMeaningfulDeadline(
            state: state,
            config: await DeskNagConfigStore(dataRoot: dataRoot).load(),
            after: now
        )
        return [notify, nag].compactMap { $0 }.min()
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

        var failures: [String] = []
        // The nag pass runs on EVERY tick, not only when a direct/urgent ping
        // is due — its triggers (a blocker closing, a defer elapsing) have
        // nothing to do with the notify evaluator's decisions (gpt-5.5
        // campaign review, BLOCKING 1: the old early-return starved the nag
        // lane whenever no item was marked direct/urgent).
        let nagCount = await runNagPass(state: state, failures: &failures)
        if decisions.isEmpty && nagCount == 0 && failures.isEmpty {
            return .skipped(reason: "no Desk notification due")
        }
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
        return .completed(result: "sent \(decisions.count) Desk notification(s)"
            + (nagCount > 0 ? " + \(nagCount) nag(s)" : ""))
    }

    // MARK: - Nag lane (Wave 3)

    /// The nag pass rides the SAME tick and the SAME delivery path as the
    /// notify pass — one desk loop, two evaluators.
    ///
    /// SELF-GATING BY DEFAULT: with the global switch off (the fresh-install
    /// state) `evaluate` returns no nags, no digest, and the config UNCHANGED,
    /// so this pass never writes a file and never posts anything. Zero
    /// behaviour change until User opts in.
    ///
    /// DELIVERY RULE (Agent's, enforced here and not only in the trigger):
    /// digest lines are NEVER pushed on their own. Stale-and-static rides along
    /// with a nag that was already going out, or with the unmute drift report.
    /// Nags always go out at `.digest` level — this lane cannot escalate.
    private func runNagPass(state: DeskState, failures: inout [String]) async -> Int {
        let configStore = DeskNagConfigStore(dataRoot: dataRoot)
        // Cheap unlocked pre-check ONLY to preserve fresh-install inertness
        // (a disabled config never even opens the flock, so no file is ever
        // created). Every decision below re-reads the config INSIDE the lock —
        // this pre-check is an optimization, never an authority (gpt-5.5
        // campaign review, BLOCKING 2+3: deciding on an unlocked snapshot let
        // the loop resurrect a config User had just changed via
        // desk_nag_control, and clear a fresh mute he set mid-tick).
        guard await configStore.load().enabled else { return 0 }

        let now = Date()
        let plan = DeskSequencing.compute(state, now: now)

        // Everything — the enabled check, the expired-mute transition, and the
        // evaluation — happens in ONE locked read-modify-write against the
        // CURRENT config, so a concurrent desk_nag_control call can never be
        // overwritten by a stale snapshot. Persist-before-deliver is preserved:
        // `updating` writes the returned config before we post anything.
        enum NagAction: Sendable {
            case none
            case unmuteDigest([String])
            case fire(DeskNagEvaluator.Outcome)
        }
        let action: NagAction
        do {
            let (_, act) = try await configStore.updating { current -> (DeskNagConfig, NagAction) in
                guard current.enabled else { return (current, .none) }
                // A mute that has EXPIRED is a transition the loop owns:
                // report the drift, consume it, and open the new window —
                // otherwise an expiring mute would silently dump every
                // accumulated delta as nags. Decided against CURRENT, so a
                // fresh mute User set after our pre-check is respected.
                if current.muteHasElapsed(now: now) {
                    let drift = DeskNagEvaluator.digestOnUnmute(state: state, plan: plan, config: current, now: now)
                    let consumed = DeskNagEvaluator.consumingDrift(state: state, plan: plan, config: current, now: now).unmuted()
                    return (consumed, .unmuteDigest(drift))
                }
                let outcome = DeskNagEvaluator.evaluate(state: state, plan: plan, config: current, now: now)
                return (outcome.updatedConfig, .fire(outcome))
            }
            action = act
        } catch {
            NSLog("desk_notify: nag config transaction failed: \(error) — skipping delivery to avoid a re-fire")
            failures.append("nag config transaction: \(error)")
            return 0
        }

        let outcome: DeskNagEvaluator.Outcome
        switch action {
        case .none:
            return 0
        case .unmuteDigest(let drift):
            if !drift.isEmpty {
                await deliverNag(
                    title: "Desk · back on",
                    body: (["Your mute elapsed. What moved while you were quiet:"] + drift).joined(separator: "\n"),
                    label: "unmute digest",
                    failures: &failures
                )
            }
            // The window just opened; the next tick evaluates against the
            // freshly consumed baselines.
            return 0
        case .fire(let o):
            outcome = o
        }
        guard !outcome.nags.isEmpty else { return 0 }

        for (idx, nag) in outcome.nags.enumerated() {
            var body = nag.body
            // Digest lines ride along with the FIRST nag only.
            if idx == 0, !outcome.digestLines.isEmpty {
                body += "\n\nAlso sitting still:\n" + outcome.digestLines.joined(separator: "\n")
            }
            await deliverNag(title: nag.title, body: body, label: nag.handle, failures: &failures)
        }
        return outcome.nags.count
    }

    /// Same dual delivery as the notify pass (Mac banner + paired-device push),
    /// with both channel outcomes logged so no failure is silent.
    private func deliverNag(title: String, body: String, label: String, failures: inout [String]) async {
        let macResult = await NativeAgentNotifications.postAndReport(title: title, body: body)
        let mobileOK = (try? await MacSyncEngine.shared.sendNotificationToPairedDevices(
            title: title,
            body: body,
            userInfo: ["screen": "inbox", "source": "desk"]
        )) != nil
        if !macResult.posted {
            NSLog("desk_notify: nag Mac banner failed for \(label)")
            failures.append("\(label) nag Mac banner")
        }
        if !mobileOK {
            NSLog("desk_notify: nag paired-device push failed for \(label)")
            failures.append("\(label) nag paired-device push")
        }
    }
}
