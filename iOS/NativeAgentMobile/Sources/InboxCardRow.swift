import SwiftUI
import NativeAgentShared
// Blueprint: | `InboxCardRow.swift` | A note of mine as a card in the conversation: its words and the actions it declares; the Inbox face reads every note |

struct InboxCardRow: View {
    let item: InboxItemRecord
    let onAction: (String) -> Void
    let onView: () -> Void

    private var actionIDs: Set<String> {
        Set(item.presentableActions.map(\.id))
    }

    private var showsArchive: Bool {
        actionIDs.contains("archive")
    }

    private var extraActions: [InboxActionRecord] {
        item.presentableActions.filter {
            !["view", "reply", "act", "archive", "dismiss", "read", "approve", "reject", "deny"].contains($0.id)
        }
    }

    private var hasApproveAction: Bool {
        actionIDs.contains("approve")
    }

    private var rejectActionID: String? {
        if actionIDs.contains("reject") { return "reject" }
        if actionIDs.contains("deny") { return "deny" }
        return nil
    }

    private var kindLine: String {
        item.relativeCreatedAt.isEmpty ? item.sourceWords : "\(item.sourceWords) · \(item.relativeCreatedAt)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if item.isUnread {
                    AliveWaitingDot()
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(kindLine)
                    .font(.caption)
                    .foregroundStyle(AlivePalette.secondary)
            }

            Text(item.title)
                .font(.body.weight(.medium))
                .foregroundStyle(AlivePalette.text)
                .fixedSize(horizontal: false, vertical: true)

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if hasApproveAction {
                        Button("Approve") { onAction("approve") }
                            .alivePrimaryButton()
                    }

                    if let rejectActionID {
                        Button("Deny") { onAction(rejectActionID) }
                            .aliveSecondaryButton()
                    }

                    // Opening detail is independent of execution; only a declared read may change card status.
                    if hasApproveAction {
                        Button("Read") {
                            onView()
                            if item.isUnread && actionIDs.contains("read") { onAction("read") }
                        }
                        .aliveSecondaryButton()
                    } else {
                        Button("Read") {
                            onView()
                            if item.isUnread && actionIDs.contains("read") { onAction("read") }
                        }
                        .alivePrimaryButton()
                    }

                    if let action = item.presentableActions.first(where: { $0.id == "act" }) {
                        Button(item.presentation?.actLabel ?? action.label) {
                            onAction("act")
                        }
                        .aliveSecondaryButton()
                    }

                    if showsArchive {
                        Button("Archive") { onAction("archive") }
                            .aliveSecondaryButton()
                    }

                    if actionIDs.contains("dismiss") {
                        Button("Dismiss") { onAction("dismiss") }
                            .aliveSecondaryButton()
                    }

                    ForEach(extraActions, id: \.id) { action in
                        Button(action.label) { onAction(action.id) }
                            .aliveSecondaryButton()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
            }
        }
        .aliveRow()
        .aliveCard()
    }
}

