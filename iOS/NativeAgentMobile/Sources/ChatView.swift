import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView.swift` | Conversation state, session navigation and anchor reconciliation; composes thread, composer, choices and notices |

// MARK: - View

struct ChatView: View {
    @Binding var notifiedSessionID: String?

    init(notifiedSessionID: Binding<String?> = .constant(nil)) { _notifiedSessionID = notifiedSessionID }

    @EnvironmentObject var bridgeClient: MacBridgeClient
    @EnvironmentObject var pairingStore: PairingStore
    @Environment(VoiceInputController.self) var voiceInput
    @EnvironmentObject var voiceOutput: VoiceOutputController
    @Environment(\.scenePhase) var scenePhase
    // Respect Reduce Motion on bubble entrance.
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(ChatStore.self) var store
    let sync = iCloudSyncEngine.shared
    @AppStorage(HazeColor.key) var hazeColorRaw = HazeColor.defaultValue.rawValue
    @AppStorage("chatFileAccess") var selectedFileAccess = "auto"
    @State var draft = MobileChatDraft()
    @State var sessionComposers: [String: SessionComposer] = [:]
    @State var composerSessionKey: String?
    @State var showsChatSetup = false
    @State private var historyLimit = ChatView.historyPage
    @State var showsConfiguration = false
    @State var inboxDetailID: String?
    @State var inboxGroup: InboxRelatedGroup?
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var sessionTabWidth: CGFloat = 156
    @FocusState var composerIsFocused: Bool
    @State var scrollScheduler = ChatScrollScheduler()
    @State var lastScrollAt = Date.distantPast
    @State var autoFollowChat = true
    var showLatestButton: Bool { !autoFollowChat }
    @State var dismissedSyncError: String?
    @State var showsSyncConnection = false
    @State var iCloudReplyObserverID: UUID?
    @State var iCloudRejectionObserverID: UUID?
    @State var iCloudResyncObserverID: UUID?
    @State var selectedPhotoItems: [PhotosPickerItem] = []
    @State var pendingPhotos: [PendingPhotoAttachment] = []
    @State var pendingFiles: [MultimodalAttachment] = []
    @State var showsFileImporter = false
    @State var isLoadingPhotos = false
    @State var fileLoadTask: Task<Void, Never>?
    @State var fileLoadID: UUID?
    @State var photoLoadTask: Task<Void, Never>?
    @State var photoLoadGeneration = 0
    @State var suppressNextEmptyPhotoSelection = false
    @State private var closingPinnedSessionIDs: Set<String> = []
    /// Dictation belongs to its keyed session; switching ends and discards it.
    @State var dictationSessionKey: String?
    /// Send was tapped while dictating: the send happens when the words land.
    @State var sendWhenDictationLands = false

    let maxPendingPhotos = 4

    var agentDisplayName: String {
        sync.agentDisplayName
    }

    private var chatSessionTabs: [ChatSessionTab] {
        ChatSessionTabs.make(
            mainSessionID: effectiveMainSessionID,
            mainTitle: mainSessionTitle,
            navigationRows: sync.sessionNavigation?.rows ?? [],
            openedSession: anchorSession
        )
    }

    /// An explicitly opened history thread gets a temporary, non-closable
    /// tab beside main. Opening history never changes the Mac's pin list.
    private var anchorSession: ChatSession? {
        guard let selectedID = store.selectedSessionID,
              selectedID != effectiveMainSessionID,
              sync.sessionNavigation?.rows.contains(where: { $0.session.id == selectedID }) != true else { return nil }
        return sync.sessions.first(where: { $0.id == selectedID && $0.archived != true })
    }

    /// Pin reconciliation uses the displayed IDs, including the derived anchor tab.
    var visiblePinnedSessionIDs: Set<String> {
        var ids = Set(sync.sessionNavigation?.rows.map { $0.session.id } ?? [])
        if let anchorSession { ids.insert(anchorSession.id) }
        return ids
    }

    /// History is User's own conversations that have something in them, newest
    /// first, a page (the Mac's ⌘K count) at a time behind "Show older".
    /// The engine's working-conversation classification owns bridge filtering.
    private var historySessions: [ChatSession] {
        let shown = sync.sessions.filter { session in
            return session.archived != true && session.id != effectiveMainSessionID
                && (session.messageCount ?? 0) > 0
                && session.isWorkingConversation == false
        }
        return shown.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    static let historyPage = 50

    var showsChatSessionTabs: Bool {
        store.selectedSessionID != effectiveMainSessionID
            || anchorSession != nil || sync.pinnedChatSessions.contains(where: { $0.archived != true })
    }

    private var selectedChatSessionTabID: String {
        guard let selected = store.selectedSessionID else { return "ios-main" }
        if selected == effectiveMainSessionID { return "ios-main" }
        return selected
    }

    var effectiveMainSessionID: String? {
        sync.chatAnchor?.cleanSessionId
    }

    private var mainSessionTitle: String {
        guard let mainID = effectiveMainSessionID,
              let session = sync.sessions.first(where: { $0.id == mainID }) else {
            return "iPhone"
        }
        return cleanTabTitle(session.displayTitle, fallback: "iPhone")
    }

    var body: some View {
        chatBody
            // Versions and rows in the published transcript both count as delivery.
            .onChange(of: sync.chatTranscripts) { _, _ in
                applyPublishedTranscriptToVisibleSession()
            }
            .onChange(of: sync.sessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            .onChange(of: sync.pinnedChatSessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            // Main follows the conversation User is in, including while already open.
            .onChange(of: sync.chatAnchor) { _, _ in
                adoptMainSessionFromSnapshots()
            }
            .onChange(of: hasComposerDraft) { _, hasDraft in
                if !hasDraft { adoptMainSessionFromSnapshots(afterClearingDraft: true) }
            }
            .onChange(of: composerIsFocused) { _, focused in
                if !focused { adoptMainSessionFromSnapshots() }
            }
            .onChange(of: store.queuedSends.map(\.id)) { _, _ in
                adoptMainSessionFromSnapshots(afterClearingDraft: true)
            }
            .onChange(of: store.isLoading) { _, isLoading in
                if !isLoading {
                    reconcilePublishedChatSessions()
                }
            }
            .onChange(of: store.sessionSwitchGeneration) { _, _ in
                invalidateAttachmentPreparation()
                restoreSessionComposer()
            }
            .onChange(of: store.selectedSessionID) { _, _ in
                restoreSessionComposer()
            }
    }

    var chatSessionTabsBar: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(chatSessionTabs) { tab in
                    let selected = tab.id == selectedChatSessionTabID
                    ZStack(alignment: .trailing) {
                        Button {
                            selectChatSessionTab(tab)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(tab.title)
                                    .font(.footnote.weight(selected ? .semibold : .regular))
                                    .lineLimit(accessibilitySize ? 2 : 1)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(selected ? AlivePalette.text : AlivePalette.secondary)
                            .padding(.leading, 12)
                            .padding(.trailing, tab.closableSessionID == nil ? 12 : 48)
                            .frame(width: accessibilitySize ? sessionTabWidth * (tab.kind == .main ? 112.0 / 156.0 : 1) : (tab.kind == .main ? 112 : 156))
                            .frame(minWidth: tab.kind == .main ? 112 : 156, minHeight: 44)
                            .background(selected ? AlivePalette.fill : Color.clear, in: Capsule())
                            .overlay { if selected { Capsule().strokeBorder(AlivePalette.rim, lineWidth: 1) } }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            ChatSessionTabPresentation.isSelectionDisabled(
                                isSwitchingSession: store.isSwitchingSession,
                                isClosingSession: tab.sessionID.map { closingPinnedSessionIDs.contains($0) } ?? false
                            )
                        )
                        .opacity(store.isSwitchingSession && !selected ? 0.55 : 1)
                        .accessibilityLabel(tab.title)

                        // Real pins only. The derived anchor tab has no pin to
                        // remove, so it gets no close control.
                        if let sessionID = tab.closableSessionID {
                            Button {
                                closePinnedChatSession(sessionID)
                            } label: {
                                Group {
                                    if closingPinnedSessionIDs.contains(sessionID) {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                            .disabled(
                                store.isLoading || store.isSwitchingSession
                                    || closingPinnedSessionIDs.contains(sessionID)
                            )
                            .accessibilityLabel("Close \(tab.title) tab")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cleanTabTitle(_ title: String, fallback: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }

    /// Hold a notification's conversation until the current session load finishes.
    func consumeNotifiedChatSessionIfNeeded() {
        guard !store.isSwitchingSession, let sessionID = notifiedSessionID else { return }
        notifiedSessionID = nil
        // Record the choice before skipping a redundant session load.
        if sessionID == effectiveMainSessionID {
            MobileChatSelectionIntent.followMain()
        } else {
            MobileChatSelectionIntent.selectSession(sessionID)
        }
        guard sessionID != store.selectedSessionID else { return }
        store.switchSession(
            to: sessionID,
            using: bridgeClient
        )
    }

    /// History is an explicit destination; main continuously follows the Mac.
    func adoptMainSessionFromSnapshots(afterClearingDraft: Bool = false) {
        let isInitialBinding = store.selectedSessionID == nil
            && MobileChatSelectionIntent.explicitlySelectedSessionID == nil
        guard !store.isSwitchingSession,
              !hasComposerDraft || isInitialBinding,
              !composerIsFocused || afterClearingDraft || isInitialBinding,
              !isInitialBinding || (!store.isLoading && !store.pendingExchanges.values.contains { $0.sessionID == store.selectedSessionID && $0.request != nil }),
              // Switching cancels the send task. Keep accepted drafts here
              // until their exact-session handoff has crossed the transport.
              !store.queuedSends.contains(where: {
                  $0.sessionID == store.selectedSessionID
                      && (!isInitialBinding || $0.preparedMessage != nil || $0.placeholderID != nil)
              }),
              let anchorID = sync.chatAnchor?.cleanSessionId,
              sync.sessions.contains(where: { $0.id == anchorID && $0.archived != true }) else { return }
        guard MobileChatSelectionIntent.explicitlySelectedSessionID == nil,
              store.selectedSessionID != anchorID else { return }
        if isInitialBinding {
            store.migrateQueuedSends(from: nil, to: anchorID)
        }
        store.switchSession(to: anchorID, using: bridgeClient)
    }

    private func reconcilePublishedChatSessions() {
        store.acknowledgePublishedSessions(Set(sync.sessions.map(\.id)))
        adoptMainSessionFromSnapshots()
        reconcileExternallyRemovedPinnedSession(
            afterPinnedIDs: visiblePinnedSessionIDs
        )
    }

    private func applyPublishedTranscriptToVisibleSession() {
        // Ingestion already updated the shared rows; settle the pending exchange.
        let sessionID = store.selectedSessionID ?? effectiveMainSessionID
        store.applyMacTranscriptRead(sync.transcriptRead(for: sessionID), sessionID: sessionID)
    }

    func reconcileExternallyRemovedPinnedSession(afterPinnedIDs: Set<String>) {
        guard ChatStore.shouldReturnToMainSession(
            selectedSessionID: store.selectedSessionID,
            mainSessionID: effectiveMainSessionID,
            availablePinnedSessionIDs: afterPinnedIDs,
            locallyCreatedSessionID: store.locallyCreatedSessionID,
            explicitlySelectedSessionID: MobileChatSelectionIntent.explicitlySelectedSessionID
        ) else { return }
        store.switchToMainSession(
            using: bridgeClient
        )
    }

    private func selectChatSessionTab(_ tab: ChatSessionTab) {
        autoFollowChat = true
        switch tab.kind {
        case .main:
            MobileChatSelectionIntent.followMain()
            adoptMainSessionFromSnapshots()
            store.switchToMainSession(using: bridgeClient)
        case .pinned, .anchor:
            guard let sessionID = tab.sessionID else { return }
            MobileChatSelectionIntent.selectSession(sessionID)
            store.switchSession(to: sessionID, using: bridgeClient)
        }
    }

    private func closePinnedChatSession(_ sessionID: String) {
        guard closingPinnedSessionIDs.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { closingPinnedSessionIDs.remove(sessionID) }
            do {
                do {
                    _ = try await sync.unpinChatSession(sessionId: sessionID)
                } catch SyncError.responseUnconfirmed {
                    // Unconfirmed, not failed: the Mac may not have picked it
                    // up yet. The same request (same message ID) re-checks or
                    // resends, and closing a tab twice is harmless.
                    _ = try await sync.unpinChatSession(sessionId: sessionID)
                }
                // Render the navigation published by the Mac owner after its receipt.
                await sync.refreshChatSessionListSnapshot()
                if store.selectedSessionID == sessionID {
                    MobileChatSelectionIntent.followMain()
                    adoptMainSessionFromSnapshots()
                    store.switchToMainSession(
                        using: bridgeClient
                    )
                }
            } catch SyncError.responseUnconfirmed {
                // Still unconfirmed. The request stays queued for the Mac and
                // the next pinned-list snapshot drops the tab once it lands;
                // there is nothing for the person to do yet.
            } catch {
                store.errorBanner = "Couldn't close that tab — try again."
            }
        }
    }

    // MARK: - Chat actions

    /// One glass control for everything the chat can do besides talk: a new
    /// conversation, another answer, spoken replies and the options sheet.
    var chatActionsMenu: some View {
        Menu {
            Menu("History", systemImage: "clock") {
                ForEach(historySessions.prefix(historyLimit)) { session in
                    Button {
                        MobileChatSelectionIntent.selectSession(session.id)
                        store.switchSession(to: session.id, using: bridgeClient)
                    } label: {
                        if session.id == store.selectedSessionID {
                            Label(session.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(session.displayTitle)
                        }
                        if let date = UserDisplayFormatters.parseISOTimestamp(session.updatedAt ?? session.createdAt) {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                }
                if historySessions.count > historyLimit {
                    Button("Show older", systemImage: "ellipsis") { historyLimit += Self.historyPage }
                }
            }
            .disabled(store.isSwitchingSession)

            // New chat stays available during a turn; the store cancels its local send and releases loading.
            Button {
                store.startNewSession()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .disabled(store.isSwitchingSession)

            // No reply yet, nothing to answer again: no dead item.
            if store.messages.contains(where: { $0.role == .assistant }) {
                Button {
                    store.regenerateLast(client: bridgeClient, controls: runtimeControls)
                } label: {
                    Label("Answer again", systemImage: "arrow.clockwise")
                }
                .disabled(!store.canRegenerateLast)
                .accessibilityLabel("Regenerate last response")
                .accessibilityHint("Asks the agent to answer the latest message again")
            }

            Toggle(isOn: Binding(
                get: { voiceOutput.enabled },
                set: { voiceOutput.setEnabled($0) }
            )) {
                Label("Speak replies", systemImage: "speaker.wave.2")
            }
            .accessibilityLabel(voiceOutput.enabled ? "Disable spoken replies" : "Enable spoken replies")

            Divider()

            Button {
                showsConfiguration = true
            } label: {
                Label("Chat options", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("Chat options: provider, model and processing")
        } label: {
            AliveTitleControlLabel(systemImage: "ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat actions")
        .accessibilityHint("New chat, answer again, spoken replies and chat options")
    }

}
