// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI

enum ChatSessionTabPresentation {
    static func isSelectionDisabled(isSwitchingSession: Bool, isClosingSession: Bool) -> Bool {
        isSwitchingSession || isClosingSession
    }
}
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

// MARK: - View

struct ChatView: View {
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    // PERF-2026-08-05: `@Observable` — this view body reads only `isListening`,
    // `isStarting`, `transcript`, `statusText`, `error` and `lastFinalTranscript`,
    // so the ~45Hz `audioLevel` tap write no longer invalidates the chat screen.
    @Environment(VoiceInputController.self) private var voiceInput
    @EnvironmentObject private var voiceOutput: VoiceOutputController
    @Environment(\.scenePhase) private var scenePhase
    // chat-smoothness phase 6: respect Reduce Motion on the bubble entrance.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: ChatStore
    @StateObject private var sync = iCloudSyncEngine.shared
    @AppStorage("chatModel") private var selectedModel = "gpt-5.6-sol"
    @AppStorage("chatReasoningEffort") private var selectedReasoningEffort = "high"
    @AppStorage("chatFastMode") private var selectedFastMode = false
    // U5 ABA guard (gpt-5.5 review, 2026-07-09): each pick bumps its
    // generation; a failed round-trip only reverts if ITS generation is still
    // current. A value-equality check alone can't tell "still my pick" from
    // "user moved away and back while I was in flight."
    @AppStorage("chatSurfaceSelectionGeneration") private var surfaceSelectionGeneration = 0
    // A snapshot is eventually consistent with the configure request. Keep a
    // freshly chosen set of runtime controls on screen until that snapshot
    // acknowledges the same selection instead of letting an older Mac value
    // immediately overwrite it.
    @AppStorage("chatSurfaceSelectionAwaitingSync") private var surfaceSelectionAwaitingSync = false
    @AppStorage("chatFileAccess") private var selectedFileAccess = "auto"
    @AppStorage("chatProviderId") private var selectedProviderId = ""
    @State private var inputText = ""
    @State private var scrollScheduler = ChatScrollScheduler()
    @State private var lastScrollAt = Date.distantPast
    @State private var autoFollowChat = true
    @State private var showLatestButton = false
    private let bottomAnchorID = "last-message-anchor"
    @State private var iCloudReplyObserverID: UUID?
    @State private var iCloudRejectionObserverID: UUID?
    @State private var iCloudResyncObserverID: UUID?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingPhotos: [PendingPhotoAttachment] = []
    @State private var isLoadingPhotos = false
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoLoadGeneration = 0
    @State private var suppressNextEmptyPhotoSelection = false
    @State private var closingPinnedSessionIDs: Set<String> = []

    private let maxPendingPhotos = 4
    // CloudKitDeviceTransport caps the complete encoded BridgeMessage at
    // 800 KiB. Base64 expands image bytes by roughly one third, so reserve
    // ample room for JSON, text, signatures, and controls and keep the
    // aggregate raw photo payload below 520 KiB.
    static let cloudKitPhotoPayloadBudgetBytes = 520 * 1024

    private var agentDisplayName: String {
        sync.agentDisplayName
    }

    private var chatSessionTabs: [ChatSessionTab] {
        ChatSessionTabProjection.make(
            mainSessionID: effectiveMainSessionID,
            mainTitle: mainSessionTitle,
            pinnedSessions: sync.pinnedChatSessions
        )
    }

    private var showsChatSessionTabs: Bool {
        sync.pinnedChatSessions.contains(where: { $0.archived != true })
    }

    private var selectedChatSessionTabID: String {
        guard let selected = store.selectedSessionID else { return "ios-main" }
        if selected == effectiveMainSessionID { return "ios-main" }
        return selected
    }

    private var effectiveMainSessionID: String? {
        store.mainSessionID
            ?? sync.sessions.first(where: {
                (NativeAgentICloudBridgeConstants.isMobileSourceKey($0.sourceKey)
                    || (($0.source ?? "").lowercased() == "ios" && ($0.sourceKey ?? "").isEmpty))
                    && $0.archived != true
            })?.id
    }

    private var mainSessionTitle: String {
        guard let mainID = effectiveMainSessionID,
              let session = sync.sessions.first(where: { $0.id == mainID }) else {
            return "iPhone"
        }
        return cleanTabTitle(session.displayTitle, fallback: "iPhone")
    }

    private var runtimeControls: ChatRuntimeControls {
        ChatRuntimeControls(
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            serviceTier: selectedFastMode ? "priority" : "default",
            fileAccess: ChatRuntimeControlPresentation.normalizedFileAccessID(selectedFileAccess),
            providerId: providerId(for: selectedModel)
        )
    }

    var body: some View {
        chatBody
            .onChange(of: sync.surfaceModels) { _, _ in
                adoptSurfaceModelPreferenceFromSync()
            }
            .onChange(of: sync.chatTranscripts) { _, _ in
                applyPublishedTranscriptToVisibleSession()
            }
            .onChange(of: sync.sessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            .onChange(of: sync.pinnedChatSessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            .onChange(of: store.isLoading) { _, isLoading in
                if !isLoading {
                    reconcilePublishedChatSessions()
                }
            }
    }

    private var chatBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = store.errorBanner {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error).font(.callout)
                        Spacer()
                        Button { store.dismissErrorBanner() } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Dismiss chat error")
                    }
                    .padding(10)
                    .background(.red.opacity(0.12))
                }

                // Voice input error banner
                if let voiceErr = voiceInput.error {
                    HStack {
                        Image(systemName: "mic.slash.fill")
                        Text(voiceErr).font(.callout)
                        Spacer()
                        if voiceErr.localizedCaseInsensitiveContains("permission")
                            || voiceErr.localizedCaseInsensitiveContains("settings") {
                            Button("Settings") { voiceInput.openSettings() }
                                .font(.callout.weight(.semibold))
                        }
                        Button { voiceInput.error = nil } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.14))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let speechErr = voiceOutput.error {
                    HStack {
                        Image(systemName: "speaker.slash.fill")
                        Text(speechErr).font(.callout)
                        Spacer()
                        Button { voiceOutput.error = nil } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.14))
                }

                runtimeControlsBar
                if showsChatSessionTabs {
                    chatSessionTabsBar
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        if store.messages.isEmpty {
                            AppEmptyState(
                                title: "No messages yet",
                                systemImage: "bubble.left.and.bubble.right",
                                kind: .empty,
                                description: "Say something to get started."
                            )
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
	                                ForEach(store.messages) { msg in
	                                    BubbleView(
	                                        message: msg,
	                                        streamingHint: store.streamingHint(for: msg),
	                                        isTimedOut: store.isTimedOut(msg),
	                                        onRetry: { store.retry(messageId: msg.id, client: bridgeClient) }
	                                    )
	                                    .id(msg.id.uuidString)
	                                    // phase 6: entrance animates ONLY when the
	                                    // append seam (ChatStore.send) supplies a
	                                    // transaction; removals and wholesale
	                                    // replaces (snapshot merge, session switch)
	                                    // are .identity → instant.
	                                    .transition(.asymmetric(
	                                        insertion: .opacity.combined(with: .offset(y: 8)),
	                                        removal: .identity))
	                                }
                            }
                            .padding()
                        }
                    }
                    // 2026-05-09 fix: keyboard would not dismiss when the user tapped
                    // off the textfield.  scrollDismissesKeyboard(.interactively)
                    // makes the keyboard slide down as the scroll view drags it
                    // off-screen (matches Messages.app feel); the tap-anywhere
                    // gesture below is the explicit dismiss-on-tap fallback.
                    .scrollDismissesKeyboard(.interactively)
                    .background {
                        AuroraBackground()
                            .opacity(0.3)
                    }
                    .contentShape(Rectangle())
	                    .onTapGesture {
                        // Resign first responder on the focused TextField.
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8).onChanged { _ in
                            if store.isLoading || !store.messages.isEmpty {
                                let follow = ChatFollowPresentation.userScrolledAway()
                                autoFollowChat = follow.autoFollow
                                showLatestButton = follow.showsLatest
                            }
                        }
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if showLatestButton {
                            Button {
                                let follow = ChatFollowPresentation.followLatest()
                                autoFollowChat = follow.autoFollow
                                showLatestButton = follow.showsLatest
                                scheduleScrollToBottom(proxy, animated: true, delayMilliseconds: 0, force: true)
                            } label: {
                                Label("Latest", systemImage: "arrow.down")
                                    .font(AppFont.tag)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.trailing, 14)
                            .padding(.bottom, 10)
                        }
                    }
                    .onAppear {
                        let follow = ChatFollowPresentation.followLatest()
                        autoFollowChat = follow.autoFollow
                        showLatestButton = follow.showsLatest
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 120, force: true)
                    }
                    .onChange(of: store.messages.count) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: store.messages.last?.text) {
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 16)
                    }
                    .onChange(of: store.messages.last?.isStreaming) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: store.isLoading) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    // B2: a straggler reply landed after its bubble timed out —
                    // force-scroll to it even if the user had scrolled away.
                    .onChange(of: store.scrollToBottomTick) {
                        scheduleScrollToBottom(proxy, animated: true, delayMilliseconds: 0, force: true)
                    }
                    // session-switch scroll fix 2026-05-23: parity with Mac.
                    // selectedSessionID flips on tab tap (user-intent moment)
                    // — reset autoFollow + scroll so the new session lands at
                    // bottom instead of leaving a blank chrome / stale scroll
                    // position. The blank symptom was: tap pinned tab,
                    // ScrollView empties + retains old scroll offset, new
                    // session's messages load async and arrive below the
                    // visible area; user has to manually scroll.
                    .onChange(of: store.selectedSessionID) {
                        let follow = ChatFollowPresentation.followLatest()
                        autoFollowChat = follow.autoFollow
                        showLatestButton = follow.showsLatest
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 80, force: true)
                    }
                    // Belt-and-suspenders: when the first message id changes
                    // the messages array has actually swapped (post-load),
                    // not just been emptied. Force one more scroll with
                    // enough delay for the LazyVStack to lay out the new
                    // content so we land on the real bottom.
                    .onChange(of: store.messages.first?.id) {
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 120, force: true)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        scheduleScrollToBottom(proxy, animated: false, force: true)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                        scheduleScrollToBottom(proxy, animated: false, force: true)
                    }
                }

                Divider()

                composerBar
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .animation(AppMotion.snappy, value: voiceInput.isListening)
            // Sweep R4 C11.3: iCloudSyncEngine.syncError was published and read
            // by nothing. Render-only — no retry, no new sync work.
            .macSyncErrorBanner()
            .toolbar {
                // Sweep R4 C11.4: connection state used to live on Diagnostics
                // and Settings only, so a sleeping Mac looked exactly like a
                // healthy one right up until a send timed out.
                ToolbarItem(placement: .navigationBarLeading) {
                    MacStatusChip()
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.regenerateLast(client: bridgeClient, controls: runtimeControls)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading || store.isSwitchingSession || !store.messages.contains(where: { $0.role == .assistant }))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.startNewSession()
                    } label: {
                        Image(systemName: "plus")
                    }
                    // A new-session action must never be gated by an in-flight
                    // turn on the session we're leaving — that made a stuck
                    // "working" turn also freeze the one control that recovers
                    // it (chat hang -> isLoading stuck true -> + permanently
                    // disabled). startNewSession() cancels the in-flight send and
                    // resets isLoading, so it is safe to run while loading.
                    .disabled(store.isSwitchingSession)
                    .accessibilityLabel("New chat")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    speakerButton
                }
            }
            // N5 fix (R18): subscribe to iCloud replies so assistant messages
            // arrive asynchronously when in iCloud pairing mode.
            // observeICloudReplies is a no-op in HTTP mode (useICloud=false guard).
            .onAppear {
                if selectedModel.lowercased() == "gpt-5.5" {
                    selectedModel = "gpt-5.6-sol"
                }
                adoptSurfaceModelPreferenceFromSync()
                // Wire TTS callback into store
                store.onReply = { [voiceOutput] text in
                    voiceOutput.speak(text)
                }
                if iCloudReplyObserverID == nil {
                    iCloudReplyObserverID = bridgeClient.observeICloudReplies { msg in
                        Task { @MainActor in
                            store.receiveICloudReply(msg)
                        }
                    }
                }
                if iCloudRejectionObserverID == nil {
                    iCloudRejectionObserverID = bridgeClient.observeICloudReplyRejections { rejection in
                        Task { @MainActor in
                            store.receiveICloudRejection(rejection)
                        }
                    }
                }
                // Phase 14e-iCloud HMAC self-heal: subscribe to signature_invalid_resync
                // hints so a stale-secret event triggers a refresh + replay instead
                // of the silent-drop behavior the action channel already avoids.
                store.pendingRetryClient = bridgeClient
                store.pairingStoreRef = pairingStore
                if iCloudResyncObserverID == nil {
                    iCloudResyncObserverID = bridgeClient.observeICloudResyncHints { hint in
                        Task { @MainActor in
                            store.receiveICloudResyncHint(hint, client: bridgeClient)
                        }
                    }
                }
                _ = NativeAgentDeepLinkSendHook.deliverPending(
                    to: store,
                    client: bridgeClient,
                    controls: runtimeControls
                )
                Task {
                    await bridgeClient.pollICloudRepliesNow()
                    await sync.refreshProviderControlsSnapshot()
                    await sync.refreshChatSessionListSnapshot()
                    adoptMainSessionFromSnapshots()
                    reconcileExternallyRemovedPinnedSession(
                        afterPinnedIDs: Set(sync.pinnedChatSessions.map(\.id))
                    )
                    store.refresh(using: bridgeClient, fallbackMessages: currentSnapshotMessages())
                    await MainActor.run { seedProviderIfNeeded() }
                }
                // PATCH-2026-05-11: foreground-refresh — pull latest history on appear.
            }
            // PATCH-2026-05-11: foreground-refresh — pull latest history when app foregrounds.
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await bridgeClient.pollICloudRepliesNow()
                        await sync.refreshChatSessionListSnapshot()
                        adoptMainSessionFromSnapshots()
                        reconcileExternallyRemovedPinnedSession(
                            afterPinnedIDs: Set(sync.pinnedChatSessions.map(\.id))
                        )
                        store.refresh(using: bridgeClient, fallbackMessages: currentSnapshotMessages())
                    }
                }
            }
            .onDisappear {
                guard !store.hasPendingICloudReplies && !store.isLoading else { return }
                bridgeClient.removeICloudReplyObserver(iCloudReplyObserverID)
                bridgeClient.removeICloudReplyRejectionObserver(iCloudRejectionObserverID)
                bridgeClient.removeICloudResyncHintObserver(iCloudResyncObserverID)
                iCloudReplyObserverID = nil
                iCloudRejectionObserverID = nil
                iCloudResyncObserverID = nil
            }
            // Simulator/process-argument test hook. The release target exposes
            // no URL scheme that can inject a real agent turn.
            .onReceive(NotificationCenter.default.publisher(for: .nativeagentDeepLinkSend)) { _ in
                _ = NativeAgentDeepLinkSendHook.deliverPending(
                    to: store,
                    client: bridgeClient,
                    controls: runtimeControls
                )
            }
            // Append transcript to input field when user releases mic button
            .onChange(of: voiceInput.lastFinalTranscript) { _, newValue in
                guard !newValue.isEmpty else { return }
                if inputText.isEmpty {
                    inputText = newValue
                } else {
                    inputText += " " + newValue
                }
            }
            .onChange(of: selectedPhotoItems) { _, items in
                if items.isEmpty && suppressNextEmptyPhotoSelection {
                    suppressNextEmptyPhotoSelection = false
                    return
                }
                loadPhotoAttachments(items)
            }
        }
    }

    // MARK: - Composer

    private var composerBar: some View {
        VStack(spacing: 8) {
            if voiceInput.isListening || voiceInput.isStarting {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(NativeAgentPalette.agentAccent)
                    Text(voiceInput.transcript.isEmpty ? (voiceInput.statusText ?? "Listening") : voiceInput.transcript)
                        .font(AppFont.body.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .frame(height: 28)
                .padding(.horizontal, 4)
            }
            if !pendingPhotos.isEmpty || isLoadingPhotos {
                pendingPhotoStrip
            }
            if !store.queuedSendsForSelectedSession.isEmpty {
                queuedSendStrip
            }

            HStack(spacing: 8) {
                photosPickerButton

                TextField("Message \(agentDisplayName)…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18))
                    .submitLabel(.send)
                    .onSubmit { submitMessage() }
                    .disabled(store.isSwitchingSession)

                micButton
                    .disabled(store.isSwitchingSession)

                if store.isLoading {
                    Button {
                        store.stop(client: bridgeClient)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.red, in: Circle())
                    }
                    .accessibilityLabel("Stop generation")
                }

                Button {
                    submitMessage()
                } label: {
                    let active = canSend && !store.isSwitchingSession
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background {
                            ZStack {
                                Circle().fill(Color.gray)
                                Circle().fill(NativeAgentPalette.agentGradient).opacity(active ? 1 : 0)
                            }
                            // phase 6: send-control micro-feedback — fade the
                            // enabled/sending fills instead of popping. Bound to
                            // the two discrete state flags (canSend/isLoading),
                            // not content. reduceMotion → nil (instant swap).
                            .animation(
                                AppMotion.respecting(AppMotion.snappy, reduceMotion: reduceMotion),
                                value: active)
                        }
                }
                .disabled(!canSend || store.isSwitchingSession)
                .accessibilityLabel(store.isLoading ? "Queue message to send next" : "Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingPhotos.isEmpty
    }

    private var queuedSendStrip: some View {
        let turns = store.queuedSendsForSelectedSession
        let next = turns[0]
        let primaryAction = QueuedSendStripAction.resolve(
            id: next.id,
            isLoading: store.isLoading
        )
        return HStack(spacing: 7) {
            Image(systemName: store.isSelectedQueuePaused
                  ? "pause.fill"
                  : "text.line.last.and.arrowtriangle.forward")
                .foregroundStyle(NativeAgentPalette.agentAccent)

            Text(store.isSelectedQueuePaused ? "Paused" : "Next")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(next.preview)
                .font(AppFont.tag)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, queued in
                    let action = QueuedSendStripAction.resolve(
                        id: queued.id,
                        isLoading: store.isLoading
                    )
                    Button {
                        action.apply(
                            onSteer: { store.sendQueuedNow($0, client: bridgeClient) },
                            onSend: { store.resumeQueuedSends(startingWith: $0) }
                        )
                    } label: {
                        Label(action.menuTitle(position: index + 1, preview: queued.preview), systemImage: "arrow.up")
                    }
                    Button(role: .destructive) {
                        store.removeQueuedSend(queued.id)
                    } label: {
                        Label("Remove \(index + 1): \(queued.preview)", systemImage: "xmark")
                    }
                    if index < turns.count - 1 { Divider() }
                }
            } label: {
                Text("\(turns.count) queued")
                    .font(AppFont.tag)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .accessibilityLabel("Show all \(turns.count) queued messages")

            Button(primaryAction.primaryTitle) {
                primaryAction.apply(
                    onSteer: { store.sendQueuedNow($0, client: bridgeClient) },
                    onSend: { store.resumeQueuedSends(startingWith: $0) }
                )
            }
            .buttonStyle(.borderless)

            Button {
                store.removeQueuedSend(next.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove next queued message")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(NativeAgentPalette.agentAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send-next queue, \(turns.count) queued")
    }

    private var pendingPhotoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isLoadingPhotos {
                    Label("Loading photos", systemImage: "photo")
                        .font(AppFont.tag)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6), in: Capsule())
                }
                ForEach(pendingPhotos) { photo in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        Button {
                            let removal = PendingPhotoPresentation.removing(photo.id, from: pendingPhotos)
                            pendingPhotos = removal.photos
                            if removal.clearsPicker {
                                selectedPhotoItems = []
                            }
                            suppressNextEmptyPhotoSelection = removal.suppressesNextEmptySelection
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.58))
                        }
                        .offset(x: 6, y: -6)
                    }
                    .accessibilityLabel("Attached photo")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Runtime controls

    private var chatSessionTabsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
                                    .font(AppFont.tag.weight(selected ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(selected ? NativeAgentPalette.agentAccent : .primary)
                            .padding(.leading, 10)
                            .padding(.trailing, tab.kind == .main ? 10 : 30)
                            .frame(width: tab.kind == .main ? 112 : 156, height: 32)
                            .background {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(
                                            selected
                                                ? AnyShapeStyle(.ultraThinMaterial)
                                                : AnyShapeStyle(Color(.secondarySystemGroupedBackground).opacity(0.5))
                                        )
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selected ? NativeAgentPalette.agentAccent.opacity(0.12) : Color.clear)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                Capsule(style: .continuous)
                                    .fill(
                                        selected
                                            ? AnyShapeStyle(NativeAgentPalette.agentGradient)
                                            : AnyShapeStyle(Color.clear)
                                    )
                                    .frame(height: 2)
                                    .padding(.horizontal, 12)
                            }
                            .shadow(color: selected ? Color.black.opacity(0.06) : .clear, radius: 3, y: 1)
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

                        if case .pinned(let sessionID) = tab.kind {
                            Button {
                                closePinnedChatSession(sessionID)
                            } label: {
                                if closingPinnedSessionIDs.contains(sessionID) {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 32)
                                        .contentShape(Rectangle())
                                }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) {
            // ui-polish 2026-05-22 — softer 0.5pt divider so the tab strip
            // layers cleanly into the chat shell instead of banding it.
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    /// PhotosPicker's label is an escaping @Sendable closure, so it cannot
    /// reference the MainActor-isolated `isLoadingPhotos` directly. Reading it
    /// into a local `Bool` (a Sendable value) before building the label means
    /// the closure captures the value, not `self`.
    private var photosPickerButton: some View {
        let loading = isLoadingPhotos
        return PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: maxPendingPhotos,
            matching: .images
        ) {
            Image(systemName: loading ? "hourglass" : "photo.on.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(loading ? .secondary : NativeAgentPalette.agentAccent)
                .frame(width: 44, height: 44)
                .background(Color(.systemGray5), in: Circle())
        }
        .disabled(store.isLoading || store.isSwitchingSession || loading)
        .accessibilityLabel("Add photos")
    }

    private var runtimeControlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(selectableProviders) { provider in
                        Button {
                            selectProvider(provider.provider_id)
                        } label: {
                            Label(provider.display_name, systemImage: provider.provider_id == selectedProviderId ? "checkmark" : "server.rack")
                        }
                    }
                } label: {
                    controlPill(icon: "server.rack", title: providerLabel(selectedProviderId))
                }

                Menu {
                    ForEach(availableModelIDs, id: \.self) { model in
                        Button {
                            // Optimistic set, then confirm against the Mac. If the
                            // iCloud round-trip fails the pick used to stay on screen
                            // until a later snapshot silently reverted it; now we undo
                            // it here and say why.
                            let previous = selectedModel
                            let previousEffort = selectedReasoningEffort
                            let previousFastMode = selectedFastMode
                            let previousProvider = selectedProviderId
                            selectedModel = model
                            reconcileExecutionControlsForSelectedModel()
                            let requestedProvider = selectedProviderId
                            let requestedEffort = selectedReasoningEffort
                            let myGeneration = beginSurfaceSelectionUpdate()
                            Task {
                                let result = await ChatRuntimeControlPresentation.execute(
                                    defaults: .standard,
                                    previous: .init(providerID: previousProvider, model: previous, reasoningEffort: previousEffort, fastMode: previousFastMode),
                                    requested: .init(providerID: requestedProvider, model: model, reasoningEffort: requestedEffort, fastMode: selectedFastMode),
                                    requestGeneration: myGeneration
                                ) { requested in
                                    _ = try await sync.configureSurfaceSelection(
                                        surface: "ios",
                                        providerId: requested.providerID,
                                        model: requested.model,
                                        reasoningEffort: requested.reasoningEffort,
                                        serviceTier: requested.fastMode ? "priority" : "default"
                                    )
                                }
                                if let restored = result.restored {
                                    // Only undo if no NEWER pick happened while this
                                    // round-trip was in flight — generation, not value:
                                    // the user may have moved away and back (ABA).
                                    selectedModel = restored.model
                                    selectedReasoningEffort = restored.reasoningEffort
                                    selectedFastMode = restored.fastMode
                                    selectedProviderId = restored.providerID
                                }
                                if let error = result.error {
                                    finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                                    iOSSystemToastCenter.shared.push(
                                        error: "Couldn't switch to \(modelLabel(model)): \(error.localizedDescription)"
                                    )
                                }
                            }
                        } label: {
                            Label(modelLabel(model), systemImage: selectedModel == model ? "checkmark" : "cpu")
                        }
                    }
                    Divider()
                    Button {
                        Task {
                            await ChatRuntimeControlPresentation.refreshModels(
                                refresh: { await sync.refreshProviderControlsSnapshot() },
                                presentError: { iOSSystemToastCenter.shared.push(error: $0) }
                            )
                        }
                    } label: {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                } label: {
                    controlPill(icon: "cpu", title: modelLabel(selectedModel))
                }

                Menu {
                    ForEach(reasoningOptions, id: \.id) { option in
                        Button {
                            let previousModel = selectedModel
                            let previous = selectedReasoningEffort
                            let previousFastMode = selectedFastMode
                            let previousProvider = selectedProviderId
                            selectedReasoningEffort = option.id
                            let requestedModel = selectedModel
                            let requestedProvider = selectedProviderId
                            let requestedServiceTier = selectedFastMode ? "priority" : "default"
                            let myGeneration = beginSurfaceSelectionUpdate()
                            Task {
                                do {
                                    _ = try await sync.configureSurfaceSelection(
                                        surface: "ios",
                                        providerId: requestedProvider,
                                        model: requestedModel,
                                        reasoningEffort: option.id,
                                        serviceTier: requestedServiceTier
                                    )
                                } catch {
                                    finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                                    // Generation, not value (ABA) — see model menu above.
                                    if let restored = ChatRuntimeControlPresentation.rollback(
                                        currentGeneration: surfaceSelectionGeneration,
                                        requestGeneration: myGeneration,
                                        previous: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previous, fastMode: previousFastMode)
                                    ) {
                                        selectedModel = restored.model
                                        selectedReasoningEffort = restored.reasoningEffort
                                        selectedFastMode = restored.fastMode
                                        selectedProviderId = restored.providerID
                                    }
                                    iOSSystemToastCenter.shared.push(
                                        error: "Couldn't set reasoning to \(option.label): \(error.localizedDescription)"
                                    )
                                }
                            }
                        } label: {
                            Label(option.label, systemImage: selectedReasoningEffort == option.id ? "checkmark" : "brain")
                        }
                    }
                } label: {
                    controlPill(icon: "brain", title: reasoningLabel(selectedReasoningEffort))
                }

                if selectedModelSupportsFast {
                    Toggle(isOn: Binding(
                        get: { selectedFastMode },
                        set: { enabled in
                            let previousModel = selectedModel
                            let previousEffort = selectedReasoningEffort
                            let previous = selectedFastMode
                            let previousProvider = selectedProviderId
                            selectedFastMode = enabled
                            let requestedModel = selectedModel
                            let requestedEffort = selectedReasoningEffort
                            let requestedProvider = selectedProviderId
                            let myGeneration = beginSurfaceSelectionUpdate()
                            Task {
                                do {
                                    _ = try await sync.configureSurfaceSelection(
                                        surface: "ios",
                                        providerId: requestedProvider,
                                        model: requestedModel,
                                        reasoningEffort: requestedEffort,
                                        serviceTier: enabled ? "priority" : "default"
                                    )
                                } catch {
                                    finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                                    if let restored = ChatRuntimeControlPresentation.rollback(
                                        currentGeneration: surfaceSelectionGeneration,
                                        requestGeneration: myGeneration,
                                        previous: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previousEffort, fastMode: previous)
                                    ) {
                                        selectedModel = restored.model
                                        selectedReasoningEffort = restored.reasoningEffort
                                        selectedFastMode = restored.fastMode
                                        selectedProviderId = restored.providerID
                                    }
                                    iOSSystemToastCenter.shared.push(
                                        error: "Couldn't change Fast mode: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    )) {
                        Label("Fast", systemImage: "bolt.fill")
                            .font(AppFont.tag)
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("Fast mode")
                }

                Menu {
                    ForEach(fileAccessOptions, id: \.id) { option in
                        Button {
                            selectedFileAccess = option.id
                        } label: {
                            Label(option.label, systemImage: selectedFileAccess == option.id ? "checkmark" : option.icon)
                        }
                    }
                } label: {
                    controlPill(icon: fileAccessIcon(selectedFileAccess), title: fileAccessLabel(selectedFileAccess))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        // Seed the provider pill off this small subview rather than the main
        // `body` chain — adding another modifier to body tips its expression
        // past the Swift type-checker's complexity budget (build timeout).
        // seedProviderIfNeeded() is idempotent, so repeated fires are safe.
        .onChange(of: sync.providers) { _, _ in
            seedProviderIfNeeded()
        }
    }

    private func controlPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(AppFont.tag)
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    private var selectableProviders: [ProviderInfo] {
        sync.providers
            .filter { $0.auth_status.state == "ready" }
            .sorted { $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending }
    }

    private func providerLabel(_ id: String) -> String {
        let full = sync.providers.first(where: { $0.provider_id == id })?.display_name
            ?? (id.isEmpty ? "Provider" : id)
        // Pill label only: drop the parenthetical auth flavor ("Anthropic
        // (OAuth / Setup-Token)" → "Anthropic"). The menu items keep the
        // full display_name so auth variants stay distinguishable there.
        if let paren = full.range(of: " (") {
            return String(full[..<paren.lowerBound])
        }
        return full
    }

    private var availableModelIDs: [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        if let provider = sync.providers.first(where: { $0.provider_id == selectedProviderId }) {
            for model in provider.models where !model.id.isEmpty && seen.insert(model.id).inserted {
                ids.append(model.id)
            }
        }
        if !selectedModel.isEmpty, seen.insert(selectedModel).inserted {
            ids.insert(selectedModel, at: 0)
        }
        return ids.sorted { lhs, rhs in
            if lhs == selectedModel { return true }
            if rhs == selectedModel { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func selectProvider(_ id: String) {
        let previousProvider = selectedProviderId
        let previousModel = selectedModel
        let previousEffort = selectedReasoningEffort
        let previousFastMode = selectedFastMode
        let preferred = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.4-mini", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-5", "grok-4.5"]
        guard let selected = ChatRuntimeControlPresentation.selectionForProvider(
            providerID: id,
            current: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previousEffort, fastMode: previousFastMode),
            providers: sync.providers,
            preferredModels: preferred
        ) else {
            iOSSystemToastCenter.shared.push(error: "That provider is not ready on the Mac.")
            return
        }
        selectedProviderId = selected.providerID
        selectedModel = selected.model
        selectedReasoningEffort = selected.reasoningEffort
        selectedFastMode = selected.fastMode
        let requestedModel = selectedModel
        let requestedEffort = selectedReasoningEffort
        let requestedFastMode = selectedFastMode
        let myGeneration = beginSurfaceSelectionUpdate()
        Task {
            let result = await ChatRuntimeControlPresentation.execute(
                defaults: .standard,
                previous: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previousEffort, fastMode: previousFastMode),
                requested: .init(providerID: id, model: requestedModel, reasoningEffort: requestedEffort, fastMode: requestedFastMode),
                requestGeneration: myGeneration
            ) { requested in
                _ = try await sync.configureSurfaceSelection(
                    surface: "ios",
                    providerId: requested.providerID,
                    model: requested.model,
                    reasoningEffort: requested.reasoningEffort,
                    serviceTier: requested.fastMode ? "priority" : "default"
                )
            }
            if let restored = result.restored {
                    selectedProviderId = restored.providerID
                    selectedModel = restored.model
                    selectedReasoningEffort = restored.reasoningEffort
                    selectedFastMode = restored.fastMode
            }
            if let error = result.error {
                finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                iOSSystemToastCenter.shared.push(
                    error: "Couldn't switch provider: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Ensure selectedModel belongs to `id`'s provider; if not, switch to a
    /// preferred-or-first model that provider actually offers. No-op when the
    /// provider has no models loaded yet (transient refresh), so we never clobber
    /// a valid selection with an empty snapshot, and a no-op when the model is
    /// already in-provider (so a deliberate pick is preserved).
    private func reconcileSelectedModel(forProviderId id: String) {
        guard let provider = sync.providers.first(where: { $0.provider_id == id }) else { return }
        let preferred = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.4-mini", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-5", "grok-4.5"]
        let reconciledModel = ChatRuntimeControlPresentation.modelForProvider(
            currentModel: selectedModel,
            provider: provider,
            preferredModels: preferred
        )
        guard reconciledModel != selectedModel else { return }
        selectedModel = reconciledModel
        reconcileExecutionControlsForSelectedModel()
    }

    private func seedProviderIfNeeded() {
        let ready = selectableProviders
        guard !ready.isEmpty else {
            selectedProviderId = ""
            return
        }
        // Already on a valid, still-selectable provider: keep it, but make sure
        // the model belongs to it (a refresh may have dropped the model from the
        // catalog), so the sent (model, providerId) pair is never inconsistent.
        if !selectedProviderId.isEmpty, ready.contains(where: { $0.provider_id == selectedProviderId }) {
            reconcileSelectedModel(forProviderId: selectedProviderId)
            return
        }
        // Seed prefers the active ios/chat surface provider (preserves the
        // operator's per-surface choice — matches pre-picker send behavior),
        // else the provider that owns the current model, else first ready provider.
        let activeChatProvider = sync.trustPolicy?.providerPolicy?.activePerSurface?["ios"]
            ?? sync.trustPolicy?.providerPolicy?.activePerSurface?["chat"]
        let seededProviderID = ChatRuntimeControlPresentation.seededProviderID(
            selectedProviderID: selectedProviderId,
            activeProviderID: activeChatProvider,
            model: selectedModel,
            readyProviders: ready
        )
        let preferred = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.4-mini", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-5", "grok-4.5"]
        guard let seededProviderID,
              let selection = ChatRuntimeControlPresentation.selectionForProvider(
                providerID: seededProviderID,
                current: .init(providerID: selectedProviderId, model: selectedModel, reasoningEffort: selectedReasoningEffort, fastMode: selectedFastMode),
                providers: ready,
                preferredModels: preferred
              ) else {
            selectedProviderId = ""
            return
        }
        selectedProviderId = selection.providerID
        selectedModel = selection.model
        selectedReasoningEffort = selection.reasoningEffort
        selectedFastMode = selection.fastMode
        // Keep the (provider, model) pair consistent so a send never carries a
        // model the chosen provider doesn't offer.
        reconcileExecutionControlsForSelectedModel()
    }

    private func adoptSurfaceModelPreferenceFromSync() {
        guard let preference = sync.surfaceModels["ios"] else { return }
        let resolution = ChatSurfaceModelPreferenceAdoption.resolve(
            current: .init(
                providerID: selectedProviderId,
                model: selectedModel,
                reasoningEffort: selectedReasoningEffort,
                fastMode: selectedFastMode
            ),
            preference: preference,
            awaitingAcknowledgement: surfaceSelectionAwaitingSync,
            selectableProviderIDs: Set(selectableProviders.map(\.provider_id))
        )
        surfaceSelectionAwaitingSync = resolution.awaitingAcknowledgement
        guard resolution.selection != .init(
            providerID: selectedProviderId,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: selectedFastMode
        ) else { return }
        selectedProviderId = resolution.selection.providerID
        selectedModel = resolution.selection.model
        selectedReasoningEffort = resolution.selection.reasoningEffort
        selectedFastMode = resolution.selection.fastMode
        reconcileSelectedModel(forProviderId: selectedProviderId)
        reconcileExecutionControlsForSelectedModel()
    }

    private func beginSurfaceSelectionUpdate() -> Int {
        surfaceSelectionGeneration += 1
        surfaceSelectionAwaitingSync = true
        return surfaceSelectionGeneration
    }

    private func finishSurfaceSelectionFailure(requestGeneration: Int) {
        guard surfaceSelectionGeneration == requestGeneration else { return }
        surfaceSelectionAwaitingSync = false
    }

    private var reasoningOptions: [(id: String, label: String)] {
        let all = [
            ("none", "No Think"),
            ("low", "Low Think"),
            ("medium", "Medium Think"),
            ("high", "High Think"),
            ("xhigh", "XHigh Think"),
            ("max", "Max Think"),
            ("ultra", "Ultra Think")
        ]
        guard let supported = selectedModelInfo?.supported_reasoning_efforts,
              !supported.isEmpty else { return Array(all.prefix(4)) }
        return all.filter { supported.contains($0.0) }
    }

    private var selectedModelInfo: ProviderModelInfo? {
        sync.providers
            .first(where: { $0.provider_id == selectedProviderId })?
            .models
            .first(where: { $0.id == selectedModel })
    }

    private var selectedModelSupportsFast: Bool {
        selectedModelInfo?.supports_fast == true
    }

    private func reconcileExecutionControlsForSelectedModel() {
        let reconciled = ChatRuntimeControlPresentation.reconciled(
            model: selectedModel,
            provider: sync.providers.first(where: { $0.provider_id == selectedProviderId }),
            selectedEffort: selectedReasoningEffort,
            selectedFastMode: selectedFastMode
        )
        selectedReasoningEffort = reconciled.effort
        selectedFastMode = reconciled.fastMode
    }

    private var fileAccessOptions: [(id: String, label: String, icon: String)] {
        [
            ("auto", "Auto Access", "wand.and.stars"),
            ("read_only", "Read Only", "eye"),
            ("workspace", "Workspace", "folder"),
            ("full", "Full Mac", "bolt.trianglebadge.exclamationmark")
        ]
    }

    private func modelLabel(_ id: String) -> String {
        sync.providers
            .flatMap(\.models)
            .first(where: { $0.id == id })?
            .name ?? id
    }

    private func cleanTabTitle(_ title: String, fallback: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }

    private func adoptMainSessionFromSnapshots() {
        store.adoptMainSessionIDIfNeeded(effectiveMainSessionID)
    }

    private func snapshotMessages(for sessionID: String?) -> [ChatMessage]? {
        guard let records = sync.transcriptRecords(for: sessionID) else { return nil }
        let mapped = MacBridgeClient.projectChatRecords(records)
        return mapped.isEmpty ? nil : mapped
    }

    private func currentSnapshotMessages() -> [ChatMessage]? {
        snapshotMessages(for: store.selectedSessionID ?? effectiveMainSessionID)
    }

    private func reconcilePublishedChatSessions() {
        adoptMainSessionFromSnapshots()
        reconcileExternallyRemovedPinnedSession(
            afterPinnedIDs: Set(sync.pinnedChatSessions.map(\.id))
        )
    }

    private func applyPublishedTranscriptToVisibleSession() {
        let sessionID = store.selectedSessionID ?? effectiveMainSessionID
        guard let messages = snapshotMessages(for: sessionID) else { return }
        store.applyMacTranscriptSnapshot(messages, sessionID: sessionID)
    }

    private func reconcileExternallyRemovedPinnedSession(afterPinnedIDs: Set<String>) {
        guard ChatStore.shouldReturnToMainSession(
            selectedSessionID: store.selectedSessionID,
            mainSessionID: effectiveMainSessionID,
            availablePinnedSessionIDs: afterPinnedIDs
        ) else { return }
        store.switchToMainSession(
            using: bridgeClient,
            fallbackMessages: snapshotMessages(for: effectiveMainSessionID)
        )
    }

    private func selectChatSessionTab(_ tab: ChatSessionTab) {
        let follow = ChatFollowPresentation.followLatest()
        autoFollowChat = follow.autoFollow
        showLatestButton = follow.showsLatest
        switch tab.kind {
        case .main:
            adoptMainSessionFromSnapshots()
            store.switchToMainSession(using: bridgeClient, fallbackMessages: snapshotMessages(for: tab.sessionID ?? effectiveMainSessionID))
        case .pinned:
            guard let sessionID = tab.sessionID else { return }
            store.switchSession(to: sessionID, using: bridgeClient, fallbackMessages: snapshotMessages(for: sessionID))
        }
    }

    private func closePinnedChatSession(_ sessionID: String) {
        guard closingPinnedSessionIDs.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { closingPinnedSessionIDs.remove(sessionID) }
            do {
                _ = try await sync.unpinChatSession(sessionId: sessionID)
                // The Mac response is the authority receipt. Remove the
                // mirrored row immediately; the snapshot/KVS write performed
                // before that response will then converge the durable mirror.
                sync.pinnedChatSessions.removeAll { $0.id == sessionID }
                if store.selectedSessionID == sessionID {
                    adoptMainSessionFromSnapshots()
                    store.switchToMainSession(
                        using: bridgeClient,
                        fallbackMessages: snapshotMessages(for: effectiveMainSessionID)
                    )
                }
            } catch {
                store.errorBanner = "Could not close the pinned tab: \(error.localizedDescription)"
            }
        }
    }

    private func providerId(for modelId: String) -> String {
        let activeChatProvider = sync.trustPolicy?.providerPolicy?.activePerSurface?["ios"]
            ?? sync.trustPolicy?.providerPolicy?.activePerSurface?["chat"]
        return ChatRuntimeControlPresentation.providerID(
            selectedProviderID: selectedProviderId,
            activeProviderID: activeChatProvider,
            model: modelId,
            providers: sync.providers
        )
    }

    private func reasoningLabel(_ id: String) -> String {
        reasoningOptions.first(where: { $0.id == id })?.label ?? "Think"
    }

    private func fileAccessLabel(_ id: String) -> String {
        let normalized = ChatRuntimeControlPresentation.normalizedFileAccessID(id)
        return fileAccessOptions.first(where: { $0.id == normalized })?.label ?? "Auto Access"
    }

    private func fileAccessIcon(_ id: String) -> String {
        let normalized = ChatRuntimeControlPresentation.normalizedFileAccessID(id)
        return fileAccessOptions.first(where: { $0.id == normalized })?.icon ?? "wand.and.stars"
    }

    // MARK: - Mic button

    private var micButton: some View {
        let micActive = voiceInput.isListening || voiceInput.isStarting
        return Button {
            if micActive {
                voiceInput.stop()
            } else {
                Task { await voiceInput.start() }
            }
        } label: {
            ZStack {
                if micActive {
                    Circle()
                        .strokeBorder(NativeAgentPalette.agentAccent.opacity(0.45), lineWidth: 2)
                        .frame(width: 46, height: 46)
                        .scaleEffect(1.12)
                        .animation(AppMotion.pulse, value: micActive)
                }

                Circle()
                    .fill(micActive
                          ? AnyShapeStyle(NativeAgentPalette.agentGradient)
                          : AnyShapeStyle(Color(.systemGray5)))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: micActive ? "mic.circle.fill" : "mic.fill")
                            .font(.system(size: micActive ? 18 : 16, weight: .semibold))
                            .foregroundStyle(micActive ? .white : .secondary)
                    }
                    .animation(AppMotion.snappy, value: micActive)
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(micActive ? "Stop dictation" : "Start dictation")
    }

    // MARK: - Speaker toggle

    private var speakerButton: some View {
        Button {
            voiceOutput.enabled.toggle()
        } label: {
            Image(systemName: voiceOutput.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(voiceOutput.enabled ? NativeAgentPalette.agentAccent : .secondary)
        }
        .animation(AppMotion.snappy, value: voiceOutput.enabled)
        .accessibilityLabel(voiceOutput.enabled ? "Disable spoken replies" : "Enable spoken replies")
    }

    // MARK: - Send

    private func submitMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingPhotos.map(\.attachment)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let sendText = text.isEmpty
            ? (attachments.count == 1 ? "Look at this photo." : "Look at these photos.")
            : text
        let pendingSnapshot = pendingPhotos
        let disposition = store.send(text: sendText, client: bridgeClient, controls: runtimeControls, attachments: attachments) {
            inputText = text
            if pendingPhotos.isEmpty {
                pendingPhotos = pendingSnapshot
            }
        }
        guard disposition != .rejected else { return }
        let follow = ChatFollowPresentation.followLatest()
        autoFollowChat = follow.autoFollow
        showLatestButton = follow.showsLatest
        inputText = ""
        pendingPhotos = []
        selectedPhotoItems = []
    }

    private func loadPhotoAttachments(_ items: [PhotosPickerItem]) {
        photoLoadTask?.cancel()
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        guard !items.isEmpty else {
            pendingPhotos = []
            isLoadingPhotos = false
            return
        }
        isLoadingPhotos = true
        let existingPhotoBytes = pendingPhotos.reduce(0) { $0 + $1.attachment.byteSize }
        photoLoadTask = Task {
            var loaded: [PendingPhotoAttachment] = []
            var skippedCount = 0
            var remainingBudget = max(0, Self.cloudKitPhotoPayloadBudgetBytes - existingPhotoBytes)
            let selectedItems = Array(items.prefix(maxPendingPhotos))
            for (index, item) in selectedItems.enumerated() {
                if Task.isCancelled { return }
                do {
                    let remainingCount = selectedItems.count - index
                    let photoBudget = Self.perPhotoBudget(
                        remainingBytes: remainingBudget,
                        remainingCount: remainingCount
                    )
                    guard let sourceData = try await item.loadTransferable(type: Data.self),
                          let sourceImage = UIImage(data: sourceData),
                          photoBudget > 0,
                          let jpeg = Self.preparedJPEGData(
                            from: sourceImage,
                            maxBytes: photoBudget
                          ),
                          let thumbnail = UIImage(data: jpeg)
                    else {
                        skippedCount += 1
                        continue
                    }
                    remainingBudget -= jpeg.count

                    let id = UUID().uuidString
                    let attachment = MultimodalAttachment(
                        id: id,
                        type: "image",
                        base64: jpeg.base64EncodedString(),
                        mime: "image/jpeg",
                        name: "iphone-photo-\(index + 1).jpg",
                        byteSize: jpeg.count
                    )
                    loaded.append(PendingPhotoAttachment(id: id, attachment: attachment, thumbnail: thumbnail))
                } catch {
                    await MainActor.run {
                        store.errorBanner = "Photo could not be loaded: \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run {
                guard generation == photoLoadGeneration, !Task.isCancelled else { return }
                pendingPhotos = Self.mergedPendingPhotos(existing: pendingPhotos, loaded: loaded, limit: maxPendingPhotos)
                isLoadingPhotos = false
                if let message = PhotosPickerLoadPresentation.message(
                    loadedCount: loaded.count,
                    skippedCount: skippedCount
                ) {
                    store.errorBanner = message
                }
                if loaded.isEmpty {
                    selectedPhotoItems = []
                }
            }
        }
    }

    private static func mergedPendingPhotos(
        existing: [PendingPhotoAttachment],
        loaded: [PendingPhotoAttachment],
        limit: Int
    ) -> [PendingPhotoAttachment] {
        var seen: Set<String> = []
        var merged: [PendingPhotoAttachment] = []
        for item in existing + loaded {
            let key = "\(item.attachment.name ?? item.id):\(item.attachment.byteSize):\(item.attachment.base64.prefix(64))"
            guard seen.insert(key).inserted else { continue }
            merged.append(item)
        }
        return Array(merged.suffix(limit))
    }

    static func perPhotoBudget(remainingBytes: Int, remainingCount: Int) -> Int {
        guard remainingBytes > 0, remainingCount > 0 else { return 0 }
        return remainingBytes / remainingCount
    }

    static func preparedJPEGData(
        from image: UIImage,
        maxDimension: CGFloat = 1400,
        maxBytes: Int = cloudKitPhotoPayloadBudgetBytes
    ) -> Data? {
        guard maxBytes > 0 else { return nil }
        let sourceSize = image.size
        let sourceLongest = max(sourceSize.width, sourceSize.height)
        var dimension = min(maxDimension, sourceLongest)

        while dimension >= 320 {
            let scale = sourceLongest > dimension ? dimension / sourceLongest : 1
            let targetSize = CGSize(
                width: max(1, sourceSize.width * scale),
                height: max(1, sourceSize.height * scale)
            )
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let normalized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }

            for quality in [0.78, 0.66, 0.54, 0.42, 0.32, 0.24] {
                if let data = normalized.jpegData(compressionQuality: quality),
                   data.count <= maxBytes {
                    return data
                }
            }
            dimension *= 0.78
        }
        return nil
    }

    private func scheduleScrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool = false,
        delayMilliseconds: Int = 30,
        force: Bool = false
    ) {
        guard !store.messages.isEmpty else { return }
        guard force || autoFollowChat else { return }
        guard let targetID = store.messages.last?.id else { return }
        guard let serial = scrollScheduler.schedule(
            targetID: targetID.uuidString,
            animated: animated,
            force: force
        ) else { return }
        let elapsed = Date().timeIntervalSince(lastScrollAt)
        let minimumInterval = animated ? 0.12 : 0.09
        let effectiveDelayMs = max(delayMilliseconds, Int(max(0, minimumInterval - elapsed) * 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(effectiveDelayMs)) {
            guard let currentTargetID = scrollScheduler.complete(
                serial: serial,
                messagesAreAvailable: !store.messages.isEmpty
            ) else { return }
            lastScrollAt = Date()
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(currentTargetID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(currentTargetID, anchor: .bottom)
            }
        }
    }
}

/// Pure decisions shared by ChatView's controls. Keeping these outside the
/// view makes an iPhone selection an explicit, testable value before it is
/// sent to the signed Mac route.
enum ChatRuntimeControlPresentation {
    static let fileAccessIDs = ICloudChatFileAccessPolicy.acceptedIDs

    /// Runs the model-menu refresh and surfaces every unsuccessful outcome to
    /// the person who explicitly asked for it. Background refresh callers can
    /// still ignore the returned outcome without producing unsolicited toast.
    @MainActor
    static func refreshModels(
        refresh: () async -> ProviderControlsRefreshOutcome,
        presentError: (String) -> Void
    ) async {
        if let message = (await refresh()).feedbackMessage {
            presentError(message)
        }
    }

    static func normalizedFileAccessID(_ id: String) -> String {
        ICloudChatFileAccessPolicy.normalized(id)
    }

    static func providerID(
        selectedProviderID: String,
        activeProviderID: String?,
        model: String,
        providers: [ProviderInfo]
    ) -> String {
        let ready = providers.filter { $0.auth_status.state == "ready" }
        if ready.contains(where: { $0.provider_id == selectedProviderID }) { return selectedProviderID }
        if let activeProviderID, ready.contains(where: { $0.provider_id == activeProviderID }) { return activeProviderID }
        return ready.first(where: { provider in
            provider.models.contains(where: { $0.id == model })
        })?.provider_id ?? ""
    }

    static func reconciled(
        model: String,
        provider: ProviderInfo?,
        selectedEffort: String,
        selectedFastMode: Bool
    ) -> (model: String, effort: String, fastMode: Bool) {
        let modelInfo = provider?.models.first(where: { $0.id == model })
        let allowed = modelInfo?.supported_reasoning_efforts?.filter { !$0.isEmpty }
            ?? ["none", "low", "medium", "high"]
        let preferred = modelInfo?.default_reasoning_effort ?? "high"
        let effort = allowed.contains(selectedEffort)
            ? selectedEffort
            : (allowed.contains(preferred) ? preferred : (allowed.first ?? "high"))
        return (model, effort, modelInfo?.supports_fast == true ? selectedFastMode : false)
    }

    static func modelForProvider(
        currentModel: String,
        provider: ProviderInfo?,
        preferredModels: [String]
    ) -> String {
        guard let provider else { return currentModel }
        let modelIDs = provider.models.map(\.id).filter { !$0.isEmpty }
        guard !modelIDs.isEmpty, !modelIDs.contains(currentModel) else { return currentModel }
        return preferredModels.first(where: modelIDs.contains) ?? modelIDs[0]
    }

    static func selectionForProvider(
        providerID: String,
        current: Selection,
        providers: [ProviderInfo],
        preferredModels: [String]
    ) -> Selection? {
        guard let provider = providers.first(where: {
            $0.provider_id == providerID && $0.auth_status.state == "ready"
        }) else { return nil }
        let model = modelForProvider(
            currentModel: current.model,
            provider: provider,
            preferredModels: preferredModels
        )
        let controls = reconciled(
            model: model,
            provider: provider,
            selectedEffort: current.reasoningEffort,
            selectedFastMode: current.fastMode
        )
        return Selection(
            providerID: providerID,
            model: controls.model,
            reasoningEffort: controls.effort,
            fastMode: controls.fastMode
        )
    }

    static func seededProviderID(
        selectedProviderID: String,
        activeProviderID: String?,
        model: String,
        readyProviders: [ProviderInfo]
    ) -> String? {
        guard !readyProviders.isEmpty else { return nil }
        if readyProviders.contains(where: { $0.provider_id == selectedProviderID }) { return selectedProviderID }
        if let activeProviderID, readyProviders.contains(where: { $0.provider_id == activeProviderID }) {
            return activeProviderID
        }
        return readyProviders.first(where: { $0.models.contains(where: { $0.id == model }) })?.provider_id
            ?? readyProviders[0].provider_id
    }

    static func shouldRollback(selectionGeneration: Int, requestGeneration: Int) -> Bool {
        selectionGeneration == requestGeneration
    }

    struct Selection: Equatable {
        var providerID: String
        var model: String
        var reasoningEffort: String
        var fastMode: Bool
    }

    static func rollback(
        currentGeneration: Int,
        requestGeneration: Int,
        previous: Selection
    ) -> Selection? {
        shouldRollback(selectionGeneration: currentGeneration, requestGeneration: requestGeneration)
            ? previous
            : nil
    }

    static let modelDefaultsKey = "chatModel"
    static let effortDefaultsKey = "chatReasoningEffort"
    static let fastDefaultsKey = "chatFastMode"
    static let providerDefaultsKey = "chatProviderId"
    static let generationDefaultsKey = "chatSurfaceSelectionGeneration"

    static func persist(_ selection: Selection, in defaults: UserDefaults) {
        defaults.set(selection.model, forKey: modelDefaultsKey)
        defaults.set(selection.reasoningEffort, forKey: effortDefaultsKey)
        defaults.set(selection.fastMode, forKey: fastDefaultsKey)
        defaults.set(selection.providerID, forKey: providerDefaultsKey)
    }

    /// The shared action seam behind every optimistic runtime-control menu.
    /// It intentionally observes the persisted generation after the transport
    /// result, so an older failed request cannot restore over a newer iPhone
    /// pick—even if all four values happen to match again (ABA).
    @MainActor
    static func execute(
        defaults: UserDefaults,
        previous: Selection,
        requested: Selection,
        requestGeneration: Int,
        configure: (Selection) async throws -> Void
    ) async -> (restored: Selection?, error: Error?) {
        persist(requested, in: defaults)
        do {
            try await configure(requested)
            return (nil, nil)
        } catch {
            guard defaults.integer(forKey: generationDefaultsKey) == requestGeneration else { return (nil, error) }
            persist(previous, in: defaults)
            return (previous, error)
        }
    }
}

/// Resolves an eventually-consistent surface-model snapshot without allowing a
/// stale snapshot to undo a selection the user has just sent to the Mac.
enum ChatSurfaceModelPreferenceAdoption {
    struct Selection: Equatable {
        var providerID: String
        var model: String
        var reasoningEffort: String
        var fastMode: Bool
    }

    struct Resolution: Equatable {
        var selection: Selection
        var awaitingAcknowledgement: Bool
    }

    static func resolve(
        current: Selection,
        preference: SurfaceModelPref,
        awaitingAcknowledgement: Bool,
        selectableProviderIDs: Set<String>
    ) -> Resolution {
        if awaitingAcknowledgement {
            return Resolution(
                selection: current,
                awaitingAcknowledgement: !acknowledges(current, preference: preference)
            )
        }

        var selection = current
        if let providerID = preference.providerId,
           selectableProviderIDs.contains(providerID) {
            selection.providerID = providerID
        }
        selection.model = preference.model
        if let reasoningEffort = preference.reasoningEffort {
            selection.reasoningEffort = reasoningEffort
        }
        if let serviceTier = preference.serviceTier {
            selection.fastMode = serviceTier == "priority"
        }
        return Resolution(selection: selection, awaitingAcknowledgement: false)
    }

    private static func acknowledges(_ selection: Selection, preference: SurfaceModelPref) -> Bool {
        guard preference.model == selection.model else { return false }
        if let providerID = preference.providerId, providerID != selection.providerID { return false }
        if let reasoningEffort = preference.reasoningEffort,
           reasoningEffort != selection.reasoningEffort { return false }
        if let serviceTier = preference.serviceTier,
           (serviceTier == "priority") != selection.fastMode { return false }
        return true
    }
}

enum ChatFollowPresentation {
    static func userScrolledAway() -> (autoFollow: Bool, showsLatest: Bool) { (false, true) }
    static func followLatest() -> (autoFollow: Bool, showsLatest: Bool) { (true, false) }
}

/// One pending callback is enough for a streaming burst. Each later ordinary
/// mutation replaces its target rather than scheduling another scroll, while a
/// forced/animated request supersedes the prior callback through a new serial.
struct ChatScrollScheduler: Equatable {
    private(set) var serial = 0
    private(set) var isScheduled = false
    private var pendingTargetID: String?

    mutating func schedule(targetID: String, animated: Bool, force: Bool) -> Int? {
        if isScheduled && !animated && !force {
            pendingTargetID = targetID
            return nil
        }
        serial &+= 1
        isScheduled = true
        pendingTargetID = targetID
        return serial
    }

    mutating func complete(serial: Int, messagesAreAvailable: Bool) -> String? {
        guard serial == self.serial else { return nil }
        defer {
            isScheduled = false
            pendingTargetID = nil
        }
        guard messagesAreAvailable else { return nil }
        return pendingTargetID
    }
}

enum ChatAttachmentPresentation {
    static func hasRenderableImage(_ attachment: ChatAttachmentSummary) -> Bool {
        guard attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image",
              let raw = attachment.base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: raw), !data.isEmpty else { return false }
        return UIImage(data: data) != nil
    }

    static func previewableImages(in attachments: [ChatAttachmentSummary]) -> [ChatAttachmentSummary] {
        attachments.filter(hasRenderableImage)
    }

    static func fallbackCount(in attachments: [ChatAttachmentSummary]) -> Int {
        max(0, attachments.count - previewableImages(in: attachments).count)
    }
}

enum PendingPhotoPresentation {
    struct Removal {
        var photos: [PendingPhotoAttachment]
        var clearsPicker: Bool
        var suppressesNextEmptySelection: Bool
    }

    static func removing(_ id: String, from photos: [PendingPhotoAttachment]) -> Removal {
        let remaining = photos.filter { $0.id != id }
        return Removal(
            photos: remaining,
            clearsPicker: true,
            suppressesNextEmptySelection: !remaining.isEmpty
        )
    }
}

enum PhotosPickerLoadPresentation {
    /// The Photos picker can successfully return selections that cannot fit the
    /// signed CloudKit turn. If every selection is rejected, the composer has
    /// no thumbnail strip, so the message must say that no attachment was
    /// added rather than merely naming the rejected source files.
    static func message(loadedCount: Int, skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        if loadedCount == 0 {
            return skippedCount == 1
                ? "No photo was added because it was too large or unsupported. Try a smaller image."
                : "No photos were added because all \(skippedCount) were too large or unsupported. Try smaller images."
        }
        return skippedCount == 1
            ? "One photo was too large or unsupported; \(loadedCount) photo\(loadedCount == 1 ? "" : "s") is ready to send."
            : "\(skippedCount) photos were too large or unsupported; \(loadedCount) photo\(loadedCount == 1 ? "" : "s") \(loadedCount == 1 ? "is" : "are") ready to send."
    }
}

enum VoicePresentation {
    static func deniedSpeechMessage() -> String {
        "Speech recognition permission denied. Enable it in Settings."
    }

    static func deniedMicrophoneMessage() -> String {
        "Microphone permission denied. Enable it in Settings."
    }

    static func canReportSpeaking(audioSessionActivated: Bool, enqueued: Bool) -> Bool {
        audioSessionActivated && enqueued
    }
}
