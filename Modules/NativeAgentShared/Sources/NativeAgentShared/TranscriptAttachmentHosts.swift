import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
public typealias TranscriptPlatformView = NSView
public typealias TranscriptHostingController<Root: View> = NSHostingController<Root>
#else
import UIKit
public typealias TranscriptPlatformView = UIView
public typealias TranscriptHostingController<Root: View> = UIHostingController<Root>
#endif

// Blueprint: | `TranscriptAttachmentHosts.swift` | `TranscriptAttachmentHosts`, `TranscriptAttachmentFrame`: one retained hosted view per attachment block, measured at the column width and placed over its paragraph, and the self-measuring root it draws in |

/// One retained hosted view per attachment block. The same block id keeps its view while the block lives; a view is measured at the
/// column width before TextKit first lays its paragraph out, measured again whenever it changes size, and placed over its paragraph's
/// laid-out frame. Each platform's subclass makes the box and host a block draws in and keeps the data they read.
@MainActor
open class TranscriptAttachmentHosts<Box: AnyObject, Root: View> {
    public typealias Host = TranscriptHostingController<Root>

    public final class Entry {
        public var ref: TranscriptAttachmentRef
        public let role: String
        public let box: Box
        public let host: Host
        public let attachment: TranscriptAttachment

        init(ref: TranscriptAttachmentRef, role: String, box: Box, host: Host, attachment: TranscriptAttachment) {
            self.ref = ref
            self.role = role
            self.box = box
            self.host = host
            self.attachment = attachment
        }
    }

    /// Set by the reader. Called when a hosted view's height changes; the reader re-lays that block's paragraph.
    public var heightChanged: (_ blockID: String) -> Void = { _ in }
    public private(set) var columnWidth: CGFloat = 0
    private var entries: [String: Entry] = [:]
    /// Blocks whose size must be read again; read together on the next main-actor turn, outside any layout pass.
    private var pending: Set<String> = []
    private var measureScheduled = false

    public init() {}

    /// The same block id returns the same attachment while the block lives. A growing reply can change what its block shows (a table
    /// gains rows) under the same id: `rebind` points the live box at it. `make` builds a new block's box and host, given the call that
    /// measures it again.
    public func retained(blockID: String, ref: TranscriptAttachmentRef, role: String, rebind: (Box) -> Void,
                         make: (_ resized: @escaping () -> Void) -> (box: Box, host: Host)) -> NSTextAttachment {
        if let entry = entries[blockID] {
            if entry.ref != ref {
                entry.ref = ref
                rebind(entry.box)
                remeasure(blockID)
            }
            return entry.attachment
        }
        let made = make { [weak self] in self?.remeasure(blockID) }
        let entry = Entry(ref: ref, role: role, box: made.box, host: made.host, attachment: TranscriptAttachment(blockID: blockID))
        entries[blockID] = entry
        // Sized before TextKit first lays the paragraph out, so the first layout is the right one.
        measure(entry)
        return entry.attachment
    }

    /// A fresh column width before every document edit. `refresh` brings one live box up to date and says whether what it shows changed.
    public func refresh(columnWidth: CGFloat, _ refresh: (_ entry: Entry, _ blockID: String) -> Bool) {
        let resized = columnWidth != self.columnWidth
        self.columnWidth = columnWidth
        for (blockID, entry) in entries {
            if refresh(entry, blockID) {
                remeasure(blockID)
            } else if resized {
                remeasure(blockID)
            }
        }
    }

    /// While the window is being dragged, the hosts on screen follow the column as it moves; the stored width stays the last settled one, so the
    /// one full measure when the drag ends still reaches every host.
    public func follow(columnWidth: CGFloat) {
        guard columnWidth > 0 else { return }
        for (blockID, entry) in entries {
#if canImport(AppKit)
            let view: TranscriptPlatformView? = entry.host.view
#else
            let view = entry.host.viewIfLoaded
#endif
            guard let view, view.superview != nil, !view.isHidden else { continue }
            if measure(entry, width: columnWidth) { heightChanged(blockID) }
        }
    }

    /// Whether a view is a block's hosted view or inside one: its own controls take the pointer or the touch, not the document.
    public func hosts(_ view: TranscriptPlatformView?) -> Bool {
        guard let view else { return false }
        return entries.values.contains { view.isDescendant(of: $0.host.view) }
    }

    /// Blocks gone from the document.
    public func forget(_ blockIDs: Set<String>) {
        for blockID in blockIDs {
#if canImport(AppKit)
            entries[blockID]?.host.view.removeFromSuperview()
            entries[blockID] = nil
#else
            guard let entry = entries.removeValue(forKey: blockID) else { continue }
            entry.host.willMove(toParent: nil)
            entry.host.view.removeFromSuperview()
            entry.host.removeFromParent()
#endif
        }
        pending.subtract(blockIDs)
    }

    /// Place retained hosts at their laid-out attachment frames; hide hosts outside layout. On the phone a host is also a child of the
    /// text view's controller, which is what lets its controls present sheets.
    public func place(_ frames: [String: CGRect], in textView: TranscriptPlatformView) {
        for (blockID, entry) in entries {
#if canImport(AppKit)
            let view = entry.host.view
#else
            guard let view = entry.host.view else { continue }
#endif
            guard let frame = frames[blockID] else {
                if view.superview != nil, !view.isHidden { view.isHidden = true }
                continue
            }
            if view.superview !== textView {
#if canImport(AppKit)
                textView.addSubview(view)
#else
                if let parent = Self.viewController(of: textView), entry.host.parent !== parent {
                    entry.host.willMove(toParent: nil)
                    entry.host.removeFromParent()
                    parent.addChild(entry.host)
                    textView.addSubview(view)
                    entry.host.didMove(toParent: parent)
                } else {
                    textView.addSubview(view)
                }
#endif
            }
            if view.frame != frame { view.frame = frame }
            if view.isHidden { view.isHidden = false }
        }
    }

#if !canImport(AppKit)
    private static func viewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
#endif

    private func remeasure(_ blockID: String) {
        pending.insert(blockID)
        guard !measureScheduled else { return }
        measureScheduled = true
        Task { @MainActor [weak self] in self?.measurePending() }
    }

    private func measurePending() {
        measureScheduled = false
        let blockIDs = pending
        pending = []
        for blockID in blockIDs {
            guard let entry = entries[blockID], measure(entry) else { continue }
            heightChanged(blockID)
        }
    }

    /// The hosted view's fitting size at the column width: its own width up to the column (so paragraph alignment can seat it)
    /// and its whole height. Returns whether the size changed. Before the reader gives a column width there is nothing to fit.
    @discardableResult
    private func measure(_ entry: Entry, width: CGFloat? = nil) -> Bool {
        let columnWidth = width ?? self.columnWidth
        guard columnWidth > 0 else { return false }
        let fit = entry.host.sizeThatFits(in: CGSize(width: columnWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(fit.width.rounded(.up), columnWidth), height: fit.height.rounded(.up))
        guard size != entry.attachment.bounds.size else { return false }
        entry.attachment.bounds = CGRect(origin: .zero, size: size)
        return true
    }
}

/// What a hosted block draws in: it grows to its whole height at the width it is given and reports every size change, so the
/// document re-lays its paragraph (a card answered, details opened, an image loaded).
public struct TranscriptAttachmentFrame<Content: View>: View {
    private let resized: () -> Void
    private let content: Content

    public init(resized: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.resized = resized
        self.content = content()
    }

    public var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in resized() }
    }
}
