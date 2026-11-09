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
    // Composer motion must respect Reduce Motion.
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(ChatStore.self) var store
    let sync = iCloudSyncEngine.shared
    @ObservedObject var turnActivity = PhoneTurnActivity.shared
    @AppStorage(HazeColor.key) var hazeColorRaw = HazeColor.defaultValue.rawValue
    @AppStorage("chatFileAccess") var selectedFileAccess = "auto"
    @State var draft = MobileChatDraft()
    @State var sessionComposers: [String: SessionComposer] = [:]
    @State var composerSessionKey: String?
    @State var showsChatSetup = false
    @State private var historyLimit = ChatView.historyPage
    @State var showsConfiguration = false
    @State var openedAgentContactID: String?
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var sessionTabWidth: CGFloat = 156
    @State var composerIsFocused = false
    @State var transcript = MobileTranscriptHandle()
    var showLatestButton: Bool { !transcript.isAtEnd }
    @State var dismissedSyncError: String?
    @State var showsSyncConnection = false
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

    /// History gets a temporary nonclosable tab; opening history must not change Mac-owned pins.
    private var anchorSession: ChatSession? {
        guard let selectedID = store.selectedSessionID,
              selectedID != effectiveMainSessionID,
              sync.sessionNavigation?.rows.contains(where: { $0.session.id == selectedID }) != true else { return nil }
        return sync.sessions.first(where: { $0.id == selectedID && $0.archived != true })
    }

    var visiblePinnedSessionIDs: Set<String> {
        var ids = Set(sync.sessionNavigation?.rows.map { $0.session.id } ?? [])
        if let anchorSession { ids.insert(anchorSession.id) }
        return ids
    }

    /// Use the engine's working-conversation classification for history filtering; page the user's populated conversations newest first.
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
            // Both version evidence and published rows count as transcript delivery.
            .onChange(of: sync.chatTranscripts) { _, _ in
                applyPublishedTranscriptToVisibleSession()
            }
            .onChange(of: sync.sessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            .onChange(of: sync.pinnedChatSessions) { _, _ in
                reconcilePublishedChatSessions()
            }
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

                        // Derived anchor tabs have no real pin to remove, so they cannot expose a close control.
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

    /// Hold notification navigation until the current session load finishes so the two switches cannot race.
    func consumeNotifiedChatSessionIfNeeded() {
        guard !store.isSwitchingSession, let sessionID = notifiedSessionID else { return }
        notifiedSessionID = nil
        // Record explicit choice even when its session is already loaded.
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
        guard !TalkModeController.shared.isPresented else { return }
        let isInitialBinding = store.selectedSessionID == nil
            && MobileChatSelectionIntent.explicitlySelectedSessionID == nil
        guard !store.isSwitchingSession,
              !hasComposerDraft || isInitialBinding,
              !composerIsFocused || afterClearingDraft || isInitialBinding,
              !isInitialBinding || (!store.isLoading && !store.pendingExchanges.values.contains { $0.sessionID == store.selectedSessionID
                  && $0.request != nil }),
              // Session switches cancel sends; retain accepted drafts until their exact-session handoff crosses transport.
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
        followEnd()
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
                _ = try await sync.unpinChatSession(sessionId: sessionID)
                await sync.refreshChatSessionListSnapshot()
                if store.selectedSessionID == sessionID {
                    MobileChatSelectionIntent.followMain()
                    adoptMainSessionFromSnapshots()
                    store.switchToMainSession(
                        using: bridgeClient
                    )
                }
            } catch SyncError.responseUnconfirmed {
                // An expired unpin wait must not resubmit; retained action evidence and published navigation remain authoritative.
                store.errorBanner = "Closing this tab is unconfirmed. Waiting for your Mac's updated tabs."
            } catch {
                store.errorBanner = "Couldn't close that tab: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Chat actions

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

            // Keep New chat available during work; the store owns local send cancellation and composer release.
            Button {
                store.startNewSession()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .disabled(store.isSwitchingSession)

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
