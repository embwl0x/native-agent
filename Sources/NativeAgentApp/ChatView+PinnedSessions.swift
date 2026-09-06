import Foundation
import PersistenceCore
import SwiftUI
import UniformTypeIdentifiers

/// The mounted sidebar-row unpin route. It translates the canonical
/// mirror-first store outcome into the explicit UI outcomes the row can show.
/// In particular, a failed retention write leaves the pin visible rather than
/// optimistically claiming the glyph was removed.
@MainActor
enum ChatSidebarRowUnpinTransaction {
    enum Outcome: Equatable {
        case unpinned(encoded: String)
        case refusedInvalidSessionID
        case refusedAlreadyUnpinned
        case failed
    }

    static func execute(
        sessionID: String,
        defaults: UserDefaults = .standard,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> Outcome {
        do {
            switch try MacPinnedChatSessionStore.closePinnedTab(
                sessionID: sessionID,
                defaults: defaults,
                dataRoot: dataRoot
            ) {
            case .closed(let encoded):
                return .unpinned(encoded: encoded)
            case .refusedInvalidSessionID:
                return .refusedInvalidSessionID
            case .refusedAlreadyUnpinned:
                return .refusedAlreadyUnpinned
            }
        } catch {
            return .failed
        }
    }
}

/// A pin snapshot is only valid when it can be reconstructed from the same
/// UserDefaults value the next launch will read. This deliberately gates the
/// fire-and-forget iCloud request: publishing an older or half-applied list is
/// worse than retaining the last proven phone snapshot.
@MainActor
enum ChatPinnedSnapshotPublication {
    @discardableResult
    static func request(
        encodedPinnedIDs: String,
        defaults: UserDefaults = .standard,
        publish: ([String]) -> Void
    ) -> Bool {
        let requested = MacPinnedChatSessionStore.decode(encodedPinnedIDs)
        let persisted = MacPinnedChatSessionStore.load(defaults: defaults)
        guard requested == persisted else { return false }
        publish(persisted)
        return true
    }
}

/// The anchor as the pin strip reads it.
///
/// The anchor is whichever remote conversation is currently live — User's phone
/// chat today, any surface he connects tomorrow — and the strip merges it in
/// front of his own pins without ever writing it into them.
///
/// Why a memo and not a bare `ConversationAnchor.currentSessionId()`: the strip
/// is projected from `ChatView.body`, which runs at TOKEN cadence while a reply
/// streams. The anchor file changes at CONVERSATION cadence — a `/new`, minutes
/// apart. Reading it per body pass would be a file read and a JSON parse on the
/// main thread for a value that cannot have moved. One second is far under any
/// human sense of "one tap away" and far over the streaming rate.
@MainActor
enum MacConversationAnchorReading {
    private static var cachedSessionId: String?
    private static var readAt = Date.distantPast

    static func currentSessionId(
        now: Date = Date(),
        maxAge: TimeInterval = 1,
        read: () -> String? = { ConversationAnchor.currentSessionId() }
    ) -> String? {
        if now.timeIntervalSince(readAt) < maxAge { return cachedSessionId }
        cachedSessionId = read()
        readAt = now
        return cachedSessionId
    }

    /// Tests own the clock; nothing in the app calls this.
    static func resetForTesting() {
        cachedSessionId = nil
        readAt = .distantPast
    }
}

extension ChatView {
    /// The human's pins WITHOUT the anchor — what `savePinnedSessionIds` must
    /// persist. Writing the merged list back would silently adopt the anchor as
    /// a real pin, and it would stay pinned after it stopped being the anchor.
    func humanPinnedSessionIds() -> [String] {
        MacPinnedChatSessionStore.decode(pinnedChatSessionIdsRaw)
    }

    /// 2026-09-06: `includeTranscripts` exists because the published transcript
    /// set is chosen from the pins as they were BEFORE this save. Publishing a
    /// newly pinned session's tab without its transcript put an empty
    /// conversation on the phone until some unrelated edge happened to publish
    /// transcripts again. A pin that ADDS a session asks for them; pruning and
    /// unpinning still do not — they only ever remove.
    func savePinnedSessionIds(_ ids: [String], includeTranscripts: Bool = false) {
        do {
            pinnedChatSessionIdsRaw = try MacPinnedChatSessionStore.save(ids)
        } catch {
            showToast("Pinned tabs could not be updated")
            return
        }
        guard ChatPinnedSnapshotPublication.request(
            encodedPinnedIDs: pinnedChatSessionIdsRaw,
            publish: { _ in
                MacSyncEngine.shared.requestChatSnapshotPublication(
                    includeTranscripts: includeTranscripts
                )
            }
        ) else {
            showToast("Pinned tabs were saved, but their phone snapshot could not be verified")
            return
        }
    }

    func prunePinnedSessions() {
        guard !appModel.chatSessions.isEmpty else { return }
        let liveIds = Set(appModel.chatSessions.map(\.id))
        // Prunes the HUMAN's list. Using the merged list here would write the
        // anchor into their pins on the first prune pass.
        let current = humanPinnedSessionIds()
        let pruned = current.filter { liveIds.contains($0) }
        if pruned != current {
            savePinnedSessionIds(pruned)
        }
    }

    func pinSession(_ sessionId: String, selectAfterPin: Bool = true) {
        guard let session = appModel.chatSessions.first(where: { $0.id == sessionId }) else { return }
        // Explicitly pinning the anchor is allowed and meaningful: it says
        // "keep this one even after it stops being the live conversation".
        var ids = humanPinnedSessionIds()
        if !ids.contains(sessionId) {
            ids.append(sessionId)
            savePinnedSessionIds(ids, includeTranscripts: true)
            showToast("Pinned \(session.title)")
        }
        if selectAfterPin {
            renameTitle = session.title
            Task { await appModel.selectChatSession(session) }
        }
    }

    func unpinSession(_ sessionId: String) {
        switch ChatSidebarRowUnpinTransaction.execute(sessionID: sessionId) {
        case .unpinned(let encoded):
            pinnedChatSessionIdsRaw = encoded
            guard ChatPinnedSnapshotPublication.request(
                encodedPinnedIDs: encoded,
                publish: { _ in
                    MacSyncEngine.shared.requestChatSnapshotPublication(includeTranscripts: false)
                }
            ) else {
                showToast("Pinned tab closed locally, but its phone snapshot could not be verified")
                return
            }
        case .refusedInvalidSessionID:
            showToast("This tab cannot be unpinned")
        case .refusedAlreadyUnpinned:
            showToast("This tab was already unpinned")
        case .failed:
            // The store writes retention before this @AppStorage value. Do not
            // remove the tab optimistically or it would return after reload.
            showToast("Pinned tab could not be closed; it remains pinned")
        }
    }

    // 2026-07-24 (desktop-icons fix): `chatSessionDragProvider` deleted — the
    // AppKit SessionDragSource replaced SwiftUI .onDrag as the only drag
    // source (W1.3), leaving it caller-less, and its plain-text payload is
    // the exact shape Finder materializes as a .textClipping. The plain-text
    // PARSER below stays: it's harmless acceptance, not a producer.
    func handlePinnedSessionDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(chatSessionDragType.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: chatSessionDragType.identifier) { data, _ in
                    guard let data,
                          let sessionId = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        pinSessionFromDroppedPayload(sessionId)
                    }
                }
            }
            if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let object else { return }
                    let payload = String(describing: object)
                    DispatchQueue.main.async {
                        pinSessionFromDroppedPayload(payload)
                    }
                }
            }
        }
        return accepted
    }

    func pinSessionFromDroppedPayload(_ payload: String) {
        guard let sessionId = sessionIdFromDroppedPayload(payload) else { return }
        pinSession(sessionId, selectAfterPin: true)
    }

    func sessionIdFromDroppedPayload(_ payload: String) -> String? {
        let clean = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId: String
        if clean.hasPrefix(chatSessionDragPlainTextPrefix) {
            sessionId = String(clean.dropFirst(chatSessionDragPlainTextPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sessionId = clean
        }
        guard appModel.chatSessions.contains(where: { $0.id == sessionId }) else { return nil }
        return sessionId
    }
}
