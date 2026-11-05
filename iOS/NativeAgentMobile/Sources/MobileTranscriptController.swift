import NativeAgentShared
import QuartzCore
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptController.swift` | Owns the phone's document and the one law: place is a text location, never a measured height |

/// Owns the text view's document. Every change is one edit inside one editing transaction, and after every edit the reader's place
/// is put back: the first visible paragraph at the offset it had, or the end when the reader follows it.
/// Nothing here reads `.layoutManager`: that silently drops the view to TextKit 1.
@MainActor
final class MobileTranscriptController: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// The reader's place: the first visible paragraph (by block) and how far its top sits below the reading top.
    struct Place {
        var block: Int
        var offset: CGFloat
    }

    /// The reply being revealed. The pacer walks `target`; the document shows `liveBlocks` of what it has revealed so far.
    @MainActor
    struct Live {
        let messageID: String
        var pacer = ChatStreamPacer()
        var target: String
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

    private var sessionKey: String?
    /// The conversation as built from the thread's rows; `shown` is what the text storage holds (with the live reply spliced in).
    private var base = TranscriptDocument.empty
    private var shown = TranscriptDocument.empty
    /// Each block's paragraph length without its separator; every block but the last is followed by one "\n".
    private var lengths: [Int] = []
    private var startsCache: [Int]?
    private var index: [String: Int] = [:]
    /// Each shown block's paragraph as rendered (without source), so a reply that grows at its end appends only the new text.
    private var rendered: [String: (block: TranscriptBlock, text: NSAttributedString)] = [:]
    private var messages: [String: ChatMessage] = [:]
    private var lastAssistantID: String?
    private var data = TranscriptAttachmentData(messages: [:], approvals: [:], inboxCards: [:])
    /// The conversation's built groups, reused while a group is unchanged; a new conversation starts its own.
    private var buildCache = TranscriptBuildCache<MobileTranscriptRow>()

    private var live: Live?
    private var link: CADisplayLink?

    /// The column the text lays out in; zero until the host gives a width.
    private var containerWidth: CGFloat = 0
    private var traits = UITraitCollection.current
    private var look: (size: DynamicTypeSize, scheme: ColorScheme)?
    private var reduceMotion = false
    private var pendingOpen = true
    /// The reader follows the end. Only the reader's own scroll coming to rest sets it (true when it rests at the end), with Latest,
    /// sending and opening setting it true; every change and resize while it holds keeps the end in view. It is state, not
    /// geometry: TextKit's document height is an estimate until laid out, so "is the offset at the bottom" lies.
    private var following = true
    private var viewportSize = CGSize.zero
    private var scrollingToEnd = false

    override init() {
        let text = MobileTranscriptTextView(usingTextLayoutManager: true)
        guard let layout = text.textLayoutManager, let content = layout.textContentManager as? NSTextContentStorage else {
            fatalError("UITextView(usingTextLayoutManager: true) is TextKit 2 and always has a layout manager and content storage")
        }
        textView = text
        self.layout = layout
        self.content = content
        storage = text.textStorage
        super.init()
        configureView()
        attachments.heightChanged = { [weak self] blockID in self?.relay(blockID) }
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

        // A tap on the words (not on a hosted card) ends the composer's editing, as tapping the conversation always has.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        textView.addGestureRecognizer(tap)
    }

    /// The document leaves the screen: the reveal stops, the hosted views leave their parent controller, and the thread reads "at
    /// the end" so no Latest button outlives it.
    func dismantle() {
        stopLink()
        attachments.forget(Set(shown.blocks.map(\.id)))
        if handle?.controller === self {
            handle?.controller = nil
            handle?.isAtEnd = true
        }
    }

    // MARK: Input

    func update(_ input: MobileTranscriptInput, width: CGFloat, bottomInset: CGFloat, environment: EnvironmentValues,
                actions: MobileTranscriptActions, handle: MobileTranscriptHandle) {
        self.actions = actions
        reduceMotion = environment.accessibilityReduceMotion
        if self.handle !== handle {
            if self.handle?.controller === self { self.handle?.controller = nil }
            self.handle = handle
            handle.controller = self
        }
        if input.sessionKey != sessionKey { resetSession(input.sessionKey) }

        var messages: [String: ChatMessage] = [:]
        for message in input.messages { messages[message.id.uuidString] = message }
        self.messages = messages
        lastAssistantID = input.messages.last { $0.role == .assistant }?.id.uuidString
        data = TranscriptAttachmentData(messages: messages, approvals: input.approvals, inboxCards: input.inboxCards)
        base = TranscriptDocument.build(input, cache: buildCache)

        let newLook = setLook(environment)
        let newWidth = setWidth(width)
        attachments.update(data, environment: environment, actions: actions, columnWidth: containerWidth)
        if newLook || newWidth { restyle() }
        follow(input.liveMessageID)
        setBottomInset(bottomInset)
        apply(composed())
        if pendingOpen { open() }
    }

    private func resetSession(_ key: String) {
        sessionKey = key
        stopLink()
        live = nil
        let gone = Set(shown.blocks.map(\.id))
        content.performEditingTransaction { storage.setAttributedString(NSAttributedString()) }
        if !gone.isEmpty { attachments.forget(gone) }
        shown = .empty
        lengths = []
        startsCache = nil
        index = [:]
        rendered = [:]
        folds.openFolds = []
        buildCache = TranscriptBuildCache()
        pendingOpen = true
    }

    private var renderer: TranscriptRenderer {
        TranscriptRenderer(width: containerWidth, traits: traits) { [attachments] block, ref in
            attachments.attachment(blockID: block.id, ref: ref)
        }
    }

    /// The reader's text size or appearance changed: fonts are read again and every fragment redraws. Returns whether it changed.
    private func setLook(_ environment: EnvironmentValues) -> Bool {
        let next = (size: environment.dynamicTypeSize, scheme: environment.colorScheme)
        guard look?.size != next.size || look?.scheme != next.scheme else { return false }
        let first = look == nil
        look = next
        traits = UITraitCollection(traitsFrom: [
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(next.size)),
            UITraitCollection(userInterfaceStyle: next.scheme == .dark ? .dark : .light),
        ])
        return !first
    }

    /// The column is the room column inside the page inset, centred in whatever width the host has. Returns whether a laid-out column
    /// changed width, so the bubbles measure again.
    private func setWidth(_ width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        let column = max(1, min(TranscriptMetrics.column, width - 2 * TranscriptMetrics.pageInset))
        let side = floor((width - column) / 2)
        let inset = UIEdgeInsets(top: TranscriptMetrics.documentInset, left: side, bottom: TranscriptMetrics.documentInset, right: side)
        guard column != containerWidth || textView.textContainerInset != inset else { return false }
        let laidOut = containerWidth > 0
        keepingPlace(editStart: lengths.count, removed: 0, inserted: 0, layoutAbove: false) {
            textView.textContainerInset = inset
            textView.textContainer.size = CGSize(width: column, height: .greatestFiniteMagnitude)
        }
        let resized = column != containerWidth
        containerWidth = column
        return laidOut && resized
    }

    /// Every drawn paragraph renders again in place: a new column width re-measures the bubbles, a new text size or appearance
    /// re-reads fonts and redraws fragments. Hosted views follow their own environment.
    private func restyle() {
        rerender { block in
            if case .attachment = block.kind { return false }
            return true
        }
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
    private var reachesEnd: Bool {
        guard let last = lastFragmentFrame(ensuringLayout: false) else { return true }
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

    /// The end recipe with a direct offset (T0 rule 1): lay out the end, size the content to cover it, scroll, lay out the viewport,
    /// then close any residual by moving the offset again. Never an animated scroll to TextKit's estimate, which lands short.
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
            if let block = self.block(atCharacter: character) { place = Place(block: block, offset: frame.minY + originY - top) }
            return false
        }
        return place
    }

    /// Puts the place's paragraph back at its recorded offset. When the edit began above it, the paragraphs between are laid out first,
    /// so the paragraph's position is real and not an estimate.
    private func restore(_ place: Place, editStart: Int, layoutAbove: Bool) {
        guard place.block < lengths.count, let location = location(at: start(place.block)) else { return }
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
            if place.block >= editStart + removed {
                place.block += inserted - removed
            } else if place.block >= editStart {
                place.block = min(editStart, lengths.count - 1)
            }
            if place.block >= 0 { restore(place, editStart: editStart, layoutAbove: layoutAbove) }
            if !follows { following = reachesEnd }
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
        if pendingOpen { open() }
        let size = textView.bounds.size
        if size != viewportSize {
            viewportSize = size
            if following, !pendingOpen, !readerHolds { scrollToEnd() }
            didMove()
        }
        placeHostedViews()
    }

    /// The document's height changed on a later layout pass (a hosted view measured, estimates replaced by real lines): a reader
    /// following the end stays at the end.
    func documentResized() {
        guard following, !pendingOpen, !scrollingToEnd, !readerHolds, !reachesEnd else { return }
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
        guard !pendingOpen else { return }
        following = reachesEnd
        didMove()
    }

    // MARK: The one edit

    /// Turns the stored document into `next` with the contract's one edit, in one editing transaction, keeping the reader's place.
    private func apply(_ next: TranscriptDocument) {
        guard containerWidth > 0, let edit = shown.edit(to: next) else { return }
        let old = shown.blocks
        let renderer = self.renderer
        if appendsOnly(edit, old: old, renderer: renderer, next: next) { return }

        let paragraphs = edit.inserted.map { renderer.render($0) }
        let bodies = paragraphs.map(\.body)
        let count = old.count, at = edit.start, removed = edit.removed
        let replacement = NSMutableAttributedString()
        let from: Int, to: Int
        if at + removed < count {
            from = start(at)
            to = start(at + removed)
            for (offset, block) in edit.inserted.enumerated() {
                replacement.append(stamped(bodies[offset], block))
                replacement.append(paragraphs[offset].separator)
            }
        } else if edit.inserted.isEmpty {
            from = at > 0 ? start(at) - 1 : 0
            to = storage.length
        } else {
            if removed > 0 {
                from = start(at)
            } else {
                from = storage.length
                if count > 0 { replacement.append(renderer.separator(old[count - 1])) }
            }
            to = storage.length
            for (offset, block) in edit.inserted.enumerated() {
                if offset > 0 { replacement.append(paragraphs[offset - 1].separator) }
                replacement.append(stamped(bodies[offset], block))
            }
        }
        keepingPlace(editStart: at, removed: removed, inserted: edit.inserted.count) {
            content.performEditingTransaction {
                storage.replaceCharacters(in: NSRange(location: from, length: to - from), with: replacement)
            }
            lengths.replaceSubrange(at..<(at + removed), with: bodies.map(\.length))
            startsCache = nil
            shown = next
            reindex()
        }
        let gone = Set(old[at..<(at + removed)].map(\.id)).subtracting(edit.inserted.map(\.id))
        for id in gone { rendered[id] = nil }
        for (offset, block) in edit.inserted.enumerated() { rendered[block.id] = (block, bodies[offset]) }
        if !gone.isEmpty { attachments.forget(gone) }
        placeHostedViews()
    }

    /// Hosted views sit over their attachment's laid-out frame in the visible range; the document keeps only their room.
    /// Runs after every layout of the text view and every edit, so a view is wherever its paragraph is laid out.
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

    /// One block that only grew at its end (a streaming reply's last paragraph): append the new text, never replace the paragraph.
    private func appendsOnly(_ edit: TranscriptDocumentEdit, old: [TranscriptBlock], renderer: TranscriptRenderer,
                             next: TranscriptDocument) -> Bool {
        guard edit.removed == 1, edit.inserted.count == 1, let grown = edit.inserted.first, grown.id == old[edit.start].id,
              let before = rendered[grown.id], before.block == old[edit.start] else { return false }
        let after = renderer.paragraph(grown)
        let kept = NSRange(location: 0, length: before.text.length)
        guard after.length > before.text.length, after.attributedSubstring(from: kept).isEqual(to: before.text) else { return false }
        let at = edit.start
        let paragraphStart = start(at)
        let tail = after.attributedSubstring(from: NSRange(location: before.text.length, length: after.length - before.text.length))
        keepingPlace(editStart: at, removed: 1, inserted: 1) {
            content.performEditingTransaction {
                storage.replaceCharacters(in: NSRange(location: paragraphStart + before.text.length, length: 0), with: tail)
                storage.addAttribute(TranscriptKey.source, value: grown.source, range: NSRange(location: paragraphStart, length: after.length))
            }
            lengths[at] = after.length
            startsCache = nil
            shown = next
        }
        rendered[grown.id] = (grown, after)
        return true
    }

    private func stamped(_ body: NSAttributedString, _ block: TranscriptBlock) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: body)
        out.addAttribute(TranscriptKey.source, value: block.source, range: NSRange(location: 0, length: out.length))
        return out
    }

    private func reindex() {
        var index: [String: Int] = [:]
        index.reserveCapacity(shown.blocks.count)
        for (offset, block) in shown.blocks.enumerated() { index[block.id] = offset }
        self.index = index
    }

    /// Re-renders the chosen blocks in place, last first so earlier offsets hold, in one transaction. Text size, appearance and the
    /// bubbles' measured widths change this way; the block list does not.
    private func rerender(_ wants: (TranscriptBlock) -> Bool) {
        let targets = shown.blocks.indices.filter { wants(shown.blocks[$0]) }
        guard let first = targets.first else { return }
        let renderer = self.renderer
        let last = shown.blocks.count - 1
        keepingPlace(editStart: first, removed: 0, inserted: 0, layoutAbove: false) {
            content.performEditingTransaction {
                for position in targets.reversed() {
                    let block = shown.blocks[position]
                    let (body, separator) = renderer.render(block)
                    let replacement = NSMutableAttributedString(attributedString: stamped(body, block))
                    if position < last { replacement.append(separator) }
                    let length = lengths[position] + (position < last ? 1 : 0)
                    storage.replaceCharacters(in: NSRange(location: start(position), length: length), with: replacement)
                    lengths[position] = body.length
                    rendered[block.id] = (block, body)
                }
            }
            startsCache = nil
        }
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

    private func follow(_ liveID: UUID?) {
        if let liveID, let message = messages[liveID.uuidString] {
            if live?.messageID != liveID.uuidString {
                live = Live(messageID: liveID.uuidString, target: message.text, streaming: true)
            }
            live?.streaming = true
        } else {
            live?.streaming = false
        }
        guard var live else { return }
        retarget(&live, messages[live.messageID]?.text ?? live.target)
        self.live = live
        paceLive()
    }

    /// A text that no longer extends what was revealed (a retried turn starts over) gets a fresh pacer, whose first look shows it all.
    private func retarget(_ live: inout Live, _ text: String) {
        if !text.hasPrefix(live.target) { live.pacer = ChatStreamPacer() }
        live.target = text
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

    /// One frame: advance the pacer and splice what it revealed over the reply's blocks. Caught up, the link rests until the next batch;
    /// caught up after the turn ended, the reply is the built document's own blocks and the reveal is over.
    private func step(now: CFTimeInterval?) {
        guard var live else {
            stopLink()
            return
        }
        let total = live.target.utf8.count
        if let now {
            live.revealed = live.pacer.advance(live.target, now: now, maxLagBytes: Self.maxLagBytes)
        } else {
            live.revealed = total
        }
        let caughtUp = live.revealed >= total
        self.live = caughtUp && !live.streaming ? nil : live
        apply(composed())
        if caughtUp { stopLink() }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        return String(text[..<utf8.index(utf8.startIndex, offsetBy: min(max(0, bytes), utf8.count))])
    }

    /// The built document with the live reply's revealed words spliced over that message's word blocks ("<messageID>#<n>").
    /// Before its first revealed word the reply keeps the built document's waiting line.
    private func composed() -> TranscriptDocument {
        guard let live else { return base }
        let marker = live.messageID + "#"
        guard let first = base.blocks.firstIndex(where: { $0.id.hasPrefix(marker) }),
              let last = base.blocks.lastIndex(where: { $0.id.hasPrefix(marker) }) else { return base }
        let head = base.blocks[first]
        let words = TranscriptBuilder.liveBlocks(messageID: live.messageID, role: head.role,
                                                  text: Self.prefix(live.target, bytes: live.revealed), lead: head.lead)
        guard !words.isEmpty else { return base }
        var document = base
        document.blocks.replaceSubrange(first...last, with: words)
        return document
    }

    // MARK: Folds and action links

    /// A tap or a VoiceOver activation on an action link does what its button did; every other link opens as the system opens it.
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
    private func relay(_ blockID: String) {
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
                let block = shown.blocks[position]
                if let group = block.foldGroup, !folds.openFolds.contains(group) { continue }
                var isAttachment = false
                if case .attachment = block.kind { isAttachment = true }
                let whole = selected.length == body.length
                let text = isAttachment || (markdown && whole) ? block.source : string.substring(with: selected)
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
