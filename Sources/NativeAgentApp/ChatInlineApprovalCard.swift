import ApprovalTransactions
import EngineRuntime
import SwiftUI
import ApprovalInbox
import PersistenceCore
import NativeAgentShared
// Blueprint: | `ChatInlineApprovalCard.swift` | Approval card with record-owned scope and facade decisions |

struct InlineApprovalCard: View {
    var message: ChatMessage
    @Environment(AppModel.self) private var appModel
    @State private var resolving = false
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

    /// Read the inbox owner so a recreated card cannot offer a second click on a resolved request.
    private var externalApproval: ApprovalRecord? {
        appModel.engine.approvals.records.first(where: { $0.id == approvalId })
    }

    private var approval: ApprovalRequest? {
        guard !approvalId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return externalApproval.map(ApprovalRequest.init(record:))
    }

    var body: some View {
        shellBody
        // A launch can draw before approvals load; read the inbox once before offering an unknown approval.
        .task(id: approvalId) {
            guard externalApproval == nil, !approvalId.isEmpty else { return }
            await appModel.engine.approvals.refresh()
        }
    }

    // MARK: - The shell card
    // A click is not settlement: approval must not claim the effect is done.
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

    /// Project the approval without keeping a second record.
    private var cardModel: InlineCardModel {
        let title = ChatShellApprovalCopy.title(displayContent)
        let why = ChatShellApprovalCopy.why(displayContent)
        let presentation = externalApproval.map(ApprovalCardPresentation.init(record:))
        var model = InlineCardModel(
            id: approvalId.isEmpty ? message.id : approvalId,
            kind: .confirm,
            title: title,
            why: why,
            primaryLabel: presentation?.primaryLabel ?? "Go ahead",
            secondaryLabel: ChatShellApprovalCopy.decline,
            consequence: "Not now → this request won't be approved.",
            state: .pending,
            scopeLines: presentation?.scopeLines ?? [],
            detailsLabel: "Details",
            detailsBody: ChatShellApprovalCopy.details(displayContent)
        )
        let approval = self.approval
        switch approval?.outcome ?? .unresolved {
        case .pending:
            model.state = resolving || appModel.engine.approvals.isResolving(id: approvalId) ? .running : .pending
            model.busyLabel = "Approving…"
            model.busyNote = "Sending your decision…"
        case .approved, .denied, .expired:
            model.state = approval?.outcome == .expired ? .unknown
                : (approval?.executionFailed == true ? .failed : (approval?.outcome == .denied ? .declined : .settled))
            model.outcome = approval?.decisionSummary
            model.outcomeMeta = approval?.expirationGuidance(agentName: appModel.agentDisplayName) ?? approval?.executionSummary ?? (why.isEmpty ? nil : why)
        case .unresolved:
            model.state = approval?.executionFailed == true ? .failed : .unknown
            model.outcome = "I couldn't check this request"
            model.outcomeMeta = approval?.executionSummary ?? "The decision is unavailable"
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
                coordinator: .app(), turn: ApprovalResolutionProvenance.local(decidedBy: "mac_ui").resolvingTurn,
                refreshHealth: { await appModel.loadHealthCard() }
            )
        } catch {
            // Keep failed settlement visible on the card.
            resolveError = UserFacingError.message(error, action: "record that decision")
        }
    }
}

/// Display prose as filed; it must never decide action or recipient.
enum ChatShellApprovalCopy {
    static let decline = "Not now"

    static func title(_ content: String) -> String {
        let first = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? content
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(AgentVoice.live.Subject) \(AgentVoice.live.verb("need")) a decision" : String(trimmed.prefix(120))
    }

    /// Keep metadata in details so the face explains why the person is being asked.
    static func why(_ content: String) -> String {
        // Use sentence-like reasons; lone tags are labels, not an explanation.
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

    /// Keep filed details intact while avoiding duplicate sentences on the face.
    static func details(_ content: String) -> String? {
        var seen = Set(sentences(why(content)))
        let rest = lines(content).flatMap { $0.components(separatedBy: " · ") }.compactMap { piece -> String? in
            let kept = piece.hasPrefix("{") || piece.hasPrefix("[")
                ? (seen.insert(piece).inserted ? [piece] : [])
                : sentences(piece).filter { seen.insert($0).inserted }
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }
        return rest.isEmpty ? nil : rest.joined(separator: "\n")
    }

    private static func lines(_ content: String) -> [String] {
        content.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

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
