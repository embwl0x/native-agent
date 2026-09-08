import SwiftUI

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
    @State private var showingDraft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if classicShell {
            classicBody
        } else {
            shellBody
        }
    }

    // MARK: - The shell card
    //
    // ui-simplify 2026-09-02 (Lane A): the same component, restyled. Teal is
    // reserved for exactly this — she is waiting on you — so the border is the
    // only teal on the page. The title is plain, the detail line carries the
    // full recipient/address (never truncated: that is the thing being
    // approved), and the draft opens in place rather than in a sheet.
    private var shellBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(NativeAgentShell.needsYou)
                Text(ChatShellApprovalCopy.title(message.content))
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 0)
            }

            let detail = ChatShellApprovalCopy.detail(message.content)
            if !detail.isEmpty {
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            switch state {
            case .resolved(let decision):
                let approved = decision == "approved"
                let rejected = decision == "denied" || decision == "rejected"
                Text(approved ? "Done." : (rejected ? "Left alone." : "Resolved."))
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            case .pending:
                HStack(spacing: 8) {
                    Button {
                        Task { await resolve("approved") }
                    } label: {
                        Text(ChatShellApprovalCopy.approve(for: message.content))
                            .font(ShellType.labelSemibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                NativeAgentShell.needsYou,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .foregroundStyle(Color(hex: 0x0B1013))
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving || approvalId.isEmpty)

                    Button {
                        Task { await resolve("denied") }
                    } label: {
                        Text(ChatShellApprovalCopy.decline)
                            .font(ShellType.labelSemibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                NativeAgentShell.softFill,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .foregroundStyle(NativeAgentShell.text)
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving || approvalId.isEmpty)

                    Button {
                        withAnimation(NativeAgentMotion.respecting(
                            .easeOut(duration: 0.15), reduceMotion: reduceMotion
                        )) { showingDraft.toggle() }
                    } label: {
                        Text(showingDraft
                            ? ChatShellApprovalCopy.hideDraft
                            : ChatShellApprovalCopy.showDraft)
                            .font(ShellType.label)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    .buttonStyle(.plain)
                }
            case .unavailable:
                Label("Approval details unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.trouble)
            }

            if showingDraft {
                Text(message.content)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            if let resolveError {
                Text(resolveError)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .background(
            NativeAgentShell.quietFill,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NativeAgentShell.needsYou.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.shell.approval-card")
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
