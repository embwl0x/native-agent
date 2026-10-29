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

// Blueprint: | `ChatInboxStrip.swift` | `InboxStripContainer`: compact unread-note/approval/card projection; reading does not resolve and settled origins archive their pointer |

struct InboxStripContainer<Header: View>: View {
    let sessionID: String
    let interactionBinding: InlineInteractionChatBinding
    /// Fluid glass A2: unread notes are one capsule; the host places it (the
    /// chat header) and the strip keeps other chats' approvals and cards.
    @ViewBuilder let header: (InboxNotesCapsule) -> Header
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var items: [InboxItemRecord] {
        appModel.engine.inbox.items.filter {
            // Reading a request is not resolving it. Delivery archives its
            // pointer when the originating interaction settles.
            $0.source == InlineInteractionDelivery.source
                ? $0.normalizedStatus != "archived"
                : $0.isUnread
        }
    }

    /// A card already posted into the open conversation shows there, once.
    /// Her own decisions (her canon) are hers: never a card here.
    private var stripApprovals: [ApprovalRecord] {
        appModel.engine.approvals.records.filter {
            $0.status == "pending" && !$0.isAgentsOwnDecision
                && (!$0.chatCardDelivered || $0.chatCardSessionId != sessionID)
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
                // Every successful action changes inbox state. Reload now so
                // a read item leaves the unread count immediately instead of
                // lingering until the next file event, then publish the same state
                // to peripheral surfaces.
                await appModel.engine.inbox.refresh()
                await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
            }
        ))
        if let approvalError = appModel.engine.approvals.refreshErrorText {
            Text(approvalError).foregroundStyle(.orange)
        }
        if !stripApprovals.isEmpty || !stripCards.isEmpty {
            // Hugs what it holds: an empty or answered set takes no room over her chat.
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
