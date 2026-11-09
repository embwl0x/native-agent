import AppKit
import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptDocumentController.swift` | Applies press scripts; TextKit viewport, reader place and prepared-glyph reveal |

/// Owns the text view's document. Every change is one edit inside one editing transaction, and after every edit the reader's place
/// is put back: the first visible paragraph at the offset it had, or the end while the reader chooses to follow it.
@MainActor
final class TranscriptDocumentController: NSObject, NSTextViewDelegate {
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
    private var presentation = ""
    private var shown = TranscriptDocument.empty
    private struct NativeParagraph {
        var body: NSAttributedString
        var separator: NSAttributedString
        var hidden: NSAttributedString
    }
    private var native: [String: NativeParagraph] = [:]
    private var hiddenLive: Set<String> = []
    private var readerID = UUID()
    private var appliedScript: UUID?
    private var readerRequested = false
    private var actTask: Task<Void, Never>?
    private var pendingActs: [UUID: Task<Void, Never>] = [:]
    private var lastGeometry: TranscriptReaderGeometry?
    private var lengths: [Int] = []
    private var startsCache: [Int]?
    private var index: [String: Int] = [:]
    private var data = TranscriptAttachmentData(sessionID: "", conversation: nil)

    private var live: Live?
    private var link: CADisplayLink?

    private var containerWidth = TranscriptMetrics.column
    private var pressWidth = TranscriptMetrics.column
    private var scale = TranscriptTextScale.value
    private var quiet = false
    private var reduceMotion = false
    private var pageVisible = true
    private var pendingOpen = true
    /// Only the reader's navigation changes whether document growth follows the end.
    private var following = true
    /// The last measured end. NSTextView sizes itself to TextKit's usage estimate, which guesses at paragraphs it has not laid out and can
    /// fall far short of the last line, so the estimate never shrinks the view below this.
    private var heldHeight: CGFloat?
    /// Where laying out the whole document has reached, as a character offset; nil once every paragraph has its real position.
    private var layoutOffset: Int?
    private var layoutPassOwed = false
    private var layoutStarted = CACurrentMediaTime()
    private var selfMoving = false
    private var liveScrolling = false
    private var openingStarted = CACurrentMediaTime()
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
        self.layout = layout
        self.content = content
        self.storage = storage
        super.init()
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
        center.addObserver(self, selector: #selector(scaleChanged(_:)), name: TranscriptTextScale.changed, object: nil)
    }

    func dismantle() {
        stopLink()
        releaseReader()
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
                transcriptLog("reader.act.failed reader=%@", reader.uuidString)
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
        let font = TranscriptRenderer(width: pressWidth, scale: scale).font(ShellType.captionSize)
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
        openingStarted = CACurrentMediaTime()
        firstPaintOwed = true
        completeDocument = false
        completeRequested = false
        completeActions.removeAll()
        model.waitingForCompleteDocument = false
        reportedFirstRender = []
        stopLink()
        live = nil
        let gone = Set(shown.blocks.map(\.id))
        content.performEditingTransaction { storage.setAttributedString(NSAttributedString()) }
        if !gone.isEmpty { attachments.forget(gone) }
        shown = .empty
        native = [:]
        hiddenLive = []
        lengths = []
        startsCache = nil
        index = [:]
        folds.openFolds = []
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

    private func observeFeed() {
        guard let appModel else { return }
        let id = readerID
        let packet = withObservationTracking {
            appModel.face.slot(.transcript(session: sessionID)).select("press:" + id.uuidString, as: TranscriptFace.self) { $0?.readers[id] }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.readerID == id, self.model.controller === self else { return }
                self.observeFeed()
            }
        }
        if let packet { receive(packet) }
    }

    private func observeConversation() {
        guard let appModel else { return }
        let id = readerID
        let session = sessionID
        data = withObservationTracking {
            appModel.face.slot(.conversation(session: session)).select("inline", as: ConversationFace.self) {
                TranscriptAttachmentData(sessionID: session, conversation: $0)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.readerID == id, self.model.controller === self else { return }
                self.observeConversation()
            }
        }
        if let environment { attachments.update(data, environment: environment, columnWidth: replyWidth) }
        if case .unavailable(let failure)? = data.state { model.conversationIssue = failure.localizedDescription }
        else { model.conversationIssue = nil }
        textView.needsDisplay = true
        rehover()
    }

    // MARK: Geometry

    private func viewportBlocks() -> Set<String> {
        guard let range = layout.textViewportLayoutController.viewportRange else { return [] }
        let from = content.offset(from: content.documentRange.location, to: range.location)
        let to = content.offset(from: content.documentRange.location, to: range.endLocation)
        guard let first = block(atCharacter: from), let last = block(atCharacter: to),
              shown.blocks.indices.contains(first), shown.blocks.indices.contains(last), first <= last else { return [] }
        return Set(shown.blocks[first...last].map(\.id))
    }

    private var clip: NSClipView { scrollView.contentView }
    private var readingTop: CGFloat { clip.bounds.minY + scrollView.contentInsets.top }
    private var readingBottom: CGFloat { clip.bounds.maxY - scrollView.contentInsets.bottom }
    private var maxOriginY: CGFloat {
        max(-scrollView.contentInsets.top, textView.frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
    }
    /// The laid-out end is within the reading area, or the reader has run out of view to scroll: the reader's scroll landed at the end.
    private var reachesEnd: Bool? {
        guard let last = lastFragmentFrame(ensuringLayout: true) else { return shown.blocks.isEmpty ? true : nil }
        return documentEnd(last) - readingBottom <= 1 || textView.frame.height - readingBottom <= 1
    }

    private var endStatus: String {
        guard let reached = reachesEnd else { return "unknown" }
        return reached ? "yes" : "no"
    }

    private func scroll(toOriginY y: CGFloat) {
        let clamped = min(max(y, -scrollView.contentInsets.top), maxOriginY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Layout performed for our own edit or scroll may synchronously move the clip again.
    private func movingDocument(_ change: () -> Void) {
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
        let wasFollowing = following
        following = reached
        if following != wasFollowing {
            transcriptLog("reader.scroll session=%@ following=%@ elapsed_ms=%.1f", String(sessionID.suffix(12)), following ? "yes" : "no",
                          (CACurrentMediaTime() - openingStarted) * 1_000)
        }
        if following, !liveScrolling { landAtEnd() }
        if readingTop <= clip.bounds.height { requestCompleteDocument() }
        didMove()
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
    private func layOutDocument(fromBlock block: Int) {
        guard let start = starts().indices.contains(block) ? start(block) : starts().last else { return }
        if layoutOffset == nil { layoutStarted = CACurrentMediaTime() }
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
        guard layoutOffset == nil else { return }
        transcriptLog("layout.done session=%@ blocks=%ld usage=%.0f end=%.0f view=%.0f elapsed_ms=%.1f", String(sessionID.suffix(12)), shown.blocks.count,
                      layout.usageBoundsForTextContainer.height, lastFragmentFrame(ensuringLayout: false).map { documentEnd($0) } ?? 0,
                      textView.frame.height, (CACurrentMediaTime() - layoutStarted) * 1_000)
    }

    private func continueDocumentLayout() {
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
    private func landAtEnd() {
        movingDocument {
            if shown.blocks.isEmpty { heldHeight = nil }
            var changed = false
            var passes = 0
            while let end = measuredEnd(), hold(end: end) {
                changed = true
                passes += 1
                guard passes < 8 else {
                    transcriptLog("end.unsettled session=%@ end=%.0f", String(sessionID.suffix(12)), end)
                    break
                }
                layout.textViewportLayoutController.layoutViewport()
            }
            guard changed else { return }
            textView.needsDisplay = true
            placeHostedViews()
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
        movingDocument {
            guard place.block >= 0, place.block < lengths.count, let location = location(at: start(place.block)) else { return }
            if layoutAbove, editStart < place.block, let from = self.location(at: start(editStart)),
               let between = NSTextRange(location: from, end: location) {
                layout.ensureLayout(for: between)
            }
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            let now = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - readingTop
            let shift = now - place.offset
            if abs(shift) > 0.01 { scroll(toOriginY: clip.bounds.origin.y + shift) }
        }
    }

    /// Growth keeps the end while following; otherwise the reader's paragraph stays at its recorded offset.
    private func keepingPlace(editStart: Int, removed: Int, inserted: Int, layoutAbove: Bool = true,
                              _ change: () -> Void) {
        let wasAtEnd = !pendingOpen && following && !liveScrolling
        movingDocument {
            let place = wasAtEnd || pendingOpen ? nil : recordPlace()
            change()
            guard !pendingOpen else { return }
            if wasAtEnd {
                landAtEnd()
            } else if var place {
                sizeViewToEnd()
                if let position = index[place.id] {
                    place.block = position
                } else if place.block >= editStart + removed {
                    place.block += inserted - removed
                } else if place.block >= editStart {
                    place.block = min(editStart, lengths.count - 1)
                }
                if place.block >= 0 { restore(place, editStart: editStart, layoutAbove: layoutAbove) }
            }
        }
        if pendingOpen {
            open()
            return
        }
        didMove()
    }

    private func open() {
        guard pendingOpen, !shown.blocks.isEmpty, scrollView.bounds.height > 0, textView.frame.width > 0 else { return }
        movingDocument {
            pendingOpen = false
            following = true
            landAtEnd()
            transcriptLog("open session=%@ blocks=%ld clip=%.0f document=%.0f reachesEnd=%@ elapsed_ms=%.1f", String(sessionID.suffix(12)),
                          shown.blocks.count, clip.bounds.height, textView.frame.height, endStatus,
                          (CACurrentMediaTime() - openingStarted) * 1_000)
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
        let end = lastFragmentFrame(ensuringLayout: false).map { documentEnd($0) - readingBottom <= 1 ? "yes" : "no" }
        transcriptLog("first.paint session=%@ reader=%@ script=%@ blocks=%ld elapsed_ms=%.1f reachesEnd=%@",
                      String(sessionID.suffix(12)), readerID.uuidString, script.uuidString, shown.blocks.count,
                      (CACurrentMediaTime() - openingStarted) * 1_000, end ?? "unknown")
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

    private func didMove() {
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

    /// The face consumes an applicable script and acknowledges exactly what reached TextKit.
    private func receive(_ packet: TranscriptPressEdits) {
        guard packet.id != appliedScript else { return }
        let id = readerID
        guard packet.base == appliedScript else {
            send(.transcriptReceipt(reader: id, receipt: .rebase))
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
                    body.addAttribute(.attachment, value: attachments.attachment(blockID: paragraph.block.id, ref: ref, role: paragraph.block.role),
                                      range: NSRange(location: 0, length: body.length))
                }
                replacements[paragraph.block.id] = try NativeParagraph(body: body,
                    separator: NSAttributedString(paragraph.separator, including: TranscriptAttributes.self),
                    hidden: NSAttributedString(paragraph.hidden, including: TranscriptAttributes.self))
            }
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
            model.pressIssue = packet.issue
            let changed = packet.edits
            if let first = changed.first {
                let single = changed.count == 1
                let layoutAbove = changed.contains { edit in
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
                attachments.forget(gone)
                transcriptLog("press.apply session=%@ reader=%@ script=%@ base=%@ edits=%ld removed=%ld inserted=%ld complete=%@",
                    sessionID, id.uuidString, packet.id.uuidString, packet.base?.uuidString ?? "nil",
                    changed.count, changed.reduce(0) { $0 + $1.removed }, changed.reduce(0) { $0 + $1.inserted.count },
                    packet.complete ? "yes" : "no")
            }
            appliedScript = packet.id
            completeDocument = packet.complete
            model.waitingForScript = false
            send(.transcriptReceipt(reader: id, receipt: .applied(script: packet.id)))
            paceLive()
            if pendingOpen { open() }
            placeHostedViews()
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
        } catch {
            model.pressIssue = "Transcript could not be applied: " + error.localizedDescription
            send(.transcriptReceipt(reader: id, receipt: .rejected(script: packet.id, cause: error.localizedDescription)))
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
        let count = shown.blocks.count
        let at = edit.start
        let removed = edit.removed
        let replacement = NSMutableAttributedString()
        let from: Int
        let to: Int
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

    private func reindex() {
        index = Dictionary(shown.blocks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
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

    @objc private func scaleChanged(_ note: Notification) {
        let next = TranscriptTextScale.value
        guard next != scale else { return }
        scale = next
        requestRestyle()
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
        let total = live.glyphs.utf8.count
        if let now {
            live.revealed = live.pacer.advance(live.glyphs, now: now, maxLagBytes: ChatStreamPacer.maxLagBytes)
        } else {
            live.revealed = total
        }
        let caughtUp = live.revealed >= total
        self.live = live
        applyReveal()
        if caughtUp && !live.streaming {
            self.live = nil
            send(.transcriptReceipt(reader: readerID, receipt: .revealed(row: live.messageID)))
        }
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

    private struct RevealEdit {
        let position: Int
        let length: Int
        let hidden: Bool
        let characters: NSRange
        let replacement: NSAttributedString
    }

    /// One storage splice appends prepared glyphs, retaining intervening text when it crosses paragraphs.
    private func applyReveal() {
        var edits: [RevealEdit] = []
        for key in Set(live?.cuts.keys.map { $0 } ?? []).union(hiddenLive) {
            guard let position = index[key], lengths.indices.contains(position), shown.blocks.indices.contains(position),
                  let paragraph = native[key] else { continue }
            let wasHidden = hiddenLive.contains(key)
            let count = visibleLength(key, paragraph)
            let isHidden = count == nil
            let body = isHidden ? paragraph.hidden : paragraph.body
            let length = count ?? body.length
            let oldLength = lengths[position]
            guard length != oldLength || wasHidden != isHidden else { continue }
            let prefix = !wasHidden && !isHidden && length > oldLength ? oldLength : 0
            edits.append(RevealEdit(position: position, length: length, hidden: isHidden,
                characters: NSRange(location: start(position) + prefix, length: oldLength - prefix),
                replacement: body.attributedSubstring(from: NSRange(location: prefix, length: length - prefix))))
        }
        edits.sort { $0.position < $1.position }
        guard let first = edits.first, let last = edits.last else { return }
        let replacement = NSMutableAttributedString()
        var cursor = first.characters.location
        for edit in edits {
            if cursor < edit.characters.location {
                replacement.append(storage.attributedSubstring(from: NSRange(location: cursor, length: edit.characters.location - cursor)))
            }
            replacement.append(edit.replacement)
            cursor = NSMaxRange(edit.characters)
        }
        let characters = NSRange(location: first.characters.location, length: NSMaxRange(last.characters) - first.characters.location)
        movingDocument {
            let origin = clip.bounds.origin
            content.performEditingTransaction {
                storage.replaceCharacters(in: characters, with: replacement)
                for edit in edits {
                    lengths[edit.position] = edit.length
                    let key = shown.blocks[edit.position].id
                    if edit.hidden { hiddenLive.insert(key) } else { hiddenLive.remove(key) }
                }
            }
            startsCache = nil
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
        let rows = members.compactMap { position -> String? in
            guard case .foldDetail = shown.blocks[position].kind else { return nil }
            return shown.blocks[position].messageID
        }
        send(.setTranscriptFold(reader: readerID, rows: rows, expanded: open))
        keepingPlace(editStart: first, removed: 0, inserted: 0) {
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
    private func relayoutAttachment(_ blockID: String) {
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
        if hover == nil { hoverReach = nil }
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
        ChatClipboard.copy(text)
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
        let state = withObservationTracking {
            appModel.face.slot(.voice(operation)).select("state", as: VoiceFace.self) { $0?.state }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.model.speechOperation == operation, self.model.controller === self else { return }
                self.observeSpeech(operation)
            }
        }
        if case .unavailable(let failure)? = state { showToast(failure.localizedDescription) }
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

    func showData(_ id: String) {
        model.dataMessage = TranscriptMessageReference(session: sessionID, id: id, role: "", action: nil)
    }

    func showToast(_ text: String) { model.show(text) }

    private func openExchange(_ exchange: OtherRoomExchange) {
        model.openedContact = exchange.contactID
    }

    // MARK: Copy as Markdown

    private func source(for block: TranscriptBlock, visibleLength: Int) -> String {
        guard let live, let cuts = live.cuts[block.id], let last = cuts.last,
              visibleLength < last.utf16End else { return block.source }
        guard let cut = cuts.last(where: { $0.utf16End <= visibleLength }) else { return "" }
        return Self.prefix(block.source, bytes: cut.markdownEnd)
    }

    /// Paragraph by paragraph: a wholly selected paragraph gives its markdown source, a partly selected one its selected text.
    /// Live sources stop at their visible glyphs; closed folds and unrevealed paragraphs are skipped, as they are on screen.
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
