import AppKit
import NativeAgentShared
// Blueprint: | `FaceComposerFocus.swift` | Exact mounted native composer identification and confirmed first-responder focus |

@MainActor
enum FaceComposerFocus {
    static func identifier(session: String, active: Bool = true) -> String {
        (active ? "face.composer." : "face.inactive-composer.") + session
    }

    static func focus(session: String, detached: Bool) -> FaceReply {
        let identifier = identifier(session: session)
        var targets: [(NSWindow, NSView)] = []
        var seen: Set<ObjectIdentifier> = []
        for window in NSApp.windows {
            if detached {
                guard (window as? DetachedChatPanel)?.sessionId == session else { continue }
            } else if window is DetachedChatPanel { continue }
            guard let root = window.contentView else { continue }
            for target in identifiedEditors(in: root, identifier: identifier) where seen.insert(ObjectIdentifier(target)).inserted {
                targets.append((window, target))
            }
        }
        guard targets.count == 1, let (window, target) = targets.first else {
            return .refused(.init(code: "composer_native_target_unavailable",
                message: targets.isEmpty ? "This conversation's native composer is not mounted." : "This conversation has multiple native composer targets.",
                cause: nil, effects: .none))
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard window.makeFirstResponder(target), window.isKeyWindow, ownsResponder(target, in: window) else {
            return .failed(.init(code: "composer_focus_rejected", message: "macOS did not focus this conversation's native composer.",
                                 cause: "The target did not become the key window's first responder.", effects: .known))
        }
        return .acknowledged
    }

    private static func identifiedEditors(in view: NSView, identifier: String) -> [NSView] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        if view.accessibilityIdentifier() == identifier { return editableControls(in: view) }
        return view.subviews.flatMap { identifiedEditors(in: $0, identifier: identifier) }
    }

    private static func editableControls(in view: NSView) -> [NSView] {
        if let field = view as? NSTextField { return field.isEditable && field.isEnabled ? [field] : [] }
        if let text = view as? NSTextView { return text.isEditable ? [text] : [] }
        return view.subviews.flatMap { editableControls(in: $0) }
    }

    private static func ownsResponder(_ target: NSView, in window: NSWindow) -> Bool {
        if let field = target as? NSTextField, let editor = field.currentEditor() { return window.firstResponder === editor }
        return window.firstResponder === target
    }
}
