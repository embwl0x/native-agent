import AppKit
import Foundation
import Observation
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptDocumentController.swift` | The Mac's glass on the Shared reader core: scroll view, whole-document layout, held height, FaceAct receipts, hover, find and menus |

/// The Mac's reader: the Shared core owns the document, its edits, the reader's place and the paced reveal; this owns the scroll view
/// the document sits in, laying the whole document out so positions are real, the end's held height, FaceAct receipts, hover, find
/// and menus. The reader's place after an edit is the first visible paragraph at the offset it had, or the end while they follow it.
@MainActor
final class TranscriptDocumentController: TranscriptReaderCore, NSTextViewDelegate {
    let scrollView = TranscriptDocumentScrollView()
    let textView: TranscriptTextView
    let attachments = TranscriptAttachments()
    let model: TranscriptDocumentModel
    private weak var handle: TranscriptDocumentHandle?
    private var appModel: AppModel?
    private var environment: EnvironmentValues?

    private var sessionID = ""
    private var presentation = ""
    private var readerRequested = false
    private var actTask: Task<Void, Never>?
    private var pendingActs: [UUID: Task<Void, Never>] = [:]
    private var lastGeometry: TranscriptReaderGeometry?
    private var inlineChanges: Task<Void, Never>?
    private var speechChanges: Task<Void, Never>?
    private var data = TranscriptAttachmentData(sessionID: "", conversation: nil)

    private var containerWidth = TranscriptMetrics.column
    private var pressWidth = TranscriptMetrics.column
    private var scaleObserver: NotificationCenter.ObservationToken?
    private var scale = TranscriptTextScale.value
    private var quiet = false
    private var reduceMotion = false
    private var pageVisible = true
    /// The last measured end. NSTextView sizes itself to TextKit's usage estimate, which guesses at paragraphs it has not laid out and can
    /// fall far short of the last line, so the estimate never shrinks the view below this.
    private var heldHeight: CGFloat?
    /// Where laying out the whole document has reached, as a character offset; nil once every paragraph has its real position.
    private var layoutOffset: Int?
    private var layoutPassOwed = false
    private var selfMoving = false
    private var liveScrolling = false
    private var firstPaintOwed = true
    private var completeDocument = false
    private var completeRequested = false
    private var completeActions: [@MainActor () -> Void] = []
    private var reportedFirstRender: Set<String> = []
    private var pendingReveal: String?
    private var widthRestylePending = false
    private var widthRestyleOwed = false
    /// The strip the hover bar hangs in below its message (text-view y range): the pointer crossing it keeps that message's bar.
    private var hoverReach: ClosedRange<CGFloat>?

    init(model: TranscriptDocumentModel) {
        self.model = model
        let storage = NSTextStorage()
        let content = NSTextContentStorage()
        content.textStorage = storage
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer()
        layout.textContainer = container
        let text = TranscriptTextView(frame: .zero, textContainer: container)
        textView = text
        super.init(content: content, layout: layout, storage: storage,
                   folds: TranscriptLayoutDelegate(user: TranscriptUserFragment.init(textElement:range:),
                                                   code: TranscriptCodeFragment.init(textElement:range:)),
                   rules: TranscriptReaderRules(maxLagBytes: ChatStreamPacer.maxLagBytes, layoutAboveOnlyWhenBlocksChange: true,
                                                foldFollowsEnd: true, copySkipsEmptyParagraphs: false))
        model.controller = self
        configureViews()
        attachments.heightChanged = { [weak self] blockID in self?.relayoutAttachment(blockID) }
        attachments.openExchange = { [weak self] exchange in self?.openExchange(exchange) }
        attachments.retryMessage = { [weak self] message in self?.regenerate(message) }
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
        center.addObserver(self, selector: #selector(liveScrollStarted(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollMoved(_:)), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollEnded(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        scaleObserver = center.addObserver(of: nil, for: TranscriptTextScale.Changed.self) { [weak self] _ in
            self?.scaleChanged()
        }
    }

    deinit {
        inlineChanges?.cancel()
        speechChanges?.cancel()
    }

    func dismantle() {
        stopLink()
        speechChanges?.cancel()
        speechChanges = nil
        releaseReader()
        scaleObserver = nil
        NotificationCenter.default.removeObserver(self)
        if handle?.controller === self { handle?.controller = nil }
        model.controller = nil
    }

    /// Hidden or offscreen copies never take keys.
    var isActive: Bool { pageVisible && !quiet }

    // MARK: Input

    func update(
        sessionID: String, presentation: String, topInset: CGFloat, bottomInset: CGFloat,
        environment: EnvironmentValues, appModel: AppModel, handle: TranscriptDocumentHandle?
    ) {
        self.appModel = appModel
        self.environment = environment
        quiet = environment.quietOffscreenRead
        let captureReader = quiet ? environment.quietTranscriptReader : nil
        guard !quiet || captureReader != nil else {
            model.pressIssue = "The offscreen transcript has no prepared reader."
            return
        }
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
        if sessionID != self.sessionID || presentation != self.presentation || captureReader.map({ $0 != readerID }) == true {
            self.presentation = presentation
            resetSession(sessionID, reader: captureReader)
        }

        setInsets(top: topInset, bottom: bottomInset)
        submitReader()
        if pendingOpen { open() }
        revealIfAsked()
    }

    /// Reader commands share one ordered chain, including release after the last acknowledgement.
    private func send(_ act: FaceAct, settlement: Bool = false) {
        guard !quiet else { return }
        guard let client = appModel?.client else {
            model.pressIssue = "The transcript has no face connection."
            return
        }
        let previous = actTask
        let model = model
        let reader = readerID
        let request = UUID()
        let task = Task { [weak self] in
            defer { self?.pendingActs.removeValue(forKey: request) }
            await previous?.value
            do {
                try Task.checkCancellation()
                try TranscriptFaceReply.acknowledged(try await client.act(act))
            } catch is CancellationError {
                // Reader closure cancels work; release remains ordered behind its settlement.
            } catch {
                if let self, self.readerID == reader {
                    model.commandIssue = error.localizedDescription
                    if case .transcriptReceipt(_, .complete) = act {
                        self.completeRequested = false
                        self.completeActions.removeAll()
                        model.waitingForCompleteDocument = false
                    }
                }
            }
        }
        actTask = task
        if !settlement { pendingActs[request] = task }
    }

    private var geometry: TranscriptReaderGeometry {
        TranscriptReaderGeometry(reader: readerID, width: pressWidth, scale: scale, viewportHeight: clip.bounds.height, viewport: viewportBlocks())
    }

    private func submitReader() {
        guard !quiet, appModel != nil, !sessionID.isEmpty, !readerRequested, clip.bounds.height > 0, textView.frame.width > 0 else { return }
        let font = NSFont.systemFont(ofSize: (ShellType.captionSize * scale).rounded(), weight: .regular)
        let line = max(1, font.ascender - font.descender + font.leading)
        guard let count = Int(exactly: ceil(clip.bounds.height / line)) else {
            model.pressIssue = "The transcript viewport has an invalid height. Resize the window."
            return
        }
        readerRequested = true
        lastGeometry = geometry
        send(.openTranscriptReader(TranscriptReaderRequest(session: sessionID, presentation: presentation,
            geometry: geometry, openingParagraphCount: max(1, count))))
    }

    private func releaseReader() {
        releaseFeedSelection()
        inlineChanges?.cancel()
        inlineChanges = nil
        for task in pendingActs.values { task.cancel() }
        pendingActs = [:]
        if readerRequested { send(.releaseTranscriptReader(reader: readerID), settlement: true) }
        readerRequested = false
    }

    private func resetSession(_ id: String, reader: UUID?) {
        // A search belongs to the chat it was asked in.
        if scrollView.isFindBarVisible { textView.findInCompleteDocument(.hideFindInterface) }
        releaseReader()
        if let reader { readerID = reader } else { readerID = UUID() }
        appliedScript = nil
        sessionID = id
        pendingOpen = true
        following = true
        heldHeight = nil
        layoutOffset = nil
        liveScrolling = false
        firstPaintOwed = true
        completeDocument = false
        completeRequested = false
        completeActions.removeAll()
        model.waitingForCompleteDocument = false
        reportedFirstRender = []
        clearDocument()
        model.pressIssue = nil
        model.conversationIssue = nil
        data = TranscriptAttachmentData(sessionID: id, conversation: nil)
        model.commandIssue = nil
        model.waitingForScript = true
        lastGeometry = nil
        observeConversation()
        observeFeed()
        setHover(nil, code: nil)
    }

    private var replyWidth: CGFloat { containerWidth - 2 * TranscriptMetrics.gutter }

    override var feed: FaceFeed? { appModel?.face }
    override var feedSession: String? { sessionID }
    override var isCurrentReader: Bool { model.controller === self }

    private func observeConversation() {
        guard let appModel else { return }
        let id = readerID
        let session = sessionID
        let selection = appModel.face.slot(.conversation(session: session)).selection("inline", as: ConversationFace.self) {
            TranscriptAttachmentData(sessionID: session, conversation: $0)
        }
        applyConversation(selection.part)
        let changes = Observations { selection.part }
        inlineChanges = Task { [weak self] in
            for await value in changes {
                guard !Task.isCancelled, let self, readerID == id, model.controller === self else { return }
                if value != data { applyConversation(value) }
            }
        }
    }

    private func applyConversation(_ value: TranscriptAttachmentData) {
        data = value
        if let environment { attachments.update(data, environment: environment, columnWidth: replyWidth) }
        if case .unavailable(let failure)? = data.state { model.conversationIssue = failure.localizedDescription }
        else { model.conversationIssue = nil }
        textView.needsDisplay = true
        rehover()
    }

    // MARK: Geometry

    private var clip: NSClipView { scrollView.contentView }
    override var readingTop: CGFloat { clip.bounds.minY + scrollView.contentInsets.top }
    private var readingBottom: CGFloat { clip.bounds.maxY - scrollView.contentInsets.bottom }
    private var maxOriginY: CGFloat {
        max(-scrollView.contentInsets.top, textView.frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
    }
    /// The laid-out end is within the reading area, or the reader has run out of view to scroll: the reader's scroll landed at the end.
    override var reachesEnd: Bool? {
        guard let last = lastFragmentFrame(ensuringLayout: true) else { return shown.blocks.isEmpty ? true : nil }
        return documentEnd(last) - readingBottom <= 1 || textView.frame.height - readingBottom <= 1
    }

    private func scroll(toOriginY y: CGFloat) {
        let clamped = min(max(y, -scrollView.contentInsets.top), maxOriginY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Layout performed for our own edit or scroll may synchronously move the clip again.
    override func moving(_ change: () -> Void) {
        let enclosing = selfMoving
        selfMoving = true
        defer { selfMoving = enclosing }
        change()
    }

    /// Reader actions own their landed position; synchronous TextKit corrections cannot pin over the move.
    func readerMove<Result>(onlyIfScrolled: Bool = false, _ change: () -> Result) -> Result {
        guard !selfMoving else { return change() }
        let origin = clip.bounds.origin
        selfMoving = true
        let result = change()
        if !pendingOpen, !onlyIfScrolled || clip.bounds.origin != origin { readerDidMove() }
        selfMoving = false
        return result
    }

    private func readerDidMove() {
        guard let reached = reachesEnd else { didMove(); return }
        following = reached
        if following, !liveScrolling { landAtEnd() }
        if readingTop <= clip.bounds.height { requestCompleteDocument() }
        didMove()
    }

    private func documentEnd(_ last: CGRect) -> CGFloat {
        last.maxY + textView.textContainerOrigin.y + textView.textContainerInset.height
    }

    /// The document's end, measured from half a reading area up: the top of that run plus the heights of its paragraphs. A fragment's height
    /// is real once laid out, but its position stays stale until the viewport reaches it, and the viewport stops at the view's bottom, so an
    /// end read from the last fragment's position can seat the view short of paragraphs that then never get placed. Half a reading area keeps
    /// the run's top on screen, where its position is real, once the reader is at the end. The work is the same however long the conversation is.
    private func measuredEnd() -> CGFloat? {
        let reach = (readingBottom - readingTop) / 2
        var covered: CGFloat = 0
        var top: CGFloat?
        _ = layout.enumerateTextLayoutFragments(from: content.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            top = fragment.layoutFragmentFrame.minY
            covered += fragment.layoutFragmentFrame.height
            return covered < reach
        }
        return top.map { ceil(documentEnd(CGRect(x: 0, y: $0, width: 0, height: covered))) }
    }

    /// TextKit places a paragraph only when the viewport reaches it and guesses everywhere else, and those guesses are what jump. So the
    /// whole document is laid out in order, from the first paragraph an edit changed: a short chat in one pass, a long one a slice per
    /// turn of the run loop, in its default mode so a scroll or a key always goes first.
    override func layOutDocument(fromBlock block: Int) {
        guard let start = starts().indices.contains(block) ? start(block) : starts().last else { return }
        layoutOffset = min(layoutOffset ?? start, start)
        advanceDocumentLayout()
    }

    private func advanceDocumentLayout() {
        guard let offset = layoutOffset, let from = location(at: offset) else { layoutOffset = nil; return }
        let deadline = CACurrentMediaTime() + 0.006
        var reached = offset
        _ = layout.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) { fragment in
            reached = self.content.offset(from: self.content.documentRange.location, to: fragment.rangeInElement.endLocation)
            return CACurrentMediaTime() < deadline
        }
        layoutOffset = reached > offset && reached < storage.length ? reached : nil
    }

    override func continueDocumentLayout() {
        guard layoutOffset != nil, !layoutPassOwed else { return }
        layoutPassOwed = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutPassOwed = false
                guard self.layoutOffset != nil else { return }
                self.keepingPlace(editStart: self.lengths.count, removed: 0, inserted: 0, layoutAbove: false) { self.advanceDocumentLayout() }
                self.continueDocumentLayout()
            }
        }
        // A block performed on a run loop does not wake it, and an idle window would leave the rest unplaced.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The view's height is the measured end, whatever TextKit's usage estimate asks for: it misses by a factor of two either way.
    func viewHeight(asked: CGFloat) -> CGFloat { heldHeight ?? asked }

    /// A reader away from the end keeps their place: the view takes the end's height and the clip stays where it is.
    private func sizeViewToEnd() {
        guard let last = lastFragmentFrame(ensuringLayout: false) else { return }
        heldHeight = ceil(documentEnd(last))
        if let heldHeight, textView.frame.height != heldHeight {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: heldHeight))
        }
    }

    /// Sizes the view to the end and seats the end at the reading bottom. Returns whether either moved.
    private func hold(end: CGFloat) -> Bool {
        heldHeight = end
        let resized = textView.frame.height != end
        if resized { textView.setFrameSize(NSSize(width: textView.frame.width, height: end)) }
        let y = max(-scrollView.contentInsets.top, end + scrollView.contentInsets.bottom - clip.bounds.height)
        let moved = abs(clip.bounds.origin.y - y) > 0.01
        if moved { scroll(toOriginY: y) }
        return resized || moved
    }

    /// The one way to the end, from anywhere: opening, Latest, growth while following. Laying out the viewport the move shows can replace
    /// estimates and move the end, so landing repeats until a pass moves nothing. A viewport that holds the end has nothing left to replace.
    override func landAtEnd() {
        moving {
            if shown.blocks.isEmpty { heldHeight = nil }
            var changed = false
            var passes = 0
            while let end = measuredEnd(), hold(end: end) {
                changed = true
                passes += 1
                guard passes < 8 else { break }
                layout.textViewportLayoutController.layoutViewport()
            }
            guard changed else { return }
            textView.needsDisplay = true
            placeHostedViews()
        }
    }

    override var textOrigin: CGPoint { textView.textContainerOrigin }
    override var holdsScroll: Bool { liveScrolling }
    override func shiftScroll(by shift: CGFloat) { scroll(toOriginY: clip.bounds.origin.y + shift) }
    /// A reader away from the end keeps their place inside a view sized to the end.
    override func willRestorePlace() { sizeViewToEnd() }

    override func open() {
        guard pendingOpen, !shown.blocks.isEmpty, scrollView.bounds.height > 0, textView.frame.width > 0 else { return }
        moving {
            pendingOpen = false
            following = true
            landAtEnd()
        }
        if let asked = pendingReveal { reveal(asked) }
        didMove()
        placeHostedViews()
    }

    func scrollViewDidLayout() {
        submitReader()
        requestRestyle()
        if pendingOpen { open() }
        viewportDidLayout()
    }

    func didPaint() {
        noteFirstRender()
        guard firstPaintOwed, !pendingOpen, !shown.blocks.isEmpty, let script = appliedScript else { return }
        firstPaintOwed = false
        send(.transcriptReceipt(reader: readerID, receipt: .painted(script: script)))
    }

    /// TextKit can move its estimated viewport without changing the document view's height.
    func viewportDidLayout() {
        requestRestyle()
        guard !pendingOpen, !selfMoving else { return }
        if following, !liveScrolling { landAtEnd() }
        didMove()
    }

    @objc private func clipMoved(_ note: Notification) {
        if model.hover != nil || model.codeCopy != nil { rehover() }
        didMove()
    }

    @objc private func liveScrollStarted(_ note: Notification) { liveScrolling = true }

    @objc private func liveScrollMoved(_ note: Notification) {
        guard !pendingOpen else { return }
        readerMove { }
    }

    @objc private func liveScrollEnded(_ note: Notification) {
        liveScrolling = false
        guard !pendingOpen else { return }
        readerMove { }
    }

    override func didMove() {
        // A document leaving for the empty room is still laid out for a moment and shares this handle; only the handle's own view speaks through it.
        if let handle, handle.controller === self, handle.isAtEnd != following { handle.isAtEnd = following }
        requestRestyle()
        // A folded tail can show its beginning and end together, leaving no room to scroll toward earlier messages.
        if !pendingOpen, !selfMoving, appliedScript != nil, model.pressIssue == nil, model.commandIssue == nil,
           let last = lastFragmentFrame(ensuringLayout: false), documentEnd(last) <= readingBottom - readingTop {
            requestCompleteDocument()
        }
    }

    /// Only glyphs drawn in a visible reader can claim the body's turn milestone.
    private func noteFirstRender() {
        guard isActive, textView.window?.occlusionState.contains(.visible) == true, !pendingOpen,
              let target = data.visibleReply, !reportedFirstRender.contains(target.turn), let script = appliedScript,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let from = content.offset(from: content.documentRange.location, to: viewport.location)
        let to = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard to > from else { return }
        let visible = NSRange(location: from, length: to - from)
        let drawn = shown.blocks.indices.contains { position in
            let block = shown.blocks[position]
            guard block.messageID == target.message, !hiddenLive.contains(block.id), block.foldGroup == nil,
                  ChatTranscriptPresentation.hasVisibleText(block.source) else { return false }
            switch block.kind {
            case .reply, .code: break
            default: return false
            }
            let intersection = NSIntersectionRange(visible, NSRange(location: start(position), length: lengths[position]))
            return intersection.length > 0
                && ChatTranscriptPresentation.hasVisibleText(storage.attributedSubstring(from: intersection).string)
        }
        guard drawn else { return }
        reportedFirstRender.insert(target.turn)
        send(.firstVisibleReply(.init(reader: readerID, session: sessionID, message: target.message, turn: target.turn, script: script, visible: true)))
    }

    // MARK: The one edit

    override func attachment(blockID: String, ref: TranscriptAttachmentRef, role: String) -> NSTextAttachment {
        attachments.attachment(blockID: blockID, ref: ref, role: role)
    }

    override func forgetAttachments(_ blockIDs: Set<String>) { attachments.forget(blockIDs) }
    override func placeHosted(_ frames: [String: CGRect]) { attachments.place(frames, in: textView) }

    override func acknowledge(_ receipt: TranscriptReaderReceipt) {
        send(.transcriptReceipt(reader: readerID, receipt: receipt.face))
    }

    override func pressIssue(_ issue: String?) { model.pressIssue = issue }
    override func scriptFailed(issue: String, cause: String) { model.pressIssue = issue }

    override func didAcceptScript(_ packet: TranscriptPressEdits) {
        completeDocument = packet.complete
        model.waitingForScript = false
    }

    override func didApplyScript(_ packet: TranscriptPressEdits) {
        revealIfAsked()
        if completeDocument {
            completeRequested = false
            model.waitingForCompleteDocument = false
            let actions = completeActions
            completeActions.removeAll()
            for action in actions { action() }
        } else if packet.issue != nil {
            completeRequested = false
            completeActions.removeAll()
            model.waitingForCompleteDocument = false
        }
        didMove()
    }

    // MARK: Width, insets, text size

    /// The column narrowed or widened: the text reflows in place and the bubbles re-measure on the next turn of the run loop,
    /// because the storage must not be edited inside the view's own layout.
    func changeContainerWidth(_ width: CGFloat, _ change: () -> Void) {
        keepingPlace(editStart: lengths.count, removed: 0, inserted: 0, layoutAbove: false) {
            change()
            layOutDocument(fromBlock: 0)
        }
        continueDocumentLayout()
        containerWidth = width
        // A live resize only reflows; the bubbles re-measure once, when the person lets go of the window.
        guard !scrollView.inLiveResize else { widthRestyleOwed = true; return }
        guard !widthRestylePending else { return }
        widthRestylePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.widthRestylePending = false
            self.restyleForWidth()
        }
    }

    /// The window stopped resizing: the one re-measure the resize owed.
    func liveResizeEnded() {
        guard widthRestyleOwed else { return }
        widthRestyleOwed = false
        restyleForWidth()
    }

    private func restyleForWidth() {
        pressWidth = containerWidth
        if let environment {
            attachments.update(data, environment: environment, columnWidth: replyWidth)
        }
        requestRestyle()
    }

    private func requestRestyle() {
        guard readerRequested else { return }
        let next = geometry
        let previous = lastGeometry
        guard next != previous else { return }
        lastGeometry = next
        if next.width != previous?.width || next.scale != previous?.scale || next.viewportHeight != previous?.viewportHeight {
            send(.resizeTranscriptReader(next))
        } else if next.viewport != previous?.viewport {
            send(.transcriptReceipt(reader: readerID, receipt: .viewport(blocks: next.viewport)))
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

    private func scaleChanged() {
        let next = TranscriptTextScale.value
        guard next != scale else { return }
        scale = next
        requestRestyle()
    }

    // MARK: The live reply

    /// Hidden, offscreen and Reduce Motion copies show the current words at once; otherwise the display link paces them in.
    override var revealsAtOnce: Bool { quiet || reduceMotion || !pageVisible || textView.window == nil }

    override func displayLink(target: Any, selector: Selector) -> CADisplayLink? {
        textView.displayLink(target: target, selector: selector)
    }

    /// One storage splice appends prepared glyphs, retaining intervening text when it crosses paragraphs. A following reader stays at
    /// the end; any other keeps the clip where it was.
    override func applyReveal(including previousReveal: [String] = []) {
        let changes = revealChanges(including: previousReveal)
        guard let first = changes.first else { return }
        moving {
            let origin = clip.bounds.origin
            splice(changes, coalesced: true)
            guard !pendingOpen else { return }
            if following && !liveScrolling {
                landAtEnd()
            } else {
                layOutDocument(fromBlock: first.position)
                sizeViewToEnd()
                if clip.bounds.origin != origin { scroll(toOriginY: origin.y) }
            }
        }
        continueDocumentLayout()
        if pendingOpen { open() }
        didMove()
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
    private func actionable(_ block: TranscriptBlock) -> TranscriptMessageReference? {
        switch block.kind {
        case .foldHeadline, .foldDetail, .gap: return nil
        default: break
        }
        guard ["user", "assistant", "system"].contains(block.role) else { return nil }
        return TranscriptMessageReference(session: sessionID, id: block.messageID, role: block.role,
            action: data.actions.first { $0.message == block.messageID })
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

    /// The App process keeps which tool rows the reader opened.
    override func foldWillToggle(rows: [String], open: Bool) {
        send(.setTranscriptFold(reader: readerID, rows: rows, expanded: open))
    }

    // MARK: Requests from the host

    func reveal(_ messageID: String) {
        if !completeDocument, !shown.blocks.contains(where: { $0.messageID == messageID }) {
            withCompleteDocument { [weak self] in self?.reveal(messageID) }
            return
        }
        guard !pendingOpen, let position = shown.blocks.firstIndex(where: { $0.messageID == messageID }) else {
            pendingReveal = messageID
            return
        }
        pendingReveal = nil
        if let group = shown.blocks[position].foldGroup, !folds.openFolds.contains(group) { setFold(group, open: true) }
        guard let location = location(at: start(position)) else { pendingReveal = messageID; return }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let frame = layout.textLayoutFragment(for: location)?.layoutFragmentFrame else { pendingReveal = messageID; return }
        readerMove {
            let reading = clip.bounds.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom
            scroll(toOriginY: frame.midY + textView.textContainerOrigin.y - scrollView.contentInsets.top - reading / 2)
            layout.textViewportLayoutController.layoutViewport()
        }
    }

    private func revealIfAsked() {
        if let asked = pendingReveal, !pendingOpen, shown.blocks.contains(where: { $0.messageID == asked }) {
            reveal(asked)
        }
    }

    func goToLatest() {
        guard !pendingOpen else { return }
        following = true
        readerMove { landAtEnd() }
    }

    func find(_ action: NSTextFinder.Action) {
        withCompleteDocument { [weak self] in
            guard let self else { return }
            if action == .showFindInterface { self.textView.window?.makeFirstResponder(self.textView) }
            self.textView.findInCompleteDocument(action)
        }
    }

    /// Full-document commands wait for the press's complete script, including every older paragraph.
    func withCompleteDocument(_ action: @escaping @MainActor () -> Void) {
        if completeDocument { action(); return }
        completeActions.append(action)
        requestCompleteDocument()
    }

    var hasPendingDocumentCommand: Bool { !completeActions.isEmpty }

    private func requestCompleteDocument() {
        guard !completeDocument else { return }
        guard !completeRequested else { return }
        completeRequested = true
        model.waitingForCompleteDocument = true
        send(.transcriptReceipt(reader: readerID, receipt: .complete))
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
            let y = frame.minY + origin.y + block.lead.topGap(message: NativeAgentShellLayout.transcriptGap) + TranscriptMetrics.codeHeader / 2
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
        // The bar sits in the room under the message; a card or other hosted view starting right there has that room, and its own controls.
        if last + 1 < shown.blocks.count, case .attachment = shown.blocks[last + 1].kind {
            setHover(nil, code: code)
            return
        }
        var seatsRight = false
        if case .user = shown.blocks[hit.block].kind { seatsRight = true }
        let bottom = fragment.layoutFragmentFrame.maxY + origin.y
        let x = origin.x + (seatsRight ? containerWidth - TranscriptMetrics.gutter : TranscriptMetrics.gutter)
        // The bar's top sits just under the message's last line, so it never covers the words it acts on.
        let anchor = hostPoint(NSPoint(x: x, y: bottom + 2))
        setHover(TranscriptHover(message: message, canRetry: canRegenerate(message), seatsRight: seatsRight, anchor: anchor), code: code)
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
        if hover == nil { hoverReach = nil; model.barHovered = false }
        if model.hover != hover { model.hover = hover }
        if model.codeCopy != code { model.codeCopy = code }
    }

    // MARK: Actions

    func canRegenerate(_ message: TranscriptMessageReference) -> Bool { message.action?.canRetry == true }

    func isReading(_ message: TranscriptMessageReference) -> Bool {
        guard let id = model.speechOperation else { return false }
        return appModel?.face.slot(.voice(id)).select("speaking", as: VoiceFace.self) {
            $0?.message == message.id && $0?.phase == .speaking
        } == true
    }

    private func messageText(_ id: String, markdown: Bool) -> String? {
        let positions = shown.blocks.indices.filter { shown.blocks[$0].messageID == id }
        return text(for: positions.map { NSRange(location: start($0), length: lengths[$0]) }, markdown: markdown)
    }

    func copyMessage(_ id: String) {
        guard completeDocument else { withCompleteDocument { [weak self] in self?.copyMessage(id) }; return }
        guard let text = messageText(id, markdown: false) else { showToast("No visible message text to copy."); return }
        ChatClipboard.copy(text)
        showToast("Copied")
    }

    func copyMarkdown(_ id: String) {
        guard completeDocument else { withCompleteDocument { [weak self] in self?.copyMarkdown(id) }; return }
        guard let text = messageText(id, markdown: true) else { showToast("No visible message text to copy."); return }
        ChatClipboard.copy(text)
        showToast("Copied as Markdown")
    }

    func copyCode(_ blockID: String) {
        guard let position = index[blockID], case .code(_, let text) = shown.blocks[position].kind else { return }
        // A code block's lines are U+2028 inside its one paragraph; the clipboard gets them back as newlines, as selection copy does.
        ChatClipboard.copy(text.replacingOccurrences(of: "\u{2028}", with: "\n"))
    }

    func readAloud(_ id: String) {
        guard let client = appModel?.client else { return }
        let operation = UUID(), session = sessionID
        model.speechOperation = operation
        observeSpeech(operation)
        Task {
            do {
                try TranscriptFaceReply.success(try await client.act(.voice(.speak(
                    id: operation, session: session, message: id, text: ""))))
            } catch { showToast(error.localizedDescription) }
        }
    }

    func stopReading() {
        guard let client = appModel?.client, let operation = model.speechOperation else { return }
        Task {
            do { try TranscriptFaceReply.success(try await client.act(.voice(.stopSpeech(id: operation)))) }
            catch { showToast(error.localizedDescription) }
        }
    }

    private func observeSpeech(_ operation: UUID) {
        guard let appModel else { return }
        let selection = appModel.face.slot(.voice(operation)).selection("state", as: VoiceFace.self) { $0?.state }
        speechChanges?.cancel()
        let changes = Observations { selection.part }
        speechChanges = Task { [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self, model.speechOperation == operation, model.controller === self else { return }
                if case .unavailable(let failure)? = state { showToast(failure.localizedDescription) }
            }
        }
    }

    func regenerate(_ id: String) {
        model.retryMessage = id
        model.retryRequested = true
    }

    func retry(_ id: String, choice: RetryChoice) {
        guard let client = appModel?.client else { return }
        let session = sessionID
        Task {
            do { try TranscriptFaceReply.success(try await client.act(.regenerate(session: session, message: id, choice: choice))) }
            catch { showToast(error.localizedDescription) }
        }
    }

    func remember(_ id: String) {
        guard completeDocument else { withCompleteDocument { [weak self] in self?.remember(id) }; return }
        guard let client = appModel?.client, let text = messageText(id, markdown: false) else {
            showToast("No visible message text to remember.")
            return
        }
        Task {
            do {
                let reply = try await client.act(.remember(text: text))
                try TranscriptFaceReply.success(reply)
                guard case .acknowledged = reply else { throw TranscriptFaceReply.unexpected }
                showToast("Remembered")
            } catch { showToast(error.localizedDescription) }
        }
    }

    /// The user's revision of her words starts from them, whole.
    func revise(_ id: String) {
        guard completeDocument else { withCompleteDocument { [weak self] in self?.revise(id) }; return }
        guard let text = messageText(id, markdown: true) else { showToast("No visible message text to revise."); return }
        model.revising = TranscriptRevision(session: sessionID, id: id, text: text)
    }

    /// Throws when the send is not accepted, so the sheet keeps the user's words and shows why.
    func sendRevision(_ revision: TranscriptRevision, text: String) async throws {
        guard let appModel else { throw WireFailure(code: "face_unavailable", message: "The app is not connected.", cause: nil, effects: .none) }
        _ = try await appModel.chatAct(.revise(session: revision.session, message: revision.id, from: revision.text, text: text))
    }

    func showData(_ id: String) {
        model.dataMessage = TranscriptMessageReference(session: sessionID, id: id, role: "", action: nil)
    }

    func showToast(_ text: String) { model.show(text) }

    private func openExchange(_ exchange: OtherRoomExchange) {
        model.openedContact = exchange.contactID
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
