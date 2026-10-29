import NativeAgentShared
import Foundation
import PersistenceCore
// Blueprint: | `DeskOperations.swift` | `DeskOpBody` enum; `updateTitle` optionally replaces refs with the same replayable summary update |

// MARK: - Ops (DeskOp) — one event each; compact() folds into DeskState

/// The mutation payload. Every op also carries a `handle` (the item it targets,
/// or — for create — the newly assigned handle). Tolerant decode: an unknown
/// `op` token yields nil and is skipped by the rebuild.
public enum DeskOpBody: Sendable, Equatable {
    case createItem(alias: String, kind: DeskKind, project: String, title: String, parent: String?, summary: String?, assignee: String?, laneOf: String?, origin: DeskOrigin, pursuit: Pursuit?, findingKey: String? = nil)
    /// A dedicated token keeps older writers from treating pursuits as ordinary projects.
    /// Origin is implicitly .agent, kind implicitly .project.
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
    case updateRef(refId: String, cachedFields: [String: JSONValue])
    case appendNote(text: String, author: String? = "system")
    /// One atomic user veto: the pursuit becomes canceled and carries the
    /// durable rationale in the same replayable event.
    case vetoPursuit(note: String)
    case setCadence(cadence: Cadence)
    case setNotify(policy: NotifyPolicy)
    case closeItem(outcomeSummary: String, status: DeskStatus)   // status ∈ {done, canceled}
    case markNotified(at: String)   // notify fired — stamps notify.lastNotifiedAt, NOT updatedAt
    case archiveItem
    case reserveWorkAttempt(attemptId: String, lane: DeskWorkAttempt.Lane, day: String, slot: String)
    case completeWorkAttempt(attemptId: String, receipt: String, disposition: DeskWorkDisposition? = nil, artifactRefs: [String] = [])
    case handOffWorkReceipt(reservationId: String)
    case workLog(receipt: String)   // desk_work_log — a plain work receipt note
    // Sequencing seam. Both REPLACE (never merge) so the op is the whole truth
    // of the field at that point in the feed.
    case setBlockedOn(handles: [String])   // replaces the WHOLE blocker set
    case setDeferUntil(until: String?)     // nil / "" CLEARS the parked date
    case setContinuation(record: DeskContinuation)

    public var token: String {
        switch self {
        case .createItem: return "create_item"
        case .openPursuit: return "open_pursuit"
        case .setStatus: return "set_status"
        case .updateTitle: return "update_title"
        case .addRef: return "add_ref"
        case .updateRef: return "update_ref"
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
            // Origin is omitted when .owner so a pre-origin create op re-serializes
            // BYTE-IDENTICAL; pursuit emitted only for an origin=agent create.
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
        case let .updateRef(refId, cachedFields):
            obj["refId"] = .string(refId)
            obj["cachedFields"] = .object(cachedFields)
        case let .appendNote(text, author):
            obj["text"] = .string(text)
            put("author", author)
        case let .vetoPursuit(note):
            obj["note"] = .string(note)
        case let .setCadence(cadence):
            obj["cadence"] = cadence.toJSON()
        case let .setNotify(policy):
            obj["policy"] = policy.toJSON()
        case let .closeItem(outcomeSummary, status):
            obj["outcomeSummary"] = .string(outcomeSummary)
            // close_item is terminal by definition — clamp on encode too so a
            // directly-constructed op can never persist a non-terminal status.
            obj["status"] = .string((status.isTerminal ? status : .done).rawValue)
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
            // ALWAYS emitted, even EMPTY — an empty set is a CLEAR, and the
            // omit-empty `put` helper above would drop it and silently lose the
            // clear on replay (the exact shape of the update_title empty-summary
            // bug this file already carries a scar from).
            obj["blockedOn"] = .array(handles.map { .string($0) })
        case let .setDeferUntil(until):
            // Same reason: "" IS the clear and must survive the round-trip.
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
        if token == "set_continuation" {
            guard let value = obj["continuation"], let record = DeskContinuation.fromJSON(value) else { return nil }
            return DeskOp(opId: opId, ts: ts, handle: handle, body: .setContinuation(record: record))
        }
        let pursuit = obj["pursuit"].flatMap(Pursuit.fromJSON)
        switch token {
        case "create_item":
            if obj["pursuit"] != nil && pursuit == nil { return nil }
            guard let alias = obj["alias"]?.stringValue,
                  let kindRaw = obj["kind"]?.stringValue, let kind = DeskKind(rawValue: kindRaw),
                  let project = obj["project"]?.stringValue,
                  let title = obj["title"]?.stringValue else { return nil }
            // Origin defaults to .owner; pursuit is optional.
            body = .createItem(alias: alias, kind: kind, project: project, title: title,
                               parent: obj["parent"]?.stringValue, summary: obj["summary"]?.stringValue,
                               assignee: obj["assignee"]?.stringValue, laneOf: obj["laneOf"]?.stringValue,
                               origin: obj["origin"]?.stringValue.flatMap(DeskOrigin.decodePersisted) ?? .owner,
                               pursuit: pursuit, findingKey: obj["findingKey"]?.stringValue)
        case "open_pursuit":
            guard let alias = obj["alias"]?.stringValue,
                  let project = obj["project"]?.stringValue,
                  let title = obj["title"]?.stringValue,
                  let pursuit else { return nil }
            body = .openPursuit(
                alias: alias,
                project: project,
                title: title,
                summary: obj["summary"]?.stringValue,
                pursuit: pursuit,
                notify: obj["notify"].map { NotifyPolicy.fromJSON($0) } ?? NotifyPolicy()
            )
        case "set_status":
            guard let statusRaw = obj["status"]?.stringValue, let status = DeskStatus(rawValue: statusRaw) else { return nil }
            body = .setStatus(
                status: status,
                blockedReason: obj["blockedReason"]?.stringValue,
                waitingOn: obj["waitingOn"]?.stringValue,
                progress: obj["progress"].flatMap { DeskProgress.fromJSON($0) },
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
        case "update_ref":
            guard let refId = obj["refId"]?.stringValue else { return nil }
            var fields: [String: JSONValue] = [:]
            if case .object(let f)? = obj["cachedFields"] { fields = f }
            body = .updateRef(refId: refId, cachedFields: fields)
        case "append_note":
            guard let text = obj["text"]?.stringValue else { return nil }
            body = .appendNote(text: text, author: obj["author"]?.stringValue)
        case "veto_pursuit":
            guard let note = obj["note"]?.stringValue, !note.isEmpty else { return nil }
            body = .vetoPursuit(note: note)
        case "set_cadence":
            guard let c = obj["cadence"] else { return nil }
            body = .setCadence(cadence: Cadence.fromJSON(c))
        case "set_notify":
            guard let p = obj["policy"] else { return nil }
            body = .setNotify(policy: NotifyPolicy.fromJSON(p))
        case "close_item":
            guard let outcome = obj["outcomeSummary"]?.stringValue else { return nil }
            let decoded = obj["status"]?.stringValue.flatMap { DeskStatus(rawValue: $0) } ?? .done
            // close_item is terminal by definition — a non-terminal token clamps
            // to .done rather than materializing a half-closed lifecycle row.
            body = .closeItem(outcomeSummary: outcome, status: decoded.isTerminal ? decoded : .done)
        case "mark_notified":
            guard let at = obj["at"]?.stringValue else { return nil }
            body = .markNotified(at: at)
        case "archive_item":
            body = .archiveItem
        case "reserve_work_session":
            guard let reservationId = obj["reservationId"]?.stringValue,
                  let day = obj["day"]?.stringValue,
                  let slot = obj["slot"]?.stringValue else { return nil }
            body = .reserveWorkAttempt(attemptId: reservationId, lane: .pursuit, day: day, slot: slot)
        case "complete_work_session":
            guard let reservationId = obj["reservationId"]?.stringValue,
                  let receipt = obj["receipt"]?.stringValue else { return nil }
            body = .completeWorkAttempt(attemptId: reservationId, receipt: receipt,
                disposition: obj["disposition"]?.stringValue.flatMap(DeskWorkDisposition.init(rawValue:)),
                artifactRefs: (obj["artifactRefs"]?.arrayValue?.compactMap(\.stringValue) ?? []))
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
            body = .completeWorkAttempt(attemptId: attemptId, receipt: receipt,
                                        disposition: obj["disposition"]?.stringValue.flatMap(DeskWorkDisposition.init(rawValue:)),
                                        artifactRefs: (obj["artifactRefs"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        case "work_log":
            guard let receipt = obj["receipt"]?.stringValue else { return nil }
            body = .workLog(receipt: receipt)
        case "hand_off_work_receipt":
            guard let reservationId = obj["reservationId"]?.stringValue else { return nil }
            body = .handOffWorkReceipt(reservationId: reservationId)
        case "set_blocked_on":
            // Absent / wrong-typed → [] , which is the CLEAR. The op is a
            // whole-set replace, so there is nothing to preserve on a partial read.
            body = .setBlockedOn(handles: (obj["blockedOn"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        case "set_defer_until":
            let raw = obj["until"]?.stringValue ?? ""
            body = .setDeferUntil(until: raw.isEmpty ? nil : raw)
        default:
            return nil // tolerant: unknown op tokens skipped
        }
        guard let attempts = DeskWorkAttempt.readAttempts(obj) else { return nil }
        if let pursuit,
           pursuit.retiredSessions.addingReportingOverflow(attempts.count).overflow { return nil }
        var op = DeskOp(opId: opId, ts: ts, handle: handle, body: body)
        op.workAttempts = attempts
        return op
    }
}
