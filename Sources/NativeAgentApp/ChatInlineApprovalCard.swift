import SwiftUI
import ApprovalInbox
import PersistenceCore
import NativeAgentShared

/// The inline approval card is a safety control, so it has an explicit state
/// for missing authority rather than presenting disabled actions as though the
/// card were merely busy. This also keeps an absent/stale approvals refresh
/// from turning a still-pending request into a resolved-looking card.
enum InlineApprovalPresentation {
    enum State: Equatable {
        case unavailable
        case pending
        case resolved(decision: String)
    }

    static func state(
        approvalID: String,
        locallyResolved: Bool,
        localDecision: String,
        externalStatus: String?,
        externalDecision: String?
    ) -> State {
        guard !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        let status = externalStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if locallyResolved {
            return .resolved(decision: localDecision)
        }
        guard let status, !status.isEmpty, status != "pending" else {
            return .pending
        }
        return .resolved(decision: externalDecision?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }
}

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
            model.state = rejected ? .declined : .settled
            // "Approved" is the truth at this instant: the decision is made,
            // and proving the execution belongs to whoever runs it.
            model.outcome = rejected
                ? "Left alone — nothing was done"
                : (decision == "approved" ? "Approved" : "Resolved")
            model.outcomeMeta = why.isEmpty ? nil : why
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
            // B.3: call the typed endpoint so we catch daemon errors
            _ = try await appModel.resolveApproval(id: approvalId, decision: decision)
            resolvedDecision = decision
            resolved = true
            // S.4: refresh the global approvals list so other inline cards
            // for the same approval ID reflect the new state immediately.
            await appModel.loadHealthCard()
        } catch {
            // B.3: daemon returned an error — keep card actionable
            resolveError = error.localizedDescription
        }
    }
}
