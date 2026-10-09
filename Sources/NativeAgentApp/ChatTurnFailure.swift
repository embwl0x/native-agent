import Foundation
import SwiftUI
import NativeAgentCore
import NativeAgentShared
import ChatOrchestration
import ProviderRouting
import ToolRegistry
import PersistenceCore
import AppToolRuntime

/// What a failed turn provably did before it stopped, read from the turn's
/// own evidence: its tool rows, the failure's work state, and whether the
/// request ever left this Mac. Agent, fluid-glass review: a failure must say
/// what actually happened, because a blind retry can repeat a real action.
enum ChatTurnFailure: Equatable {
    /// The request never reached the model. Nothing ran.
    case notSent
    /// The model had it and stopped; no tool that changes anything ran.
    case stoppedNoActions
    /// It changed something before stopping. Names are the tools that ran;
    /// empty when the engine says steps ran but no row names them.
    case acted([String])
    /// Nothing here can say whether it finished.
    case unknown

    /// The failed tail turn and what it did, or nil when the last turn did
    /// not fail. Same tail `ChatShellTroubleState.consecutiveFailures` reads.
    static func read(_ messages: [ChatMessage]) -> (message: ChatMessage, failure: ChatTurnFailure)? {
        guard ChatShellTroubleState.consecutiveFailures(messages) > 0,
              let index = messages.lastIndex(where: { role($0) == "assistant" }) else { return nil }
        let message = messages[index]
        // From the turn's own first row: a steering message lands mid-turn as
        // a user row, and the actions before it are still this turn's.
        let turnStart = message.runId.flatMap { run in messages[..<index].firstIndex { $0.runId == run } }
            ?? messages[..<index].lastIndex(where: { role($0) == "user" }).map { $0 + 1 } ?? 0
        let toolRows = messages[turnStart..<messages.endIndex].filter { role($0) == "tool" && ran($0) }
        return (message, classify(message.metadata, toolRows: Array(toolRows)))
    }

    static func classify(_ meta: ChatMessageMetadata?, toolRows: [ChatMessage]) -> ChatTurnFailure {
        // The core already wrote "outcome unknown — inspect before retry" on
        // a rejected turn that may have run steps; the card must agree.
        if meta?.providerRefusal == true, meta?.providerRefusalDraft != true { return .unknown }
        var seen = Set<String>()
        let actions = toolRows.compactMap { actionTitle($0.metadata) }.filter { seen.insert($0).inserted }
        if !actions.isEmpty { return .acted(actions) }
        // A proven pre-dispatch refusal, or a request whose user row the core
        // never wrote (it writes that row before calling the model), cannot
        // have reached the model.
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

    /// Stamped on a synthetic failure whose request provably never left.
    static let notSentWork = "not sent"

    /// The work state a synthetic failure bubble carries, from the error the
    /// stream threw. A connection that was never made sent nothing; anything
    /// else is what the provider failure itself reports.
    static func work(for error: Error) -> String {
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

    /// The one line the card says.
    func line(model: String?) -> String {
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
        }
    }

    /// Retry repeats the whole turn, so it asks first when that could repeat
    /// something real.
    var retryNeedsConfirmation: Bool {
        switch self {
        case .notSent, .stoppedNoActions: return false
        case .acted, .unknown: return true
        }
    }

    var confirmationMessage: String {
        switch self {
        case .acted(let names) where !names.isEmpty:
            return "It already did: \(names.joined(separator: ", ")). Starting over could do that again. "
                + "Continue from here starts a new turn that is told what already ran."
        default:
            return "Part of this may already have happened. Starting over could repeat it. "
                + "Continue from here starts a new turn from the conversation so far; nothing guarantees it won't repeat a step."
        }
    }

    /// What Continue from here sends: a new turn that sees the rows above.
    static let continuePrompt =
        "Continue from where you stopped. Don't repeat any step that already ran."

    /// The tool a row ran, named for a person, or nil only when it is
    /// positively known to have just read. Fail-safe both ways: an `app` call
    /// is a read only if the engine's own app test says so
    /// (`RunawayOutputDetector.isAppReadOnly`: a registry action marked read,
    /// or a page/find read), and any other tool only if the engine's
    /// read-only dispatch test vouches for its name. Unknown, unparseable or
    /// unregistered means it acted.
    private static func actionTitle(_ meta: ChatMessageMetadata?) -> String? {
        let name = meta?.toolName ?? ""
        guard name == "app" else {
            return ParallelToolDispatch.isParallelSafe(internalToolName: name) ? nil : ToolActivityPresentation.title(name)
        }
        let json = meta?.inputJSON ?? ""
        if case .object(let fields)? = try? JSONValue.parse(Data(json.utf8)) {
            if RunawayOutputDetector.isAppReadOnly(fields) { return nil }
            return ToolActivityPresentation.title(ToolNameAliases.shown(name, input: .object(fields)).name)
        }
        // The row keeps only the first 4,000 characters of the input, so a
        // long call (a mail.send with its body) no longer parses. What was cut
        // could hold anything (a script past the cutoff), so it always counts
        // as acted; the id near the front only names it.
        return ToolActivityPresentation.title(clippedActionID(json) ?? name)
    }

    /// `"action": "<id>"` from input text that may be cut off mid-way.
    static func clippedActionID(_ json: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""action"\s*:\s*"([^"\\]+)""#),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        let id = json[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func role(_ message: ChatMessage) -> String {
        message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A tool row that never executed — a card still waiting, a declined or
    /// superseded request — did nothing.
    private static func ran(_ row: ChatMessage) -> Bool {
        guard let meta = row.metadata else { return true }
        if meta.isPendingApproval || meta.interactionMirror != nil { return false }
        let status = (meta.resultStatus ?? meta.interactionState ?? "").lowercased()
        if ["pending", "declined", "superseded", "denied", "refused", "needs_input"].contains(status) { return false }
        return ToolPillPresentation.outcome(
            toolName: meta.toolName ?? "", result: meta.resultSummary, ok: meta.ok
        ) != .refused
    }
}

extension ChatTurnFailure {
    /// THE retry decision, for every way a failed turn can be re-run (the
    /// card, the bubble's Try again, Regenerate on hover, in the context menu
    /// and for accessibility, detached panels, and her own chat.retry verb).
    /// Nil: retrying is safe, go. Otherwise the failure whose retry could
    /// repeat a real action, which must be confirmed first.
    static func retryNeedsConfirmation(for message: ChatMessage, in messages: [ChatMessage]) -> ChatTurnFailure? {
        guard let tail = read(messages), tail.message.id == message.id,
              tail.failure.retryNeedsConfirmation else { return nil }
        return tail.failure
    }
}

extension AppModel {
    /// `ChatTurnFailure.retryNeedsConfirmation` over the message's own session.
    func retryNeedsConfirmation(for message: ChatMessage) -> ChatTurnFailure? {
        let sessionId = message.sessionId ?? activeChatSessionId
        return ChatTurnFailure.retryNeedsConfirmation(
            for: message, in: engine.transcripts.messages(for: sessionId)
        )
    }

    /// Continue from here: a new turn in the failed message's session that
    /// sees the rows above it, instead of replaying the whole turn.
    func continueFailedTurn(_ message: ChatMessage) async {
        let sessionId = message.sessionId ?? activeChatSessionId
        _ = await startChatTurnForSession(ChatTurnFailure.continuePrompt, sessionId: sessionId)
    }
}

/// The one confirmation every retry path shows before re-running a turn that
/// acted or whose outcome is unknown.
struct FailedTurnRetryConfirmation: ViewModifier {
    @Binding var failure: ChatTurnFailure?
    var onRetry: () -> Void
    var onContinue: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Start this over?",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            titleVisibility: .visible,
            presenting: failure
        ) { _ in
            Button("Continue from here", action: onContinue)
            Button("Start over anyway", role: .destructive, action: onRetry)
            Button("Cancel", role: .cancel) {}
        } message: { failure in
            Text(failure.confirmationMessage)
        }
    }
}

extension EnvironmentValues {
    /// True in the main room, where the trouble card carries Retry, so the
    /// failed bubble does not draw a second one. Detached panels have no card
    /// and keep the bubble's own button.
    @Entry var troubleCardOwnsRetry = false
}
