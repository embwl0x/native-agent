import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import Darwin
import AppKit
import MacControl
import Desk
import StandingBots
import Transcripts
import ChatToolParsing
// Blueprint: | `DelegationContactEvidence.swift` | Contact-specific retained delivery evidence, lifecycle ordering and scalar interpretation |

extension DelegationStatusProjector {
    // MARK: - Claude projection

    static func projectClaude(url: URL, now: Date, object job: [String: JSONValue]) -> DelegationReadout? {
        // messageId is the claude record's identity (it is also the filename stem). Fall back to the stem so a record that lost the field still shows up addressable rather than being dropped.
        let id = string(job, "messageId") ?? url.deletingPathExtension().lastPathComponent
        let createdAt = string(job, "createdAt")
        let claimedAt = string(job, "claimedAt")
        let startedAt = string(job, "startedAt")
        let completedAt = string(job, "completedAt")
        // heartbeatAt proves the RUNNER is alive; progressAt proves the CHILD is. Either one is liveness, so the projection takes the later.
        let liveness = laterISO(string(job, "heartbeatAt"), string(job, "progressAt"))

        let start = firstDate(startedAt, claimedAt, createdAt)
        let end = date(completedAt) ?? now
        let elapsed = start.map { Int(max(0, end.timeIntervalSince($0)).rounded()) }

        // Completed runs ignore run deadlines; failed spawns are terminal.
        let state = string(job, "state")
        // Delivery stays nonterminal and uses runEndedAt for its grace clock when available.
        let delivering = completedAt == nil && state == "delivering"
        let terminal = !delivering && (completedAt != nil
            || string(job, "runStatus") != nil
            || ["settled", "spawn_failed"].contains(state ?? ""))
        let stalled: Bool
        let basis: DelegationReadout.StallBasis
        let stallDeadline: Date?
        if delivering {
            let clock = firstDate(string(job, "runEndedAt"), liveness, startedAt, claimedAt, createdAt)
            let deadline = clock?.addingTimeInterval(deliveryStallSeconds)
            stalled = deadline.map { now >= $0 } ?? false
            basis = deadline == nil ? .none : .deliveryStall
            stallDeadline = deadline
        } else {
            (stalled, basis, stallDeadline) = stallVerdict(
                terminal: terminal,
                deadlineAt: string(job, "deadlineAt"),
                stallSeconds: job["stallSeconds"]?.numberValue(coercingStrings: true, finiteOnly: false),
                lastLiveness: liveness ?? startedAt ?? claimedAt ?? createdAt,
                now: now
            )
        }

        var row = DelegationReadout(
            id: id,
            motorOwnerID: id,
            source: "claude",
            agent: "claude",
            topicSlug: string(job, "topicSlug"),
            deskHandle: nestedString(job, objectKey: "payload", field: "deskHandle"),
            state: state,
            status: string(job, "status"),
            runStatus: string(job, "runStatus"),
            createdAt: createdAt,
            claimedAt: claimedAt,
            startedAt: startedAt,
            lastLiveness: liveness,
            completedAt: completedAt,
            elapsedSeconds: elapsed,
            stalled: stalled,
            stallBasis: basis,
            deliveryLost: job["deliveryLost"]?.boolValue,
            deliveryOutcome: claudeDeliveryOutcome(job),
            completionTextHead: head(string(job, "completionText")),
            producerSchemaVersion: nestedInt(job, objectKey: "payload", field: "producerSchemaVersion"),
            producerSourceRevision: nestedString(job, objectKey: "payload", field: "producerSourceRevision"),
            stallDeadline: stallDeadline
        )
        row.recencyKey = firstDate(completedAt, liveness, startedAt, claimedAt, createdAt)
        Self.retainReply(string(job, "agentReplyText"), truncated: job["agentReplyTruncated"]?.boolValue ?? true, in: &row)
        row.acceptedMessageIDs = Set([Self.recordedLookupID(job["messageId"])].compactMap { $0 })
        if row.deliveryOutcome == "blocked", string(job, "bridgeReason") == "missing_origin_session" {
            row.deliveryReason = "missing_origin_session"
        }
        if case .object(let payload)? = job["payload"] { row.requestTextHead = head(string(payload, "text")) }
        return row
    }

    // MARK: - Codex projection

    static func projectCodex(url: URL, undelivered: Bool, now: Date, object job: [String: JSONValue]) -> DelegationReadout? {
        let id = string(job, "id") ?? url.deletingPathExtension().lastPathComponent
        let createdAt = string(job, "createdAt")
        // boundAt is when the watcher bound this job to a live turn — the closest analogue the codex record has to claude's claimedAt.
        let claimedAt = string(job, "boundAt")

        var turnResult: [String: JSONValue] = [:]
        if case .object(let exec)? = job["completedExecution"], case .object(let tr)? = exec["turnResult"] {
            turnResult = tr
        }
        let completedAt = string(turnResult, "completedAt")
        let runStatus = string(turnResult, "status")

        var probe: [String: JSONValue] = [:]
        if case .object(let value)? = job["stallProbe"] { probe = value }
        var watcherObservedAt: String?
        if case .object(let wait)? = job["lastWait"] { watcherObservedAt = string(wait, "observedAt") }
        var liveness: String?
        if case .object(let snapshot)? = probe["rolloutSnapshot"],
           let mtime = snapshot["mtimeMs"]?.numberValue(coercingStrings: true, finiteOnly: false), mtime.isFinite {
            liveness = NativeTimestampFormat.fractionalZulu(Date(timeIntervalSince1970: mtime / 1000))
        }

        let start = firstDate(claimedAt, createdAt)
        let end = date(completedAt) ?? now
        let elapsed = start.map { Int(max(0, end.timeIntervalSince($0)).rounded()) }

        let terminal = completedAt != nil || !turnResult.isEmpty
        let (idleStalled, idleBasis, stallDeadline) = stallVerdict(
            terminal: terminal, deadlineAt: nil,
            stallSeconds: probe["idleThresholdMs"]?.numberValue(coercingStrings: true, finiteOnly: false).map { $0 / 1000 },
            lastLiveness: liveness, now: now
        )
        let recordedStall = runStatus == "stalled" || runStatus == "failed_hung"
        let stalled = recordedStall || idleStalled
        let basis: DelegationReadout.StallBasis = recordedStall ? .recordedStall
            : idleBasis == .stallSeconds ? .rolloutIdle : idleBasis
        var recordedDeliveryStatus: String?
        var recordedDeliveryOutcome: String?
        if case .object(let delivery)? = job["delivery"] {
            recordedDeliveryStatus = string(delivery, "status")
            recordedDeliveryOutcome = string(delivery, "outcome")
        }
        let deliveryOutcome = recordedDeliveryOutcome ?? (undelivered ? "unknown" : nil)
        let recordedPhase = string(job, "phase")
        let effectiveState: String? = {
            guard terminal else { return recordedPhase }
            switch deliveryOutcome {
            case "delivered": return "settled"
            case "unknown": return "delivery_unknown"
            default:
                // Old records predate the explicit execution/delivery split. Their completedExecution is canonical terminal evidence, so never repeat the stale pre-terminal `watching_turn` label.
                return recordedPhase == "watching_turn" ? "execution_completed" : recordedPhase
            }
        }()

        var row = DelegationReadout(
            id: id,
            motorOwnerID: codexSoleMessageID(job),
            source: "codex",
            agent: "codex",
            topicSlug: codexTopicSlug(job),
            deskHandle: codexDeskHandle(job),
            state: effectiveState,
            status: recordedDeliveryStatus,
            runStatus: runStatus,
            createdAt: createdAt,
            claimedAt: claimedAt,
            startedAt: nil,  // codex records no runner start; boundAt is the closest
            lastLiveness: liveness,
            completedAt: completedAt,
            elapsedSeconds: elapsed,
            stalled: stalled,
            stallBasis: basis,
            // The codex record has NO deliveryLost field, and living under undelivered/ does not prove loss — it proves the bridge could not confirm the outcome. So `deliveryLost` stays nil and the disposition is reported as "unknown"
            // instead.
            deliveryLost: nil,
            deliveryOutcome: deliveryOutcome,
            completionTextHead: head(string(turnResult, "message") ?? string(turnResult, "lastAgentMessage")),
            producerSchemaVersion: codexProducerSchemaVersion(job),
            producerSourceRevision: codexProducerSourceRevision(job),
            stallDeadline: stallDeadline
        )
        row.recencyKey = firstDate(completedAt, watcherObservedAt, liveness, claimedAt, createdAt)
        row.watcherObservedAt = watcherObservedAt
        let evidence = terminal ? turnResult : probe
        row.toolActivityCount = int(evidence, "toolActivityCount")
        row.noWorkObserved = evidence["noWorkObserved"]?.boolValue
        if case .object(let recovery)? = turnResult["hangRecovery"] { row.recoveryStatus = string(recovery, "status") }
        row.executionError = Self.codexExecutionError(turnResult)
        row.recordKind = undelivered ? "retained_reply_job" : "reply_job"
        row.completionDeliveryID = id
        Self.retainReply(string(turnResult, "message") ?? string(turnResult, "lastAgentMessage"), truncated: false, in: &row)
        row.acceptedMessageIDs = Set(Self.codexPayloadValues(job, field: "messageId").compactMap { Self.recordedLookupID($0) })
        // A completed execution may belong to a later recovery turn. Keep its recorded pair together instead of mixing it with initial job IDs.
        let identity: [String: JSONValue]
        if case .object(let execution)? = job["completedExecution"] { identity = execution }
        else { identity = job }
        row.recordedThreadID = Self.recordedLookupID(identity["threadId"])
        row.recordedTurnID = Self.recordedLookupID(identity["turnId"])
        return row
    }

    /// Project the durable completion receipt that survives after a successful Codex reply job is unlinked. One delivery may batch several originating messages, so each message id receives the same proven terminal result; this preserves
    /// the exact identity emitted at dispatch time.
    static func projectCodexDeliveries(
        objects: [[String: JSONValue]]
    ) -> [DelegationReadout] {
        objects.flatMap { delivery -> [DelegationReadout] in
            guard case .array(let rawIDs)? = delivery["messageIds"] else { return [] }
            let ids = rawIDs.compactMap { value -> String? in
                guard case .string(let id) = value, !id.isEmpty else { return nil }
                return id
            }
            guard !ids.isEmpty else { return [] }

            var turnResult: [String: JSONValue] = [:]
            if case .object(let value)? = delivery["turnResult"] { turnResult = value }
            var bridge: [String: JSONValue] = [:]
            if case .object(let value)? = delivery["bridge"] { bridge = value }
            let runStatus = string(turnResult, "status")
            let completedAt = string(turnResult, "completedAt") ?? string(delivery, "createdAt") ?? string(delivery, "settledAt")
            let bridgeStatus = string(bridge, "status")
            let replyStatus = string(bridge, "replyStatus")
            // Older receipts have no explicit persistence flag, but retain the chat return and its separate notification settlement.
            var completionDelivery: [String: JSONValue] = [:]
            if case .object(let value)? = bridge["completionDelivery"] { completionDelivery = value }
            let persisted = bridge["replyPersisted"]?.boolValue == true
                || (string(bridge, "nativeAgentReplyPreview")?.isEmpty == false
                    && string(bridge, "nativeAgentSessionId") != nil
                    && string(bridge, "nativeAgentSessionId") == string(delivery, "sessionId")
                    && string(completionDelivery, "surface") != nil
                    && string(completionDelivery, "surface") != "caller-result")
            let outcome: String? = string(delivery, "settlement") ?? { switch (persisted, bridgeStatus, replyStatus) {
            case (true, _, _), (_, "delivered", _), (_, _, "ok"): "delivered"
            // A failed POST or notification proves neither transcript absence nor a delivery deadline. Keep uncertainty instead of minting loss.
            case (_, .some, _), (_, _, .some): "unknown"
            default: nil
            } }()
            let effectiveState: String = switch outcome {
            case "delivered": "settled"
            case "unknown": "delivery_unknown"
            default: outcome ?? "execution_completed"
            }
            let completion = string(bridge, "nativeAgentReplyPreview")
                ?? string(turnResult, "messagePreview") ?? string(turnResult, "message") ?? string(turnResult, "lastAgentMessage")
            return ids.map { id in
                var row = DelegationReadout(
                    id: id,
                    motorOwnerID: id,
                    source: "codex",
                    agent: "codex",
                    topicSlug: nil,
                    deskHandle: nil,
                    state: effectiveState,
                    status: bridgeStatus ?? replyStatus,
                    runStatus: runStatus,
                    createdAt: nil,
                    claimedAt: nil,
                    startedAt: nil,
                    lastLiveness: nil,
                    completedAt: completedAt,
                    elapsedSeconds: nil,
                    stalled: runStatus == "stalled" || runStatus == "failed_hung",
                    stallBasis: runStatus == "stalled" || runStatus == "failed_hung" ? .recordedStall : .terminal,
                    deliveryLost: nil,
                    deliveryOutcome: outcome,
                    completionTextHead: head(completion),
                    producerSchemaVersion: nil,
                    producerSourceRevision: nil,
                    stallDeadline: nil
                )
                row.recencyKey = date(completedAt)
                row.executionError = Self.codexExecutionError(turnResult)
                row.toolActivityCount = int(turnResult, "toolActivityCount")
                row.noWorkObserved = turnResult["noWorkObserved"]?.boolValue
                if case .object(let recovery)? = turnResult["hangRecovery"] { row.recoveryStatus = string(recovery, "status") }
                row.recordKind = "delivery_receipt"
                row.completionDeliveryID = string(delivery, "jobId")
                row.deliveryReceiptVersion = [string(delivery, "createdAt"),
                    string(delivery, "threadId"), string(delivery, "turnId"),
                    bridgeStatus, replyStatus, string(delivery, "settlement")].map { $0 ?? "" }.joined(separator: "|")
                if persisted, bridgeStatus != "delivered", replyStatus != "ok" {
                    row.deliveryReceiptVersion = (row.deliveryReceiptVersion ?? "") + "|reply_persisted"
                }
                row.agentReplyTextHead = head(string(turnResult, "messagePreview"))
                Self.retainReply(string(turnResult, "agentReplyText") ?? string(turnResult, "message")
                    ?? string(turnResult, "lastAgentMessage") ?? string(turnResult, "messagePreview"),
                    truncated: turnResult["agentReplyTruncated"]?.boolValue ?? (string(turnResult, "message") == nil && string(turnResult, "lastAgentMessage") == nil), in: &row)
                row.acceptedMessageIDs = Set([Self.recordedLookupID(.string(id))].compactMap { $0 })
                row.recordedThreadID = Self.recordedLookupID(delivery["threadId"])
                row.recordedTurnID = Self.recordedLookupID(delivery["turnId"])
                return row
            }
        }
    }

    // MARK: - OMP projection

    /// OMP keeps settled job records, like Claude, but writes the delivery result as a nested `bridge.status` and the topic inside `payload`.
    static func projectOMP(url: URL, now: Date, object job: [String: JSONValue]) -> DelegationReadout? {
        let id = string(job, "messageId") ?? url.deletingPathExtension().lastPathComponent
        let createdAt = string(job, "createdAt")
        let startedAt = string(job, "startedAt")
        let completedAt = string(job, "completedAt")
        let liveness = laterISO(string(job, "lastActivityAt"), string(job, "updatedAt"))
        let start = firstDate(startedAt, createdAt)
        let end = date(completedAt) ?? now
        let elapsed = start.map { Int(max(0, end.timeIntervalSince($0)).rounded()) }
        let state = string(job, "state")
        let status = string(job, "status")
        let terminal = completedAt != nil || state == "settled"
        let (stalled, basis, stallDeadline) = stallVerdict(
            terminal: terminal,
            deadlineAt: nil,
            stallSeconds: job["idleSeconds"]?.numberValue(coercingStrings: true, finiteOnly: false),
            lastLiveness: liveness ?? startedAt ?? createdAt,
            now: now
        )
        var payload: [String: JSONValue] = [:]
        if case .object(let value)? = job["payload"] { payload = value }
        var bridge: [String: JSONValue] = [:]
        if case .object(let value)? = job["bridge"] { bridge = value }
        let bridgeStatus = string(bridge, "status")
        // Decode historical combined verdicts only when the turn's own verdict is absent.
        let received = int(bridge, "httpStatus") == 200 && string(payload, "sessionId") != nil
            && string(bridge, "nativeAgentSessionId") == string(payload, "sessionId")
            && (string(bridge, "execution_result_class").map { $0 == "succeeded" }
                ?? ["ok", "delivery_failed_pre_dispatch", "delivery_rejected", "delivery_lifecycle_unavailable",
                    "delivery_in_progress", "outcome_unknown", "completion_already_settled"].contains(string(bridge, "replyStatus") ?? ""))
        let delivery: String? = switch (received, bridgeStatus) {
        // A dry run made no POST, regardless of other retained bridge fields.
        case (_, "dry_run"): "dry_run"
        case (true, _), (_, "delivered"): "delivered"
        case (_, "failed"): "lost"
        case (_, "unknown"): "unknown"
        case (_, "blocked"): "blocked"
        default: nil
        }
        let retained = string(job, "completionText")
            ?? string(job, "reply")
            ?? string(job, "stderrTail")
        var row = DelegationReadout(
            id: id,
            motorOwnerID: id,
            source: "omp",
            agent: "omp",
            topicSlug: string(payload, "topic").map(slug),
            deskHandle: string(payload, "deskHandle"),
            state: state,
            status: status,
            runStatus: status,
            createdAt: createdAt,
            claimedAt: nil,
            startedAt: startedAt,
            lastLiveness: liveness,
            completedAt: completedAt,
            elapsedSeconds: elapsed,
            stalled: stalled,
            stallBasis: basis,
            deliveryLost: delivery == "lost" ? true : nil,
            deliveryOutcome: delivery,
            completionTextHead: head(retained),
            producerSchemaVersion: int(payload, "producerSchemaVersion"),
            producerSourceRevision: string(payload, "producerSourceRevision"),
            stallDeadline: stallDeadline
        )
        row.recencyKey = firstDate(completedAt, liveness, startedAt, createdAt)
        row.completionDeliveryID = string(job, "deliveryId")
        if case .object(let onward)? = bridge["completionDelivery"] {
            row.onwardDelivery = .object(onward.filter { ["status", "reason", "surface", "delivery"].contains($0.key) })
        }
        Self.retainReply(string(job, "reply"), truncated: false, in: &row)
        row.acceptedMessageIDs = Set([Self.recordedLookupID(job["messageId"])].compactMap { $0 })
        // What was sent, and why a failed run failed (a provider's error, else the runner's reason).
        row.requestTextHead = head(string(payload, "text"))
        if status == "failed" { row.executionError = head(string(job, "assistantError") ?? string(job, "reason")) }
        if delivery == "blocked", string(bridge, "reason") == "missing_origin_session" {
            row.deliveryReason = "missing_origin_session"
        }
        return row
    }

    /// Delivery disposition uses only explicit `deliveryLost` and `bridgeStatus` fields.
    static func claudeDeliveryOutcome(_ job: [String: JSONValue]) -> String? {
        if job["deliveryLost"]?.boolValue == true { return "lost" }
        switch string(job, "bridgeStatus") {
        case "delivered": return "delivered"
        case "unknown": return "unknown"
        case "blocked": return "blocked"
        case .some(let other) where !other.isEmpty: return "unknown"
        default: return nil
        }
    }

    /// Mirrors `topicSlug()` in claude_thread_wakeup.js so a topic slugs identically on both sides. Returns nil — never the JS writer's "general" default — when the record carries no topic, because inventing a topic the record does not
    /// contain is fabrication.
    static func codexTopicSlug(_ job: [String: JSONValue]) -> String? {
        for value in codexPayloadValues(job, field: "topic") {
            guard case .string(let topic) = value else { continue }
            let trimmed = slug(topic)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// A reply job can batch entries. One exact originating id is safe to bind into a single motor projection; a mixed batch remains explicitly unbound until it is split by the terminal delivery ledger, which lists every message id
    /// separately.
    static func codexSoleMessageID(_ job: [String: JSONValue]) -> String? {
        let ids = Set(codexPayloadValues(job, field: "messageId").compactMap { value -> String? in
            guard case .string(let raw) = value, !raw.isEmpty else { return nil }
            return raw
        })
        return ids.count == 1 ? ids.first : nil
    }

    /// Preserve exact opaque IDs or omit them. Never clip one into a different handle, infer one from a filename/topic, or serialize the whole batch.
    private static func recordedLookupID(_ value: JSONValue?) -> String? {
        guard case .string(let id)? = value, !id.isEmpty, id.count <= 160 else { return nil }
        return id
    }

    /// A Codex reply job can batch several inbox entries. Bind it to a Desk item only when every bound entry names the same exact stable handle; mixed ownership is ambiguous and therefore stays unbound.
    static func codexDeskHandle(_ job: [String: JSONValue]) -> String? {
        let handles = Set(codexPayloadValues(job, field: "deskHandle").compactMap { value -> String? in
            guard case .string(let handle) = value, !handle.isEmpty else { return nil }
            return handle
        })
        return handles.count == 1 ? handles.first : nil
    }

    static func codexProducerSchemaVersion(_ job: [String: JSONValue]) -> Int? {
        codexPayloadValues(job, field: "producerSchemaVersion").compactMap { value in
            switch value {
            case .int(let raw): return Int(raw)
            case .double(let raw): return Int(exactly: raw.rounded(.towardZero))
            case .string(let raw): return Int(raw)
            default: return nil
            }
        }.max()
    }

    static func codexProducerSourceRevision(_ job: [String: JSONValue]) -> String? {
        let revisions: Set<String> = Set(codexPayloadValues(job, field: "producerSourceRevision").compactMap { value -> String? in
            guard case .string(let raw) = value, !raw.isEmpty else { return nil }
            return raw.lowercased()
        })
        return revisions.count == 1 ? revisions.first : nil
    }

    static func codexPayloadValues(_ job: [String: JSONValue], field: String) -> [JSONValue] {
        guard case .array(let entries)? = job["entries"] else { return [] }
        return entries.compactMap { entry in
            guard case .object(let object) = entry,
                  case .object(let payload)? = object["payload"] else { return nil }
            return payload[field]
        }
    }

    static func slug(_ topic: String) -> String {
        let value = String(topic.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(value.prefix(64))
    }

    /// The single place a stall verdict is made, for every store.
    static func stallVerdict(
        terminal: Bool,
        deadlineAt: String?,
        stallSeconds: Double?,
        lastLiveness: String?,
        now: Date
    ) -> (Bool, DelegationReadout.StallBasis, Date?) {
        if terminal { return (false, .terminal, nil) }
        if let deadline = date(deadlineAt) {
            return (now >= deadline, .deadline, deadline)
        }
        if let stallSeconds, stallSeconds > 0, let last = date(lastLiveness) {
            let deadline = last.addingTimeInterval(stallSeconds)
            return (now >= deadline, .stallSeconds, deadline)
        }
        return (false, .none, nil)
    }

    /// The helper retains provider failures even when no final reply exists. Surface only that terminal error, never the surrounding diagnostics or an inferred retry instruction. Absence remains absence of evidence.
    static func codexExecutionError(_ result: [String: JSONValue]) -> String? {
        guard let status = string(result, "status"),
              ["failed", "error", "timed_out", "timeout"].contains(status.lowercased()) else { return nil }
        let nested: String? = {
            guard case .object(let error)? = result["error"] else { return nil }
            return string(error, "message")
        }()
        guard let raw = string(result, "errorMessage") ?? string(result, "error") ?? nested else { return nil }
        return head(ChatSecretRedactor.redactText(raw))
    }

    static func head(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard longer(text, than: completionTextHeadLimit) else { return text }
        // Truncated heads prefer a word boundary and carry an ellipsis.
        var cut = text.prefix(completionTextHeadLimit - 1)
        if !text[cut.endIndex].isWhitespace, let space = cut.lastIndex(where: \.isWhitespace) {
            cut = cut[..<space]
        }
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// `text.count > limit` without counting a whole long reply's characters: every delivery row asks, and replies run to many kilobytes.
    static func longer(_ text: String, than limit: Int) -> Bool {
        text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex).map { $0 < text.endIndex } ?? false
    }

    static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s.isEmpty ? nil : s }
        return nil
    }

    static func nestedString(
        _ obj: [String: JSONValue], objectKey: String, field: String
    ) -> String? {
        guard case .object(let nested)? = obj[objectKey] else { return nil }
        return string(nested, field)
    }

    static func nestedInt(
        _ obj: [String: JSONValue], objectKey: String, field: String
    ) -> Int? {
        guard case .object(let nested)? = obj[objectKey] else { return nil }
        return int(nested, field)
    }

    static func int(_ obj: [String: JSONValue], _ key: String) -> Int? {
        switch obj[key] {
        case .some(.int(let value)): return Int(value)
        case .some(.double(let value)): return Int(exactly: value.rounded(.towardZero))
        case .some(.string(let value)): return Int(value)
        default: return nil
        }
    }

    /// Both writers emit `new Date().toISOString()` — fractional-second UTC. The no-fractional variant is the fallback so a hand-edited or older record still parses.
    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(iso)
    }

    static func laterISO(_ a: String?, _ b: String?) -> String? {
        switch (date(a), date(b)) {
        case let (x?, y?): return x >= y ? a : b
        case (_?, nil): return a
        case (nil, _?): return b
        case (nil, nil): return a ?? b
        }
    }

    static func retainReply(_ text: String?, truncated: Bool, in row: inout DelegationReadout) {
        guard let text, !text.isEmpty else { return }
        row.agentReplyText = String(text.prefix(6000))
        row.agentReplyTextHead = head(text)
        row.agentReplyTruncated = truncated || longer(text, than: 6000)
    }

    static func firstDate(_ candidates: String?...) -> Date? {
        for candidate in candidates {
            if let d = date(candidate) { return d }
        }
        return nil
    }
}
