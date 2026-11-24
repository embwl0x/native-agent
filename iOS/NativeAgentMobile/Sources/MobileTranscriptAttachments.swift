import NativeAgentShared
import Observation
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptAttachments.swift` | The phone's hosted attachment views on the Shared hosts: message and Inbox data, box, host, model and what each attachment draws |

/// The phone's hosted views: each block's box reads the conversation's messages and Inbox rows by its reference, and acts through the
/// thread's actions.
@MainActor final class TranscriptAttachments: TranscriptAttachmentHosts<TranscriptAttachmentBox, TranscriptAttachmentRoot> {
    private var data: TranscriptAttachmentData?
    private var environment: EnvironmentValues?
    private var actions = MobileTranscriptActions()

    /// The same block id returns the same attachment while the block lives.
    func attachment(blockID: String, ref: TranscriptAttachmentRef, role: String) -> NSTextAttachment {
        retained(blockID: blockID, ref: ref, role: role, rebind: { box in
            box.model = data.map { TranscriptAttachmentModel(ref, in: $0) } ?? .unavailable("Waiting on transcript data")
        }) { resized in
            let box = TranscriptAttachmentBox(model: data.map { TranscriptAttachmentModel(ref, in: $0) } ?? .unavailable("Waiting on transcript data"),
                                              environment: environment, actions: actions)
            box.resized = resized
            let host = UIHostingController(rootView: TranscriptAttachmentRoot(box: box))
            // The controller places the view by frame; the host neither drives Auto Layout nor insets for the screen's bars.
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            return (box, host)
        }
    }

    /// Fresh data, SwiftUI environment, actions and column width before every document edit; live hosted views refresh from it.
    func update(_ data: TranscriptAttachmentData, environment: EnvironmentValues, actions: MobileTranscriptActions, columnWidth: CGFloat) {
        self.data = data
        self.environment = environment
        self.actions = actions
        refresh(columnWidth: columnWidth) { entry, _ in
            entry.box.environment = environment
            entry.box.actions = actions
            let model = TranscriptAttachmentModel(entry.ref, in: data)
            guard model != entry.box.model else { return false }
            entry.box.model = model
            return true
        }
    }
}

/// What the attachment side reads when it builds or refreshes a hosted view, keyed as the references name them.
struct TranscriptAttachmentData: Sendable {
    /// By `ChatMessage.id.uuidString`.
    var messages: [String: ChatMessage]
    var rowContent: [String: String] = [:]
    /// The matter each asking block shows, seated by the press's input preparation.
    var asked: [String: String]
    /// The Inbox face's rows by matter id.
    var inbox: [String: PartFace.Row]
    /// Each card's own face by its matter id, read on the Mac from the card itself.
    var cards: [String: PartFace.Row] = [:]
    /// The matters the Inbox still owes the person; nil until the Inbox has been read.
    var waiting: Set<String>? = nil
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
    /// A card or an ask: its matter's row of the Inbox face.
    case matter(PartFace.Row)
    case table(ChatMarkdownTable)
    case image(ChatAttachmentSummary)
    case voice(ChatAttachmentSummary, transcript: String, isOwn: Bool)
    case file(ChatAttachmentSummary)
    case otherRoom(OtherRoomExchange)
    case envelope(String)
    case unavailable(String)

    init(_ ref: TranscriptAttachmentRef, in data: TranscriptAttachmentData) {
        switch ref {
        // A card draws its own face with only its Inbox row's answers, so a card the Inbox no longer holds still reads whole; a Mac build
        // that sends no face leaves the Inbox row. An ask names its matter through the block it sits in and draws that matter's Inbox row.
        case .card(_, let matter):
            if var card = data.cards[matter] {
                if card.tone == .attention, let settled = data.inbox[matter], data.waiting?.contains(matter) == false {
                    // A face read before the card settled (an older page of history keeps its first copy) never draws as still asking: the
                    // Inbox holds the matter as settled, so its own row says the outcome. A card the Inbox does not hold yet draws its own
                    // face with no answers until they arrive.
                    self = .matter(PartFace.Row(id: card.id, title: settled.title, detail: settled.detail, symbol: settled.symbol ?? card.symbol,
                        tone: settled.tone, actions: settled.cardAnswers))
                } else {
                    card.actions = card.tone == .attention ? data.inbox[matter]?.cardAnswers : nil
                    self = .matter(card)
                }
            } else {
                self = data.inbox[matter].map { Self.matter($0) }
                    ?? .unavailable("Inbox matter \(matter) has not arrived. Open Inbox to inspect its sync status.")
            }
        case .approval(let id):
            self = data.asked[id].flatMap { data.inbox[$0] }.map { Self.matter($0) }
                ?? .unavailable("Approval \(id) has no available Inbox row. Open Inbox to inspect its sync status.")
        case .table(let table):
            self = .table(table)
        case .image(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { Self.image($0.attachment) }
                ?? .unavailable("Image \(index) is unavailable on message \(messageID). Load the whole message to inspect its attachments.")
        case .voice(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { found in
                let utterance = found.attachment.utterance
                return Self.voice(found.attachment, transcript: utterance?.correctedText ?? utterance?.text ?? found.message.text,
                                  isOwn: found.message.role == .user)
            } ?? .unavailable("Voice note \(index) is unavailable on message \(messageID). Load the whole message to inspect its attachments.")
        case .file(let messageID, let index):
            self = Self.attachment(messageID, index, in: data).map { Self.file($0.attachment) }
                ?? .unavailable("File \(index) is unavailable on message \(messageID). Load the whole message to inspect its attachments.")
        case .otherRoom(let exchange):
            self = .otherRoom(exchange)
        case .envelope(let messageID):
            self = data.rowContent[messageID].map { Self.envelope($0) }
                ?? .unavailable("Envelope \(messageID) has no available transcript row. Reopen the conversation to inspect its sync status.")
        case .trouble:
            self = .unavailable("Reply needs attention. Open the conversation's status to inspect the reported cause.")
        }
    }

    /// Indexes count into the message's `attachments`, as the reference says.
    private static func attachment(_ messageID: String, _ index: Int, in data: TranscriptAttachmentData)
        -> (message: ChatMessage, attachment: ChatAttachmentSummary)? {
        guard let message = data.messages[messageID], message.attachments.indices.contains(index) else { return nil }
        return (message, message.attachments[index])
    }
}

// MARK: - What each attachment draws

/// The hosted root. It carries the conversation's whole environment, so the stores, pairing and appearance reach every attachment
/// as they reach the rest of the chat.
struct TranscriptAttachmentRoot: View {
    let box: TranscriptAttachmentBox

    var body: some View {
        if let environment = box.environment {
            TranscriptAttachmentFrame(resized: { box.resized() }) { TranscriptAttachmentBody(box: box) }
                .environment(\.self, environment)
        }
    }
}

private struct TranscriptAttachmentBody: View {
    let box: TranscriptAttachmentBox

    @ViewBuilder var body: some View {
        switch box.model {
        case .matter(let row):
            MobileFaceRow(page: "inbox", row: row)
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
        case .envelope(let content):
            DisclosureGroup("Delegated reply") {
                Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
        case .unavailable(let cause):
            Label(cause, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(NativeAgentMobileTheme.Colors.trouble)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A markdown table as a Grid sized from its content, cells read with the same sanitized inline markdown as prose.
private struct TranscriptTableView: View {
    let table: ChatMarkdownTable

    var body: some View {
        let columns = Array(0..<table.columnCount)
        ScrollView(.horizontal, showsIndicators: true) {
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
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeAgentMobileTheme.Colors.quietFill, in: RoundedRectangle(cornerRadius: TranscriptMetrics.codeRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func cell(_ text: String, column: Int) -> some View {
        let align = table.align(column)
        let horizontal: HorizontalAlignment = align == .trailing ? .trailing : align == .center ? .center : .leading
        return TranscriptTableCellLayout(maxWidth: 220, alignment: horizontal) {
            Text(ChatRichContentParser.inline(text).presentation)
                .multilineTextAlignment(align == .trailing ? .trailing : align == .center ? .center : .leading)
        }
        .gridColumnAlignment(horizontal)
    }
}

private struct TranscriptTableCellLayout: Layout {
    let maxWidth: CGFloat
    let alignment: HorizontalAlignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let cap = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        let fit = child.sizeThatFits(ProposedViewSize(width: cap, height: proposal.height))
        return CGSize(width: min(cap, fit.width), height: fit.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let (x, anchor): (CGFloat, UnitPoint) = switch alignment {
        case .trailing: (bounds.maxX, .topTrailing)
        case .center: (bounds.midX, .top)
        default: (bounds.minX, .topLeading)
        }
        child.place(at: CGPoint(x: x, y: bounds.minY), anchor: anchor, proposal: ProposedViewSize(bounds.size))
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
