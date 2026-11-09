import AppKit
import Foundation
import NativeAgentShared

// Blueprint: | `TranscriptTextView.swift` | The one NSTextView (TextKit 2) and its scroll view: menu, pasteboard, keys, hover, folds and the soft edges |

/// The one text view. Nothing here or in the controller reads `.layoutManager`: that silently drops the view to TextKit 1.
final class TranscriptTextView: NSTextView {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    weak var controller: TranscriptDocumentController?
    private var writesMarkdownAsString = false
    private var hoverArea: NSTrackingArea?

    /// The container is the column (or the whole width when narrower); the inset centres it in whatever width the view has.
    override func setFrameSize(_ newSize: NSSize) {
        let size = NSSize(width: newSize.width, height: controller?.viewHeight(asked: newSize.height) ?? newSize.height)
        guard size != frame.size else { return }
        super.setFrameSize(size)
        // The views NSTextView draws its text in cover it, but follow its height only when it resizes itself, and clip every line below
        // the height they were left at. Hosted views keep the frame their paragraph gave them.
        for view in subviews where controller?.attachments.hosts(view) != true && view.frame.size != size {
            view.setFrameSize(size)
            view.needsDisplay = true
        }
        // An unsized view keeps the column it has; laying the document out at zero width would only be thrown away.
        guard size.width > 0 else { return }
        let column = min(TranscriptMetrics.column, size.width)
        let inset = NSSize(width: max(0, floor((size.width - column) / 2)), height: TranscriptMetrics.documentInset)
        if textContainerInset != inset { textContainerInset = inset }
        guard let container = textContainer, container.size.width != column else { return }
        let resize = { container.size = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude) }
        if let controller { controller.changeContainerWidth(column, resize) } else { resize() }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The visible-rect area follows scrolling and resizing without replacing its registration.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// TextKit lays the viewport out here; hosted views follow their paragraphs after each pass.
    override func layout() {
        super.layout()
        controller?.viewportDidLayout()
        controller?.placeHostedViews()
    }

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        controller?.placeHostedViews()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        controller?.didPaint()
    }

    // MARK: Accessibility

    /// The hosted attachment views placed over their paragraphs (cards, tables, images) on screen now. They are this view's subviews, which
    /// the text view's own accessibility element (AXTextArea) leaves out.
    private var shownHostedViews: [NSView] {
        subviews.filter { !$0.isHidden && controller?.attachments.hosts($0) == true }
    }

    /// The text area's children are its own and every hosted view on screen, so VoiceOver and an accessibility press reach a card's buttons
    /// (Approve, Deny, a choice) inside the transcript.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + shownHostedViews
    }

    /// A point over a hosted view is that view's element (its button, when there is one), not the text under it.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        if let window {
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            if let view = shownHostedViews.last(where: { $0.frame.contains(local) }) { return view.accessibilityHitTest(point) }
        }
        return super.accessibilityHitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let onText = textIsOnTop(event)
        // NSTextView sets its own I-beam on a move: only where the text is on top.
        if onText { super.mouseMoved(with: event) }
        setPointer(onText: onText, at: point)
        controller?.hover(atViewPoint: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setPointer(onText: false, at: .zero)
        controller?.hover(atViewPoint: nil)
    }

    // Window hit testing keeps the text cursor beneath overlaid panes and cards.
    override func resetCursorRects() {}

    override func cursorUpdate(with event: NSEvent) {
        setPointer(onText: textIsOnTop(event), at: convert(event.locationInWindow, from: nil))
    }

    /// Whether the pointer showing is the text's: the arrow goes back once, when the pointer leaves the text, and never over a pane's own.
    private var showsTextPointer = false

    private func setPointer(onText: Bool, at point: NSPoint) {
        guard onText else {
            if showsTextPointer { NSCursor.arrow.set() }
            showsTextPointer = false
            return
        }
        showsTextPointer = true
        (linkIsUnder(point) ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    /// The window's hit test lands on this view's own text: not a block's hosted view, a pane, a card or a bar drawn over it.
    private func textIsOnTop(_ event: NSEvent) -> Bool {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return false }
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = root.hitTest(point), hit.isDescendant(of: self) else { return false }
        return controller?.attachments.hosts(hit) != true
    }

    /// A link is drawn under the point: the character under it, read from its line through TextKit 2.
    private func linkIsUnder(_ point: NSPoint) -> Bool {
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = textLayoutManager?.textLayoutFragment(for: inContainer) else { return false }
        let frame = fragment.layoutFragmentFrame
        let inFragment = CGPoint(x: inContainer.x - frame.minX, y: inContainer.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(inFragment) }) else { return false }
        let inLine = CGPoint(x: inFragment.x - line.typographicBounds.minX, y: inFragment.y - line.typographicBounds.minY)
        // The index is the caret nearest the point; the character under the point is the one before it when the caret sits right of the point.
        var index = line.characterIndex(for: inLine)
        if index > line.characterRange.location, line.locationForCharacter(at: index).x > inLine.x { index -= 1 }
        guard index >= 0, index < line.attributedString.length else { return false }
        return line.attributedString.attribute(.link, at: index, effectiveRange: nil) != nil
    }

    /// A click on a fold's headline opens or closes it; everything else selects as text does.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let controller, controller.toggleFold(atViewPoint: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    override func autoscroll(with event: NSEvent) -> Bool {
        guard let controller else { return super.autoscroll(with: event) }
        return controller.readerMove(onlyIfScrolled: true) { super.autoscroll(with: event) }
    }

    /// Find's incremental search and its own buttons reveal through this NSTextFinderClient entry.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let controller else { super.scrollRangeToVisible(range); return }
        controller.readerMove { super.scrollRangeToVisible(range) }
    }

    // MARK: Keys

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = NSTextFinder.Action(rawValue: item.tag), let controller else {
            super.performTextFinderAction(sender)
            return
        }
        controller.find(action)
    }

    func findInCompleteDocument(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        super.performTextFinderAction(item)
    }

    override func selectAll(_ sender: Any?) {
        guard let controller else { super.selectAll(sender); return }
        controller.withCompleteDocument { [weak self] in self?.selectCompleteDocument() }
    }

    private func selectCompleteDocument() { super.selectAll(nil) }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        guard let controller else { super.scrollToBeginningOfDocument(sender); return }
        controller.withCompleteDocument { [weak self] in self?.scrollToCompleteBeginning() }
    }

    private func scrollToCompleteBeginning() {
        guard let controller else { super.scrollToBeginningOfDocument(nil); return }
        controller.readerMove { super.scrollToBeginningOfDocument(nil) }
    }

    override func moveToBeginningOfDocument(_ sender: Any?) {
        guard let controller else { super.moveToBeginningOfDocument(sender); return }
        controller.withCompleteDocument { [weak self] in self?.moveToCompleteBeginning(selecting: false) }
    }

    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        guard let controller else { super.moveToBeginningOfDocumentAndModifySelection(sender); return }
        controller.withCompleteDocument { [weak self] in self?.moveToCompleteBeginning(selecting: true) }
    }

    private func moveToCompleteBeginning(selecting: Bool) {
        guard let controller else { return }
        controller.readerMove {
            if selecting { super.moveToBeginningOfDocumentAndModifySelection(nil) }
            else { super.moveToBeginningOfDocument(nil) }
        }
    }

    override func copy(_ sender: Any?) {
        guard let controller, controller.hasPendingDocumentCommand else { super.copy(sender); return }
        controller.withCompleteDocument { [weak self] in self?.copyCompleteSelection() }
    }

    private func copyCompleteSelection() { super.copy(nil) }

    override func keyDown(with event: NSEvent) {
        guard let controller else { super.keyDown(with: event); return }
        controller.readerMove(onlyIfScrolled: true) { super.keyDown(with: event) }
    }

    /// ⌘+ and ⌘− size the transcript's text from anywhere in this window, as a document's text size does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function, .shift])
        if modifiers == .command, event.window === window, controller?.isActive == true {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                TranscriptTextScale.nudge(1)
                return true
            case "-":
                TranscriptTextScale.nudge(-1)
                return true
            default:
                break
            }
        }
        guard let controller else { return super.performKeyEquivalent(with: event) }
        return controller.readerMove(onlyIfScrolled: true) { super.performKeyEquivalent(with: event) }
    }

    // MARK: One menu: ours on top, then the system's (Look Up, Translate, Services, Writing Tools, Share)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let controller else { return menu }
        let target = controller.menuTarget(atViewPoint: convert(event.locationInWindow, from: nil))
        var ours: [NSMenuItem] = []
        func add(_ title: String, _ symbol: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.representedObject = target
            ours.append(item)
        }
        if target?.codeBlockID != nil { add("Copy code", "doc.on.doc", #selector(copyCode(_:))) }
        let message = target?.message
        add("Copy message", "doc.on.doc", #selector(copyMessage(_:)), enabled: message != nil)
        add("Copy as Markdown", "doc.richtext", #selector(copyAsMarkdown(_:)), enabled: message != nil || selectedRange().length > 0)
        if let message, message.role != "user" {
            let reading = controller.isReading(message)
            add(reading ? "Stop reading" : "Read aloud", reading ? "speaker.slash" : "speaker.wave.2",
                reading ? #selector(stopReading(_:)) : #selector(readAloud(_:)))
        }
        if let message, controller.canRegenerate(message) {
            add("Regenerate response", "arrow.clockwise", #selector(regenerate(_:)))
        }
        if message != nil {
            ours.append(.separator())
            add("Remember this", "brain", #selector(rememberThis(_:)), enabled: message?.action?.canRemember == true)
            add("Show message data", "curlybraces", #selector(showMessageData(_:)))
        }
        for (offset, item) in ours.enumerated() { menu.insertItem(item, at: offset) }
        menu.insertItem(.separator(), at: ours.count)
        return menu
    }

    private func target(_ sender: Any?) -> TranscriptMenuTarget? {
        (sender as? NSMenuItem)?.representedObject as? TranscriptMenuTarget
    }

    @objc func copyCode(_ sender: Any?) {
        guard let blockID = target(sender)?.codeBlockID else { return }
        controller?.copyCode(blockID)
    }

    @objc func copyMessage(_ sender: Any?) {
        guard let id = target(sender)?.message?.id else { return }
        controller?.copyMessage(id)
    }

    /// With a selection: the markdown source of the selected blocks, through `writeSelection(to:type:)`. Without one: the whole message.
    @objc func copyAsMarkdown(_ sender: Any?) {
        if let controller, controller.hasPendingDocumentCommand {
            controller.withCompleteDocument { [weak self] in self?.copyAsMarkdown(sender) }
            return
        }
        if selectedRange().length > 0 {
            writesMarkdownAsString = true
            defer { writesMarkdownAsString = false }
            let copied = writeSelection(to: .general, types: [.string, Self.markdownType])
            controller?.showToast(copied ? "Copied as Markdown" : "Could not write the selection to the clipboard.")
        } else if let id = target(sender)?.message?.id {
            controller?.copyMarkdown(id)
        }
    }

    @objc func readAloud(_ sender: Any?) {
        guard let id = target(sender)?.message?.id else { return }
        controller?.readAloud(id)
    }

    @objc func stopReading(_ sender: Any?) { controller?.stopReading() }

    @objc func regenerate(_ sender: Any?) {
        guard let id = target(sender)?.message?.id else { return }
        controller?.regenerate(id)
    }

    @objc func rememberThis(_ sender: Any?) {
        guard let id = target(sender)?.message?.id else { return }
        controller?.remember(id)
    }

    @objc func showMessageData(_ sender: Any?) {
        guard let id = target(sender)?.message?.id else { return }
        controller?.showData(id)
    }

    // MARK: Pasteboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes + [Self.markdownType]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.markdownType || (type == .string && writesMarkdownAsString) else {
            return super.writeSelection(to: pboard, type: type)
        }
        guard let controller, let markdown = controller.text(for: selectedRanges.map(\.rangeValue), markdown: true) else { return false }
        return pboard.setString(markdown, forType: type)
    }
}

/// What a right-click landed on: the message it answers to, and the code block when it was one.
final class TranscriptMenuTarget: NSObject {
    let message: TranscriptMessageReference?
    let codeBlockID: String?

    init(message: TranscriptMessageReference?, codeBlockID: String?) {
        self.message = message
        self.codeBlockID = codeBlockID
    }
}

/// The transcript fades in over its top 24 pt below the find bar, and out above the composer glass, so no text shows under it.
final class TranscriptDocumentScrollView: NSScrollView {
    weak var controller: TranscriptDocumentController?
    private let fade = CAGradientLayer()

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { super.scrollWheel(with: event); return }
        controller.readerMove(onlyIfScrolled: true) { super.scrollWheel(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { super.keyDown(with: event); return }
        controller.readerMove(onlyIfScrolled: true) { super.keyDown(with: event) }
    }

    override func tile() {
        super.tile()
        updateFade()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.liveResizeEnded()
    }

    override func layout() {
        super.layout()
        updateFade()
        controller?.scrollViewDidLayout()
    }

    func updateFade() {
        if !wantsLayer { wantsLayer = true }
        guard let layer else { return }
        if layer.mask !== fade { layer.mask = fade }
        let bar = isFindBarVisible ? (findBarView?.frame.height ?? 0) : 0
        let height = max(1, bounds.height)
        let top = min(1, bar / height)
        let clearUntil = min(1, (bar + contentInsets.top) / height)
        let opaqueFrom = min(1, (bar + contentInsets.top + TranscriptMetrics.topFade) / height)
        // Only a transcript that runs under a composer fades at the bottom; one that ends above its host's edge shows every line.
        let underComposer = contentInsets.bottom > 0
        let fadeFrom = underComposer ? min(1, max(opaqueFrom, 1 - contentInsets.bottom / height)) : 1
        let fadeTo = underComposer
            ? min(1, max(fadeFrom, 1 - max(0, contentInsets.bottom - TranscriptMetrics.bottomFade) / height)) : 1
        let locations: [NSNumber] = [0, NSNumber(value: Double(max(0, top - 0.0001))), NSNumber(value: Double(top)),
            NSNumber(value: Double(clearUntil)), NSNumber(value: Double(opaqueFrom)), NSNumber(value: Double(fadeFrom)),
            NSNumber(value: Double(fadeTo)), 1]
        // Unit space follows the layer's flippedness; the fade always starts at the visual top.
        let flipped = layer.contentsAreFlipped()
        let start = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        let end = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        guard fade.frame != layer.bounds || fade.locations != locations || fade.startPoint != start || fade.endPoint != end else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer.bounds
        if fade.colors == nil {
            let opaque = NSColor.black.cgColor, clear = NSColor.clear.cgColor
            fade.colors = [opaque, opaque, clear, clear, opaque, opaque, clear, clear]
        }
        fade.locations = locations
        fade.startPoint = start
        fade.endPoint = end
        CATransaction.commit()
    }
}
