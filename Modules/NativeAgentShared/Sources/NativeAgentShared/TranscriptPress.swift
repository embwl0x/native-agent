import Foundation

// Blueprint: | `TranscriptPress.swift` | Actor-owned transcript blocks, rendered paragraphs and acknowledged per-reader edit scripts |

public struct TranscriptRenderedParagraph: Equatable, Sendable, Codable {
    public var block: TranscriptBlock
    public var body: AttributedString
    public var separator: AttributedString
    public var hidden: AttributedString
    public var mapping: TranscriptRevealMapping

    public init(block: TranscriptBlock, body: AttributedString, separator: AttributedString, hidden: AttributedString,
                mapping: TranscriptRevealMapping) {
        (self.block, self.body, self.separator, self.hidden) = (block, body, separator, hidden)
        self.mapping = mapping
    }

    private enum CodingKeys: String, CodingKey { case block, body, separator, hidden, mapping }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        block = try values.decode(TranscriptBlock.self, forKey: .block)
        body = try values.decode(AttributedString.self, forKey: .body, configuration: TranscriptAttributes.self)
        separator = try values.decode(AttributedString.self, forKey: .separator, configuration: TranscriptAttributes.self)
        hidden = try values.decode(AttributedString.self, forKey: .hidden, configuration: TranscriptAttributes.self)
        mapping = try values.decode(TranscriptRevealMapping.self, forKey: .mapping)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(block, forKey: .block)
        try values.encode(body, forKey: .body, configuration: TranscriptAttributes.self)
        try values.encode(separator, forKey: .separator, configuration: TranscriptAttributes.self)
        try values.encode(hidden, forKey: .hidden, configuration: TranscriptAttributes.self)
        try values.encode(mapping, forKey: .mapping)
    }
}

public struct TranscriptParagraphEdit: Equatable, Sendable, Codable {
    public var start: Int
    public var removed: Int
    public var inserted: [TranscriptRenderedParagraph]
}

public struct TranscriptRevealCut: Equatable, Sendable, Codable {
    public var utf8End: Int
    public var utf16End: Int
    /// UTF-8 end in the block's Markdown source, for copying its visible glyphs.
    public var markdownEnd: Int

    public init(utf8End: Int, utf16End: Int, markdownEnd: Int) {
        (self.utf8End, self.utf16End, self.markdownEnd) = (utf8End, utf16End, markdownEnd)
    }
}

public struct TranscriptLiveLine: Equatable, Sendable, Codable {
    public var rowID: String
    public var text: String
    public var glyphs: String
    public var streaming: Bool
    public var cuts: [String: [TranscriptRevealCut]]
}

public struct TranscriptPressEdits: Equatable, Sendable, Codable {
    public var base: UUID?
    public var id: UUID
    public var edits: [TranscriptParagraphEdit]
    public var live: TranscriptLiveLine?
    public var wordKeys: [String]
    public var issue: String?
    public var complete: Bool
}

public struct TranscriptFace: FaceValue {
    public var readers: [UUID: TranscriptPressEdits]
}

/// A reader's frozen inputs. The render closure runs only on the press actor.
public struct TranscriptPressInput<Row: TranscriptRow>: Sendable {
    public var session: String
    public var presentation: String
    public var groups: [TranscriptGroup<Row>]
    public var exchanges: [OtherRoomExchange]
    public var cards: [String: [String]]
    public var faceEpoch: String
    public var face: @Sendable (Row) -> TranscriptRowFace
    public var wanted: @Sendable ([Row]) -> Void
    public var render: @Sendable (TranscriptBlock, Double, Double) throws -> TranscriptRenderedParagraph
    public var door: TranscriptDoor
    /// Synced rows carry their authored words; a resident reader observes the live copy slots.
    public var useCarriedWords: Bool
    public var liveID: String?
    public var liveText: String?
    public var width: Double
    public var scale: Double
    public var viewport: Set<String>
    public var openingParagraphs: Int
    public var hasEarlierMessages: Bool

    public init(session: String, presentation: String, groups: [TranscriptGroup<Row>], exchanges: [OtherRoomExchange], cards: [String: [String]],
                faceEpoch: String, face: @escaping @Sendable (Row) -> TranscriptRowFace,
                wanted: @escaping @Sendable ([Row]) -> Void,
                render: @escaping @Sendable (TranscriptBlock, Double, Double) throws -> TranscriptRenderedParagraph,
                door: TranscriptDoor, liveID: String?, liveText: String?, width: Double, scale: Double, viewport: Set<String>,
                openingParagraphs: Int, useCarriedWords: Bool = false, hasEarlierMessages: Bool = false) {
        (self.session, self.groups, self.exchanges, self.cards) = (session, groups, exchanges, cards)
        self.presentation = presentation
        (self.faceEpoch, self.face, self.wanted, self.render) = (faceEpoch, face, wanted, render)
        (self.door, self.liveID, self.liveText) = (door, liveID, liveText)
        self.useCarriedWords = useCarriedWords
        (self.width, self.scale, self.viewport) = (width, scale, viewport)
        self.openingParagraphs = openingParagraphs
        self.hasEarlierMessages = hasEarlierMessages
    }
}

@available(macOS 15, iOS 18, *)
public actor TranscriptPress<Row: TranscriptRow> {
    private struct Printed: Equatable {
        var paragraphs: [TranscriptRenderedParagraph] = []
        var live: TranscriptLiveLine?
        var wordKeys: [String] = []
        var failure: String?
        var unconfirmedReply = false
        var complete = false

        var issue: String? {
            var causes: [String] = []
            if let failure { causes.append(failure) }
            if unconfirmedReply {
                causes.append("Finished reply has no conversation row. Read the conversation again; its reply is unconfirmed.")
            }
            for paragraph in paragraphs {
                if case .failed(let reason) = paragraph.mapping {
                    causes.append("Transcript reveal mapping failed for \(paragraph.block.id): \(reason)")
                }
            }
            return causes.isEmpty ? nil : causes.joined(separator: "\n")
        }
    }

    private struct Format: Hashable {
        var width: Double
        var scale: Double
        init(_ input: TranscriptPressInput<Row>) { width = input.width.rounded(.down); scale = input.scale }
    }

    private struct Selection: Equatable {
        var groupIDs: [String]
        var rows: [[Row]]
        var toolGroups: [Bool]
        var gaps: [Date?]
        var exchanges: [OtherRoomExchange]
        var cards: [String: [String]]
        var faceEpoch: String
        var door: TranscriptDoor
        var useCarriedWords: Bool
        var liveID: String?
        var liveText: String?
        var hasEarlierMessages: Bool

        init(_ input: TranscriptPressInput<Row>) {
            groupIDs = input.groups.map(\.id); rows = input.groups.map(\.messages)
            toolGroups = input.groups.map(\.isToolGroup); gaps = input.groups.map(\.gapAbove)
            exchanges = input.exchanges; cards = input.cards; faceEpoch = input.faceEpoch; door = input.door
            useCarriedWords = input.useCarriedWords
            liveID = input.liveID; liveText = input.liveText
            hasEarlierMessages = input.hasEarlierMessages
        }
    }

    private struct Saved {
        var selection: Selection
        var words: [String: String]
        var value: Printed
        var complete: Bool
    }

    /// The press keeps the book when its window closes. A reader owns only its delivery and place.
    private final class Session {
        let cache = TranscriptBuildCache<Row>()
        var markdown = TranscriptLiveMarkdown()
        var paragraphs: [String: [Format: TranscriptRenderedParagraph]] = [:]
        var printed: [Format: [String: Saved]] = [:]

        func keep(_ value: Printed, input: TranscriptPressInput<Row>, words: [String: String], complete: Bool) {
            printed[Format(input), default: [:]][input.presentation] =
                Saved(selection: Selection(input), words: words, value: value, complete: complete)
        }

        func ready(_ input: TranscriptPressInput<Row>) -> Saved? {
            guard let saved = printed[Format(input)]?[input.presentation], saved.selection == Selection(input) else { return nil }
            return saved
        }

        func revealed(_ value: Printed) {
            guard let live = value.live, !live.streaming else { return }
            for (format, values) in printed {
                for (presentation, previous) in values where previous.value.live?.rowID == live.rowID
                    && previous.value.live?.text == live.text && previous.value.live?.streaming == false {
                    var saved = previous
                    saved.value.live = nil
                    printed[format]?[presentation] = saved
                }
            }
        }
    }

    private final class Reader {
        var input: TranscriptPressInput<Row>
        let session: Session
        var words: [String: String] = [:]
        var current = Printed()
        var applied = Printed()
        var appliedID: UUID?
        var sent: [UUID: Printed] = [:]
        var packet: TranscriptPressEdits?
        var opening = true
        var openingApplied: Set<UUID> = []
        var paintedID: UUID?
        var openingStopped = false
        var unwrittenLiveRows: Set<String> = []
        init(_ input: TranscriptPressInput<Row>, session: Session) { self.input = input; self.session = session }
    }

    private let feed: FaceFeedSource
    private var readers: [UUID: Reader] = [:]
    private var sessions: [String: Session] = [:]
    private var pending: Set<UUID> = []
    private var printing = false
    private var outbox: [String: TranscriptFace] = [:]
    private var sending = false
    private let log = ModuleLog(category: "TranscriptPress")

    public init(feed: FaceFeedSource) { self.feed = feed }

    public func update(reader id: UUID, input: TranscriptPressInput<Row>) async {
        let reader: Reader
        let mounting = readers[id]?.input.session != input.session
        if let existing = readers[id], existing.input.session == input.session {
            reader = existing
            reader.input = input
            reader.openingStopped = false
        } else {
            let session: Session
            if let existing = sessions[input.session] { session = existing }
            else { session = Session(); sessions[input.session] = session }
            reader = Reader(input, session: session)
            readers[id] = reader
        }
        if let liveID = input.liveID { reader.unwrittenLiveRows.insert(liveID) }
        for group in input.groups.reversed() {
            for row in group.messages { reader.unwrittenLiveRows.remove(row.id) }
            if reader.unwrittenLiveRows.isEmpty { break }
        }
        if mounting, let saved = reader.session.ready(input) {
            reader.current = Self.openingPage(saved.value, count: input.openingParagraphs)
            reader.words = saved.words
            log("reuse session=%@ reader=%@ paragraphs=%ld renders=0", input.session, id.uuidString, saved.value.paragraphs.count)
            await publish(reader)
            guard readers[id] === reader else { return }
            if !reader.current.paragraphs.isEmpty { return }
        }
        enqueue(id)
    }

    public func words(reader id: UUID, values: [String: String]) async {
        guard let reader = readers[id], reader.words != values else { return }
        reader.words = values
        enqueue(id)
    }

    public func live(reader id: UUID, rowID: String, text: String) async {
        guard let reader = readers[id], reader.input.liveID == rowID, reader.input.liveText != text else { return }
        reader.input.liveText = text
        enqueue(id)
    }

    public func resize(reader id: UUID, width: Double, scale: Double, viewport: Set<String>) async {
        guard let reader = readers[id], reader.input.width != width || reader.input.scale != scale || reader.input.viewport != viewport else { return }
        reader.input.width = width
        reader.input.scale = scale
        reader.input.viewport = viewport
        enqueue(id)
    }

    public func revealed(reader id: UUID, rowID: String) async {
        guard let reader = readers[id], reader.current.live?.rowID == rowID,
              reader.current.live?.streaming == false else { return }
        reader.session.revealed(reader.current)
        reader.current.live = nil
        await publish(reader)
    }

    /// Acknowledgement names an actual applied script. Coalescing never changes the base of an unapplied edit.
    @discardableResult
    public func applied(reader id: UUID, script: UUID) async -> Bool {
        guard let reader = readers[id], let printed = reader.sent[script] else { return false }
        reader.applied = printed
        reader.appliedID = script
        reader.sent = [:]
        reader.packet = nil
        if reader.opening {
            reader.openingApplied.insert(script)
            finishOpening(id, reader)
            return true
        }
        if printed != reader.current { await publish(reader) }
        return true
    }

    /// Only a draw of the acknowledged opening page releases older paragraphs. Other readers keep printing meanwhile.
    public func painted(reader id: UUID, script: UUID) {
        guard let reader = readers[id], reader.opening, !reader.openingStopped,
              reader.sent[script] != nil || reader.openingApplied.contains(script) else { return }
        reader.paintedID = script
        finishOpening(id, reader)
    }

    private func finishOpening(_ id: UUID, _ reader: Reader) {
        guard let painted = reader.paintedID, reader.openingApplied.contains(painted) else { return }
        reader.opening = false
        reader.openingApplied = []
        reader.paintedID = nil
        enqueue(id)
    }

    public func remove(reader id: UUID) async {
        guard let reader = readers.removeValue(forKey: id) else { return }
        pending.remove(id)
        await postSession(reader.input.session)
    }

    public func rejected(reader id: UUID, script: UUID) {
        guard let reader = readers[id], reader.sent[script] != nil else { return }
        reader.openingStopped = true
        reader.opening = false
    }

    public func rebase(reader id: UUID) async {
        guard let reader = readers[id] else { return }
        await publish(reader)
    }

    /// An arrival during printing is held as the reader's next input, independently of feed acknowledgements.
    private func enqueue(_ id: UUID) {
        pending.insert(id)
        guard !printing else { return }
        printing = true
        Task { await drain() }
    }

    private func drain() async {
        while let next = pending.first {
            pending.remove(next)
            if let reader = readers[next] { await printReader(next, reader) }
        }
        printing = false
    }

    private func printReader(_ id: UUID, _ reader: Reader) async {
        guard !reader.openingStopped else { return }
        guard !reader.opening || reader.current.paragraphs.isEmpty else { return }
        let input = reader.input
        let session = reader.session
        if !reader.opening, let saved = session.ready(input), saved.complete, saved.words == reader.words {
            reader.current = saved.value
            await publish(reader)
            return
        }
        var prepared: [String: [TranscriptPiece]] = [:]
        var liveText: String?
        if let liveID = input.liveID, let row = input.groups.lazy.flatMap(\.messages).first(where: { $0.id == liveID }) {
            // A cleared streaming tail reads the settled row's own words.
            let text = input.liveText ?? row.content
            let readable = ChatRichContentParser.visibleText(TranscriptGrouping.readableText(text))
            prepared[liveID] = session.markdown.pieces(rowID: liveID, text: readable)
            liveText = readable
        }
        let words = reader.words
        let cards = input.cards
        func build(_ groups: [TranscriptGroup<Row>], exchanges: [OtherRoomExchange]) -> TranscriptDocument {
            var door = input.door
            door.live = input.liveID.map { .init(rowID: $0, waiting: input.door.live?.waiting ?? "") }
            let authored: ((String) -> String?)? = input.useCarriedWords ? nil : { words[$0] }
            return TranscriptBuilder.build(TranscriptThread(
                groups: groups, exchanges: exchanges, face: input.face,
                words: authored, cards: { cards[$0] ?? [] }, faceEpoch: input.faceEpoch,
                livePieces: prepared, wanted: input.wanted,
                door: door
            ), cache: session.cache)
        }
        if reader.opening {
            let rooms = OtherRoomExchange.anchored(input.exchanges, to: input.groups.compactMap { group in
                group.messages.first.flatMap { row in UserDisplayFormatters.parseISOTimestamp(row.createdAt).map { (id: group.id, at: $0) } }
            })
            var count = min(max(1, input.openingParagraphs / 4), input.groups.count)
            while true {
                let groups = Array(input.groups.suffix(count))
                let kept = Set(groups.map(\.id) + [""])
                let exchanges = rooms.filter { kept.contains($0.key) }.values.flatMap { $0 }
                let document = build(groups, exchanges: exchanges)
                if Self.openingStart(document.blocks, lines: input.openingParagraphs) != nil || count == input.groups.count {
                    await printDocument(document, reader: reader, id: id, input: input,
                                        words: words, liveText: liveText, complete: count == input.groups.count)
                    return
                }
                count += min(count, input.groups.count - count)
            }
        }
        await printDocument(build(input.groups, exchanges: input.exchanges), reader: reader, id: id,
                            input: input, words: words, liveText: liveText, complete: true)
    }

    private func printDocument(_ document: TranscriptDocument, reader: Reader, id: UUID, input: TranscriptPressInput<Row>,
                               words: [String: String], liveText: String?, complete: Bool) async {
        let session = reader.session
        let opening = reader.current.paragraphs.isEmpty
        let tail = Set((Self.openingStart(document.blocks, lines: input.openingParagraphs) ?? 0)..<document.blocks.count)
        let priority = document.blocks.indices.filter { position in
            if opening || (input.viewport.isEmpty && reader.appliedID == nil) { return tail.contains(position) }
            return input.viewport.contains(document.blocks[position].id)
        }
        let prioritized = Set(priority)
        let rest = document.blocks.indices.filter { !prioritized.contains($0) }
        let restyling = reader.current.paragraphs.map(\.block) == document.blocks && !priority.isEmpty
        var values: [String: TranscriptRenderedParagraph] = [:]
        var renders = 0
        do {
            for position in priority + rest {
                let block = document.blocks[position]
                var format = Format(input)
                if case .user = block.kind {} else { format.width = 0 }
                if let cached = session.paragraphs[block.id]?[format], cached.block == block {
                    values[block.id] = cached
                } else {
                    let paragraph = try input.render(block, input.width.rounded(.down), input.scale)
                    session.paragraphs[block.id, default: [:]][format] = paragraph
                    values[block.id] = paragraph
                    renders += 1
                }
                if opening || restyling, position == priority.last {
                    var visible = opening ? Printed() : reader.current
                    for target in priority {
                        guard let value = values[document.blocks[target].id] else {
                            throw CocoaError(.coderReadCorrupt,
                                userInfo: [NSLocalizedDescriptionKey: "The press has no rendered viewport paragraph."])
                        }
                        if opening { visible.paragraphs.append(value) }
                        else { visible.paragraphs[target] = value }
                    }
                    visible.live = liveLine(reader, paragraphs: visible.paragraphs, input: input, text: liveText)
                    reader.current = visible
                    session.keep(visible, input: input, words: words, complete: false)
                    if renders > 0 { log("viewport session=%@ reader=%@ count=%ld", input.session, id.uuidString, renders) }
                    await publish(reader)
                    if opening { return }
                    guard readers[id] === reader, !reader.openingStopped else { return }
                }
            }
            let paragraphs = try document.blocks.map { block in
                guard let value = values[block.id] else {
                    throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "The press has no rendered paragraph."])
                }
                return value
            }
            let live = liveLine(reader, paragraphs: paragraphs, input: input, text: liveText)
            let keys = input.groups.flatMap { session.cache.entries[$0.id]?.wordKeys ?? [] }.sorted()
            reader.current = Printed(paragraphs: paragraphs, live: live, wordKeys: keys, complete: complete && !input.hasEarlierMessages)
            session.keep(reader.current, input: input, words: words, complete: complete)
            if renders > 0 {
                log("render session=%@ reader=%@ count=%ld paragraphs=%ld", input.session, id.uuidString, renders, paragraphs.count)
            }
        } catch {
            reader.current.failure = "Transcript rendering failed: " + error.localizedDescription
        }
        await publish(reader)
    }

    /// Where the opening page begins: the end of the chat, enough to fill the window about twice, nil if the blocks fall short. Folded
    /// rows between its paragraphs stay in, so the older paragraphs that follow go in above it and nothing on screen is set again.
    /// `lines` is one window of the smallest text, and a block's lines are counted roughly: a page that falls short is filled by those older paragraphs.
    private static func openingStart(_ blocks: [TranscriptBlock], lines: Int) -> Int? {
        var covered = 0
        var start = blocks.count
        while start > 0 {
            start -= 1
            let block = blocks[start]
            guard block.foldGroup == nil else { continue }
            if case .attachment = block.kind { covered += 15 } else { covered += 1 + block.source.count / 80 }
            if covered >= lines * 2 { return start }
        }
        return nil
    }

    private static func openingPage(_ printed: Printed, count: Int) -> Printed {
        var page = printed
        let start = openingStart(printed.paragraphs.map(\.block), lines: count) ?? 0
        page.paragraphs = Array(printed.paragraphs[start...])
        page.complete = printed.complete && page.paragraphs.count == printed.paragraphs.count
        if let live = printed.live {
            page.live = TranscriptLiveMarkdown.line(page.paragraphs.filter { $0.block.messageID == live.rowID },
                                                   rowID: live.rowID, text: live.text, streaming: live.streaming)
        }
        return page
    }

    private func liveLine(_ reader: Reader, paragraphs: [TranscriptRenderedParagraph], input: TranscriptPressInput<Row>,
                          text: String?) -> TranscriptLiveLine? {
        if let rowID = input.liveID, let text {
            return TranscriptLiveMarkdown.line(paragraphs.filter { $0.block.messageID == rowID }, rowID: rowID, text: text, streaming: true)
        }
        if let rowID = reader.current.live?.rowID,
           let row = input.groups.lazy.flatMap(\.messages).first(where: { $0.id == rowID }) {
            let text = ChatRichContentParser.visibleText(TranscriptGrouping.readableText(input.face(row).words ?? row.content))
            return TranscriptLiveMarkdown.line(paragraphs.filter { $0.block.messageID == rowID }, rowID: rowID, text: text, streaming: false)
        }
        return nil
    }

    private func publish(_ reader: Reader) async {
        reader.current.unconfirmedReply = reader.input.liveID == nil && !reader.unwrittenLiveRows.isEmpty
        guard reader.current != reader.applied || (reader.appliedID == nil && reader.packet == nil) else { return }
        if let packet = reader.packet, packet.base == reader.appliedID, reader.sent[packet.id] == reader.current { return }
        let token = UUID()
        let packet = TranscriptPressEdits(base: reader.appliedID, id: token,
            edits: Self.edits(from: reader.applied.paragraphs, to: reader.current.paragraphs), live: reader.current.live,
            wordKeys: reader.current.wordKeys, issue: reader.current.issue, complete: reader.current.complete)
        reader.sent[token] = reader.current
        reader.packet = packet
        await postSession(reader.input.session)
    }

    private func postSession(_ session: String) async {
        let packets = readers.filter { $0.value.input.session == session }.compactMapValues(\.packet)
        outbox[session] = TranscriptFace(readers: packets)
        guard !sending else { return }
        sending = true
        while let next = outbox.first {
            outbox[next.key] = nil
            await feed.post(next.value, at: .transcript(session: next.key))
        }
        sending = false
    }

    /// Separate changed runs keep an authored headline or a width-only bubble edit from replacing its healthy siblings.
    private static func edits(from old: [TranscriptRenderedParagraph], to new: [TranscriptRenderedParagraph]) -> [TranscriptParagraphEdit] {
        if old.map({ $0.block.id }) != new.map({ $0.block.id }) {
            // Paragraphs keep their order, so the two line up on those they share and only what lies between is set again: a window
            // sliding down a chat, or a row appearing mid-page, must not reprint everything on screen. Starts are in the old document.
            let positions = Dictionary(new.enumerated().map { ($0.element.block.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            var edits: [TranscriptParagraphEdit] = []
            var from = 0, to = 0
            while true {
                var sharedOld = from
                var sharedNew: Int?
                while sharedOld < old.count {
                    if let position = positions[old[sharedOld].block.id], position >= to, new[position] == old[sharedOld] {
                        sharedNew = position
                        break
                    }
                    sharedOld += 1
                }
                let endNew = sharedNew ?? new.count
                if sharedOld > from || endNew > to {
                    edits.append(TranscriptParagraphEdit(start: from, removed: sharedOld - from, inserted: Array(new[to..<endNew])))
                }
                guard sharedNew != nil else { return edits }
                from = sharedOld + 1
                to = endNew + 1
            }
        }
        var edits: [TranscriptParagraphEdit] = []
        var start: Int?
        for index in new.indices {
            if old[index] != new[index] {
                if start == nil { start = index }
            } else if let from = start {
                edits.append(TranscriptParagraphEdit(start: from, removed: index - from, inserted: Array(new[from..<index])))
                start = nil
            }
        }
        if let from = start { edits.append(TranscriptParagraphEdit(start: from, removed: old.count - from, inserted: Array(new[from...]))) }
        return edits
    }
}
