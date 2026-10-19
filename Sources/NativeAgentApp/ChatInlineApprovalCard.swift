import ApprovalTransactions
import EngineRuntime
import SwiftUI
import ApprovalInbox
import PersistenceCore
import NativeAgentShared

// PATCH-2026-05-08: wave2-chat-ux — inline approval card for kind=approval_pending
struct InlineApprovalCard: View {
    var message: ChatMessage
    @Environment(AppModel.self) private var appModel
    @State private var resolving = false
    @State private var resolved = false
    @State private var resolvedDecision = ""
    @State private var resolveError: String? = nil

    private var meta: ChatMessageMetadata? { message.metadata }
    private var approvalId: String { meta?.approvalId ?? "" }
    private var displayContent: String {
        let tool = appModel.engine.approvals.records.first(where: { $0.id == approvalId })?.action
            ?? meta?.toolName ?? ""
        let titleEnd = message.content.firstIndex(of: "\n") ?? message.content.endIndex
        let title = ToolActivityPresentation.approvalText(String(message.content[..<titleEnd]), tool: tool)
        return title + String(message.content[titleEnd...])
    }

    /// The inbox's own view of this approval, so a card recreated by a
    /// re-render cannot offer a second click on an already-resolved request.
    private var externalApproval: ApprovalRecord? {
        appModel.engine.approvals.records.first(where: { $0.id == approvalId })
    }

    private var state: InlineApprovalPresentation.State {
        InlineApprovalPresentation.state(
            approvalID: approvalId,
            locallyResolved: resolved,
            localDecision: resolvedDecision,
            externalStatus: externalApproval?.status,
            externalDecision: externalApproval?.decision
        )
    }

    var body: some View {
        VStack(alignment: .leading) {
            shellBody
            if message.content.hasPrefix("Connect to Grok Bot?"),
               case .resolved(let decision) = state, decision == "approved" {
                GrokSecureSetupCard(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
        }
        // After a launch the chat can draw before the approvals list loads;
        // a card that doesn't know its approval reads the inbox once, so an
        // answered one never comes back asking.
        .task(id: approvalId) {
            guard externalApproval == nil, !approvalId.isEmpty else { return }
            appModel.engine.approvals.records = (try? await appModel.engine.approvals.list())
                ?? appModel.engine.approvals.records
        }
    }

    // MARK: - The shell card
    //
    // 0.4.12 cards round: the same component, in the shared inline-card
    // grammar — symbol column, title, one sentence, primary + quiet secondary,
    // and the consequence of declining. Teal is still reserved for exactly this
    // (she is waiting on you) and now lives on the primary command rather than
    // a second border colour. The message is shown ONCE: the title is its first
    // line and the rest opens in place, never both in full. A click is not
    // settlement, so an approved request reads "Approved", never "Done."
    private var shellBody: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            InlineCardView(model: cardModel) { taken in
                switch taken {
                case .primary: Task { await resolve("approved") }
                case .secondary: Task { await resolve("denied") }
                case .retry, .stop, .fullSetup: break
                }
            }
            if let resolveError {
                Text(resolveError)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.shell.approval-card")
    }

    /// The approval projected into the shared card value. Nothing is stored
    /// here that the approval itself does not already say.
    private var cardModel: InlineCardModel {
        let title = ChatShellApprovalCopy.title(displayContent)
        let why = ChatShellApprovalCopy.why(displayContent)
        let primary = ChatShellApprovalCopy.approve(for: message.content)
        var model = InlineCardModel(
            id: approvalId.isEmpty ? message.id : approvalId,
            kind: .confirm,
            title: title,
            why: why,
            primaryLabel: primary,
            secondaryLabel: ChatShellApprovalCopy.decline,
            consequence: ChatShellApprovalCopy.consequence(for: message.content),
            state: .pending,
            scopeLines: ChatShellApprovalCopy.recipient(displayContent).map { [$0] } ?? [],
            detailsLabel: primary == "Send it" ? ChatShellApprovalCopy.showDraft : "Details",
            detailsBody: ChatShellApprovalCopy.details(displayContent)
        )
        switch state {
        case .pending:
            model.state = resolving ? .running : .pending
            model.busyLabel = "Approving…"
            model.busyNote = "Sending your decision…"
        case .resolved(let decision):
            let rejected = decision == "denied" || decision == "rejected"
            let approval = externalApproval.map(ApprovalRequest.init(record:))
            model.state = approval?.isExpired == true ? .unknown
                : (approval?.executionFailed == true ? .failed : (rejected ? .declined : .settled))
            model.outcome = approval?.decisionSummary ?? (rejected ? "Denied" : (decision == "approved" ? "Approved" : "Resolved"))
            model.outcomeMeta = approval?.expirationGuidance(agentName: appModel.agentDisplayName) ?? approval?.executionSummary ?? (why.isEmpty ? nil : why)
        case .unavailable:
            model.state = .unknown
            model.outcome = "I couldn't check this request"
            model.outcomeMeta = "Nothing was decided"
        }
        return model
    }

    private func resolve(_ decision: String) async {
        guard !approvalId.isEmpty else { return }
        resolving = true
        resolveError = nil
        defer { resolving = false }
        do {
            try await appModel.engine.approvals.settleInlineCard(
                id: approvalId, decision: decision,
                coordinator: .app(dataRootOverride: appModel.dataRootOverride),
                resolutionChanged: { id, active in
                    if active { appModel.approvalResolutionInFlightIDs.insert(id) }
                    else { appModel.approvalResolutionInFlightIDs.remove(id) }
                },
                didResolve: { decision in
                    resolvedDecision = decision
                    resolved = true
                },
                refreshHealth: { await appModel.loadHealthCard() }
            )
        } catch {
            // B.3: daemon returned an error — keep card actionable
            resolveError = UserFacingError.message(error, action: "record that decision")
        }
    }
}

/// The approval card's words.
///
/// The mockup's card is an email, and its primary button reads "Send it". A
/// button that says "Send it" over an approval to DELETE something would be a
/// lie the person acts on, so the verb is chosen from the request rather than
/// hard-coded: send-shaped requests get "Send it", everything else gets the
/// neutral "Go ahead". "Not now" is constant; the fold reads "Show me the
/// draft" over a send and "Details" over everything else.
enum ChatShellApprovalCopy {
    static let decline = "Not now"
    static let showDraft = "Show me the draft"

    static func approve(for content: String) -> String {
        // The verb is read from the request's opening word only. A delete
        // that mentions an email in passing must never be labelled "Send it".
        let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let firstWord = firstLine.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "-" }).first.map(String.init) ?? ""
        let sendVerbs: Set<String> = ["send", "email", "e-mail", "mail", "message", "reply", "post", "text"]
        let destructive = ["delete", "remove", "erase", "wipe", "drop", "overwrite"]
        let lowered = content.lowercased()
        // The primary names the OUTCOME. "Connect" is the one the universal
        // agent bridge's setup card asks for by name, and it is read from the
        // opening word like every other verb here, so a request that merely
        // mentions connecting cannot claim it.
        if firstWord == "connect" { return "Connect" }
        if destructive.contains(where: lowered.contains) { return "Go ahead" }
        return sendVerbs.contains(firstWord) ? "Send it" : "Go ahead"
    }

    /// What taking the quiet option costs, in the request's own terms. Every
    /// card says this (Agent): a decline that does not state its consequence
    /// makes the person guess what they just refused. "→" is used here and
    /// nowhere else in the card grammar.
    static func consequence(for content: String) -> String {
        let lowered = content.lowercased()
        let destructive = ["delete", "remove", "erase", "wipe", "drop", "overwrite"]
        if destructive.contains(where: lowered.contains) {
            return "\(decline) → nothing is changed or removed."
        }
        let sendVerbs = ["send", "email", "e-mail", "mail", "message", "reply", "post", "text"]
        if sendVerbs.contains(where: { lowered.hasPrefix($0) }) {
            return "\(decline) → nothing leaves this Mac; I'll keep the draft."
        }
        return "\(decline) → I'll leave it alone and carry on without it."
    }

    /// The card's plain title: the first line of the request, no decoration.
    static func title(_ content: String) -> String {
        let first = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? content
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(AgentVoice.live.Subject) \(AgentVoice.live.verb("need")) a decision" : String(trimmed.prefix(120))
    }

    /// The why, for the person: the reason's opening sentence or two (the
    /// line under the title). Ids, timestamps, counters and " · "-joined
    /// metadata stay off the face — they fold into `details`.
    static func why(_ content: String) -> String {
        // The first line that reads as a sentence: a lone tag ("recurring") is a label, not the why.
        let all = lines(content)
        guard let reason = all.first(where: { $0.components(separatedBy: " · ")[0].split(separator: " ").count >= 3 }) ?? all.first,
              !reason.hasPrefix("{"), !reason.hasPrefix("[") else { return "" }
        var why = ""
        for sentence in sentences(reason.components(separatedBy: " · ")[0]) {
            guard why.isEmpty || why.count + sentence.count < 140 else { break }
            why += (why.isEmpty ? "" : " ") + sentence
        }
        return why
    }

    /// Everything after the title and the why, each sentence once, one piece
    /// per line; nil when nothing is left. What was filed stays intact.
    static func details(_ content: String) -> String? {
        var seen = Set(sentences(why(content)) + [recipient(content)].compactMap { $0 })
        let rest = lines(content).flatMap { $0.components(separatedBy: " · ") }.compactMap { piece -> String? in
            let kept = piece.hasPrefix("{") || piece.hasPrefix("[")
                ? (seen.insert(piece).inserted ? [piece] : [])
                : sentences(piece).filter { seen.insert($0).inserted }
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }
        return rest.isEmpty ? nil : rest.joined(separator: "\n")
    }

    /// Who a send goes to, on the face: a filed "To:" line, else the first
    /// `to` / `recipient(s)` / `expected_participants` / `chat_id` / `channel` value in the filed
    /// arguments (read as text, so a clipped preview still yields it).
    static func recipient(_ content: String) -> String? {
        if let line = lines(content).first(where: { $0.lowercased().hasPrefix("to: ") }) {
            return String(line.prefix(160))
        }
        let pattern = #""(?:to|recipients?|expected_participants|chat_id|channel)"\s*:\s*(\[[^\]]*\]|"[^"]*"|-?\d+)"#
        guard let regex = try? Regex(pattern), let match = content.firstMatch(of: regex),
              let value = match.output[1].substring else { return nil }
        let who = value.filter { !"[]\"".contains($0) }.trimmingCharacters(in: .whitespaces)
        return who.isEmpty ? nil : "To: " + who.prefix(160)
    }

    private static func lines(_ content: String) -> [String] {
        content.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Split after ". ", "! " or "? ".
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for char in text {
            if char == " ", let last = current.last, ".!?".contains(last) {
                out.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
