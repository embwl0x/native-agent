import Foundation
import Experiences
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `EngineCarriedHabits.swift` | Join terminal and dispatch evidence off-turn to record carried-work trials |

enum EngineCarriedHabits {
    static func record(turn: String, dataRoot: URL) async {
        // Terminal persistence can overtake trace ingress; this background observer waits for accepted rows without holding the turn.
        await TurnTraceBus.shared.drainForProcessExit()
        do {
            let read = try await TurnTracePersistLane(dataRootOverride: dataRoot).events(.init(subjects: [turn], kinds: [
                "turn.accepted", "turn.terminal", "turn.cancelled", "turn.failed", "work.identified", "tool.dispatch", "tool.dispatch.closed", "llm.call",
            ]))
            let events = read.events
            guard read.isClean,
                  events.contains(where: { $0.kind == "turn.accepted" && $0.sessionId == ResidentWake.session }),
                  let terminal = events.last(where: { TurnTraceEvent.isTerminalKind($0.kind) }),
                  let work = events.first(where: { $0.kind == "work.identified" })?.payload.objectValue?["workIdentity"]?.stringValue,
                  work.hasPrefix("carry.") else { return }
            guard let actions = handling(events) else { return }
            let handling = actions.first(where: { $0.hasPrefix("authored.") }).map { [$0] } ?? actions
            await CarriedHabits.shared.record(handle: String(work.dropFirst(6)), turn: turn, handling: handling,
                modelCalls: events.filter { $0.kind == "llm.call" }.count, at: terminal.ts, dataRoot: dataRoot)
        } catch { nativeLog("carried turn %@ could not be read: %@", turn, error.localizedDescription) }
    }

    /// Read coverage and receipts directly from their dispatch owner.
    private static func handling(_ events: [TurnTraceEvent]) -> [String]? {
        let dispatches = events.filter { $0.kind == "tool.dispatch" }
        let closed = events.filter { $0.kind == "tool.dispatch.closed" }
        let marks = (dispatches + closed).compactMap { $0.payload.objectValue?["dispatchCoverage"]?.objectValue }
        let lives = Set(marks.compactMap { $0["life"]?.stringValue })
        let ordinals = dispatches.compactMap { $0.payload.objectValue?["dispatchCoverage"]?.objectValue?["ordinal"]?.integerValue }.sorted()
        guard closed.count == 1, lives.count == 1, marks.count == dispatches.count + 1,
              let total = closed.first?.payload.objectValue?["dispatchCoverage"]?.objectValue?["ordinal"]?.integerValue,
              total == Int64(exactly: dispatches.count), ordinals.count == dispatches.count,
              ordinals.enumerated().allSatisfy({ $0.element == Int64(exactly: $0.offset) }) else { return nil }
        var began: [String: Date] = [:], ended: Set<String> = [], actions: [(Date, String, String)] = []
        for event in dispatches {
            guard let fields = event.payload.objectValue else { return nil }
            guard fields["parentId"] == nil, fields["automaticOrigin"] == nil else { continue }
            guard let receipt = fields["receipt"]?.objectValue, let id = receipt["id"]?.stringValue else { return nil }
            if fields["phase"] == .string("begin") {
                guard began[id] == nil else { return nil }
                began[id] = event.ts
            } else if fields["phase"] == .string("end") {
                guard ended.insert(id).inserted else { return nil }
                if let action = receipt["action"]?.stringValue {
                    guard let ms = fields["durationMs"]?.integerValue, ms >= 0 else { return nil }
                    actions.append((event.ts.addingTimeInterval(-Double(ms) / 1000), id, action))
                }
            } else { return nil }
        }
        guard Set(began.keys) == ended else { return nil }
        return actions.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 }
    }
}
