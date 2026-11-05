import AppKit
import EngineRuntime
import QuartzCore

// Blueprint: | `TranscriptTextView.swift` | The one NSTextView (TextKit 2) and its scroll view: menu, pasteboard, keys, hover, folds and the soft edges |

/// The one text view. Nothing here or in the controller reads `.layoutManager`: that silently drops the view to TextKit 1.
final class TranscriptTextView: NSTextView {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    weak var controller: TranscriptDocumentController?
    private var writesMarkdownAsString = false
    private var hoverArea: NSTrackingArea?

    /// The container is the column (or the whole width when narrower); the inset centres it in whatever width the view has.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // An unsized view keeps the column it has; laying the document out at zero width would only be thrown away.
        guard newSize.width > 0 else { return }
        let column = min(TranscriptMetrics.column, newSize.width)
        let inset = NSSize(width: max(0, floor((newSize.width - column) / 2)), height: TranscriptMetrics.documentInset)
        if textContainerInset != inset { textContainerInset = inset }
        guard let container = textContainer, container.size.width != column else { return }
        let resize = { container.size = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude) }
        if let controller { controller.changeContainerWidth(column, resize) } else { resize() }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// TextKit lays the viewport out here (and on scroll in prepareContent); hosted views follow their paragraphs after each pass.
    override func layout() {
        super.layout()
        controller?.placeHostedViews()
    }

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        controller?.placeHostedViews()
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

    // AppKit's cursor rects ignore whatever is drawn over a view, so a pane or card over the transcript showed the text cursor.
    // The text's pointer is set from the window's hit test instead: the I-beam, or a link's hand, only where the text itself is on top.
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

    // MARK: Keys

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
        return super.performKeyEquivalent(with: event)
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
            add(reading ? "Stop reading" : "Read aloud", reading ? "speaker.slash" : "speaker.wave.2", #selector(readAloud(_:)))
        }
        if let message, controller.canRegenerate(message) {
            add("Regenerate response", "arrow.clockwise", #selector(regenerate(_:)))
        }
        if message != nil {
            ours.append(.separator())
            add("Remember this", "brain", #selector(rememberThis(_:)))
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
        if selectedRange().length > 0 {
            writesMarkdownAsString = true
            defer { writesMarkdownAsString = false }
            _ = writeSelection(to: .general, types: [.string, Self.markdownType])
            controller?.showToast("Copied as Markdown")
        } else if let id = target(sender)?.message?.id {
            controller?.copyMarkdown(id)
        }
    }

    @objc func readAloud(_ sender: Any?) {
        guard let id = target(sender)?.message?.id else { return }
        controller?.toggleReadAloud(id)
    }

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
    let message: ChatMessage?
    let codeBlockID: String?

    init(message: ChatMessage?, codeBlockID: String?) {
        self.message = message
        self.codeBlockID = codeBlockID
    }
}

/// The transcript fades in over its top 24 pt below the find bar, and out above the composer glass, so no text shows under it.
final class TranscriptDocumentScrollView: NSScrollView {
    weak var controller: TranscriptDocumentController?
    private let fade = CAGradientLayer()

    override func tile() {
        super.tile()
        updateFade()
    }

    /// The reader's own scroll decides whether they follow the end.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        controller?.readerScrolled()
    }

    override func layout() {
        super.layout()
        updateFade()
        controller?.scrollViewDidLayout()
    }

    func updateFade() {
        wantsLayer = true
        guard let layer else { return }
        if layer.mask !== fade { layer.mask = fade }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer.bounds
        let height = max(1, bounds.height)
        let bar = isFindBarVisible ? (findBarView?.frame.height ?? 0) : 0
        let top = min(1, bar / height)
        let clearUntil = min(1, (bar + contentInsets.top) / height)
        let opaqueFrom = min(1, (bar + contentInsets.top + TranscriptMetrics.topFade) / height)
        // Only a transcript that runs under a composer fades at the bottom; one that ends above its host's edge shows every line.
        let underComposer = contentInsets.bottom > 0
        let fadeFrom = underComposer ? min(1, max(opaqueFrom, 1 - contentInsets.bottom / height)) : 1
        let fadeTo = underComposer
            ? min(1, max(fadeFrom, 1 - max(0, contentInsets.bottom - TranscriptMetrics.bottomFade) / height)) : 1
        let opaque = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        fade.colors = [opaque, opaque, clear, clear, opaque, opaque, clear, clear]
        fade.locations = [0, NSNumber(value: Double(max(0, top - 0.0001))), NSNumber(value: Double(top)), NSNumber(value: Double(clearUntil)),
                          NSNumber(value: Double(opaqueFrom)), NSNumber(value: Double(fadeFrom)), NSNumber(value: Double(fadeTo)), 1]
        // Unit space follows the layer's flippedness; the fade always starts at the visual top.
        let flipped = layer.contentsAreFlipped()
        fade.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        fade.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        CATransaction.commit()
    }
}
