import BackgroundWork
import ApprovalTransactions
import SwiftUI
import Observation
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import TriggerScheduler
import DeviceSync
import StandingBots
import AppKit
import PersistenceCore
import Desk
import EngineRuntime
import WorkshopExecution
import Cognition
import BackgroundLoops
import ApprovalInbox

// Blueprint: | `InboxNotesCapsule.swift` | Chat-header unread notes capsule, note selection and failed-read retries |

/// One chat-header capsule opens unread notes newest first, with detail and actions.
struct InboxNotesCapsule: View {
    let items: [InboxItemRecord]
    let onAction: @MainActor (String, String) async throws -> Void

    @State private var showsList = false
    @State private var selectedItem: InboxItemRecord?
    @State private var actionFlight = InboxRowActionFlight()
    @State private var isMarkingAll = false
    @State private var failedReads: [String: String] = [:]

    private static let rowHeight: CGFloat = 44

    var body: some View {
        // Newest first: the inbox already lists that way.
        let unread = items.filter(\.isUnread)
        ZStack {
            if !unread.isEmpty || !failedReads.isEmpty {
                Button { showsList.toggle() } label: {
                    Text(failedReads.isEmpty
                         ? "\(unread.count) \(unread.count == 1 ? "update" : "updates")"
                         : "\(failedReads.count) updates need retry")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .houseSurface(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Unread notes")
                .accessibilityLabel(failedReads.isEmpty
                                    ? "\(unread.count) unread \(unread.count == 1 ? "update" : "updates")"
                                    : "\(failedReads.count) updates could not be marked read")
                .accessibilityIdentifier("chat.notes.capsule")
                .transition(NativeAgentMotion.fade)
                .popover(isPresented: $showsList, arrowEdge: .bottom) {
                    list(unread)
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            InboxItemDetailSheet(
                item: item,
                allItems: items,
                onAction: { actionID in
                    await actionFlight.perform {
                        try await onAction(item.id, actionID)
                    }
                },
                onClose: { selectedItem = nil }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func list(_ unread: [InboxItemRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Updates")
                    .font(ShellType.labelSemibold)
                Spacer()
                // Marked read, they stay in Notifications; nothing is lost.
                Button(failedReads.isEmpty ? "Mark all read" : "Retry failed") {
                    let ids = failedReads.isEmpty ? unread.map(\.id) : failedReads.keys.sorted()
                    isMarkingAll = true
                    Task {
                        var failures: [String: String] = [:]
                        for id in ids {
                            do { try await onAction(id, "read") }
                            catch { failures[id] = error.localizedDescription }
                        }
                        failedReads = failures
                        isMarkingAll = false
                        if failures.isEmpty { showsList = false }
                    }
                }
                .disabled(isMarkingAll || actionFlight.isInFlight)
                .buttonStyle(.link)
                .font(ShellType.label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if !failedReads.isEmpty {
                Text("\(failedReads.count) updates could not be marked read. " + failedReads.keys.sorted().compactMap { failedReads[$0] }.joined(separator: "\n"))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .textSelection(.enabled)
                    .padding(12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(unread) { item in
                        Button {
                            showsList = false
                            // Let the popover close before the sheet opens.
                            DispatchQueue.main.async { selectedItem = item }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.sourceIcon)
                                    .foregroundStyle(item.severityColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(ShellType.labelSemibold)
                                        .lineLimit(1)
                                    Text(item.summary)
                                        .font(ShellType.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isMarkingAll)
                    }
                }
            }
            .frame(height: min(CGFloat(unread.count), 8) * Self.rowHeight)
        }
        .frame(width: 320)
    }
}
