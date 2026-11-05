import AuthoredCapabilities
import AgentConversations
import AgentWorkspace
import ChatSessionWork
import ChatTurnContracts
import Experiences
import ProviderRouting
import Foundation
import NativeAgentShared
import CryptoKit
import ToolRegistry
import ToolExecution
import MacControl
import NativeAgentCore
import PersistenceCore
import TurnTrace
import TrustCenter
import ChromeControl
import Senses
import StandingBots
import ChatToolParsing
// Blueprint: | `ChatToolDispatchTrace.swift` | `ChatToolDispatchTracer`, `isPreview`: Preserve redacted failure evidence. |

/// TurnTrace owns bound dispatches; standalone events keep recent_trace_summary aware of tool activity. Trace outside the gates so refusals are recorded too.
/// Turn previews obey local redaction policy; recorded details are unencrypted. Diagnostic trace failures must not change dispatch outcomes.
package final class ChatToolDispatchTracer: ToolDispatchClient, @unchecked Sendable {
    /// An owned no met inside a call surfaces with the call's own failure: a batch or part that fails without an owner of its own owes its steps'.
    struct OwedNo: Sendable { let operation, owner: String; let lever, nextCall, tap: String? }
    final class SurfacedNos: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [OwedNo] = []
        let parent: SurfacedNos?
        init(parent: SurfacedNos?) { self.parent = parent }
        func add(_ more: [OwedNo]) { lock.withLock { items += more } }
        var all: [OwedNo] { lock.withLock { items } }
        /// A later success of the operation or its lever answers an earlier no, at every level.
        func worked(_ operation: String) {
            lock.withLock { items.removeAll { $0.operation == operation || $0.lever == operation } }
            parent?.worked(operation)
        }
    }

    private let inner: any ToolDispatchClient
    private let dataRoot: URL

    package init(
        inner: any ToolDispatchClient,
        dataRoot: URL
    ) {
        self.inner = inner
        self.dataRoot = dataRoot
    }

    /// One dispatch predicate for both recording and the turn's learning readers.
    package static func isPreview(tool: String, input: [String: JSONValue]) -> Bool {
        tool == "app" && input["preview"] == .bool(true)
    }

    package func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        if Self.isPreview(tool: tool, input: input) {
            // Keep the real gated chain. The preview owner records its inert trace; dispatch/act evidence would otherwise feed the agent's body, habits and
            // next dream as though the agent had performed the work.
            return try await inner.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let receiptID = UUID().uuidString.lowercased()
        let parent = turn.act
        let enclosing = invocation.surfacedNos, inside = SurfacedNos(parent: enclosing)
        // The begin event lets Inspector show an in-flight dispatch.
        Self.fireBusEvent(turn: turn,
            tool: tool, input: input, surface: surface,
            phase: "begin", status: "running", durationMs: nil, result: nil,
            evidence: Self.dispatchEvidence(turn: turn, tool: tool, input: input, status: "running", result: nil, receiptID: receiptID),
            parent: parent
        )
        let result: JSONValue
        do {
            result = ChatToolOutcome.normalizedFailure(try await inner.dispatch(
                tool: tool, input: input, surface: surface, turn: turn.with(\.act, receiptID),
                invocation: invocation.with(\.surfacedNos, inside)), tool: tool,
                throughAppDoor: invocation.appDoor != nil)
        } catch {
            let failure = ChatToolOutcome.failure(error: error, tool: tool)
            let reply = ToolResult(failure)
            let verdict = reply.outcome
            let evidence = Self.dispatchEvidence(turn: turn, tool: tool, input: input, status: "failed", result: failure, receiptID: receiptID,
                verdict: verdict)
            await recordCompletion(turn: turn,
                tool: tool, input: input, surface: surface,
                status: "failed", startNs: startNs,
                receiptID: receiptID, evidence: evidence,
                result: failure, verdict: verdict, parent: parent, nos: (inside, enclosing),
                errorClass: "dispatch_threw",
                errorDetail: ChatToolOutcome.failureDetail(error: error)
            )
            throw error
        }
        let reply = ToolResult(result)
        let verdict = reply.outcome
        let ok = ChatToolOutcome.outputLooksSuccessful(result, verdict: verdict)
        // An unanswered approval card is waiting, never a failed dispatch.
        let waiting = ChatToolOutcome.isWaitingOnPerson(result, verdict: verdict)
        let status = waiting ? "waiting" : ChatToolOutcome.statusWord(result, verdict: verdict)
        let failureShaped = !ok && !waiting
        let evidence = Self.dispatchEvidence(turn: turn, tool: tool, input: input, status: status, result: result, receiptID: receiptID, verdict: verdict)
        await recordCompletion(turn: turn,
            tool: tool, input: input, surface: surface,
            status: status, startNs: startNs,
            receiptID: receiptID, evidence: evidence,
            result: result, verdict: verdict, parent: parent, nos: (inside, enclosing),
            errorClass: failureShaped ? ChatToolOutcome.receiptFailureClass(result, verdict: verdict) : nil,
            // Only failure-shaped envelopes contribute failure evidence; waiting and success cannot create debts.
            errorDetail: failureShaped ? ChatToolOutcome.failureDetail(result) : nil
        )
        guard case .object(var output) = reply.payload else { return reply.payload }
        output["dispatch_receipt_id"] = .string(receiptID)
        output["dispatch_receipt_source"] = .string("detail")
        return .object(output)
    }

    /// Calls refused without dispatch still belong to model activity and need failure traces.
    package static func traceUndispatched(turn: Turn, tool: String, input: [String: JSONValue], surface: String, result: JSONValue) {
        fireBusEvent(turn: turn, tool: tool, input: input, surface: surface, phase: "end", status: "failed", durationMs: nil, result: result,
                     evidence: dispatchEvidence(turn: turn, tool: tool, input: input, status: "failed", result: result,
                                                receiptID: UUID().uuidString.lowercased()),
                     parent: nil)
    }

    private static func fireBusEvent(turn: Turn,
        tool: String,
        input: [String: JSONValue],
        surface: String,
        phase: String,
        status: String,
        durationMs: Int?,
        result: JSONValue?,
        evidence: [String: JSONValue],
        parent: String?,
        recordedAt: Date = Date()
    ) {
        guard let turnId = TurnTraceContext.turnId else { return }
        var payload: [String: JSONValue] = [
            "name": .string(tool),
            "phase": .string(phase),
            "status": .string(status),
            "receipt": .object(evidence),
            "argKeys": .array(input.keys.sorted().map { .string($0) }),
            // Redact injections before bounding; short secrets fit in a preview.
            "args": .string(Self.truncatePreview(
                .object(MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn))
            )),
        ]
        if let durationMs { payload["durationMs"] = .int(Int64(durationMs)) }
        if let parent { payload["parentId"] = .string(parent) }
        if let origin = TurnTraceContext.automaticOrigin { payload["automaticOrigin"] = .string(origin) }
        let shown = ToolNameAliases.shown(tool, input: .object(input)).name
        if shown != tool { payload["shown"] = .string(shown) }
        if tool == "act", case .object(let reply)? = result, case .object(let detail)? = reply["detail"],
           let changed = detail["owner_front_changed"] {
            payload["user_front_changed"] = changed
        }
        if let result {
            if status == "failed" {
                payload.merge(Self.failureFields(result)) { _, field in field }
                payload["errorDetail"] = ChatToolOutcome.failureDetail(result).map(JSONValue.string)
            }
            // Redact echoed injections and screen pixels as the tool that ran.
            let ran = ToolNameAliases.ranTool(tool, input: input)
            payload["result"] = .string(Self.truncatePreview(
                MacInjectionResultRedaction.redacted(
                    tool: ran,
                    result: MacScreenViewResultRedaction.redacted(tool: ran, result: result),
                    turn: turn
                )
            ))
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId, ts: recordedAt, kind: "tool.dispatch",
            sessionId: traceSessionID(turn: turn, input), surface: surface, payload: .object(payload), turn: turn
        ), on: TurnTraceContext.bus ?? .shared)
        // Emit redacted file.touch paths only after successful file-tool dispatches.
        if phase == "end", status == "ok" {
            Self.fireFileTouchEvent(turn: turn, tool: tool, input: input, surface: surface, status: status)
        }
    }

    private static let fileToolModes: [String: String] = [
        "read_file": "read",
        "file_excerpt": "read",
        "list_dir": "read",
        "list_directory": "read",
        "grep": "read",
        "git_status": "read",
        "git_diff": "read",
        "git_log": "read",
        "repo_dirty_summary": "read",
        "write_file": "write",
        "move_file": "write",
        "copy_file": "write",
        "file_write": "write",
        "apply_patch": "write",
    ]

    /// Extract path arguments only; apply_patch body paths are deliberately not parsed, so patch evidence records write mode with an empty paths array.
    private static let pathArgKeys: [String] = ["path", "destination", "dir", "directory", "file", "filepath", "file_path"]

    private static func fireFileTouchEvent(turn: Turn,
        tool: String,
        input: [String: JSONValue],
        surface: String,
        status: String
    ) {
        guard TurnTraceContext.turnId != nil else { return }
        guard let mode = fileToolModes[tool] else { return }
        var paths: [String] = []
        for key in pathArgKeys {
            if case .string(let p)? = input[key], !p.isEmpty {
                // Redact secrets before preview bounds can split credential-bearing paths or URLs.
                paths.append(ChatSecretRedactor.redactText(p))
            }
        }
        var payload: [String: JSONValue] = [
            "tool": .string(tool),
            "mode": .string(mode),
            "status": .string(status),
            "paths": .array(paths.map { .string($0) }),
        ]
        payload["pathCount"] = .int(Int64(paths.count))
        TurnTraceBus.fireFromContext(
            kind: "file.touch",
            sessionId: traceSessionID(turn: turn, input),
            surface: surface,
            payload: .object(payload),
            turn: turn
        )
    }

    private static func traceSessionID(turn: Turn, _ input: [String: JSONValue]) -> String? {
        let sessionID = ChatToolSessionInjection.explicitSessionId(in: input)
        return sessionID.isEmpty ? turn.session : sessionID
    }

    /// Select failure evidence before preview clipping. Keep the result's status separately from the dispatch verdict. Redact whole fields before bounding: a
    /// secret may otherwise be cut in half and evade redaction.
    private static func failureFields(_ result: JSONValue) -> [String: JSONValue] {
        guard case .object(let object) = result else { return [:] }
        var fields: [String: JSONValue] = [:]
        for key in ["status", "failure_code", "code", "reason", "argument_path", "error", "detail", "message"] {
            guard let original = object[key] else { continue }
            let value = TurnTraceRedactor.redactValue(original)
            let target = key == "status" ? "result_status" : key
            switch value {
            case .null, .bool, .int, .double: fields[target] = value
            default:
                let raw: String?
                if case .string(let text) = value { raw = text }
                else { raw = try? value.serialize(pretty: false) }
                guard let raw else { continue }
                let redacted = ChatSecretRedactor.redactText(raw)
                fields[target] = .string(redacted.count <= 300 ? redacted : String(redacted.prefix(299)) + "…")
            }
        }
        return fields
    }

    private static func dispatchEvidence(turn: Turn,
        tool: String, input: [String: JSONValue], status: String, result: JSONValue?, receiptID: String, verdict: ChatToolOutcome.ExactResultClass? = nil
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(receiptID),
            "source": .string("detail"),
            "action": .string(ToolNameAliases.appAction(tool) ?? tool),
            "preview": .bool(input["preview"] == .bool(true)),
            "status": .string(status),
        ]
        if case .string(let action)? = input["action"] {
            fields["action"] = .string(ChatSecretRedactor.redactText(String(action.prefix(512))))
        }
        fields["model"] = (turn.admission?.model).map(JSONValue.string)
        fields["reasoningEffort"] = (turn.admission?.reasoningEffort).map(JSONValue.string)
        if let result {
            let reply = ToolResult(result)
            if status == "failed" { fields.merge(failureFields(result)) { _, field in field } }
            let preview = if case .object(let object) = result { (reply.said("preview") && reply.status == object["status"]?.stringValue)
                || object["execution"] == .string("preview") } else { false }
            fields["resultClass"] = .string(preview ? "preview" : (verdict ?? reply.outcome).rawValue)
            let evidence = receiptFields(result)
            fields["resultReceipt"] = (try? evidence.serializedData(pretty: false).count).map { $0 <= 6_144 } == true
                ? evidence : .object(["_truncated": .bool(true)])
            if let data = try? TurnTraceRedactor.redactValue(result).serializedData(pretty: false) {
                fields["resultDigest"] = .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
        }
        return fields
    }

    // Select evidence before preview truncation; keep worker routing and outcome trees without retaining their prompts or answers.
    private static func receiptFields(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var fields: [String: JSONValue] = [:]
            for key in ["id", "receipt_id", "run_id", "runId", "job_id", "message_id", "session_id", "handle",
                        "status", "outcome", "final_status", "preview", "effects", "execution", "read_only", "skill", "would_card", "approver",
                            "preview_scope", "verified", "verification",
                        "exit_code", "timed_out",
                        "result_handle", "result_ref", "read_ref", "digest", "sha256", "has_more", "next", "runsPath", "report_id", "index",
                        "model", "model_id", "reasoning_effort", "reasoningEffort", "provider"] {
                guard let field = object[key] else { continue }
                switch field {
                case .string(let text) where text.utf8.count <= 512:
                    fields[key] = .string(ChatSecretRedactor.redactText(text))
                case .bool, .int, .double, .null: fields[key] = field
                default: break
                }
            }
            if case .array(let checks)? = object["checks_not_run"] {
                fields["checks_not_run"] = .array(checks.prefix(8).compactMap { check in
                    guard case .string(let text) = check else { return nil }
                    return .string(ChatSecretRedactor.redactText(String(text.prefix(160))))
                })
                if checks.count > 8 { fields["checks_not_run_omitted"] = .int(Int64(checks.count - 8)) }
            }
            for key in ["execution", "receipt", "detail", "workers", "results", "outputs", "agents", "routing", "synthesis", "next"] {
                if let field = object[key], case .object = field { fields[key] = receiptFields(field) }
                else if let field = object[key], case .array = field { fields[key] = receiptFields(field) }
            }
            return .object(fields)
        case .array(let values): return .array(values.map(receiptFields))
        default: return .null
        }
    }

    /// Redact before applying the 500-character preview cap; serialization failure remains explicit.
    private static func truncatePreview(_ value: JSONValue) -> String {
        let limit = 500
        let reply = ToolResult(value)
        var value = value
        if case .object(let fields) = value, reply.said("preview"), reply.status == fields["status"]?.stringValue {
            var compact = fields.filter { ["status", "effects", "execution", "would_card", "approver", "preview_scope"].contains($0.key) }
            if case .array(let checks)? = fields["checks_not_run"] {
                compact["checks_not_run"] = .array(checks.prefix(2).compactMap { check in
                    if case .string(let text) = check { .string(String(text.prefix(40))) } else { nil }
                })
                if checks.count > 2 { compact["checks_not_run_omitted"] = .int(Int64(checks.count - 2)) }
            }
            value = .object(compact)
        }
        let raw: String
        if let data = try? TurnTraceRedactor.redactValue(value).serializedData(pretty: false),
           let s = String(data: data, encoding: .utf8) {
            raw = ChatSecretRedactor.redactText(s)
        } else {
            raw = "[unserializable]"
        }
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit)) + "…[+\(raw.count - limit) chars]"
    }

    package func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await inner.listAvailableTools(turn: turn, surface: surface)
    }

    package func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }

    package func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(turn: turn, surface: surface)
    }

    private func recordCompletion(turn: Turn,
        tool: String,
        input: [String: JSONValue],
        surface: String,
        status: String,
        startNs: UInt64,
        receiptID: String,
        evidence: [String: JSONValue],
        result: JSONValue,
        verdict: ChatToolOutcome.ExactResultClass,
        parent: String?,
        nos: (inside: SurfacedNos, enclosing: SurfacedNos?),
        errorClass: String? = nil,
        errorDetail: String? = nil
    ) async {
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        let recordedAt = Date()
        let argKeys = input.keys.sorted()
        let risk = SwiftNativeSecurityCenter.canonicalToolRisk(
            tool: tool,
            input: input,
            dataRoot: dataRoot,
            turn: turn
        )
        let projected = evidence["resultClass"] == .string("preview") ? ChatToolOutcome.ExactResultClass.unknown : verdict
        let ok = projected == .succeeded
        let waiting = status == "waiting"
        var receiptEvidence: [String: JSONValue] = [
            "action": .string("tool_dispatch"),
            "surface": .string(surface),
            "target": .string(tool),
            "decision": .string("attempted"),
            "outcome": .string(ok ? "completed" : (waiting ? "waiting" : projected.rawValue)),
            "reason": .string(ok ? "tool dispatch completed" : (waiting ? "waiting on you" : "tool dispatch \(projected.rawValue)")),
            "changedFields": .array([]),
            "proof": .array([
                "detail:tool.dispatch:\(receiptID)",
                "status:\(status)",
                "duration_ms:\(durationMs)",
                "arg_key_count:\(argKeys.count)",
                // Retention proves recording here, not an effect's permanence.
                "permanence_source:detail_retention",
                "risk_source:security_center.canonical_tool_risk",
            ].map(JSONValue.string)),
            "permanence": .string("bounded_trace"),
            "risk": .string(risk.rawValue),
        ]
        // Failure text is already bounded and redacted; absent errors omit their keys.
        if !ok && !waiting {
            if let errorClass, !errorClass.isEmpty { receiptEvidence["errorClass"] = .string(errorClass) }
            if let errorDetail, !errorDetail.isEmpty { receiptEvidence["errorDetail"] = .string(errorDetail) }
        }
        receiptEvidence.merge(evidence) { _, evidence in evidence }
        receiptEvidence["source"] = .string("detail")
        Self.fireBusEvent(turn: turn,
            tool: tool, input: input, surface: surface, phase: "end",
            status: status, durationMs: durationMs, result: result,
            evidence: receiptEvidence, parent: parent, recordedAt: recordedAt
        )
        // The act is the turn's, or its enclosing call's; its receipt is the evidence. A preview's only receipt is the trace just emitted. Experience and
        // repair readers must never turn a proposed act into the agent's life.
        guard !Self.isPreview(tool: tool, input: input) else { return }
        guard case .string(let action)? = evidence["action"] else { return }
        let reply = ToolResult(result)
        let effects = reply.effects.flatMap { Experience.Effects(rawValue: $0.rawValue) }
        var act = Experience(id: receiptID, kind: .act, cause: [parent ?? turn.id],
                             evidence: [.init(source: "detail", id: receiptID)],
                             outcome: .init(domain: action, status: status, effects: effects))
        // Repair is owed until the operation works or the agent lets it go.
        let remedy = reply.remedy
        let operation = ChatToolOutcome.repairOperation(action, input)
        let refusedBeforeEffect: Bool = if effects == Experience.Effects.none, case .object(let fields) = result {
            ChatToolOutcome.neverRan(result) || verdict == .refused
                || fields["execution"] == .string("not_run") || fields["not_run_status"] != nil
                || fields["argument_path"] != nil && fields["argument_path"] != .null
                || (reply.status == fields["status"]?.stringValue
                    && ["invalid_arguments", "unknown_contact", "not_run"].contains(where: { reply.said($0) }))
        } else { false }
        // A refused probe changed nothing. Keep its act as evidence, but do not invent an obligation for the call it never made.
        let probeOnly = action == "agent.verify" && effects == Experience.Effects.none
        var own: OwedNo?
        if !refusedBeforeEffect, !probeOnly, case .object(let fix)? = remedy, fix["kind"] == .string("repair"), case .string(let owner)? = fix["owner"] {
            let tap: String? = if case .string(let tap)? = fix["tap"] { tap } else { nil }
            let call = fix["next_call"].flatMap { $0 == .null ? nil : try? $0.serialize(pretty: false) }
            let lever: String?
            do { lever = try ChatToolOutcome.leverOperation(remedy, turn: turn) }
            catch {
                lever = nil
                TurnTraceBus.fireFromContext(kind: "repair.lever_unavailable", payload: .object([
                    "operation": .string(operation), "owner": .string(owner), "failure": .string(error.localizedDescription),
                    "detail": .string("The original repair remains owed. Repair the action catalog before binding its settling operation.")]), turn: turn)
            }
            own = OwedNo(operation: operation, owner: owner, lever: lever,
                         nextCall: call.map(ChatSecretRedactor.redactText), tap: tap)
        }
        // A no inside a call is owed by the call that surfaced it; a call that failed with no owner of its own surfaces its steps' owned nos.
        let surfaced = refusedBeforeEffect || probeOnly ? [] : own.map { [$0] } ?? (status == "failed" ? nos.inside.all : [])
        // A preview shows what a call would do; it proves nothing works.
        let worked = status == "ok" && input["preview"] != .bool(true)
        if parent != nil {
            if status == "failed" { nos.enclosing?.add(surfaced) } else if worked { nos.enclosing?.worked(operation) }
        } else if let own {
            act.owes["repair"] = .init(to: own.tap == nil ? "self" : "person")
            act.claims = RepairDebt(owner: own.owner, operation: own.operation, lever: own.lever,
                                    nextCall: own.nextCall, tap: own.tap).claims
        } else {
            for (index, no) in surfaced.enumerated() {
                RepairOwed.owe(dataRoot, id: receiptID + ":" + String(index), kind: .act, cause: [receiptID],
                               evidence: [.init(source: "detail", id: receiptID)], operation: no.operation,
                               owner: no.owner, words: errorDetail ?? "", lever: no.lever, nextCall: no.nextCall, tap: no.tap)
            }
        }
        // Debts and settlements of one operation share its queue, so neither overtakes the other.
        let queue = act.owes["repair"] != nil || worked ? "repair:" + operation : receiptID
        ExperienceStore.record(dataRoot, queue) { [act] store in
            var act = act
            // A repeat of a debt still open is evidence on it, not a second line.
            if act.owes["repair"] != nil, let owner = RepairDebt(act).owner,
               let open = try await RepairOwed.openDebt(store, operation: operation, owner: owner) {
                act.owes["repair"] = nil
                try await store.begin(act)
                try await store.append([.evidence(.init(source: "act", id: receiptID))], to: open.id)
                return
            }
            try await store.begin(act)
            if worked { try await RepairOwed.settle(store, operation: operation, evidence: .init(source: "act", id: receiptID)) }
        }
        await recordStandaloneTrace(turn: turn, tool: tool, surface: surface, status: status, argKeys: argKeys,
            durationMs: durationMs, receiptID: receiptID, receiptEvidence: receiptEvidence, result: result, recordedAt: recordedAt)
    }

    private func recordStandaloneTrace(turn: Turn, tool: String, surface: String, status: String, argKeys: [String],
        durationMs: Int, receiptID: String, receiptEvidence: [String: JSONValue], result: JSONValue, recordedAt: Date) async {
        guard TurnTraceContext.turnId == nil else { return }
        var payload: [String: JSONValue] = [
            "name": .string(tool),
            "phase": .string("end"),
            "status": .string(status),
            "argKeys": .array(argKeys.map { .string($0) }),
            "durationMs": .int(Int64(durationMs)),
            "surface": .string(surface),
            "turnId": .string(turn.id),
            "receipt": .object(receiptEvidence),
        ]
        if status == "failed" { payload.merge(Self.failureFields(result)) { _, field in field } }
        let event = TurnTraceEvent(kind: "tool.dispatch", title: tool, status: status,
            // Keep argument and result bodies out of compact repair evidence.
            payload: .object(payload), id: receiptID, createdAt: NativeTimestampFormat.plainZulu(recordedAt), ts: recordedAt,
            turnId: turn.id, sessionId: turn.session, surface: surface, turn: turn)
        await TurnTracePersistLane(dataRootOverride: dataRoot).append(event)
    }
}
