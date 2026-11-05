import AppKit
import ChatTurnRuntime
import EngineRuntime
import MultimodalTTS
import NativeAgentShared
import Observation
import QuartzCore
import SwiftUI
import TurnTrace

// Blueprint: | `TranscriptDocumentController.swift` | Owns the document and the one law: place is a text location, never a measured height |

/// Owns the text view's document. Every change is one edit inside one editing transaction, and after every edit the reader's place
/// is put back: the first visible paragraph at the offset it had, or the end when the reader was at the end before the edit.
@MainActor
final class TranscriptDocumentController: NSObject, NSTextViewDelegate {
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

    let scrollView = TranscriptDocumentScrollView()
    let textView: TranscriptTextView
    let layout: NSTextLayoutManager
    let content: NSTextContentStorage
    let storage: NSTextStorage
    let folds = TranscriptLayoutDelegate()
    let attachments = TranscriptAttachments()
    let model: TranscriptDocumentModel
    private weak var handle: TranscriptDocumentHandle?
    private var appModel: AppModel?
    private var environment: EnvironmentValues?

    private var sessionID = ""
    /// The conversation as built from the host's rows; `shown` is what the text storage holds (with the live reply spliced in).
    private var base = TranscriptDocument.empty
    private var shown = TranscriptDocument.empty
    private var buildCache = TranscriptBuildCache<ChatMessage>()
    /// Each block's paragraph length without its separator; every block but the last is followed by one "\n".
    private var lengths: [Int] = []
    private var startsCache: [Int]?
    private var index: [String: Int] = [:]
    /// Each shown block's paragraph as rendered (without source), so a reply that grows at its end appends only the new text.
    private var rendered: [String: (block: TranscriptBlock, text: NSAttributedString)] = [:]
    private var messages: [String: ChatMessage] = [:]
    private var lastAssistantID: String?
    private var data = TranscriptAttachmentData(sessionID: "", messages: [:], cardsByRow: [:])

    private var live: Live?
    private var box: ChatStreamingTailBox?
    private var link: CADisplayLink?

    private var containerWidth = TranscriptMetrics.column
    private var scale = TranscriptTextScale.value
    private var quiet = false
    private var reduceMotion = false
    private var pageVisible = true
    private var pendingOpen = true
    /// The reader follows the end. Only the reader's own scrolling sets it (true when it lands at the end), with Latest and
    /// opening setting it true and a reveal or a find step false; every change and resize while it holds keeps the end in view.
    /// It is state, not geometry: TextKit's document height is an estimate until laid out, so "is the clip at the bottom" lies.
    private var following = true
    private var clipSize = CGSize.zero
    private var followingEnd = false
    private var pendingReveal: String?
    private var widthRestylePending = false
    private var reportedFirstRender: Set<String> = []
    /// The strip the hover bar hangs in below its message (text-view y range): the pointer crossing it keeps that message's bar.
    private var hoverReach: ClosedRange<CGFloat>?

    init(model: TranscriptDocumentModel) {
        self.model = model
        let text = TranscriptTextView(usingTextLayoutManager: true)
        guard let layout = text.textLayoutManager, let content = text.textContentStorage, let storage = text.textStorage else {
            fatalError("NSTextView(usingTextLayoutManager: true) is TextKit 2 and always has a layout manager, content storage and text storage")
        }
        textView = text
        self.layout = layout
        self.content = content
        self.storage = storage
        super.init()
        model.controller = self
        configureViews()
        attachments.heightChanged = { [weak self] blockID in self?.relay(blockID) }
        attachments.openExchange = { [weak self] exchange in self?.openExchange(exchange) }
    }

    private func configureViews() {
        textView.controller = self
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        // Links colour themselves where they are drawn (a fold headline keeps its own ink); the view only adds the hand.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            container.size = NSSize(width: TranscriptMetrics.column, height: CGFloat.greatestFiniteMagnitude)
        }
        content.delegate = folds
        layout.delegate = folds

        scrollView.controller = self
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.findBarPosition = .aboveContent
        scrollView.documentView = textView
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 0)

        let center = NotificationCenter.default
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(clipMoved(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(clipMoved(_:)), name: NSView.frameDidChangeNotification, object: clip)
        textView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(documentResized(_:)), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(readerScrolled(_:)), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(scaleChanged(_:)), name: TranscriptTextScale.changed, object: nil)
    }

    func dismantle() {
        stopLink()
        NotificationCenter.default.removeObserver(self)
        if handle?.controller === self { handle?.controller = nil }
        model.controller = nil
    }

    /// Hidden or offscreen copies never take keys.
    var isActive: Bool { pageVisible && !quiet }

    // MARK: Input

    func update<Groups: RandomAccessCollection<MessageGroup>>(
        sessionID: String, groups: Groups, cardsByRow: [String: [TranscriptReadout.Card]], exchanges: [OtherRoomExchange],
        showsTrouble: Bool, streamingMessageID: String?, topInset: CGFloat, bottomInset: CGFloat,
        environment: EnvironmentValues, appModel: AppModel, handle: TranscriptDocumentHandle?
    ) {
        self.appModel = appModel
        self.environment = environment
        quiet = environment.quietOffscreenRead
        reduceMotion = environment.accessibilityReduceMotion
        pageVisible = environment.chatPageIsVisible
        // A page under another is hidden, not only transparent, so nothing about it answers the pointer.
        textView.enclosingScrollView?.isHidden = !pageVisible
        if self.handle !== handle {
            if self.handle?.controller === self { self.handle?.controller = nil }
            self.handle = handle
            handle?.controller = self
            if let asked = handle?.pendingReveal {
                handle?.pendingReveal = nil
                pendingReveal = asked
            }
        }
        if sessionID != self.sessionID { resetSession(sessionID) }

        var messages: [String: ChatMessage] = [:]
        var lastAssistant: String?
        for group in groups {
            for message in group.messages {
                messages[message.id] = message
                if message.role == "assistant" { lastAssistant = message.id }
            }
        }
        self.messages = messages
        lastAssistantID = lastAssistant
        let transcripts = appModel.engine.transcripts
        let presentation = transcripts.presentation
        let title = transcripts.firstConversationReceiptTitle
        let trailing: [TranscriptBlock] = showsTrouble ? [
            TranscriptBlock(id: "trouble", messageID: "trouble", role: "system", kind: .attachment(.trouble), source: "",
                            lead: .message, foldGroup: nil)
        ] : []
        base = TranscriptBuilder.build(TranscriptThread(
            groups: Array(groups), exchanges: exchanges,
            face: { TranscriptRowFace.read($0, receiptTitle: title) },
            words: { presentation.words($0) }, cards: { cardsByRow[$0]?.map(\.model.id) ?? [] }, faceEpoch: title ?? "",
            wanted: { rows in Task { await transcripts.prepareToolFold(rows) } },
            door: TranscriptDoor(trailing: trailing)
        ), cache: buildCache)
        data = TranscriptAttachmentData(sessionID: sessionID, messages: messages, cardsByRow: cardsByRow)
        attachments.update(data, environment: environment, columnWidth: replyWidth)

        follow(streamingMessageID)
        setInsets(top: topInset, bottom: bottomInset)
        apply(composed())
        if pendingOpen { open() }
        if let asked = pendingReveal, !pendingOpen { reveal(asked) }
    }

    private func resetSession(_ id: String) {
        sessionID = id
        stopLink()
        live = nil
        box = nil
        buildCache = TranscriptBuildCache<ChatMessage>()
        let gone = Set(shown.blocks.map(\.id))
        content.performEditingTransaction { storage.setAttributedString(NSAttributedString()) }
        if !gone.isEmpty { attachments.forget(gone) }
        shown = .empty
        lengths = []
        startsCache = nil
        index = [:]
        rendered = [:]
        folds.openFolds = []
        reportedFirstRender = []
        pendingOpen = true
        setHover(nil, code: nil)
    }

    private var replyWidth: CGFloat { containerWidth - 2 * TranscriptMetrics.gutter }

    private var renderer: TranscriptRenderer {
        TranscriptRenderer(width: containerWidth, scale: scale) { [attachments] block, ref in
            attachments.attachment(blockID: block.id, ref: ref)
        }
    }

    // MARK: Geometry

    private var clip: NSClipView { scrollView.contentView }
    private var readingTop: CGFloat { clip.bounds.minY + scrollView.contentInsets.top }
    private var readingBottom: CGFloat { clip.bounds.maxY - scrollView.contentInsets.bottom }
    private var maxOriginY: CGFloat {
        max(-scrollView.contentInsets.top, textView.frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
    }
    /// The laid-out end is within the reading area: the reader's scroll landed at the end.
    private var reachesEnd: Bool {
        guard let last = lastFragmentFrame(ensuringLayout: false) else { return true }
        return documentEnd(last) - readingBottom <= 1
    }

    private func scroll(toOriginY y: CGFloat) {
        let clamped = min(max(y, -scrollView.contentInsets.top), maxOriginY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
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
        last.maxY + textView.textContainerOrigin.y + textView.textContainerInset.height
    }

    /// Positive: the document's end is below the reading bottom. Negative: blank room past the end.
    private func endResidual() -> CGFloat {
        guard let last = lastFragmentFrame(ensuringLayout: false) else { return 0 }
        return documentEnd(last) - readingBottom
    }

    /// The end recipe with the clip scroll (T0 rule 1): lay out the end, size the view to cover it, scroll, lay out the viewport,
    /// then close any residual by moving the clip. `adjustViewport` lands short and corrects late, which shows as a jump.
    private func scrollToEnd() {
        guard let last = lastFragmentFrame(ensuringLayout: true) else { return }
        let needed = documentEnd(last)
        if textView.frame.height < needed { textView.setFrameSize(NSSize(width: textView.frame.width, height: needed)) }
        scroll(toOriginY: maxOriginY)
        layout.textViewportLayoutController.layoutViewport()
        let residual = endResidual()
        if abs(residual) > 0.5 {
            scroll(toOriginY: clip.bounds.origin.y + residual)
            layout.textViewportLayoutController.layoutViewport()
        }
    }

    private func recordPlace() -> Place? {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return nil }
        let top = readingTop
        let originY = textView.textContainerOrigin.y
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
        let now = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - readingTop
        let shift = now - place.offset
        if abs(shift) > 0.01 { scroll(toOriginY: clip.bounds.origin.y + shift) }
    }

    /// The place law around one change of `removed` blocks at `editStart` into `inserted` blocks. Following means "was at the end
    /// before this change"; a fold the reader opens never follows, it holds the row.
    private func keepingPlace(editStart: Int, removed: Int, inserted: Int, follows: Bool = true, layoutAbove: Bool = true,
                              _ change: () -> Void) {
        let wasAtEnd = follows && !pendingOpen && following
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

    private func open() {
        guard pendingOpen, !shown.blocks.isEmpty, scrollView.bounds.height > 0, textView.frame.width > 0 else { return }
        pendingOpen = false
        scrollToEnd()
        following = true
        transcriptLog("open session=%@ blocks=%ld clip=%.0f document=%.0f reachesEnd=%@", String(sessionID.suffix(12)), shown.blocks.count,
                      clip.bounds.height, textView.frame.height, reachesEnd ? "yes" : "no")
        if let asked = pendingReveal { reveal(asked) }
        didMove()
        placeHostedViews()
    }

    func scrollViewDidLayout() {
        if pendingOpen { open() }
    }

    /// The viewport moved or resized. A resize keeps a reader who rested at the end there; content moved under a resting pointer
    /// moves the hover bar to whatever is under it now.
    @objc private func clipMoved(_ note: Notification) {
        if clip.frame.size != clipSize {
            clipSize = clip.frame.size
            if following, !pendingOpen { scrollToEnd() }
        }
        if model.hover != nil || model.codeCopy != nil { rehover() }
        didMove()
    }

    /// The document's height changed on a later layout pass (a hosted view measured, estimates replaced by real lines):
    /// a reader resting at the end stays at the end.
    @objc private func documentResized(_ note: Notification) {
        guard following, !pendingOpen, !followingEnd, !reachesEnd else { return }
        followingEnd = true
        transcriptLog("follow.resize document=%.0f", textView.frame.height)
        scrollToEnd()
        placeHostedViews()
        followingEnd = false
        didMove()
    }

    /// The reader scrolled (wheel, trackpad, scroller): they follow the end exactly when they landed on it.
    @objc func readerScrolled(_ note: Notification? = nil) {
        guard !pendingOpen else { return }
        following = reachesEnd
        didMove()
    }

    private func didMove() {
        if let handle, handle.isAtEnd != following { handle.isAtEnd = following }
        noteFirstRender()
    }

    // MARK: The one edit

    /// Turns the stored document into `next` with the contract's one edit, in one editing transaction, keeping the reader's place.
    private func apply(_ next: TranscriptDocument) {
        guard let edit = shown.edit(to: next) else { return }
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
        revealIfAsked()
    }

    /// Hosted views sit over their attachment's laid-out frame in the visible range; the document keeps only their room.
    /// Runs after every layout of the text view and every edit, so a view is wherever its paragraph is laid out.
    func placeHostedViews() {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let origin = textView.textContainerOrigin
        var frames: [String: CGRect] = [:]
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
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
        attachments.place(frames, in: textView)
    }

    /// One block that only grew at its end (a streaming reply's last paragraph): append the new text, never replace the paragraph.
    private func appendsOnly(_ edit: TranscriptDocumentEdit, old: [TranscriptBlock], renderer: TranscriptRenderer, next: TranscriptDocument) -> Bool {
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

    /// Re-renders the chosen blocks in place, last first so earlier offsets hold, in one transaction. Text size and the bubbles'
    /// measured widths change this way; the block list does not.
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

    // MARK: Width, insets, text size

    /// The column narrowed or widened: the text reflows in place and the bubbles re-measure on the next turn of the run loop,
    /// because the storage must not be edited inside the view's own layout.
    func changeContainerWidth(_ width: CGFloat, _ change: () -> Void) {
        keepingPlace(editStart: lengths.count, removed: 0, inserted: 0, layoutAbove: false, change)
        containerWidth = width
        guard !widthRestylePending else { return }
        widthRestylePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.widthRestylePending = false
            if let environment = self.environment {
                self.attachments.update(self.data, environment: environment, columnWidth: self.replyWidth)
            }
            self.rerender { block in
                if case .user = block.kind { return true }
                return false
            }
        }
    }

    private func setInsets(top: CGFloat, bottom: CGFloat) {
        let insets = scrollView.contentInsets
        guard insets.top != top || insets.bottom != bottom else { return }
        keepingPlace(editStart: lengths.count, removed: 0, inserted: 0, layoutAbove: false) {
            scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            scrollView.updateFade()
        }
    }

    @objc private func scaleChanged(_ note: Notification) {
        let next = TranscriptTextScale.value
        guard next != scale else { return }
        scale = next
        rerender { block in
            if case .attachment = block.kind { return false }
            return true
        }
    }

    // MARK: The live reply

    private func follow(_ streamingID: String?) {
        if let streamingID, let appModel {
            if live?.messageID != streamingID {
                let box = appModel.engine.transcripts.streamingTailBox(forMessage: streamingID)
                self.box = box
                live = Live(messageID: streamingID, target: box.content ?? messages[streamingID]?.content ?? "", streaming: true)
                observe(box)
            }
            live?.streaming = true
        } else {
            live?.streaming = false
        }
        guard var live else { return }
        retarget(&live, box?.content ?? messages[live.messageID]?.content ?? live.target)
        self.live = live
        paceLive()
    }

    /// The tail box changes on every streamed chunk without a structural publish; only this observation sees it.
    private func observe(_ box: ChatStreamingTailBox) {
        withObservationTracking {
            _ = box.content
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.boxChanged(box) }
        }
    }

    private func boxChanged(_ changed: ChatStreamingTailBox) {
        guard changed === box, var live else { return }
        observe(changed)
        retarget(&live, changed.content ?? messages[live.messageID]?.content ?? live.target)
        self.live = live
        paceLive()
    }

    /// A text that no longer extends what was revealed (a retried turn starts over) gets a fresh pacer, whose first look shows it all.
    private func retarget(_ live: inout Live, _ text: String) {
        if !text.hasPrefix(live.target) { live.pacer = ChatStreamPacer() }
        live.target = text
    }

    /// Hidden, offscreen and Reduce Motion copies show the current words at once; otherwise the display link paces them in.
    private var revealsAtOnce: Bool { quiet || reduceMotion || !pageVisible || textView.window == nil }

    private func paceLive() {
        guard live != nil else { return }
        if revealsAtOnce {
            step(now: nil)
        } else if link == nil {
            let link = textView.displayLink(target: self, selector: #selector(tick(_:)))
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
        let total = live.target.utf8.count
        if let now {
            live.revealed = live.pacer.advance(live.target, now: now, maxLagBytes: ChatStreamPacer.maxLagBytes)
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

    /// The built document with the live reply's revealed text spliced over that message's blocks ("<messageID>#<n>").
    private func composed() -> TranscriptDocument {
        guard let live else { return base }
        let marker = live.messageID + "#"
        guard let first = base.blocks.firstIndex(where: { $0.id.hasPrefix(marker) }),
              let last = base.blocks.lastIndex(where: { $0.id.hasPrefix(marker) }) else { return base }
        let head = base.blocks[first]
        var document = base
        document.blocks.replaceSubrange(first...last, with: TranscriptBuilder.liveBlocks(
            messageID: live.messageID, role: head.role, text: Self.prefix(live.target, bytes: live.revealed), lead: head.lead))
        return document
    }

    // MARK: Hit testing

    private func hit(atViewPoint point: NSPoint) -> (fragment: NSTextLayoutFragment, block: Int)? {
        let origin = textView.textContainerOrigin
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) else { return nil }
        let character = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard let block = block(atCharacter: character), block < shown.blocks.count else { return nil }
        return (fragment, block)
    }

    /// The message a block's menu and hover bar act on: a person's or the agent's words, never a fold, a gap line or a tool row.
    private func actionable(_ block: TranscriptBlock) -> ChatMessage? {
        switch block.kind {
        case .foldHeadline, .foldDetail, .gap: return nil
        default: break
        }
        guard let message = message(block.messageID), ["user", "assistant", "system"].contains(message.role) else { return nil }
        return message
    }

    /// The row as it reads now: a streaming reply carries everything streamed so far.
    private func message(_ id: String) -> ChatMessage? {
        guard var message = messages[id] else { return nil }
        if let live, live.messageID == id { message.content = live.target }
        return message
    }

    func menuTarget(atViewPoint point: NSPoint) -> TranscriptMenuTarget? {
        guard let hit = hit(atViewPoint: point) else { return nil }
        let block = shown.blocks[hit.block]
        var code: String?
        if case .code = block.kind { code = block.id }
        return TranscriptMenuTarget(message: actionable(block), codeBlockID: code)
    }

    // MARK: Folds

    /// A fold headline's link toggles its run; every other link opens as the system opens it.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        transcriptLog("link.press at=%ld fold=%@", charIndex, TranscriptFoldLink.group(link) ?? "-")
        guard let group = TranscriptFoldLink.group(link) else { return false }
        setFold(group, open: !folds.openFolds.contains(group))
        return true
    }

    func toggleFold(atViewPoint point: NSPoint) -> Bool {
        guard let hit = hit(atViewPoint: point), hit.fragment is TranscriptFoldFragment else { return false }
        let group = shown.blocks[hit.block].messageID
        setFold(group, open: !folds.openFolds.contains(group))
        return true
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
        // An opened run asks for its rows' detail words; the document rebuilds when they land.
        if open, let transcripts = appModel?.engine.transcripts {
            let rows = members.compactMap { position -> ChatMessage? in
                guard case .foldDetail = shown.blocks[position].kind else { return nil }
                return messages[shown.blocks[position].messageID]
            }
            if !rows.isEmpty { Task { await transcripts.prepareToolFold(rows, expanded: true) } }
        }
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

    func reveal(_ messageID: String) {
        guard !pendingOpen, let position = shown.blocks.firstIndex(where: { $0.messageID == messageID }) else {
            pendingReveal = messageID
            return
        }
        pendingReveal = nil
        following = false
        if let group = shown.blocks[position].foldGroup, !folds.openFolds.contains(group) { setFold(group, open: true) }
        guard let location = location(at: start(position)) else { return }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let frame = layout.textLayoutFragment(for: location)?.layoutFragmentFrame else { return }
        let reading = clip.bounds.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom
        scroll(toOriginY: frame.midY + textView.textContainerOrigin.y - scrollView.contentInsets.top - reading / 2)
        layout.textViewportLayoutController.layoutViewport()
        didMove()
    }

    private func revealIfAsked() {
        if let asked = pendingReveal, !pendingOpen, shown.blocks.contains(where: { $0.messageID == asked }) {
            reveal(asked)
        }
    }

    func goToLatest() {
        guard !pendingOpen else { return }
        following = true
        scrollToEnd()
        didMove()
    }

    func find(_ action: NSTextFinder.Action) {
        // Stepping through matches is reading, not following.
        if action == .nextMatch || action == .previousMatch { following = false; didMove() }
        if action == .showFindInterface { textView.window?.makeFirstResponder(textView) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: First render

    /// The first time the last reply's paragraphs are in the laid-out viewport with words in them, the turn's first-render receipt fires.
    /// Quiet offscreen copies never claim a render the person saw.
    private func noteFirstRender() {
        guard !quiet, let id = lastAssistantID, !reportedFirstRender.contains(id), let appModel, let message = message(id) else { return }
        let visible = live?.messageID == id ? Self.prefix(message.content, bytes: live?.revealed ?? 0) : message.content
        guard ChatTranscriptPresentation.hasVisibleText(visible), let viewport = layout.textViewportLayoutController.viewportRange,
              let first = shown.blocks.firstIndex(where: { $0.messageID == id }),
              let last = shown.blocks.lastIndex(where: { $0.messageID == id }),
              let from = location(at: start(first)), let to = location(at: start(last) + lengths[last]),
              let range = NSTextRange(location: from, end: to), viewport.intersects(range) else { return }
        reportedFirstRender.insert(id)
        let activeSessionID = appModel.activeChatSessionId
        Task {
            await TurnFirstRenderRegistry.shared.observeFirstRender(
                role: message.role, content: visible, isLastAssistant: true, messageSessionID: message.sessionId,
                messageTurnID: message.metadata?.turnTraceId, activeSessionID: activeSessionID,
                observedBy: "NativeAgentApp.TranscriptDocumentView")
        }
    }

    // MARK: Hover

    func hover(atViewPoint point: NSPoint?) {
        guard !model.barHovered else { return }
        if let point, let reach = hoverReach, model.hover != nil, reach.contains(point.y) { return }
        guard let point, let hit = hit(atViewPoint: point) else {
            setHover(nil, code: nil)
            return
        }
        let block = shown.blocks[hit.block]
        let origin = textView.textContainerOrigin
        var code: TranscriptCodeCopy?
        if case .code = block.kind {
            let frame = hit.fragment.layoutFragmentFrame
            let y = frame.minY + origin.y + TranscriptMetrics.topGap(block.lead) + TranscriptMetrics.codeHeader / 2
            let x = origin.x + containerWidth - TranscriptMetrics.gutter - TranscriptMetrics.codePadH
            code = TranscriptCodeCopy(blockID: block.id, anchor: hostPoint(NSPoint(x: x, y: y)))
        }
        guard let message = actionable(block) else {
            setHover(nil, code: code)
            return
        }
        var last = hit.block
        while last + 1 < shown.blocks.count, shown.blocks[last + 1].messageID == message.id { last += 1 }
        guard let location = location(at: start(last)), let fragment = layout.textLayoutFragment(for: location) else {
            setHover(nil, code: code)
            return
        }
        var seatsRight = false
        if case .user = shown.blocks[hit.block].kind { seatsRight = true }
        let bottom = fragment.layoutFragmentFrame.maxY + origin.y
        let x = origin.x + (seatsRight ? containerWidth - TranscriptMetrics.gutter : TranscriptMetrics.gutter)
        // The bar's top sits just under the message's last line, so it never covers the words it acts on.
        let anchor = hostPoint(NSPoint(x: x, y: bottom + 2))
        setHover(TranscriptHover(message: message, isLastAssistant: canRegenerate(message), seatsRight: seatsRight, anchor: anchor), code: code)
        hoverReach = bottom...(bottom + NativeAgentShellLayout.hoverBarStrip)
    }

    /// The pointer left the hover bar: hover whatever is under it now.
    func rehover() {
        guard let window = textView.window else { return }
        let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hover(atViewPoint: textView.visibleRect.contains(point) ? point : nil)
    }

    /// A text-view point in the SwiftUI host's space (top-left origin).
    private func hostPoint(_ point: NSPoint) -> CGPoint {
        let converted = textView.convert(point, to: scrollView)
        return CGPoint(x: converted.x, y: scrollView.isFlipped ? converted.y : scrollView.bounds.height - converted.y)
    }

    private func setHover(_ hover: TranscriptHover?, code: TranscriptCodeCopy?) {
        if hover == nil { hoverReach = nil }
        if model.hover != hover { model.hover = hover }
        if model.codeCopy != code { model.codeCopy = code }
    }

    // MARK: Actions (the same AppModel calls the bubble made)

    func canRegenerate(_ message: ChatMessage) -> Bool {
        message.role == "assistant" && message.id == lastAssistantID && message.metadata?.providerRefusal != true
    }

    private static func speechOwner(_ message: ChatMessage) -> String {
        "message:\(message.sessionId ?? "unknown"):\(message.id)"
    }

    func isReading(_ message: ChatMessage) -> Bool {
        VoiceOutputController.sharedMessagePlayback.isSpeaking(ownerID: Self.speechOwner(message))
    }

    func copyMessage(_ id: String) {
        guard let message = message(id) else { return }
        ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
        showToast("Copied")
    }

    func copyMarkdown(_ id: String) {
        guard let message = message(id) else { return }
        ChatClipboard.copy(ChatExport.messageMarkdown(message))
        showToast("Copied as Markdown")
    }

    func copyCode(_ blockID: String) {
        guard let position = index[blockID], case .code(_, let text) = shown.blocks[position].kind else { return }
        ChatClipboard.copy(text)
    }

    func toggleReadAloud(_ id: String) {
        guard let message = message(id), let appModel else { return }
        let voice = VoiceOutputController.sharedMessagePlayback
        let owner = Self.speechOwner(message)
        if voice.isSpeaking(ownerID: owner) {
            voice.stop()
            return
        }
        model.speechOwnerID = owner
        Task {
            await voice.speak(text: message.content, policy: appModel.engine.trust.policy,
                              loadPolicy: { try await appModel.engine.trust.load() }, ownerID: owner)
        }
    }

    /// Retries after effects or an unknown outcome go through the shared confirmation; anything else regenerates at once.
    func regenerate(_ id: String) {
        guard let message = message(id), let appModel else { return }
        let rows = appModel.engine.transcripts.messages(for: message.sessionId ?? appModel.activeChatSessionId)
        if let failure = ChatTurnFailure.retryNeedsConfirmation(for: message, in: rows) {
            model.retryMessage = message
            model.retryFailure = failure
        } else {
            Task { await appModel.regenerateAssistantMessage(message) }
        }
    }

    func remember(_ id: String) {
        guard let message = message(id), let appModel else { return }
        Task { showToast(await appModel.addMemoryFact(message.content).userMessage) }
    }

    func showData(_ id: String) {
        model.dataMessage = message(id)
    }

    func showToast(_ text: String) {
        model.show(text)
    }

    private func openExchange(_ exchange: OtherRoomExchange) {
        guard let appModel else { return }
        if let contact = appModel.engine.contactThreads.contacts.first(where: { $0.id == exchange.contactID }) {
            model.openedContact = contact
        } else {
            showToast("That conversation can't be opened right now.")
        }
    }

    // MARK: Copy as Markdown

    /// Paragraph by paragraph: a wholly selected paragraph gives its markdown source, a partly selected one its selected text.
    /// Closed folds are skipped, as they are on screen.
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
                let tight = block.messageID == lastMessage && (block.lead == .listItem || block.lead == .detail)
                parts.append((parts.isEmpty ? "" : (tight ? "\n" : "\n\n")) + text)
                lastMessage = block.messageID
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    // MARK: Writing Tools

    /// Code, attachments, folds and gap lines are not prose; Writing Tools leaves them alone.
    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        let range = NSIntersectionRange(enclosingRange, NSRange(location: 0, length: storage.length))
        let prose: Set<String> = [TranscriptParagraph.user.rawValue, TranscriptParagraph.reply.rawValue, TranscriptParagraph.heading.rawValue,
                                  TranscriptParagraph.quote.rawValue, TranscriptParagraph.listItem.rawValue]
        var ignored: [NSValue] = []
        storage.enumerateAttribute(TranscriptKey.kind, in: range) { value, run, _ in
            if let kind = value as? String, !prose.contains(kind) { ignored.append(NSValue(range: run)) }
        }
        return ignored
    }
}
