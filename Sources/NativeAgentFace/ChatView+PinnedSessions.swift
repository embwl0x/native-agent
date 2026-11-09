import Foundation
import SwiftUI
import NativeAgentShared
import AppKit
// Blueprint: | `ChatView+PinnedSessions.swift` | `ChatView`: feed pin presentation, body pin acts and local drop intake |

extension ChatView {
    /// Exclude the live anchor from saved human pins so following a conversation cannot persist it as a pin.
    func humanPinnedSessionIds() -> [String] {
        appModel.face.slot(.sessions).select("pins", as: SessionListFace.self) { $0?.pinnedIDs ?? [] }
    }

    func pinSession(_ sessionId: String, selectAfterPin: Bool = true) {
        Task {
            let result = await appModel.performChatMutation(.pinConversation(session: sessionId), success: "Conversation pinned")
            guard result.succeeded else { showToast(result.agentMessage); return }
            if selectAfterPin { await appModel.selectChatSession(id: sessionId) }
        }
    }

    func unpinSession(_ sessionId: String) {
        Task {
            let result = await appModel.performChatMutation(.unpinConversation(session: sessionId), success: "Conversation unpinned")
            if !result.succeeded { showToast(result.agentMessage) }
        }
    }

    func handlePinnedSessionDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            let type: String
            if provider.hasItemConformingToTypeIdentifier(chatSessionDragType) { type = chatSessionDragType }
            else if provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text") { type = "public.utf8-plain-text" }
            else { continue }
            accepted = true
            ChatAttachmentTypeResolver.loadProviderData(provider, type: type) { data, failure in
                let payload = data.flatMap { String(data: $0, encoding: .utf8) }
                Task { @MainActor in
                    if let failure { showToast(failure); return }
                    guard let payload else { showToast("Couldn't read the conversation drop"); return }
                    pinSessionFromDroppedPayload(payload)
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
        guard !sessionId.isEmpty else { return nil }
        return sessionId
    }
}
