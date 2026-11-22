import AppKit
import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptAttachments.swift` | The Mac's hosted attachment views on the Shared hosts: conversation data, box, host and model |

/// The Mac's hosted views: each block's box reads the conversation's resolved attachments, and its card or other-room row can open
/// a contact thread or retry a message through the view.
@MainActor final class TranscriptAttachments: TranscriptAttachmentHosts<TranscriptAttachmentBox, TranscriptAttachmentRoot> {
    /// Set by the view. An other-room row was clicked: open that contact thread.
    var openExchange: (OtherRoomExchange) -> Void = { _ in }
    var retryMessage: (String) -> Void = { _ in }

    private var data: TranscriptAttachmentData?
    private var environment: EnvironmentValues?

    /// The same block id returns the same attachment while the block lives.
    func attachment(blockID: String, ref: TranscriptAttachmentRef, role: String) -> NSTextAttachment {
        retained(blockID: blockID, ref: ref, role: role, rebind: { box in
            box.model = data.map { TranscriptAttachmentModel(ref, blockID: blockID, role: role, in: $0) }
                ?? .waiting("Waiting on attachment data… Close this conversation to stop viewing it.")
        }) { resized in
            let model = data.map { TranscriptAttachmentModel(ref, blockID: blockID, role: role, in: $0) }
                ?? .waiting("Waiting on attachment data… Close this conversation to stop viewing it.")
            let box = TranscriptAttachmentBox(model: model, environment: environment)
            box.resized = resized
            box.open = { [weak self] exchange in self?.openExchange(exchange) }
            box.retry = { [weak self] message in self?.retryMessage(message) }
            // The controller's view (an NSHostingView) is the attachment's view; the controller measures it at the column width.
            let host = NSHostingController(rootView: TranscriptAttachmentRoot(box: box))
            // TextKit places the view by frame; the host neither drives Auto Layout nor insets for the window's bars.
            host.sizingOptions = []
            host.safeAreaRegions = []
            // A hosted view draws only inside its paragraph's room: a card that settles smaller never leaves its old controls over the next row.
            host.view.clipsToBounds = true
            return (box, host)
        }
    }

    /// Fresh data, SwiftUI environment and column width before every document edit; live hosted views refresh from it.
    func update(_ data: TranscriptAttachmentData, environment: EnvironmentValues, columnWidth: CGFloat) {
        self.data = data
        self.environment = environment
        refresh(columnWidth: columnWidth) { entry, blockID in
            entry.box.environment = environment
            let model = TranscriptAttachmentModel(entry.ref, blockID: blockID, role: entry.role, in: data)
            guard model != entry.box.model else { return false }
            entry.box.model = model
            return true
        }
    }
}

/// What the attachment side reads when it builds or refreshes a hosted view. The document view hands over a fresh snapshot before every edit.
struct TranscriptAttachmentData: Equatable {
    var sessionID: String
    var state: FaceReadState?
    var actions: [MessageActionFace]
    var attachments: [FaceResolvedAttachment]
    var visibleReply: VisibleReplyTarget?

    init(sessionID: String, conversation: ConversationFace?) {
        self.sessionID = sessionID
        state = conversation?.state
        actions = conversation.map(\.actions) ?? []
        attachments = conversation.map(\.attachments) ?? []
        visibleReply = conversation?.visibleReply
    }
}

/// What one live hosted view shows. The owner writes it on every update; the view reads it, so an answered card or a loaded
/// image redraws in place.
@MainActor @Observable
final class TranscriptAttachmentBox {
    var model: TranscriptAttachmentModel
    /// The transcript host's whole SwiftUI environment; nil until the view's first update, and nothing draws before it.
    var environment: EnvironmentValues?
    @ObservationIgnored var resized: () -> Void = {}
    @ObservationIgnored var open: (OtherRoomExchange) -> Void = { _ in }
    @ObservationIgnored var retry: (String) -> Void = { _ in }

    init(model: TranscriptAttachmentModel, environment: EnvironmentValues?) {
        self.model = model
        self.environment = environment
    }
}

/// Resolve an attachment's reference against the document's input snapshot.
enum TranscriptAttachmentModel: Equatable {
    case resolved(FaceResolvedAttachment, ref: TranscriptAttachmentRef, role: String)
    case table(ChatMarkdownTable, cells: [[AttributedString]])
    case otherRoom(OtherRoomExchange)
    case waiting(String)
    case unavailable(String)

    init(_ ref: TranscriptAttachmentRef, blockID: String, role: String, in data: TranscriptAttachmentData) {
        switch ref {
        case .table(let table):
            let cells = ([table.header] + table.rows).map { row in
                (0..<table.columnCount).map { ChatRichContentParser.inline(table.cell(row, $0)).presentation }
            }
            self = .table(table, cells: cells)
        case .otherRoom(let exchange): self = .otherRoom(exchange)
        default:
            guard let state = data.state else {
                self = .waiting("Waiting on conversation attachments… Close this conversation to stop viewing it.")
                return
            }
            if case .unavailable(let failure) = state {
                self = .unavailable(failure.localizedDescription)
                return
            }
            if let attachment = data.attachments.first(where: { $0.id == blockID }) {
                self = .resolved(attachment, ref: ref, role: role)
                return
            }
            switch state {
            case .waiting(let owner): self = .waiting("Waiting on \(owner)… Close this conversation to stop viewing it.")
            case .unavailable(let failure): self = .unavailable(failure.localizedDescription)
            case .ready:
                self = .waiting("Waiting on attachment \(blockID)'s resolved presentation. Its absence does not settle it.")
            }
        }
    }
}
