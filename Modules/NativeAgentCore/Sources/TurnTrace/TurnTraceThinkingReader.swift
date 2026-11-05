import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `TurnTraceThinkingReader.swift` | `TurnTraceThinkingReader`: Recorded model/turn counts in local day buckets |

/// Counts recorded turn-bound model calls, never prompts or standalone receipts.
public actor TurnTraceThinkingReader {
    public static let shared = TurnTraceThinkingReader()

    public struct Counts: Sendable {
        public let calls: Int
        public let turns: Int
    }
    public struct Snapshot: Sendable {
        public let today: Counts
        /// Today and the preceding six days, using the trace writer's calendar.
        public let week: Counts
    }
    private struct Day {
        var calls = 0
        var turns: Set<String> = []
    }

    public func read(dataRoot: URL, now: Date = Date()) async throws -> Snapshot {
        let calendar = TurnTracePersistLane.dayCalendar
        let todayStart = calendar.startOfDay(for: now)
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) else {
            throw PersistenceCoreError.ioFailure("Thinking counts could not determine the week's day boundary.")
        }
        let lane = TurnTracePersistLane(dataRootOverride: dataRoot)
        let pageSize = 128
        var after: Int64?
        var today = Day(), week = Day()
        while true {
            try Task.checkCancellation()
            let read = try await lane.events(.init(kinds: ["llm.call"], from: weekStart, through: now, after: after, limit: pageSize))
            guard read.isClean else {
                throw PersistenceCoreError.ioFailure("Thinking counts have \(read.unreadable) unreadable model-call details.")
            }
            for event in read.events where event.turnId != "unknown" {
                try Task.checkCancellation()
                guard case .object(let payload) = event.payload else {
                    throw PersistenceCoreError.ioFailure("Thinking counts have a model call without a readable payload.")
                }
                let purpose: String?
                switch payload["purpose"] {
                case .string(let value)?: purpose = value
                case nil, .null?: purpose = nil
                default: throw PersistenceCoreError.ioFailure("Thinking counts have a model call without a readable purpose.")
                }
                week.calls += 1
                if purpose == "turn" { week.turns.insert(event.turnId) }
                if calendar.startOfDay(for: event.ts) == todayStart {
                    today.calls += 1
                    if purpose == "turn" { today.turns.insert(event.turnId) }
                }
            }
            guard read.events.count == pageSize else { break }
            guard let seq = read.lastSeq, after.map({ seq > $0 }) ?? true else {
                throw PersistenceCoreError.ioFailure("Thinking counts could not advance through the record.")
            }
            after = seq
        }
        return Snapshot(today: Counts(calls: today.calls, turns: today.turns.count),
                        week: Counts(calls: week.calls, turns: week.turns.count))
    }
}
