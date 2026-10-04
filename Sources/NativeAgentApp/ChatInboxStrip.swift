import SwiftUI
import NotificationInbox
import ApprovalInbox
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
import DeviceSync
#endif

/// A failed inbox read is a distinct visible state, not an empty inbox. Keep
/// this reducer at the presentation boundary so the file-refresh path cannot
/// silently erase a previously rendered actionable item.
enum InboxStripPresentation {
    struct State: Equatable {
        var items: [InboxItemRecord]
        var loadError: String?
    }

    static func loaded(_ items: [InboxItemRecord]) -> State {
        State(items: items, loadError: nil)
    }

    static func failed(previousItems: [InboxItemRecord], errorDescription: String) -> State {
        State(items: previousItems, loadError: errorDescription)
    }
}

struct InboxStripContainer: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [InboxItemRecord] = []
    // U5 W-A item 1 (ChatView:2287): a failed inbox READ was swallowed into
    // [] — the strip rendered as "no unread items" on a corrupt/unreadable
    // inbox. Load failures now keep the last-known items and render this
    // inline error row instead of fabricating an empty strip.
    @State private var loadError: String? = nil
    @State private var reloadGeneration = 0
    @State private var approvals: [ApprovalRecord] = []
    @State private var approvalError: String?

    /// A card already posted into the open conversation shows there, once.
    private var stripApprovals: [ApprovalRecord] {
        approvals.filter { !$0.chatCardDelivered || $0.chatCardSessionId != appModel.activeChatSessionId }
    }
    private var stripCards: [InboxItemRecord] {
        items.filter { $0.source == InteractionCardDelivery.source && $0.chat_session_id != appModel.activeChatSessionId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        if let approvalError {
            Text(approvalError).foregroundStyle(.orange)
        }
        if !stripApprovals.isEmpty || !stripCards.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stripApprovals) { approval in
                        if ApprovalPayloadPreviewPresentation.canResolve(approval) {
                            InlineApprovalCard(message: approvalMessage(approval))
                        } else {
                            Text(ApprovalPayloadPreviewPresentation.unavailableText)
                        }
                    }
                    ForEach(stripCards) { item in
                        InteractionInboxCard(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 260)
        }
        if let loadError {
            Label("Inbox unavailable: \(loadError)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help("The unread-inbox read failed; items shown may be stale. The strip retries when the inbox changes.")
                .accessibilityIdentifier("inbox-strip-load-error")
        }
        InboxStripView(
            items: items.filter { $0.source != InteractionCardDelivery.source && !$0.hasLinkedApproval },
            onAction: { id, actionID in
                try await appModel.inboxAction(id, action: actionID)
                // Every successful action changes inbox state. Reload now so
                // a read item leaves the unread strip immediately instead of
                // lingering until the next poll, then publish the same state
                // to peripheral surfaces.
                await reload()
                if let inboxSnapshotWriterOverride = appModel.inboxSnapshotWriterOverride {
                    await inboxSnapshotWriterOverride()
                } else {
                    await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
                }
            }
        )
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let inboxPath = (appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                .appendingPathComponent("notifications", isDirectory: true)
                .appendingPathComponent("inbox.jsonl")
            await ViewFileRefreshTask.run(paths: [inboxPath]) {
                await reload()
            }
        }
        .onChange(of: appModel.inboxReloadGeneration) { _, _ in
            Task { await reload() }
        }
        .task {
            await ApprovalRequestsLiveRefresh.observe(approvals: appModel.engine.approvals) {
                do {
                    approvals = try await appModel.engine.approvals.list().filter { $0.status == "pending" }
                    approvalError = nil
                } catch {
                    approvalError = ApprovalLoadFailurePresentation.banner(error: error, retainedApprovalCount: approvals.count)
                }
            }
        }
        }
    }

    private func approvalMessage(_ approval: ApprovalRecord) -> ChatMessage {
        var metadata = ChatMessageMetadata()
        metadata.kind = ChatMessageMetadata.approvalPendingKind
        metadata.approvalId = approval.id
        return ChatMessage(id: approval.id, role: "tool",
            content: "\(approval.title)\n\(approval.reason)\n\(approval.payloadPreview)", metadata: metadata)
    }

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        do {
            let next = InboxStripPresentation.loaded(
                try await appModel.engine.inbox.list().filter {
                    // Reading a request is not resolving it. Delivery archives
                    // its pointer when the originating interaction settles.
                    $0.source == InteractionCardDelivery.source
                        ? $0.normalizedStatus != "archived"
                        : $0.isUnread
                }
            )
            guard generation == reloadGeneration else { return }
            items = next.items
            loadError = next.loadError
        } catch {
            // Keep last-known items — never fabricate an empty strip; the
            // inline error row above renders the real failure.
            let next = InboxStripPresentation.failed(
                previousItems: items,
                errorDescription: error.localizedDescription
            )
            guard generation == reloadGeneration else { return }
            items = next.items
            loadError = next.loadError
        }
    }
}

// PATCH-2026-05-07: chat-provider-picker Now shows Provider → Model
// dual picker. Provider list comes from /v1/providers (cached on AppModel
// as providersList). Model list narrows to whatever the SELECTED provider
// exposes — so picking Anthropic shows Claude models, picking ChatGPT
// shows GPT models, etc. Falls back to the catalog-based static list when
// no provider is matched (codex / local / etc).
