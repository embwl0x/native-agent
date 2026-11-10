import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskState.swift` | Append-only archive records and materialized Desk state formats |

// MARK: - ArchiveRecord (append-only archived item record)

public struct ArchiveRecord: Sendable, Equatable {
    public var handle: String
    public var title: String
    public var project: String
    public var finalStatus: ArchiveFinalStatus
    public var openedAt: String
    public var closedAt: String
    public var summary: String
    public var refs: [DeskRef]
    public var decisions: [String]
    public var artifacts: [String]
    public var supersededBy: String?
    public var findingKey: String?

    public init(
        handle: String, title: String, project: String,
        finalStatus: ArchiveFinalStatus, openedAt: String, closedAt: String,
        summary: String, refs: [DeskRef] = [], decisions: [String] = [],
        artifacts: [String] = [], supersededBy: String? = nil, findingKey: String? = nil
    ) {
        self.handle = handle
        self.title = title
        self.project = project
        self.finalStatus = finalStatus
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.summary = summary
        self.refs = refs
        self.decisions = decisions
        self.artifacts = artifacts
        self.supersededBy = supersededBy
        self.findingKey = findingKey
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "handle": .string(handle),
            "title": .string(title),
            "project": .string(project),
            "finalStatus": .string(finalStatus.rawValue),
            "openedAt": .string(openedAt),
            "closedAt": .string(closedAt),
            "summary": .string(summary),
        ]
        if !refs.isEmpty { obj["refs"] = .array(refs.map { $0.toJSON() }) }
        if !decisions.isEmpty { obj["decisions"] = .array(decisions.map { .string($0) }) }
        if !artifacts.isEmpty { obj["artifacts"] = .array(artifacts.map { .string($0) }) }
        if let supersededBy, !supersededBy.isEmpty { obj["supersededBy"] = .string(supersededBy) }
        if let findingKey { obj["findingKey"] = .string(findingKey) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> ArchiveRecord? {
        guard case .object(let obj) = value,
              let handle = obj["handle"]?.stringValue,
              let title = obj["title"]?.stringValue,
              let project = obj["project"]?.stringValue,
              let finalRaw = obj["finalStatus"]?.stringValue,
              let finalStatus = ArchiveFinalStatus(rawValue: finalRaw),
              let openedAt = obj["openedAt"]?.stringValue,
              let closedAt = obj["closedAt"]?.stringValue,
              let summary = obj["summary"]?.stringValue else { return nil }
        guard let refs = deskStoredCollection(obj["refs"], decode: DeskRef.fromJSON),
              let decisions = DeskJSON.strings(obj["decisions"]),
              let artifacts = DeskJSON.strings(obj["artifacts"]),
              DeskJSON.optionalStringsAreValid(obj, keys: ["supersededBy", "findingKey"]) else { return nil }
        return ArchiveRecord(
            handle: handle, title: title, project: project, finalStatus: finalStatus,
            openedAt: openedAt, closedAt: closedAt, summary: summary, refs: refs,
            decisions: decisions,
            artifacts: artifacts,
            supersededBy: obj["supersededBy"]?.stringValue, findingKey: obj["findingKey"]?.stringValue
        )
    }
}

// MARK: - DeskState (derived — the materialized live view)

public struct DeskState: Sendable, Equatable {
    public var items: [DeskItem]
    public var generatedTs: String
    public var workSlotsByDay: [String: [String: [String]]]

    public init(items: [DeskItem], generatedTs: String, workSlotsByDay: [String: [String: [String]]]? = nil) {
        self.items = items
        self.generatedTs = generatedTs
        if let workSlotsByDay {
            self.workSlotsByDay = workSlotsByDay
        } else {
            self.workSlotsByDay = [:]
            for item in items {
                for attempt in item.workAttempts where attempt.disposition != .unstarted {
                    chargeWorkSlot(handle: item.handle, day: attempt.day, id: attempt.attemptId)
                }
            }
        }
    }

    public func workSessions(on day: String, handle: String? = nil) -> Int {
        guard let slots = workSlotsByDay[day] else { return 0 }
        if let handle { return slots[handle]?.count ?? 0 }
        return slots.values.reduce(0) { $0 + $1.count }
    }

    /// Count pursuit charges for the requested day; unstarted attempts consume no budget.
    public func pursuitWorkSessions(on day: String, handle: String) -> Int? {
        guard let item = items.first(where: { $0.handle == handle }) else { return nil }
        return (item.pursuit?.retiredSessionsByDay[day] ?? 0)
            + item.workAttempts.filter { $0.lane == .pursuit && $0.day == day && $0.disposition != .unstarted
                && hasWorkSlot(handle: handle, day: day, id: $0.attemptId) }.count
    }

    public func hasWorkSlot(handle: String, day: String, id: String) -> Bool {
        workSlotsByDay[day]?[handle]?.contains(id) == true
    }

    public func hasWorkSlot(handle: String, id: String) -> Bool {
        workSlotsByDay.values.contains { $0[handle]?.contains(id) == true }
            || items.contains { item in
                item.handle == handle && item.workAttempts.contains { $0.attemptId == id }
            }
    }

    mutating func chargeWorkSlot(handle: String, day: String, id: String) {
        guard !workSlotsByDay.values.contains(where: { $0[handle]?.contains(id) == true }) else { return }
        workSlotsByDay[day, default: [:]][handle, default: []].append(id)
    }

    mutating func releaseWorkSlot(handle: String, day: String, id: String) {
        workSlotsByDay[day]?[handle]?.removeAll { $0 == id }
    }

    public var topLevel: [DeskItem] { items.filter { $0.parent == nil } }
    /// Keep the person's board distinct from the agent's intentions.
    public var board: DeskState {
        var board = self
        board.items.removeAll { $0.project == MyQueue.project }
        return board
    }
    public var boardCountSummary: String {
        let board = self.board
        let top = board.topLevel
        return """
            \(top.filter { !$0.status.isTerminal }.count) of \(top.count) top-level items open; \
            \(board.items.filter { !$0.status.isTerminal }.count) board items open including parts; \
            \(MyQueue.entries(self).filter { $0.item.project == MyQueue.project }.count) open MY QUEUE intentions; archives excluded
            """
    }
    public func children(of handle: String) -> [DeskItem] { items.filter { $0.parent == handle } }

    public func toJSON() -> JSONValue {
        .object([
            "version": .int(2),
            "generatedTs": .string(generatedTs),
            "items": .array(items.map { $0.toJSON() }),
            "workSlotsByDay": .object(workSlotsByDay.mapValues { handles in
                .object(handles.mapValues { .array($0.map(JSONValue.string)) })
            }),
        ])
    }

    /// Reject a malformed base whole: a silently dropped item would vanish from every future replay.
    public static func fromJSON(_ value: JSONValue) -> DeskState? {
        guard case .object(let obj) = value,
              case .int(2)? = obj["version"],
              case .string(let generatedTs)? = obj["generatedTs"],
              case .array(let rows)? = obj["items"] else { return nil }
        guard obj["workSlotsByDay"] != nil else { return nil }
        var items: [DeskItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            guard let item = DeskItem.fromJSON(row) else { return nil }
            items.append(item)
        }
        var workSlotsByDay: [String: [String: [String]]]? = nil
        if let value = obj["workSlotsByDay"] {
            guard case .object(let days) = value else { return nil }
            var decoded: [String: [String: [String]]] = [:]
            for (day, value) in days {
                guard case .object(let handles) = value else { return nil }
                var slots: [String: [String]] = [:]
                for (handle, value) in handles {
                    guard case .array(let rows) = value else { return nil }
                    var ids: [String] = []
                    for row in rows {
                        guard case .string(let id) = row, !id.isEmpty, !ids.contains(id) else { return nil }
                        ids.append(id)
                    }
                    slots[handle] = ids
                }
                decoded[day] = slots
            }
            workSlotsByDay = decoded
        }
        let state = DeskState(items: items, generatedTs: generatedTs, workSlotsByDay: workSlotsByDay)
        for item in items {
            for attempt in item.workAttempts where attempt.disposition != .unstarted {
                guard state.hasWorkSlot(handle: item.handle, day: attempt.day, id: attempt.attemptId) else { return nil }
            }
            if let pursuit = item.pursuit {
                for (day, count) in pursuit.retiredSessionsByDay {
                    let liveCount = item.workAttempts.filter { $0.lane == .pursuit && $0.day == day && $0.disposition != .unstarted }.count
                    let slots = state.workSessions(on: day, handle: item.handle)
                    let ledgerDay = DeskClock.parseISO(generatedTs).map(DeskClock.dayStamp)
                    // Pruned historical charges do not waive the slot evidence required for retained receipts.
                    guard slots == count + liveCount
                        || (ledgerDay.map { day < $0 } == true && slots == liveCount) else { return nil }
                }
            }
        }
        return state
    }
}
