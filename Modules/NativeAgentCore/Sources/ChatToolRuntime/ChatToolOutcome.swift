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
// Blueprint: | `ChatToolOutcome.swift` | `ChatToolOutcome` runtime extension: failure normalization, waiting/effect evidence, refusal interpretation, cognitive grading and repair operation identity; uses ChatToolParsing's exact result classification |

/// Trace and persisted tool rows use the same success/failure classification.
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
        let genericCodes: Set<String> = ["failed", "error", "dispatch_error", "tool_failed"]
        let suppliedCodes = [text("failure_code"), text("error_code"), text("errorCode"), text("code")].compactMap { $0 }
        let legacyCodes = [oldReason, text("error"), inner].compactMap { $0 }.filter(isCode)
        let code = oldReason.flatMap { isCode($0) && !genericCodes.contains($0) ? $0 : nil }
            ?? (suppliedCodes + legacyCodes).first { !genericCodes.contains($0) }
            ?? suppliedCodes.first ?? legacyCodes.first ?? "tool_failed"
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
        // Missing receipts leave effects unknown; known workspace readers prove none.
        let named = tool ?? text("tool")
        let effects = text("effects") ?? (object["effects_unknown"] == .bool(true) ? "unknown"
            : object["not_run_status"] != nil || named.map { AgentWorkspaceEnvironment.readTools.contains($0) } == true
                ? "none" : "unknown")
        let explained: String? = candidates.first { !isCode($0) && $0 != code }
            ?? oldReason.flatMap { isCode($0) || $0 == code ? nil : $0 }
        let message = explained ?? processFailure ?? "The action supplied no explanation."
        // Preserve prose reasons and refusals; failure_code projects the authoritative coded cause.
        object["failure_code"] = .string(code)
        if oldReason == nil || oldReason.map(isCode) == true { object["reason"] = .string(code) }
        // Project error-only and nested explanations; canonical prose needs no duplicate.
        let hasExplanation = ["detail", "message", "summary"].contains { text($0) != nil }
            || oldReason.map { !isCode($0) && $0 != code } == true
        if object["message"] == nil, !hasExplanation { object["message"] = .string(message) }
        if object["argument_path"] == nil { object["argument_path"] = .null }
        if object["accepted"] == nil { object["accepted"] = .null }
        if object["effects"] == nil { object["effects"] = .string(effects) }
        if object["remedy"] == nil || object["remedy"] == .null {
            // Project the owner's lever; naming an action makes no lookup or replay a repair.
            object["remedy"] = nil
            let door = AppDoorReentry.perform != nil
            let argument = text("argument_path")
            let correction = effects == "none" && argument != nil
            let instruction = text("fix") ?? text("recovery_hint") ?? text("hint")
            if let tap = text("tap") {
                object["remedy"] = Repair.why(owner: text("owner") ?? named ?? "This action", tap: tap, instruction: instruction)
            } else if case .object? = object["next_call"], let supplied = object["next_call"] {
                object["remedy"] = .object([
                    "kind": .string(correction ? "correct_arguments" : "inspect"),
                    "instruction": .string(instruction ?? (effects == "none" ? argument.map { "Correct \($0); use next_call." } : nil) ?? "Use next_call."),
                    "next_call": door ? ToolNameAliases.appPointer(supplied) : supplied,
                ])
            }
        }
        return .object(object)
    }

    /// Repair identity includes the setting, so its success settles only its own debt.
    static func repairOperation(_ action: String, _ input: [String: JSONValue]) -> String {
        let args = if case .object(let args)? = input["args"] { args } else { input }
        if action == "setting.set", case .string(let setting)? = args["setting"] { return action + ":" + setting }
        if action == "permissions.request", case .string(let capability)? = args["capability"] {
            return action + ":" + capability + (capability == "calendars" && args["mode"] == .string("write") ? ":write" : "")
        }
        return action
    }

    /// Name a lever as its act; reads and restarts change no owner and settle no repair.
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
        let evidence = error as? ToolFailureError
        let sense = error as? SenseFailure
        let status = evidence?.status.rawValue ?? sense?.status ?? (error is CancellationError ? "cancelled" : "failed")
        let code = evidence?.failureCode
            ?? sense?.code ?? (status == "failed" ? "dispatch_error" : status)
        func rendered(_ text: String) -> String {
            String(TurnTraceRedactor.redactText(text)
                .replacingOccurrences(of: NSHomeDirectory(), with: "~").prefix(2_000))
        }
        let message = if error is CancellationError { "The action was cancelled." }
            else { errorMessage(error) }
        var object: [String: JSONValue] = sense?.failureEvidence(render: rendered) ?? [
            "status": .string(status),
            "failure_code": .string(code),
            "reason": .string(code),
            "detail": .string(message),
        ]
        if let effects { object["effects"] = .string(effects.rawValue) }
        if let evidence {
            object.merge(evidence.failureEvidence(defaultCode: code)) { _, owned in owned }
            object["accepted"] = evidence.accepted.map { .string(ChatSecretRedactor.redactText($0)) } ?? .null
        }
        if let refusal = error as? AgentConversationStore.Failure { object["effects"] = .string(refusal.effects.rawValue) }
        if error is AgentWorkspaceFailure { object["effects"] = .string("none") }
        // A part's save or read refused for its shape or state wrote nothing.
        if let refusal = error as? PartError {
            object["effects"] = .string("none")
            if case .notFound = refusal { object["execution"] = .string("not_run") }
        }
        if let chrome = error as? ChromeControlRuntimeError {
            if let effects = chrome.failureEffects { object["effects"] = .string(effects.rawValue) }
            if let remedy = chrome.remedy { object["remedy"] = remedy }
            if case .outcomeUnknown = chrome { object["effects_unknown"] = .bool(true) }
        }
        if status == "cancelled" {
            if object["effects"] == nil { object["effects"] = .string("unknown") }
            if object["remedy"] == nil || object["remedy"] == .null {
                object["remedy"] = Repair.terminal(instruction: "Do not repeat the cancelled action automatically.")
            }
        }
        if let recovery = (error as? LocalizedError)?.recoverySuggestion,
           !recovery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["hint"] = .string(ChatSecretRedactor.redactText(recovery))
        }
        if let gate = error as? AutonomyGateError {
            if case .toolDenied(let reason, let remedy) = gate {
                if let remedy { object["remedy"] = remedy }
                object["gate_reason"] = .string(ChatSecretRedactor.redactText(reason))
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

    /// The trace's failure/open/completed status projection.
    package static func statusWord(_ output: JSONValue, verdict: ExactResultClass? = nil) -> String {
        let result = verdict ?? exactResultClass(output)
        return result == .succeeded ? "ok" : result.isFailure ? "failed" : "unknown"
    }

    /// Exact classification owns failure shape; unknown is not failure except skipped calls or needs.
    package static func outputLooksSuccessful(_ output: JSONValue, verdict: ExactResultClass? = nil) -> Bool {
        switch verdict ?? exactResultClass(output) {
        case .failed, .refused, .timeout, .cancelled: return false
        case .succeeded: return true
        case .unknown:
            guard case .object(let object) = output, case .string(let status)? = object["status"] else { return true }
            return !["skipped", "needs_input"].contains(status.lowercased())
        }
    }

    /// A synthetic cancelled slot never ran and proves neither an effect nor a failure.
    public static func wasCancelled(_ output: JSONValue) -> Bool {
        exactResultClass(output) == .cancelled
    }

    /// Waiting approval is neither failure nor progress and cannot renew the turn budget.
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
    public static func isWaitingOnPerson(_ output: JSONValue, verdict: ExactResultClass? = nil) -> Bool {
        isWaitingApproval(output) || isWaitingInteraction(output, verdict: verdict)
    }

    /// Held, unoffered, skipped and unrun cancelled calls prove neither progress nor effects.
    public static func neverRan(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        if case .string(let status)? = object["status"],
           status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "skipped" {
            return true
        }
        return object["execution"] == .string("not_run")
            || (exactResultClass(output) == .cancelled && object["effects"] == .string("none"))
            || object["held_for_results"] == .bool(true) || object["not_offered"] == .bool(true)
    }

    /// Decode current effect evidence and historical cancellation receipts.
    public static func effectsUnknown(_ output: JSONValue) -> Bool {
        guard case .object(let object) = output else { return false }
        return object["effects"] == .string("unknown") || object["effects_unknown"] == .bool(true)
    }

    /// Canonical motor read models own consequences; their tool envelopes prove transport only.
    package static func cognitiveResult(tool: String, output: JSONValue) -> CognitiveResult {
        let resultClass = exactResultClass(output)
        // Policy/input refusals remain audit failures without lowering tool confidence.
        if isDeterministicRefusal(output) {
            return .unknown
        }
        if hasCanonicalMotorOwner(tool) {
            // An admitted owner's read model alone supplies consequences;
            // before admission, exact failures still reach resident attention.
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
        // A cancelled slot never reached implementation and contributes no failure evidence.
        case .cancelled: return .unknown
        case .unknown: return .unknown
        }
    }

    /// Single-line receipt detail uses error-shaped fields, never result bodies;
    /// secrets are redacted before the cap, and absent error fields yield nil.
    package static let failureDetailLimit = 200

    package static func failureDetail(_ output: JSONValue) -> String? {
        guard case .object(let object) = output else {
            if case .string(let text) = output { return boundedDetail(text) }
            return nil
        }
        var parts: [String] = []
        func take(_ key: String, label: String? = nil) {
            guard let text = object[key]?.scalarText else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Keep distinct error/reason text once when the envelope repeats it.
            let rendered = label.map { "\($0)=\(trimmed)" } ?? trimmed
            guard !parts.contains(rendered), !parts.contains(trimmed) else { return }
            parts.append(rendered)
        }
        take("error_code", label: "code")
        take("errorCode", label: "code")
        take("failure_code", label: "code")
        if object["reason"] != object["failure_code"] { take("reason") }
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

    /// Receipt class names its evidence source; returned and thrown failures stay distinct.
    package static func receiptFailureClass(_ output: JSONValue, verdict: ExactResultClass? = nil) -> String {
        switch verdict ?? exactResultClass(output) {
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
                "file_not_found", "wrong_path_kind",
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
            // SecurityCenter denials carry authority evidence beside status=denied.
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
