import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+Composer.swift` | Session-bound drafts, dictation, talk entry and attachment preparation on ChatView |

extension ChatView {
    struct SessionComposer {
        var draft = MobileChatDraft()
        var photos: [PendingPhotoAttachment] = []
        var files: [MultimodalAttachment] = []
    }

    private var composerPlaceholder: String {
        return agentDisplayName == NativeAgentIdentity.displayName(nil) ? "Message…" : "Message \(agentDisplayName)…"
    }

    private var queuedTurns: [QueuedChatSend] {
        #if DEBUG
        if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleExtras") {
            return ["Also remind me to call Sam", "And pick a walking route"].map {
                QueuedChatSend(id: UUID(), sessionID: nil, text: $0, controls: runtimeControls,
                               attachments: [], createdAt: Date(), pairingFingerprint: "chat-sample")
            }
        }
        #endif
        return store.queuedSendsForSelectedSession
    }

    var composerBar: some View {
        VStack(spacing: 8) {
            if !pendingPhotos.isEmpty || !pendingFiles.isEmpty || isLoadingPhotos {
                pendingPhotoStrip
            }
            if !queuedTurns.isEmpty {
                queuedSendStrip
            }
            if isRecordingVoice {
                DictationTranscript(input: voiceInput)
            }

            let a11y = dynamicTypeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 4) {
                if isRecordingVoice {
                    recordingStrip
                } else {
                    MobileChatComposerField(draft: draft, placeholder: composerPlaceholder,
                        focused: $composerIsFocused, accessibilitySize: a11y,
                        isSwitchingSession: store.isSwitchingSession, onSubmit: submitMessage)
                        .padding(.horizontal, 10)
                }

                HStack(spacing: 2) {
                    leadingButtons
                    Spacer(minLength: 8)
                    micButton
                        .disabled(store.isSwitchingSession)
                    Button {
                        composerIsFocused = false
                        voiceInput.cancel(); voiceOutput.stop()
                        TalkModeController.shared.begin(client: bridgeClient, controls: runtimeControls)
                    } label: {
                        Image(systemName: "phone.arrow.up.right")
                            .font(.system(size: 18)).frame(width: 44, height: 44)
                    }
                    .disabled(store.isSwitchingSession || voiceInput.isFinalizing)
                    .accessibilityLabel("Talk to \(agentDisplayName)")
                    .accessibilityHint("Start a hands-free conversation in this chat")

                    let replying = !voiceInput.isListening && !voiceInput.isStarting
                        && (!store.stoppableRunIDs(client: bridgeClient).isEmpty || (isChatSample && visibleMessages.last?.isStreaming == true))
                    if replying {
                        Button {
                            guard !isChatSample else { return }
                            store.stop(client: bridgeClient)
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AlivePalette.text)
                                .frame(width: 36, height: 36)
                                .background(NativeAgentMobileTheme.Colors.softFill, in: Circle())
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Stop generation")
                    }
                    if !replying || canSend {
                        Button {
                            if voiceInput.isListening || voiceInput.isStarting {
                                sendWhenDictationLands = true
                                voiceInput.stop()
                            } else {
                                submitMessage()
                            }
                        } label: {
                            let active = (canSend || voiceInput.isListening || voiceInput.isStarting) && !store.isSwitchingSession
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(active ? Color.white : AlivePalette.secondary)
                                .frame(width: 36, height: 36)
                                .background {
                                    Circle().fill(active
                                        ? HazeColor(stored: hazeColorRaw).control(dark: colorScheme == .dark, labelled: true)
                                        : NativeAgentMobileTheme.Colors.softFill)
                                    .animation(
                                        Animation.respecting(AppMotion.snappy, reduceMotion: reduceMotion),
                                        value: active)
                                }
                                .frame(width: 44, height: 44)
                        }
                        .disabled(!(canSend || voiceInput.isListening || voiceInput.isStarting) || store.isSwitchingSession || voiceInput.isFinalizing)
                        .accessibilityLabel("Send message")
                    }
                }
            }
        }
        .foregroundStyle(AlivePalette.text)
        .hazeTinted()
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .aliveGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)
        .overlay {
            PhoneThinkingLight(correlationIDs: Set(store.pendingICloudPlaceholders.keys))
        }
        .frame(maxWidth: NativeAgentSpacing.chatRoomWidth)
        #if DEBUG
        .task { voiceInput.showDictationSample() }
        #endif
    }

    private var canSend: Bool {
        !isLoadingPhotos && fileLoadID == nil && (draft.hasText
            || !pendingPhotos.isEmpty || !pendingFiles.isEmpty)
    }

    var hasComposerDraft: Bool {
        !draft.isEmpty || !pendingPhotos.isEmpty || !pendingFiles.isEmpty
            || !selectedPhotoItems.isEmpty || isLoadingPhotos || fileLoadID != nil
    }

    @ViewBuilder private var queuedSendStrip: some View {
        let turns = queuedTurns
        if let next = turns.first {
            let primaryAction = QueuedSendStripAction.resolve(
                id: next.id,
                isLoading: store.isLoading
            )
            HStack(spacing: 10) {
                Text(!store.canDeliverQueuedSend(next) ? "Saved for another pairing" : store.isSelectedQueuePaused ? "Paused" : turns.count > 1
                    ? "Next of \(turns.count)" : "Next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize()

                VStack(alignment: .leading, spacing: 4) {
                    Text(next.preview)
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let failure = next.steeringFailure {
                        Text(failure).font(.caption).foregroundStyle(AlivePalette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button {
                        if !store.canDeliverQueuedSend(next) {
                            store.submitSavedSendToCurrentPairing(next.id, client: bridgeClient)
                        } else { primaryAction.apply(
                            onSteer: { store.sendQueuedNow($0, client: bridgeClient) },
                            onSend: { store.resumeQueuedSends(startingWith: $0) }
                        ) }
                    } label: {
                        Label(store.canDeliverQueuedSend(next) ? primaryAction.primaryTitle : "Submit to this Mac as new", systemImage: "arrow.up")
                    }
                    Button(role: .destructive) {
                        store.removeQueuedSend(next.id)
                    } label: {
                        Label("Remove", systemImage: "xmark")
                    }
                    .disabled(!store.canRemoveQueuedSend(next))
                    if turns.count > 1 {
                        Section(AliveWords.count(turns.count, "message") + " waiting") {
                            ForEach(Array(turns.enumerated().dropFirst()), id: \.element.id) { index, queued in
                                let action = QueuedSendStripAction.resolve(
                                    id: queued.id,
                                    isLoading: store.isLoading
                                )
                                Button {
                                    if !store.canDeliverQueuedSend(queued) {
                                        store.submitSavedSendToCurrentPairing(queued.id, client: bridgeClient)
                                    } else { action.apply(
                                        onSteer: { store.sendQueuedNow($0, client: bridgeClient) },
                                        onSend: { store.resumeQueuedSends(startingWith: $0) }
                                    ) }
                                } label: {
                                    Label(store.canDeliverQueuedSend(queued) ? action.menuTitle(position: index + 1, preview: queued.preview)
                                        : "Submit to this Mac as new: \(queued.preview)", systemImage: "arrow.up")
                                }
                                if let failure = queued.steeringFailure { Text(failure) }
                                Button(role: .destructive) {
                                    store.removeQueuedSend(queued.id)
                                } label: {
                                    Label("Remove \(index + 1): \(queued.preview)", systemImage: "xmark")
                                }
                                .disabled(!store.canRemoveQueuedSend(queued))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AlivePalette.text)
                        .frame(width: 30, height: 30)
                        .background(AlivePalette.fill, in: Circle())
                        .overlay(Circle().strokeBorder(AlivePalette.rim, lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Queued message actions")
            }
            .padding(.leading, 12)
            .padding(.trailing, 0)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AlivePalette.divider).frame(height: 1).padding(.horizontal, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Send-next queue, \(turns.count) queued")
        }
    }

    private var pendingPhotoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingFiles) { file in
                    HStack(spacing: 4) {
                        Label(file.name ?? "Document", systemImage: "doc")
                            .lineLimit(1)
                            .padding(.leading, 12)
                        Button { pendingFiles.removeAll { $0.id == file.id } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attached document")
                    }
                    .font(.footnote)
                    .background(AlivePalette.fill, in: Capsule())
                }
                if isLoadingPhotos {
                    Label("Loading photos", systemImage: "photo")
                        .font(AppFont.tag)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AlivePalette.fill, in: Capsule())
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
                            .accessibilityLabel("Attached photo")
                        Button {
                            photoLoadTask?.cancel()
                            photoLoadGeneration &+= 1
                            isLoadingPhotos = false
                            pendingPhotos.removeAll { $0.id == photo.id }
                            suppressNextEmptyPhotoSelection = !pendingPhotos.isEmpty && !selectedPhotoItems.isEmpty
                            selectedPhotoItems = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.58))
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(Rectangle())
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove attached photo")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var attachmentMenu: some View {
        let sessionKey = store.queueSessionKey(store.selectedSessionID)
        let retainedOutsidePicker = pendingPhotos.filter { photo in
            !selectedPhotoItems.contains { $0 == photo.pickerItem }
        }.count
        let busy = store.isLoading || store.isSwitchingSession || isLoadingPhotos || fileLoadID != nil
        let atLimit = pendingPhotos.count + pendingFiles.count >= maxPendingPhotos
        return MobileAttachmentMenu(
            selectedPhotoItems: Binding(get: { selectedPhotoItems }, set: { items in
                guard composerSessionKey == sessionKey,
                      store.queueSessionKey(store.selectedSessionID) == sessionKey else { return }
                selectedPhotoItems = items
            }),
            canAttach: !busy && !atLimit,
            isLoading: isLoadingPhotos || fileLoadID != nil,
            maxPhotos: max(1, maxPendingPhotos - pendingFiles.count - retainedOutsidePicker),
            onChooseFiles: { showsFileImporter = true }
        )
    }

    private var micButton: some View {
        ComposerVoiceMicrophone(input: voiceInput, begin: { note in
            voiceOutput.stop()
            VoiceNoteBubble.stopPlayback()
            composerIsFocused = false
            sendWhenDictationLands = false
            dictationSessionKey = store.queueSessionKey(store.selectedSessionID)
            let names = [agentDisplayName, sync.personality?.userName ?? ""].filter { !$0.isEmpty }
            voiceInput.begin(voiceNote: note, names: names)
        }, release: {
            sendWhenDictationLands = true
            voiceInput.stop()
        }, cancel: cancelVoiceInput)
    }

    private func cancelVoiceInput() {
        sendWhenDictationLands = false
        dictationSessionKey = nil
        voiceInput.cancel()
    }

    private var isRecordingVoice: Bool {
        voiceInput.isListening || voiceInput.isStarting || voiceInput.isFinalizing
    }

    /// Replace attachments with recording cancel in the same slot so the microphone cannot move beneath a held finger.
    @ViewBuilder private var leadingButtons: some View {
        if isRecordingVoice {
            Button(action: cancelVoiceInput) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AlivePalette.text)
                    .frame(width: 36, height: 36)
                    .background(NativeAgentMobileTheme.Colors.softFill, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")
        } else {
            attachmentMenu
        }
    }

    private var recordingStrip: some View {
        HStack(spacing: 8) {
            if voiceInput.isLocked { Image(systemName: "lock.fill").font(.footnote) }
            if let start = voiceInput.startedAt {
                Text(start, style: .timer).monospacedDigit().font(.subheadline)
            }
            DictationWaveform(input: voiceInput)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 4)
    }

    func invalidateAttachmentPreparation() {
        fileLoadTask?.cancel()
        fileLoadTask = nil
        fileLoadID = nil
        photoLoadTask?.cancel()
        photoLoadTask = nil
        photoLoadGeneration &+= 1
        isLoadingPhotos = false
    }

    func restoreSessionComposer() {
        let destination = store.queueSessionKey(store.selectedSessionID)
        guard composerSessionKey != destination else { return }
        invalidateAttachmentPreparation()
        if composerSessionKey == store.queueSessionKey(nil),
           MobileChatSelectionIntent.explicitlySelectedSessionID == nil {
            // Adopting main's identity binds the existing composer; it must not clear it as a different conversation.
            composerSessionKey = destination
            return
        }
        if let origin = composerSessionKey {
            sessionComposers[origin] = SessionComposer(draft: draft, photos: pendingPhotos, files: pendingFiles)
        }
        let restored = sessionComposers.removeValue(forKey: destination) ?? SessionComposer()
        composerSessionKey = destination
        draft = restored.draft
        pendingPhotos = restored.photos
        pendingFiles = restored.files
        let items = restored.photos.compactMap(\.pickerItem)
        suppressNextEmptyPhotoSelection = items.isEmpty && !selectedPhotoItems.isEmpty
        selectedPhotoItems = items
    }

    func submitMessage() {
        restoreSessionComposer()
        guard !isChatSample, canSend, !store.isSwitchingSession else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingPhotos.map(\.attachment) + pendingFiles
        let sendText = text.isEmpty
            ? (attachments.count == 1 ? "Look at this attachment." : "Look at these attachments.")
            : text
        guard store.send(text: sendText, client: bridgeClient, controls: runtimeControls, attachments: attachments) else { return }
        followEnd()
        draft.text = ""
        pendingPhotos = []
        pendingFiles = []
        selectedPhotoItems = []
    }

    func loadFileAttachments(_ result: Result<[URL], Error>) {
        guard composerSessionKey == store.queueSessionKey(store.selectedSessionID) else { return }
        do {
            let urls = try result.get()
            guard urls.count + pendingFiles.count + pendingPhotos.count <= maxPendingPhotos else {
                store.errorBanner = "Attach up to four photos or documents at a time."
                return
            }
            let generation = store.sessionSwitchGeneration
            fileLoadTask?.cancel()
            let loadID = UUID()
            fileLoadID = loadID
            fileLoadTask = Task {
                defer {
                    if fileLoadID == loadID { fileLoadID = nil; fileLoadTask = nil }
                }
                do {
                    let files = try await Task.detached(priority: .userInitiated) {
                        try urls.map { try MobileChatAttachmentPreparation.fileAttachment(from: $0) }
                    }.value
                    guard !Task.isCancelled, fileLoadID == loadID, generation == store.sessionSwitchGeneration else { return }
                    guard files.count + pendingFiles.count + pendingPhotos.count <= maxPendingPhotos else {
                        store.errorBanner = "Attach up to four photos or documents at a time."
                        return
                    }
                    pendingFiles.append(contentsOf: files)
                } catch {
                    guard !Task.isCancelled, fileLoadID == loadID, generation == store.sessionSwitchGeneration else { return }
                    let failure = error as NSError
                    store.errorBanner = failure.domain == "ChatAttachment" ? failure.localizedDescription
                        : "File could not be loaded: \(error.localizedDescription)"
                }
            }
        } catch { store.errorBanner = "File could not be loaded: \(error.localizedDescription)" }
    }

    func loadPhotoAttachments(_ items: [PhotosPickerItem], previousItems: [PhotosPickerItem]) {
        let sessionKey = store.queueSessionKey(store.selectedSessionID)
        guard composerSessionKey == sessionKey else { return }
        let sessionGeneration = store.sessionSwitchGeneration
        photoLoadTask?.cancel()
        photoLoadGeneration &+= 1
        let generation = photoLoadGeneration
        pendingPhotos.removeAll { photo in
            previousItems.contains { $0 == photo.pickerItem }
                && !items.contains { $0 == photo.pickerItem }
        }
        guard !items.isEmpty else {
            isLoadingPhotos = false
            return
        }
        isLoadingPhotos = true
        let newItems = items.filter { item in !pendingPhotos.contains { $0.pickerItem == item } }
        guard !newItems.isEmpty else {
            isLoadingPhotos = false
            return
        }
        let selectedItems = Array(newItems.prefix(max(0, maxPendingPhotos - pendingPhotos.count - pendingFiles.count)))
        photoLoadTask = Task {
            var loaded: [PendingPhotoAttachment] = []
            var skippedCount = newItems.count - selectedItems.count
            for (index, item) in selectedItems.enumerated() {
                if Task.isCancelled { return }
                do {
                    guard let sourceData = try await item.loadTransferable(type: Data.self),
                          let prepared = await Task.detached(priority: .userInitiated, operation: {
                              guard let jpeg = MobileChatAttachmentPreparation.preparedJPEGData(from: sourceData),
                                    let thumbnail = MobileChatAttachmentPreparation.thumbnail(from: jpeg, maxDimension: 240) else {
                                  return nil as (MultimodalAttachment, UIImage)?
                              }
                              let attachment = MultimodalAttachment(id: UUID().uuidString, type: "image",
                                  base64: jpeg.base64EncodedString(), mime: "image/jpeg",
                                  name: "iphone-photo-\(index + 1).jpg", byteSize: jpeg.count)
                              return (attachment, thumbnail)
                          }).value else {
                        skippedCount += 1
                        continue
                    }
                    let (attachment, thumbnail) = prepared
                    let id = attachment.id
                    loaded.append(PendingPhotoAttachment(id: id, attachment: attachment, thumbnail: thumbnail, pickerItem: item))
                } catch {
                    if generation == photoLoadGeneration, !Task.isCancelled,
                       sessionGeneration == store.sessionSwitchGeneration,
                       sessionKey == store.queueSessionKey(store.selectedSessionID) {
                        store.errorBanner = "Photo could not be loaded: \(error.localizedDescription)"
                    }
                }
            }
            guard generation == photoLoadGeneration, !Task.isCancelled,
                  sessionGeneration == store.sessionSwitchGeneration,
                  sessionKey == store.queueSessionKey(store.selectedSessionID) else { return }
            // Four attachments in all, whichever picker finished first.
            pendingPhotos.append(contentsOf: loaded.prefix(max(0, maxPendingPhotos - pendingPhotos.count - pendingFiles.count)))
            isLoadingPhotos = false
            if let message = PhotosPickerLoadPresentation.message(
                loadedCount: loaded.count,
                skippedCount: skippedCount
            ) {
                store.errorBanner = message
            }
            if loaded.isEmpty {
                suppressNextEmptyPhotoSelection = !selectedPhotoItems.isEmpty
                selectedPhotoItems = []
            }
        }
    }

    func importSharedItems() {
        store.importSharedItems(controls: runtimeControls)
    }
}

@Observable
final class MobileChatDraft {
    var text = "" {
        didSet {
            if isEmpty != text.isEmpty { isEmpty = text.isEmpty }
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if self.hasText != hasText { self.hasText = hasText }
        }
    }
    private(set) var isEmpty = true
    private(set) var hasText = false
}

private struct MobileChatComposerField: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let draft: MobileChatDraft
    let placeholder: String
    @Binding var focused: Bool
    let accessibilitySize: Bool
    let isSwitchingSession: Bool
    let onSubmit: () -> Void

    var body: some View {
        let maxLines = verticalSizeClass == .compact ? 2 : (accessibilitySize ? 8 : 5)
        MobileComposerTextView(text: draft.text, placeholder: placeholder, isFocused: focused, maxLines: maxLines,
                               enabled: !isSwitchingSession, onChange: { draft.text = $0 }, onFocus: { focused = $0 }, onSubmit: onSubmit)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.system(.body, weight: .regular))
                        .foregroundStyle(AlivePalette.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 11)
            .frame(minHeight: 44)
    }
}

private struct MobileAttachmentMenu: View {
    @Binding var selectedPhotoItems: [PhotosPickerItem]
    let canAttach: Bool
    let isLoading: Bool
    let maxPhotos: Int
    let onChooseFiles: () -> Void
    @State private var showsPhotosPicker = false

    var body: some View {
        Menu {
            Button { showsPhotosPicker = true } label: {
                Label("Photos", systemImage: "photo")
            }
            Button(action: onChooseFiles) {
                Label("Files", systemImage: "doc")
            }
        } label: {
            Image(systemName: isLoading ? "hourglass" : "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AlivePalette.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(!canAttach)
        .accessibilityLabel("Add attachments")
        .photosPicker(
            isPresented: $showsPhotosPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: maxPhotos,
            matching: .images
        )
    }
}

private final class ComposerUITextView: UITextView {
    var onLayoutWidth: ((CGFloat) -> Void)?
    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if width > 0, width != lastLayoutWidth {
            lastLayoutWidth = width
            onLayoutWidth?(width)
        }
    }
}

private struct MobileComposerTextView: UIViewRepresentable {
    let text: String
    let placeholder: String
    let isFocused: Bool
    let maxLines: Int
    let enabled: Bool
    let onChange: (String) -> Void
    let onFocus: (Bool) -> Void
    let onSubmit: () -> Void

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileComposerTextView
        var measured: [CGFloat: CGFloat] = [:]
        var measuredFont: UIFont?
        var width: CGFloat = 0
        init(_ parent: MobileComposerTextView) { self.parent = parent }

        func measuredHeight(in textView: UITextView, width: CGFloat) -> CGFloat {
            if measuredFont != textView.font {
                measured.removeAll()
                measuredFont = textView.font
            }
            if let cached = measured[width] { return cached }
            let full = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            measured[width] = full
            return full
        }

        func syncScrollMode(_ textView: UITextView) {
            let layoutWidth = textView.bounds.width
            guard layoutWidth > 44 else { return }
            let line = ceil(textView.font?.lineHeight ?? 22)
            let limit = line * CGFloat(parent.maxLines)
            let scrolls = measuredHeight(in: textView, width: layoutWidth) > limit
            if textView.isScrollEnabled != scrolls {
                textView.isScrollEnabled = scrolls
                if scrolls {
                    textView.scrollRangeToVisible(textView.selectedRange)
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            measured.removeAll()
            syncScrollMode(textView)
            parent.onChange(textView.text)
            textView.invalidateIntrinsicContentSize()
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            parent.onSubmit()
            return false
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocus(true) }
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocus(false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        let coordinator = context.coordinator
        view.delegate = coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .label
        view.returnKeyType = .send
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onLayoutWidth = { [weak coordinator, weak view] _ in
            guard let coordinator, let view else { return }
            coordinator.syncScrollMode(view)
        }
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            context.coordinator.measured.removeAll()
            view.invalidateIntrinsicContentSize()
        }
        context.coordinator.syncScrollMode(view)
        view.isEditable = enabled
        view.accessibilityLabel = placeholder
        guard isFocused != view.isFirstResponder else { return }
        let coordinator = context.coordinator
        Task { @MainActor [weak view] in
            guard let view, coordinator.parent.isFocused != view.isFirstResponder else { return }
            if coordinator.parent.isFocused { view.becomeFirstResponder() } else { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ComposerUITextView, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        let line = ceil(view.font?.lineHeight ?? 22)
        var width = proposal.width ?? coordinator.width
        if !width.isFinite { width = coordinator.width }
        guard width > 44 else { return CGSize(width: proposal.width ?? 44, height: line) }
        coordinator.width = width
        let full = coordinator.measuredHeight(in: view, width: width)
        let limit = line * CGFloat(maxLines)
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : width } ?? width, height: min(full, limit))
    }
}
