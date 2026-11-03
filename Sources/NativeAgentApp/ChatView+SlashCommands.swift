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
// Blueprint: | `ChatView+SlashCommands.swift` | `ChatView`: shared slash recognition and execution preserve attachments; Simple/Advanced commands open existing pages in SimpleSetupPanel, voice action and composer context receipt |

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
        // Capture the edit time before clearing so this send cannot erase a newer draft in another panel.
        let messageEditedAt = draftEditedAt
        let composerSessionId = appModel.activeChatSessionId
        // Commands consume no attachments. Paths and slash prose stay messages.
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
        case .unknownCommand(let command):
            showToast(ChatSlashCommandRouting.unknownMessage(command: command))
            return
        case .sendAsMessage:
            break
        }
        // Recognize /voice before finishing dictation, so it can stop the
        // current recording rather than finish it and immediately start again.
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
        case .presentation(let route, let argument):
            switch route {
            case .new:
                text = ""
                Task { await appModel.newChatSession() }
                return
            case .clear: clearConfirmation.request(sessionId: appModel.activeChatSessionId)
            case .help:
                appModel.engine.transcripts.appendMessage(ChatMessage(role: "system", content: ChatSlashCommandRegistry.helpText()), to: appModel.activeChatSessionId, leads: false)
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
                    default: page = .connector(service) // Checked wizard route above.
                    }
                default: preconditionFailure("Expected a page command")
                }
                ApplicationLifetime.shared.request(.chatShortcut(page))
            case .voice:
                // Dictation must capture the draft after the command is gone.
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

extension ChatSlashPage {
    @MainActor @ViewBuilder
    func content(close: @escaping () -> Void) -> some View {
        switch self {
        case .settings: SetupView()
        case .connectors: ConnectorsRailPage()
        case .telegram: TelegramView()
        case .iphone: MacPairingView()
        case .connector(let service):
            ConnectorWizardView(provider: service, onDismiss: close)
        case .helpers:
            BotsShelfView(onContinue: { destination in
                ApplicationLifetime.shared.request(destination)
            })
        case .today: TodayView()
        case .desk: DeskPageView(rootRouteVersion: 0)
        case .memories(let query, let choosingToForget):
            ShellPageFrame(title: "Memories", subtitle: choosingToForget
                           ? "Choose a memory and use ‘Forget this…’ to confirm." : nil, alive: true) {
                MemoriesPageView(initialQuery: query)
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
