import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ComposerShellState.swift` | Mounted menus, context receipt, Trust confirmation and ordered composer control requests |

/// Quiet reads must use the person's open menu.
struct ComposerShellRow: Identifiable, Hashable {
    let id: String
    let label: String
    let isSelected: Bool
}

@MainActor
@Observable
final class ComposerShellState {
    var activePane: ChatComposerCard?
    var fullMacConfirmationSession: String?
    var controlCommands: [ComposerControlCommand] = []
    var controlIssues: [ComposerControlCommand.Issue] = []
    var savingChoice: Bool { controlCommands.contains { $0.operation.savesChoice } }
    var savingTrust: Bool {
        controlCommands.contains {
            if case .trust = $0.operation { return true }
            return false
        }
    }
    @ObservationIgnored private weak var contextModel: AppModel?
    private var contextSession: String?
    var contextReceipt: ContextReceiptFace? {
        guard let contextModel, let contextSession else { return nil }
        return contextModel.face.slot(.contextReceipt(session: contextSession)).value(as: ContextReceiptFace.self)
    }
    func bindContext(session: String, appModel: AppModel) {
        contextModel = appModel
        contextSession = session
    }
    @ObservationIgnored private var menu: NSMenu?
    @ObservationIgnored private var anchors: [ChatComposerCard: WeakAnchor] = [:]
    private final class WeakAnchor {
        weak var view: ComposerMenuAnchor.AnchorView?
        init(_ view: ComposerMenuAnchor.AnchorView) { self.view = view }
    }
    fileprivate func register(_ view: ComposerMenuAnchor.AnchorView, for card: ChatComposerCard) {
        anchors[card] = WeakAnchor(view)
    }
    fileprivate func unregister(_ view: ComposerMenuAnchor.AnchorView, for card: ChatComposerCard) {
        if anchors[card]?.view === view { anchors.removeValue(forKey: card) }
    }
    @discardableResult
    func open(_ card: ChatComposerCard) -> Bool {
        guard let anchor = anchors[card]?.view, anchor.window != nil else { return false }
        if activePane == card { return true }
        if card == .context {
            dismiss()
            activePane = .context
            return true
        }
        guard let nativeMenu = anchor.build?() else { return false }
        dismiss()
        menu = nativeMenu
        activePane = card
        // Return the quiet command before native menu tracking blocks.
        DispatchQueue.main.async { [weak self, weak anchor] in
            guard let self, let anchor, self.menu === nativeMenu else { return }
            nativeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
            if self.menu === nativeMenu { self.dismiss() }
        }
        return true
    }
    func dismiss() {
        menu?.cancelTracking()
        menu = nil
        activePane = nil
    }
    var rows: [ComposerShellRow] {
        if activePane == .context {
            return contextReceipt?.rows.map {
                ComposerShellRow(id: $0.id, label: $0.title + ($0.detail.map { " — " + $0 } ?? ""), isSelected: false)
            } ?? []
        }
        func rows(in menu: NSMenu, path: String = "") -> [ComposerShellRow] {
            menu.items.filter { !$0.isSeparatorItem }.flatMap { item -> [ComposerShellRow] in
                let label = path + item.title + (item.subtitle.map { " — " + $0 } ?? "")
                if let submenu = item.submenu { return rows(in: submenu, path: label + " → ") }
                return [ComposerShellRow(id: item.identifier?.rawValue ?? label,
                                         label: label, isSelected: item.state == .on)]
            }
        }
        return menu.map { rows(in: $0) } ?? []
    }
    var paneReadLine: String {
        switch activePane {
        case .none: "No composer pane is open."
        case .model: "Model menu is open."
        case .effort: "Thinking menu is open."
        case .trust: "Trust menu is open."
        case .context: "Context pane is open."
        }
    }

    func enqueueControl(_ operation: ComposerControlCommand.Operation, session: String) {
        dismiss()
        controlCommands.append(.init(session: session, operation: operation))
    }

    func endControls() {
        dismiss()
        fullMacConfirmationSession = nil
        controlCommands.removeAll()
        controlIssues.removeAll()
    }

    func applyTrust(_ preset: MobileTrustAction.Preset, session: String, confirmed: Bool = false) {
        guard !savingTrust else { return }
        if preset == .fullMac, !confirmed {
            fullMacConfirmationSession = session
            return
        }
        enqueueControl(.trust(preset, confirmed: confirmed), session: session)
    }
}

struct ComposerMenuAnchor: NSViewRepresentable {
    let card: ChatComposerCard
    let state: ComposerShellState?
    var live: Bool
    let build: @MainActor () -> NSMenu
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        if let previous = view.card { view.state?.unregister(view, for: previous) }
        view.build = build
        view.card = card
        view.state = live ? state : nil
        view.state?.register(view, for: card)
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        if let card = view.card { view.state?.unregister(view, for: card) }
    }
    final class AnchorView: NSView {
        weak var state: ComposerShellState?
        var card: ChatComposerCard?
        var build: (@MainActor () -> NSMenu)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
private final class ComposerMenuAction: NSObject {
    let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    @objc func take() { perform() }
}

@MainActor
func composerMenuItem(_ id: String, _ title: String, selected: Bool = false,
                      enabled: Bool = true, perform: @escaping @MainActor () -> Void) -> NSMenuItem {
    let target = ComposerMenuAction(perform)
    let item = NSMenuItem(title: title, action: #selector(ComposerMenuAction.take), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.identifier = NSUserInterfaceItemIdentifier(id)
    item.state = selected ? .on : .off
    item.isEnabled = enabled
    return item
}
