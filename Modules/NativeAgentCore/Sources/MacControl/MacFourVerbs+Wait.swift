import Foundation
import NativeAgentCore
import PersistenceCore

extension MacFourVerbs {
    // MARK: 4 — PATIENCE

    /// Signals prompt fresh observations. Without a text condition, two equal
    /// reads end the wait — the app-level observer misses changes inside many
    /// windows, so its quiet alone never settles. With a condition, only a
    /// match in the screen's content can.
    public func wait(until: String? = nil, seconds: Double? = nil) async -> MacFourVerbsReply {
        let budget = min(max(seconds ?? Self.defaultWaitSeconds, 0), Self.maxWaitSeconds)
        let needle = until?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let waitingForText = needle?.isEmpty == false
        let startedAt = clock.monotonicSeconds()

        func elapsedNow() -> Double { clock.monotonicSeconds() - startedAt }
        func cancelled() -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: "I stopped waiting.", detail: ["outcome": .string("cancelled")])
        }
        func refusal(_ reply: MacFourVerbsReply) async -> MacFourVerbsReply {
            guard reply.detail["status"] == .string("in_process_route") else { return reply }
            // A plain "wait N seconds" needs no screen to watch: just wait.
            if !waitingForText, seconds != nil {
                let left = budget - elapsedNow()
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
                guard !Task.isCancelled else { return cancelled() }
                return MacFourVerbsReply(ok: true, text: "Waited \(Self.seconds(elapsedNow())) (NativeAgent is in front, so there was no other screen to watch).",
                                         detail: ["outcome": .string("waited"), "seconds": .double(elapsedNow())])
            }
            return MacFourVerbsReply(
                ok: false,
                text: "wait watches the frontmost external Mac app until its screen settles or the requested text appears; it is not a general sleep. NativeAgent is in front, and screen waiting cannot observe its own app. Use app {page:\"current\"} to inspect NativeAgent, or pass agent: name to wait for a contact's in-flight reply.",
                detail: reply.detail
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

        // 1 — the baseline. One render, before anything is subscribed to.
        let first: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return await refusal(reply)
        case .seen(let seen): first = seen
        }
        var last = first
        var previous = first.effectRender
        var lastRenderAt = clock.monotonicSeconds()
        if let needle, !needle.isEmpty, first.effectRender.lowercased().contains(needle) {
            return matched(first, elapsedNow())
        }

        // 2 — subscribe. Installed only AFTER a look succeeded, so the gate has
        // already run; removed on every exit, including a thrown cancellation.
        var observedPID = first.pid
        var signals = MacWaitSignals(
            effects: effectObserverSource,
            activation: appActivationSource,
            pid: first.pid
        )
        defer { signals.stop() }

        while true {
            guard !Task.isCancelled else { return cancelled() }
            let remaining = budget - elapsedNow()
            if remaining <= 0 { break }
            let window = min(
                remaining,
                signals.isObserving && !waitingForText ? Self.settleQuietSeconds : Self.fallbackPollSeconds
            )
            // THE CAPTURE-RATE FLOOR. A screen that fires notifications
            // continuously (a progress bar, a live log) would otherwise wake
            // this loop on every one and render as fast as the machine can walk
            // and capture — a hot loop, strictly worse than the poll it
            // replaced. So a signal never causes a render sooner than
            // `settleQuietSeconds` after the last one: the old poll's cadence
            // becomes the WORST case instead of the only case.
            let fired = await awaitSignal(
                signals,
                window: window,
                notBefore: lastRenderAt + Self.settleQuietSeconds
            )
            guard !Task.isCancelled else { return cancelled() }
            // The budget ran out inside a short final window.
            if !fired, signals.isObserving, !waitingForText, window < Self.settleQuietSeconds { break }
            // 3 — render ONCE: a signal fired, a quiet window passed (quiet is
            // only settled by a read that matches), or the fallback said look.
            switch await sight(part: nil) {
            case .blind(let reply): return await refusal(reply)
            case .seen(let seen): last = seen
            }
            guard !Task.isCancelled else { return cancelled() }
            lastRenderAt = clock.monotonicSeconds()
            let elapsed = elapsedNow()
            if let needle, !needle.isEmpty, last.effectRender.lowercased().contains(needle) {
                return matched(last, elapsed)
            }
            // A new app needs its own subscription and a fresh baseline
            // before two reads can settle.
            let needsReconciliation = last.pid != observedPID
            if needsReconciliation {
                signals.stop()
                observedPID = last.pid
                signals = MacWaitSignals(effects: effectObserverSource, activation: appActivationSource, pid: last.pid)
            }
            if !waitingForText, !needsReconciliation, previous == last.effectRender {
                // Two identical reads of the screen's content: it has settled.
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

    /// Wait until a signal arrives or `window` elapses. The granularity is a
    /// lock-guarded read of an in-process collector — no AX walk, no capture —
    /// which is what makes it affordable at 50 ms while the old loop was
    /// unaffordable at 500 ms. It is paced through `clock` so a 60-second
    /// budget stays a 60-second budget in production and costs nothing in a
    /// test.
    private func awaitSignal(
        _ signals: MacWaitSignals,
        window: Double,
        notBefore: Double
    ) async -> Bool {
        let deadline = clock.monotonicSeconds() + window
        var fired = false
        while !Task.isCancelled, clock.monotonicSeconds() < deadline {
            if signals.consume() { fired = true }
            // Latched, but held until the capture-rate floor passes. Holding
            // rather than dropping is what keeps a fast signal from being lost:
            // the wake still happens, it just happens on the floor.
            if fired, clock.monotonicSeconds() >= notBefore { return true }
            await clock.sleep(seconds: min(Self.signalPollSeconds, max(0, deadline - clock.monotonicSeconds())))
        }
        if signals.consume() { fired = true }
        return fired
    }

    static let defaultWaitSeconds: Double = 10
    static let maxWaitSeconds: Double = 60
    /// Silence this long, with a live subscription, earns the settling read:
    /// "two identical renders 500 ms apart", read only when nothing fired.
    static let settleQuietSeconds: Double = 0.5
    /// The SAFETY NET cadence, used only when no observer could be installed.
    static let fallbackPollSeconds: Double = 5.0
    /// How often the wait drains the collector. A lock read, not a look.
    static let signalPollSeconds: Double = 0.05

}
