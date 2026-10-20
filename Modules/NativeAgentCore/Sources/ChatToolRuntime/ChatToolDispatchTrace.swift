import AuthoredCapabilities
import AgentConversations
import AgentWorkspace
import ChatSessionWork
import ChatTurnContracts
import Experiences
import ProviderRouting
import Foundation
import CryptoKit
import ToolRegistry
import MacControl
import MCPDispatcher
import NativeAgentCore
import PersistenceCore
import TurnTrace
import TrustCenter
import ChromeControl
import Skills
import Senses

// MARK: - Tool-output failure-shape heuristic

/// Shared success/failure classification for chat tool envelopes. Lives here
/// (not inside ToolProgressPersistenceBuffer, its original home) because the
/// trace recorder below must classify failures IDENTICALLY to the persisted
/// tool rows — two heuristics would let a dispatch persist as failed in chat
/// history yet trace as ok in events.jsonl.
extension ChatToolOutcome {

    /// Fill missing failure evidence at the result boundary; successes pass through unchanged.
    public static func normalizedFailure(_ output: JSONValue, tool: String? = nil) -> JSONValue {
        guard !outputLooksSuccessful(output), !isWaitingOnPerson(output),
              !wasCancelled(output), !InlineInteractionNeed.isWaiting(output),
              case .object(var object) = output else { return output }
        func text(_ key: String) -> String? {
            guard case .string(let raw)? = object[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func isCode(_ value: String) -> Bool {
            value.count <= 80 && value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
        }
        func explanations(_ value: JSONValue?) -> [String] {
            switch value {
            case .string(let raw):
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? [] : [value]
            case .object(let detail):
                return ["message", "text", "detail", "error", "reason", "content", "result", "output"].flatMap { explanations(detail[$0]) }
            case .array(let values):
                return values.flatMap { explanations($0) }
            default: return []
            }
        }
        let oldReason = text("reason")
        // The tool's own code, wherever it says one (a Mac verb's detail.error).
        let inner: String? = if case .object(let detail)? = object["detail"], case .string(let error)? = detail["error"] { error } else { nil }
        let code = [text("error_code"), text("errorCode"), oldReason, text("error"), inner].compactMap { $0 }.first {
            isCode($0) && !["failed", "error"].contains($0)
        } ?? "tool_failed"
        let candidates = ["message", "spoken", "text", "detail", "output", "error", "content", "result", "fix", "recovery_hint", "hint"].flatMap { explanations(object[$0]) }
        // A process that failed says why on stderr and in its exit code.
        let exit = [object["exit_code"], object["exitCode"]].lazy.compactMap { value -> Int? in
            if case .int(let code)? = value { return Int(code) }
            if case .double(let code)? = value { return Int(exactly: code) }
            return nil
        }.first
        var processFailure: String?
        if let stderr = text("stderr") {
            let tail = String(stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n").suffix(600))
            processFailure = (exit.map { "The command exited with code \($0). " } ?? "") + "Its stderr ends: " + tail
        } else if let exit, exit != 0 {
            processFailure = "The command exited with code \(exit) and wrote nothing to stderr."
        }
        // A missing receipt is not proof that a write did not happen; a
        // built-in reader (the workspace's own read list) writes nothing.
        let named = tool ?? text("tool")
        let effects = text("effects") ?? (object["effects_unknown"] == .bool(true) ? "unknown"
            : object["not_run_status"] != nil || named.map { AgentWorkspaceEnvironment.readTools.contains($0) } == true
                ? "none" : "unknown")
        let explained: String? = candidates.first { !isCode($0) } ?? oldReason.flatMap { isCode($0) ? nil : $0 }
        // Only codes said why: the first one still says what failed, in words.
        let bare = (candidates.first ?? code).replacingOccurrences(of: "_", with: " ")
        let worded = "The call failed: \(bare)." + (effects == "none" ? " Nothing changed." : "")
        let message = explained ?? processFailure ?? worded
        // Receipt readers own the meaning of reason/message, including refusal
        // classification. Enrichment must never replace the tool's own fields.
        // An added reason is the code, never a second copy of the message.
        if object["failure_code"] == nil { object["failure_code"] = .string(code) }
        if object["reason"] == nil { object["reason"] = .string(code) }
        if object["message"] == nil { object["message"] = .string(message) }
        if object["argument_path"] == nil { object["argument_path"] = .null }
        if object["accepted"] == nil { object["accepted"] = .null }
        if object["effects"] == nil { object["effects"] = .string(effects) }
        if object["remedy"] == nil {
            // A folded tool is an app action: she calls and finds it there,
            // when the call came through the door. A lane that calls it by
            // name (Workshop, studio wander) keeps its name.
            let door = AppDoorReentry.perform != nil
            let action = door ? named.flatMap { ToolNameAliases.appAction($0) } : nil
            let argument = text("argument_path")
            let correction = effects == "none" && argument != nil && named != nil
            var nextCall: JSONValue
            switch named {
            case "bot_create", "bot_update":
                nextCall = .object(["tool": .string("bot_list"), "input": .object(["include_models": .bool(true)])])
            case "scheduler_update_job":
                nextCall = .object(["tool": .string("scheduler_list_jobs"), "input": .object([:])])
            default:
                // Through the door, app {find} shows an action's accepted args;
                // for any other failure it is a round spent, not a next step.
                let words = (action ?? named ?? "").replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
                nextCall = door && correction && !words.isEmpty
                    ? .object(["tool": .string("app"), "input": .object(["find": .string(words)])]) : .null
            }
            let fix = effects == "none" ? text("fix") : nil
            if fix != nil { nextCall = .null }
            else if door { nextCall = ToolNameAliases.appPointer(nextCall) }
            object["remedy"] = .object([
                "kind": .string(correction ? "correct_arguments" : "inspect"),
                "instruction": .string(fix ?? (correction
                    ? "Correct \(argument!) to the accepted shape, then call \(action.map { "app " + $0 } ?? named!) again with the intended values. Do not guess missing choices. Use next_call to inspect accepted choices or the current state if needed."
                    : effects == "none"
                        ? "Nothing changed. Do what the reason names, or tell the person why."
                        : effects == "occurred"
                            ? "The call took effect. Read the affected state before making another change; do not replay it blindly."
                            : "It may have taken effect: read the affected state before retrying, or tell the person why.")),
                "next_call": nextCall,
            ])
        }
        return .object(object)
    }

    /// The operation a call is for repair: its action, and for a setting the
    /// setting it sets, so one setting working again settles only its own debt.
    static func repairOperation(_ action: String, _ input: [String: JSONValue]) -> String {
        let args = if case .object(let args)? = input["args"] { args } else { input }
        if action == "setting.set", case .string(let setting)? = args["setting"] { return action + ":" + setting }
        if action == "permissions.request", case .string(let capability)? = args["capability"] {
            return action + ":" + capability + (capability == "calendars" && args["mode"] == .string("write") ? ":write" : "")
        }
        return action
    }

    /// The operation a remedy's lever performs, named as acts name theirs. A
    /// read or a restart inspects or retries; it changes no owner, so it is no
    /// lever and its success settles nothing.
    static func leverOperation(_ remedy: JSONValue?) -> String? {
        guard case .object(let fields)? = remedy, case .object(let call)? = fields["next_call"],
              case .string(let tool)? = call["tool"] else { return nil }
        let input: [String: JSONValue] = if case .object(let given)? = call["input"] { given } else { [:] }
        guard case .string(let action)? = input["action"], !action.isEmpty else {
            return tool == "app" ? nil : ToolNameAliases.appAction(tool) ?? tool
        }
        guard !action.hasSuffix(".restart"), AppActionBinding.action(input: input)?.read != true else { return nil }
        return repairOperation(action, input)
    }

    public static func failure(error: any Error, tool: String? = nil, effects: ToolFailureError.Effects? = nil) -> JSONValue {
        if let back = error as? SkillRunContext.HandBack { return SkillRunContext.handBack(back.why) }
        var object: [String: JSONValue] = [
            "status": .string("failed"),
            "failure_code": .string("dispatch_error"),
            "reason": .string(errorMessage(error)),
            "error": .string(errorMessage(error)),
        ]
        if let effects { object["effects"] = .string(effects.rawValue) }
        if let evidence = error as? ToolFailureError {
            object["argument_path"] = evidence.argumentPath.map(JSONValue.string) ?? .null
            object["accepted"] = evidence.accepted.map { .string(ChatSecretRedactor.redactText($0)) } ?? .null
            object["effects"] = .string(evidence.effects.rawValue)
            if evidence.argumentPath != nil { object["failure_code"] = .string("invalid_arguments") }
            if let owner = evidence.owner, evidence.nextCall != nil || evidence.tap != nil {
                let call = evidence.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                object["remedy"] = if evidence.personDecides, let tap = evidence.tap {
                    Repair.why(owner: owner, tap: tap)
                } else { Repair.remedy(owner: owner, nextCall: call, tap: evidence.tap) }
            } else if let call = evidence.nextCall.flatMap({ try? JSONValue.parse(Data($0.utf8)) }) {
                // A correction: the call that works next, no owner and no debt.
                object["remedy"] = .object([
                    "kind": .string(evidence.argumentPath != nil ? "correct_arguments" : "inspect"),
                    "instruction": .string(evidence.message), "next_call": call,
                ])
            }
        }
        if let refusal = error as? AgentConversationStore.Failure { object["effects"] = .string(refusal.effects.rawValue) }
        if let failure = error as? SenseFailure { object["remedy"] = failure.remedy }
        if error is AgentWorkspaceFailure { object["effects"] = .string("none") }
        // A skill's save, read or enable refused for its shape or state wrote nothing.
        if let refusal = error as? SkillsError {
            object["effects"] = .string("none")
            // A shape or state refusal ran nothing; an invalid script may have run under interception.
            if case .invalidScript = refusal {} else { object["execution"] = .string("not_run") }
        }
        if let connector = error.missingConnectorID {
            object["effects"] = .string("none")
            object["outcome"] = .string("unmet")
            object["fix"] = .string("The owner can sign in to \(connector) by requesting a setup card in chat or opening Connectors in Advanced view.")
        }
        if let chrome = error as? ChromeControlRuntimeError {
            if let effects = chrome.failureEffects { object["effects"] = .string(effects.rawValue) }
            if let remedy = chrome.remedy { object["remedy"] = remedy }
            if case .outcomeUnknown = chrome { object["effects_unknown"] = .bool(true) }
        }
        if let recovery = (error as? LocalizedError)?.recoverySuggestion,
           !recovery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["hint"] = .string(ChatSecretRedactor.redactText(recovery))
        }
        if let gate = error as? AutonomyGateError {
            if case .toolDenied(let reason, let remedy) = gate {
                if let remedy { object["remedy"] = remedy }
                object["gate_reason"] = .string(ChatSecretRedactor.redactText(reason))
                if let tool, reason.hasPrefix("autonomy=") || reason.hasPrefix("fileAccess=") {
                    let sentence = ToolNotRunStatus.blockedSentence(reason: reason, tool: tool)
                    object["reason"] = .string(sentence)
                    object["error"] = .string(sentence)
                }
            }
            return normalizedFailure(gate.notRunStatus.reporting(.object(object), tool: tool), tool: tool)
        }
        return normalizedFailure(.object(object), tool: tool)
    }

    package enum CognitiveResult: String, Sendable, Equatable {
        case succeeded
        case failed
        case unknown
    }

    /// The algebra as one status word: failed for every failure shape,
    /// unknown only when the envelope itself says its outcome is still open
    /// (`saysOutcomeOpen`), ok for every other call that returned without
    /// error. A status word the algebra does not know (workspace's
    /// "prepared", a read's "nothing_to_read") came back fine.
    package static func statusWord(_ output: JSONValue) -> String {
        guard outputLooksSuccessful(output) else { return "failed" }
        return saysOutcomeOpen(output) ? "unknown" : "ok"
    }

    /// Not failure-shaped, as the one outcome algebra (`exactResultClass`)
    /// grades it: an unknown outcome is not a failure, except a skipped call
    /// or a raised need, which did not run.
    package static func outputLooksSuccessful(_ output: JSONValue) -> Bool {
        switch exactResultClass(output) {
        case .failed, .refused, .timeout, .cancelled: return false
        case .succeeded: return true
        case .unknown:
            guard case .object(let object) = output, case .string(let status)? = object["status"] else { return true }
            return !["skipped", "needs_input"].contains(status.lowercased())
        }
    }

    /// User, 2026-09-06: a slot the Stop reached NEVER RAN. Its envelope is
    /// synthetic (`SwiftNativeTurnEngine.cancelledToolResult`) and carries an
    /// `error` string only so the model reads a reason — it is not evidence of
    /// an effect, and not evidence of a failure. Every counter that grades a
    /// turn asks this before it grades a record.
    public static func wasCancelled(_ output: JSONValue) -> Bool {
        exactResultClass(output) == .cancelled
    }

    /// User, 2026-09-06: a tool that filed an approval and returned
    /// `waiting_approval` DID NOT RUN. The row is honest as it stands — it is
    /// not a failure — but it is not PROGRESS either, and counting it as one let
    /// a model that kept re-asking for the same CONFIRM renew the whole-turn
    /// budget on every round and run the turn out at the iteration cap.
    public static func isWaitingApproval(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if object["not_run_status"] == .string("approval_filed") { return true }
        if let result = object["result"], isWaitingApproval(result) { return true }
        guard case .string(let raw)? = object["status"] else { return false }
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status == "waiting_approval"
            || status == "awaiting_approval"
            || status == "pending_approval"
    }

    /// Either kind of wait: the turn is parked on a person, not on a model.
    public static func isWaitingOnPerson(_ output: JSONValue) -> Bool {
        isWaitingApproval(output) || isWaitingInteraction(output)
    }

    /// A call the harness answered without running it: a send held back for
    /// its step's results, a tool that was not offered this round, or a skipped
    /// call. None is progress, and none is an effect.
    public static func neverRan(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if case .string(let status)? = object["status"],
           status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "skipped" {
            return true
        }
        return object["held_for_results"] == .bool(true) || object["not_offered"] == .bool(true)
    }

    /// User, 2026-09-06: a cancelled envelope whose dispatch HAD STARTED
    /// (`SwiftNativeTurnEngine.interruptedToolResult`). Still not a failure, but
    /// the tool may have written before it unwound, so retry safety counts it
    /// as an effect while the failure counters keep skipping it.
    public static func effectsUnknown(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output,
              case .bool(true)? = object["effects_unknown"] else { return false }
        return true
    }

    /// Generic chat-tool completion must not duplicate an existing motor
    /// owner's consequence. Those domains publish from their canonical read
    /// models; their immediate tool envelope is transport evidence only.
    package static func cognitiveResult(tool: String, output: JSONValue) -> CognitiveResult {
        let resultClass = exactResultClass(output)
        // Deterministic policy/input refusals are useful transcript and audit
        // failures, but they are not evidence that the tool implementation is
        // brittle. Keeping them out of resident physiology prevents a correctly
        // enforced sensitive-path fence (or a caller's missing path) from
        // manufacturing a low-confidence tool reflex.
        if isDeterministicRefusal(output) {
            return .unknown
        }
        // External protocol responses prove only that transport returned.
        // They do not prove that any external effect settled, and a timeout or
        // stream loss may occur after submission. Keep resident physiology
        // neutral; the model and trace still receive the exact result/error.
        if ToolCausalBoundary.isExternalProtocolTool(tool) {
            return .unknown
        }
        if hasCanonicalMotorOwner(tool) {
            // Once the envelope carries the canonical owner's identity, its
            // read model is the only consequence source. Before admission no
            // owner exists, so an exact failure must still reach resident
            // attention instead of disappearing behind the tool-name rule.
            guard canonicalMotorOwnerReference(tool: tool, output: output) == nil else {
                return .unknown
            }
            switch resultClass {
            case .failed, .refused, .timeout: return .failed
            case .cancelled, .succeeded, .unknown: return .unknown
            }
        }
        switch resultClass {
        case .succeeded: return .succeeded
        case .failed, .refused, .timeout: return .failed
        // User, 2026-09-06: a Stop is not the tool failing. A cancelled slot
        // never reached its implementation, so it is no evidence either way —
        // grading it as a failure manufactured a low-confidence tool reflex out
        // of the user pressing stop.
        case .cancelled: return .unknown
        case .unknown: return .unknown
        }
    }

    /// Bounded, secret-redacted, single-line failure detail for a
    /// failure-shaped envelope — the text a receipt may carry so the NEXT
    /// failure burst is diagnosable from `events.jsonl` alone. Composed ONLY
    /// from error-shaped fields (`error`/`message`/`reason`/`detail`/
    /// `error_code`/`status`), never the result body; `ChatSecretRedactor`
    /// runs BEFORE the cap so a short secret cannot ride through under it.
    /// Returns nil when no such field is set (ok envelopes, bare objects).
    package static let failureDetailLimit = 200

    package static func failureDetail(_ output: JSONValue) -> String? {
        guard case .object(let object) = output else {
            if case .string(let text) = output { return boundedDetail(text) }
            return nil
        }
        var parts: [String] = []
        func take(_ key: String, label: String? = nil) {
            guard let value = object[key], value != .null else { return }
            let text: String
            switch value {
            case .string(let s): text = s
            case .bool(let b): text = String(b)
            case .int(let i): text = String(i)
            case .double(let d): text = String(d)
            default: return // nested bodies are never summarised
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // The tool loop's projected-error envelope repeats one message
            // under `error` AND `reason`; keep each distinct text once.
            let rendered = label.map { "\($0)=\(trimmed)" } ?? trimmed
            guard !parts.contains(rendered), !parts.contains(trimmed) else { return }
            parts.append(rendered)
        }
        take("error_code", label: "code")
        take("errorCode", label: "code")
        take("failure_code", label: "code")
        take("reason")
        take("status", label: "status")
        take("message")
        take("error")
        take("detail")
        take("fix", label: "fix")
        guard !parts.isEmpty else { return nil }
        return boundedDetail(parts.joined(separator: " | "))
    }

    /// Thrown-error variant: the error's description, same redaction + cap.
    package static func failureDetail(error: any Error) -> String {
        failureDetail(failure(error: error)) ?? "The tool failed."
    }

    /// Receipt classification describes the evidence source, not an invented
    /// root cause. A thrown dispatch and a returned failure envelope are
    /// materially different failure paths for investigation.
    package static func receiptFailureClass(_ output: JSONValue) -> String {
        switch exactResultClass(output) {
        case .cancelled: return "result_cancelled"
        case .timeout: return "result_timeout"
        case .failed, .refused: return "result_failed"
        case .succeeded, .unknown: return "result_failure_envelope"
        }
    }

    private static func boundedDetail(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let redacted = ChatSecretRedactor.redactText(collapsed)
        guard redacted.count > failureDetailLimit else { return redacted }
        return String(redacted.prefix(failureDetailLimit)) + "…"
    }

    private static func isDeterministicRefusal(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if case .bool(true)? = object["requires_approval"] ?? object["requiresApproval"] {
            return true
        }
        if case .bool(true)? = object["permission_denied"] ?? object["permissionDenied"] {
            return true
        }
        if case .string(let rawCode)? = object["error_code"] ?? object["errorCode"] {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let neutralCodes: Set<String> = [
                "approval_required",
                "bad_input",
                "file_not_found",
                "not_loaded",
                "path_not_allowed",
                "permission_denied",
                "policy_denied",
                "security_denied",
                "unsupported",
            ]
            if neutralCodes.contains(code) { return true }
        }
        if case .string(let rawStatus)? = object["status"] {
            let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "awaiting_approval"
                || status == "blocked"
                || status == "pending_approval" {
                return true
            }
            // A typed SecurityCenter denial carries authority evidence beside
            // `status=denied`; an arbitrary domain failure does not.
            if status == "denied",
               object["decision"] != nil
                || object["reasons"] != nil
                || object["capabilities"] != nil {
                return true
            }
        }
        return false
    }

    package static func hasCanonicalMotorOwner(_ rawTool: String) -> Bool {
        ToolCausalBoundary.hasCanonicalMotorOwner(tool: rawTool)
    }

    package static func canonicalMotorOwnerReference(tool rawTool: String, output: JSONValue) -> String? {
        ToolCausalBoundary.motorReference(tool: rawTool, output: output)?.ownerActionID
    }


}

// MARK: - ChatToolDispatchTracer

/// Trace-recording ToolDispatchClient. TurnTrace owns bound dispatches;
/// `<dataRoot>/traces/events.jsonl` owns standalone dispatches:
/// success, failure-shaped envelope, and thrown error. This keeps
/// `recent_trace_summary` aware of the assistant's own tool activity.
///
/// Wraps the gated chain OUTERMOST (above AutonomyGatedDispatcher /
/// FileAccessGatedDispatcher) so gate denials — which throw before the inner
/// dispatcher runs — still land as status:"failed" rows.
///
/// PRIVACY: rows carry keys and compact dispatch evidence, never bodies. The traces
/// file is unencrypted and long-lived.
///
/// Tracing is non-fatal: an IO failure here logs to stderr and the dispatch
/// result (or thrown error) reaches the tool loop unchanged.
///
/// Row schema matches the existing writers (DispatchLedger,
/// CapabilityPackInstall.appendCapabilityPackTrace):
///   {id, kind, title, status, payload, createdAt} with ISO8601 createdAt.
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
    private let tracesPath: URL
    private let persistence = SwiftNativePersistenceCore()

    package init(
        inner: any ToolDispatchClient,
        dataRoot: URL
    ) {
        self.inner = inner
        self.dataRoot = dataRoot
        self.tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
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
            let evidence = Self.dispatchEvidence(tool: tool, input: input, status: "failed", result: failure, receiptID: receiptID)
            await recordCompletion(
                tool: tool, input: input, surface: surface,
                status: "failed", startNs: startNs,
                receiptID: receiptID, evidence: evidence,
                result: failure, parent: parent, nos: (inside, enclosing),
                errorClass: "dispatch_threw",
                errorDetail: ChatToolOutcome.failureDetail(error: error)
            )
            throw error
        }
        let ok = ChatToolOutcome.outputLooksSuccessful(result)
        // A raised card is a question to the person, not a failure. It traced
        // as "failed" — with an error class — until 2026-09-14, which is what
        // made the chat fold read "1 of 3 failed" for a card nobody had
        // answered yet. The row stays honest: it is waiting.
        let waiting = ChatToolOutcome.isWaitingOnPerson(result)
        let status = waiting ? "waiting" : ChatToolOutcome.statusWord(result)
        let failureShaped = !ok && !waiting
        let evidence = Self.dispatchEvidence(tool: tool, input: input, status: status, result: result, receiptID: receiptID)
        await recordCompletion(
            tool: tool, input: input, surface: surface,
            status: status, startNs: startNs,
            receiptID: receiptID, evidence: evidence,
            result: result, parent: parent, nos: (inside, enclosing),
            errorClass: failureShaped ? ChatToolOutcome.receiptFailureClass(result) : nil,
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
        if tool == "app" {
            let calls = if case .array(let calls)? = input["actions"] { calls } else { [JSONValue.object(input)] }
            payload["callShapes"] = .array(calls.compactMap { call in
                guard case .object(let fields) = call, case .string(let action)? = fields["action"] else { return nil }
                return .object(["action": .string(action), "args": Self.argumentShape(fields["args"] ?? .object([:]))])
            })
        }
        if let parent { payload["parentId"] = .string(parent) }
        // An app call as a person is shown it: the action it ran.
        let shown = ToolNameAliases.shown(tool, input: .object(input)).name
        if shown != tool { payload["shown"] = .string(shown) }
        // Her-screen Phase 4 — "User's screen touched: y/n" for the proof tasks.
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
        // Turn Inspector W2 — derived file.touch event. When the dispatched
        // tool is a known FILE tool, extract the path argument(s) and fire a
        // file.touch event with {tool, paths, mode}. Fired ONLY on a
        // SUCCESSFUL end (gpt-5.5 W2 review: a thrown/gate-denied dispatch
        // never touched the file — recording it as a touch would be a lie; the
        // failed attempt stays visible as the tool.dispatch end event above).
        // Paths are not secrets but are redacted anyway (cheap, consistent
        // with the redaction-at-emission discipline).
        if phase == "end", status == "ok" {
            Self.fireFileTouchEvent(tool: tool, input: input, surface: surface, status: status)
        }
    }

    /// Turn Inspector W2 — known file-tool catalog → mode map. Names mirror the
    /// real dispatch catalog in ChatOrchestrationClient (SwiftToolDispatcher
    /// fullMacFileToolNames + the always-on read/write file tools + the builder
    /// apply_patch). `read` vs `write` is the dominant access axis; tools that
    /// can do either default to the more sensitive `write` only when they
    /// actually mutate (apply_patch / write_file / file_write). git_* and grep
    /// are reads.
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

    /// Argument keys that carry a filesystem path across the file-tool catalog.
    /// `apply_patch` carries its target paths INSIDE the patch body (the
    /// envelope itself has no path key), so it contributes no extracted path —
    /// the event still records {tool, mode:write} with an empty paths array,
    /// which is honest (we know it touched files, not which without parsing the
    /// patch — out of W2 scope).
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

    private static func traceSessionID(_ input: [String: JSONValue]) -> String? {
        for key in ["__session_id", "session_id", "sessionId"] {
            guard case .string(let raw)? = input[key] else { continue }
            let sessionID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionID.isEmpty { return sessionID }
        }
        return LLMCallContext.sessionId
    }

    private static func traceSource(at date: Date = Date()) -> String {
        TurnTraceContext.turnId == nil ? "data/traces/events.jsonl"
            : "data/turn_traces/" + TurnTracePersistLane().path(for: date).lastPathComponent
    }

    private static func dispatchEvidence(
        tool: String, input: [String: JSONValue], status: String, result: JSONValue?, receiptID: String
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
            fields["resultClass"] = .string(preview ? "preview" : ChatToolOutcome.exactResultClass(result).rawValue)
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

    /// Structural evidence survives preview truncation and contains no values.
    private static func argumentShape(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields): return .object(fields.filter { !$0.key.hasPrefix("__") }.mapValues(argumentShape))
        case .array(let values):
            return .array(values.map(argumentShape).reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
        case .string: return .string("string")
        case .bool: return .string("bool")
        case .int: return .string("int")
        case .double: return .string("number")
        case .null: return .string("null")
        }
    }

    /// Serialize a JSONValue to a compact preview string, SECRET-REDACTED
    /// (gpt-5.5 W1 review blocker: truncation alone is not redaction — a
    /// token/password under the limit would persist to turn_traces verbatim),
    /// then truncated to 500 chars. Best-effort: a serialization failure
    /// yields a short marker.
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
        let receipt = CompactActionReceipt.toolDispatch(
            tool: tool,
            surface: surface,
            status: status,
            durationMs: durationMs,
            argKeyCount: argKeys.count,
            risk: risk.rawValue,
            tracePath: tracePath,
            errorClass: errorClass,
            errorDetail: errorDetail
        )
        guard case .object(let receiptFields) = receipt.toJSONValue() else { return }
        var receiptEvidence = receiptFields.merging(evidence) { _, evidence in evidence }
        receiptEvidence["source"] = .string(tracePath)
        if let turn = TurnTraceContext.turnId {
            Self.fireBusEvent(
                tool: tool, input: input, surface: surface, phase: "end",
                status: status, durationMs: durationMs, result: result,
                evidence: receiptEvidence, parent: parent, recordedAt: recordedAt
            )
            // The act is the turn's, or its enclosing call's; its receipt is the evidence.
            guard case .string(let action)? = evidence["action"] else { return }
            let effects: Experience.Effects? = if case .object(let fields) = result, case .string(let raw)? = fields["effects"] {
                Experience.Effects(rawValue: raw)
            } else { nil }
            var act = Experience(id: receiptID, kind: .act, cause: [parent ?? turn],
                                 evidence: [.init(source: tracePath, id: receiptID)],
                                 outcome: .init(domain: action, status: status, effects: effects))
            // An owned no on the act she meant owes repair until that operation,
            // or its lever, works again, or she lets it go (User 10-18).
            let remedy: JSONValue? = if case .object(let fields) = result { fields["remedy"] } else { nil }
            let operation = ChatToolOutcome.repairOperation(action, input)
            var own: OwedNo?
            if case .object(let fix)? = remedy, fix["kind"] == .string("repair"), case .string(let owner)? = fix["owner"] {
                let tap: String? = if case .string(let tap)? = fix["tap"] { tap } else { nil }
                let call = fix["next_call"].flatMap { $0 == .null ? nil : try? $0.serialize(pretty: false) }
                own = OwedNo(operation: operation, owner: owner, lever: ChatToolOutcome.leverOperation(remedy),
                             nextCall: call.map(ChatSecretRedactor.redactText), tap: tap)
            }
            // A no inside a call is owed by the call that surfaced it; a call that
            // failed with no owner of its own surfaces its steps' owned nos.
            let surfaced = own.map { [$0] } ?? (status == "failed" ? nos.inside.all : [])
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
        let row: JSONValue = .object([
            "id": .string(receiptID),
            "kind": .string("tool.dispatch"),
            "title": .string(tool),
            "status": .string(status),
            // Compact evidence only; no argument or result bodies.
            "payload": .object([
                "argKeys": .array(argKeys.map { .string($0) }),
                "durationMs": .int(Int64(durationMs)),
                "surface": .string(surface),
                // Turn Inspector W1: correlate this row to its turn. Unbound
                // (non-turn dispatch) → "unknown".
                "turnId": .string(TurnTraceContext.turnId ?? "unknown"),
                "receipt": .object(receiptEvidence),
            ]),
            "createdAt": .string(ISO8601DateFormatter().string(from: recordedAt)),
        ])
        do {
            try await appendPathOwnedJSONL(
                row,
                to: tracesPath,
                using: persistence,
                logLabel: "ChatToolDispatchTracer"
            )
        } catch {
            FileHandle.standardError.write(
                Data("ChatToolDispatchTracer: trace append failed (\(tool)): \(error)\n".utf8)
            )
        }
    }
}
