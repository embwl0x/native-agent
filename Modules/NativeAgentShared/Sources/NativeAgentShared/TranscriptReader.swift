import Foundation
import Observation
import QuartzCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Blueprint: | `TranscriptReader.swift` | `TranscriptReaderCore`: the TextKit 2 document both readers apply press scripts to (paragraph index, script receipt, reader place, paced reveal, folds, hosted-view frames, copy text), with each platform's glass as overridden hooks |

/// The rules where the Mac's and the phone's readers differ, named.
public struct TranscriptReaderRules: Sendable {
    /// How far the reveal may lag the stream, in bytes, before the pacer jumps.
    public var maxLagBytes: Int
    /// Whether a script lays out the paragraphs between its edit and the reader's place only when it changed which blocks there are
    /// (true), or after every script (false).
    public var layoutAboveOnlyWhenBlocksChange: Bool
    /// Whether opening or closing a fold keeps a following reader at the end (true), or always holds the reader's row and lets where
    /// it lands decide following (false).
    public var foldFollowsEnd: Bool
    /// Whether copied text leaves out a paragraph that reads as nothing (true), or keeps its paragraph break (false).
    public var copySkipsEmptyParagraphs: Bool

    public init(maxLagBytes: Int, layoutAboveOnlyWhenBlocksChange: Bool, foldFollowsEnd: Bool, copySkipsEmptyParagraphs: Bool) {
        self.maxLagBytes = maxLagBytes
        self.layoutAboveOnlyWhenBlocksChange = layoutAboveOnlyWhenBlocksChange
        self.foldFollowsEnd = foldFollowsEnd
        self.copySkipsEmptyParagraphs = copySkipsEmptyParagraphs
    }
}

/// What a reader tells the press about a script or the reveal.
public enum TranscriptReaderReceipt: Sendable {
    case applied(script: UUID)
    case rejected(script: UUID, cause: String)
    case rebase
    case revealed(row: String)

    /// The same receipt as the face link carries it.
    public var face: TranscriptReceipt {
        switch self {
        case .applied(let script): .applied(script: script)
        case .rejected(let script, let cause): .rejected(script: script, cause: cause)
        case .rebase: .rebase
        case .revealed(let row): .revealed(row: row)
        }
    }
}

/// Owns a reader's document. Every change is one edit inside one editing transaction, and after every edit the reader's place is put
/// back: the first visible paragraph at the offset it had, or the end while the reader follows it. A platform's reader subclasses
/// this and overrides the hooks under "Glass": its text view's geometry, its scroll, its receipts and its hosted views.
/// Nothing here reads `.layoutManager`: that silently drops a text view to TextKit 1.
@available(macOS 15, iOS 18, *)
@MainActor
open class TranscriptReaderCore: NSObject {
    /// The pacer reveals glyphs from paragraphs already rendered by the press.
    @MainActor
    public struct Live {
        public let messageID: String
        public var pacer = ChatStreamPacer()
        /// The row's text as streamed so far.
        public var target: String
        public var glyphs: String
        public var cuts: [String: [TranscriptRevealCut]]
        public var revealed = 0
        /// Once the turn stops streaming, the reveal finishes and the reply is the built document's own blocks again.
        public var streaming: Bool
    }

    /// One paragraph the reveal changes: what it reads now and what it read before.
    public struct RevealChange {
        public let position: Int
        public let body: NSAttributedString
        public let hidden: Bool
        public let oldLength: Int
        public let wasHidden: Bool
    }

    /// The reader's place: the first visible paragraph (by block) and how far its top sits below the reading top.
    private struct Place {
        var block: Int
        var id: String
        var offset: CGFloat
    }

    private struct NativeParagraph {
        var body: NSAttributedString
        var separator: NSAttributedString
        var hidden: NSAttributedString
    }

    public let layout: NSTextLayoutManager
    public let content: NSTextContentStorage
    public let storage: NSTextStorage
    public let folds: TranscriptLayoutDelegate
    public let rules: TranscriptReaderRules

    public var readerID = UUID()
    public var appliedScript: UUID?
    public var pendingOpen = true
    /// Only the reader's own navigation (and opening, Latest, a send) decides whether document growth follows the end.
    public var following = true
    public private(set) var shown = TranscriptDocument.empty
    /// Each block's paragraph length without its separator; every block but the last is followed by one "\n".
    public private(set) var lengths: [Int] = []
    private var startsCache: [Int]?
    public private(set) var index: [String: Int] = [:]
    private var native: [String: NativeParagraph] = [:]
    public private(set) var hiddenLive: Set<String> = []
    public private(set) var live: Live?
    private var link: CADisplayLink?

    public init(content: NSTextContentStorage, layout: NSTextLayoutManager, storage: NSTextStorage, folds: TranscriptLayoutDelegate,
                rules: TranscriptReaderRules) {
        self.content = content
        self.layout = layout
        self.storage = storage
        self.folds = folds
        self.rules = rules
        super.init()
    }

    // MARK: Glass

    /// Where the text container's origin sits in the text view.
    open var textOrigin: CGPoint { .zero }
    /// The top of the reading area, in text-view space.
    open var readingTop: CGFloat { 0 }
    /// The reader holds the scroll (a live scroll, a drag or its glide): nothing moves the document under them.
    open var holdsScroll: Bool { false }
    /// Whether the reader's scroll rests at the laid-out end; nil before there is a layout to say.
    open var reachesEnd: Bool? { nil }
    /// Hidden, offscreen and Reduce Motion readers show the current words at once instead of pacing them in.
    open var revealsAtOnce: Bool { true }
    /// The feed this reader's scripts arrive on, and the conversation they are for.
    open var feed: FaceFeed? { nil }
    open var feedSession: String? { nil }
    /// This is still the view's reader, so a feed change reads again.
    open var isCurrentReader: Bool { false }

    /// Runs a change the reader's own edits and scrolls make, so layout it triggers is not taken for the reader moving.
    open func moving(_ change: () -> Void) { change() }
    /// Scrolls the reading area by `shift` points.
    open func shiftScroll(by shift: CGFloat) {}
    /// Seats the document's end at the reading bottom.
    open func landAtEnd() {}
    /// Just before the reader's place is put back after an edit.
    open func willRestorePlace() {}
    /// Opens the document at the end once it has something to show and room to show it.
    open func open() {}
    /// After every edit and scroll the reader's place may have changed.
    open func didMove() {}
    /// Lays out the whole document in order from `fromBlock`, so positions above the viewport are real; the phone does not.
    open func layOutDocument(fromBlock block: Int) {}
    /// Carries a whole-document layout on to its next slice.
    open func continueDocumentLayout() {}
    /// The display link that paces the reveal, on this platform's screen.
    open func displayLink(target: Any, selector: Selector) -> CADisplayLink? { nil }
    /// A block's retained hosted view, as the attachment its paragraph carries.
    open func attachment(blockID: String, ref: TranscriptAttachmentRef, role: String) -> NSTextAttachment {
        TranscriptAttachment(blockID: blockID)
    }
    /// Blocks gone from the document.
    open func forgetAttachments(_ blockIDs: Set<String>) {}
    /// Hosted views go over their laid-out attachment frames, in text-view space.
    open func placeHosted(_ frames: [String: CGRect]) {}
    /// Sends one receipt to the press.
    open func acknowledge(_ receipt: TranscriptReaderReceipt) {}
    /// The press's issue with the script it sent, or nil.
    open func pressIssue(_ issue: String?) {}
    /// A script was accepted, before its receipt goes.
    open func didAcceptScript(_ packet: TranscriptPressEdits) {}
    /// A script and its reveal reached TextKit.
    open func didApplyScript(_ packet: TranscriptPressEdits) {}
    /// A script could not be applied; its rejection goes next.
    open func scriptFailed(issue: String, cause: String) {}
    /// A fold opens or closes over its detail rows.
    open func foldWillToggle(rows: [String], open: Bool) {}
    /// The reveal's changes go into storage this platform's way (`splice`), keeping the reader's place its way.
    open func applyReveal(including previousReveal: [String] = []) {}

    // MARK: Paragraph index

    public func starts() -> [Int] {
        if let startsCache { return startsCache }
        var out: [Int] = []
        out.reserveCapacity(lengths.count)
        var at = 0
        for length in lengths {
            out.append(at)
            at += length + 1
        }
        startsCache = out
        return out
    }

    public func start(_ block: Int) -> Int { starts()[block] }

    public func block(atCharacter character: Int) -> Int? {
        let starts = starts()
        guard !starts.isEmpty, character >= 0 else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func location(at character: Int) -> (any NSTextLocation)? {
        content.location(content.documentRange.location, offsetBy: character)
    }

    public func lastFragmentFrame(ensuringLayout: Bool) -> CGRect? {
        var frame: CGRect?
        let options: NSTextLayoutFragment.EnumerationOptions = ensuringLayout ? [.reverse, .ensuresLayout] : [.reverse]
        _ = layout.enumerateTextLayoutFragments(from: content.documentRange.endLocation, options: options) { fragment in
            frame = fragment.layoutFragmentFrame
            return false
        }
        return frame
    }

    /// The ids of the blocks TextKit's viewport covers.
    public func viewportBlocks() -> Set<String> {
        guard let range = layout.textViewportLayoutController.viewportRange else { return [] }
        let from = content.offset(from: content.documentRange.location, to: range.location)
        let to = content.offset(from: content.documentRange.location, to: range.endLocation)
        guard let first = block(atCharacter: from), let last = block(atCharacter: to),
              shown.blocks.indices.contains(first), shown.blocks.indices.contains(last), first <= last else { return [] }
        return Set(shown.blocks[first...last].map(\.id))
    }

    private func reindex() {
        index = Dictionary(shown.blocks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
    }

    /// Empties the document for a new conversation: the reveal stops, storage and its index clear, every hosted view and open fold goes.
    public func clearDocument() {
        stopLink()
        live = nil
        let gone = Set(shown.blocks.map(\.id))
        content.performEditingTransaction { storage.setAttributedString(NSAttributedString()) }
        if !gone.isEmpty { forgetAttachments(gone) }
        shown = .empty
        native = [:]
        hiddenLive = []
        lengths = []
        startsCache = nil
        index = [:]
        folds.openFolds = []
    }

    // MARK: Place

    private func recordPlace() -> Place? {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return nil }
        let top = readingTop
        let originY = textOrigin.y
        var place: Place?
        _ = layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.maxY + originY > top else { return true }
            let character = self.content.offset(from: self.content.documentRange.location, to: fragment.rangeInElement.location)
            if let block = self.block(atCharacter: character), self.shown.blocks.indices.contains(block) {
                place = Place(block: block, id: self.shown.blocks[block].id, offset: frame.minY + originY - top)
            }
            return false
        }
        return place
    }

    /// Puts the place's paragraph back at its recorded offset. When the edit began above it, the paragraphs between are laid out first,
    /// so the paragraph's position is real and not an estimate.
    private func restore(_ place: Place, editStart: Int, layoutAbove: Bool) {
        moving {
            guard lengths.indices.contains(place.block), let location = location(at: start(place.block)) else { return }
            if layoutAbove, editStart < place.block, let from = self.location(at: start(editStart)),
               let between = NSTextRange(location: from, end: location) {
                layout.ensureLayout(for: between)
            }
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            let now = fragment.layoutFragmentFrame.minY + textOrigin.y - readingTop
            let shift = now - place.offset
            if abs(shift) > 0.01 { shiftScroll(by: shift) }
        }
    }

    /// The place law around one change of `removed` blocks at `editStart` into `inserted` blocks. Following means "followed the end
    /// before this change"; a change that does not `follow` holds the reader's row and lets where it lands decide following; a reader
    /// holding the scroll keeps what is under them.
    public func keepingPlace(editStart: Int, removed: Int, inserted: Int, follows: Bool = true, layoutAbove: Bool = true,
                             _ change: () -> Void) {
        let wasAtEnd = follows && !pendingOpen && following && !holdsScroll
        moving {
            let place = wasAtEnd || pendingOpen ? nil : recordPlace()
            change()
            guard !pendingOpen else { return }
            if wasAtEnd {
                landAtEnd()
            } else if var place {
                willRestorePlace()
                if let position = index[place.id] {
                    place.block = position
                } else if place.block >= editStart + removed {
                    place.block += inserted - removed
                } else if place.block >= editStart {
                    place.block = min(editStart, lengths.count - 1)
                }
                if place.block >= 0 { restore(place, editStart: editStart, layoutAbove: layoutAbove) }
                if !follows, let reached = reachesEnd { following = reached }
            }
        }
        if pendingOpen {
            open()
            return
        }
        didMove()
    }

    // MARK: The one edit

    /// Reads this reader's script from the feed and applies it; a change reads it again while this is still the view's reader.
    public func observeFeed() {
        guard let feed, let session = feedSession else { return }
        let id = readerID
        let packet = withObservationTracking {
            feed.slot(.transcript(session: session)).select("press:" + id.uuidString, as: TranscriptFace.self) { $0?.readers[id] }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.readerID == id, self.isCurrentReader else { return }
                self.observeFeed()
            }
        }
        if let packet { receive(packet) }
    }

    /// The reader consumes an applicable script and acknowledges exactly what reached TextKit.
    public func receive(_ packet: TranscriptPressEdits) {
        guard packet.id != appliedScript else { return }
        guard packet.base == appliedScript else {
            acknowledge(.rebase)
            return
        }
        do {
            var end = 0
            for edit in packet.edits {
                guard edit.start >= end, edit.start <= shown.blocks.count, edit.removed >= 0,
                      edit.removed <= shown.blocks.count - edit.start else {
                    throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "The transcript script has an invalid paragraph range."])
                }
                end = edit.start + edit.removed
            }
            var replacements: [String: NativeParagraph] = [:]
            for paragraph in packet.edits.flatMap(\.inserted) {
                let body = NSMutableAttributedString(attributedString:
                    try NSAttributedString(paragraph.body, including: TranscriptAttributes.self))
                if case .attachment(let ref) = paragraph.block.kind, body.length > 0 {
                    body.addAttribute(.attachment, value: attachment(blockID: paragraph.block.id, ref: ref, role: paragraph.block.role),
                                      range: NSRange(location: 0, length: body.length))
                }
                replacements[paragraph.block.id] = try NativeParagraph(body: body,
                    separator: NSAttributedString(paragraph.separator, including: TranscriptAttributes.self),
                    hidden: NSAttributedString(paragraph.hidden, including: TranscriptAttributes.self))
            }
            let previousReveal = live?.cuts.keys.map { $0 } ?? []
            if let line = packet.live {
                if live?.messageID != line.rowID {
                    live = Live(messageID: line.rowID, target: line.text, glyphs: line.glyphs, cuts: line.cuts, streaming: line.streaming)
                } else if var live {
                    retarget(&live, line)
                    live.cuts = line.cuts
                    live.streaming = line.streaming
                    self.live = live
                }
            } else { live = nil; stopLink() }
            if revealsAtOnce, var live { live.revealed = live.glyphs.utf8.count; self.live = live }
            pressIssue(packet.issue)
            let changed = packet.edits
            if let first = changed.first {
                let single = changed.count == 1
                let layoutAbove = !rules.layoutAboveOnlyWhenBlocksChange || changed.contains { edit in
                    edit.removed != edit.inserted.count
                        || Array(shown.blocks[edit.start..<(edit.start + edit.removed)]) != edit.inserted.map(\.block)
                }
                let gone = Set(changed.flatMap { edit in
                    shown.blocks.dropFirst(edit.start).prefix(edit.removed).map(\.id)
                }).subtracting(changed.flatMap { $0.inserted.map { $0.block.id } })
                let nextNative = native.merging(replacements) { _, next in next }
                let resolved = try changed.map { try resolve($0, paragraphs: nextNative) }
                native = nextNative
                keepingPlace(editStart: first.start, removed: single ? first.removed : 0,
                             inserted: single ? first.inserted.count : 0, layoutAbove: layoutAbove) {
                    content.performEditingTransaction {
                        for edit in resolved.reversed() {
                            storage.replaceCharacters(in: edit.characters, with: edit.replacement)
                            lengths.replaceSubrange(edit.paragraphs, with: edit.bodies.map { $0.1.length })
                            shown.blocks.replaceSubrange(edit.paragraphs, with: edit.bodies.map { $0.0 })
                            for (block, body) in edit.bodies { rememberVisibility(block.id, body) }
                        }
                    }
                    startsCache = nil
                    reindex()
                    layOutDocument(fromBlock: first.start)
                }
                continueDocumentLayout()
                for key in gone { native[key] = nil; hiddenLive.remove(key) }
                forgetAttachments(gone)
            }
            appliedScript = packet.id
            didAcceptScript(packet)
            acknowledge(.applied(script: packet.id))
            applyReveal(including: previousReveal)
            paceLive()
            if pendingOpen { open() }
            placeHostedViews()
            didApplyScript(packet)
        } catch {
            scriptFailed(issue: "Transcript could not be applied: " + error.localizedDescription, cause: error.localizedDescription)
            acknowledge(.rejected(script: packet.id, cause: error.localizedDescription))
        }
    }

    private struct ResolvedEdit {
        var paragraphs: Range<Int>
        var characters: NSRange
        var replacement: NSAttributedString
        var bodies: [(TranscriptBlock, NSAttributedString)]
    }

    /// Resolve every native range before opening TextKit's single transaction.
    private func resolve(_ edit: TranscriptParagraphEdit, paragraphs: [String: NativeParagraph]) throws -> ResolvedEdit {
        let count = shown.blocks.count, at = edit.start, removed = edit.removed
        let replacement = NSMutableAttributedString()
        let from: Int, to: Int
        let inserted = try edit.inserted.map { paragraph -> (TranscriptBlock, NSAttributedString, NSAttributedString) in
            guard let value = paragraphs[paragraph.block.id] else {
                throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "A prepared transcript paragraph is missing."])
            }
            return (paragraph.block, visible(paragraph.block.id, value), value.separator)
        }
        if at + removed < count {
            from = start(at)
            to = start(at + removed)
            for (_, body, separator) in inserted { replacement.append(body); replacement.append(separator) }
        } else if inserted.isEmpty {
            from = at > 0 ? start(at) - 1 : 0
            to = storage.length
        } else {
            from = removed > 0 ? start(at) : storage.length
            to = storage.length
            if removed == 0, let last = shown.blocks.last {
                guard let separator = paragraphs[last.id]?.separator else {
                    throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "The transcript separator is missing."])
                }
                replacement.append(separator)
            }
            for (offset, value) in inserted.enumerated() {
                if offset > 0 { replacement.append(inserted[offset - 1].2) }
                replacement.append(value.1)
            }
        }
        return ResolvedEdit(paragraphs: at..<(at + removed), characters: NSRange(location: from, length: to - from),
                            replacement: replacement, bodies: inserted.map { ($0.0, $0.1) })
    }

    private func rememberVisibility(_ key: String, _ body: NSAttributedString) {
        if body.length > 0, body.attribute(TranscriptKey.liveHidden, at: 0, effectiveRange: nil) as? Bool == true {
            hiddenLive.insert(key)
        } else { hiddenLive.remove(key) }
    }

    /// Nil is the press's unrevealed paragraph, whose hidden placeholder is not a glyph.
    private func visibleLength(_ blockID: String, _ paragraph: NativeParagraph) -> Int? {
        guard let live, let cuts = live.cuts[blockID] else { return paragraph.body.length }
        if live.revealed >= live.glyphs.utf8.count { return paragraph.body.length }
        var low = 0
        var high = cuts.count
        while low < high {
            let mid = low + (high - low) / 2
            if cuts[mid].utf8End <= live.revealed { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        return min(paragraph.body.length, cuts[low - 1].utf16End)
    }

    private func visible(_ blockID: String, _ paragraph: NativeParagraph) -> NSAttributedString {
        guard let length = visibleLength(blockID, paragraph) else { return paragraph.hidden }
        if length == paragraph.body.length { return paragraph.body }
        return paragraph.body.attributedSubstring(from: NSRange(location: 0, length: length))
    }

    /// Hosted views sit over their attachment's laid-out frame in the visible range; the document keeps only their room.
    /// Runs after every layout of the text view and every edit, so a view is wherever its paragraph is laid out.
    public func placeHostedViews() {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let origin = textOrigin
        var frames: [String: CGRect] = [:]
        _ = layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
                  let attachment = paragraph.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? TranscriptAttachment
            else { return true }
            let local = fragment.frameForTextAttachment(at: fragment.rangeInElement.location)
            guard local.width > 0, local.height > 0 else { return true }
            let frame = fragment.layoutFragmentFrame
            frames[attachment.blockID] = local.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
            return true
        }
        placeHosted(frames)
    }

    // MARK: The live reply

    /// Reset the pacer when the target stops extending.
    private func retarget(_ live: inout Live, _ line: TranscriptLiveLine) {
        if !line.glyphs.hasPrefix(live.glyphs) {
            live.pacer = ChatStreamPacer()
            live.revealed = line.glyphs.utf8.count
        }
        live.target = line.text
        live.glyphs = line.glyphs
    }

    private func paceLive() {
        guard live != nil else { return }
        if revealsAtOnce {
            step(now: nil)
        } else if link == nil, let link = displayLink(target: self, selector: #selector(tick(_:))) {
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        step(now: revealsAtOnce ? nil : CACurrentMediaTime())
    }

    /// One frame: advance the pacer and splice what it revealed over the reply's blocks. Caught up, the link rests until the next chunk;
    /// caught up after the turn ended, the reply is the built document's own blocks and the reveal is over.
    private func step(now: CFTimeInterval?) {
        guard var live else {
            stopLink()
            return
        }
        let total = live.glyphs.utf8.count
        if let now {
            live.revealed = live.pacer.advance(live.glyphs, now: now, maxLagBytes: rules.maxLagBytes)
        } else {
            live.revealed = total
        }
        let caughtUp = live.revealed >= total
        self.live = live
        applyReveal()
        if caughtUp && !live.streaming {
            self.live = nil
            acknowledge(.revealed(row: live.messageID))
        }
        if caughtUp { stopLink() }
    }

    public func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// The paragraphs the reveal changes, in document order: the live line's, those leaving it (they regain their complete prepared
    /// body, a partly revealed one included) and every hidden one.
    public func revealChanges(including previousReveal: [String]) -> [RevealChange] {
        var changes: [RevealChange] = []
        for key in Set(live?.cuts.keys.map { $0 } ?? []).union(previousReveal).union(hiddenLive) {
            guard let position = index[key], lengths.indices.contains(position), shown.blocks.indices.contains(position),
                  let paragraph = native[key] else { continue }
            let hidden = visibleLength(key, paragraph) == nil
            let body = visible(key, paragraph)
            let wasHidden = hiddenLive.contains(key)
            let oldLength = lengths[position]
            guard body.length != oldLength || wasHidden != hidden else { continue }
            changes.append(RevealChange(position: position, body: body, hidden: hidden, oldLength: oldLength, wasHidden: wasHidden))
        }
        changes.sort { $0.position < $1.position }
        return changes
    }

    /// Writes the reveal's changes in one editing transaction. A growing visible paragraph only appends its new glyphs. `coalesced`
    /// is one storage splice across the changed paragraphs, keeping the text between; otherwise each paragraph is its own splice.
    public func splice(_ changes: [RevealChange], coalesced: Bool) {
        guard !changes.isEmpty else { return }
        let edits = changes.map { change -> (change: RevealChange, characters: NSRange, replacement: NSAttributedString) in
            let prefix = !change.wasHidden && !change.hidden && change.body.length > change.oldLength ? change.oldLength : 0
            return (change, NSRange(location: start(change.position) + prefix, length: change.oldLength - prefix),
                    change.body.attributedSubstring(from: NSRange(location: prefix, length: change.body.length - prefix)))
        }
        content.performEditingTransaction {
            if coalesced {
                let replacement = NSMutableAttributedString()
                var cursor = edits[0].characters.location
                for edit in edits {
                    if cursor < edit.characters.location {
                        replacement.append(storage.attributedSubstring(from: NSRange(location: cursor, length: edit.characters.location - cursor)))
                    }
                    replacement.append(edit.replacement)
                    cursor = NSMaxRange(edit.characters)
                }
                let from = edits[0].characters.location
                storage.replaceCharacters(in: NSRange(location: from, length: NSMaxRange(edits[edits.count - 1].characters) - from),
                                          with: replacement)
            } else {
                for edit in edits.reversed() { storage.replaceCharacters(in: edit.characters, with: edit.replacement) }
            }
            for edit in edits {
                lengths[edit.change.position] = edit.change.body.length
                let key = shown.blocks[edit.change.position].id
                if edit.change.hidden { hiddenLive.insert(key) } else { hiddenLive.remove(key) }
            }
        }
        startsCache = nil
    }

    // MARK: Folds and hosted views

    /// A toggle is an attribute edit over the run's range, so TextKit enumerates it again and asks `shouldEnumerate` afresh.
    public func setFold(_ group: String, open: Bool) {
        let members = shown.blocks.indices.filter { position in
            let block = shown.blocks[position]
            if case .foldHeadline = block.kind, block.messageID == group { return true }
            return block.foldGroup == group
        }
        guard let first = members.first, let last = members.last else { return }
        let range = NSRange(location: start(first), length: start(last) + lengths[last] - start(first))
        let rows = members.compactMap { position -> String? in
            guard case .foldDetail = shown.blocks[position].kind else { return nil }
            return shown.blocks[position].messageID
        }
        foldWillToggle(rows: rows, open: open)
        keepingPlace(editStart: first, removed: 0, inserted: 0, follows: rules.foldFollowsEnd) {
            if open { folds.openFolds.insert(group) } else { folds.openFolds.remove(group) }
            content.performEditingTransaction {
                storage.beginEditing()
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
                storage.endEditing()
            }
            layOutDocument(fromBlock: first)
        }
        continueDocumentLayout()
    }

    /// A hosted view changed height: lay its paragraph out again where it is.
    public func relayoutAttachment(_ blockID: String) {
        guard let position = index[blockID], let from = location(at: start(position)),
              let to = location(at: start(position) + lengths[position]), let range = NSTextRange(location: from, end: to) else { return }
        keepingPlace(editStart: position, removed: 0, inserted: 0) {
            layout.invalidateLayout(for: range)
            layOutDocument(fromBlock: position)
            layout.textViewportLayoutController.layoutViewport()
        }
        continueDocumentLayout()
        placeHostedViews()
    }

    // MARK: Copy

    /// A block's markdown source, cut at its visible glyphs while it is live.
    private func source(for block: TranscriptBlock, visibleLength: Int) -> String {
        guard let live, let cuts = live.cuts[block.id], let last = cuts.last,
              visibleLength < last.utf16End else { return block.source }
        guard let cut = cuts.last(where: { $0.utf16End <= visibleLength }) else { return "" }
        // A cut's markdown end falls on a character boundary of the source.
        let utf8 = block.source.utf8
        return String(block.source[..<utf8.index(utf8.startIndex, offsetBy: min(max(0, cut.markdownEnd), utf8.count))])
    }

    /// Paragraph by paragraph: a wholly selected paragraph gives its markdown source (with `markdown`), a partly selected one its
    /// selected text. Live sources stop at their visible glyphs; closed folds and unrevealed paragraphs are skipped, as they are on
    /// screen; line separators read as newlines and attachments as their source.
    public func text(for ranges: [NSRange], markdown: Bool) -> String? {
        let string = storage.string as NSString
        let separators: Set<unichar> = [0x0A, 0x0D, 0x2029]
        var parts: [String] = []
        var lastMessage: String?
        for range in ranges where range.length > 0 {
            var location = range.location
            let end = min(NSMaxRange(range), string.length)
            while location < end {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(paragraph)
                var body = paragraph
                while body.length > 0, separators.contains(string.character(at: NSMaxRange(body) - 1)) { body.length -= 1 }
                let selected = NSIntersectionRange(body, range)
                guard selected.length > 0,
                      let id = storage.attribute(TranscriptKey.blockID, at: paragraph.location, effectiveRange: nil) as? String,
                      let position = index[id] else { continue }
                if hiddenLive.contains(id) { continue }
                let block = shown.blocks[position]
                if let group = block.foldGroup, !folds.openFolds.contains(group) { continue }
                var isAttachment = false
                if case .attachment = block.kind { isAttachment = true }
                let whole = selected.length == body.length
                let text = isAttachment || (markdown && whole) ? source(for: block, visibleLength: body.length) : string.substring(with: selected)
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                if rules.copySkipsEmptyParagraphs, text.isEmpty { continue }
                let tight = block.messageID == lastMessage && (block.lead == .listItem || block.lead == .detail)
                parts.append((parts.isEmpty ? "" : (tight ? "\n" : "\n\n")) + text)
                lastMessage = block.messageID
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}
