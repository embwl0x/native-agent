import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - evals-total-coverage · shared hermetic trace-bus harness (fence core.chat.engine)
//
// Every trace assertion in this fence's eval files runs against a PER-TEST
// TurnTraceBus so nothing reaches the live data root.
//
// TWO TRAPS this helper exists to close:
//   1. `streamTurn`, `chatStream`, and the text-compat producer each REBIND
//      `TurnTraceContext.$bus` to the ENGINE's / CLIENT's own bus inside their
//      producer Task. A caller-side task-local binding alone is therefore NOT
//      enough — the bus has to be handed to the engine/client too. `body`
//      receives it for exactly that reason.
//   2. Emission is fire-and-forget through a process-wide bounded pump. A
//      fixed sleep flakes under full-suite parallel load (observed: a
//      1145-test run where the expected rows had not drained inside 700 ms).
//      So we WAIT for the expected count under a deadline, then settle briefly
//      to catch any EXTRA rows — which keeps "exactly one" a real assertion
//      rather than a race.

/// Accumulates events off the bus subscription so the waiter can poll a count.
actor EvalTraceEventBox {
    private var events: [TurnTraceEvent] = []
    func append(_ event: TurnTraceEvent) { events.append(event) }
    func count() -> Int { events.count }
    func all() -> [TurnTraceEvent] { events }
}

/// Run `body` with a hermetic bus bound (and handed in), returning every event
/// of `kinds` emitted under this turn's id.
///
/// - Parameter expecting: wait until at least this many matching events have
///   arrived (or `waitDeadline` elapses) before the settle window. Pass 0 when
///   the assertion is "none were emitted".
func withHermeticTraceBus(
    kinds: Set<String>,
    expecting: Int = 1,
    waitDeadline: Duration = .seconds(10),
    settle: Duration = .milliseconds(400),
    _ body: @escaping @Sendable (TurnTraceBus) async throws -> Void
) async throws -> [TurnTraceEvent] {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("eval-trace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let subscription = await bus.subscribe(capacity: 4096)
    let turnId = TurnTraceContext.mintTurnId()
    let box = EvalTraceEventBox()
    let drain = Task {
        for await event in subscription.stream
        where kinds.contains(event.kind) && event.turnId == turnId {
            await box.append(event)
        }
    }

    try await TurnTraceContext.$bus.withValue(bus) {
        try await TurnTraceContext.$turnId.withValue(turnId) {
            try await body(bus)
        }
    }

    if expecting > 0 {
        let started = ContinuousClock.now
        while await box.count() < expecting, ContinuousClock.now - started < waitDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    // Settle window: give any EXTRA (unexpected) rows a chance to show up, so
    // an "exactly N" assertion can still fail on N+1.
    try? await Task.sleep(for: settle)
    await bus.unsubscribe(subscription.id)
    _ = await drain.value
    return await box.all()
}
