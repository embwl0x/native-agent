import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskItem.swift` | Derived work and explicit progress; statusDescription shares persisted wait truth |

// MARK: - Item (a derived row — never serialized as a mutation, only state.json)

/// Progress is explicit; the Desk cannot infer completed work.
public struct DeskProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let note: String?

    public init?(done: Int, total: Int, note: String? = nil) {
        guard done >= 0, total > 0, done <= total else { return nil }
        self.done = done
        self.total = total
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = trimmed?.isEmpty == false ? trimmed : nil
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "done": .int(Int64(done)),
            "total": .int(Int64(total)),
        ]
        if let note { object["note"] = .string(note) }
        return .object(object)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskProgress? {
        guard case .object(let object) = value,
              let done = jsonInt(object, "done"),
              let total = jsonInt(object, "total") else { return nil }
        return DeskProgress(done: done, total: total, note: object["note"]?.stringValue)
    }
}

public struct DeskItem: Sendable, Equatable {
    /// Interpret persisted person waits consistently across readers without rewriting stored work.
    public var statusDescription: String {
        if !status.isTerminal, let party = waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines), !party.isEmpty {
            return "waiting on " + party
        }
        return status.rawValue
    }
    public var continuation: DeskContinuation?
    public var findingKey: String?
    public var handle: String
    public var alias: String            // view number "2" / "2.1" — stable, never renumbered
    public var parent: String?
    public var kind: DeskKind
    public var status: DeskStatus
    public var project: String
    public var title: String
    public var summary: String?
    /// Delegation display fields never change ownership, hierarchy or admission.
    public var assignee: String?
    public var laneOf: String?
    public var progress: DeskProgress?
    public var refs: [DeskRef]
    public var step: DeskStep? {
        refs.reversed().lazy.compactMap { ref -> DeskStep? in
            if case .step(let step) = ref.kind { return step }; return nil
        }.first
    }
    public var cadence: Cadence
    public var notify: NotifyPolicy
    public var notes: [DeskNote]
    public var openedAt: String
    public var updatedAt: String
    public var closedAt: String?
    public var pinned: Bool
    public var blockedReason: String?
    public var waitingOn: String?
    /// Derive readiness from stable blocker handles and defer dates so settlement needs no unblocking write.
    public var blockedOn: [String]
    public var deferUntil: String?
    public var origin: DeskOrigin       // immutable after create; default .owner
    public var pursuit: Pursuit?        // present only for origin=agent, kind=project
    public var workAttempts: [DeskWorkAttempt]

    /// The pursuit cap and work-session gates share this exact recognized shape.
    public var isPursuit: Bool { origin == .agent && kind == .project && pursuit != nil }

    public var pursuitExpiresAt: Date? {
        guard isPursuit, let pursuit, let opened = DeskClock.parseISO(openedAt) else { return nil }
        return opened.addingTimeInterval(TimeInterval(pursuit.maxDays) * 86_400)
    }

    /// Only canonical owner waits require user action; generic blockage or failed verification is insufficient.
    public var requiresOwnerInput: Bool { OwnerAttentionPolicy.waitsOnOwner(self) }

    public init(
        handle: String,
        alias: String,
        parent: String? = nil,
        kind: DeskKind,
        status: DeskStatus = .watch,
        project: String,
        title: String,
        summary: String? = nil,
        assignee: String? = nil,
        laneOf: String? = nil,
        progress: DeskProgress? = nil,
        refs: [DeskRef] = [],
        cadence: Cadence = Cadence(),
        notify: NotifyPolicy = NotifyPolicy(),
        notes: [DeskNote] = [],
        openedAt: String,
        updatedAt: String,
        closedAt: String? = nil,
        pinned: Bool = false,
        blockedReason: String? = nil,
        waitingOn: String? = nil,
        origin: DeskOrigin = .owner,
        pursuit: Pursuit? = nil,
        blockedOn: [String] = [],
        deferUntil: String? = nil,
        workAttempts: [DeskWorkAttempt] = [],
        continuation: DeskContinuation? = nil,
        findingKey: String? = nil
    ) {
        self.handle = handle
        self.continuation = continuation
        self.findingKey = findingKey
        self.alias = alias
        self.parent = parent
        self.kind = kind
        self.status = status
        self.project = project
        self.title = title
        self.summary = summary
        self.assignee = assignee
        self.laneOf = laneOf
        self.progress = progress
        self.refs = refs
        self.cadence = cadence
        self.notify = notify
        self.notes = notes
        self.openedAt = openedAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.pinned = pinned
        self.blockedReason = blockedReason
        self.waitingOn = waitingOn
        self.origin = origin
        self.pursuit = pursuit
        self.blockedOn = blockedOn
        self.deferUntil = deferUntil
        self.workAttempts = workAttempts
    }

    public func liveRefs(limit: Int = 3) -> [DeskRef] {
        Array(refs.sorted { $0.priority < $1.priority }.prefix(limit))
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "handle": .string(handle),
            "alias": .string(alias),
            "kind": .string(kind.rawValue),
            "status": .string(status.rawValue),
            "project": .string(project),
            "title": .string(title),
            "cadence": cadence.toJSON(),
            "notify": notify.toJSON(),
            "openedAt": .string(openedAt),
            "updatedAt": .string(updatedAt),
            "pinned": .bool(pinned),
        ]
        if let parent, !parent.isEmpty { obj["parent"] = .string(parent) }
        if let summary, !summary.isEmpty { obj["summary"] = .string(summary) }
        if let assignee, !assignee.isEmpty { obj["assignee"] = .string(assignee) }
        if let laneOf, !laneOf.isEmpty { obj["laneOf"] = .string(laneOf) }
        if let progress { obj["progress"] = progress.toJSON() }
        if !refs.isEmpty { obj["refs"] = .array(refs.map { $0.toJSON() }) }
        if !notes.isEmpty { obj["notes"] = .array(notes.map { $0.toJSON() }) }
        if let closedAt, !closedAt.isEmpty { obj["closedAt"] = .string(closedAt) }
        if let blockedReason, !blockedReason.isEmpty { obj["blockedReason"] = .string(blockedReason) }
        if let waitingOn, !waitingOn.isEmpty { obj["waitingOn"] = .string(waitingOn) }
        if !blockedOn.isEmpty { obj["blockedOn"] = .array(blockedOn.map { .string($0) }) }
        if let deferUntil, !deferUntil.isEmpty { obj["deferUntil"] = .string(deferUntil) }
        if origin != .owner { obj["origin"] = .string(origin.rawValue) }
        if let pursuit { obj["pursuit"] = pursuit.toJSON() }
        if !workAttempts.isEmpty { obj["workAttempts"] = .array(workAttempts.map { $0.toJSON() }) }
        if let continuation { obj["continuation"] = continuation.toJSON() }
        if let findingKey { obj["findingKey"] = .string(findingKey) }
        return .object(obj)
    }

    /// Decode stored collections completely so references, notes, blockers and work identity cannot disappear.
    public static func fromJSON(_ value: JSONValue) -> DeskItem? {
        guard case .object(let obj) = value,
              let handle = obj["handle"]?.stringValue,
              let alias = obj["alias"]?.stringValue,
              let kindRaw = obj["kind"]?.stringValue, let kind = DeskKind(rawValue: kindRaw),
              let statusRaw = obj["status"]?.stringValue, let status = DeskStatus(rawValue: statusRaw),
              let project = obj["project"]?.stringValue,
              let title = obj["title"]?.stringValue,
              let openedAt = obj["openedAt"]?.stringValue,
              let updatedAt = obj["updatedAt"]?.stringValue,
              case .bool(let pinned)? = obj["pinned"],
              let cadenceValue = obj["cadence"], let cadence = Cadence.fromJSON(cadenceValue),
              let notifyValue = obj["notify"], let notify = NotifyPolicy.fromJSON(notifyValue),
              DeskJSON.optionalStringsAreValid(obj, keys: ["parent", "summary", "assignee", "laneOf", "closedAt", "blockedReason", "waitingOn", "origin",
                  "deferUntil", "findingKey"]),
              let refs = deskStoredCollection(obj["refs"], decode: DeskRef.fromJSON),
              let notes = deskStoredCollection(obj["notes"], decode: DeskNote.fromJSON),
              let blockedOn = DeskJSON.strings(obj["blockedOn"]) else { return nil }
        guard let workAttempts = DeskWorkAttempt.readAttempts(obj) else { return nil }
        let pursuit = obj["pursuit"].flatMap(Pursuit.fromJSON)
        if let pursuitValue = obj["pursuit"] {
            // Reject malformed pursuit collections so decoding cannot shrink evidence or reservation budgets.
            guard case .object(let pursuitObj) = pursuitValue else { return nil }
            guard let pursuit else { return nil }
            if let evidenceValue = pursuitObj["evidence"] {
                guard case .object(let evidenceObj) = evidenceValue else { return nil }
                if let citationsValue = evidenceObj["citations"] {
                    guard case .array(let citationRows) = citationsValue,
                          pursuit.evidence.citations.count == citationRows.count else { return nil }
                }
            }
        }
        if let pursuit,
           pursuit.retiredSessions.addingReportingOverflow(workAttempts.count).overflow { return nil }
        let continuation = obj["continuation"].flatMap(DeskContinuation.fromJSON)
        if obj["continuation"] != nil && continuation == nil { return nil }
        let progress = obj["progress"].flatMap(DeskProgress.fromJSON)
        if obj["progress"] != nil && progress == nil { return nil }
        let origin: DeskOrigin
        if let raw = obj["origin"]?.stringValue {
            guard let decoded = DeskOrigin(rawValue: raw) else { return nil }
            origin = decoded
        } else { origin = .owner } // current writer omits owner origin
        if let until = obj["deferUntil"]?.stringValue, DeskSequencing.parseDeferStamp(until) == nil { return nil }
        return DeskItem(
            handle: handle, alias: alias, parent: obj["parent"]?.stringValue,
            kind: kind, status: status, project: project, title: title,
            summary: obj["summary"]?.stringValue,
            assignee: obj["assignee"]?.stringValue,
            laneOf: obj["laneOf"]?.stringValue,
            progress: progress,
            refs: refs,
            cadence: cadence,
            notify: notify,
            notes: notes, openedAt: openedAt, updatedAt: updatedAt,
            closedAt: obj["closedAt"]?.stringValue,
            pinned: pinned,
            blockedReason: obj["blockedReason"]?.stringValue,
            waitingOn: obj["waitingOn"]?.stringValue,
            origin: origin,
            pursuit: pursuit,
            blockedOn: blockedOn,
            deferUntil: obj["deferUntil"]?.stringValue,
            workAttempts: workAttempts,
            continuation: continuation,
            findingKey: obj["findingKey"]?.stringValue
        )
    }
}
