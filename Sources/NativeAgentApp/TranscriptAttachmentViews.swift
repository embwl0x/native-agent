import ApprovalTransactions
import ChatTurnRuntime
import EngineRuntime
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptAttachmentViews.swift` | What each document attachment draws: the transcript's existing card, table and row views |

/// The hosted root. It carries the transcript host's whole environment, so the app model, the card action and the appearance
/// reach every attachment as they reach the rest of the chat.
struct TranscriptAttachmentRoot: View {
    let box: TranscriptAttachmentBox

    var body: some View {
        if let environment = box.environment {
            TranscriptAttachmentBody(box: box)
                .environment(\.self, environment)
        }
    }
}

/// Grows to its whole height at the width it is given, and reports every size change so the document re-lays its paragraph
/// (a card answered, details opened, an image loaded).
private struct TranscriptAttachmentBody: View {
    let box: TranscriptAttachmentBox

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in box.resized() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
    }

    @ViewBuilder private var content: some View {
        switch box.model {
        case .card(let card):
            TranscriptCardAttachment(card: card)
        case .approval(let message):
            InlineApprovalCard(message: message)
        case .table(let table, let cells):
            ChatMarkdownTableView(table: table, cells: cells)
                .font(ShellType.body)
        case .image(let attachment):
            MessageLocalImageAttachmentView(attachment: attachment)
        case .voice(let attachment, let transcript, let isOwn):
            TranscriptVoiceAttachment(attachment: attachment, transcript: transcript, isOwn: isOwn)
        case .file(let attachment):
            MessageAttachmentChipView(attachment: attachment)
        case .otherRoom(let exchange):
            TranscriptOtherRoomAttachment(exchange: exchange, open: box.open)
        case .envelope(let content):
            ShellEnvelopeRow(content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .trouble(let sessionID):
            TranscriptTroubleAttachment(sessionID: sessionID)
        case .missing:
            EmptyView()
        }
    }

    /// What VoiceOver says for the attachment as a whole; its buttons stay reachable inside it.
    private var label: String {
        switch box.model {
        case .card(let card): card.title
        case .approval: "Approval request"
        case .table: "Table"
        case .image(let attachment): Self.name(of: attachment) ?? "Image"
        case .voice: "Voice note"
        case .file(let attachment): Self.name(of: attachment) ?? "File"
        case .otherRoom(let exchange): exchange.title
        case .envelope(let content): ChatShellEnvelope.headline(content)
        case .trouble: "Reply failed"
        case .missing: ""
        }
    }

    private static func name(of attachment: PersistedAttachment) -> String? {
        if let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        return nil
    }
}

/// One card, acted on through the chat's card action, at the reply column's width as under a reply today.
private struct TranscriptCardAttachment: View {
    let card: InlineCardModel
    @Environment(\.inlineCardAction) private var action

    var body: some View {
        ChatInlineCardHost(cards: [card], action: action)
            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}

private struct TranscriptVoiceAttachment: View {
    let attachment: PersistedAttachment
    let transcript: String
    let isOwn: Bool
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VoiceNoteBubble(id: attachment.id, transcript: transcript, isOwn: isOwn, speaker: appModel.agentDisplayName) { [attachment] in
            guard let path = attachment.path, !path.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: path)
        }
        .font(ShellType.body)
    }
}

/// Opens the contact thread through the document view; a contact no longer in the list cannot be opened.
private struct TranscriptOtherRoomAttachment: View {
    let exchange: OtherRoomExchange
    let open: (OtherRoomExchange) -> Void
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            open(exchange)
        } label: {
            OtherRoomExchangePreview(exchange: exchange)
        }
        .buttonStyle(.plain)
        .disabled(!appModel.engine.contactThreads.contacts.contains { $0.id == exchange.contactID })
    }
}

/// The failed turn's card, read from the transcript owner for this session so it follows the conversation's tail.
private struct TranscriptTroubleAttachment: View {
    let sessionID: String
    @Environment(AppModel.self) private var appModel
    @Environment(\.transcriptOpenSettings) private var openSettings

    var body: some View {
        let messages = appModel.engine.transcripts.messages(for: sessionID)
        if let tail = ChatTurnFailure.read(messages) {
            ShellTroubleCard(
                message: tail.message,
                failure: tail.failure,
                showsStuckLink: ChatShellTroubleState.showsStuckLink(messages),
                onRetry: {
                    Task { await appModel.regenerateAssistantMessage(tail.message) }
                },
                onContinue: {
                    Task { await appModel.continueFailedTurn(tail.message) }
                },
                onOpenSettings: {
                    openSettings()
                }
            )
        }
    }
}

/// Opens Settings for the trouble card's stuck link. The chat that mounts the transcript binds it to its own page opener
/// (`InlineInteractionChatBinding.openPage(.settings)`); unbound, the link does nothing.
struct TranscriptOpenSettingsKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var transcriptOpenSettings: @Sendable @MainActor () -> Void {
        get { self[TranscriptOpenSettingsKey.self] }
        set { self[TranscriptOpenSettingsKey.self] = newValue }
    }
}
