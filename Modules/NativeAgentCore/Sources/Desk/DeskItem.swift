import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskItem.swift` | Derived live Desk items and explicit progress; statusDescription reads existing status/waitingOn without rewriting persisted rows |

// MARK: - Item (a derived row — never serialized as a mutation, only state.json)

/// Explicit progress reported by the agent. The Desk never derives a value: callers must provide a positive total and a completed count inside it.
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
    /// Person waits keep the existing persisted status/party fields. All readers speak the same status without migrating an agent's stored work.
    public var statusDescription: String {
        if !status.isTerminal, let party = waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines), !party.isEmpty {
            return "waiting on " + party
        }
        return status.rawValue
    }
    public var continuation: DeskContinuation?
    public var findingKey: String?
    public var handle: String           // stable
    public var alias: String            // view number "2" / "2.1" — stable, never renumbered
    public var parent: String?
    public var kind: DeskKind
    public var status: DeskStatus
    public var project: String
    public var title: String
    public var summary: String?
    /// Delegation display metadata only. Neither field changes hierarchy, scheduling, admission, or ownership semantics.
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
    /// Stable blocker handles; `DeskSequencing` derives blockedness so closing a blocker unblocks dependents.
    public var blockedOn: [String]
    /// `yyyy-MM-dd` day or full ISO stamp this item is deliberately parked until. A deferred item is not ready AND is never flagged stale.
    public var deferUntil: String?
    public var origin: DeskOrigin       // immutable after create; default .owner
    public var pursuit: Pursuit?        // present only for origin=agent, kind=project
    /// Direct Desk-owned execution attempts for non-pursuit lanes.
    public var workAttempts: [DeskWorkAttempt]

    /// True for a store-recognized pursuit: self-authored project. The work-session ops and the open-pursuit cap key on exactly this shape.
    public var isPursuit: Bool { origin == .agent && kind == .project && pursuit != nil }

    /// The declared lifetime is elapsed days from this durable work's opening.
    public var pursuitExpiresAt: Date? {
        guard isPursuit, let pursuit, let opened = DeskClock.parseISO(openedAt) else { return nil }
        return opened.addingTimeInterval(TimeInterval(pursuit.maxDays) * 86_400)
    }

    /// True only when canonical Desk state names the human owner as the party that must unblock a nonterminal item (`OwnerAttentionPolicy`). A generic `blocked` status is not enough: verification failures, unavailable external systems, and
    /// domain-owned reconciliation can all be blocked without requiring user action.
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

    /// Live refs in render priority order (gh_pr > gh_issue > … > note), capped.
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
        // Default sequencing fields are omitted to preserve existing row shapes.
        if !blockedOn.isEmpty { obj["blockedOn"] = .array(blockedOn.map { .string($0) }) }
        if let deferUntil, !deferUntil.isEmpty { obj["deferUntil"] = .string(deferUntil) }
        // Default origin is omitted for byte compatibility; pursuit is emitted only when present.
        if origin != .owner { obj["origin"] = .string(origin.rawValue) }
        if let pursuit { obj["pursuit"] = pursuit.toJSON() }
        if !workAttempts.isEmpty { obj["workAttempts"] = .array(workAttempts.map { $0.toJSON() }) }
        if let continuation { obj["continuation"] = continuation.toJSON() }
        if let findingKey { obj["findingKey"] = .string(findingKey) }
        return .object(obj)
    }

    /// Default reads skip unknown refs and malformed collection rows for forward compatibility. Compaction-base reads require `strictCollections` so the sole surviving snapshot loses no ledger rows.
    public static func fromJSON(_ value: JSONValue, strictCollections: Bool = false) -> DeskItem? {
        guard case .object(let obj) = value,
              let handle = obj["handle"]?.stringValue,
              let alias = obj["alias"]?.stringValue,
              let kindRaw = obj["kind"]?.stringValue, let kind = DeskKind(rawValue: kindRaw),
              let statusRaw = obj["status"]?.stringValue, let status = DeskStatus(rawValue: statusRaw),
              let project = obj["project"]?.stringValue,
              let title = obj["title"]?.stringValue,
              let openedAt = obj["openedAt"]?.stringValue,
              let updatedAt = obj["updatedAt"]?.stringValue else { return nil }
        var refs: [DeskRef] = []
        if case .array(let arr)? = obj["refs"] {
            refs = arr.compactMap { DeskRef.fromJSON($0) }
            if strictCollections, refs.count != arr.count { return nil }
        } else if strictCollections, obj["refs"] != nil {
            return nil   // present but not an array — corrupt, never "empty"
        }
        var notes: [DeskNote] = []
        if case .array(let arr)? = obj["notes"] {
            notes = arr.compactMap { DeskNote.fromJSON($0) }
            if strictCollections, notes.count != arr.count { return nil }
        } else if strictCollections, obj["notes"] != nil {
            return nil   // present but not an array — corrupt, never "empty"
        }
        // blockedOn: same strict rule as refs/notes/reservations. In the compaction base this snapshot is the ONLY copy — a silently-dropped blocker edge would vanish a dependency FOREVER, and the item would read as ready when it is not.
        var blockedOn: [String] = []
        if case .array(let arr)? = obj["blockedOn"] {
            blockedOn = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            if strictCollections, blockedOn.count != arr.count { return nil }
        } else if strictCollections, obj["blockedOn"] != nil {
            return nil   // present but not an array — corrupt, never "empty"
        }
        guard let workAttempts = DeskWorkAttempt.readAttempts(obj) else { return nil }
        let pursuit = obj["pursuit"].flatMap(Pursuit.fromJSON)
        if strictCollections, let pursuitValue = obj["pursuit"] {
            // A present pursuit must be an OBJECT, and every nested ledger collection that is present must be a fully-decodable array — a wrong-typed value decoding to empty/default would silently shrink the reservation cap ledger or the
            // dossier.
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
        return DeskItem(
            handle: handle, alias: alias, parent: obj["parent"]?.stringValue,
            kind: kind, status: status, project: project, title: title,
            summary: obj["summary"]?.stringValue,
            assignee: obj["assignee"]?.stringValue,
            laneOf: obj["laneOf"]?.stringValue,
            progress: obj["progress"].flatMap { DeskProgress.fromJSON($0) },
            refs: refs,
            cadence: obj["cadence"].map { Cadence.fromJSON($0) } ?? Cadence(),
            notify: obj["notify"].map { NotifyPolicy.fromJSON($0) } ?? NotifyPolicy(),
            notes: notes, openedAt: openedAt, updatedAt: updatedAt,
            closedAt: obj["closedAt"]?.stringValue,
            pinned: obj["pinned"]?.boolValue ?? false,
            blockedReason: obj["blockedReason"]?.stringValue,
            waitingOn: obj["waitingOn"]?.stringValue,
            // Origin defaults to .owner; pursuit is optional.
            origin: obj["origin"]?.stringValue.flatMap(DeskOrigin.decodePersisted) ?? .owner,
            pursuit: pursuit,
            blockedOn: blockedOn,
            deferUntil: obj["deferUntil"]?.stringValue,
            workAttempts: workAttempts,
            continuation: continuation,
            findingKey: obj["findingKey"]?.stringValue
        )
    }
}
