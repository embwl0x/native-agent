import SwiftUI
import PersistenceCore

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
        externalStatus: String?
    ) -> State {
        guard !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        let externalDecision = externalStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if locallyResolved {
            return .resolved(decision: localDecision)
        }
        guard let externalDecision,
              !externalDecision.isEmpty,
              externalDecision != "pending" else {
            return .pending
        }
        return .resolved(decision: externalDecision)
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
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false

    private var meta: ChatMessageMetadata? { message.metadata }
    private var approvalId: String { meta?.approvalId ?? "" }

    /// The daemon's own view of this approval, so a card recreated by a
    /// re-render cannot offer a second click on an already-resolved request.
    private var externalDecision: String? {
        appModel.approvals.first(where: { $0.id == approvalId })?.status.lowercased()
    }

    private var state: InlineApprovalPresentation.State {
        InlineApprovalPresentation.state(
            approvalID: approvalId,
            locallyResolved: resolved,
            localDecision: resolvedDecision,
            externalStatus: externalDecision
        )
    }

    var body: some View {
        VStack(alignment: .leading) {
            if classicShell { classicBody } else { shellBody }
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
                case .retry, .stop: break
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
        let title = ChatShellApprovalCopy.title(message.content)
        let detail = ChatShellApprovalCopy.detail(message.content)
        var model = InlineCardModel(
            id: approvalId.isEmpty ? message.id : approvalId,
            kind: .confirm,
            target: detail,
            title: title,
            why: detail,
            primaryLabel: ChatShellApprovalCopy.approve(for: message.content),
            secondaryLabel: ChatShellApprovalCopy.decline,
            consequence: ChatShellApprovalCopy.consequence(for: message.content),
            state: .pending,
            detailsLabel: ChatShellApprovalCopy.showDraft,
            detailsBody: draftBody
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
            model.outcomeMeta = detail.isEmpty ? nil : detail
        case .unavailable:
            model.state = .unknown
            model.outcome = "I couldn't check this request"
            model.outcomeMeta = "Nothing was decided"
        }
        return model
    }

    /// The rest of the request, once. The title already carries its first line,
    /// so the disclosure never repeats it.
    private var draftBody: String? {
        let rest = message.content.split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("Action needs approval")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            Text(message.content)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            // S.7: treat as resolved if local @State says so OR if the daemon
            // no longer lists this approval as pending (prevents second-click
            // after the view is recreated by a re-render).
            let externalDecision = appModel.approvals
                .first(where: { $0.id == approvalId })?
                .status
                .lowercased()
            switch InlineApprovalPresentation.state(
                approvalID: approvalId,
                locallyResolved: resolved,
                localDecision: resolvedDecision,
                externalStatus: externalDecision
            ) {
            case .resolved(let decision):
                let approved = decision == "approved"
                let rejected = decision == "denied" || decision == "rejected"
                let badge = approved ? "Approved" : (rejected ? "Rejected" : "Resolved")
                let icon = approved ? "checkmark.circle.fill" : (rejected ? "xmark.circle.fill" : "checkmark.circle")
                Label(badge, systemImage: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(approved ? Color.green : (rejected ? Color.red : Color.secondary))
            case .pending:
                HStack(spacing: 8) {
                    Button {
                        Task { await resolve("approved") }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(resolving || approvalId.isEmpty)

                    Button {
                        Task { await resolve("denied") }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(resolving || approvalId.isEmpty)
                }
            case .unavailable:
                Label("Approval details unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            // B.3: show daemon error inline; card stays actionable
            if let err = resolveError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
        .padding(.leading, 24)
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
