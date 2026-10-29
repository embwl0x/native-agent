import Foundation
import PersistenceCore
import Transcripts
import SwiftUI
import UniformTypeIdentifiers
import DeviceSync
// Blueprint: | `ChatView+PinnedSessions.swift` | `ChatView`: human pin reads and pruning; additive pinning delegates to `TranscriptsFacade` |

extension ChatView {
    /// Human pins exclude the anchor, which must not become a persisted pin.
    func humanPinnedSessionIds() -> [String] {
        appModel.engine.transcripts.pinnedSessionIDs
    }

    func prunePinnedSessions() {
        guard !appModel.engine.transcripts.sessions.isEmpty else { return }
        let liveIds = Set(appModel.engine.transcripts.sessions.map(\.id))
        // Prunes the HUMAN's list. Using the merged list here would write the
        // anchor into their pins on the first prune pass.
        let current = humanPinnedSessionIds()
        let pruned = current.filter { liveIds.contains($0) }
        guard pruned != current else { return }
        do {
            let encoded = try appModel.engine.transcripts.savePinnedSessionIDs(pruned)
            if !appModel.engine.transcripts.publishPins(encoded, includeTranscripts: false) {
                showToast("Pinned tabs were saved on this Mac, but could not be shared with your phone")
            }
        } catch {
            showToast("Pinned tabs could not be updated")
        }
    }

    func pinSession(_ sessionId: String, selectAfterPin: Bool = true) {
        guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionId }) else { return }
        // Explicitly pinning the anchor is allowed and meaningful: it says
        // "keep this one even after it stops being the live conversation".
        do {
            let result = try appModel.engine.transcripts.pinSession(sessionId)
            guard result.shared else {
                showToast("Pinned tabs were saved on this Mac, but could not be shared with your phone")
                return
            }
            if result.changed { showToast("Pinned \(session.title)") }
        } catch {
            showToast("Pinned tabs could not be updated")
            return
        }
        if selectAfterPin {
            Task { await appModel.selectChatSession(session) }
        }
    }

    func unpinSession(_ sessionId: String) {
        do {
            switch try appModel.engine.transcripts.closePinnedTab(sessionId) {
        case .closed(let encoded):
            guard appModel.engine.transcripts.publishPins(encoded, includeTranscripts: false) else {
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

    // Plain-text drops are accepted, but SessionDragSource emits only the custom session type.
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
