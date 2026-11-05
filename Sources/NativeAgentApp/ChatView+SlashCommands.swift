import EngineRuntime
import Foundation
import ToolRegistry
import SwiftUI
import NativeAgentShared
import ChatSessionWork
import PersistenceCore
import Dispatcher
import AppToolRuntime
import Connectors
import ChatToolRuntime
// Blueprint: | `ChatView+SlashCommands.swift` | `ChatView`: Shared slash dispatch, setup navigation and attachment preservation |

enum ChatSlashPage: Equatable, Sendable {
    case settings, connectors, helpers, today, desk, telegram, iphone
    case connector(String)
    case memories(query: String, choosingToForget: Bool)
}

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
        // Capture edit time before clearing so this send cannot erase a newer draft in another panel.
        let messageEditedAt = draftEditedAt
        let composerSessionId = appModel.activeChatSessionId
        // Slash commands consume no attachments; paths and slash prose remain messages.
        switch ChatSlashCommandRouting.decide(
            text: message,
            supportsDispatch: true
        ) {
        case .dispatch(let commandLine):
            // Preserve attachments because commands send no message.
            handleSlashCommand(commandLine)
            return
        case .unsupportedHere(let command):
            // Keep the switch exhaustive so a new dispatch decision cannot silently become a chat send.
            showToast(ChatSlashCommandRouting.unsupportedMessage(command: command))
            return
        case .unknownCommand(let command):
            showToast(ChatSlashCommandRouting.unknownMessage(command: command))
            return
        case .sendAsMessage:
            break
        }
        // Recognize /voice before ending dictation so stopping cannot finish and immediately restart recording.
        if !voiceSessionId.isEmpty {
            Task { @MainActor in if await finishDictation() { send() } }
            return
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
            case .accepted(let acceptedSessionId):
                // Acceptance may wait behind Stop; clear only accepted text and attachments so newer edits survive.
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
                // End dictation so cumulative recognition cannot restore sent words.
                endDictation()
                transcriptLatestRequest &+= 1
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
        case .presentation(let route, let argument):
            switch route {
            case .new:
                text = ""
                Task { await appModel.newChatSession() }
                return
            case .clear: clearConfirmation.request(sessionId: appModel.activeChatSessionId)
            case .help:
                appModel.engine.transcripts.appendMessage(
                    ChatMessage(role: "system", content: ChatSlashCommandRegistry.helpText()),
                    to: appModel.activeChatSessionId,
                    leads: false
                )
            case .tools: ApplicationLifetime.shared.request(.skillsTools(.tools))
            case .export: exportCurrentChatToDownloads()
            case .settings, .helpers, .today, .desk, .memory, .forget, .agents, .connect:
                if route == .connect, !argument.isEmpty {
                    let service = InlineInteractionRegistry.canonicalConnectorID(argument)
                    guard service == "telegram" || service == "iphone"
                            || ConnectorWizardSetupRoute.resolve(provider: service) != .unavailable else {
                        showToast("Setup for ‘\(argument)’ isn't available through /connect. Use /connect to see connections.")
                        return
                    }
                }
                if route == .agents || (route == .connect && argument.isEmpty) {
                    let tab = route == .agents ? "agents" : "connectors"
                    let layout = appModel.engine.layout.availability
                    guard ShellRailTab.shown(.connectors, ConnectorsRailPage.tabs, layout)
                        .contains(where: { $0.key == tab }) else {
                        showToast("/\(route.rawValue) isn't available: its Connectors tab is hidden in your layout.")
                        return
                    }
                    UserDefaults.standard.set(tab,
                                              forKey: ShellRailTab.storageKey(.connectors))
                }
                endDictation()
                composerCardState.dismiss()
                let page: ChatSlashPage
                switch route {
                case .settings: page = .settings
                case .helpers: page = .helpers
                case .today: page = .today
                case .desk: page = .desk
                case .memory, .forget:
                    page = .memories(query: argument, choosingToForget: route == .forget)
                case .agents: page = .connectors
                case .connect:
                    let service = InlineInteractionRegistry.canonicalConnectorID(argument)
                    switch service {
                    case "": page = .connectors
                    case "telegram": page = .telegram
                    case "iphone": page = .iphone
                    default: page = .connector(service)
                    }
                default: preconditionFailure("Expected a page command")
                }
                ApplicationLifetime.shared.request(.chatShortcut(page))
            case .voice:
                // Capture dictation's draft only after the command is removed.
                text = ""
                toggleVoice()
                return
            case .context:
                guard composerCardState.open(.context) else {
                    showToast("Context receipt isn't available in this composer.")
                    return
                }
            default: preconditionFailure("Core requested a nonpresentation slash command")
            }
        case .consumed: break
        case .deferred: return
        case .refused(let message):
            showToast(message)
            return
        }
        // Clear composer text only after the command is accepted.
        text = ""
    }

    func clearSuccessfulSlashCommandDraft(_ command: String, sessionId: String, editedAt: Date) {
        guard appModel.activeChatSessionId == sessionId,
              draftSessionId == sessionId,
              text == command else { return }
        appModel.clearChatDraftAfterSend(command, sessionId: sessionId, editedAt: editedAt)
    }
}

extension ChatSlashPage {
    @MainActor @ViewBuilder
    func content(close: @escaping () -> Void) -> some View {
        switch self {
        case .settings: FacePageView(page: "settings")
        case .connectors: ConnectorsRailPage()
        case .telegram: TelegramView()
        case .iphone: MacPairingView()
        case .connector(let service):
            ConnectorWizardView(provider: service, onDismiss: close)
        case .helpers: FacePageView(page: "bots")
        case .today: TodayView()
        case .desk: FacePageView(page: "desk").modifier(DeskFaceEditors())
        case .memories(let query, let choosingToForget):
            ShellPageFrame(title: "Memories", subtitle: choosingToForget
                           ? "Choose a memory and use ‘Forget this…’ to confirm." : nil, alive: true) {
                FacePageView(page: "memories").modifier(MemoriesFaceNavigation(initialQuery: query))
            }
        }
    }
}

extension AppModel: ChatSlashCommandHost {
    var chatSlashReasoningEfforts: [String] {
        ProvidersFacade.reasoningOptions(from: engine.providers.catalog,
            providers: engine.providers.connections, providerID: chatProvider, model: chatModel).map(\.id)
    }
    func stageChatSlashBrain() { _ = enqueueChatBrainDefaultsSave() }
    func saveChatSlashBrain() async -> String { await saveChatBrainDefaults().userMessage }
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
