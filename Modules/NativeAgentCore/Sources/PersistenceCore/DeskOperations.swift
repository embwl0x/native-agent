import Foundation

// MARK: - Ops (DeskOp) — one event each; compact() folds into DeskState

/// The mutation payload. Every op also carries a `handle` (the item it targets,
/// or — for create — the newly assigned handle). Tolerant decode: an unknown
/// `op` token yields nil and is skipped by the rebuild.
public enum DeskOpBody: Sendable, Equatable {
    case createItem(alias: String, kind: DeskKind, project: String, title: String, parent: String?, summary: String?, assignee: String?, laneOf: String?, origin: DeskOrigin, pursuit: Pursuit?)
    /// Agent self-pursuit creation under a DEDICATED op token (H2, 2026-07-11
    /// review). A pre-Workshop binary sharing the ops flock decodes an unknown
    /// token to nil and SKIPS it — so an old writer can never see a pursuit as
    /// an ordinary user project, mutate it past the cap, or drop its fields on
    /// reserialize. origin is implicitly .agent, kind implicitly .project.
    case openPursuit(alias: String, project: String, title: String, summary: String?, pursuit: Pursuit, notify: NotifyPolicy)
    case setStatus(
        status: DeskStatus,
        blockedReason: String?,
        waitingOn: String?,
        progress: DeskProgress?,
        assignee: String?,
        laneOf: String?
    )
    case updateTitle(title: String?, summary: String?)
    case addRef(ref: DeskRef)
    case updateRef(refId: String, cachedFields: [String: JSONValue])
    case appendNote(text: String)
    /// One atomic user veto: the pursuit becomes canceled and carries the
    /// durable rationale in the same replayable event.
    case vetoPursuit(note: String)
    case setCadence(cadence: Cadence)
    case setNotify(policy: NotifyPolicy)
    case closeItem(outcomeSummary: String, status: DeskStatus)   // status ∈ {done, canceled}
    case markNotified(at: String)   // notify fired — stamps notify.lastNotifiedAt, NOT updatedAt
    case archiveItem
    // Workshop work-session seam (Wave B drives these; Wave A designs them).
    case reserveWorkSession(reservationId: String, day: String, slot: String)
    case completeWorkSession(reservationId: String, receipt: String)
    case settleWorkSession(reservationId: String, receipt: String, disposition: DeskWorkDisposition, artifactRefs: [String])
    case reserveWorkAttempt(attemptId: String, lane: DeskWorkAttempt.Lane, day: String, slot: String)
    case completeWorkAttempt(attemptId: String, receipt: String)
    case workLog(receipt: String)   // desk_work_log — a plain work receipt note
    // Sequencing seam. Both REPLACE (never merge) so the op is the whole truth
    // of the field at that point in the feed.
    case setBlockedOn(handles: [String])   // replaces the WHOLE blocker set
    case setDeferUntil(until: String?)     // nil / "" CLEARS the parked date

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
        case .reserveWorkSession: return "reserve_work_session"
        case .completeWorkSession: return "complete_work_session"
        case .settleWorkSession: return "complete_work_session"
        case .reserveWorkAttempt: return "reserve_work_attempt"
        case .completeWorkAttempt: return "complete_work_attempt"
        case .workLog: return "work_log"
        case .setBlockedOn: return "set_blocked_on"
        case .setDeferUntil: return "set_defer_until"
        }
    }
}

public struct DeskOp: Sendable, Equatable {
    public var opId: String
    public var ts: String
    public var handle: String
    public var body: DeskOpBody

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
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { obj[k] = .string(v) } }
        switch body {
        case let .createItem(alias, kind, project, title, parent, summary, assignee, laneOf, origin, pursuit):
            obj["alias"] = .string(alias)
            obj["kind"] = .string(kind.rawValue)
            obj["project"] = .string(project)
            obj["title"] = .string(title)
            put("parent", parent)
            put("summary", summary)
            put("assignee", assignee)
            put("laneOf", laneOf)
            // M10: origin OMITTED when .owner so a pre-origin create op re-serializes
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
        case let .updateTitle(title, summary):
            put("title", title)
            put("summary", summary)
        case let .addRef(ref):
            obj["ref"] = ref.toJSON()
        case let .updateRef(refId, cachedFields):
            obj["refId"] = .string(refId)
            obj["cachedFields"] = .object(cachedFields)
        case let .appendNote(text):
            obj["text"] = .string(text)
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
        case let .reserveWorkSession(reservationId, day, slot):
            obj["reservationId"] = .string(reservationId)
            obj["day"] = .string(day)
            obj["slot"] = .string(slot)
        case let .completeWorkSession(reservationId, receipt):
            obj["reservationId"] = .string(reservationId)
            obj["receipt"] = .string(receipt)
        case let .settleWorkSession(reservationId, receipt, disposition, artifactRefs):
            obj["reservationId"] = .string(reservationId)
            obj["receipt"] = .string(receipt)
            obj["disposition"] = .string(disposition.rawValue)
            obj["artifactRefs"] = .array(artifactRefs.map(JSONValue.string))
        case let .reserveWorkAttempt(attemptId, lane, day, slot):
            obj["attemptId"] = .string(attemptId)
            obj["lane"] = .string(lane.rawValue)
            obj["day"] = .string(day)
            obj["slot"] = .string(slot)
        case let .completeWorkAttempt(attemptId, receipt):
            obj["attemptId"] = .string(attemptId)
            obj["receipt"] = .string(receipt)
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
        }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskOp? {
        guard case .object(let obj) = value,
              let opId = jsonString(obj, "opId"),
              let ts = jsonString(obj, "ts"),
              let token = jsonString(obj, "op"),
              let handle = jsonString(obj, "handle") else { return nil }
        let body: DeskOpBody
        switch token {
        case "create_item":
            guard let alias = jsonString(obj, "alias"),
                  let kindRaw = jsonString(obj, "kind"), let kind = DeskKind(rawValue: kindRaw),
                  let project = jsonString(obj, "project"),
                  let title = jsonString(obj, "title") else { return nil }
            // M10: origin decodes OPTIONAL defaulting .owner; pursuit optional.
            body = .createItem(alias: alias, kind: kind, project: project, title: title,
                               parent: jsonString(obj, "parent"), summary: jsonString(obj, "summary"),
                               assignee: jsonString(obj, "assignee"), laneOf: jsonString(obj, "laneOf"),
                               origin: jsonString(obj, "origin").flatMap(DeskOrigin.decodePersisted) ?? .owner,
                               pursuit: obj["pursuit"].map { Pursuit.fromJSON($0) })
        case "open_pursuit":
            guard let alias = jsonString(obj, "alias"),
                  let project = jsonString(obj, "project"),
                  let title = jsonString(obj, "title"),
                  let pursuitVal = obj["pursuit"] else { return nil }
            body = .openPursuit(
                alias: alias,
                project: project,
                title: title,
                summary: jsonString(obj, "summary"),
                pursuit: Pursuit.fromJSON(pursuitVal),
                notify: obj["notify"].map { NotifyPolicy.fromJSON($0) } ?? NotifyPolicy()
            )
        case "set_status":
            guard let statusRaw = jsonString(obj, "status"), let status = DeskStatus(rawValue: statusRaw) else { return nil }
            body = .setStatus(
                status: status,
                blockedReason: jsonString(obj, "blockedReason"),
                waitingOn: jsonString(obj, "waitingOn"),
                progress: obj["progress"].flatMap { DeskProgress.fromJSON($0) },
                assignee: jsonString(obj, "assignee"),
                laneOf: jsonString(obj, "laneOf")
            )
        case "update_title":
            body = .updateTitle(title: jsonString(obj, "title"), summary: jsonString(obj, "summary"))
        case "add_ref":
            guard let refVal = obj["ref"], let ref = DeskRef.fromJSON(refVal) else { return nil }
            body = .addRef(ref: ref)
        case "update_ref":
            guard let refId = jsonString(obj, "refId") else { return nil }
            var fields: [String: JSONValue] = [:]
            if case .object(let f)? = obj["cachedFields"] { fields = f }
            body = .updateRef(refId: refId, cachedFields: fields)
        case "append_note":
            guard let text = jsonString(obj, "text") else { return nil }
            body = .appendNote(text: text)
        case "veto_pursuit":
            guard let note = jsonString(obj, "note"), !note.isEmpty else { return nil }
            body = .vetoPursuit(note: note)
        case "set_cadence":
            guard let c = obj["cadence"] else { return nil }
            body = .setCadence(cadence: Cadence.fromJSON(c))
        case "set_notify":
            guard let p = obj["policy"] else { return nil }
            body = .setNotify(policy: NotifyPolicy.fromJSON(p))
        case "close_item":
            guard let outcome = jsonString(obj, "outcomeSummary") else { return nil }
            let decoded = jsonString(obj, "status").flatMap { DeskStatus(rawValue: $0) } ?? .done
            // close_item is terminal by definition — a non-terminal token clamps
            // to .done rather than materializing a half-closed lifecycle row.
            body = .closeItem(outcomeSummary: outcome, status: decoded.isTerminal ? decoded : .done)
        case "mark_notified":
            guard let at = jsonString(obj, "at") else { return nil }
            body = .markNotified(at: at)
        case "archive_item":
            body = .archiveItem
        case "reserve_work_session":
            guard let reservationId = jsonString(obj, "reservationId"),
                  let day = jsonString(obj, "day"),
                  let slot = jsonString(obj, "slot") else { return nil }
            body = .reserveWorkSession(reservationId: reservationId, day: day, slot: slot)
        case "complete_work_session":
            guard let reservationId = jsonString(obj, "reservationId"),
                  let receipt = jsonString(obj, "receipt") else { return nil }
            if let raw = jsonString(obj, "disposition"),
               let disposition = DeskWorkDisposition(rawValue: raw) {
                body = .settleWorkSession(
                    reservationId: reservationId,
                    receipt: receipt,
                    disposition: disposition,
                    artifactRefs: jsonStringArray(obj, "artifactRefs")
                )
            } else {
                body = .completeWorkSession(reservationId: reservationId, receipt: receipt)
            }
        case "reserve_work_attempt":
            guard let attemptId = jsonString(obj, "attemptId"),
                  let laneRaw = jsonString(obj, "lane"),
                  let lane = DeskWorkAttempt.Lane(rawValue: laneRaw),
                  let day = jsonString(obj, "day"),
                  let slot = jsonString(obj, "slot") else { return nil }
            body = .reserveWorkAttempt(attemptId: attemptId, lane: lane, day: day, slot: slot)
        case "complete_work_attempt":
            guard let attemptId = jsonString(obj, "attemptId"),
                  let receipt = jsonString(obj, "receipt") else { return nil }
            body = .completeWorkAttempt(attemptId: attemptId, receipt: receipt)
        case "work_log":
            guard let receipt = jsonString(obj, "receipt") else { return nil }
            body = .workLog(receipt: receipt)
        case "set_blocked_on":
            // Absent / wrong-typed → [] , which is the CLEAR. The op is a
            // whole-set replace, so there is nothing to preserve on a partial read.
            body = .setBlockedOn(handles: jsonStringArray(obj, "blockedOn"))
        case "set_defer_until":
            let raw = jsonString(obj, "until") ?? ""
            body = .setDeferUntil(until: raw.isEmpty ? nil : raw)
        default:
            return nil // tolerant: unknown op tokens skipped
        }
        return DeskOp(opId: opId, ts: ts, handle: handle, body: body)
    }
}
