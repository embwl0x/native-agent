import NativeAgentShared
import Observation
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptView.swift` | The phone's conversation as one selectable document: the text view, its host handle and actions |

/// The conversation as one selectable TextKit 2 document. The thread hands over its rows, its width and the composer's room; the view
/// owns layout, place, folds, the live reply's reveal and the menu.
struct MobileTranscriptView: UIViewRepresentable {
    let input: MobileTranscriptInput
    /// The host's width and the room its composer (and the keyboard, while it shows) covers at the bottom.
    let width: CGFloat
    let bottomInset: CGFloat
    let actions: MobileTranscriptActions
    let handle: MobileTranscriptHandle

    func makeCoordinator() -> MobileTranscriptController {
        MobileTranscriptController()
    }

    func makeUIView(context: Context) -> MobileTranscriptTextView {
        context.coordinator.textView
    }

    func updateUIView(_ view: MobileTranscriptTextView, context: Context) {
        context.coordinator.update(input, width: width, bottomInset: bottomInset, environment: context.environment, actions: actions,
                                   handle: handle)
    }

    static func dismantleUIView(_ view: MobileTranscriptTextView, coordinator: MobileTranscriptController) {
        coordinator.dismantle()
    }
}

/// The thread's line to its document: whether the reader follows the end (the Latest button shows while not), and back to the end.
@MainActor @Observable
final class MobileTranscriptHandle {
    var isAtEnd = true
    @ObservationIgnored weak var controller: MobileTranscriptController?

    init() {}

    /// Back to the end; the document follows from there. Before the document mounts there is nothing to move: it opens at its end.
    func goToLatest() {
        controller?.goToLatest()
    }
}

/// What the document's links, cards and menu do, as the thread does them.
struct MobileTranscriptActions {
    var loadOlder: @MainActor () -> Void = {}
    var sendNow: @MainActor (UUID) -> Void = { _ in }
    var loadWholeMessage: @MainActor (UUID) -> Void = { _ in }
    var retrySend: @MainActor (UUID) -> Void = { _ in }
    var openExchange: @MainActor (OtherRoomExchange) -> Void = { _ in }
    var inboxAction: @MainActor (_ itemID: String, _ actionID: String) -> Void = { _, _ in }
    var openInboxItem: @MainActor (String) -> Void = { _ in }
    /// Answer again reaches only the last reply, and only while the store can replace it.
    var canRegenerate = false
    var regenerate: @MainActor () -> Void = {}
    /// Read aloud is offered while spoken replies are on, the voice the phone already speaks replies in.
    var canReadAloud = false
    var isReading = false
    var readAloud: @MainActor (String) -> Void = { _ in }
    var stopReading: @MainActor () -> Void = {}
}

/// The one text view. Nothing here or in the controller reads `.layoutManager`: that silently drops the view to TextKit 1.
final class MobileTranscriptTextView: UITextView {
    weak var controller: MobileTranscriptController?

    /// TextKit lays the viewport out here, and a scroll runs it too; hosted views follow their paragraphs after each pass.
    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.didLayout()
    }

    /// TextKit's estimate of the document's height changed: a reader following the end stays there.
    override var contentSize: CGSize {
        didSet {
            if contentSize.height != oldValue.height { controller?.documentResized() }
        }
    }

    /// Copy gives the selection's words as they read, line separators as newlines and no attachment characters.
    override func copy(_ sender: Any?) {
        guard let text = controller?.text(for: [selectedRange], markdown: false) else { return }
        UIPasteboard.general.string = text
    }
}
