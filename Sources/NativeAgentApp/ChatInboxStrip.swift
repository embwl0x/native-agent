import Cognition
import EngineRuntime
import ApprovalTransactions
import SwiftUI
import NotificationInbox
import ApprovalInbox
import AppKit
import CoreGraphics
import ScreenVision
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
import DeviceSync

// Blueprint: | `ChatInboxStrip.swift` | `InboxStripContainer`: Inbox projection; reads do not resolve |

struct InboxStripContainer<Header: View>: View {
    let sessionID: String
    let interactionBinding: InlineInteractionChatBinding
    /// Let the host place unread notes while the strip retains other chats' approvals and cards.
    @ViewBuilder let header: (InboxNotesCapsule) -> Header
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var items: [InboxItemRecord] {
        appModel.engine.inbox.items.filter {
            // Reading is not resolution; archive only the pointer when the originating interaction settles.
            $0.source == InlineInteractionDelivery.source
                ? $0.normalizedStatus != "archived"
                : $0.isUnread
        }
    }

    /// An approval born in this conversation already has its card here (its conversation door); agent-owned canon decisions never belong here.
    private var stripApprovals: [ApprovalRecord] {
        appModel.engine.approvals.records.filter {
            $0.status == "pending" && !$0.isAgentsOwnDecision && (try? $0.personOrigin)?.session != sessionID
        }
    }
    private var stripCards: [InboxItemRecord] {
        items.filter { $0.source == InlineInteractionDelivery.source && $0.chat_session_id != sessionID }
    }

    var body: some View {
        let originSessions = Set(stripCards.prefix(2).compactMap { (try? InlineInteractionDelivery.Pointer(item: $0))?.sessionID })
        VStack(alignment: .leading, spacing: 4) {
        header(InboxNotesCapsule(
            items: items.filter { $0.source != InlineInteractionDelivery.source && !$0.hasLinkedApproval },
            onAction: { id, actionID in
                try await appModel.inboxAction(id, action: actionID)
                // Reload after each successful action so unread counts update before file events and peripheral surfaces share the same state.
                await appModel.engine.inbox.refresh()
                await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
            }
        ))
        if let approvalError = appModel.engine.approvals.refreshErrorText {
            Text(approvalError).foregroundStyle(.orange)
        }
        if !stripApprovals.isEmpty || !stripCards.isEmpty {
            // Empty or answered sets must take no room over chat.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stripApprovals.prefix(2)) { approval in
                    Group {
                        if ApprovalChatCards.canResolve(approval) {
                            InlineApprovalCard(message: ChatMessage(approval: approval))
                        } else {
                            Text(ApprovalChatCards.unavailableText)
                        }
                    }
                    .padding(.bottom, 8)
                }
                ForEach(stripCards.prefix(2)) { item in
                    InteractionInboxCard(item: item, binding: interactionBinding)
                }
            }
            .padding(.horizontal, 16)
        }
        if let loadError = appModel.engine.inbox.loadError {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help("The unread-inbox read failed; items shown may be stale. The strip retries when the inbox changes.")
                .accessibilityIdentifier("inbox-strip-load-error")
        }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await appModel.engine.inbox.observe()
        }
        .task(id: originSessions) {
            for session in originSessions.sorted() {
                guard !Task.isCancelled else { return }
                await appModel.engine.transcripts.refreshCards(in: session)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { event in
            guard let session = event.object as? String, originSessions.contains(session) else { return }
            Task { await appModel.engine.transcripts.refreshCards(in: session) }
        }
    }
}
