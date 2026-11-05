import Foundation
import Experiences
// Blueprint: | `TurnTraceReplayReader.swift` | Record queries and positive terminal evidence |

public struct TurnTraceReplayReader {
    /// Replay reads the same record and root as live persistence. Unreadable details remain explicit in the result.
    public static func read(_ query: ExperienceStore.DetailQuery, root: URL) async throws -> TraceRead {
        try await TurnTracePersistLane(dataRootOverride: root).events(query)
    }

    /// Positive terminal evidence among decoded rows. Recovery separately checks coverage before concluding that work is settled.
    static func containsTerminal(forTurn turnId: String, in events: [TurnTraceEvent], status: String? = nil) -> Bool {
        events.contains { event in
            guard event.turnId == turnId, TurnTraceEvent.isTerminalKind(event.kind) else { return false }
            guard let status else { return true }
            guard case .object(let payload) = event.payload else { return false }
            return payload["status"] == .string(status)
        }
    }

    /// Scan the requested record window; a failed read throws instead of standing in for an empty scan.
    public static func scan(
        _ query: ExperienceStore.DetailQuery, root: URL, handle: (TurnTraceEvent) -> Void
    ) async throws -> (unreadable: Int, matchedRows: Int, lastSeq: Int64?) {
        let read = try await self.read(query, root: root)
        for event in read.events { handle(event) }
        return (read.unreadable, read.events.count, read.lastSeq)
    }
}
