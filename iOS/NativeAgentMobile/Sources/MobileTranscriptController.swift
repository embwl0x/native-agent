import Foundation
import NativeAgentShared
import Observation
import QuartzCore
import SwiftUI
import UIKit

// Blueprint: | `MobileTranscriptController.swift` | The phone's glass on the Shared reader core: text view and scroll, press calls, action links, edit menu and copy |

/// The phone's reader: the Shared core owns the document, its edits, the reader's place and the paced reveal; this owns the text view
/// and its scroll, the in-process press calls, action links, the edit menu and copy. The reader's place after an edit is the first
/// visible paragraph at the offset it had, or the end when the reader follows it.
/// Nothing here reads `.layoutManager`: that silently drops the view to TextKit 1.
@MainActor
final class MobileTranscriptController: TranscriptReaderCore, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// The phone's ~1 s batches run up to ~1,200 characters, so the reveal jumps only past four bytes a character of that.
    static let maxLagBytes = 4_800

    let textView: MobileTranscriptTextView
    let attachments = TranscriptAttachments()
    private weak var handle: MobileTranscriptHandle?
    private var actions = MobileTranscriptActions()
    private var environment: EnvironmentValues?

    private var sessionKey: String?
    private let owner = MobileTranscriptPress.shared
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

    /// The column the text lays out in; zero until the host gives a width.
    private var containerWidth: CGFloat = 0
    private var reduceMotion = false
    private var viewportSize = CGSize.zero
    private var scrollingToEnd = false
    private var openingStarted = CACurrentMediaTime()
    private var firstPaintOwed = true
    private let log = ModuleLog(category: "MobileTranscriptDocument")

    init() {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        layout.textContainer = container
        let text = MobileTranscriptTextView(frame: .zero, textContainer: container)
        textView = text
        // Reader scroll, Latest, sending and opening own following; estimated document height cannot decide it. A fold the reader
        // opens holds its row, and copy leaves out a paragraph that reads as nothing.
        super.init(content: content, layout: layout, storage: text.textStorage,
                   folds: TranscriptLayoutDelegate(user: TranscriptUserFragment.init(textElement:range:),
                                                   code: TranscriptCodeFragment.init(textElement:range:)),
                   rules: TranscriptReaderRules(maxLagBytes: MobileTranscriptController.maxLagBytes, layoutAboveOnlyWhenBlocksChange: false,
                                                foldFollowsEnd: false, copySkipsEmptyParagraphs: true))
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
        textView.bottomEdgeEffect.style = .soft
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityFocusMoved(_:)),
            name: UIAccessibility.elementFocusedNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The document leaves the screen: the reveal stops, the hosted views leave their parent controller, and the thread reads "at
    /// the end" so no Latest button outlives it.
    func dismantle() {
        mounted = false
        NotificationCenter.default.removeObserver(self)
        releaseFeedSelection()
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
        clearDocument()
        pendingOpen = true
        following = true
        handle?.issue = nil
        handle?.isPreparing = true
        observeFeed()
    }

    override var feed: FaceFeed? { owner.face }
    override var feedSession: String? { sessionKey }
    override var isCurrentReader: Bool { mounted }

    /// The column stays inside the page inset, centred in the room the host gives it.
    private func setWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let column = max(1, min(NativeAgentSpacing.chatRoomWidth, width - 2 * NativeAgentSpacing.pageInset))
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

    override var readingTop: CGFloat { textView.contentOffset.y + textView.contentInset.top }
    private var readingBottom: CGFloat { textView.contentOffset.y + textView.bounds.height - textView.contentInset.bottom }
    private var maxOffsetY: CGFloat {
        max(-textView.contentInset.top, textView.contentSize.height + textView.contentInset.bottom - textView.bounds.height)
    }
    /// The reader holds the scroll during a drag, its glide, or an animated scroll.
    private var readerHolds: Bool { textView.isDragging || textView.isDecelerating || textView.isScrollAnimating }
    override var reachesEnd: Bool? {
        if shown.blocks.isEmpty { return true }
        guard textView.bounds.height > 0 else { return nil }
        if let last = lastLaidOutFragmentFrame() {
            return documentEnd(last) - readingBottom <= 1
        }
        guard textView.contentSize.height - readingBottom <= 1 else { return false }
        if let viewport = layout.textViewportLayoutController.viewportRange,
           content.offset(from: viewport.endLocation, to: content.documentRange.endLocation) > 0 {
            return false
        }
        return true
    }

    private func lastLaidOutFragmentFrame(ensuringLayout: Bool = false) -> CGRect? {
        var frame: CGRect?
        let options: NSTextLayoutFragment.EnumerationOptions = ensuringLayout ? [.reverse, .ensuresLayout] : [.reverse]
        _ = layout.enumerateTextLayoutFragments(from: content.documentRange.endLocation, options: options) { fragment in
            if fragment.state == .layoutAvailable { frame = fragment.layoutFragmentFrame }
            return false
        }
        return frame
    }

    private func scroll(toOffsetY y: CGFloat) {
        let clamped = min(max(y, -textView.contentInset.top), maxOffsetY)
        guard textView.contentOffset.y != clamped else { return }
        moving {
            textView.contentOffset = CGPoint(x: textView.contentOffset.x, y: clamped)
        }
    }

    private func documentEnd(_ last: CGRect) -> CGFloat {
        last.maxY + textView.textContainerInset.top + textView.textContainerInset.bottom
    }

    /// Lay out the end before scrolling; close any residual after viewport layout.
    private func scrollToEnd() {
        guard !scrollingToEnd else { return }
        scrollingToEnd = true
        defer { scrollingToEnd = false }
        moving {
            guard let last = lastLaidOutFragmentFrame(ensuringLayout: true) else { return }
            let needed = documentEnd(last)
            if textView.contentSize.height < needed { textView.contentSize = CGSize(width: textView.contentSize.width, height: needed) }
            scroll(toOffsetY: maxOffsetY)
            layout.textViewportLayoutController.layoutViewport()
            guard let laidOutEnd = lastLaidOutFragmentFrame() else { return }
            let residual = documentEnd(laidOutEnd) - readingBottom
            if abs(residual) > 0.5 {
                scroll(toOffsetY: textView.contentOffset.y + residual)
                layout.textViewportLayoutController.layoutViewport()
            }
        }
    }

    override var textOrigin: CGPoint { CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top) }
    override var holdsScroll: Bool { readerHolds }
    override func shiftScroll(by shift: CGFloat) { scroll(toOffsetY: textView.contentOffset.y + shift) }
    override func landAtEnd() { scrollToEnd() }

    /// Opening lands at the end once there is something to show and a viewport to show it in.
    override func open() {
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

    override func didMove() {
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

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if !selfMoving { readerRested() }
    }

    func readerScrolled() {
        guard !selfMoving, !pendingOpen else { return }
        if textView.isScrollAnimating {
            following = false
            didMove()
        } else if !readerHolds {
            readerRested()
        }
    }

    @objc private func accessibilityFocusMoved(_ notification: Notification) {
        guard !selfMoving, !readerHolds,
              let element = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey],
              containsAccessibilityElement(element) else { return }
        readerRested()
    }

    private func containsAccessibilityElement(_ element: Any) -> Bool {
        var current: Any? = element
        var steps = 0
        while let node = current, steps < 64 {
            steps += 1
            if (node as AnyObject) === textView { return true }
            let next: Any?
            if let view = node as? UIView {
                next = view.superview
            } else if let item = node as? UIAccessibilityElement {
                next = item.accessibilityContainer
            } else {
                return false
            }
            if let next, (next as AnyObject) === (node as AnyObject) { return false }
            current = next
        }
        return false
    }

    /// The reader's own scroll came to rest: they follow the end exactly when it rests on it.
    private func readerRested() {
        guard !pendingOpen, let reached = reachesEnd else { return }
        following = reached
        didMove()
    }

    // MARK: The one edit

    override func attachment(blockID: String, ref: TranscriptAttachmentRef, role: String) -> NSTextAttachment {
        attachments.attachment(blockID: blockID, ref: ref, role: role)
    }

    override func forgetAttachments(_ blockIDs: Set<String>) { attachments.forget(blockIDs) }
    override func placeHosted(_ frames: [String: CGRect]) { attachments.place(frames, in: textView) }

    /// Receipts go straight to the in-process press.
    override func acknowledge(_ receipt: TranscriptReaderReceipt) {
        let id = readerID, press = owner.press
        Task {
            switch receipt {
            case .applied(let script): _ = await press.applied(reader: id, script: script)
            case .rejected(let script, _): await press.rejected(reader: id, script: script)
            case .rebase: await press.rebase(reader: id)
            case .revealed(let row): await press.revealed(reader: id, rowID: row)
            }
        }
    }

    override func pressIssue(_ issue: String?) { handle?.issue = issue }

    override func didAcceptScript(_ packet: TranscriptPressEdits) {
        handle?.isPreparing = false
        log("press.apply reader=%@ script=%@ edits=%ld blocks=%ld", readerID.uuidString, packet.id.uuidString,
            packet.edits.count, shown.blocks.count)
    }

    override func didApplyScript(_ packet: TranscriptPressEdits) { textView.setNeedsDisplay() }

    override func scriptFailed(issue: String, cause: String) {
        handle?.issue = issue
        handle?.isPreparing = false
        log("press.rejected reader=%@ cause=%@", readerID.uuidString, cause, level: .error)
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

    /// Reduce Motion and a view off screen show the current words at once; otherwise the display link paces them in.
    override var revealsAtOnce: Bool { reduceMotion || textView.window == nil }

    override func displayLink(target: Any, selector: Selector) -> CADisplayLink? { CADisplayLink(target: target, selector: selector) }

    /// Paragraph by paragraph inside the place law; paragraphs leaving the live line regain their complete prepared body.
    override func applyReveal(including previousReveal: [String] = []) {
        let changes = revealChanges(including: previousReveal)
        guard let first = changes.first else { return }
        keepingPlace(editStart: first.position, removed: 0, inserted: 0, layoutAbove: false) {
            splice(changes, coalesced: false)
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

    // MARK: Requests from the host

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
            if let sessionKey, message.id.uuidString == lastAssistantID, actions.canRegenerate {
                ours.append(UIAction(title: "Answer again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.actions.regenerate(message.id, sessionKey)
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

    /// Every paragraph of the message as it stands on screen.
    private func messageRange(_ id: String) -> NSRange? {
        guard let first = shown.blocks.firstIndex(where: { $0.messageID == id && actionable($0) != nil }),
              let last = shown.blocks.lastIndex(where: { $0.messageID == id && actionable($0) != nil }) else { return nil }
        return NSRange(location: start(first), length: start(last) + lengths[last] - start(first))
    }

    /// The message's words as they read on screen, every paragraph of it.
    private func copyMessage(_ id: String) {
        guard let range = messageRange(id), let text = text(for: [range], markdown: false) else { return }
        UIPasteboard.general.string = text
        SystemToastCenter.shared.push(success: "Copied")
    }

    /// A selection across paragraphs gives their markdown sources; otherwise the shown message's, cut where its words have revealed (as on the Mac).
    private func copyMarkdown(_ range: NSRange?, message: ChatMessage) {
        guard let markdown = (range ?? messageRange(message.id.uuidString)).flatMap({ text(for: [$0], markdown: true) }) else { return }
        UIPasteboard.general.string = markdown
        SystemToastCenter.shared.push(success: "Copied as Markdown")
    }
}
