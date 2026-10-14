import Foundation
import PersistenceCore
import Transcripts
import SwiftUI
import UniformTypeIdentifiers
import DeviceSync

extension ChatView {
    /// The human's pins WITHOUT the anchor — what `savePinnedSessionIds` must
    /// persist. Writing the merged list back would silently adopt the anchor as
    /// a real pin, and it would stay pinned after it stopped being the anchor.
    func humanPinnedSessionIds() -> [String] {
        ChatSessionRetention.decode(pinnedChatSessionIdsRaw)
    }

    /// 2026-09-06: `includeTranscripts` exists because the published transcript
    /// set is chosen from the pins as they were BEFORE this save. Publishing a
    /// newly pinned session's tab without its transcript put an empty
    /// conversation on the phone until some unrelated edge happened to publish
    /// transcripts again. A pin that ADDS a session asks for them; pruning and
    /// unpinning still do not — they only ever remove.
    @discardableResult
    func savePinnedSessionIds(_ ids: [String], includeTranscripts: Bool = false) -> Bool {
        do {
            pinnedChatSessionIdsRaw = try ChatSessionRetention.save(ids)
        } catch {
            showToast("Pinned tabs could not be updated")
            return false
        }
        guard ChatSessionRetention.request(
            encodedPinnedIDs: pinnedChatSessionIdsRaw,
            publish: { _ in
                NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(
                    includeTranscripts: includeTranscripts
                )
            }
        ) else {
            showToast("Pinned tabs were saved on this Mac, but could not be shared with your phone")
            return false
        }
        return true
    }

    func prunePinnedSessions() {
        guard !appModel.engine.transcripts.sessions.isEmpty else { return }
        let liveIds = Set(appModel.engine.transcripts.sessions.map(\.id))
        // Prunes the HUMAN's list. Using the merged list here would write the
        // anchor into their pins on the first prune pass.
        let current = humanPinnedSessionIds()
        let pruned = current.filter { liveIds.contains($0) }
        if pruned != current {
            savePinnedSessionIds(pruned)
        }
    }

    func pinSession(_ sessionId: String, selectAfterPin: Bool = true) {
        guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionId }) else { return }
        // Explicitly pinning the anchor is allowed and meaningful: it says
        // "keep this one even after it stops being the live conversation".
        var ids = humanPinnedSessionIds()
        if !ids.contains(sessionId) {
            ids.append(sessionId)
            guard savePinnedSessionIds(ids, includeTranscripts: true) else { return }
            showToast("Pinned \(session.title)")
        }
        if selectAfterPin {
            renameTitle = session.title
            Task { await appModel.selectChatSession(session) }
        }
    }

    func unpinSession(_ sessionId: String) {
        do {
            switch try ChatSessionRetention.closePinnedTab(sessionID: sessionId) {
        case .closed(let encoded):
            pinnedChatSessionIdsRaw = encoded
            guard ChatSessionRetention.request(
                encodedPinnedIDs: encoded,
                publish: { _ in
                    NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
                }
            ) else {
                showToast("Pinned tab closed locally, but its phone snapshot could not be verified")
                return
            }
        case .refusedInvalidSessionID:
            showToast("This tab cannot be unpinned")
        case .refusedAlreadyUnpinned:
            showToast("This tab was already unpinned")
            }
        } catch {
            // A failed retention write leaves the visible pin unchanged.
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
        guard appModel.engine.transcripts.sessions.contains(where: { $0.id == sessionId }) else { return nil }
        return sessionId
    }
}
