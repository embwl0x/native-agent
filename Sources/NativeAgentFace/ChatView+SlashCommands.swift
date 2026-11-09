import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatView+SlashCommands.swift` | Draft-preserving sends and slash acts; execution and route validation belong to the body |

enum ChatSlashPage: Equatable, Sendable {
    case page(SidebarItem)
    case connector(String)
    case memories(query: String, choosingToForget: Bool)
}

extension ChatView {
    var isSavingComposerChoice: Bool { appModel.providerSavingChatBrain || composerCardState.savingChoice }

    func send() {
        guard !isSubmittingSend else { return }
        guard !isCapturing else { showToast("Screen capture is still in progress"); return }
        guard !isSavingComposerChoice else { showToast("The Chat model choice is still being saved"); return }
        let message = text
        switch ChatSlashCommandRouting.decide(text: message, supportsDispatch: true) {
        case .dispatch(let command): handleSlashCommand(command); return
        case .unknownCommand(let command): showToast(ChatSlashCommandRouting.unknownMessage(command: command)); return
        case .unsupportedHere(let command): showToast(ChatSlashCommandRouting.unsupportedMessage(command: command)); return
        case .sendAsMessage: break
        }
        if !voiceSessionId.isEmpty {
            Task { @MainActor in if await finishDictation() { send() } }
            return
        }
        let attachments = pendingAttachments
        let messageEditedAt = draftEditedAt
        let revision = draft.manualEditRevision
        let session = appModel.activeChatSessionId
        isSubmittingSend = true
        Task { @MainActor in
            defer { isSubmittingSend = false }
            switch await appModel.startActiveChatTurn(message, attachments: attachments, expectedSessionId: session, composerRevision: revision) {
            case .accepted(let accepted):
                guard accepted == session, appModel.activeChatSessionId == session,
                      draftSessionId == session, text == message, draftEditedAt == messageEditedAt,
                      draft.manualEditRevision == revision, pendingAttachments == attachments else { return }
                appModel.clearChatDraftAfterSend(message, sessionId: session, editedAt: messageEditedAt)
                pendingAttachments = []
                endDictation()
                transcriptLatestRequest &+= 1
            case .rejected(let failure): showToast(failure)
            }
        }
    }

    func handleSlashCommand(_ raw: String) {
        guard !isSubmittingSend else { return }
        guard !isCapturing else { showToast("Screen capture is still in progress"); return }
        let parts = raw.split(whereSeparator: \.isWhitespace)
        guard let name = parts.first.map(String.init), let route = ChatSlashCommandRegistry.descriptor(named: name)?.route else {
            showToast(ChatSlashCommandRouting.unknownMessage(command: raw))
            return
        }
        let argument = parts.dropFirst().joined(separator: " ")
        switch route {
        case .settings, .helpers, .agents, .today, .desk, .forget, .voice, .context:
            guard argument.isEmpty else { showToast("/" + name + " takes no arguments"); return }
        default: break
        }
        let captured = text, session = appModel.activeChatSessionId, editedAt = draftEditedAt
        switch route {
        case .voice:
            clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt)
            toggleVoice()
            return
        case .context:
            guard composerCardState.open(.context) else { showToast("Context receipt isn't available in this composer."); return }
            clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt)
            return
        case .clear:
            clearConfirmation.request(sessionId: session)
            clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt)
            return
        case .export:
            exportCurrentChat { clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt) }
            return
        case .tools:
            ApplicationLifetime.shared.request(.sidebar(.capabilities))
        case .settings, .connect, .helpers, .agents, .today, .desk, .memory, .forget:
            let page: ChatSlashPage
            switch route {
            case .settings: page = .page(.settings)
            case .helpers: page = .page(.bots)
            case .agents: page = .page(.connectors)
            case .today: page = .page(.activity)
            case .desk: page = .page(.desk)
            case .memory, .forget: page = .memories(query: argument, choosingToForget: route == .forget)
            case .connect:
                let service = ConnectorSetup.canonicalID(argument)
                switch service {
                case "", "telegram", "iphone": page = .page(.connectors)
                default:
                    guard ConnectorWizardSetupRoute.resolve(provider: service) != .unavailable else {
                        showToast("Setup for ‘" + argument + "’ isn't available through /connect. Use /connect to see connections.")
                        return
                    }
                    page = .connector(service)
                }
            default: return
            }
            endDictation()
            composerCardState.dismiss()
            ApplicationLifetime.shared.request(.chatShortcut(page))
        default:
            performSlashMutation(route, argument: argument, captured: captured, session: session, editedAt: editedAt)
            return
        }
        clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt)
    }

    private func performSlashMutation(_ route: ChatSlashCommandRoute, argument: String, captured: String, session: String, editedAt: Date) {
        isSubmittingSend = true
        Task { @MainActor in
            defer { isSubmittingSend = false }
            do {
                switch route {
                case .help:
                    try await appModel.chatAct(.appendSlashHelp(session: session)).checkedAcknowledgement()
                case .new:
                    appModel.chatSelectionGeneration = UUID()
                    let selection = appModel.chatSelectionGeneration
                    let created = try appModel.acceptedConversation(await appModel.chatAct(.createConversation))
                    guard appModel.chatSelectionGeneration == selection else { return }
                    clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt)
                    appModel.commitChatSessionSelection(created)
                    return
                case .model, .think, .fast:
                    showToast(try await appModel.performSlashBrain(route, argument: argument, session: session))
                case .persona:
                    guard !argument.isEmpty else { showToast("Usage: /persona <name>"); return }
                    _ = try await appModel.chatAct(.setPreference(key: "chatPersona", value: .string(argument))).checkedCommit()
                    showToast("Persona selected: " + argument)
                case .remember, .note:
                    guard !argument.isEmpty else { showToast("/" + route.rawValue + " requires some text"); return }
                    let act: FaceAct = route == .remember ? .remember(text: argument) : .commitNote(text: argument)
                    try await appModel.chatAct(act).checkedAcknowledgement()
                    showToast(route == .remember ? "Memory saved" : "Note committed")
                case .scratch:
                    let parts = argument.split(separator: " ", maxSplits: 1)
                    guard let key = parts.first, let value = parts.dropFirst().first else {
                        showToast("Usage: /scratch <key> <value>"); return
                    }
                    let result = try await appModel.chatAct(.writeScratch(session: session, key: String(key), value: String(value))).checkedValue()
                    guard case .string(let text) = result else { throw appModel.chatProtocolFailure("the scratch writer's result.") }
                    showToast(text)
                default: throw appModel.chatProtocolFailure("a supported slash mutation.")
                }
                clearSuccessfulSlashCommandDraft(captured, sessionId: session, editedAt: editedAt)
            } catch { showToast(error.localizedDescription) }
        }
    }

    func clearSuccessfulSlashCommandDraft(_ command: String, sessionId: String, editedAt: Date) {
        guard appModel.composerDraft(for: sessionId).text == command else { return }
        appModel.clearChatDraftAfterSend(command, sessionId: sessionId, editedAt: editedAt)
    }
}

extension ChatSlashPage {
    @MainActor @ViewBuilder
    func content(close: @escaping () -> Void) -> some View {
        switch self {
        case .page(let item): ShellPageContent(item: item)
        case .connector(let service): ConnectorWizardView(provider: service, onDismiss: close)
        case .memories(let query, let choosingToForget):
            ShellPageFrame(title: "Memories", subtitle: choosingToForget
                           ? "Choose a memory and use ‘Forget this…’ to confirm." : nil, alive: true) {
                FacePageView(page: "memories").modifier(MemoriesFaceNavigation(initialQuery: query))
            }
        }
    }
}
