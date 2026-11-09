import AppKit
import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptDocumentView.swift` | `TranscriptDocumentView`: any run of a conversation as one document; hover bar, sheets, host handle |

/// Any run of a conversation as one selectable document: the main chat, the detached panel, Shotgun's last rows, a contact or crew thread.
/// The host names the session and presentation; the view owns layout, place, folds, the live reply's reveal, the menu and find.
struct TranscriptDocumentView: View {
    var sessionID: String
    var presentation = "conversation"
    /// Room the host's chrome covers: the header above, the composer glass and working card below. The text scrolls under both.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Find, Latest, reveal and the at-end signal for the host's Latest pill.
    var handle: TranscriptDocumentHandle?

    @Environment(AppModel.self) private var appModel
    @State private var model = TranscriptDocumentModel()

    var body: some View {
        TranscriptDocumentRepresentable(
            sessionID: sessionID, presentation: presentation, topInset: topInset, bottomInset: bottomInset, handle: handle,
            model: model, appModel: appModel
        )
        .overlay(alignment: .topLeading) { TranscriptHoverLayer(model: model) }
        .overlay(alignment: .bottom) { TranscriptToastLayer(model: model, bottomInset: bottomInset) }
        .overlay(alignment: .top) {
            if let issue = model.conversationIssue ?? model.commandIssue ?? model.pressIssue {
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .padding().background(.regularMaterial)
            } else if model.waitingForScript {
                Text("Waiting on the transcript… Close this conversation to stop viewing it.")
                    .font(.caption).padding().background(.regularMaterial)
            } else if model.waitingForCompleteDocument {
                Text("Reading earlier messages… Close this conversation to cancel.")
                    .font(.caption).padding().background(.regularMaterial)
            }
        }
        .sheet(item: $model.dataMessage) { MessageJSONSheet(message: $0) }
        .sheet(isPresented: Binding(get: { model.openedContact != nil }, set: { if !$0 { model.openedContact = nil } })) {
            if let contact = model.openedContact {
                SimpleContactThread(contactID: contact) { model.openedContact = nil }.frame(minWidth: 600, minHeight: 500)
            }
        }
        .confirmationDialog("Retry this reply?", isPresented: Binding(
            get: { model.retryRequested }, set: { model.retryRequested = $0 }
        ), titleVisibility: .visible) {
            Button("Continue from results") { retry(.continueFromResults) }
            Button("Restart turn") { retry(.restartConfirmed) }
            Button("Cancel", role: .cancel) { model.retryRequested = false }
        } message: {
            Text("Restarting can repeat this turn’s effects. Continue uses its recorded results.")
        }
    }

    private func retry(_ choice: RetryChoice) {
        guard let message = model.retryMessage else { return }
        model.controller?.retry(message, choice: choice)
        model.retryRequested = false
    }

}

/// The host's line to its transcript: find (⌘F, ⌘G, ⇧⌘G), Latest, reveal a message, and whether the reader is at the end.
@MainActor @Observable
final class TranscriptDocumentHandle {
    /// The reader chooses to follow the end; the host's Latest pill shows while this is false.
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
    var conversationIssue: String?
    var pressIssue: String?
    var commandIssue: String?
    var waitingForScript = true
    var waitingForCompleteDocument = false
    var hover: TranscriptHover?
    var codeCopy: TranscriptCodeCopy?
    /// Each feedback occurrence displays for 2.5 seconds.
    let toasts = ChatToastQueue(displayDuration: 2.5)
    var dataMessage: TranscriptMessageReference?
    var openedContact: String?
    var retryRequested = false
    @ObservationIgnored var retryMessage: String?
    /// While the pointer is on the hover bar, the bar stays with its message.
    @ObservationIgnored var barHovered = false
    var speechOperation: UUID?
    @ObservationIgnored weak var controller: TranscriptDocumentController?

    func show(_ text: String) {
        toasts.show(text)
    }
}

/// The hovered message and where its bar hangs: `anchor` is the bar's top at the message's leading (or, seated right, trailing) edge.
struct TranscriptHover: Equatable {
    var message: TranscriptMessageReference
    var canRetry: Bool
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

    // The host's size is independent of the moving hover anchors.
    var body: some View {
        GeometryReader { _ in
            layers
        }
    }

    @ViewBuilder private var layers: some View {
        if let hover = model.hover {
            HStack(spacing: NativeAgentSpacing.sm) {
                BubbleHoverBar(
                    message: hover.message,
                    canRetry: hover.canRetry,
                    onCopy: { model.controller?.copyMessage(hover.message.id) },
                    onRegenerate: { model.controller?.regenerate(hover.message.id) },
                    isReading: model.controller?.isReading(hover.message) == true,
                    onReadAloud: { model.controller?.readAloud(hover.message.id) },
                    onStopReading: { model.controller?.stopReading() }
                )
                .onHover { hovering in
                    model.barHovered = hovering
                    if !hovering { model.controller?.rehover() }
                }
            }
            .fixedSize()
            .frame(width: 0, height: 0, alignment: hover.seatsRight ? .topTrailing : .topLeading)
            .offset(x: hover.anchor.x, y: hover.anchor.y)
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
            .frame(width: 0, height: 0, alignment: .trailing)
            .offset(x: code.anchor.x, y: code.anchor.y)
        }
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
private struct TranscriptDocumentRepresentable: NSViewRepresentable {
    let sessionID: String
    let presentation: String
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

    /// The room sizes the viewport; growing text and hosted attachments never size the SwiftUI window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: TranscriptDocumentScrollView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: TranscriptDocumentScrollView, context: Context) {
        context.coordinator.update(
            sessionID: sessionID, presentation: presentation, topInset: topInset, bottomInset: bottomInset,
            environment: context.environment, appModel: appModel, handle: handle
        )
    }

    static func dismantleNSView(_ view: TranscriptDocumentScrollView, coordinator: TranscriptDocumentController) {
        coordinator.dismantle()
    }
}

/// A menu holds the identity and finished eligibility it draws; the body rechecks every act.
struct TranscriptMessageReference: Identifiable, Equatable {
    var session: String
    var id: String
    var role: String
    var action: MessageActionFace?
}
