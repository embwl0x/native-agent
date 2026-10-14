import EngineRuntime
import Foundation
import ToolRegistry
import SwiftUI
import NativeAgentShared
import ChatOrchestration
import PersistenceCore
import Privacy
import TurnTrace
import Dispatcher

extension ChatView {
    func send() {
        guard !isSubmittingSend else { return }
        guard !appModel.isSavingChatBrain else { return }
        guard !isCapturing else {
            showToast("Screen capture is still in progress")
            return
        }
        let attachments = pendingAttachments
        let message = text
        // 2026-09-06: the snapshot's own edit time, captured BEFORE the box is
        // cleared (clearing `text` stamps a fresh one). The send-clear carries
        // it so sending older text here cannot delete a newer unsent edit made
        // in a detached panel on the same conversation.
        let messageEditedAt = draftEditedAt
        let composerSessionId = appModel.activeChatSessionId
        // Known commands consume no attachments; other slash text is sent unchanged.
        switch ChatSlashCommandRouting.decide(
            text: message,
            dynamicToolNames: capabilitiesStore.slashCommandNames,
            supportsDispatch: true
        ) {
        case .dispatch(let commandLine):
            // 2026-09-06: this used to drop the pending attachments on the
            // floor. A slash command sends nothing, so it consumes nothing —
            // and cancelling the /clear confirmation left the attachments
            // already gone. Picking the same command from the popover never
            // came through here, so mouse and Return also disagreed.
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
                text = ""
                // H5: the composer's draft is view-local @State now, so clearing
                // `text` does not clear the persisted copy automatically.
                appModel.clearChatDraftAfterSend(
                    message,
                    sessionId: acceptedSessionId,
                    editedAt: messageEditedAt
                )
                draftAdoptedText = ""
                pendingAttachments = []
                // 2026-09-06: the composer's words have been sent, but the
                // recognizer's transcript is cumulative and its pre-dictation
                // base still pointed at them — the next update wrote the whole
                // already-sent phrase back into the empty box.
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
            tools: capabilitiesStore.slashCatalog.map { ($0.name, $0.availableNow) }, host: appModel,
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
                appModel.commitChatDraft("", sessionId: appModel.activeChatSessionId)
                draftAdoptedText = ""
                Task { await appModel.newChatSession() }
                return
            case .clear: clearConfirmation.request(sessionId: appModel.activeChatSessionId)
            case .help:
                appModel.chatMessages.append(ChatMessage(role: "system", content: ChatSlashCommandRegistry.helpText()))
            case .tools: NativeAgentAppCoordinator.shared.request(.skillsTools(.tools))
            case .nextgen:
                NotificationCenter.default.post(name: .openNextGenRequest, object: nil)
                showToast("Navigating to NextGen in Capabilities\u{2026}")
            case .export: exportCurrentChatToDownloads()
            default: preconditionFailure("Core requested a nonpresentation slash command")
            }
        case .consumed: break
        case .deferred: return
        case .tool(let name, let argument):
            if let capability = capabilitiesStore.slashCatalog.first(where: { $0.name == name }) {
                Task { await dispatchSlashCommandTool(cap: capability, freeText: argument, sessionId: commandSessionId) }
            }
        case .refused(let message):
            showToast(message)
            return
        }
        // The command was taken. Only now does the composer lose its text.
        text = ""
        appModel.commitChatDraft("", sessionId: appModel.activeChatSessionId)
        draftAdoptedText = ""
    }

    func clearSuccessfulSlashCommandDraft(_ command: String, sessionId: String, editedAt: Date) {
        guard appModel.activeChatSessionId == sessionId,
              draftSessionId == sessionId,
              text == command else { return }
        text = ""
        appModel.clearChatDraftAfterSend(command, sessionId: sessionId, editedAt: editedAt)
        draftAdoptedText = ""
    }

    @MainActor
    func dispatchSlashCommandTool(cap: ToolCapability, freeText: String, sessionId: String) async {
        var plan = capabilitiesStore.planDispatch(toolName: cap.name, freeText: freeText)
            ?? DispatchArgPlan(tool: cap, mode: .zeroArgs, prefilled: [:])
        // Carried through the form sheet so a submission made after a session
        // switch still lands where the command was typed (2026-09-06).
        plan.sessionId = sessionId

        switch plan.mode {
        case .zeroArgs:
            await appModel.engine.runChatSlashCommand(tool: cap.name, input: [:], sessionId: sessionId)

        case .singleStringArg(let field):
            let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Need the user to supply the value — fall back to a form.
                currentDispatchPlan = plan
                showToolInputForm = true
            } else {
                await appModel.engine.runChatSlashCommand(
                    tool: cap.name,
                    input: [field: trimmed],
                    sessionId: sessionId
                )
            }

        case .formNeeded:
            currentDispatchPlan = plan
            showToolInputForm = true
        }
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
