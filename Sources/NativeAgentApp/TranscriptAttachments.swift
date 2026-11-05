import AppKit
import ApprovalTransactions
import EngineRuntime
import NativeAgentShared
import Observation
import SwiftUI

/// The document's own motion and hosted views: what opened, followed, measured and loaded, so a blank card or a jump is observable.
let transcriptLog = ModuleLog(category: "TranscriptDocument")

// Blueprint: | `TranscriptAttachments.swift` | Document view attachments: one hosted view per block id, fed from the model, sized to fit |

/// Every card, approval, table, image, voice note, file chip, other-room row, envelope and trouble card in the document.
/// One block id owns one attachment and one hosted view for as long as the block lives; the controller places the view over the
/// attachment's frame. What a view shows is pushed into its box by block id, never kept in the view.
@MainActor final class TranscriptAttachments {
    /// Set by the view. Called when a hosted view's height changes; the view re-lays that block's paragraph.
    var heightChanged: (_ blockID: String) -> Void = { _ in }
    /// Set by the view. An other-room row was clicked: open that contact thread.
    var openExchange: (OtherRoomExchange) -> Void = { _ in }

    private var entries: [String: Entry] = [:]
    private var data: TranscriptAttachmentData?
    private var environment: EnvironmentValues?
    private var columnWidth: CGFloat = 0
    /// Blocks whose size must be read again; read together on the next main-actor turn, outside any layout pass.
    private var pending: Set<String> = []
    private var measureScheduled = false

    init() {}

    /// The same block id returns the same attachment while the block lives.
    func attachment(blockID: String, ref: TranscriptAttachmentRef) -> NSTextAttachment {
        if let entry = entries[blockID] {
            // A growing reply can change what its block shows (a table gains rows) under the same id.
            if entry.ref != ref {
                entry.ref = ref
                entry.box.model = data.map { TranscriptAttachmentModel(ref, in: $0) } ?? .missing
                remeasure(blockID)
            }
            return entry.attachment
        }
        let box = TranscriptAttachmentBox(model: data.map { TranscriptAttachmentModel(ref, in: $0) } ?? .missing, environment: environment)
        box.resized = { [weak self] in self?.remeasure(blockID) }
        box.open = { [weak self] exchange in self?.openExchange(exchange) }
        // The controller's view (an NSHostingView) is the attachment's view; the controller measures it at the column width.
        let host = NSHostingController(rootView: TranscriptAttachmentRoot(box: box))
        // TextKit places the view by frame; the host neither drives Auto Layout nor insets for the window's bars.
        host.sizingOptions = []
        host.safeAreaRegions = []
        let entry = Entry(ref: ref, box: box, host: host, attachment: TranscriptAttachment(blockID: blockID))
        entries[blockID] = entry
        // Sized before TextKit first lays the paragraph out, so the first layout is the right one.
        measure(entry)
        transcriptLog("attach.new block=%@ column=%.0f size=%.0fx%.0f", blockID, columnWidth,
                      entry.attachment.bounds.width, entry.attachment.bounds.height)
        return entry.attachment
    }

    /// Fresh data, SwiftUI environment and column width before every document edit; live hosted views refresh from it.
    func update(_ data: TranscriptAttachmentData, environment: EnvironmentValues, columnWidth: CGFloat) {
        let resized = columnWidth != self.columnWidth
        self.data = data
        self.environment = environment
        self.columnWidth = columnWidth
        for (blockID, entry) in entries {
            entry.box.environment = environment
            let model = TranscriptAttachmentModel(entry.ref, in: data)
            if model != entry.box.model {
                entry.box.model = model
                remeasure(blockID)
            } else if resized {
                remeasure(blockID)
            }
        }
    }

    /// The view is a block's hosted view or inside one.
    func hosts(_ view: NSView) -> Bool {
        entries.values.contains { view.isDescendant(of: $0.host.view) }
    }

    /// Blocks gone from the document.
    func forget(_ blockIDs: Set<String>) {
        for blockID in blockIDs {
            entries[blockID]?.host.view.removeFromSuperview()
            entries[blockID] = nil
        }
        pending.subtract(blockIDs)
    }

    /// Puts each block's hosted view over its attachment's laid-out frame (text view coordinates) and hides the rest, so a view
    /// shows exactly where its paragraph is laid out and nowhere else. One view per block for its whole life: what the reader
    /// did inside it (an opened disclosure, a playing note) stays.
    func place(_ frames: [String: CGRect], in textView: NSView) {
        for (blockID, entry) in entries {
            let view = entry.host.view
            guard let frame = frames[blockID] else {
                if view.superview != nil, !view.isHidden { view.isHidden = true }
                continue
            }
            if view.superview !== textView { textView.addSubview(view) }
            if view.frame != frame { view.frame = frame }
            if view.isHidden { view.isHidden = false }
        }
    }

    private func remeasure(_ blockID: String) {
        pending.insert(blockID)
        guard !measureScheduled else { return }
        measureScheduled = true
        Task { @MainActor [weak self] in self?.measurePending() }
    }

    private func measurePending() {
        measureScheduled = false
        let blockIDs = pending
        pending = []
        for blockID in blockIDs {
            guard let entry = entries[blockID], measure(entry) else { continue }
            transcriptLog("attach.resized block=%@ size=%.0fx%.0f", blockID, entry.attachment.bounds.width, entry.attachment.bounds.height)
            heightChanged(blockID)
        }
    }

    /// The hosted view's fitting size at the column width: its own width up to the column (so paragraph alignment can seat it)
    /// and its whole height. Returns whether the size changed. Before the view gives a column width there is nothing to fit.
    @discardableResult
    private func measure(_ entry: Entry) -> Bool {
        guard columnWidth > 0 else { return false }
        let fit = entry.host.sizeThatFits(in: CGSize(width: columnWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(fit.width.rounded(.up), columnWidth), height: fit.height.rounded(.up))
        guard size != entry.attachment.bounds.size else { return false }
        entry.attachment.bounds = CGRect(origin: .zero, size: size)
        return true
    }

    private final class Entry {
        var ref: TranscriptAttachmentRef
        let box: TranscriptAttachmentBox
        let host: NSHostingController<TranscriptAttachmentRoot>
        let attachment: TranscriptAttachment

        init(ref: TranscriptAttachmentRef, box: TranscriptAttachmentBox, host: NSHostingController<TranscriptAttachmentRoot>,
             attachment: TranscriptAttachment) {
            self.ref = ref
            self.box = box
            self.host = host
            self.attachment = attachment
        }
    }
}

/// What the attachment side reads when it builds or refreshes a hosted view. The document view hands over a fresh snapshot before every edit.
struct TranscriptAttachmentData {
    var sessionID: String
    var messages: [String: ChatMessage]
    var cardsByRow: [String: [TranscriptReadout.Card]]
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

    init(model: TranscriptAttachmentModel, environment: EnvironmentValues?) {
        self.model = model
        self.environment = environment
    }
}

/// An attachment's inputs, read from the document's data by its reference: exactly what today's view for that kind takes.
enum TranscriptAttachmentModel: Equatable {
    case card(InlineCardModel)
    case approval(ChatMessage)
    case table(ChatMarkdownTable, cells: [[AttributedString]])
    case image(PersistedAttachment)
    case voice(PersistedAttachment, transcript: String, isOwn: Bool)
    case file(PersistedAttachment)
    case otherRoom(OtherRoomExchange)
    case envelope(content: String)
    case trouble(sessionID: String)
    /// The row, card or attachment is not in the latest data: the block takes no room until it is.
    case missing

    init(_ ref: TranscriptAttachmentRef, in data: TranscriptAttachmentData) {
        switch ref {
        case .card(let rowID, let cardID):
            self = data.cardsByRow[rowID]?.first(where: { $0.model.id == cardID }).map { Self.card($0.model) } ?? .missing
        case .approval(let rowID):
            self = data.messages[rowID].map { Self.approval($0) } ?? .missing
        case .table(let table):
            // The same sanitized inline Markdown as prose cells today (`ChatPreparedContent.segments`).
            let cells = ([table.header] + table.rows).map { row in
                (0..<table.columnCount).map { ChatMarkdownCache.inline(table.cell(row, $0)).presentation }
            }
            self = .table(table, cells: cells)
        case .image(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { Self.image($0.attachment) } ?? .missing
        case .voice(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { found in
                let utterance = found.attachment.utterance
                return Self.voice(found.attachment, transcript: utterance?.correctedText ?? utterance?.text ?? found.message.content,
                              isOwn: found.message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user")
            } ?? .missing
        case .file(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { Self.file($0.attachment) } ?? .missing
        case .otherRoom(let exchange):
            self = .otherRoom(exchange)
        case .envelope(let messageID):
            self = data.messages[messageID].map { Self.envelope(content: $0.content) } ?? .missing
        case .trouble:
            self = .trouble(sessionID: data.sessionID)
        }
    }

    /// Indexes count into the message's `metadata.attachments`, as the reference says.
    private static func attachment(_ messageID: String, _ index: Int, in data: TranscriptAttachmentData)
        -> (message: ChatMessage, attachment: PersistedAttachment)? {
        guard let message = data.messages[messageID], let attachments = message.metadata?.attachments,
              attachments.indices.contains(index) else { return nil }
        return (message, attachments[index])
    }
}

/// A block's room in the text: TextKit lays out its measured bounds and draws nothing there; the controller places the block's
/// hosted view over that frame. TextKit's own attachment views are not used: it creates their providers only for paragraphs a
/// scroll lays out, so a card at the end of a freshly opened conversation stayed blank.
final class TranscriptAttachment: NSTextAttachment {
    let blockID: String

    init(blockID: String) {
        self.blockID = blockID
        super.init(data: Data(blockID.utf8), ofType: "com.nativeagent.transcript.attachment")
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { nil }

    /// The hosted view is the only drawing; there is no image under it.
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? { nil }

    /// The hosted view's measured size (kept in `bounds` by the owner), never wider than the line; zero until measured.
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: min(bounds.width, proposedLineFragment.width), height: bounds.height)
    }
}
