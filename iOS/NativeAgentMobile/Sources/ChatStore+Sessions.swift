import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    /// Session loading and refresh share MacTranscriptRead's distinction between unavailable and published empty.
    typealias SessionTranscriptLoader = (String?) async throws -> MacTranscriptRead

    static func shouldReturnToMainSession(
        selectedSessionID: String?,
        mainSessionID: String?,
        availablePinnedSessionIDs: Set<String>,
        locallyCreatedSessionID: String? = nil,
        explicitlySelectedSessionID: String? = nil
    ) -> Bool {
        // Without a known main-session identity we cannot distinguish a Mac
        // pin from the phone's still-being-adopted main chat. Wait for that
        // authority instead of resetting an iOS-created session to nil.
        guard let selected = cleanSessionID(selectedSessionID),
              let main = cleanSessionID(mainSessionID),
              selected != main else { return false }
        // A new iPhone chat is born locally and can legitimately be absent
        // from one or more Mac snapshots. Never classify that publication gap
        // as an externally removed pinned chat.
        if selected == cleanSessionID(locallyCreatedSessionID) { return false }
        // Explicitly opened conversations survive absence from the Mac's pinned snapshot.
        if selected == cleanSessionID(explicitlySelectedSessionID) { return false }
        return !availablePinnedSessionIDs.contains(selected)
    }

    func switchSession(to sessionID: String, using client: MacBridgeClient) {
        guard !isSwitchingSession, let clean = Self.cleanSessionID(sessionID) else { return }
        guard clean != selectedSessionID else {
            forceSessionRefresh(using: client)
            return
        }
        setSelectedSessionID(clean)
        loadSelectedSession(
            loadTranscript: { [weak self] sessionID in
                let read = await client.readChatTranscript(sessionID: sessionID)
                guard read == .unavailable, let sessionID else { return read }
                // Outside the Mac's published window: ask the Mac for the
                // newest page instead of showing "Not here yet".
                let page = try await iCloudSyncEngine.shared.chatHistoryPage(sessionID: sessionID)
                if page.hasOlder { self?.pagedSessionsWithOlder.insert(sessionID) }
                return .published(page.messages, generation: nil)
            }
        )
    }

    func switchToMainSession(using client: MacBridgeClient) {
        guard !isSwitchingSession else { return }
        if let mainSessionID {
            switchSession(to: mainSessionID, using: client)
            return
        }
        guard selectedSessionID != nil || !messages.isEmpty else {
            forceSessionRefresh(using: client)
            return
        }
        setSelectedSessionID(nil)
        loadSelectedSession(
            loadTranscript: { sessionID in await client.readChatTranscript(sessionID: sessionID) }
        )
    }

    /// Start a fresh chat session from iOS. Generates a new client-side session
    /// id; the Mac creates it as a `source: "ios"` session on the first message.
    /// It is an explicit conversation; main continues to follow the Mac.
    /// Mirrors loadSelectedSession's
    /// in-flight reset so no stale stream/poll bleeds into the new session.
    func startNewSession() {
        let freshSessionID = UUID().uuidString
        MobileChatSelectionIntent.selectSession(freshSessionID)
        // Dictation ends with the conversation it belongs to.
        onSessionChange?()
        // New chat takes priority over pending history reads and releases the composer immediately.
        cancelSessionSwitch()
        sendTask?.cancel()
        sendTask = nil
        // Retire old visible correlations, including sessionless replies, while retaining signed handoffs.
        let retiringCorrelations = Set(pendingICloudPlaceholders.keys)
            .union(timedOutPendingIds.keys)
            .union(maxDeltaSeqByCorrelation.keys)
            .union(pendingTimeouts.keys)
        for correlationID in retiringCorrelations {
            markICloudReplyResolved(correlationID, discardRetainedSend: false)
        }
        isPollingFallback = false
        errorBanner = nil
        // The fresh session starts with an unlocked composer.
        isLoading = false
        // Switch to the fresh id BEFORE clearing messages so the empty
        // transcript never persists over the previous session.
        markLocallyCreatedSession(freshSessionID)
        setSelectedSessionID(freshSessionID)
        messages = []
        lastRefreshAt = .distantPast
    }

    func cancelSessionSwitch() {
        sessionSwitchGeneration &+= 1
        sessionSwitchTask?.cancel()
        sessionSwitchTask = nil
        isSwitchingSession = false
    }

    private func loadSelectedSession(
        loadTranscript: @escaping SessionTranscriptLoader
    ) {
        // Every conversation change ends dictation at its owner.
        onSessionChange?()
        sendTask?.cancel()
        sendTask = nil
        // Detachment retires visible callbacks, not the retained transport queue.
        let retiringCorrelations = Set(pendingICloudPlaceholders.keys)
            .union(timedOutPendingIds.keys)
            .union(maxDeltaSeqByCorrelation.keys)
            .union(pendingTimeouts.keys)
        for correlationID in retiringCorrelations {
            markICloudReplyResolved(correlationID, discardRetainedSend: false)
        }
        isPollingFallback = false
        isSwitchingSession = true
        sessionSwitchGeneration &+= 1
        let switchGeneration = sessionSwitchGeneration
        // Gate queue draining before releasing the previous turn's composer.
        isLoading = false
        errorBanner = nil
        let loadingSessionID = selectedSessionID
        sessionSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSessionSwitch(generation: switchGeneration) }
            await self.restorationTask?.value
            guard !Task.isCancelled, self.selectedSessionID == loadingSessionID,
                  self.sessionSwitchGeneration == switchGeneration else { return }
            do {
                let read = try await loadTranscript(loadingSessionID)
                guard !Task.isCancelled, self.selectedSessionID == loadingSessionID else { return }
                self.applyMacTranscriptRead(read, sessionID: loadingSessionID)
                self.restorePendingExchanges(for: loadingSessionID)
                self.lastRefreshAt = Date()
            } catch is CancellationError {
                // cancelSessionSwitch releases the gate; deferred cleanup is guarded by the switch generation.
            } catch {
                guard !Task.isCancelled, self.selectedSessionID == loadingSessionID else { return }
                errorBanner = "Could not load this chat."
            }
        }
    }

    private func finishSessionSwitch(generation: UInt64) {
        guard generation == sessionSwitchGeneration else { return }
        sessionSwitchTask = nil
        isSwitchingSession = false
    }

    private func forceSessionRefresh(using client: MacBridgeClient) {
        lastRefreshAt = .distantPast
        refresh(using: client)
    }
}
