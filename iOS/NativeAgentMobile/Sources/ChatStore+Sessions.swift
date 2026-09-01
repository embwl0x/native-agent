// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

extension ChatStore {
    typealias SessionHistoryLoader = (String?) async throws -> [ChatMessage]?

    static func shouldReturnToMainSession(
        selectedSessionID: String?,
        mainSessionID: String?,
        availablePinnedSessionIDs: Set<String>,
        locallyCreatedSessionID: String? = nil
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
        return !availablePinnedSessionIDs.contains(selected)
    }

    func switchSession(to sessionID: String, using client: MacBridgeClient, fallbackMessages: [ChatMessage]?) {
        guard !isSwitchingSession, let clean = Self.cleanSessionID(sessionID) else { return }
        guard clean != selectedSessionID else {
            forceSessionRefresh(using: client, fallbackMessages: fallbackMessages)
            return
        }
        setSelectedSessionID(clean)
        loadSelectedSession(
            loadHistory: { sessionID in await client.refreshChatHistory(sessionID: sessionID) },
            fallbackMessages: fallbackMessages
        )
    }

    /// The loader stays at the session boundary so all terminal outcomes can
    /// release the composer lock. Production supplies MacBridgeClient; the
    /// hermetic path also proves a failed/cancelled read cannot leave the field
    /// permanently disabled.
    func switchSessionForEvaluation(
        to sessionID: String,
        loadHistory: @escaping SessionHistoryLoader,
        fallbackMessages: [ChatMessage]?
    ) {
        guard !isSwitchingSession, let clean = Self.cleanSessionID(sessionID) else { return }
        guard clean != selectedSessionID else { return }
        setSelectedSessionID(clean)
        loadSelectedSession(loadHistory: loadHistory, fallbackMessages: fallbackMessages)
    }

    func switchToMainSession(using client: MacBridgeClient, fallbackMessages: [ChatMessage]?) {
        guard !isSwitchingSession else { return }
        if let mainSessionID {
            switchSession(to: mainSessionID, using: client, fallbackMessages: fallbackMessages)
            return
        }
        guard selectedSessionID != nil || !messages.isEmpty else {
            forceSessionRefresh(using: client, fallbackMessages: fallbackMessages)
            return
        }
        setSelectedSessionID(nil)
        loadSelectedSession(
            loadHistory: { sessionID in await client.refreshChatHistory(sessionID: sessionID) },
            fallbackMessages: fallbackMessages
        )
    }

    /// Start a fresh chat session from iOS. Generates a new client-side session
    /// id; the Mac creates it as a `source: "ios"` session on the first message.
    /// It becomes the phone's one main session; additional tabs come only from
    /// the exact Mac-owned pinned snapshot. Mirrors loadSelectedSession's
    /// in-flight reset so no stale stream/poll bleeds into the new session.
    func startNewSession() {
        // Escape hatch: usable even while a turn is still "working" — that is
        // exactly when the user reaches for it (a hung iCloud round-trip leaves
        // isLoading stuck true). A session history read is cancellable, so a
        // new chat takes priority and releases the composer immediately.
        cancelSessionSwitch()
        sendTask?.cancel()
        sendTask = nil
        // Clearing the pending maps alone makes their eventual signed replies
        // look unsolicited. Retire every old correlation first so sessionless
        // stragglers are rejected as well as replies carrying the old session id.
        let retiringCorrelations = Set(pendingICloudPlaceholders.keys)
            .union(pendingSendArgs.keys)
            .union(timedOutPendingIds.keys)
            .union(canceledPendingIds)
            .union(maxDeltaSeqByCorrelation.keys)
        for correlationID in retiringCorrelations {
            markICloudReplyResolved(correlationID)
        }
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingTimeouts.removeAll()
        pendingPolls.values.forEach { $0.cancel() }
        pendingPolls.removeAll()
        pendingICloudPlaceholders.removeAll()
        pendingSendArgs.removeAll()
        retriedSignatureCorrelations.removeAll()
        timedOutPendingIds.removeAll()
        canceledPendingIds.removeAll()
        streamingHintsByMessageId.removeAll()
        maxDeltaSeqByCorrelation.removeAll()
        cancelAllTypewriters()
        isPollingFallback = false
        errorBanner = nil
        // The in-flight turn (if any) was just cancelled above; a brand-new
        // session has nothing loading. Without this, a stuck isLoading would
        // persist into the new session and keep the composer + this button
        // disabled — the very freeze this escape hatch exists to clear.
        isLoading = false
        // Switch to the fresh id BEFORE clearing messages so the empty
        // transcript never persists over the previous session. It replaces the
        // one phone-main slot; only Mac-pinned sessions occupy extra tabs.
        let freshSessionID = UUID().uuidString
        markLocallyCreatedSession(freshSessionID)
        replaceMainSessionID(freshSessionID)
        setSelectedSessionID(freshSessionID)
        suppressMessagePersistence = true
        messages = []
        suppressMessagePersistence = false
        lastRefreshAt = .distantPast
    }

    func cancelSessionSwitch() {
        sessionSwitchGeneration &+= 1
        sessionSwitchTask?.cancel()
        sessionSwitchTask = nil
        isSwitchingSession = false
    }

    private func loadSelectedSession(
        loadHistory: @escaping SessionHistoryLoader,
        fallbackMessages: [ChatMessage]?
    ) {
        sendTask?.cancel()
        sendTask = nil
        let retiringCorrelations = Set(pendingICloudPlaceholders.keys)
            .union(pendingSendArgs.keys)
            .union(timedOutPendingIds.keys)
            .union(canceledPendingIds)
            .union(maxDeltaSeqByCorrelation.keys)
        for correlationID in retiringCorrelations {
            markICloudReplyResolved(correlationID)
        }
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingTimeouts.removeAll()
        pendingPolls.values.forEach { $0.cancel() }
        pendingPolls.removeAll()
        pendingICloudPlaceholders.removeAll()
        pendingSendArgs.removeAll()
        retriedSignatureCorrelations.removeAll()
        timedOutPendingIds.removeAll()
        canceledPendingIds.removeAll()
        streamingHintsByMessageId.removeAll()
        // PATCH-2026-05-30: session switch — clear text_delta seq tracking too.
        maxDeltaSeqByCorrelation.removeAll()
        cancelAllTypewriters()
        isPollingFallback = false
        isSwitchingSession = true
        sessionSwitchGeneration &+= 1
        let switchGeneration = sessionSwitchGeneration
        errorBanner = nil
        let loadingSessionID = selectedSessionID
        let cachedMessages = fallbackMessages ?? loadCachedMessages(for: loadingSessionID)
        suppressMessagePersistence = true
        messages = cachedMessages
        suppressMessagePersistence = false
        // Cache-loaded rows are NOT recent arrivals: without this, switching
        // back to a session could resurrect rows the Mac removed/aged out for
        // a full preserve window. Live in-session arrivals keep real stamps.
        for id in cachedMessages.map(\.id) { localArrivalDates[id] = .distantPast }
        lastRefreshAt = .distantPast
        sessionSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSessionSwitch(generation: switchGeneration) }
            do {
                let macMessages = try await loadHistory(loadingSessionID)
                guard !Task.isCancelled, self.selectedSessionID == loadingSessionID else { return }
                if let macMessages, !macMessages.isEmpty {
                    // Stale-snapshot guard (ff7b6657): merge instead of replace so a
                    // snapshot built before the newest turns synced can't vanish the
                    // locally-cached transcript on a session (re)load. An EMPTY
                    // snapshot is treated like nil — likely an iOS-created session
                    // the Mac hasn't written back yet, never grounds to clear cache.
                    // Only the session's OWN cache earns the merge; an explicit
                    // fallbackMessages payload (legacy/global cache) must not leak
                    // into this session — snapshot replaces it like before.
                    if fallbackMessages == nil {
                        self.messages = self.mergedMacMessagesPreservingPending(
                            macMessages, replyArrived: false)
                    } else {
                        self.messages = macMessages
                    }
                    self.persistMessages()
                } else if self.messages.isEmpty, let fallbackMessages {
                    self.messages = fallbackMessages
                    self.persistMessages()
                } else if !self.messages.isEmpty {
                    self.persistMessages()
                }
                self.lastRefreshAt = Date()
            } catch is CancellationError {
                // The explicit cancellation owner clears the gate immediately;
                // defer remains as a backstop for a cooperative loader.
            } catch {
                guard !Task.isCancelled, self.selectedSessionID == loadingSessionID else { return }
                errorBanner = "Could not load this chat. Showing the cached transcript."
            }
        }
    }

    private func finishSessionSwitch(generation: UInt64) {
        guard generation == sessionSwitchGeneration else { return }
        sessionSwitchTask = nil
        isSwitchingSession = false
    }

    private func forceSessionRefresh(using client: MacBridgeClient, fallbackMessages: [ChatMessage]?) {
        lastRefreshAt = .distantPast
        refresh(using: client, fallbackMessages: fallbackMessages)
    }
}
