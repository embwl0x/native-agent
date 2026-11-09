import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatView.swift` | `ChatView`: local composer state, feed demands and mounted lifecycle; stale-panel notice leaves |

struct ChatView: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    /// Suspend hidden-page input, commands and visual work.
    @Environment(\.chatPageIsVisible) var chatPageIsVisible
    /// Simple's seeded profile omits the conversation list, Work pane and new-chat button.
    @Environment(\.layoutProfile) var layoutProfile
    var inSimple: Bool { layoutProfile == SimpleViewMode.simple }
    @FacePreference(WorkPaneState.sidebarsHiddenKey) var sidebarsHidden = false
    /// The Work pane belongs only to main chat, never Simple.
    @AppStorage(WorkPaneState.openKey) var workPaneOpen = false
    /// The app's one presenter of a card's own control: the sheet or panel it opens shows over this chat too.
    var inlineCards: CardControls { CardControls.shared }
    var draft: ChatComposerDraft { appModel.composerDraft(for: appModel.activeChatSessionId) }

    var draftSessionId: String {
        get { draft.sessionId }
    }
    var draftEditedAt: Date {
        get { draft.editedAt }
    }

    var text: String {
        get { draft.text }
        nonmutating set { draft.edit(newValue) }
    }
    var pendingAttachments: [FaceAttachment] {
        get { appModel.chatPendingAttachments[appModel.activeChatSessionId] ?? [] }
        nonmutating set { appModel.chatPendingAttachments[appModel.activeChatSessionId] = newValue }
    }

    @State var sessionSearch = ""
    @State var sessionSearchID = UUID()
    // Share one rename target between the editor and context menu so they cannot race.
    @State var renamingSessionId: String? = nil
    @State var turnCardClearanceStore = ChatTurnCardClearance()
    /// Share one open-card owner across drawing and insets.
    @State var composerCardState = ComposerShellState()
    /// Quiet reads must be distinguishable from the mounted live page.
    @Environment(\.quietOffscreenRead) var quietOffscreenRead

    @State var voiceInput = FaceVoiceInput()
    @State var voiceDraftBeforeListening = ""
    @State var voiceDraftRevision: UInt64 = 0
    /// Fence dictation writes to the conversation where recognition started.
    @State var voiceSessionId = ""
    /// Ending dictation must invalidate permission-prompt starts even across page changes.
    @State var voiceGeneration = 0
    @State var isCapturing = false
    @State var toasts = ChatToastQueue()
    @FocusState var inputFocused: Bool
    @State var transcriptLatestRequest = 0
    @State var transcriptHandle = TranscriptDocumentHandle()
    /// Retain the send latch through acceptance to prevent duplicate submissions of the held draft.
    @State var isSubmittingSend = false
    // Separate the state gate from the binding so dismissal and the destructive action cannot race into duplicate clears.
    @State var clearConfirmation = ChatClearConfirmationState()
    /// Fence navigation tasks so an older suspended click cannot overtake the latest selection.
    @State var runningSessionNavigationGeneration: UInt = 0

    var clearConfirmationBinding: Binding<Bool> {
        Binding(
            get: { clearConfirmation.isPresented },
            set: { isPresented in
                if isPresented {
                    clearConfirmation.request(sessionId: appModel.activeChatSessionId)
                } else {
                    clearConfirmation.cancel()
                }
            }
        )
    }

    var chatSessionIDs: Set<String> {
        appModel.face.slot(.sessions).select("membership", as: SessionListFace.self) { Set($0?.allIDs ?? []) }
    }

    private var layoutAvailability: SurfaceLayoutAvailability? {
        appModel.face.slot(.layout).select("chat.layout", as: LayoutFace.self) { $0?.availability }
    }

    var body: some View {
        FacePreferences(keys: [WorkPaneState.sidebarsHiddenKey, "voiceAutoRead"]) { preferenceContent }
    }

    private var preferenceContent: some View {
        GeometryReader { geometry in
            let conversationsWidth = layoutAvailability.map {
                !$0.contentNames("chat", profile: layoutProfile).isEmpty && !sidebarsHidden
                    ? NativeAgentShellLayout.conversationsWidth : 0
            } ?? 0
            let roomWidth = NativeAgentShellLayout.roomColumn
                + NativeAgentShellLayout.roomLeadingInset + NativeAgentShellLayout.roomTrailingInset
            HStack(spacing: 0) {
                if let layoutAvailability, !layoutAvailability.contentNames("chat", profile: layoutProfile).isEmpty && !sidebarsHidden {
                    shellConversationsColumn(layoutAvailability)
                }
                chatColumn
                    // Keep the detached window's minimum width as the chat floor; below it, the Work pane yields space.
                    .frame(minWidth: 380)
                    .modifier(ChatAttachmentDropTarget(
                        isEnabled: chatPageIsVisible,
                        contentTypes: ChatAttachmentTypeResolver.attachmentTypeIdentifiers + chatSessionDropTypes,
                        onDrop: { providers in
                            let attachments = providers.filter { provider in
                                ChatAttachmentTypeResolver.attachmentTypeIdentifiers.contains {
                                    provider.hasItemConformingToTypeIdentifier($0)
                                }
                            }
                            guard !attachments.isEmpty else {
                                return handlePinnedSessionDrop(providers: providers)
                            }
                            handleDrop(providers: attachments)
                            return true
                        }
                    ))
                if !inSimple && workPaneOpen {
                    // Give the reading room its width before expanding the person's saved Work width.
                    WorkPane(maximumWidth: Double(max(CGFloat(WorkPane.floorWidth), geometry.size.width - conversationsWidth - roomWidth)))
                        .layoutPriority(1)
                        .transition(NativeAgentMotion.fade)
                }
                // Offscreen quiet reads must not open the Work pane.
                if !inSimple && !quietOffscreenRead { WorkPaneAutoOpen() }
            }
        }
        .navigationTitle("Chat")
        .modifier(FaceObservation(demand: .key(.sessions)))
        .modifier(FaceObservation(demand: .key(.layout)))
        .modifier(FaceDictationObservation(input: voiceInput))
        // Use the surface's existing setup presentation so a card opens in the correct host.
        .inlineCardSetup(inlineCards, sessionID: appModel.activeChatSessionId, active: chatPageIsVisible)
        .liveOnAppear {
            // Wait for the initial responder before focusing the composer.
            DispatchQueue.main.async { if chatPageIsVisible { inputFocused = true } }
        }
        // Register only the live shell so quiet reads cannot replace its shared composer registration.
        .liveOnAppear {
            QuietSelfAdmin.shared.attach(cards: composerCardState)
        }
        .onDisappear {
            QuietSelfAdmin.shared.detachComposer(cards: composerCardState)
            endDictation()
        }
        // Dismiss cards and stop dictation on page changes even while Chat remains mounted.
        .onChange(of: chatPageIsVisible) { _, visible in
            if !visible { composerCardState.dismiss(); endDictation() }
        }
        .onChange(of: appModel.activeChatSessionId) {
            composerCardState.dismiss()
            endDictation()
        }
        // The document centres a message locator, or holds it until that message arrives.
        .onChange(of: appModel.pendingChatMessageID, initial: true) { _, messageID in
            guard let messageID else { return }
            appModel.pendingChatMessageID = nil
            transcriptHandle.reveal(messageID: messageID)
        }
        .onChange(of: chatSessionIDs) {
            // Clear rename targets that leave the list so no editor points at a dead identity.
            if let id = renamingSessionId,
               !chatSessionIDs.contains(id) {
                renamingSessionId = nil
            }
        }
        .onChange(of: voiceInput.errorMessage) {
            if let message = voiceInput.errorMessage {
                showToast(message)
                voiceInput.errorMessage = nil
            }
        }
    }

}

/// Keep retained-data failure observation in this leaf so it cannot invalidate the chat root.
struct PanelStaleNoticeView: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let notice = appModel.panelStaleNotice(for: item) {
            StalePanelNotice(text: notice)
        }
    }
}

struct StalePanelNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stale data. \(text)")
        .help(text)
    }
}
