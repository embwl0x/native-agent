import NativeAgentShared
import Observation
import QuartzCore
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptController.swift` | Applies Shared press scripts; phone viewport, reader place and prepared-glyph reveal |

/// Owns the text view's document. Every change is one edit inside one editing transaction, and after every edit the reader's place
/// is put back: the first visible paragraph at the offset it had, or the end when the reader follows it.
/// Nothing here reads `.layoutManager`: that silently drops the view to TextKit 1.
@MainActor
final class MobileTranscriptController: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// The reader's place: the first visible paragraph (by block) and how far its top sits below the reading top.
    struct Place {
        var block: Int
        var id: String
        var offset: CGFloat
    }

    /// The pacer reveals glyphs from paragraphs already rendered by the press.
    @MainActor
    struct Live {
        let messageID: String
        var pacer = ChatStreamPacer()
        var target: String
        var glyphs: String
        var cuts: [String: [TranscriptRevealCut]]
        var revealed = 0
        /// Once the turn stops streaming, the reveal finishes and the reply is the built document's own blocks again.
        var streaming: Bool
    }

    /// The phone's ~1 s batches run up to ~1,200 characters, so the reveal jumps only past four bytes a character of that.
    static let maxLagBytes = 4_800

    let textView: MobileTranscriptTextView
    let layout: NSTextLayoutManager
    let content: NSTextContentStorage
    let storage: NSTextStorage
    let folds = TranscriptLayoutDelegate()
    let attachments = TranscriptAttachments()
    private weak var handle: MobileTranscriptHandle?
    private var actions = MobileTranscriptActions()
    private var environment: EnvironmentValues?

    private var sessionKey: String?
    private var shown = TranscriptDocument.empty
    /// Each block's paragraph length without its separator; every block but the last is followed by one "\n".
    private var lengths: [Int] = []
    private var startsCache: [Int]?
    private var index: [String: Int] = [:]
    private struct NativeParagraph {
        var body: NSAttributedString
        var separator: NSAttributedString
        var hidden: NSAttributedString
    }
    private var native: [String: NativeParagraph] = [:]
    private var hiddenLive: Set<String> = []
    private let owner = MobileTranscriptPress.shared
    private var readerID = UUID()
    private var appliedScript: UUID?
    private var paintedScript: UUID?
    private var mounted = true
    private struct Pending: Equatable {
        var input: MobileTranscriptInput
        var width: Double
        var scale: Double
        var category: String
    }
    private var pendingInput: Pending?
    private var requestedInput: Pending?
    private var inputTask: Task<Void, Never>?
    private var messages: [String: ChatMessage] = [:]
    private var lastAssistantID: String?
    private var data = TranscriptAttachmentData(messages: [:], asked: [:], inbox: [:])

    private var live: Live?
    private var link: CADisplayLink?

    /// The column the text lays out in; zero until the host gives a width.
    private var containerWidth: CGFloat = 0
    private var reduceMotion = false
    private var pendingOpen = true
    /// Reader scroll, Latest, sending and opening own following; estimated document height cannot decide it.
    private var following = true
    private var viewportSize = CGSize.zero
    private var scrollingToEnd = false
    private var openingStarted = CACurrentMediaTime()
    private var firstPaintOwed = true
    private let log = ModuleLog(category: "MobileTranscriptDocument")

    override init() {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        layout.textContainer = container
        let text = MobileTranscriptTextView(frame: .zero, textContainer: container)
        textView = text
        self.layout = layout
        self.content = content
        storage = text.textStorage
        super.init()
        configureView()
        attachments.heightChanged = { [weak self] blockID in self?.relayoutAttachment(blockID) }
    }

    private func configureView() {
        textView.controller = self
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.backgroundColor = .clear
        // Links colour themselves where they are drawn (an action reads as a control, a markdown link as underlined words).
        textView.linkTextAttributes = [:]
        textView.adjustsFontForContentSizeCategory = false
        textView.alwaysBounceVertical = true
        textView.showsHorizontalScrollIndicator = false
        textView.keyboardDismissMode = .interactive
        // The host hands over the composer's room; nothing else insets the document.
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: TranscriptMetrics.documentInset, left: 0, bottom: TranscriptMetrics.documentInset,
                                                   right: 0)
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.lineFragmentPadding = 0
        content.delegate = folds
        layout.delegate = folds

        // Hosted controls retain their own touch handling.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        textView.addGestureRecognizer(tap)
    }

    /// The document leaves the screen: the reveal stops, the hosted views leave their parent controller, and the thread reads "at
    /// the end" so no Latest button outlives it.
    func dismantle() {
        mounted = false
        let task = inputTask
        task?.cancel()
        pendingInput = nil
        let id = readerID, press = owner.press
        Task { await task?.value; await press.remove(reader: id) }
        stopLink()
        attachments.forget(Set(shown.blocks.map(\.id)))
        if handle?.controller === self {
            handle?.controller = nil
            handle?.isAtEnd = true
            handle?.isPreparing = false
        }
    }

    // MARK: Input

    func update(_ input: MobileTranscriptInput, width: CGFloat, bottomInset: CGFloat, environment: EnvironmentValues,
                actions: MobileTranscriptActions, handle: MobileTranscriptHandle) {
        self.actions = actions
        self.environment = environment
        reduceMotion = environment.accessibilityReduceMotion
        if self.handle !== handle {
            if self.handle?.controller === self { self.handle?.controller = nil }
            self.handle = handle
            handle.controller = self
        }
        if input.sessionKey != sessionKey { resetSession(input.sessionKey) }

        setWidth(width)
        attachments.update(data, environment: environment, actions: actions, columnWidth: containerWidth)
        let category = UIContentSizeCategory(environment.dynamicTypeSize).rawValue
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(rawValue: category))
        let scale = Double(UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize)
        let next = Pending(input: input, width: Double(containerWidth), scale: scale, category: category)
        if next != requestedInput {
            requestedInput = next
            pendingInput = next
            submitInput()
        }
        setBottomInset(bottomInset)
        if pendingOpen { open() }
    }

    private func submitInput() {
        guard inputTask == nil, pendingInput != nil, containerWidth > 0, textView.bounds.height > 0 else { return }
        let id = readerID, press = owner.press
        inputTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.mounted, self.readerID == id, let next = self.pendingInput {
                self.pendingInput = nil
                let height = self.textView.bounds.height
                guard let count = Int(exactly: ceil(height / max(1, next.scale))) else {
                    self.handle?.issue = "The transcript viewport has an invalid height. Resize the conversation."
                    break
                }
                let prepared = await MobileTranscriptPreparation.prepare(next.input, width: next.width, scale: next.scale,
                    category: next.category, viewport: self.viewportBlocks(), openingParagraphs: max(1, count))
                guard !Task.isCancelled, self.mounted, self.readerID == id else { break }
                self.messages = prepared.messages
                self.lastAssistantID = prepared.lastAssistantID
                self.data = prepared.attachments
                if let environment = self.environment {
                    self.attachments.update(self.data, environment: environment, actions: self.actions, columnWidth: self.containerWidth)
                }
                self.log("press.submit reader=%@ groups=%ld width=%.0f", id.uuidString, prepared.input.groups.count, next.width)
                await press.update(reader: id, input: prepared.input)
            }
            guard let self, self.readerID == id else { return }
            self.inputTask = nil
        }
    }

    private func resetSession(_ key: String) {
        let task = inputTask
        task?.cancel()
        let old = readerID, press = owner.press
        Task { await task?.value; await press.remove(reader: old) }
        inputTask = nil
        pendingInput = nil
        requestedInput = nil
        readerID = UUID()
        appliedScript = nil
        paintedScript = nil
        sessionKey = key
        openingStarted = CACurrentMediaTime()
        firstPaintOwed = true
        stopLink()
        live = nil
        let gone = Set(shown.blocks.map(\.id))
        content.performEditingTransaction { storage.setAttributedString(NSAttributedString()) }
        if !gone.isEmpty { attachments.forget(gone) }
        shown = .empty
        lengths = []
        startsCache = nil
        index = [:]
        native = [:]
        hiddenLive = []
        folds.openFolds = []
        pendingOpen = true
        following = true
        handle?.issue = nil
        handle?.isPreparing = true
        observeFeed()
    }

    private func observeFeed() {
        guard let sessionKey else { return }
        let id = readerID
        let packet = withObservationTracking {
            owner.face.slot(.transcript(session: sessionKey)).select("press:" + id.uuidString, as: TranscriptFace.self) { $0?.readers[id] }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.mounted, self.readerID == id else { return }
                self.observeFeed()
            }
        }
        if let packet { receive(packet) }
    }

    private func viewportBlocks() -> Set<String> {
        guard let range = layout.textViewportLayoutController.viewportRange else { return [] }
        let from = content.offset(from: content.documentRange.location, to: range.location)
        let to = content.offset(from: content.documentRange.location, to: range.endLocation)
        guard let first = block(atCharacter: from), let last = block(atCharacter: to),
              shown.blocks.indices.contains(first), shown.blocks.indices.contains(last) else { return [] }
        return Set(shown.blocks[first...last].map(\.id))
    }

    /// The column stays inside the page inset, centred in the room the host gives it.
    private func setWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let column = max(1, min(TranscriptMetrics.column, width - 2 * TranscriptMetrics.pageInset))
        let side = floor((width - column) / 2)
        let inset = UIEdgeInsets(top: TranscriptMetrics.documentInset, left: side, bottom: TranscriptMetrics.documentInset, right: side)
        guard column != containerWidth || textView.textContainerInset != inset else { return }
        keepingPlace(editStart: lengths.count, removed: 0, inserted: 0, layoutAbove: false) {
            textView.textContainerInset = inset
            textView.textContainer.size = CGSize(width: column, height: .greatestFiniteMagnitude)
        }
        containerWidth = column
    }

    // MARK: Geometry

    private var readingTop: CGFloat { textView.contentOffset.y + textView.contentInset.top }
    private var readingBottom: CGFloat { textView.contentOffset.y + textView.bounds.height - textView.contentInset.bottom }
    private var maxOffsetY: CGFloat {
        max(-textView.contentInset.top, textView.contentSize.height + textView.contentInset.bottom - textView.bounds.height)
    }
    /// The reader holds the scroll: a drag or its glide is under way, and nothing moves the document under the finger.
    private var readerHolds: Bool { textView.isDragging || textView.isDecelerating }
    /// The laid-out end is within the reading area: the reader's scroll came to rest at the end.
    private var reachesEnd: Bool? {
        guard let last = lastFragmentFrame(ensuringLayout: false) else { return shown.blocks.isEmpty ? true : nil }
        return documentEnd(last) - readingBottom <= 1
    }

    private func scroll(toOffsetY y: CGFloat) {
        let clamped = min(max(y, -textView.contentInset.top), maxOffsetY)
        guard textView.contentOffset.y != clamped else { return }
        textView.contentOffset = CGPoint(x: textView.contentOffset.x, y: clamped)
    }

    private func starts() -> [Int] {
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

    private func start(_ block: Int) -> Int { starts()[block] }

    private func block(atCharacter character: Int) -> Int? {
        let starts = starts()
        guard !starts.isEmpty, character >= 0 else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func location(at character: Int) -> (any NSTextLocation)? {
        content.location(content.documentRange.location, offsetBy: character)
    }

    private func lastFragmentFrame(ensuringLayout: Bool) -> CGRect? {
        var frame: CGRect?
        let options: NSTextLayoutFragment.EnumerationOptions = ensuringLayout ? [.reverse, .ensuresLayout] : [.reverse]
        _ = layout.enumerateTextLayoutFragments(from: content.documentRange.endLocation, options: options) { fragment in
            frame = fragment.layoutFragmentFrame
            return false
        }
        return frame
    }

    private func documentEnd(_ last: CGRect) -> CGFloat {
        last.maxY + textView.textContainerInset.top + textView.textContainerInset.bottom
    }

    /// Positive: the document's end is below the reading bottom. Negative: blank room past the end.
    private func endResidual() -> CGFloat {
        guard let last = lastFragmentFrame(ensuringLayout: false) else { return 0 }
        return documentEnd(last) - readingBottom
    }

    /// Lay out the end before scrolling; close any residual after viewport layout.
    private func scrollToEnd() {
        guard !scrollingToEnd, let last = lastFragmentFrame(ensuringLayout: true) else { return }
        scrollingToEnd = true
        defer { scrollingToEnd = false }
        let needed = documentEnd(last)
        if textView.contentSize.height < needed { textView.contentSize = CGSize(width: textView.contentSize.width, height: needed) }
        scroll(toOffsetY: maxOffsetY)
        layout.textViewportLayoutController.layoutViewport()
        let residual = endResidual()
        if abs(residual) > 0.5 {
            scroll(toOffsetY: textView.contentOffset.y + residual)
            layout.textViewportLayoutController.layoutViewport()
        }
    }

    private func recordPlace() -> Place? {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return nil }
        let top = readingTop
        let originY = textView.textContainerInset.top
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
        guard lengths.indices.contains(place.block), let location = location(at: start(place.block)) else { return }
        if layoutAbove, editStart < place.block, let from = self.location(at: start(editStart)),
           let between = NSTextRange(location: from, end: location) {
            layout.ensureLayout(for: between)
        }
        guard let fragment = layout.textLayoutFragment(for: location) else { return }
        let now = fragment.layoutFragmentFrame.minY + textView.textContainerInset.top - readingTop
        let shift = now - place.offset
        if abs(shift) > 0.01 { scroll(toOffsetY: textView.contentOffset.y + shift) }
    }

    /// The place law around one change of `removed` blocks at `editStart` into `inserted` blocks. Following means "followed the end
    /// before this change"; a fold the reader opens never follows, it holds the row; a reader holding the scroll keeps what is under
    /// the finger.
    private func keepingPlace(editStart: Int, removed: Int, inserted: Int, follows: Bool = true, layoutAbove: Bool = true,
                              _ change: () -> Void) {
        let wasAtEnd = follows && !pendingOpen && following && !readerHolds
        let place = wasAtEnd || pendingOpen ? nil : recordPlace()
        change()
        if pendingOpen {
            open()
            return
        }
        if wasAtEnd {
            scrollToEnd()
        } else if var place {
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
        didMove()
    }

    /// Opening lands at the end once there is something to show and a viewport to show it in.
    private func open() {
        guard pendingOpen, !shown.blocks.isEmpty, textView.bounds.height > 0, containerWidth > 0 else { return }
        pendingOpen = false
        scrollToEnd()
        following = true
        didMove()
        placeHostedViews()
    }

    /// After every layout pass of the text view (scrolls included): open when the viewport first has a size, keep a following reader at
    /// the end when the viewport resizes, and put hosted views over their paragraphs.
    func didLayout() {
        submitInput()
        if pendingOpen { open() }
        let size = textView.bounds.size
        if size != viewportSize {
            viewportSize = size
            if following, !pendingOpen, !readerHolds { scrollToEnd() }
            didMove()
        }
        placeHostedViews()
    }

    /// Only an actual draw releases this reader's older history from the press.
    func didDraw() {
        guard mounted, !pendingOpen, let script = appliedScript, paintedScript != script else { return }
        paintedScript = script
        if firstPaintOwed {
            firstPaintOwed = false
            log("first.paint reader=%@ script=%@ blocks=%ld elapsed_ms=%.1f", readerID.uuidString, script.uuidString,
                shown.blocks.count, (CACurrentMediaTime() - openingStarted) * 1_000)
        }
        let id = readerID, press = owner.press
        Task { await press.painted(reader: id, script: script) }
    }

    /// The document's height changed on a later layout pass (a hosted view measured, estimates replaced by real lines): a reader
    /// following the end stays at the end.
    func documentResized() {
        guard following, !pendingOpen, !scrollingToEnd, !readerHolds, reachesEnd != true else { return }
        scrollToEnd()
        placeHostedViews()
        didMove()
    }

    private func didMove() {
        if let handle, handle.isAtEnd != following { handle.isAtEnd = following }
    }

    // MARK: The reader's scroll

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { readerRested() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        readerRested()
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        readerRested()
    }

    /// The reader's own scroll came to rest: they follow the end exactly when it rests on it.
    private func readerRested() {
        guard !pendingOpen, let reached = reachesEnd else { return }
        following = reached
        didMove()
    }

    // MARK: The one edit

    /// The face applies an acknowledged press script in one TextKit transaction.
    private func receive(_ packet: TranscriptPressEdits) {
        guard packet.id != appliedScript else { return }
        let id = readerID, press = owner.press
        guard packet.base == appliedScript else {
            Task { await press.rebase(reader: id) }
            return
        }
        do {
            var end = 0
            for edit in packet.edits {
                guard edit.start >= end, edit.start <= shown.blocks.count, edit.removed >= 0,
                      edit.removed <= shown.blocks.count - edit.start else {
                    throw CocoaError(.coderReadCorrupt,
                        userInfo: [NSLocalizedDescriptionKey: "The transcript script has an invalid paragraph range."])
                }
                end = edit.start + edit.removed
            }
            var replacements: [String: NativeParagraph] = [:]
            for paragraph in packet.edits.flatMap(\.inserted) {
                let body = NSMutableAttributedString(attributedString:
                    try NSAttributedString(paragraph.body, including: TranscriptAttributes.self))
                if case .attachment(let ref) = paragraph.block.kind, body.length > 0 {
                    body.addAttribute(.attachment, value: attachments.attachment(blockID: paragraph.block.id, ref: ref),
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
            handle?.issue = packet.issue
            let changed = packet.edits
            if let first = changed.first {
                let single = changed.count == 1
                let gone = Set(changed.flatMap { edit in
                    shown.blocks.dropFirst(edit.start).prefix(edit.removed).map(\.id)
                }).subtracting(changed.flatMap { $0.inserted.map { $0.block.id } })
                let nextNative = native.merging(replacements) { _, next in next }
                let resolved = try changed.map { try resolve($0, paragraphs: nextNative) }
                native = nextNative
                keepingPlace(editStart: first.start, removed: single ? first.removed : 0,
                             inserted: single ? first.inserted.count : 0) {
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
                }
                for key in gone { native[key] = nil; hiddenLive.remove(key) }
                attachments.forget(gone)
            }
            appliedScript = packet.id
            handle?.isPreparing = false
            log("press.apply reader=%@ script=%@ edits=%ld blocks=%ld", id.uuidString, packet.id.uuidString,
                changed.count, shown.blocks.count)
            Task { await press.applied(reader: id, script: packet.id) }
            applyReveal(including: previousReveal)
            paceLive()
            if pendingOpen { open() }
            placeHostedViews()
            textView.setNeedsDisplay()
        } catch {
            handle?.issue = "Transcript could not be applied: " + error.localizedDescription
            handle?.isPreparing = false
            log("press.rejected reader=%@ cause=%@", id.uuidString, error.localizedDescription, level: .error)
            Task { await press.rejected(reader: id, script: packet.id) }
        }
    }

    private struct ResolvedEdit {
        var paragraphs: Range<Int>
        var characters: NSRange
        var replacement: NSAttributedString
        var bodies: [(TranscriptBlock, NSAttributedString)]
    }

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

    private func visible(_ blockID: String, _ paragraph: NativeParagraph) -> NSAttributedString {
        guard let live, let cuts = live.cuts[blockID] else { return paragraph.body }
        if live.revealed >= live.glyphs.utf8.count { return paragraph.body }
        var low = 0, high = cuts.count
        while low < high {
            let mid = low + (high - low) / 2
            if cuts[mid].utf8End <= live.revealed { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return paragraph.hidden }
        let length = min(paragraph.body.length, cuts[low - 1].utf16End)
        return paragraph.body.attributedSubstring(from: NSRange(location: 0, length: length))
    }

    private func reindex() {
        index = Dictionary(shown.blocks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
    }

    /// TextKit places the existing attachment hosts over the visible attachment paragraphs.
    func placeHostedViews() {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let inset = textView.textContainerInset
        var frames: [String: CGRect] = [:]
        _ = layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
                  let attachment = paragraph.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? TranscriptAttachment
            else { return true }
            let local = fragment.frameForTextAttachment(at: fragment.rangeInElement.location)
            guard local.width > 0, local.height > 0 else { return true }
            let frame = fragment.layoutFragmentFrame
            frames[attachment.blockID] = local.offsetBy(dx: frame.minX + inset.left, dy: frame.minY + inset.top)
            return true
        }
        attachments.place(frames, in: textView)
    }

    // MARK: Insets

    /// The composer's room (and the keyboard's, while it shows) is the bottom inset; the text scrolls under the glass and fades there.
    private func setBottomInset(_ bottom: CGFloat) {
        guard textView.contentInset.bottom != bottom else { return }
        keepingPlace(editStart: lengths.count, removed: 0, inserted: 0, layoutAbove: false) {
            textView.contentInset.bottom = bottom
            textView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    // MARK: The live reply

    private func retarget(_ live: inout Live, _ line: TranscriptLiveLine) {
        if !line.glyphs.hasPrefix(live.glyphs) {
            live.pacer = ChatStreamPacer()
            live.revealed = line.glyphs.utf8.count
        }
        live.target = line.text
        live.glyphs = line.glyphs
    }

    /// Reduce Motion and a view off screen show the current words at once; otherwise the display link paces them in.
    private var revealsAtOnce: Bool { reduceMotion || textView.window == nil }

    private func paceLive() {
        guard live != nil else { return }
        if revealsAtOnce {
            step(now: nil)
        } else if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        step(now: revealsAtOnce ? nil : CACurrentMediaTime())
    }

    /// A frame slices prepared glyphs; the press owns Markdown and block building.
    private func step(now: CFTimeInterval?) {
        guard var live else { stopLink(); return }
        let total = live.glyphs.utf8.count
        if let now {
            live.revealed = live.pacer.advance(live.glyphs, now: now, maxLagBytes: Self.maxLagBytes)
        } else { live.revealed = total }
        let caughtUp = live.revealed >= total
        self.live = live
        applyReveal()
        if caughtUp && !live.streaming {
            self.live = nil
            let id = readerID, row = live.messageID, press = owner.press
            Task { await press.revealed(reader: id, rowID: row) }
        }
        if caughtUp { stopLink() }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func applyReveal(including previousReveal: [String] = []) {
        var edits: [(Int, NSAttributedString)] = []
        // Paragraphs leaving the live line regain their complete prepared body, including a partly revealed paragraph.
        for key in Set(live?.cuts.keys.map { $0 } ?? []).union(previousReveal).union(hiddenLive) {
            guard let position = index[key], let paragraph = native[key] else { continue }
            let body = visible(key, paragraph)
            let hidden = body.length > 0 && body.attribute(TranscriptKey.liveHidden, at: 0, effectiveRange: nil) as? Bool == true
            if body.length != lengths[position] || hiddenLive.contains(key) != hidden { edits.append((position, body)) }
        }
        edits.sort { $0.0 < $1.0 }
        guard let first = edits.first else { return }
        keepingPlace(editStart: first.0, removed: 0, inserted: 0, layoutAbove: false) {
            content.performEditingTransaction {
                for (position, body) in edits.reversed() {
                    let key = shown.blocks[position].id
                    let oldLength = lengths[position]
                    if !hiddenLive.contains(key), body.length > oldLength {
                        let tail = body.attributedSubstring(from: NSRange(location: oldLength, length: body.length - oldLength))
                        storage.replaceCharacters(in: NSRange(location: start(position) + oldLength, length: 0), with: tail)
                    } else {
                        storage.replaceCharacters(in: NSRange(location: start(position), length: oldLength), with: body)
                    }
                    lengths[position] = body.length
                    rememberVisibility(key, body)
                }
            }
            startsCache = nil
        }
    }

    // MARK: Folds and action links

    /// Action links dispatch transcript controls; other links open through the system.
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, let action = TranscriptLink(url) else { return defaultAction }
        return UIAction { [weak self] _ in self?.perform(action) }
    }

    /// An action link has no link preview or menu of its own.
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        guard case .link(let url) = textItem.content, TranscriptLink(url) != nil else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
        return nil
    }

    private func perform(_ action: TranscriptLink) {
        switch action {
        case .fold(let group): setFold(group, open: !folds.openFolds.contains(group))
        case .olderHistory: actions.loadOlder()
        case .sendNow(let id): actions.sendNow(id)
        case .wholeMessage(let id): actions.loadWholeMessage(id)
        case .retrySend(let id): actions.retrySend(id)
        }
    }

    /// A toggle is an attribute edit over the run's range, so TextKit enumerates it again and asks `shouldEnumerate` afresh.
    private func setFold(_ group: String, open: Bool) {
        let members = shown.blocks.indices.filter { position in
            let block = shown.blocks[position]
            if case .foldHeadline = block.kind, block.messageID == group { return true }
            return block.foldGroup == group
        }
        guard let first = members.first, let last = members.last else { return }
        let range = NSRange(location: start(first), length: start(last) + lengths[last] - start(first))
        keepingPlace(editStart: first, removed: 0, inserted: 0, follows: false) {
            if open { folds.openFolds.insert(group) } else { folds.openFolds.remove(group) }
            content.performEditingTransaction {
                storage.beginEditing()
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
                storage.endEditing()
            }
        }
    }

    /// A hosted view changed height: lay its paragraph out again where it is.
    private func relayoutAttachment(_ blockID: String) {
        guard let position = index[blockID], let from = location(at: start(position)),
              let to = location(at: start(position) + lengths[position]), let range = NSTextRange(location: from, end: to) else { return }
        keepingPlace(editStart: position, removed: 0, inserted: 0) {
            layout.invalidateLayout(for: range)
            layout.textViewportLayoutController.layoutViewport()
        }
        placeHostedViews()
    }

    // MARK: Requests from the host

    /// Back to the end, following from there: Latest, a send, the keyboard rising.
    func goToLatest() {
        guard !pendingOpen else { return }
        following = true
        scrollToEnd()
        didMove()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !attachments.hosts(touch.view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: The menu

    /// The message a block's menu acts on: the person's or the agent's words, never a fold, an action line or a card.
    private func actionable(_ block: TranscriptBlock) -> ChatMessage? {
        switch block.kind {
        case .foldHeadline, .foldDetail, .gap, .attachment: return nil
        default: break
        }
        guard block.role != "system" else { return nil }
        return message(block.messageID)
    }

    /// The row as it reads now: a streaming reply carries everything streamed so far.
    private func message(_ id: String) -> ChatMessage? {
        guard var message = messages[id] else { return nil }
        if let live, live.messageID == id { message.text = live.target }
        return message
    }

    /// Ours on top (copy the code, copy the message, copy as Markdown, read aloud, answer again), then the system's (Copy, Look Up,
    /// Translate, Share).
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let position = block(atCharacter: range.location), position < shown.blocks.count else {
            return UIMenu(children: suggestedActions)
        }
        let target = shown.blocks[position]
        let spansBlocks = range.length > 0 && block(atCharacter: NSMaxRange(range) - 1) != position
        var ours: [UIMenuElement] = []
        if case .code(_, let text) = target.kind {
            ours.append(UIAction(title: "Copy code", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
        }
        if let message = actionable(target) {
            ours.append(UIAction(title: "Copy message", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copyMessage(message.id.uuidString)
            })
            ours.append(UIAction(title: "Copy as Markdown", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
                self?.copyMarkdown(spansBlocks ? range : nil, message: message)
            })
            if message.role == .assistant, actions.canReadAloud {
                if actions.isReading {
                    ours.append(UIAction(title: "Stop reading", image: UIImage(systemName: "speaker.slash")) { [weak self] _ in
                        self?.actions.stopReading()
                    })
                } else {
                    ours.append(UIAction(title: "Read aloud", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                        self?.actions.readAloud(message.text)
                    })
                }
            }
            if message.id.uuidString == lastAssistantID, actions.canRegenerate {
                ours.append(UIAction(title: "Answer again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.actions.regenerate()
                })
            }
        } else if spansBlocks {
            ours.append(UIAction(title: "Copy as Markdown", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
                guard let markdown = self?.text(for: [range], markdown: true) else { return }
                UIPasteboard.general.string = markdown
            })
        }
        guard !ours.isEmpty else { return UIMenu(children: suggestedActions) }
        return UIMenu(children: [UIMenu(options: .displayInline, children: ours)] + suggestedActions)
    }

    /// The message's words as they read on screen, every paragraph of it.
    private func copyMessage(_ id: String) {
        guard let first = shown.blocks.firstIndex(where: { $0.messageID == id && actionable($0) != nil }),
              let last = shown.blocks.lastIndex(where: { $0.messageID == id && actionable($0) != nil }),
              let text = text(for: [NSRange(location: start(first), length: start(last) + lengths[last] - start(first))], markdown: false)
        else { return }
        UIPasteboard.general.string = text
        SystemToastCenter.shared.push(success: "Copied")
    }

    /// A selection across paragraphs gives their markdown sources; otherwise the whole message's markdown.
    private func copyMarkdown(_ range: NSRange?, message: ChatMessage) {
        let markdown = range.flatMap { text(for: [$0], markdown: true) } ?? message.text
        UIPasteboard.general.string = markdown
        SystemToastCenter.shared.push(success: "Copied as Markdown")
    }

    // MARK: Copy

    private func source(for block: TranscriptBlock, visibleLength: Int) -> String {
        guard let live, let cuts = live.cuts[block.id], let last = cuts.last,
              visibleLength < last.utf16End else { return block.source }
        guard let cut = cuts.last(where: { $0.utf16End <= visibleLength }) else { return "" }
        return String(decoding: block.source.utf8.prefix(cut.markdownEnd), as: UTF8.self)
    }

    /// Paragraph by paragraph: a wholly selected paragraph gives its markdown source (with `markdown`), a partly selected one its
    /// selected text. Closed folds are skipped, as they are on screen; line separators read as newlines and attachments as their source.
    func text(for ranges: [NSRange], markdown: Bool) -> String? {
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
                guard !text.isEmpty else { continue }
                let tight = block.messageID == lastMessage && (block.lead == .listItem || block.lead == .detail)
                parts.append((parts.isEmpty ? "" : (tight ? "\n" : "\n\n")) + text)
                lastMessage = block.messageID
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}
