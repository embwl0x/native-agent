import Foundation
// Blueprint: | `Settle.swift` | `settle`: the Stop law's one primitive; settlement runs outside the caller's cancellation, exactly once (docs/STOP.md) |

/// The Stop law (docs/STOP.md): Stop cancels the work, never its settlement.
///
/// Work in flight has two parts. Its effect (send, write, run a process, wait
/// for a reply) is what Stop cancels. Its settlement (save what was produced,
/// write the one terminal record, release what the work held, say what
/// landed) always runs to completion, exactly once, after the effect ends
/// however it ended. `settle` runs that settlement outside the caller's
/// cancellation: a cancelled caller still waits for it to finish.
///
/// Task-local values (turn trace, chat session) do not carry into the
/// settlement; capture what it needs before calling.
public func settle<T: Sendable>(_ settlement: @escaping @Sendable () async -> T) async -> T {
    await Task.detached(priority: .userInitiated) { await settlement() }.value
}
