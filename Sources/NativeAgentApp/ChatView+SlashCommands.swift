import EngineRuntime
import Foundation
import ToolRegistry
import SwiftUI
import NativeAgentShared
import ChatSessionWork
import PersistenceCore
import Dispatcher
// Blueprint: | `ChatView+SlashCommands.swift` | `ChatView`: `send` admits ordinary chat; built-in commands use `ChatSlashCommandRouting.perform` and preserve pending attachments |

extension ChatView {
    func send() {
        guard !isSubmittingSend else { return }
        if !voiceSessionId.isEmpty {
            Task { @MainActor in if await finishDictation() { send() } }
            return
        }
        guard !appModel.isSavingChatBrain else { return }
        guard !isCapturing else {
            showToast("Screen capture is still in progress")
            return
        }
        let attachments = pendingAttachments
        let message = text
        // Capture the edit time before clearing so this send cannot erase a newer draft in another panel.
        let messageEditedAt = draftEditedAt
        let composerSessionId = appModel.activeChatSessionId
        // Known commands consume no attachments; other slash text is sent unchanged.
        switch ChatSlashCommandRouting.decide(
            text: message,
            supportsDispatch: true
        ) {
        case .dispatch(let commandLine):
            // Slash commands preserve pending attachments because they send no message.
            handleSlashCommand(commandLine)
            return
        case .unsupportedHere(let command):
            // Unreachable with supportsDispatch: true; kept exhaustive so a new
            // decision case cannot silently fall through to a chat send.
            showToast(ChatSlashCommandRouting.unsupportedMessage(command: command))
            return
        case .sendAsMessage:
            break
        }
        isSubmittingSend = true
        Task { @MainActor in
            defer { isSubmittingSend = false }
            let acceptance = await appModel.startActiveChatTurn(
                message,
                attachments: attachments,
                expectedSessionId: composerSessionId
            )
            switch acceptance {
            case .accepted(let acceptedSessionId), .queued(let acceptedSessionId, _):
                // The acceptance path can suspend behind a pending Stop write.
                // Only clear the exact composer snapshot that was accepted;
                // preserve any edits or attachments added while it waited.
                guard appModel.activeChatSessionId == acceptedSessionId,
                      composerSessionId == acceptedSessionId,
                      text == message,
                      pendingAttachments == attachments
                else { return }
                appModel.clearChatDraftAfterSend(
                    message,
                    sessionId: acceptedSessionId,
                    editedAt: messageEditedAt
                )
                pendingAttachments = []
                // Ending dictation prevents cumulative transcripts from restoring sent words.
                endDictation()
                transcriptLatestRequest &+= 1
                scrollCoordinator.forceFollow()
            case .rejected(let failureMessage):
                showToast(failureMessage)
            }
        }
    }

    func handleSlashCommand(_ raw: String) {
        guard !isSubmittingSend else { return }
        guard !appModel.isSavingChatBrain else { return }
        guard !isCapturing else {
            showToast("Screen capture is still in progress")
            return
        }
        let commandDraft = text
        let commandSessionId = appModel.activeChatSessionId
        let commandEditedAt = draftEditedAt
        let disposition = ChatSlashCommandRouting.perform(
            raw, sessionId: commandSessionId,
            host: appModel,
            toast: { showToast($0) },
            mutationFinished: { succeeded, message in
                showToast(message)
                if succeeded {
                    clearSuccessfulSlashCommandDraft(commandDraft, sessionId: commandSessionId, editedAt: commandEditedAt)
                }
            }
        )
        switch disposition {
        case .presentation(let route):
            switch route {
            case .new:
                text = ""
                Task { await appModel.newChatSession() }
                return
            case .clear: clearConfirmation.request(sessionId: appModel.activeChatSessionId)
            case .help:
                appModel.chatMessages.append(ChatMessage(role: "system", content: ChatSlashCommandRegistry.helpText()))
            case .tools: ApplicationLifetime.shared.request(.skillsTools(.tools))
            case .export: exportCurrentChatToDownloads()
            default: preconditionFailure("Core requested a nonpresentation slash command")
            }
        case .consumed: break
        case .deferred: return
        case .refused(let message):
            showToast(message)
            return
        }
        // The command was taken. Only now does the composer lose its text.
        text = ""
    }

    func clearSuccessfulSlashCommandDraft(_ command: String, sessionId: String, editedAt: Date) {
        guard appModel.activeChatSessionId == sessionId,
              draftSessionId == sessionId,
              text == command else { return }
        appModel.clearChatDraftAfterSend(command, sessionId: sessionId, editedAt: editedAt)
    }
}

extension AppModel: ChatSlashCommandHost {
    var chatSlashReasoningEfforts: [String] {
        ProvidersFacade.reasoningOptions(from: engine.providers.catalog, model: chatModel).map(\.id)
    }
    func stageChatSlashBrain() { _ = enqueueChatBrainDefaultsSave() }
    func saveChatSlashBrain() async -> String { await saveChatBrainDefaults().userMessage }
    func compactChatSlashSession() async -> String { await compactActiveChat().userMessage }
    func rememberChatSlashFact(_ text: String) async -> (succeeded: Bool, message: String) {
        let result = await addMemoryFact(text)
        return (result.succeeded, result.userMessage)
    }
    func commitChatSlashNote(_ text: String) async -> (succeeded: Bool, message: String) {
        let result = await addNote(text)
        return (result.succeeded, result.userMessage)
    }
    func writeChatSlashScratch(key: String, value: String, sessionId: String) async -> (succeeded: Bool, message: String) {
        let result = await writeScratch(key: key, value: value, sessionId: sessionId)
        return (result.succeeded, result.userMessage)
    }
}
