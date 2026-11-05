import NativeAgentShared
import Foundation
import PersistenceCore
// Blueprint: | `DeskOperations.swift` | `DeskOpBody`: complete ops and explicit clears; `updateTitle` commits refs atomically |

// MARK: - Ops (DeskOp) — one event each; compact() folds into DeskState

/// Persisted operations must decode completely before replay so no mutation disappears.
public enum DeskOpBody: Sendable, Equatable {
    case createItem(alias: String, kind: DeskKind, project: String, title: String, parent: String?, summary: String?, assignee: String?, laneOf: String?,
        origin: DeskOrigin, pursuit: Pursuit?, findingKey: String? = nil)
    /// A dedicated token prevents generic creation from bypassing pursuit evidence gates.
    case openPursuit(alias: String, project: String, title: String, summary: String?, pursuit: Pursuit, notify: NotifyPolicy)
    case setStatus(
        status: DeskStatus,
        blockedReason: String?,
        waitingOn: String?,
        progress: DeskProgress?,
        assignee: String?,
        laneOf: String?
    )
    case updateTitle(title: String?, summary: String?, refs: [DeskRef]? = nil)
    case addRef(ref: DeskRef)
    case appendNote(text: String, author: String? = "system", releaseCondition: String? = nil)
    /// Record veto and cancellation atomically so the rationale survives replay.
    case vetoPursuit(note: String)
    case setCadence(cadence: Cadence)
    case setNotify(policy: NotifyPolicy)
    case closeItem(outcomeSummary: String, status: DeskStatus)   // status ∈ {done, canceled}
    case markNotified(at: String)
    case archiveItem
    case reserveWorkAttempt(attemptId: String, lane: DeskWorkAttempt.Lane, day: String, slot: String)
    case completeWorkAttempt(attemptId: String, receipt: String, disposition: DeskWorkDisposition? = nil, artifactRefs: [String] = [])
    case handOffWorkReceipt(reservationId: String)
    case workLog(receipt: String)
    // Replace complete fields so each operation owns the full replay truth.
    case setBlockedOn(handles: [String])
    case setDeferUntil(until: String?)     // nil / "" CLEARS the parked date
    case setContinuation(record: DeskContinuation)

    public var token: String {
        switch self {
        case .createItem: return "create_item"
        case .openPursuit: return "open_pursuit"
        case .setStatus: return "set_status"
        case .updateTitle: return "update_title"
        case .addRef: return "add_ref"
        case .appendNote: return "append_note"
        case .vetoPursuit: return "veto_pursuit"
        case .setCadence: return "set_cadence"
        case .setNotify: return "set_notify"
        case .closeItem: return "close_item"
        case .markNotified: return "mark_notified"
        case .archiveItem: return "archive_item"
        case .reserveWorkAttempt: return "reserve_work_attempt"
        case .completeWorkAttempt: return "complete_work_attempt"
        case .handOffWorkReceipt: return "hand_off_work_receipt"
        case .workLog: return "work_log"
        case .setBlockedOn: return "set_blocked_on"
        case .setDeferUntil: return "set_defer_until"
        case .setContinuation: return "set_continuation"
        }
    }
}

public struct DeskOp: Sendable, Equatable {
    public var opId: String
    public var ts: String
    public var handle: String
    public var body: DeskOpBody
    public var workAttempts: [DeskWorkAttempt] = []

    public init(opId: String = DeskClock.newOpId(), ts: String? = nil, handle: String, body: DeskOpBody) {
        self.opId = opId
        self.ts = ts ?? DeskClock.nowISO()
        self.handle = handle
        self.body = body
    }

    public var op: String { body.token }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "opId": .string(opId),
            "ts": .string(ts),
            "op": .string(body.token),
            "handle": .string(handle),
        ]
        if !workAttempts.isEmpty { obj["workAttempts"] = .array(workAttempts.map { $0.toJSON() }) }
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { obj[k] = .string(v) } }
        switch body {
        case let .createItem(alias, kind, project, title, parent, summary, assignee, laneOf, origin, pursuit, findingKey):
            obj["alias"] = .string(alias)
            obj["kind"] = .string(kind.rawValue)
            obj["project"] = .string(project)
            obj["title"] = .string(title)
            put("parent", parent)
            put("summary", summary)
            put("assignee", assignee)
            put("laneOf", laneOf)
            put("findingKey", findingKey)
            if origin != .owner { obj["origin"] = .string(origin.rawValue) }
            if let pursuit { obj["pursuit"] = pursuit.toJSON() }
        case let .openPursuit(alias, project, title, summary, pursuit, notify):
            obj["alias"] = .string(alias)
            obj["project"] = .string(project)
            obj["title"] = .string(title)
            put("summary", summary)
            obj["pursuit"] = pursuit.toJSON()
            if notify != NotifyPolicy() { obj["notify"] = notify.toJSON() }
        case let .setStatus(status, blockedReason, waitingOn, progress, assignee, laneOf):
            obj["status"] = .string(status.rawValue)
            put("blockedReason", blockedReason)
            put("waitingOn", waitingOn)
            if let progress { obj["progress"] = progress.toJSON() }
            put("assignee", assignee)
            put("laneOf", laneOf)
        case let .updateTitle(title, summary, refs):
            put("title", title)
            put("summary", summary)
            if let refs { obj["refs"] = .array(refs.map { $0.toJSON() }) }
        case let .addRef(ref):
            obj["ref"] = ref.toJSON()
        case let .appendNote(text, author, releaseCondition):
            obj["text"] = .string(text)
            put("author", author)
            if let releaseCondition { obj["releaseCondition"] = .string(releaseCondition) }
        case let .vetoPursuit(note):
            obj["note"] = .string(note)
        case let .setCadence(cadence):
            obj["cadence"] = cadence.toJSON()
        case let .setNotify(policy):
            obj["policy"] = policy.toJSON()
        case let .closeItem(outcomeSummary, status):
            obj["outcomeSummary"] = .string(outcomeSummary)
            obj["status"] = .string(status.rawValue)
        case let .markNotified(at):
            obj["at"] = .string(at)
        case .archiveItem:
            break
        case let .reserveWorkAttempt(attemptId, lane, day, slot):
            obj["attemptId"] = .string(attemptId)
            obj["lane"] = .string(lane.rawValue)
            obj["day"] = .string(day)
            obj["slot"] = .string(slot)
        case let .completeWorkAttempt(attemptId, receipt, disposition, artifactRefs):
            obj["attemptId"] = .string(attemptId)
            obj["receipt"] = .string(receipt)
            if let disposition { obj["disposition"] = .string(disposition.rawValue) }
            if !artifactRefs.isEmpty { obj["artifactRefs"] = .array(artifactRefs.map(JSONValue.string)) }
        case let .handOffWorkReceipt(reservationId):
            obj["reservationId"] = .string(reservationId)
        case let .workLog(receipt):
            obj["receipt"] = .string(receipt)
        case let .setBlockedOn(handles):
            // Emit even an empty set: omission would lose an explicit clear on replay.
            obj["blockedOn"] = .array(handles.map { .string($0) })
        case let .setDeferUntil(until):
            // An empty string is an explicit clear and must survive replay.
            obj["until"] = .string(until ?? "")
        case let .setContinuation(record):
            obj["continuation"] = record.toJSON()
        }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskOp? {
        guard case .object(let obj) = value,
              let opId = obj["opId"]?.stringValue,
              let ts = obj["ts"]?.stringValue,
              let token = obj["op"]?.stringValue,
              let handle = obj["handle"]?.stringValue else { return nil }
        let body: DeskOpBody
        guard !opId.isEmpty, !handle.isEmpty, DeskClock.parseISO(ts) != nil,
              DeskJSON.optionalStringsAreValid(obj, keys: ["parent", "summary", "assignee", "laneOf", "origin", "findingKey", "blockedReason", "waitingOn",
                  "title", "author", "disposition"])
        else { return nil }
        let pursuit = obj["pursuit"].flatMap(Pursuit.fromJSON)
        if obj["pursuit"] != nil && pursuit == nil { return nil }
        let progress = obj["progress"].flatMap(DeskProgress.fromJSON)
        if obj["progress"] != nil && progress == nil { return nil }
        switch token {
        case "create_item":
            if obj["pursuit"] != nil && pursuit == nil { return nil }
            guard let alias = obj["alias"]?.stringValue,
                  let kindRaw = obj["kind"]?.stringValue, let kind = DeskKind(rawValue: kindRaw),
                  let project = obj["project"]?.stringValue,
                  let title = obj["title"]?.stringValue else { return nil }
            let origin: DeskOrigin
            if let raw = obj["origin"]?.stringValue {
                guard let value = DeskOrigin(rawValue: raw) else { return nil }
                origin = value
            } else { origin = .owner } // omitted by the current owner-origin writer
            body = .createItem(alias: alias, kind: kind, project: project, title: title,
                               parent: obj["parent"]?.stringValue, summary: obj["summary"]?.stringValue,
                               assignee: obj["assignee"]?.stringValue, laneOf: obj["laneOf"]?.stringValue,
                               origin: origin,
                               pursuit: pursuit, findingKey: obj["findingKey"]?.stringValue)
        case "open_pursuit":
            guard let alias = obj["alias"]?.stringValue,
                  let project = obj["project"]?.stringValue,
                  let title = obj["title"]?.stringValue,
                  let pursuit else { return nil }
            let notify: NotifyPolicy
            if let raw = obj["notify"] {
                guard let policy = NotifyPolicy.fromJSON(raw) else { return nil }
                notify = policy
            } else { notify = NotifyPolicy() } // current writer omits the default policy
            body = .openPursuit(
                alias: alias,
                project: project,
                title: title,
                summary: obj["summary"]?.stringValue,
                pursuit: pursuit,
                notify: notify
            )
        case "set_status":
            guard let statusRaw = obj["status"]?.stringValue, let status = DeskStatus(rawValue: statusRaw) else { return nil }
            body = .setStatus(
                status: status,
                blockedReason: obj["blockedReason"]?.stringValue,
                waitingOn: obj["waitingOn"]?.stringValue,
                progress: progress,
                assignee: obj["assignee"]?.stringValue,
                laneOf: obj["laneOf"]?.stringValue
            )
        case "update_title":
            var refs: [DeskRef]?
            if let value = obj["refs"] {
                guard case .array(let rows) = value else { return nil }
                let decoded = rows.compactMap(DeskRef.fromJSON)
                guard decoded.count == rows.count else { return nil }
                refs = decoded
            }
            body = .updateTitle(title: obj["title"]?.stringValue, summary: obj["summary"]?.stringValue, refs: refs)
        case "add_ref":
            guard let refVal = obj["ref"], let ref = DeskRef.fromJSON(refVal) else { return nil }
            body = .addRef(ref: ref)
        case "append_note":
            guard let text = obj["text"]?.stringValue, DeskNote.fromJSON(value) != nil else { return nil }
            body = .appendNote(text: text, author: obj["author"]?.stringValue, releaseCondition: obj["releaseCondition"]?.stringValue)
        case "veto_pursuit":
            guard let note = obj["note"]?.stringValue, !note.isEmpty else { return nil }
            body = .vetoPursuit(note: note)
        case "set_cadence":
            guard let c = obj["cadence"], let cadence = Cadence.fromJSON(c) else { return nil }
            body = .setCadence(cadence: cadence)
        case "set_notify":
            guard let p = obj["policy"], let policy = NotifyPolicy.fromJSON(p) else { return nil }
            body = .setNotify(policy: policy)
        case "close_item":
            guard let outcome = obj["outcomeSummary"]?.stringValue,
                  let raw = obj["status"]?.stringValue, let status = DeskStatus(rawValue: raw), status.isTerminal else { return nil }
            body = .closeItem(outcomeSummary: outcome, status: status)
        case "mark_notified":
            guard let at = obj["at"]?.stringValue else { return nil }
            body = .markNotified(at: at)
        case "archive_item":
            body = .archiveItem
        case "reserve_work_attempt":
            guard let attemptId = obj["attemptId"]?.stringValue,
                  let laneRaw = obj["lane"]?.stringValue,
                  let lane = DeskWorkAttempt.Lane(rawValue: laneRaw),
                  let day = obj["day"]?.stringValue,
                  let slot = obj["slot"]?.stringValue else { return nil }
            body = .reserveWorkAttempt(attemptId: attemptId, lane: lane, day: day, slot: slot)
        case "complete_work_attempt":
            guard let attemptId = obj["attemptId"]?.stringValue,
                  let receipt = obj["receipt"]?.stringValue else { return nil }
            let disposition = obj["disposition"]?.stringValue.flatMap(DeskWorkDisposition.init(rawValue:))
            guard obj["disposition"] == nil || disposition != nil,
                  let artifacts = DeskJSON.strings(obj["artifactRefs"]) else { return nil }
            body = .completeWorkAttempt(attemptId: attemptId, receipt: receipt, disposition: disposition, artifactRefs: artifacts)
        case "work_log":
            guard let receipt = obj["receipt"]?.stringValue else { return nil }
            body = .workLog(receipt: receipt)
        case "hand_off_work_receipt":
            guard let reservationId = obj["reservationId"]?.stringValue else { return nil }
            body = .handOffWorkReceipt(reservationId: reservationId)
        case "set_blocked_on":
            guard let handles = DeskJSON.strings(obj["blockedOn"], defaultWhenAbsent: false) else { return nil }
            body = .setBlockedOn(handles: handles)
        case "set_defer_until":
            guard let raw = obj["until"]?.stringValue,
                  raw.isEmpty || DeskSequencing.parseDeferStamp(raw) != nil else { return nil }
            body = .setDeferUntil(until: raw.isEmpty ? nil : raw)
        case "set_continuation":
            guard let value = obj["continuation"], let record = DeskContinuation.fromJSON(value) else { return nil }
            body = .setContinuation(record: record)
        default:
            return nil
        }
        guard let attempts = DeskWorkAttempt.readAttempts(obj) else { return nil }
        if let pursuit,
           pursuit.retiredSessions.addingReportingOverflow(attempts.count).overflow { return nil }
        var op = DeskOp(opId: opId, ts: ts, handle: handle, body: body)
        op.workAttempts = attempts
        guard op.toJSON() == value else { return nil }
        return op
    }
}
