import NativeAgentShared
import Observation
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptAttachments.swift` | Phone document attachments: one hosted view per block id, fed from the model, sized to fit |

/// Every card, approval, table, image, voice note, file chip and other-room row in the document. One block id owns one attachment
/// and one hosted view for as long as the block lives; the controller places the view over the attachment's laid-out frame.
/// What a view shows is pushed into its box by block id, never kept in the view.
@MainActor final class TranscriptAttachments {
    /// Set by the controller. Called when a hosted view's height changes; the controller re-lays that block's paragraph.
    var heightChanged: (_ blockID: String) -> Void = { _ in }

    private var entries: [String: Entry] = [:]
    private var data: TranscriptAttachmentData?
    private var environment: EnvironmentValues?
    private var actions = MobileTranscriptActions()
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
        let box = TranscriptAttachmentBox(model: data.map { TranscriptAttachmentModel(ref, in: $0) } ?? .missing,
                                          environment: environment, actions: actions)
        box.resized = { [weak self] in self?.remeasure(blockID) }
        let host = UIHostingController(rootView: TranscriptAttachmentRoot(box: box))
        // The controller places the view by frame; the host neither drives Auto Layout nor insets for the screen's bars.
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        let entry = Entry(ref: ref, box: box, host: host, attachment: TranscriptAttachment(blockID: blockID))
        entries[blockID] = entry
        // Sized before TextKit first lays the paragraph out, so the first layout is the right one.
        measure(entry)
        return entry.attachment
    }

    /// Fresh data, SwiftUI environment, actions and column width before every document edit; live hosted views refresh from it.
    func update(_ data: TranscriptAttachmentData, environment: EnvironmentValues, actions: MobileTranscriptActions, columnWidth: CGFloat) {
        let resized = columnWidth != self.columnWidth
        self.data = data
        self.environment = environment
        self.actions = actions
        self.columnWidth = columnWidth
        for (blockID, entry) in entries {
            entry.box.environment = environment
            entry.box.actions = actions
            let model = TranscriptAttachmentModel(entry.ref, in: data)
            if model != entry.box.model {
                entry.box.model = model
                remeasure(blockID)
            } else if resized {
                remeasure(blockID)
            }
        }
    }

    /// Blocks gone from the document.
    func forget(_ blockIDs: Set<String>) {
        for blockID in blockIDs {
            guard let entry = entries.removeValue(forKey: blockID) else { continue }
            entry.host.willMove(toParent: nil)
            entry.host.view.removeFromSuperview()
            entry.host.removeFromParent()
        }
        pending.subtract(blockIDs)
    }

    /// Whether a touched view is inside a hosted view: its own controls take the touch, not the document's taps.
    func hosts(_ view: UIView?) -> Bool {
        guard let view else { return false }
        return entries.values.contains { view.isDescendant(of: $0.host.view) }
    }

    /// Puts each block's hosted view over its attachment's laid-out frame (text view coordinates) and hides the rest, so a view
    /// shows exactly where its paragraph is laid out and nowhere else. One view per block for its whole life: what the reader did
    /// inside it (an opened disclosure, a playing note, a typed key) stays. Each host is a child of the screen's view controller, so
    /// what it presents (a sheet, a picker) has a presenter.
    func place(_ frames: [String: CGRect], in textView: UIView) {
        for (blockID, entry) in entries {
            let view = entry.host.view!
            guard let frame = frames[blockID] else {
                if view.superview != nil, !view.isHidden { view.isHidden = true }
                continue
            }
            if view.superview !== textView {
                if let parent = Self.viewController(of: textView), entry.host.parent !== parent {
                    entry.host.willMove(toParent: nil)
                    entry.host.removeFromParent()
                    parent.addChild(entry.host)
                    textView.addSubview(view)
                    entry.host.didMove(toParent: parent)
                } else {
                    textView.addSubview(view)
                }
            }
            if view.frame != frame { view.frame = frame }
            if view.isHidden { view.isHidden = false }
        }
    }

    private static func viewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
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
            heightChanged(blockID)
        }
    }

    /// The hosted view's fitting size at the column width: its own width up to the column (so paragraph alignment can seat it)
    /// and its whole height. Returns whether the size changed. Before the controller gives a column width there is nothing to fit.
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
        let host: UIHostingController<TranscriptAttachmentRoot>
        let attachment: TranscriptAttachment

        init(ref: TranscriptAttachmentRef, box: TranscriptAttachmentBox, host: UIHostingController<TranscriptAttachmentRoot>,
             attachment: TranscriptAttachment) {
            self.ref = ref
            self.box = box
            self.host = host
            self.attachment = attachment
        }
    }
}

/// What the attachment side reads when it builds or refreshes a hosted view, keyed as the references name them.
struct TranscriptAttachmentData {
    /// By `ChatMessage.id.uuidString`.
    var messages: [String: ChatMessage]
    var approvals: [String: ApprovalRequest]
    var inboxCards: [String: InboxItemRecord]
}

/// What one live hosted view shows. The owner writes it on every update; the view reads it, so an answered card or a loaded image
/// redraws in place.
@MainActor @Observable
final class TranscriptAttachmentBox {
    var model: TranscriptAttachmentModel
    /// The conversation's whole SwiftUI environment; nil until the controller's first update, and nothing draws before it.
    var environment: EnvironmentValues?
    @ObservationIgnored var actions: MobileTranscriptActions
    @ObservationIgnored var resized: () -> Void = {}

    init(model: TranscriptAttachmentModel, environment: EnvironmentValues?, actions: MobileTranscriptActions) {
        self.model = model
        self.environment = environment
        self.actions = actions
    }
}

/// An attachment's inputs, read from the document's data by its reference: exactly what the phone's view for that kind takes.
enum TranscriptAttachmentModel: Equatable {
    case interaction(InlineInteraction, InlineInteractionDescriptor, sessionID: String)
    case inboxCard(InboxItemRecord)
    case approval(ApprovalRequest)
    case table(ChatMarkdownTable)
    case image(ChatAttachmentSummary)
    case voice(ChatAttachmentSummary, transcript: String, isOwn: Bool)
    case file(ChatAttachmentSummary)
    case otherRoom(OtherRoomExchange)
    /// The row, card or attachment is not in the latest data, or the reference is one the phone never draws: no room until it is.
    case missing

    init(_ ref: TranscriptAttachmentRef, in data: TranscriptAttachmentData) {
        switch ref {
        case .card(let rowID, let cardID):
            if let message = data.messages[rowID], let card = message.interaction, card.id == cardID,
               let descriptor = message.interactionDescriptor, let session = message.interactionSessionID {
                self = .interaction(card, descriptor, sessionID: session)
            } else {
                self = data.inboxCards[cardID].map { Self.inboxCard($0) } ?? .missing
            }
        case .approval(let id):
            self = data.approvals[id].map { Self.approval($0) } ?? .missing
        case .table(let table):
            self = .table(table)
        case .image(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { Self.image($0.attachment) } ?? .missing
        case .voice(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { found in
                let utterance = found.attachment.utterance
                return Self.voice(found.attachment, transcript: utterance?.correctedText ?? utterance?.text ?? found.message.text,
                                  isOwn: found.message.role == .user)
            } ?? .missing
        case .file(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { Self.file($0.attachment) } ?? .missing
        case .otherRoom(let exchange):
            self = .otherRoom(exchange)
        case .envelope, .trouble:
            self = .missing
        }
    }

    /// Indexes count into the message's `attachments`, as the reference says.
    private static func attachment(_ messageID: String, _ index: Int, in data: TranscriptAttachmentData)
        -> (message: ChatMessage, attachment: ChatAttachmentSummary)? {
        guard let message = data.messages[messageID], message.attachments.indices.contains(index) else { return nil }
        return (message, message.attachments[index])
    }
}

/// A block's room in the text: TextKit lays out its measured bounds and draws nothing there; the controller places the block's hosted
/// view over that frame. TextKit's own attachment views are not used: it creates their providers only for paragraphs a scroll lays out.
final class TranscriptAttachment: NSTextAttachment {
    let blockID: String

    init(blockID: String) {
        self.blockID = blockID
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { nil }

    /// The hosted view is the only drawing; under it TextKit draws an empty image.
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> UIImage? { UIImage() }

    /// The hosted view's measured size (kept in `bounds` by the owner), never wider than the line; zero until measured.
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: min(bounds.width, proposedLineFragment.width), height: bounds.height)
    }
}

// MARK: - What each attachment draws

/// The hosted root. It carries the conversation's whole environment, so the stores, pairing and appearance reach every attachment
/// as they reach the rest of the chat.
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
    }

    @ViewBuilder private var content: some View {
        switch box.model {
        case .interaction(let card, let descriptor, let sessionID):
            MobileInteractionCard(card: card, descriptor: descriptor, sessionID: sessionID)
        case .inboxCard(let item):
            InboxCardRow(item: item, onAction: { action in box.actions.inboxAction(item.id, action) },
                         onView: { box.actions.openInboxItem(item.id) })
        case .approval(let approval):
            InlineChatApprovalCard(approval: approval)
        case .table(let table):
            TranscriptTableView(table: table)
        case .image(let attachment):
            TranscriptImageAttachment(attachment: attachment)
        case .voice(let attachment, let transcript, let isOwn):
            TranscriptVoiceAttachment(attachment: attachment, transcript: transcript, isOwn: isOwn)
        case .file(let attachment):
            TranscriptFileChip(attachment: attachment)
        case .otherRoom(let exchange):
            Button { box.actions.openExchange(exchange) } label: {
                OtherRoomExchangePreview(exchange: exchange).foregroundStyle(AlivePalette.text)
            }
            .buttonStyle(.plain)
        case .missing:
            EmptyView()
        }
    }
}

/// A markdown table as a Grid sized from its content, cells read with the same sanitized inline markdown as prose.
private struct TranscriptTableView: View {
    let table: ChatMarkdownTable

    var body: some View {
        let columns = Array(0..<table.columnCount)
        Grid(alignment: .topLeading, horizontalSpacing: NativeAgentSpacing.sm, verticalSpacing: 0) {
            GridRow {
                ForEach(columns, id: \.self) { column in
                    cell(table.cell(table.header, column), column: column)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AlivePalette.secondary)
                        .padding(.vertical, NativeAgentSpacing.xs)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(columns, id: \.self) { column in
                        cell(table.cell(table.rows[row], column), column: column)
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.text)
                            .padding(.vertical, NativeAgentSpacing.xs)
                    }
                }
            }
        }
        .padding(NativeAgentSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeAgentMobileTheme.Colors.quietFill, in: RoundedRectangle(cornerRadius: TranscriptMetrics.codeRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func cell(_ text: String, column: Int) -> some View {
        let align = table.align(column)
        return Text(ChatRichContentParser.inline(text).presentation)
            .multilineTextAlignment(align == .trailing ? .trailing : align == .center ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: align == .trailing ? .trailing : align == .center ? .center : .leading)
            .gridColumnAlignment(align == .trailing ? .trailing : .leading)
    }
}

/// A sent or received image's thumbnail, decoded once per attachment by `ChatAttachmentPresentation`. Until it decodes, and when it
/// has no preview, it reads as its file chip: the view always has room, so it is placed and its decode runs.
private struct TranscriptImageAttachment: View {
    let attachment: ChatAttachmentSummary
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                    }
                    .accessibilityLabel(attachment.name)
            } else {
                TranscriptFileChip(attachment: attachment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: attachment) {
            let prepared = await ChatAttachmentPresentation.shared.images(in: [attachment])
            guard !Task.isCancelled else { return }
            image = prepared.first?.image
        }
    }
}

private struct TranscriptVoiceAttachment: View {
    let attachment: ChatAttachmentSummary
    let transcript: String
    let isOwn: Bool

    var body: some View {
        VoiceNoteBubble(id: attachment.id, transcript: transcript, isOwn: isOwn, speaker: iCloudSyncEngine.shared.agentDisplayName) {
            try await Task.detached(priority: .utility) {
                if let raw = attachment.base64, !raw.isEmpty {
                    return try MobileLocalStorage.retainRecording(MultimodalAttachment(
                        id: attachment.id, type: "audio", base64: raw, mime: attachment.mime ?? "audio/x-caf"))
                }
                let url = try MobileLocalStorage.recordingURL(id: attachment.id, mime: attachment.mime)
                _ = try url.checkResourceIsReachable()
                return url
            }.value
        }
    }
}

private struct TranscriptFileChip: View {
    let attachment: ChatAttachmentSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.type == "image" ? "photo.fill" : "doc.fill")
                .accessibilityHidden(true)
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote)
        .foregroundStyle(AlivePalette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
