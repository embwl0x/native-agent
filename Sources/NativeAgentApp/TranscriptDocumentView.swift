import AppKit
import ChatTurnRuntime
import EngineRuntime
import MultimodalTTS
import NativeAgentShared
import Observation
import SwiftUI

// Blueprint: | `TranscriptDocumentView.swift` | `TranscriptDocumentView`: any run of a conversation as one document; hover bar, sheets, host handle |

/// Any run of a conversation as one selectable document: the main chat, the detached panel, Shotgun's last rows, a contact or crew thread.
/// The host hands over rows and room; the view owns layout, place, folds, the live reply's reveal, the menu and find.
struct TranscriptDocumentView<Groups: RandomAccessCollection<MessageGroup>>: View {
    var sessionID: String
    var groups: Groups
    var cardsByRow: [String: [TranscriptReadout.Card]] = [:]
    var exchanges: [OtherRoomExchange] = []
    /// The failed-turn card closes the document.
    var showsTrouble = false
    /// The row the running turn streams into (`turns.streamingBubbleIds[sessionID]`); nil when nothing streams here.
    var streamingMessageID: String?
    /// Room the host's chrome covers: the header above, the composer glass and working card below. The text scrolls under both.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Find, Latest, reveal and the at-end signal for the host's Latest pill.
    var handle: TranscriptDocumentHandle?

    @Environment(AppModel.self) private var appModel
    @State private var model = TranscriptDocumentModel()
    @State private var voice = VoiceOutputController.sharedMessagePlayback

    var body: some View {
        TranscriptDocumentRepresentable(
            sessionID: sessionID, groups: groups, cardsByRow: cardsByRow, exchanges: exchanges, showsTrouble: showsTrouble,
            streamingMessageID: streamingMessageID, topInset: topInset, bottomInset: bottomInset, handle: handle,
            model: model, appModel: appModel
        )
        .overlay(alignment: .topLeading) { TranscriptHoverLayer(model: model) }
        .overlay(alignment: .bottom) { TranscriptToastLayer(model: model, bottomInset: bottomInset) }
        .sheet(item: $model.dataMessage) { MessageJSONSheet(message: $0) }
        .sheet(item: $model.openedContact) { contact in
            SimpleContactThread(contact: contact, store: appModel.engine.contactThreads) { model.openedContact = nil }
                .frame(minWidth: 600, minHeight: 500)
        }
        .modifier(FailedTurnRetryConfirmation(
            failure: $model.retryFailure,
            onRetry: { regenerate() },
            onContinue: { continueTurn() }
        ))
        // Read-aloud failures surface once, on the transcript that started the reading.
        .onChange(of: voice.errorMessage) {
            if let owner = model.speechOwnerID, let message = voice.consumeError(ownerID: owner) { model.show(message) }
        }
        .onAppear { appModel.engine.contactThreads.start() }
    }

    private func regenerate() {
        guard let message = model.retryMessage else { return }
        Task { await appModel.regenerateAssistantMessage(message) }
    }

    private func continueTurn() {
        guard let message = model.retryMessage else { return }
        Task { await appModel.continueFailedTurn(message) }
    }
}

/// The host's line to its transcript: find (⌘F, ⌘G, ⇧⌘G), Latest, reveal a message, and whether the reader is at the end.
@MainActor @Observable
final class TranscriptDocumentHandle {
    /// The reader is at the end of the document; the host's Latest pill shows while this is false.
    var isAtEnd = true
    @ObservationIgnored weak var controller: TranscriptDocumentController?
    /// A reveal asked before the view mounted; the view takes it when it does.
    @ObservationIgnored var pendingReveal: String?

    init() {}

    func showFind() { controller?.find(.showFindInterface) }
    func findNext() { controller?.find(.nextMatch) }
    func findPrevious() { controller?.find(.previousMatch) }
    /// Back to the end; the document follows from there.
    func goToLatest() { controller?.goToLatest() }

    /// Centres the message. One that is not in the document yet is revealed when it arrives, until another reveal replaces it.
    func reveal(messageID: String) {
        if let controller {
            controller.reveal(messageID)
        } else {
            pendingReveal = messageID
        }
    }
}

/// What the transcript shows over and beside its text: the hover bar, code copy, toasts and the sheets its menu opens.
@MainActor @Observable
final class TranscriptDocumentModel {
    var hover: TranscriptHover?
    var codeCopy: TranscriptCodeCopy?
    /// "Copied", a memory result, a read-aloud failure: each shows for as long as a bubble's toast did.
    let toasts = ChatToastQueue(displayDuration: 2.5)
    var dataMessage: ChatMessage?
    var openedContact: AgentContactPresentation?
    var retryFailure: ChatTurnFailure?
    @ObservationIgnored var retryMessage: ChatMessage?
    /// While the pointer is on the hover bar, the bar stays with its message.
    @ObservationIgnored var barHovered = false
    @ObservationIgnored var speechOwnerID: String?
    @ObservationIgnored weak var controller: TranscriptDocumentController?

    func show(_ text: String) {
        toasts.show(text)
    }
}

/// The hovered message and where its bar hangs: `anchor` is the bar's bottom at the message's leading (or, seated right, trailing) edge.
struct TranscriptHover: Equatable {
    var message: ChatMessage
    var isLastAssistant: Bool
    var seatsRight: Bool
    var anchor: CGPoint
}

/// A hovered code block's copy button; `anchor` is the button's trailing centre in its header strip.
struct TranscriptCodeCopy: Equatable {
    var blockID: String
    var anchor: CGPoint
}

private struct TranscriptHoverLayer: View {
    let model: TranscriptDocumentModel

    var body: some View {
        if let hover = model.hover {
            HStack(spacing: NativeAgentSpacing.sm) {
                if hover.seatsRight { stamp(hover) }
                BubbleHoverBar(
                    message: hover.message,
                    isLastAssistant: hover.isLastAssistant,
                    onCopy: { model.controller?.copyMessage(hover.message.id) },
                    onRegenerate: { model.controller?.regenerate(hover.message.id) },
                    onReadAloud: { model.controller?.toggleReadAloud(hover.message.id) }
                )
                .onHover { hovering in
                    model.barHovered = hovering
                    if !hovering { model.controller?.rehover() }
                }
                if !hover.seatsRight { stamp(hover) }
            }
            .fixedSize()
            .alignmentGuide(.leading) { size in hover.seatsRight ? size.width - hover.anchor.x : -hover.anchor.x }
            .alignmentGuide(.top) { size in size.height - hover.anchor.y }
            .accessibilityHidden(true)
            .transition(.opacity)
        }
        if let code = model.codeCopy {
            Button {
                model.controller?.copyCode(code.blockID)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(NativeAgentFont.tag)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy code")
            .accessibilityLabel("Copy code block")
            .fixedSize()
            .alignmentGuide(.leading) { size in size.width - code.anchor.x }
            .alignmentGuide(.top) { size in size.height / 2 - code.anchor.y }
        }
    }

    private func stamp(_ hover: TranscriptHover) -> some View {
        let isUser = hover.message.role == "user"
        let line = [UserDisplayFormatters.chatTimestamp(hover.message.createdAt), isUser ? nil : MessageBubble.brainLine(hover.message.metadata)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return Text(line)
            .font(ShellType.caption)
            .lineLimit(1)
            .foregroundStyle(NativeAgentShell.secondary)
            .allowsHitTesting(false)
    }
}

private struct TranscriptToastLayer: View {
    let model: TranscriptDocumentModel
    let bottomInset: CGFloat

    var body: some View {
        let toast = model.toasts.current
        ZStack {
            if let toast {
                NoticePill(text: toast)
                    .padding(.bottom, bottomInset + NativeAgentSpacing.sm)
                    .transition(NativeAgentMotion.reveal())
            }
        }
        .animation(NativeAgentMotion.standard, value: toast)
    }
}

/// The scroll view and text view, rebuilt never: every input change is one document edit.
private struct TranscriptDocumentRepresentable<Groups: RandomAccessCollection<MessageGroup>>: NSViewRepresentable {
    let sessionID: String
    let groups: Groups
    let cardsByRow: [String: [TranscriptReadout.Card]]
    let exchanges: [OtherRoomExchange]
    let showsTrouble: Bool
    let streamingMessageID: String?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let handle: TranscriptDocumentHandle?
    let model: TranscriptDocumentModel
    let appModel: AppModel

    func makeCoordinator() -> TranscriptDocumentController {
        TranscriptDocumentController(model: model)
    }

    func makeNSView(context: Context) -> TranscriptDocumentScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ view: TranscriptDocumentScrollView, context: Context) {
        context.coordinator.update(
            sessionID: sessionID, groups: groups, cardsByRow: cardsByRow, exchanges: exchanges, showsTrouble: showsTrouble,
            streamingMessageID: streamingMessageID, topInset: topInset, bottomInset: bottomInset,
            environment: context.environment, appModel: appModel, handle: handle
        )
    }

    static func dismantleNSView(_ view: TranscriptDocumentScrollView, coordinator: TranscriptDocumentController) {
        coordinator.dismantle()
    }
}

// MARK: - A reply's brain line

/// A reply's brain as its hover stamp names it: the model (or the one requested), the reasoning effort and the file access mode.
enum MessageBubble {
    nonisolated static func brainLine(_ metadata: ChatMessageMetadata?) -> String? {
        guard let metadata else { return nil }
        let model = metadata.model ?? metadata.requestedModel.map { "requested \($0)" }
        let fields = [model, metadata.reasoningEffort, metadata.fileAccessMode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return fields.isEmpty ? nil : fields.joined(separator: " / ")
    }
}
