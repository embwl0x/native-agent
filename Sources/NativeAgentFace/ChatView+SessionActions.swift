import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatView+SessionActions.swift` | Session rename and export acts; saved transcript and speech remain body-owned |

extension ChatView {
    func showToast(_ message: String) { toasts.show(message) }

    func renameSession(_ sessionId: String, _ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !title.isEmpty else { return }
        Task { await appModel.renameChatSession(id: sessionId, title: title) }
    }

    func exportCurrentChat(onCommitted: @escaping () -> Void = {}) {
        let session = appModel.activeChatSessionId
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export here"
        panel.message = "Choose the folder for this conversation's Markdown export."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let grant = try await Task.detached {
                    let held = destination.startAccessingSecurityScopedResource()
                    defer { if held { destination.stopAccessingSecurityScopedResource() } }
                    return ResourceGrant(id: UUID(), name: destination.lastPathComponent,
                                         bookmark: try destination.bookmarkData(), writable: true)
                }.value
                let request = ConversationExportRequest(session: session, format: "markdown", destination: grant)
                guard case .artifact(let artifact) = try await appModel.chatAct(.exportConversation(request)) else {
                    throw appModel.chatProtocolFailure("the exported conversation artifact.")
                }
                onCommitted()
                if artifact.warnings.isEmpty { appModel.systemToasts.push(success: "Chat exported") }
                else { appModel.systemToasts.push(warn: "Chat exported; " + artifact.warnings.joined(separator: "; ")) }
            } catch { showToast(error.localizedDescription) }
        }
    }
}

extension ChatTurnCardInset {
    var showThinkingRow: Bool {
        appModel.turnPart("hasCard", for: appModel.activeChatSessionId) { $0?.card != nil }
    }
}
