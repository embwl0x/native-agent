import Foundation
import SwiftUI
import AppKit
import Observation
import TrustCenter
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import BackgroundLoops
import PersonaEngine
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import StandingBots
import ApprovalInbox
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `ComposerShellState.swift` | Mounted native menu tracking, context receipt and Trust confirmation state; quiet reads use the open menu |

/// Quiet reads use the very menu the person opened.
struct ComposerShellRow: Identifiable, Hashable {
    let id: String
    let label: String
    let isSelected: Bool
}

@MainActor
@Observable
final class ComposerShellState {
    var activePane: ChatComposerCard?
    var savingTrust = false
    var confirmingFullMac = false
    var trustError: String?
    var contextReceipt: ComposerContextReceiptState = .loading
    @ObservationIgnored let contextReceiptRead = LatestRead()
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
        // Let a quiet command return before native menu tracking begins.
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
            return ComposerContextReceiptPresentation.lines(contextReceipt).map {
                ComposerShellRow(id: $0.id, label: $0.label, isSelected: false)
            }
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

    func applyTrust(_ preset: MobileTrustAction.Preset, appModel: AppModel, confirmed: Bool = false) {
        guard !savingTrust else { return }
        if preset == .fullMac, !confirmed {
            confirmingFullMac = true
            return
        }
        dismiss()
        savingTrust = true
        Task { @MainActor in
            let outcome = await TrustPolicyPresetAction.apply(
                preset, appModel: appModel, fullMacConfirmed: confirmed
            )
            savingTrust = false
            appModel.statusText = TrustPolicyPresetActionPresentation.statusText(for: outcome)
            switch outcome {
            case .confirmationRequired: confirmingFullMac = true
            case .failed(let reason): trustError = reason
            case .applied: break
            }
        }
    }
}

/// The word supplies an anchor and menu. AppKit owns tracking, submenus,
/// keyboard navigation, scrolling and edge placement.
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
final class ComposerMenuItem: NSMenuItem {
    private let perform: @MainActor () -> Void
    init(_ id: String, _ title: String, selected: Bool = false,
         enabled: Bool = true, perform: @escaping @MainActor () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(take), keyEquivalent: "")
        target = self
        identifier = NSUserInterfaceItemIdentifier(id)
        state = selected ? .on : .off
        isEnabled = enabled
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func take() { perform() }
}
