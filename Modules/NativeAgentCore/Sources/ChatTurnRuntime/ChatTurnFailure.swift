import Foundation
import NativeAgentCore
import NativeAgentShared
import ChatSessionWork
import ProviderRouting
import ToolRegistry
import PersistenceCore
import MacControl

// Blueprint: | `ChatTurnFailure.swift` | `ChatTurnFailure`; Retry from exact dispatch/effect evidence |

public protocol ChatTurnFailureMetadata {
    var providerRefusal: Bool? { get }
    var providerRefusalDraft: Bool? { get }
    var syntheticUserRowPersisted: Bool? { get }
    var failureWork: String? { get }
    var toolName: String? { get }
    var inputJSON: String? { get }
    var isPendingApproval: Bool { get }
    var interactionMirror: (sessionID: String, interactionID: String)? { get }
    var resultStatus: String? { get }
    var interactionState: String? { get }
    var resultSummary: String? { get }
    var cancelled: Bool? { get }
    var error: String? { get }
    var partial: Bool? { get }
    var mechanicalKind: String? { get }
}

public protocol ChatTurnFailureMessage {
    associatedtype Metadata: ChatTurnFailureMetadata
    var id: String { get }
    var role: String { get }
    var runId: String? { get }
    var metadata: Metadata? { get }
}

/// Read the failed turn's tool rows, work state and dispatch evidence before retry: repeating a turn can repeat real effects.
public enum ChatTurnFailure: Equatable {
    case notSent
    case stoppedNoActions
    /// Retain unnamed actions when execution evidence says steps ran but no receipt identifies them.
    case acted([String])
    case unknown
    case classificationFailed(String)

    /// Only the same failed tail read by `consecutiveFailures` may drive this decision.
    public static func read<Message: ChatTurnFailureMessage>(_ messages: [Message]) -> (message: Message, failure: ChatTurnFailure)? {
        guard consecutiveFailures(messages) > 0,
              let index = messages.lastIndex(where: { role($0) == "assistant" }) else { return nil }
        let message = messages[index]
        // From the turn's own first row: a steering message lands mid-turn as
        // a user row, and the actions before it are still this turn's.
        let turnStart = message.runId.flatMap { run in messages[..<index].firstIndex { $0.runId == run } }
            ?? messages[..<index].lastIndex(where: { role($0) == "user" }).map { $0 + 1 } ?? 0
        let toolRows = messages[turnStart..<messages.endIndex].filter { role($0) == "tool" && ran($0) }
        return (message, classify(message.metadata, toolRows: Array(toolRows)))
    }

    public static func classify<Message: ChatTurnFailureMessage>(_ meta: Message.Metadata?, toolRows: [Message]) -> ChatTurnFailure {
        // The card must preserve the core's unknown-outcome warning when steps may have run.
        if meta?.providerRefusal == true, meta?.providerRefusalDraft != true { return .unknown }
        var seen = Set<String>()
        let actions: [String]
        do { actions = try toolRows.compactMap { try actionTitle($0.metadata) }.filter { seen.insert($0).inserted } }
        catch { return .classificationFailed(error.localizedDescription) }
        if !actions.isEmpty { return .acted(actions) }
        // Only a proven pre-dispatch refusal or an unwritten pre-model user row can establish that the model never received the request.
        if toolRows.isEmpty, meta?.providerRefusalDraft == true || meta?.syntheticUserRowPersisted == false {
            return .notSent
        }
        switch meta?.failureWork {
        case ProviderFailure.WorkState.ranPartly.rawValue:
            // Rows that only read things are the better evidence when present.
            return toolRows.isEmpty ? .acted([]) : .stoppedNoActions
        case ProviderFailure.WorkState.outcomeUnknown.rawValue:
            return .unknown
        case notSentWork:
            return toolRows.isEmpty ? .notSent : .stoppedNoActions
        case ProviderFailure.WorkState.nothingRan.rawValue:
            return .stoppedNoActions
        default:
            // No work state recorded: nothing proves no action ran.
            return .unknown
        }
    }

    public static let notSentWork = "not sent"

    /// Only a connection never made proves nothing was sent; other failures retain their provider's work evidence.
    public static func work(for error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        let neverConnected = [
            "not connected to internet", "code=-1009", "cannot connect to", "code=-1004",
            "cannot find host", "cannot resolve", "code=-1003", "code=-1006",
        ]
        if let url = error as? URLError,
           [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(url.code) {
            return notSentWork
        }
        if neverConnected.contains(where: text.contains) { return notSentWork }
        return (ProviderFailure.report(error)?.work ?? .outcomeUnknown).rawValue
    }

    public func line(model: String?) -> String {
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .notSent:
            return "Your message didn't reach \(model ?? "the model"). Nothing ran, so it's safe to try again."
        case .stoppedNoActions:
            return "\(model ?? "The model") stopped partway. No actions were taken, so it's safe to try again."
        case .acted(let names) where names.isEmpty:
            return "It stopped after some steps had already run. Trying again could run them again."
        case .acted(let names):
            return "It stopped after doing something: \(names.joined(separator: ", ")). Trying again could do it again."
        case .unknown:
            return "I can't tell whether it finished. Check what it did before trying again."
        case .classificationFailed(let cause):
            return "I can't classify what ran: \(cause). Check what it did before trying again."
        }
    }

    /// Retry repeats the whole turn, so it asks first when that could repeat
    /// something real.
    public var retryNeedsConfirmation: Bool {
        switch self {
        case .notSent, .stoppedNoActions: return false
        case .acted, .unknown, .classificationFailed: return true
        }
    }

    public var confirmationMessage: String {
        switch self {
        case .classificationFailed(let cause):
            return "I can't classify what ran: \(cause). Starting over could repeat a step. Check its outcome before continuing."
        case .acted(let names) where !names.isEmpty:
            return "It already did: \(names.joined(separator: ", ")). Starting over could do that again. "
                + "Continue from here starts a new turn that is told what already ran."
        default:
            return "Part of this may already have happened. Starting over could repeat it. "
                + "Continue from here starts a new turn from the conversation so far; nothing guarantees it won't repeat a step."
        }
    }

    public static let continuePrompt =
        "Continue from where you stopped. Don't repeat any step that already ran."

    /// Only engine-verified read-only calls are safe to repeat; unknown, unparseable or unregistered calls may have acted.
    private static func actionTitle<Metadata: ChatTurnFailureMetadata>(_ meta: Metadata?) throws -> String? {
        let name = meta?.toolName ?? ""
        guard name == "app" else {
            return ParallelToolDispatch.isParallelSafe(internalToolName: name, turn: nil) ? nil : ToolActivityPresentation.title(name)
        }
        let json = meta?.inputJSON ?? ""
        if case .object(let fields)? = try? JSONValue.parse(Data(json.utf8)) {
            if try AppActionBinding.isAppReadOnly(fields, turn: nil) { return nil }
            return ToolActivityPresentation.title(ToolNameAliases.shown(name, input: .object(fields)).name)
        }
        // Clipped arguments may hide any effect, so classify them as acted; a leading action ID can name but never disprove that effect.
        return ToolActivityPresentation.title(clippedActionID(json) ?? name)
    }

    /// Extract only the action label from input that may be clipped.
    public static func clippedActionID(_ json: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""action"\s*:\s*"([^"\\]+)""#),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        let id = json[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    public static func isFailed<Message: ChatTurnFailureMessage>(_ message: Message) -> Bool {
        if message.metadata?.cancelled == true { return false }
        return message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
            || message.metadata?.mechanicalKind == "systemRow"
    }

    public static func consecutiveFailures<Message: ChatTurnFailureMessage>(_ messages: [Message]) -> Int {
        var count = 0
        var sawAssistant = false
        for message in messages.reversed() {
            let role = role(message)
            if role == "user", !sawAssistant { break }
            guard role == "assistant" else { continue }
            sawAssistant = true
            guard isFailed(message) else { break }
            count += 1
        }
        return count
    }

    private static func role<Message: ChatTurnFailureMessage>(_ message: Message) -> String {
        message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Waiting, declined and superseded tool rows prove no execution when their own outcome explicitly says so.
    private static func ran<Message: ChatTurnFailureMessage>(_ row: Message) -> Bool {
        guard let meta = row.metadata else { return true }
        if meta.isPendingApproval || meta.interactionMirror != nil { return false }
        let status = (meta.resultStatus ?? meta.interactionState ?? "").lowercased()
        if ["pending", "declined", "superseded", "denied", "refused", "needs_input"].contains(status) { return false }
        guard let result = meta.resultSummary,
              let value = try? JSONValue.parse(Data(result.utf8)) else { return true }
        switch ChatToolOutcome.recordedResultClass(value) ?? ChatToolOutcome.exactResultClass(value) {
        case .refused: return false
        case .failed:
            if MacControlReceiptOutcome.projecting(envelope: value) == .refused { return false }
            if case .object(let fields) = value,
               string(fields["status"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "failed",
               let error = string(fields["error"]), error.hasPrefix("tool denied: "),
               fields["reason"] == .string(error) { return false }
            return true
        default: return true
        }
    }
}

public extension ChatTurnFailure {
    /// All retry surfaces share this decision: nil permits retry; possible repeated effects require confirmation.
    static func retryNeedsConfirmation<Message: ChatTurnFailureMessage>(for message: Message, in messages: [Message]) -> ChatTurnFailure? {
        guard let tail = read(messages), tail.message.id == message.id,
              tail.failure.retryNeedsConfirmation else { return nil }
        return tail.failure
    }
}
