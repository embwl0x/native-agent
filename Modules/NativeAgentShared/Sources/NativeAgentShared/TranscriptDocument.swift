import Foundation

// Blueprint: | `TranscriptDocument.swift` | The conversation as one document on Mac and iPhone: blocks, attachment references, the edit between two |

/// The conversation as one document. Every row becomes blocks in reading order, and one block is one paragraph of the text view.
/// Place is a text location, never a measured height: block ids are stable across rebuilds, so the view edits only what changed.
public struct TranscriptDocument: Equatable, Sendable {
    public var blocks: [TranscriptBlock]

    public init(blocks: [TranscriptBlock]) {
        self.blocks = blocks
    }

    public static let empty = TranscriptDocument(blocks: [])

    /// The one edit that turns this document into `next`: the blocks before `start` and the last `kept` blocks are equal in both.
    /// Appends and a growing tail touch only the end, so everything the reader sees above stays where it is.
    public func edit(to next: TranscriptDocument) -> TranscriptDocumentEdit? {
        let old = blocks, new = next.blocks
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        if start == old.count, start == new.count { return nil }
        var kept = 0
        while kept < old.count - start, kept < new.count - start, old[old.count - 1 - kept] == new[new.count - 1 - kept] { kept += 1 }
        return TranscriptDocumentEdit(start: start, removed: old.count - start - kept, inserted: Array(new[start..<(new.count - kept)]))
    }
}

/// Replace `removed` blocks at `start` with `inserted`.
public struct TranscriptDocumentEdit: Equatable, Sendable {
    public var start: Int
    public var removed: Int
    public var inserted: [TranscriptBlock]

    public init(start: Int, removed: Int, inserted: [TranscriptBlock]) {
        self.start = start
        self.removed = removed
        self.inserted = inserted
    }
}

public struct TranscriptBlock: Equatable, Sendable, Identifiable {
    /// "<messageID>#<n>" for a message's nth block of words; "fold-<groupID>" for a tool run's headline, "tool-<rowID>" for its detail
    /// lines, "gap-<groupID>", "card-<cardID>", "approval-<id>", "room-<exchangeID>" and "trouble" for the rest. A platform may add
    /// its own ids for a message's other blocks, never in the "<messageID>#" form, which belongs to the words a live reply replaces.
    public let id: String
    /// The row whose menu, hover bar and first-render receipt this block answers to; a tool run's headline answers to its group id.
    public let messageID: String
    public let role: String
    public var kind: Kind
    /// The markdown this block came from. Copy as Markdown joins the sources of the selected blocks.
    public var source: String
    /// The space above the block.
    public var lead: Lead
    /// The tool-run group this block folds into: hidden while that group is closed. Nil when the block always shows.
    public var foldGroup: String?

    public init(id: String, messageID: String, role: String, kind: Kind, source: String, lead: Lead, foldGroup: String?) {
        self.id = id
        self.messageID = messageID
        self.role = role
        self.kind = kind
        self.source = source
        self.lead = lead
        self.foldGroup = foldGroup
    }

    public enum Kind: Equatable, Sendable {
        /// Right-seated bubble. The tag is the provenance or bridge line drawn above it.
        case user(runs: [TranscriptRun], tag: Tag?)
        case reply(runs: [TranscriptRun], ink: Ink)
        case heading(runs: [TranscriptRun])
        case quote(runs: [TranscriptRun])
        case listItem(marker: String, depth: Int, runs: [TranscriptRun])
        case code(language: String, text: String)
        /// A tool run's one line ("shell.run ×3 · mac.look · 1 failed · 18s"); its detail lines carry `foldGroup`.
        case foldHeadline(text: String, failed: Bool)
        case foldDetail(text: String, failed: Bool)
        /// "Today 3:04 PM" after an hour of quiet.
        case gap(Date)
        case attachment(TranscriptAttachmentRef)
    }

    /// Quiet ink is a peer bridge, a system row or a status line: secondary colour, label size.
    public enum Ink: Equatable, Sendable { case primary, quiet }

    public struct Tag: Equatable, Sendable {
        public var symbol: String
        public var label: String
        /// Automated provenance draws in the trouble colour.
        public var automated: Bool

        public init(symbol: String, label: String, automated: Bool) {
            self.symbol = symbol
            self.label = label
            self.automated = automated
        }
    }

    public enum Lead: Equatable, Sendable { case none, message, paragraph, listItem, detail, gap }
}

/// One inline run of rendered markdown. Markdown keeps only http, https and mailto links; a platform's own action link (a row's
/// button as words in the document) is the only other scheme a run carries.
public struct TranscriptRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var strike: Bool
    public var link: URL?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, strike: Bool = false, link: URL? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strike = strike
        self.link = link
    }
}

/// What an attachment block shows, as ids and values both platforms carry. Live state (an answered card, a playing note) lives in
/// the platform's model keyed by the block id, never in the view.
public enum TranscriptAttachmentRef: Equatable, Sendable {
    /// A card on a row: the Mac's mounted card, the iPhone's inline interaction or mirrored inbox card.
    case card(rowID: String, cardID: String)
    /// The Mac's pending-approval row, or the iPhone's approval request by its id.
    case approval(rowID: String)
    case table(ChatMarkdownTable)
    /// Image, voice and file indexes count into the message's attachments.
    case image(messageID: String, index: Int)
    case voice(messageID: String, index: Int)
    case file(messageID: String, index: Int)
    case otherRoom(OtherRoomExchange)
    case envelope(messageID: String)
    case trouble
}
