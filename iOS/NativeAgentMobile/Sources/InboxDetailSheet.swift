import SwiftUI
import NativeAgentShared
import UserNotifications
// Blueprint: | `InboxDetailSheet.swift` | ID-resolved inbox detail and related digest navigation |

struct InboxDetailSheet: View {
    let itemID: String
    let onOpenGroup: (InboxRelatedGroup) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Group {
            if let item = iCloudSyncEngine.shared.inboxItems.first(where: { $0.id == itemID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.relativeCreatedAt.isEmpty ? item.sourceWords : "\(item.sourceWords) · \(item.relativeCreatedAt)")
                            .font(.caption)
                            .foregroundStyle(AlivePalette.secondary)
                        Text(item.title)
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(AlivePalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.body)
                                .foregroundStyle(AlivePalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 4)

                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(AlivePalette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AliveMetrics.rowInsetH)
                            .aliveCard()
                    }

                    let relatedGroups = InboxDigestGroups.groups(item: item, allItems: iCloudSyncEngine.shared.inboxItems)
                    if !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            AliveEyebrow("Related")
                            AliveCard {
                                ForEach(Array(relatedGroups.enumerated()), id: \.element.id) { index, group in
                                    if index > 0 { AliveDivider() }
                                    Button {
                                        onOpenGroup(group)
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(group.title)
                                                    .font(.body)
                                                    .foregroundStyle(AlivePalette.text)
                                                    .multilineTextAlignment(.leading)
                                                Text(AliveWords.count(group.displayCount, "item"))
                                                    .font(.footnote)
                                                    .foregroundStyle(AlivePalette.secondary)
                                            }
                                            Spacer()
                                            AliveChevron()
                                        }
                                        .aliveRow()
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            } else {
                ContentUnavailableView("Item unavailable", systemImage: "tray")
            }
            }
            .alivePageChrome(title: "Inbox Item", root: false)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}
