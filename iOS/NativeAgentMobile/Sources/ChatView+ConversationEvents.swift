import SwiftUI
import PhotosUI
import UIKit
import Speech
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+ConversationEvents.swift` | Store-owned reply receiver; foreground refresh and session-bound dictation callbacks |

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
        store.onReply = { [voiceOutput, voiceInput, weak store] text, run in
            guard !TalkModeController.shared.consumeEndedReply(run) else { return }
            guard let store, ChatStore.visibleStore === store else { return }
            guard !TalkModeController.shared.isPresented else { return }
            guard !voiceInput.isListening, !voiceInput.isStarting else { return }
            voiceOutput.speak(text)
        }
        store.onSessionChange = { [voiceInput, origin = $dictationSessionKey] in
            guard voiceInput.isListening || voiceInput.isStarting
                || origin.wrappedValue != nil else { return }
            origin.wrappedValue = nil
            voiceInput.cancel()
        }
        store.attachReplyReceiver(using: bridgeClient)
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
        dictationSessionKey = nil
        sendWhenDictationLands = false
        voiceInput.cancel()
        if ChatStore.visibleStore === store { ChatStore.visibleStore = nil }
    }

    /// Final dictation and a pending send belong only to the conversation that started recording.
    func dictationFinished(_: String, _ newValue: String) {
        let sendNow = sendWhenDictationLands
        sendWhenDictationLands = false
        guard !newValue.isEmpty else { return }
        guard let origin = dictationSessionKey,
              origin == store.queueSessionKey(store.selectedSessionID) else { return }
        if voiceInput.isVoiceNote, sendNow {
            if store.send(text: newValue, client: bridgeClient, controls: runtimeControls) {
                followEnd()
                return
            }
            store.errorBanner = "Voice note kept in the draft. Reconnect and tap Send."
        }
        if draft.text.isEmpty {
            draft.text = newValue
        } else {
            draft.text += " " + newValue
        }
        if sendNow && !voiceInput.isVoiceNote { DispatchQueue.main.async { submitMessage() } }
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
