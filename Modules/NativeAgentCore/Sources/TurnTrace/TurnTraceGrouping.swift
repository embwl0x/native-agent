import Foundation
import PersistenceCore
import CryptoKit
import NativeAgentCore
import Darwin
import AuthoredCapabilities
import os
import NativeAgentShared
import Experiences
import Observation
// Blueprint: | `TurnTraceGrouping.swift` | Stable arrival-index grouping and exact nonnegative measurements with damage evidence shared by Inspector and phone summaries |

/// Stable chronological evidence and metrics shared by the Inspector and phone summaries.
public struct TurnTraceGroup: Identifiable, Sendable {
    public let id: String
    public let surface: String?
    public let sessionId: String?
    public let events: [TurnTraceEvent]
    public let startedAt: Date
    public let lastAt: Date
    public var eventCount: Int { events.count }
    public var wallMs: Int { max(0, Int(lastAt.timeIntervalSince(startedAt) * 1000)) }
    public let llmTokens: Int?
    public let ttftMs: Int?
    public let measurementError: String?
}

public enum TurnTraceGrouping {
    public static func group(_ events: [TurnTraceEvent]) -> [TurnTraceGroup] {
        guard !events.isEmpty else { return [] }
        // Equal timestamps preserve arrival order: live emission order or persisted append order.
        var byTurn: [String: [(index: Int, event: TurnTraceEvent)]] = [:]
        for (i, ev) in events.enumerated() { byTurn[ev.turnId, default: []].append((i, ev)) }

        var cards: [TurnTraceGroup] = []
        cards.reserveCapacity(byTurn.count)
        for (turnId, group) in byTurn {
            // Original arrival index breaks timestamp ties deterministically.
            let sortedPairs = group.sorted {
                if $0.event.ts != $1.event.ts { return $0.event.ts < $1.event.ts }
                return $0.index < $1.index
            }
            let sorted = sortedPairs.map(\.event)
            // Skip empty groups rather than trapping the Inspector.
            guard let started = sorted.first?.ts, let last = sorted.last?.ts else { continue }
            // Surface/session: take the first non-nil we see (they're turn-wide).
            let surface = sorted.lazy.compactMap { $0.surface }.first
            let session = sorted.lazy.compactMap { $0.sessionId }.first
            let (tokens, ttft, measurementError) = llmSummary(sorted)
            cards.append(TurnTraceGroup(
                id: turnId,
                surface: surface,
                sessionId: session,
                events: sorted,
                startedAt: started,
                lastAt: last,
                llmTokens: tokens,
                ttftMs: ttft,
                measurementError: measurementError
            ))
        }
        // Newest STARTED turn on top. Tie-break by turnId for determinism.
        return cards.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id > $1.id
        }
    }

    /// Sum input+output tokens across llm.call events and pick the first TTFT.
    private static func llmSummary(_ events: [TurnTraceEvent]) -> (tokens: Int?, ttftMs: Int?, error: String?) {
        var tokenTotal: Int64 = 0
        var sawTokens = false
        var ttft: Int? = nil
        for ev in events where ev.kind == "llm.call" {
            guard case .object(let p) = ev.payload else { continue }
            // Only the recorder's camelCase keys count; aliases could double-count evidence.
            do {
                for key in ["inputTokens", "outputTokens"] {
                    if let n = try TraceMeasurement.value(p[key], field: key) {
                        tokenTotal = try TraceMeasurement.add(tokenTotal, n, field: key)
                        sawTokens = true
                    }
                }
                if ttft == nil, let n = try TraceMeasurement.value(p["ttftMs"], field: "ttftMs") {
                    ttft = Int(exactly: n)
                }
            } catch {
                return (nil, nil, error.localizedDescription)
            }
        }
        return (sawTokens ? Int(exactly: tokenTotal) : nil, ttft, nil)
    }

}

/// Recorded measurements are nonnegative integers; totals must remain exact.
enum TraceMeasurement {
    static func value(_ value: JSONValue?, field: String) throws -> Int64? {
        guard let value, value != .null else { return nil }
        guard case .int(let n) = value, n >= 0 else {
            throw PersistenceCoreError.ioFailure("Damaged trace measurement: \(field) must be a nonnegative integer.")
        }
        return n
    }

    static func add(_ lhs: Int64, _ rhs: Int64, field: String) throws -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow else {
            throw PersistenceCoreError.ioFailure("Damaged trace evidence: \(field) total exceeds the representable integer range.")
        }
        return sum.partialValue
    }
}
