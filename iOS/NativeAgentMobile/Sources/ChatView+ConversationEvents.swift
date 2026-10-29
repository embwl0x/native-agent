import SwiftUI
import PhotosUI
import UIKit
import Speech
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+ConversationEvents.swift` | Mounted reply observers, foreground refresh and session-bound dictation callbacks on ChatView |

extension ChatView {
    func restoreConversation() async {
        await store.restorationTask?.value
        guard !Task.isCancelled else { return }
        store.resumeObservingPendingExchanges(using: bridgeClient)
        #if DEBUG
        if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleModel") {
            showsConfiguration = true
        }
        if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleToast") {
            SystemToastCenter.shared.push(success: "Approved. I'll add it now.", autoDismissAfter: nil)
        }
        if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleKeyboard") {
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-chatSampleDraft"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                draft.text = ProcessInfo.processInfo.arguments[index + 1]
            }
            await Task.yield()
            composerIsFocused = true
        }
        #endif
    }

    func conversationAppeared() {
        // Visible chat suppresses reply alerts for the answer being read.
        ChatStore.visibleStore = store
        restoreSessionComposer()
        adoptMainSessionFromSnapshots()
        restoreSessionComposer()
        if MobileQuickAskRoute.consume() { composerIsFocused = true }
        consumeNotifiedChatSessionIfNeeded()
        importSharedItems()
        store.onReply = { [voiceOutput] text in
            voiceOutput.speak(text)
        }
        // Every session change ends dictation at the shared switch boundary.
        store.onSessionChange = { [voiceInput, origin = $dictationSessionKey] in
            guard voiceInput.isListening || voiceInput.isStarting
                || origin.wrappedValue != nil else { return }
            origin.wrappedValue = nil
            voiceInput.stop()
        }
        if iCloudReplyObserverID == nil {
            iCloudReplyObserverID = bridgeClient.observeICloudReplies { msg in
                Task { @MainActor in
                    await store.receiveICloudReply(msg)
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
        // Resync hints resume observation through the bridge's installed pairing key.
        store.pendingRetryClient = bridgeClient
        if iCloudResyncObserverID == nil {
            iCloudResyncObserverID = bridgeClient.observeICloudResyncHints { hint in
                Task { @MainActor in
                    store.receiveICloudResyncHint(hint, client: bridgeClient)
                }
            }
        }
        // Resume observing accepted exchanges without sending them again.
        store.resumeObservingPendingExchanges(using: bridgeClient)
        NativeAgentDeepLinkSendHook.deliverPending(
            to: store,
            client: bridgeClient,
            controls: runtimeControls
        )
        Task {
            await store.restorationTask?.value
            await iCloudBridge.shared.deviceIncomingSetupTask?.value
            await iCloudBridge.shared.setupTask?.value
            await bridgeClient.pollICloudRepliesNow()
            if !sync.refreshInFlight {
                await sync.refreshProviderControlsSnapshot()
                await sync.refreshChatSessionListSnapshot()
            }
            adoptMainSessionFromSnapshots()
            reconcileExternallyRemovedPinnedSession(
                afterPinnedIDs: visiblePinnedSessionIDs
            )
            if !sync.refreshInFlight { store.refresh(using: bridgeClient) }
        }
    }

    func conversationSceneChanged(_: ScenePhase, _ newPhase: ScenePhase) {
        if newPhase == .active {
            if MobileQuickAskRoute.consume() { composerIsFocused = true }
            importSharedItems()
            store.resumeObservingPendingExchanges(using: bridgeClient)
            Task {
                await bridgeClient.pollICloudRepliesNow()
                await sync.refreshChatSessionListSnapshot()
                adoptMainSessionFromSnapshots()
                reconcileExternallyRemovedPinnedSession(
                    afterPinnedIDs: visiblePinnedSessionIDs
                )
                store.refresh(using: bridgeClient)
            }
        }
    }

    func conversationDisappeared() {
        if ChatStore.visibleStore === store { ChatStore.visibleStore = nil }
        guard !store.hasPendingICloudReplies && !store.isLoading else { return }
        bridgeClient.removeICloudReplyObserver(iCloudReplyObserverID)
        bridgeClient.removeICloudReplyRejectionObserver(iCloudRejectionObserverID)
        bridgeClient.removeICloudResyncHintObserver(iCloudResyncObserverID)
        iCloudReplyObserverID = nil
        iCloudRejectionObserverID = nil
        iCloudResyncObserverID = nil
    }

    /// Final words and a pending one-tap send belong only to the dictated conversation.
    func dictationFinished(_: String, _ newValue: String) {
        let sendNow = sendWhenDictationLands
        sendWhenDictationLands = false
        guard !newValue.isEmpty else { return }
        guard let origin = dictationSessionKey,
              origin == store.queueSessionKey(store.selectedSessionID) else { return }
        if let attachment = voiceInput.lastAttachment { pendingFiles.append(attachment) }
        if draft.text.isEmpty {
            draft.text = newValue
        } else {
            draft.text += " " + newValue
        }
        if sendNow { DispatchQueue.main.async { submitMessage() } }
    }

    func photoSelectionChanged(_ previousItems: [PhotosPickerItem], _ items: [PhotosPickerItem]) {
        guard composerSessionKey == store.queueSessionKey(store.selectedSessionID),
              items == selectedPhotoItems else { return }
        if items.isEmpty && suppressNextEmptyPhotoSelection {
            suppressNextEmptyPhotoSelection = false
            return
        }
        loadPhotoAttachments(items, previousItems: previousItems)
    }
}
