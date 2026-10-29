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
// Blueprint: | `ChatToolDispatchTrace.swift` | `ChatToolDispatchTracer`: dispatch timing, redacted receipts and file-touch evidence; turn-bound receipts record act experience and repair attribution; nominated practice calls keep one redacted tape row with exact paths, steer and call-end sequence, built off the dispatch path (`TurnPractice`), every other call none |

/// Trace-recording ToolDispatchClient. TurnTrace owns bound dispatches;
/// `<dataRoot>/traces/events.jsonl` owns standalone dispatches:
/// success, failure-shaped envelope, and thrown error. This keeps
/// `recent_trace_summary` aware of the assistant's own tool activity.
///
/// Wraps the gated chain OUTERMOST (above AutonomyGatedDispatcher /
/// FileAccessGatedDispatcher) so gate denials — which throw before the inner
/// dispatcher runs — still land as status:"failed" rows.
///
/// Standalone receipts are compact; turn events retain argument/result previews
/// under TurnTraceRedactor's local trace policy. Trace files are unencrypted.
///
/// Tracing failures are diagnostic; the dispatch result reaches the tool loop unchanged.
///
/// Standalone rows retain {id, kind, title, status, payload, createdAt}.
package final class ChatToolDispatchTracer: ToolDispatchClient, @unchecked Sendable {
    /// An owned no met inside a call surfaces with the call's own failure: a
    /// batch or part that fails without an owner of its own owes its steps'.
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
    @TaskLocal static var surfacedNos: SurfacedNos?

    private let inner: any ToolDispatchClient
    private let dataRoot: URL

    package init(
        inner: any ToolDispatchClient,
        dataRoot: URL
    ) {
        self.inner = inner
        self.dataRoot = dataRoot
    }

    package func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let receiptID = UUID().uuidString.lowercased()
        let parent = Experience.currentAct
        let enclosing = Self.surfacedNos, inside = SurfacedNos(parent: enclosing)
        // The begin event lets Inspector show an in-flight dispatch.
        Self.fireBusEvent(
            tool: tool, input: input, surface: surface,
            phase: "begin", status: "running", durationMs: nil, result: nil,
            evidence: Self.dispatchEvidence(tool: tool, input: input, status: "running", result: nil, receiptID: receiptID),
            parent: parent
        )
        let result: JSONValue
        do {
            // The turn this call belongs to, for her windows to step aside for it.
            let driver = ChatToolSessionContext.verifiedSessionId.flatMap { session in
                TurnTraceContext.turnId.map { PersonOnlyWindows.Driver(session: session, turn: $0) }
            }
            result = ChatToolOutcome.normalizedFailure(try await Experience.$currentAct.withValue(receiptID) {
                try await Self.$surfacedNos.withValue(inside) {
                    try await PersonOnlyWindows.$driver.withValue(driver) {
                        try await inner.dispatch(tool: tool, input: input, surface: surface)
                    }
                }
            }, tool: tool)
        } catch {
            let failure = ChatToolOutcome.failure(error: error, tool: tool)
            let verdict = ChatToolOutcome.exactResultClass(failure)
            let evidence = Self.dispatchEvidence(tool: tool, input: input, status: "failed", result: failure, receiptID: receiptID, verdict: verdict)
            await recordCompletion(
                tool: tool, input: input, surface: surface,
                status: "failed", startNs: startNs,
                receiptID: receiptID, evidence: evidence,
                result: failure, verdict: verdict, parent: parent, nos: (inside, enclosing),
                errorClass: "dispatch_threw",
                errorDetail: ChatToolOutcome.failureDetail(error: error)
            )
            throw error
        }
        let verdict = ChatToolOutcome.exactResultClass(result)
        let ok = ChatToolOutcome.outputLooksSuccessful(result, verdict: verdict)
        // An unanswered approval card is waiting, never a failed dispatch.
        let waiting = ChatToolOutcome.isWaitingOnPerson(result, verdict: verdict)
        let status = waiting ? "waiting" : ChatToolOutcome.statusWord(result, verdict: verdict)
        let failureShaped = !ok && !waiting
        let evidence = Self.dispatchEvidence(tool: tool, input: input, status: status, result: result, receiptID: receiptID, verdict: verdict)
        await recordCompletion(
            tool: tool, input: input, surface: surface,
            status: status, startNs: startNs,
            receiptID: receiptID, evidence: evidence,
            result: result, verdict: verdict, parent: parent, nos: (inside, enclosing),
            errorClass: failureShaped ? ChatToolOutcome.receiptFailureClass(result, verdict: verdict) : nil,
            // Failure-shaped envelope only: an ok or waiting row carries none.
            errorDetail: failureShaped ? ChatToolOutcome.failureDetail(result) : nil
        )
        return result
    }

    /// A call the loop answered without dispatching it (not offered, held):
    /// still one the model made, so it is traced as one that failed.
    package static func traceUndispatched(tool: String, input: [String: JSONValue], surface: String, result: JSONValue) {
        fireBusEvent(tool: tool, input: input, surface: surface, phase: "end", status: "failed", durationMs: nil, result: result,
                     evidence: dispatchEvidence(tool: tool, input: input, status: "failed", result: result,
                                                receiptID: UUID().uuidString.lowercased()),
                     parent: nil)
    }

    /// Emit dispatch evidence and redacted previews through the turn owner.
    private static func fireBusEvent(
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
                .object(MacInjectionArgRedaction.redacted(tool: tool, input: input))
            )),
        ]
        if let durationMs { payload["durationMs"] = .int(Int64(durationMs)) }
        if let parent { payload["parentId"] = .string(parent) }
        if let origin = TurnTraceContext.automaticOrigin { payload["automaticOrigin"] = .string(origin) }
        // An app call as a person is shown it: the action it ran.
        let shown = ToolNameAliases.shown(tool, input: .object(input)).name
        if shown != tool { payload["shown"] = .string(shown) }
        // Record whether the action changed the person's front window.
        if tool == "act", case .object(let reply)? = result, case .object(let detail)? = reply["detail"],
           let changed = detail["owner_front_changed"] {
            payload["user_front_changed"] = changed
        }
        if let result {
            if status == "failed", case .object(let failure) = result {
                // Failure fields bypass the serialized preview, so apply its
                // secret redactor here too, before emission.
                if case .string(let reason)? = failure["reason"] {
                    payload["reason"] = .string(ChatSecretRedactor.redactText(reason))
                }
                payload["errorDetail"] = ChatToolOutcome.failureDetail(result).map(JSONValue.string)
            }
            // Redact echoed injections and screen pixels as the tool that ran.
            let ran = ToolNameAliases.ranTool(tool, input: input)
            payload["result"] = .string(Self.truncatePreview(
                MacInjectionResultRedaction.redacted(
                    tool: ran,
                    result: MacScreenViewResultRedaction.redacted(tool: ran, result: result)
                )
            ))
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId, ts: recordedAt, kind: "tool.dispatch",
            sessionId: traceSessionID(input), surface: surface, payload: .object(payload)
        ), on: TurnTraceContext.bus ?? .shared)
        // Emit redacted file.touch paths only after successful file-tool dispatches.
        if phase == "end", status == "ok" {
            Self.fireFileTouchEvent(tool: tool, input: input, surface: surface, status: status)
        }
    }

    /// Read/write evidence classifications for recognized file-tool dispatch names.
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

    /// Extract path arguments only; apply_patch body paths are deliberately not parsed,
    /// so patch evidence records write mode with an empty paths array.
    private static let pathArgKeys: [String] = ["path", "destination", "dir", "directory", "file", "filepath", "file_path"]

    private static func fireFileTouchEvent(
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
                // Redact BEFORE bounding (TurnTraceEvent bounds leaves; this
                // adds the secret-scrub half). A path is rarely a secret but a
                // signed URL / token-bearing path would be caught.
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
            sessionId: traceSessionID(input),
            surface: surface,
            payload: .object(payload)
        )
    }

    /// A turn's own call of an operation that a nominated practice of this
    /// agent uses keeps one tape row (`TurnPractice.TapeRow`); every other
    /// call keeps none. Redacted as its trace preview is, the row keeps what
    /// redaction left unchanged within its bound, path by path, and names
    /// what it left out. Its steer is the provenance an `ability.save` in
    /// this turn would carry. Built off the dispatch path.
    private static func keepPractice(tool: String, input: [String: JSONValue], surface: String, receiptID: String, turn: String,
                                     evidence: [String: JSONValue], result: JSONValue, dataRoot: URL, at: Date) {
        let action: String? = if case .string(let text)? = input["action"] { text } else { nil }
        guard let operation = TurnPractice.operation(tool: tool, keys: Set(input.keys), action: action) else { return }
        let principal = TurnPractice.principal(helper: BotDefinition.id(forSession: traceSessionID(input)))
        guard TurnPractice.records(operation, principal: principal, dataRoot: dataRoot) else { return }
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        let resultClass: String = if case .string(let text)? = evidence["resultClass"] { text } else { "unknown" }
        let model: String? = if case .string(let text)? = evidence["model"] { text } else { nil }
        // The call's place is taken here, as it ends; its row is built off the path.
        let sequence = TurnPractice.nextSequence()
        Task.detached(priority: .utility) {
            let ran = ToolNameAliases.ranTool(tool, input: input)
            let redactedArgs = TurnTraceRedactor.redactValue(
                TurnPractice.arguments(operation, input: MacInjectionArgRedaction.redacted(tool: tool, input: input)))
            let redactedResult = TurnTraceRedactor.redactValue(
                MacInjectionResultRedaction.redacted(tool: ran, result: MacScreenViewResultRedaction.redacted(tool: ran, result: result)))
            let row = TurnPractice.TapeRow(receipt: receiptID, turn: turn, operation: operation, resultClass: resultClass,
                args: TurnPractice.arguments(operation, input: input), redactedArgs: redactedArgs,
                options: TurnPractice.options(input), redactedOptions: TurnTraceRedactor.redactValue(
                    TurnPractice.options(MacInjectionArgRedaction.redacted(tool: tool, input: input))),
                result: result, redactedResult: redactedResult,
                steer: steer.sources + steer.elevated, model: model, at: at, sequence: sequence)
            await TurnPractice.Tape.shared.append(row, principal: principal, dataRoot: dataRoot)
        }
    }

    private static func traceSessionID(_ input: [String: JSONValue]) -> String? {
        let sessionID = ChatToolSessionInjection.explicitSessionId(in: input)
        return sessionID.isEmpty ? LLMCallContext.sessionId : sessionID
    }

    private static func traceSource(at date: Date = Date()) -> String {
        TurnTraceContext.turnId == nil ? "data/traces/events.jsonl"
            : "data/turn_traces/" + TurnTracePersistLane().path(for: date).lastPathComponent
    }

    private static func dispatchEvidence(
        tool: String, input: [String: JSONValue], status: String, result: JSONValue?, receiptID: String, verdict: ChatToolOutcome.ExactResultClass? = nil
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(receiptID),
            "source": .string(traceSource()),
            "action": .string(ToolNameAliases.appAction(tool) ?? tool),
            "preview": .bool(input["preview"] == .bool(true)),
            "status": .string(status),
        ]
        if case .string(let action)? = input["action"] {
            fields["action"] = .string(ChatSecretRedactor.redactText(String(action.prefix(512))))
        }
        fields["model"] = LLMCallContext.admittedModel.map(JSONValue.string)
        fields["reasoningEffort"] = LLMCallContext.reasoningEffort.map(JSONValue.string)
        if let result {
            let preview = if case .object(let object) = result { object["status"] == .string("preview") || object["execution"] == .string("preview") } else { false }
            fields["resultClass"] = .string(preview ? "preview" : (verdict ?? ChatToolOutcome.exactResultClass(result)).rawValue)
            let evidence = receiptFields(result)
            fields["resultReceipt"] = (try? evidence.serializedData(pretty: false).count).map { $0 <= 6_144 } == true
                ? evidence : .object(["_truncated": .bool(true)])
            if let data = try? TurnTraceRedactor.redactValue(result).serializedData(pretty: false) {
                fields["resultDigest"] = .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
        }
        return fields
    }

    // Select evidence before preview truncation; keep worker routing and outcome
    // trees without retaining their prompts or answers.
    private static func receiptFields(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var fields: [String: JSONValue] = [:]
            for key in ["id", "receipt_id", "run_id", "runId", "job_id", "message_id", "session_id", "handle",
                        "status", "outcome", "final_status", "preview", "effects", "execution", "read_only", "skill", "would_card", "approver", "preview_scope", "verified", "verification",
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

    /// Serialize a compact preview, redact secrets, then truncate to 500 characters; mark serialization failures.
    private static func truncatePreview(_ value: JSONValue) -> String {
        let limit = 500
        var value = value
        if case .object(let fields) = value, fields["status"] == .string("preview") {
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

    package func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    package func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    package func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }

    private func recordCompletion(
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
        let tracePath = Self.traceSource(at: recordedAt)
        let argKeys = input.keys.sorted()
        let risk = SwiftNativeSecurityCenter.canonicalToolRisk(
            tool: tool,
            input: input,
            dataRoot: dataRoot
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
                tracePath == "data/traces/events.jsonl"
                    ? "events.jsonl:tool.dispatch" : "\(tracePath.dropFirst(5)):tool.dispatch",
                "status:\(status)",
                "duration_ms:\(durationMs)",
                "arg_key_count:\(argKeys.count)",
                // Retention proves recording here, not an effect's permanence.
                tracePath == "data/traces/events.jsonl"
                    ? "permanence_source:events_jsonl_tail_retention" : "permanence_source:turn_trace_retention",
                "risk_source:security_center.canonical_tool_risk",
            ].map(JSONValue.string)),
            "permanence": .string("bounded_trace"),
            "risk": .string(risk.rawValue),
            "tracePath": .string(tracePath),
        ]
        // Failure text is already bounded and redacted; absent errors omit their keys.
        if !ok && !waiting {
            if let errorClass, !errorClass.isEmpty { receiptEvidence["errorClass"] = .string(errorClass) }
            if let errorDetail, !errorDetail.isEmpty { receiptEvidence["errorDetail"] = .string(errorDetail) }
        }
        receiptEvidence.merge(evidence) { _, evidence in evidence }
        receiptEvidence["source"] = .string(tracePath)
        if let turn = TurnTraceContext.turnId {
            Self.fireBusEvent(
                tool: tool, input: input, surface: surface, phase: "end",
                status: status, durationMs: durationMs, result: result,
                evidence: receiptEvidence, parent: parent, recordedAt: recordedAt
            )
            // A call her night is learning from keeps its tape row.
            if parent == nil, TurnTraceContext.automaticOrigin == nil {
                Self.keepPractice(tool: tool, input: input, surface: surface, receiptID: receiptID, turn: turn,
                                  evidence: evidence, result: result, dataRoot: dataRoot, at: recordedAt)
            }
            // The act is the turn's, or its enclosing call's; its receipt is the evidence.
            guard case .string(let action)? = evidence["action"] else { return }
            let effects: Experience.Effects? = if case .object(let fields) = result, case .string(let raw)? = fields["effects"] {
                Experience.Effects(rawValue: raw)
            } else { nil }
            var act = Experience(id: receiptID, kind: .act, cause: [parent ?? turn],
                                 evidence: [.init(source: tracePath, id: receiptID)],
                                 outcome: .init(domain: action, status: status, effects: effects))
            // Repair is owed until the operation works or she lets it go.
            let remedy: JSONValue? = if case .object(let fields) = result { fields["remedy"] } else { nil }
            let operation = ChatToolOutcome.repairOperation(action, input)
            let refusedBeforeEffect: Bool = if effects == Experience.Effects.none, case .object(let fields) = result {
                ChatToolOutcome.neverRan(result) || verdict == .refused
                    || fields["execution"] == .string("not_run") || fields["argument_path"] != nil && fields["argument_path"] != .null
                    || ["invalid_arguments", "unknown_contact", "not_run"].contains(fields["status"]?.stringValue ?? "")
            } else { false }
            // A refused probe changed nothing. Keep its act as evidence, but
            // do not invent an obligation for the call it never made.
            let probeOnly = action == "agent.verify" && effects == Experience.Effects.none
            var own: OwedNo?
            if !refusedBeforeEffect, !probeOnly, case .object(let fix)? = remedy, fix["kind"] == .string("repair"), case .string(let owner)? = fix["owner"] {
                let tap: String? = if case .string(let tap)? = fix["tap"] { tap } else { nil }
                let call = fix["next_call"].flatMap { $0 == .null ? nil : try? $0.serialize(pretty: false) }
                own = OwedNo(operation: operation, owner: owner, lever: ChatToolOutcome.leverOperation(remedy),
                             nextCall: call.map(ChatSecretRedactor.redactText), tap: tap)
            }
            // A no inside a call is owed by the call that surfaced it; a call that
            // failed with no owner of its own surfaces its steps' owned nos.
            let surfaced = refusedBeforeEffect || probeOnly ? [] : own.map { [$0] } ?? (status == "failed" ? nos.inside.all : [])
            // A preview shows what a call would do; it proves nothing works.
            let worked = status == "ok" && input["preview"] != .bool(true)
            if parent != nil {
                if status == "failed" { nos.enclosing?.add(surfaced) } else if worked { nos.enclosing?.worked(operation) }
            } else if let own {
                act.owes["repair"] = .init(to: own.tap == nil ? "self" : "person")
                act.claims = RepairOwed.claims(owner: own.owner, operation: own.operation, lever: own.lever,
                                               nextCall: own.nextCall, tap: own.tap)
            } else {
                for (index, no) in surfaced.enumerated() {
                    RepairOwed.owe(dataRoot, id: receiptID + ":" + String(index), kind: .act, cause: [receiptID],
                                   evidence: [.init(source: tracePath, id: receiptID)], operation: no.operation,
                                   owner: no.owner, words: errorDetail ?? "", lever: no.lever, nextCall: no.nextCall, tap: no.tap)
                }
            }
            // Debts and settlements of one operation share its queue, so neither overtakes the other.
            let queue = act.owes["repair"] != nil || worked ? "repair:" + operation : receiptID
            ExperienceStore.record(dataRoot, queue) { [act] store in
                var act = act
                // A repeat of a debt still open is evidence on it, not a second line.
                if act.owes["repair"] != nil, let owner = act.claims.first(where: { $0.claim.hasPrefix("owner: ") }),
                   let open = try await RepairOwed.openDebt(store, operation: operation, owner: String(owner.claim.dropFirst(7))) {
                    act.owes["repair"] = nil
                    try await store.begin(act)
                    try await store.append([.evidence(.init(source: "act", id: receiptID))], to: open.id)
                    return
                }
                try await store.begin(act)
                if worked { try await RepairOwed.settle(store, operation: operation, evidence: .init(source: "act", id: receiptID)) }
            }
            return
        }
        let event = TurnTraceEvent(kind: "tool.dispatch", title: tool, status: status,
            // Compact evidence only; no argument or result bodies.
            payload: .object([
                "argKeys": .array(argKeys.map { .string($0) }),
                "durationMs": .int(Int64(durationMs)),
                "surface": .string(surface),
                "turnId": .string(TurnTraceContext.turnId ?? "unknown"),
                "receipt": .object(receiptEvidence),
            ]), id: receiptID, createdAt: NativeTimestampFormat.plainZulu(recordedAt), ts: recordedAt)
        await TurnTracePersistLane(dataRootOverride: dataRoot).append(event)
    }
}
