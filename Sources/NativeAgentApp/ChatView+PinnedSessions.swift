import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension ChatView {
    func decodedPinnedSessionIds() -> [String] {
        MacPinnedChatSessionStore.decode(pinnedChatSessionIdsRaw)
    }

    func savePinnedSessionIds(_ ids: [String]) {
        do {
            pinnedChatSessionIdsRaw = try MacPinnedChatSessionStore.save(ids)
        } catch {
            showToast("Pinned tabs could not be updated")
            return
        }
        Task { @MainActor in
            await MacSyncEngine.shared.writeSnapshots()
        }
    }

    func prunePinnedSessions() {
        guard !appModel.chatSessions.isEmpty else { return }
        let liveIds = Set(appModel.chatSessions.map(\.id))
        let current = decodedPinnedSessionIds()
        let pruned = current.filter { liveIds.contains($0) }
        if pruned != current {
            savePinnedSessionIds(pruned)
        }
    }

    func pinSession(_ sessionId: String, selectAfterPin: Bool = true) {
        guard let session = appModel.chatSessions.first(where: { $0.id == sessionId }) else { return }
        var ids = decodedPinnedSessionIds()
        if !ids.contains(sessionId) {
            ids.append(sessionId)
            savePinnedSessionIds(ids)
            showToast("Pinned \(session.title)")
        }
        if selectAfterPin {
            renameTitle = session.title
            Task { await appModel.selectChatSession(session) }
        }
    }

    func unpinSession(_ sessionId: String) {
        guard decodedPinnedSessionIds().contains(sessionId) else { return }
        savePinnedSessionIds(decodedPinnedSessionIds().filter { $0 != sessionId })
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
