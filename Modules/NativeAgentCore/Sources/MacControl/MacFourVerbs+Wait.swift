import Foundation
import NativeAgentCore
import PersistenceCore

extension MacFourVerbs {
    // MARK: 4 — PATIENCE

    /// Bounded waiting, ended by a SIGNAL rather than by a stopwatch
    /// (fable51 item 31; NORTHSTAR clause 4).
    ///
    /// Same three outcomes and the same words as before — matched, settled,
    /// timeout, and a timeout is never dressed up as a settle. What changed is
    /// what it costs. The old loop re-rendered every 500 ms, and each render is
    /// a full AX walk plus a screen capture plus (conditionally) OCR: a 60 s
    /// wait was up to 120 captures, nearly all of them of a screen that had not
    /// moved. Now:
    ///
    ///   1. ONE render up front — the baseline it compares against.
    ///   2. Then it SUBSCRIBES (`MacWaitSignals`: the same `AXObserver` the act
    ///      loop already ends on, plus NSWorkspace activation for the app-switch
    ///      signal an AX observer installed on one pid structurally cannot
    ///      carry) and renders again only when a signal actually arrives. A
    ///      burst of notifications is ONE episode and ONE render.
    ///   3. SILENCE IS THE SETTLE. When the subscription is live and nothing
    ///      fires for `settleQuietSeconds`, the screen has stopped changing —
    ///      so the render already in hand is the answer, and a settled wait
    ///      costs one capture instead of two.
    ///
    /// THE SAFETY NET, and exactly what it is for: when NO observer could be
    /// installed (the app publishes nothing subscribable, the look could not
    /// name a pid, or the platform has no observer at all), silence proves
    /// nothing — so this must not report a settle it cannot see. In that case
    /// and only that case, `wait` degrades to a coarse re-render every
    /// `fallbackPollSeconds` and decides settle the old way, by comparing two
    /// renders. That is ten times cheaper than the old poll and still honest.
    public func wait(until: String? = nil, seconds: Double? = nil) async -> MacFourVerbsReply {
        let budget = min(max(seconds ?? Self.defaultWaitSeconds, 0), Self.maxWaitSeconds)
        let needle = until?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let startedAt = clock.now()

        func elapsedNow() -> Double { clock.now().timeIntervalSince(startedAt) }

        func matched(_ hit: Sighting, _ elapsed: Double) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: true,
                text: "\"\(until ?? "")\" appeared after \(Self.seconds(elapsed)).\n" + hit.render,
                detail: ["outcome": .string("matched"), "seconds": .double(elapsed)]
            )
        }
        func settled(_ hit: Sighting, _ elapsed: Double, quiet: Bool) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: true,
                text: (needle?.isEmpty == false
                       ? "Settled after \(Self.seconds(elapsed)) and \"\(until ?? "")\" never appeared."
                       : "Settled after \(Self.seconds(elapsed)).") + "\n" + hit.render,
                detail: [
                    "outcome": .string("settled"),
                    "seconds": .double(elapsed),
                    // How the settle was DECIDED. `quiet` means the
                    // subscription went silent; `compared` means there was no
                    // subscription and two renders matched.
                    "settled_by": .string(quiet ? "quiet" : "compared"),
                ]
            )
        }

        // 1 — the baseline. One render, before anything is subscribed to.
        let first: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let seen): first = seen
        }
        var last = first
        var previous = first.render
        var lastRenderAt = clock.now()
        if let needle, !needle.isEmpty, first.render.lowercased().contains(needle) {
            return matched(first, elapsedNow())
        }

        // 2 — subscribe. Installed only AFTER a look succeeded, so the gate has
        // already run; removed on every exit, including a thrown cancellation.
        let signals = MacWaitSignals(
            effects: effectObserverSource,
            activation: appActivationSource,
            pid: first.pid
        )
        defer { signals.stop() }

        while true {
            let remaining = budget - elapsedNow()
            if remaining <= 0 { break }
            let window = min(
                remaining,
                signals.isObserving ? Self.settleQuietSeconds : Self.fallbackPollSeconds
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
                notBefore: lastRenderAt.addingTimeInterval(Self.settleQuietSeconds)
            )
            if !fired, signals.isObserving {
                // Nothing fired for a full quiet window: the screen has stopped
                // changing, and the render in hand already describes it.
                if window >= Self.settleQuietSeconds {
                    return settled(last, elapsedNow(), quiet: true)
                }
                // The budget ran out inside a short final window.
                break
            }
            // 3 — render ONCE, because something happened (or, with no
            // subscription, because the coarse fallback said to look again).
            switch await sight(part: nil) {
            case .blind(let reply): return reply
            case .seen(let seen): last = seen
            }
            lastRenderAt = clock.now()
            let elapsed = elapsedNow()
            if let needle, !needle.isEmpty, last.render.lowercased().contains(needle) {
                return matched(last, elapsed)
            }
            if previous == last.render {
                // A signal that changed nothing visible, or the fallback's two
                // identical renders. Either way the screen has settled.
                return settled(last, elapsed, quiet: false)
            }
            previous = last.render
        }

        let elapsed = elapsedNow()
        let ending = needle?.isEmpty == false
            ? "Timed out after \(Self.seconds(elapsed)) — \"\(until ?? "")\" never appeared and the screen is still changing."
            : "Timed out after \(Self.seconds(elapsed)) — the screen is still changing."
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
        notBefore: Date
    ) async -> Bool {
        let deadline = clock.now().addingTimeInterval(window)
        var fired = false
        while clock.now() < deadline {
            if signals.consume() { fired = true }
            // Latched, but held until the capture-rate floor passes. Holding
            // rather than dropping is what keeps a fast signal from being lost:
            // the wake still happens, it just happens on the floor.
            if fired, clock.now() >= notBefore { return true }
            await clock.sleep(seconds: min(Self.signalPollSeconds, window))
        }
        if signals.consume() { fired = true }
        return fired
    }

    static let defaultWaitSeconds: Double = 10
    static let maxWaitSeconds: Double = 60
    /// Silence this long, with a live subscription, IS a settle. The same
    /// half-second the old loop encoded as "two identical renders 500 ms
    /// apart" — the meaning is unchanged, only the evidence got cheaper.
    static let settleQuietSeconds: Double = 0.5
    /// The SAFETY NET cadence, used only when no observer could be installed.
    static let fallbackPollSeconds: Double = 5.0
    /// How often the wait drains the collector. A lock read, not a look.
    static let signalPollSeconds: Double = 0.05

}
