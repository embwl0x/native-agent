import Foundation
// Blueprint: | `TranscriptBuild.swift` | Content-keyed conversation blocks for the press and phone |

/// What a door shows of one conversation. The rows are the transcript's own (the Mac's, or the records the phone received), each read through
/// its face; the agent's words come from the presentation part; cards are the ids a row carries. The door adds only its physics.
public struct TranscriptThread<Row: TranscriptRow> {
    public var groups: [TranscriptGroup<Row>]
    public var exchanges: [OtherRoomExchange]
    /// Mac-owned presentation, or the explicitly local row's own presentation.
    public var face: (Row) -> TranscriptRowFace
    /// The agent's words by key ("headline:<first fold row id>", "detail:<row id>") when the door holds them live; a face's carried words otherwise.
    public var words: ((String) -> String?)?
    /// The card ids a row carries, in mount order.
    public var cards: (String) -> [String]
    /// Changes when a face's inputs beyond its row change, so built groups read their faces again.
    public var faceEpoch: String
    /// The press's completed markdown and open tail, already parsed for the live row.
    public var livePieces: [String: [TranscriptPiece]]
    /// Asked once per run content whose headline is not prepared yet (the Mac prepares it; the phone receives it).
    public var wanted: (([Row]) -> Void)?
    public var door: TranscriptDoor

    public init(groups: [TranscriptGroup<Row>], exchanges: [OtherRoomExchange] = [], face: @escaping (Row) -> TranscriptRowFace,
                words: ((String) -> String?)? = nil, cards: @escaping (String) -> [String] = { _ in [] },
                faceEpoch: String = "", livePieces: [String: [TranscriptPiece]] = [:],
                wanted: (([Row]) -> Void)? = nil, door: TranscriptDoor = TranscriptDoor()) {
        (self.groups, self.exchanges, self.face, self.words, self.cards) = (groups, exchanges, face, words, cards)
        (self.faceEpoch, self.wanted, self.door) = (faceEpoch, wanted, door)
        self.livePieces = livePieces
    }
}

/// One door's physics around the conversation: never a second reading of it.
public struct TranscriptDoor: Equatable, Sendable {
    /// The reply streaming here: its first word block is its waiting line until words arrive, so the words replace it in place.
    public struct Live: Equatable, Sendable {
        public var rowID: String
        public var waiting: String
        public init(rowID: String, waiting: String) { (self.rowID, self.waiting) = (rowID, waiting) }
    }

    /// Before the first row (the phone's earlier-history action).
    public var leading: [TranscriptBlock]
    /// After a row's own blocks, by row id (the phone's send-now, whole-message and retry actions).
    public var after: [String: [TranscriptBlock]]
    /// After everything (the Mac's trouble line).
    public var trailing: [TranscriptBlock]
    public var live: Live?

    public init(leading: [TranscriptBlock] = [], after: [String: [TranscriptBlock]] = [:], trailing: [TranscriptBlock] = [], live: Live? = nil) {
        (self.leading, self.after, self.trailing, self.live) = (leading, after, trailing, live)
    }
}

@available(macOS 15, iOS 18, *)
public enum TranscriptBuilder {
    /// The whole conversation. A group unchanged since the last build reuses its blocks; ids never depend on anything but the row, so an
    /// unchanged conversation is no edit and a reader's place holds.
    public static func build<Row>(_ thread: TranscriptThread<Row>, cache: TranscriptBuildCache<Row>) -> TranscriptDocument {
        let groups = thread.groups
        let hosts = TranscriptGrouping.cardHosts(groups)
        let relocated = Set(hosts.values.joined())
        let rooms = thread.exchanges.isEmpty ? [:] : OtherRoomExchange.anchored(thread.exchanges, to: groups.compactMap { group in
            group.messages.first.flatMap { row in UserDisplayFormatters.parseISOTimestamp(row.createdAt).map { (id: group.id, at: $0) } }
        })
        var blocks = thread.door.leading
        blocks.reserveCapacity(blocks.count + groups.count * 2)
        for group in groups {
            for exchange in rooms[group.id] ?? [] { blocks.append(roomBlock(exchange)) }
            blocks += cache.blocks(group, slots: slots(group, hosts: hosts, relocated: relocated, cards: thread.cards), thread: thread)
            for row in group.messages { blocks += thread.door.after[row.id] ?? [] }
        }
        for exchange in rooms[""] ?? [] { blocks.append(roomBlock(exchange)) }
        blocks += thread.door.trailing
        if !blocks.isEmpty { blocks[0].lead = .none }
        cache.trim(retaining: Set(groups.map(\.id)))
        return TranscriptDocument(blocks: blocks)
    }

    /// Live blocks close unfinished Markdown; settlement restores the authored text with the same block identities.
    public static func liveBlocks(messageID: String, role: String, text: String, lead: TranscriptBlock.Lead) -> [TranscriptBlock] {
        TranscriptDocument.stamp(TranscriptDocument.replyPieces(TranscriptGrouping.readableText(text), ink: .primary, edge: true),
                                 messageID: messageID, role: role, lead: lead)
    }

    // MARK: Groups

    /// The cards a group draws, in order: a reply hosts the cards relocated from the run before it, a run keeps the cards of its rows that
    /// stayed, and a mirrored card is its own.
    static func slots(_ group: TranscriptGroup<some TranscriptRow>, hosts: [String: [String]], relocated: Set<String>,
                      cards: (String) -> [String]) -> [TranscriptCardSlot] {
        let rowIDs: [String]
        if !group.isToolGroup {
            rowIDs = group.messages.first.flatMap { hosts[$0.id] } ?? []
        } else if group.messages.count == 1, group.messages[0].metadata?.interactionMirror != nil {
            rowIDs = [group.messages[0].id]
        } else {
            rowIDs = group.messages.map(\.id).filter { !relocated.contains($0) }
        }
        return rowIDs.compactMap { rowID in
            let ids = cards(rowID)
            return ids.isEmpty ? nil : TranscriptCardSlot(rowID: rowID, cardIDs: ids)
        }
    }

    static func gapBlock(_ group: TranscriptGroup<some TranscriptRow>) -> TranscriptBlock? {
        group.gapAbove.map { date in
            TranscriptBlock(id: "gap-" + group.id, messageID: "gap-" + group.id, role: "system", kind: .gap(date), source: "", lead: .gap,
                            foldGroup: nil)
        }
    }

    static func roomBlock(_ exchange: OtherRoomExchange) -> TranscriptBlock {
        TranscriptBlock(id: "room-" + exchange.id, messageID: "room-" + exchange.id, role: "system",
                        kind: .attachment(.otherRoom(exchange)), source: "", lead: .message, foldGroup: nil)
    }

    static func cardBlocks(_ slots: [TranscriptCardSlot]) -> [TranscriptBlock] {
        slots.flatMap { slot in
            slot.cardIDs.enumerated().map { index, cardID in
                TranscriptBlock(id: "card-" + cardID, messageID: slot.rowID, role: "system", kind: .attachment(.card(rowID: slot.rowID, cardID: cardID)),
                                source: "", lead: index == 0 ? .message : .paragraph, foldGroup: nil)
            }
        }
    }

    // MARK: Rows

    /// Row content and attachments retain their order; voice notes carry their own words.
    static func rowBlocks(_ row: some TranscriptRow, face: TranscriptRowFace, slots: [TranscriptCardSlot],
                          live: TranscriptDoor.Live?, prepared: [TranscriptPiece]?) -> [TranscriptBlock] {
        let id = row.id
        let role = row.role
        let text = face.words ?? row.content
        if face.seat == .envelope {
            return TranscriptDocument.stamp([TranscriptPiece(kind: .attachment(.envelope(messageID: id)), source: text)], messageID: id, role: role,
                                            lead: .message) + cardBlocks(slots)
        }
        var out: [TranscriptBlock] = []
        var images: [Int] = [], voices: [Int] = [], files: [Int] = []
        for (index, attachment) in (row.metadata?.attachments ?? []).enumerated() {
            switch attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "audio": voices.append(index)
            case "image": images.append(index)
            default: files.append(index)
            }
        }
        func attach(_ name: String, _ index: Int, _ ref: TranscriptAttachmentRef) {
            out.append(TranscriptBlock(id: "\(id)@\(name)-\(index)", messageID: id, role: role, kind: .attachment(ref), source: "",
                                       lead: out.isEmpty ? .message : .paragraph, foldGroup: nil))
        }
        for index in images { attach("image", index, .image(messageID: id, index: index)) }
        for index in voices { attach("voice", index, .voice(messageID: id, index: index)) }
        for index in files { attach("file", index, .file(messageID: id, index: index)) }

        let lead: TranscriptBlock.Lead = out.isEmpty ? .message : .paragraph
        let readable = TranscriptGrouping.readableText(text)
        let hasWords = readable.contains { !$0.isWhitespace }
        if let live, live.rowID == id, !hasWords, prepared?.isEmpty != false {
            out.append(TranscriptBlock(id: id + "#0", messageID: id, role: role,
                                       kind: .reply(runs: [TranscriptRun(text: TranscriptDocument.lineBreaks(live.waiting))], ink: .quiet),
                                       source: "", lead: lead, foldGroup: nil))
            return out + cardBlocks(slots)
        }
        var pieces: [TranscriptPiece] = []
        if voices.isEmpty, face.seat == .right {
            let runs = TranscriptDocument.flattened(TranscriptDocument.replyPieces(readable, ink: .primary, edge: false))
            if !runs.isEmpty {
                let tag = face.tag.map { TranscriptBlock.Tag(symbol: $0.symbol, label: $0.label, automated: $0.automated) }
                pieces.append(TranscriptPiece(kind: .user(runs: runs, tag: tag), source: text))
            }
        } else if voices.isEmpty {
            if let prepared { pieces = prepared }
            else { pieces = TranscriptDocument.replyPieces(readable, ink: face.quiet == true ? .quiet : .primary, edge: false) }
        }
        // The reply has no tag, so a left-seated row's bridge or provenance line is its own quiet first paragraph.
        if face.seat == .left, let label = face.label, !pieces.isEmpty || !out.isEmpty {
            pieces.insert(TranscriptPiece(kind: .reply(runs: [TranscriptRun(text: label, bold: true)], ink: .quiet), source: ""), at: 0)
        }
        return out + TranscriptDocument.stamp(pieces, messageID: id, role: role, lead: lead) + cardBlocks(slots)
    }

    /// Tool rows fold beneath their authored headline; receipts and decisions remain visible.
    static func runBlocks<Row: TranscriptRow>(_ group: TranscriptGroup<Row>, slots: [TranscriptCardSlot], thread: TranscriptThread<Row>)
        -> (blocks: [TranscriptBlock], wordKeys: [String], foldRows: [Row]) {
        if group.messages.count == 1, group.messages[0].metadata?.interactionMirror != nil { return (cardBlocks(slots), [], []) }
        let rows = group.messages.map { (row: $0, face: thread.face($0)) }
        let foldRows = rows.filter { $0.face.asks != true && $0.face.receipt == nil }
        let failed = Set(foldRows.filter { $0.face.failed == true }.map(\.row.id))
        var blocks: [TranscriptBlock] = []
        var wordKeys: [String] = []
        let folds = !foldRows.isEmpty
        if let first = foldRows.first {
            let key = "headline:" + first.row.id
            wordKeys = [key] + foldRows.map { "detail:" + $0.row.id }
            let authored: String? = if let words = thread.words { words(key) } else { first.face.headline }
            let headline = authored ?? ""
            blocks.append(TranscriptBlock(id: "fold-" + group.id, messageID: group.id, role: "tool",
                                          kind: .foldHeadline(text: TranscriptDocument.lineBreaks(headline), failed: !failed.isEmpty),
                                          source: headline, lead: .message, foldGroup: nil))
        }
        for (row, face) in rows where face.asks != true {
            let detail: String? = if let words = thread.words { words("detail:" + row.id) } else { face.detail }
            let line = face.receipt ?? detailLine(row, words: detail)
            blocks.append(TranscriptBlock(id: "tool-" + row.id, messageID: row.id, role: row.role,
                                          kind: .foldDetail(text: TranscriptDocument.lineBreaks(line), failed: failed.contains(row.id)),
                                          source: line, lead: folds ? .detail : .message, foldGroup: folds ? group.id : nil))
        }
        for (row, face) in rows where face.asks == true {
            blocks.append(TranscriptBlock(id: "approval-" + row.id, messageID: row.id, role: "system", kind: .attachment(.approval(rowID: row.id)),
                                          source: "", lead: .message, foldGroup: nil))
        }
        return (blocks + cardBlocks(slots), wordKeys, foldRows.map(\.row))
    }

    /// Authored detail and its observed duration, or the missing presentation evidence.
    static func detailLine(_ row: some TranscriptRow, words: String?) -> String {
        let line = words ?? "Waiting for activity detail · " + row.id
        guard let ms = row.metadata?.durationMs else { return line }
        return line + " · \(ms)ms"
    }
}

/// The cards one row contributes to a group, in mount order.
public struct TranscriptCardSlot: Equatable, Sendable {
    public let rowID: String
    public let cardIDs: [String]
}

/// Built blocks per group, reused while the group's rows, gap, cards, face epoch, live line and the agent's words are unchanged. A door keeps one
/// for the conversation it shows.
@available(macOS 15, iOS 18, *)
public final class TranscriptBuildCache<Row: TranscriptRow> {
    struct Entry {
        var rows: [Row]
        var gapAbove: Date?
        var slots: [TranscriptCardSlot]
        var faceEpoch: String
        var live: TranscriptDoor.Live?
        var livePieces: [String: [TranscriptPiece]]
        var wordKeys: [String]
        var words: [String?]
        var blocks: [TranscriptBlock]
    }

    var entries: [String: Entry] = [:]
    /// The rows each run's headline was last asked for, by its words key.
    var asked: [String: [Row]] = [:]
    let limit: Int

    public init(limit: Int = 4_096) { self.limit = limit }

    func blocks(_ group: TranscriptGroup<Row>, slots: [TranscriptCardSlot], thread: TranscriptThread<Row>) -> [TranscriptBlock] {
        let live = thread.door.live.flatMap { live in group.messages.contains { $0.id == live.rowID } ? live : nil }
        let prepared = thread.livePieces.filter { key, _ in group.messages.contains { $0.id == key } }
        if let entry = entries[group.id],
           entry.rows == group.messages,
           entry.gapAbove == group.gapAbove, entry.slots == slots,
           entry.faceEpoch == thread.faceEpoch, entry.live == live, entry.livePieces == prepared,
           entry.wordKeys.map({ thread.words?($0) }) == entry.words {
            return entry.blocks
        }
        var blocks = TranscriptBuilder.gapBlock(group).map { [$0] } ?? []
        var wordKeys: [String] = []
        if group.isToolGroup {
            let run = TranscriptBuilder.runBlocks(group, slots: slots, thread: thread)
            blocks += run.blocks
            wordKeys = run.wordKeys
            if let key = wordKeys.first, let wanted = thread.wanted {
                if asked[key] != run.foldRows {
                    asked[key] = run.foldRows
                    wanted(run.foldRows)
                }
            }
        } else if let row = group.messages.first {
            blocks += TranscriptBuilder.rowBlocks(row, face: thread.face(row), slots: slots, live: live, prepared: prepared[row.id])
        }
        entries[group.id] = Entry(rows: group.messages, gapAbove: group.gapAbove, slots: slots,
                                  faceEpoch: thread.faceEpoch, live: live, livePieces: prepared, wordKeys: wordKeys,
                                  words: wordKeys.map { thread.words?($0) }, blocks: blocks)
        return blocks
    }

    /// Past the limit, groups outside the current reading go; a group seen again builds once.
    func trim(retaining groups: Set<String>) {
        guard entries.count > limit else { return }
        entries = entries.filter { groups.contains($0.key) }
        if asked.count > limit { asked.removeAll() }
    }
}
