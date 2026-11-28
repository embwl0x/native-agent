import SenseCore
import Synchronization
import MindCore
import ProviderRouting
import Foundation
import NativeAgentShared
import DeskCore
import MacNerves
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatToolDispatchTrace.swift` | `ChatToolDispatchTracer`, `isPreview`: Preserve redacted failure evidence. |

/// TurnTrace owns bound dispatches; standalone events keep recent_trace_summary aware of tool activity. Trace outside the gates so refusals are recorded too.
/// Turn previews obey local redaction policy; recorded details are unencrypted. Diagnostic trace failures must not change dispatch outcomes.
package enum ChatToolDispatchTracer {
    /// An owned no met inside a call surfaces with the call's own failure: a batch or part that fails without an owner of its own owes its steps'.
    struct OwedNo: Sendable { let operation, owner: String; let lever, nextCall, tap: String? }
    final class SurfacedNos: Sendable {
        private let items = Mutex<[OwedNo]>([])
        let parent: SurfacedNos?
        init(parent: SurfacedNos?) { self.parent = parent }
        func add(_ more: [OwedNo]) { items.withLock { $0 += more } }
        var all: [OwedNo] { items.withLock { $0 } }
        /// A later success of the operation or its lever answers an earlier no, at every level.
        func worked(_ operation: String) {
            items.withLock { $0.removeAll { $0.operation == operation || $0.lever == operation } }
            parent?.worked(operation)
        }
    }

    /// The recorded call a dispatch runs inside, and the ability it named.
    private struct TracedAct: NativeAgentCore.TurnPart, Sendable {
        let receipt: String, ability: String
        static let unset: TracedAct? = nil
    }

    /// One dispatch predicate for both recording and the turn's learning readers.
    package static func isPreview(tool: String, input: [String: JSONValue]) -> Bool {
        tool == "app" && input["preview"] == .bool(true)
    }

    static func trace(_ pipeline: DoorPipeline, tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        // The card this call runs on, carried in by a replay or filled by the gate when the person approves it mid-call.
        let dataRoot = pipeline.dataRoot
        let turn = turn.with(\.cardCause, turn.cardCause ?? CardCause())
        let ability = Self.abilityName(tool: tool, input: input)
        if turn[DreamPart.Key.self] != nil {
            return try await pipeline.checkProvenance(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        }
        if turn.doorPreview != nil {
            let result = try await pipeline.checkProvenance(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
            if tool == "app", let fields = result.objectValue, let execution = fields["execution"]?.stringValue {
                let page = fields["page"]?.stringValue.map { page in
                    fields["item"]?.stringValue.map { page + "/" + $0 } ?? page
                }
                if let action = invocation[BoundDoorAction.self]?.previewRead?.id ?? (input["find"]?.stringValue == nil ? page : "find") {
                    await TurnTracePersistLane(dataRootOverride: dataRoot).previewRead(action, execution: execution,
                        status: fields["status"], surface: surface, turn: turn)
                }
            }
            return result
        }
        if pipeline.policy.traceOnlyAbilities, ability == nil {
            return try await pipeline.checkProvenance(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        }
        // A part's own fold and admission re-enter this door inside its recorded call: one call is one row, and its children keep that row as parent.
        if tool != "app", let ability, let held = turn[TracedAct.self], held.ability == ability, held.receipt == turn.act {
            return try await pipeline.checkProvenance(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let startedAt = Date()
        let receiptID = UUID().uuidString.lowercased()
        let target: Result<AbilityTarget?, Error>
        do { target = .success(try await Self.abilityTarget(named: ability, input: input, turn: turn, dataRoot: dataRoot)) }
        catch { target = .failure(error) }
        let parent = turn.act
        let enclosing = invocation.surfacedNos, inside = SurfacedNos(parent: enclosing)
        // The begin event lets Inspector show an in-flight dispatch.
        await Self.fireBusEvent(dataRoot: dataRoot, turn: turn,
            tool: tool, input: input, surface: surface,
            phase: "begin", status: "running", durationMs: nil, result: nil, resultView: nil,
            evidence: Self.dispatchEvidence(turn: turn, tool: tool, input: input, status: "running", result: nil, receiptID: receiptID),
            parent: parent
        )
        var inner = turn.with(\.act, receiptID)
        if let ability { inner[TracedAct.self] = TracedAct(receipt: receiptID, ability: ability) }
        let held = inner
        let dispatched: JSONValue
        do {
            dispatched = ChatToolOutcome.normalizedFailure(try await pipeline.checkProvenance(
                tool: tool, input: input, surface: surface, turn: held,
                invocation: invocation.with(\.surfacedNos, inside)), tool: tool,
                throughAppDoor: invocation.appDoor != nil)
        } catch {
            let failure = await settleTrace {
                let failure = await Self.settleAbilityRefusal(ChatToolOutcome.failure(error: error, tool: tool), target: target,
                    turn: turn, receiptID: receiptID, at: startedAt, dataRoot: dataRoot)
                let reply = ToolResult(failure)
                let verdict = reply.outcome
                let evidence = Self.dispatchEvidence(turn: turn, tool: tool, input: input, status: "failed", result: failure, receiptID: receiptID,
                    verdict: verdict)
                await Self.recordCompletion(dataRoot: dataRoot, turn: turn,
                    tool: tool, input: input, surface: surface,
                    status: "failed", startNs: startNs,
                    receiptID: receiptID, evidence: evidence,
                    result: failure, verdict: verdict, parent: parent, nos: (inside, enclosing),
                    errorClass: "dispatch_threw",
                    errorDetail: ChatToolOutcome.failureDetail(error: error)
                )
                return failure
            }
            if ability != nil, case .object(var fields) = failure {
                fields["dispatch_receipt_id"] = .string(receiptID)
                fields["dispatch_receipt_source"] = .string("detail")
                return .object(fields)
            }
            throw error
        }
        return await settleTrace {
            let result = await Self.settleAbilityRefusal(dispatched, target: target, turn: turn, receiptID: receiptID, at: startedAt, dataRoot: dataRoot)
            let reply = ToolResult(result)
            let verdict = reply.outcome
            let ok = ChatToolOutcome.outputLooksSuccessful(result, verdict: verdict)
            // An unanswered approval card is waiting, never a failed dispatch.
            let waiting = ChatToolOutcome.isWaitingOnPerson(result, verdict: verdict)
            let status = waiting ? "waiting" : ChatToolOutcome.statusWord(result, verdict: verdict)
            let failureShaped = !ok && !waiting
            let evidence = Self.dispatchEvidence(turn: turn, tool: tool, input: input, status: status, result: result, receiptID: receiptID, verdict: verdict)
            await Self.recordCompletion(dataRoot: dataRoot, turn: turn,
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
    }

    private static func settleTrace(_ completion: @escaping @Sendable () async -> JSONValue) async -> JSONValue {
        let turnID = TurnTraceContext.turnId, bus = TurnTraceContext.bus, origin = TurnTraceContext.automaticOrigin
        let destination = TurnTraceContext.destinationId, thread = TurnTraceContext.threadId
        return await settle {
            await TurnTraceContext.$turnId.withValue(turnID) {
                await TurnTraceContext.$bus.withValue(bus) {
                    await TurnTraceContext.$automaticOrigin.withValue(origin) {
                        await TurnTraceContext.$destinationId.withValue(destination) {
                            await TurnTraceContext.$threadId.withValue(thread, operation: completion)
                        }
                    }
                }
            }
        }
    }

    /// Native calls and app actions name the same part; native executor names never become ability ids.
    package static func abilityName(tool: String, input: [String: JSONValue]) -> String? {
        let action = tool == "app" ? input["action"]?.stringValue : tool
        guard let action else { return nil }
        if action == "ability.resume" { return action }
        if let id = ToolNameAliases.authoredTool(action) { return id }
        let declared = AppActionBinding.declaredBinding(action)
        if declared == nil, tool == "app" { return action }
        let target = declared?.tool ?? action
        guard !target.isEmpty, !target.contains("."), !SwiftToolDispatcher.nativeCanonicalToolNames.contains(target) else { return nil }
        return target
    }

    private struct AbilityTarget: Sendable { let id: String; let version: String }

    /// Capture a resume's sealed identity before its owner may consume or close the checkpoint.
    @concurrent private static func abilityTarget(named: String?, input: [String: JSONValue], turn: Turn, dataRoot: URL) async throws -> AbilityTarget? {
        guard let named else { return nil }
        if named == "ability.resume" {
            let args = input["args"]?.objectValue ?? input
            guard let runID = args["run_id"]?.stringValue,
                  runID.range(of: "^run-[0-9a-f]{8}$", options: .regularExpression) != nil else { return nil }
            let run = try await PartRunStore.read(runID, root: dataRoot)
            guard let id = run["skill"]?.stringValue, let version = run["digest"]?.stringValue else {
                throw ToolFailureError("The refused resume has no ability identity in its saved checkpoint.", effects: .none)
            }
            return AbilityTarget(id: id, version: version)
        }
        let binding = try AppActionBinding.action(input: ["action": .string(named)], turn: turn)
        let reference: String
        if let binding, !binding.tool.isEmpty { reference = binding.tool } else { reference = named }
        guard let row = try Parts(root: dataRoot).row(reference) else { return nil }
        guard let id = row["id"]?.stringValue, let version = row["codeFingerprint"]?.stringValue else {
            throw ToolFailureError("Ability \(reference) has no selected version for this refusal's accounting.", effects: .none)
        }
        return AbilityTarget(id: id, version: version)
    }

    /// Refusals before runner entry settle beside runner receipts, through the same dispatch completion.
    @concurrent private static func settleAbilityRefusal(_ result: JSONValue, target: Result<AbilityTarget?, Error>, turn: Turn,
        receiptID: String, at: Date, dataRoot: URL) async -> JSONValue {
        guard ToolResult(result).outcome.isFailure else { return result }
        var fields = result.objectValue ?? [:]
        if fields["ability_run"]?.objectValue != nil { return result }
        if fields["result"]?.objectValue?["ability_run"]?.objectValue != nil { return result }
        // A producer that could not select an identity already retained that failure; a later catalog read cannot name this run.
        if fields["accounting_error"] != nil { return result }
        fields["checker"] = fields["checker"] ?? .string("dispatch")
        do {
            guard let target = try target.get(), target.id != DreamPart.id else { return .object(fields) }
            fields["dispatch_receipt_id"] = .string(receiptID)
            return await AbilityStore(dataRoot: dataRoot).settleRun(id: target.id, version: target.version,
                receipt: .object(fields), input: nil, turn: turn, at: at)
        } catch {
            fields["accounting_error"] = .string(error.localizedDescription)
            return .object(fields)
        }
    }

    /// Calls refused without dispatch still belong to model activity and need failure traces.
    @discardableResult
    package static func traceUndispatched(turn: Turn, tool: String, input: [String: JSONValue], surface: String, result: JSONValue,
        dataRoot: URL) async -> JSONValue {
        if turn.doorPreview != nil || isPreview(tool: tool, input: input) || turn[DreamPart.Key.self] != nil { return result }
        let at = Date(), startNs = DispatchTime.now().uptimeNanoseconds
        let receiptID = UUID().uuidString.lowercased()
        let ability = abilityName(tool: tool, input: input)
        if ability == nil {
            let view = await resultView(turn: turn, tool: tool, input: input, result: result, receiptID: receiptID, dataRoot: dataRoot)
            var evidence = dispatchEvidence(turn: turn, tool: tool, input: input, status: "failed", result: result, receiptID: receiptID)
            evidence["result_recovery"] = view.recovery
            if view.failed { evidence["result_retention_failed"] = .bool(true) }
            await fireBusEvent(dataRoot: dataRoot, turn: turn, tool: tool, input: input, surface: surface, phase: "end", status: "failed", durationMs: nil,
                result: result, resultView: view, evidence: evidence, parent: nil)
            return result
        }
        let target: Result<AbilityTarget?, Error>
        do { target = .success(try await abilityTarget(named: ability, input: input, turn: turn, dataRoot: dataRoot)) }
        catch { target = .failure(error) }
        let result = await settleAbilityRefusal(result, target: target, turn: turn, receiptID: receiptID, at: at, dataRoot: dataRoot)
        let verdict = ToolResult(result).outcome
        let evidence = dispatchEvidence(turn: turn, tool: tool, input: input, status: "failed", result: result, receiptID: receiptID, verdict: verdict)
        await recordCompletion(dataRoot: dataRoot, turn: turn, tool: tool, input: input, surface: surface, status: "failed", startNs: startNs,
            receiptID: receiptID, evidence: evidence, result: result, verdict: verdict, parent: turn.act,
            nos: (SurfacedNos(parent: nil), nil), errorClass: ChatToolOutcome.receiptFailureClass(result, verdict: verdict),
            errorDetail: ChatToolOutcome.failureDetail(result))
        var fields = result.objectValue ?? [:]
        fields["dispatch_receipt_id"] = .string(receiptID)
        fields["dispatch_receipt_source"] = .string("detail")
        return .object(fields)
    }

    @concurrent static func resultView(turn: Turn, tool: String, input: [String: JSONValue], result: JSONValue,
        receiptID: String?, dataRoot: URL) async -> ProviderToolResultPage.View {
        do {
            let ran = ToolNameAliases.ranTool(tool, input: input)
            func redact(_ result: JSONValue) -> JSONValue {
                TurnTraceRedactor.redactValue(MacInjectionResultRedaction.redacted(tool: ran,
                    result: MacScreenViewResultRedaction.redacted(tool: ran, result: result), turn: turn))
            }
            var redacted = redact(result)
            if case .object(var fields) = redacted {
                if let receiptID {
                    fields["dispatch_receipt_id"] = .string(receiptID)
                    fields["dispatch_receipt_source"] = .string("detail")
                } else if fields["reason"] == .string("continuation_settlement_failed"),
                          let receipt = result.objectValue?["receipt"] {
                    fields["receipt"] = redact(receipt)
                }
                redacted = .object(fields)
            }
            let content = ChatSecretRedactor.redactText(try redacted.serialize(pretty: false))
            return await ProviderToolResultPage.project(toolName: tool, content: content,
                dataRoot: dataRoot, turn: turn,
                originalResultClass: ToolResult(result).outcome, appDoor: true,
                inlineLimit: TurnTraceEvent.toolResultInlineUTF8Bytes, includeSections: false)
        } catch {
            let cause = String(error.localizedDescription.prefix(300))
            return .init(content: "The result could not be encoded for retention: \(cause). Inspect its effect before repeating it.",
                recovery: nil, failed: true)
        }
    }

    private static func fireBusEvent(dataRoot: URL, turn: Turn,
        tool: String,
        input: [String: JSONValue],
        surface: String,
        phase: String,
        status: String,
        durationMs: Int?,
        result: JSONValue?,
        resultView: ProviderToolResultPage.View?,
        evidence: [String: JSONValue],
        parent: String?,
        recordedAt: Date = Date()
    ) async {
        var payload: [String: JSONValue] = [
            "name": .string(tool),
            "phase": .string(phase),
            "status": .string(status),
            "receipt": .object(evidence),
            "argKeys": .array(input.keys.sorted().map { .string($0) }),
            // Redact injections before bounding; short secrets fit in a preview.
            "args": .string(Self.argumentPreview(
                .object(MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn))
            )),
        ]
        if let durationMs { payload["durationMs"] = .int(Int64(durationMs)) }
        if let parent { payload["parentId"] = .string(parent) }
        if let invocationID = turn.invocationID { payload["invocationID"] = .string(invocationID) }
        if let origin = TurnTraceContext.automaticOrigin { payload["automaticOrigin"] = .string(origin) }
        let shown = ToolNameAliases.shown(tool, input: .object(input)).name
        if shown != tool { payload["shown"] = .string(shown) }
        // A call that worked names the place it was about, each nested step its own (`AppActionBinding.faceLink`): the turn's attention.
        if phase == "end", status == "ok", let place = AppActionBinding.faceLink(tool, input: .object(input)) { payload["face"] = .string(place) }
        if tool == "act", case .object(let reply)? = result, case .object(let detail)? = reply["detail"],
           let changed = detail["owner_front_changed"] {
            payload["user_front_changed"] = changed
        }
        if let result {
            if status == "failed" {
                payload.merge(Self.failureFields(result)) { _, field in field }
                payload["errorDetail"] = ChatToolOutcome.failureDetail(result).map(JSONValue.string)
            }
            payload["result"] = resultView.map { JSONValue.string($0.content) }
            payload["result_recovery"] = resultView?.recovery
        }
        let event = TurnTraceEvent(
            turnId: turn.id, ts: recordedAt, kind: "tool.dispatch",
            sessionId: traceSessionID(turn: turn, input), surface: surface, payload: .object(payload), turn: turn
        )
        if TurnTraceContext.turnId != nil { TurnTraceBus.fire(event, on: TurnTraceContext.bus ?? .shared) }
        else if phase == "end" { await TurnTracePersistLane(dataRootOverride: dataRoot).append(event) }
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
        for key in ["status", "failure_code", "code", "reason", "checker", "remedy", "argument_path", "error", "detail", "message"] {
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
        if let card = turn.cardCause?.card { fields["cause"] = .object(["card": .string(card)]) }
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
                fields["resultDigest"] = .string(SHA256Hex.of(data))
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
                        "ability", "version", "at", "reason", "checker", "detail", "message", "dispatch_receipt_id",
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
            if let remedy = object["remedy"] { fields["remedy"] = TurnTraceRedactor.redactValue(remedy) }
            for key in ["execution", "receipt", "result", "error", "stopped", "detail", "workers", "results", "outputs", "agents", "routing",
                        "synthesis", "next", "ability_run"] {
                if let field = object[key], case .object = field { fields[key] = receiptFields(field) }
                else if let field = object[key], case .array = field { fields[key] = receiptFields(field) }
            }
            return .object(fields)
        case .array(let values): return .array(values.map(receiptFields))
        default: return .null
        }
    }

    /// Redact before applying the 500-character preview cap; serialization failure remains explicit.
    private static func argumentPreview(_ value: JSONValue) -> String {
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

    private static func recordCompletion(dataRoot: URL, turn: Turn,
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
        let resultView = await Self.resultView(turn: turn, tool: tool, input: input, result: result, receiptID: receiptID, dataRoot: dataRoot)
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
        let pending = projected == .unknown
            && ChatToolOutcome.displayOutcome(result: result, ok: nil, hasResult: true) == .pending
        let outcome = ok ? "completed" : waiting ? "waiting" : pending ? "pending" : projected.rawValue
        let reason = ok ? "tool dispatch completed" : waiting ? "waiting on you" : "tool dispatch \(outcome)"
        var receiptEvidence: [String: JSONValue] = [
            "action": .string("tool_dispatch"),
            "surface": .string(surface),
            "target": .string(tool),
            "decision": .string("attempted"),
            "outcome": .string(outcome),
            "reason": .string(reason),
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
        receiptEvidence["result_recovery"] = resultView.recovery
        if resultView.failed { receiptEvidence["result_retention_failed"] = .bool(true) }
        await Self.fireBusEvent(dataRoot: dataRoot, turn: turn,
            tool: tool, input: input, surface: surface, phase: "end",
            status: status, durationMs: durationMs, result: result, resultView: resultView,
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
                             outcome: .init(domain: action, status: status, effects: effects), steeredBy: turn.steeringStamp())
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
            // The debt says why it was owed, as a debt born through `RepairOwed.owe` does; Home and Doctor read these words.
            if let errorDetail, !errorDetail.isEmpty { act.face = .init(words: errorDetail, artifacts: []) }
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
    }
}
