import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+Wait.swift` | `MacFourVerbs.wait`: Required AX/app signals, bounded text rechecks and settling within one deadline |

extension MacFourVerbs {
    // MARK: 4 — PATIENCE

    /// Observer quiet misses in-window changes: settling needs two equal reads, while a text condition needs an observed match.
    public func wait(until: String? = nil, seconds: Double? = nil, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        let budget = min(max(seconds ?? Self.defaultWaitSeconds, 0), Self.maxWaitSeconds)
        let needle = until?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let waitingForText = needle?.isEmpty == false
        let startedAt = clock.monotonicSeconds()

        func elapsedNow() -> Double { clock.monotonicSeconds() - startedAt }
        func cancelled() -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: "Waiting was cancelled.", detail: ["outcome": .string("cancelled"), "status": .string("cancelled"),
                "error": .string("cancelled"), "effects": .string("unknown"),
                "remedy": Repair.terminal(instruction: "The wait was cancelled; no further observation runs for this request.")])
        }
        func observationUnavailable(_ detail: String) -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: detail + " Read this app again after repairing its Accessibility observation; no watch was started.",
                detail: ["outcome": .string("unavailable"), "error": .string("observation_unavailable"),
                    "message": .string(detail), "effects": .string("none"),
                    "remedy": Repair.reconcile(instruction: "Inspect the app's Accessibility access and read the app again before waiting.",
                        nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("mac")])]))])
        }
        func refusal(_ reply: MacFourVerbsReply) async -> MacFourVerbsReply {
            guard reply.detail["status"] == .string("in_process_route") else { return reply }
            // Unconditional waits need no screen permission.
            if !waitingForText, seconds != nil {
                let left = budget - elapsedNow()
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
                guard !Task.isCancelled else { return cancelled() }
                return MacFourVerbsReply(ok: true,
                    text: "Waited \(Self.seconds(elapsedNow())) (NativeAgent is in front, so there was no other screen to watch).",
                    detail: ["outcome": .string("waited"), "seconds": .double(elapsedNow())])
            }
            return MacFourVerbsReply(
                ok: false,
                text: """
                    NativeAgent is in front, so wait cannot watch an external app. For a delay only, set seconds and omit until. Inspect NativeAgent with app \
                    {page:\"current\"}, or pass agent: name to wait for a contact's in-flight reply.
                    """,
                detail: reply.detail.merging([
                    "status": .string("refused"), "reason": .string("self_screen_wait_unavailable"),
                    "error": .string("self_screen_wait_unavailable"), "effects": .string("none"),
                    "remedy": Repair.reconcile(instruction: "Read NativeAgent's current page; screen waiting observes external apps.",
                        nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("current")])])),
                ]) { _, new in new }
            )
        }
        guard !Task.isCancelled else { return cancelled() }

        func matched(_ hit: Sighting, _ elapsed: Double) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: true,
                text: "\"\(until ?? "")\" appeared after \(Self.seconds(elapsed)).\n" + hit.render,
                detail: ["outcome": .string("matched"), "seconds": .double(elapsed)]
            )
        }
        func settled(_ hit: Sighting, _ elapsed: Double) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: true,
                text: "Settled after \(Self.seconds(elapsed)).\n" + hit.render,
                detail: ["outcome": .string("settled"), "seconds": .double(elapsed)]
            )
        }

        let first: Sighting
        switch await sight(part: nil, turn: turn, context: context) {
        case .blind(let reply): return await refusal(reply)
        case .seen(let seen): first = seen
        }
        var last = first
        var previous = first.effectRender
        var lastRenderAt = clock.monotonicSeconds()
        if let needle, !needle.isEmpty, first.effectRender.lowercased().contains(needle) {
            return matched(first, elapsedNow())
        }

        // Subscribe only after a gated look succeeds; release subscriptions on every exit, including cancellation.
        var observedPID = first.pid
        var signals = MacWaitSignals(
            effects: effectObserverSource,
            activation: appActivationSource,
            pid: first.pid
        )
        defer { signals.stop() }
        if let failure = signals.installationFailure { return observationUnavailable(failure) }

        while true {
            guard !Task.isCancelled else { return cancelled() }
            let remaining = budget - elapsedNow()
            if remaining <= 0 { break }
            let window = min(
                remaining,
                !waitingForText ? Self.settleQuietSeconds : Self.textRecheckSeconds
            )
            // Rate-limit signal-driven renders to `settleQuietSeconds`, within the deadline.
            let fired = await awaitSignal(
                signals,
                window: window,
                notBefore: lastRenderAt + Self.settleQuietSeconds
            )
            guard !Task.isCancelled else { return cancelled() }
            if !fired, signals.isObserving, !waitingForText, window < Self.settleQuietSeconds { break }
            switch await sight(part: nil, turn: turn, context: context) {
            case .blind(let reply): return await refusal(reply)
            case .seen(let seen): last = seen
            }
            guard !Task.isCancelled else { return cancelled() }
            lastRenderAt = clock.monotonicSeconds()
            let elapsed = elapsedNow()
            if let needle, !needle.isEmpty, last.effectRender.lowercased().contains(needle) {
                return matched(last, elapsed)
            }
            // App switches invalidate both observation and the settling baseline.
            let needsReconciliation = last.pid != observedPID
            if needsReconciliation {
                signals.stop()
                observedPID = last.pid
                signals = MacWaitSignals(effects: effectObserverSource, activation: appActivationSource, pid: last.pid)
                if let failure = signals.installationFailure { return observationUnavailable(failure) }
            }
            if !waitingForText, !needsReconciliation, previous == last.effectRender {
                return settled(last, elapsed)
            }
            previous = last.effectRender
        }

        let elapsed = elapsedNow()
        let ending = waitingForText
            ? "Timed out after \(Self.seconds(elapsed)) — \"\(until ?? "")\" never appeared."
            : "Timed out after \(Self.seconds(elapsed)) — I couldn't confirm that the screen settled."
        return MacFourVerbsReply(
            ok: false,
            text: ending + "\n" + last.render,
            detail: ["outcome": .string("timeout"), "seconds": .double(elapsed)]
        )
    }

    /// Signals wake directly; the capture-rate floor coalesces bursts without extending the deadline.
    private func awaitSignal(
        _ signals: MacWaitSignals,
        window: Double,
        notBefore: Double
    ) async -> Bool {
        let deadline = clock.monotonicSeconds() + window
        let fired = await signals.waitForSignal(seconds: window)
        if fired, !Task.isCancelled {
            await clock.sleep(seconds: max(0, min(notBefore, deadline) - clock.monotonicSeconds()))
        }
        return signals.consume() || fired
    }

    static let defaultWaitSeconds: Double = 10
    static let maxWaitSeconds: Double = 60
    /// Bound capture bursts and allow quiet before checking for settlement.
    static let settleQuietSeconds: Double = 0.5
    /// Text conditions need bounded rechecks even while observation is installed.
    static let textRecheckSeconds: Double = 5.0

}
