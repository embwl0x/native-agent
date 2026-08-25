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
        guard ChatPinnedSnapshotPublication.request(
            encodedPinnedIDs: pinnedChatSessionIdsRaw,
            publish: { _ in
                MacSyncEngine.shared.requestChatSnapshotPublication(includeTranscripts: false)
            }
        ) else {
            showToast("Pinned tabs were saved, but their phone snapshot could not be verified")
            return
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
