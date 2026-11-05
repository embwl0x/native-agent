import Foundation
import SwiftUI
import AppKit
import EngineRuntime
import AppToolRuntime
import NativeAgentShared
import TrustCenter
import MacControl
import ProviderRouting
import Transcripts
import Desk
import MultimodalTTS
import ChatToolRuntime
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatComposerSettings.swift` | Native composer menus and context receipt: keyboard access and shared routing/actions |

enum ChatComposerCard: String, Hashable, CaseIterable {
    case model, effort = "think", trust, context
}

struct ComposerSessionRefresh: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let sessionID: String
    var live = true

    func body(content: Content) -> some View {
        content.quietReadTask(id: "\(sessionID):\(live)") {
            if quietOffscreenRead { await appModel.engine.providers.refreshSession(sessionID) }
            else if live { await appModel.engine.providers.observeSession(sessionID) }
        }
    }
}

/// Observe routing and policy here so changes do not invalidate draft or transcript owners.
struct ChatComposerSettings: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(ComposerShellState.self) var cardState: ComposerShellState?

    private var routing: QuietComposerCommands.Routing { .init(appModel: appModel) }

    var focusWordToken: Int
    /// Show hand-back only when it can act.
    @State private var handoffWouldChange = false
    @State private var handoffProblem: String?
    @AppStorage(ShotgunController.enabledKey) private var shotgunEnabled = true

    @FocusState private var focusedWord: ChatComposerCard?

    init(focusWordToken: Int = 0) {
        self.focusWordToken = focusWordToken
    }

    /// Walk the local Tab ring because window-wide ordering skips plain buttons; hand focus back at either end.
    private static let ring: [ChatComposerCard] = [.context, .model, .effort, .trust]

    var body: some View {
        HStack(spacing: 0) {
            if let handoffProblem {
                Image(systemName: "exclamationmark.triangle")
                    .help(handoffProblem)
                    .accessibilityLabel(handoffProblem)
                    .padding(.trailing, 12)
            }
            // Offer hand-back only below Full Mac when a Mac action needs the driver held by the user.
            if handoffWouldChange {
                Button("Let \(appModel.agentDisplayName) use the Mac") {
                    guard let generation = MacAttentionSessionStore.shared.userHandoffGeneration() else { return }
                    Task { await MacAttentionSessionStore.shared.giveAgentControl(userGeneration: generation) }
                }
                .buttonStyle(.plain)
                .font(ShellType.label)
                .padding(.trailing, 12)
                .help("Your mouse or keyboard took the Mac back. Control stays yours until you hand it back here.")
            }
            // Move this window aside while the agent drives so it does not obstruct the target.
            Toggle("Shotgun", isOn: $shotgunEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text.opacity(0.85))
                .help("""
                    On: when I start driving the Mac, this window steps aside into Shotgun, a small chat you can keep typing in. Off: I work in the \
                    background and this window stays put. Its shortcut (Settings) or View ▸ Show Shotgun shows it either way.
                    """)
                .accessibilityIdentifier("chat.composer.shotgun")
            Spacer(minLength: 0)

            // Keep Fast first in the trailing cluster so other controls stay fixed.
            if routing.fastIsOn {
                Button {
                    guard let presentation = routing.presentation else { return }
                    if presentation.contract != nil {
                        NotificationCenter.default.post(name: .openCommandRouteRequest, object: "bots")
                        return
                    }
                    appModel.chatFastMode = false
                    appModel.enqueueChatBrainDefaultsSave()
                } label: {
                    Text("Fast")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(NativeAgentShell.softFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help(routing.isBotConversation ? "Fast is on for this helper. Tell me in chat to change it." : "Fast is on. Click to turn it off.")
                .accessibilityIdentifier("chat.composer.fast")
                .accessibilityLabel("Fast is on")
                .accessibilityHint(routing.isBotConversation ? "Opens Helpers" : "Turns Fast off")
            }

            // Keep the last assembled context receipt reachable from its usage ring.
            contextRing

            separator

            modelMenuWord
            // Cap width at the name and 220pt so the ring cannot drift into the middle of the bar.
            .frame(maxWidth: 220, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)

            separator

            if routing.isBotConversation {
                word(
                    .effort,
                    text: routing.effortWord,
                    help: "This conversation uses its helper's thinking level. Tell me in chat to change it.",
                    accessibility: "Helper thinking: \(routing.effortWord). Tell me in chat to change it",
                    identifier: "chat.composer.effort"
                )
            } else {
                nativeMenuWord(.effort, text: routing.effortWord,
                               help: "How much thinking \(appModel.agentDisplayName) spends on a turn.",
                               identifier: "chat.composer.effort")
            }

            separator

            nativeMenuWord(.trust, text: routing.trustWord,
                           help: "Your saved permissions, used throughout the app.",
                           identifier: "chat.composer.trust")

        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .font(ShellType.label)
        .foregroundStyle(NativeAgentShell.text.opacity(0.85))

        .task { await appModel.loadProvidersForChat() }
        // Re-read after driver or posture changes so hand-back availability remains current.
        .task(id: routing.activeTrustPreset) {
            for await _ in await MacAttentionSessionStore.shared.driverChanges() {
                do {
                    handoffWouldChange = try await MacAttentionSessionStore.shared.handoffWouldChange()
                    handoffProblem = nil
                } catch {
                    handoffWouldChange = false
                    handoffProblem = error.localizedDescription
                }
            }
        }
        .modifier(ComposerSessionRefresh(sessionID: appModel.activeChatSessionId, live: chatPageIsVisible))
        .onChange(of: focusWordToken) { _, _ in focusedWord = .model }
        .alert("Enable Full Mac access?", isPresented: Binding(
            get: { cardState?.confirmingFullMac == true },
            set: { cardState?.confirmingFullMac = $0 }
        )) {
            Button("Enable Full Mac", role: .destructive) {
                cardState?.applyTrust(.fullMac, appModel: appModel, confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                I can read and change files anywhere, run commands, control your Mac, and move files or put them in the Trash. I can act on my own, and \
                files are backed up before changes. macOS privacy permissions still apply. This stays active until you change Trust.
                """)
        }
        .alert("Trust could not be changed", isPresented: Binding(
            get: { cardState?.trustError != nil },
            set: { if !$0 { cardState?.trustError = nil } }
        )) {
            Button("OK") { cardState?.trustError = nil }
        } message: {
            Text(cardState?.trustError ?? "")
        }

    }

    /// Keep both resting and active words at least secondary for contrast.
    /// Reserve the widest label at its scaled font size so routing label changes cannot move the row beneath an open pane.
    private var widestEffortWordWidth: CGFloat? {
        let labels = routing.efforts.map(\.label)
        guard !labels.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: ShellType.labelSize, weight: .medium)
        return labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max()
            .map { ceil($0) }
    }

    /// Bind menus and receipts to their opening word.
    private func isActive(_ card: ChatComposerCard) -> Bool {
        cardState?.activePane == card
    }

    /// Punctuation separates hit targets without becoming a control.
    private var separator: some View {
        Text("·")
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }

    /// Mouse and keyboard must open the same native receipt.
    private var contextRing: some View {
        Button {
            toggleContextPopover()
        } label: {
            ComposerContextRing(sessionId: appModel.activeChatSessionId)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background {
                    if isActive(.context) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(NativeAgentShell.softFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonFocusable()
        .focused($focusedWord, equals: .context)
        .background(ComposerMenuAnchor(card: .context, state: cardState,
                                      live: chatPageIsVisible && !quietOffscreenRead,
                                      build: { NSMenu() }))
        .accessibilityIdentifier("chat.composer.context")
        .popover(isPresented: Binding(
            get: { cardState?.activePane == .context },
            set: { if !$0, cardState?.activePane == .context { cardState?.dismiss() } }
        ), arrowEdge: .top) {
            if let state = cardState {
                ComposerContextReceiptCard(sessionId: appModel.activeChatSessionId, shell: state,
                                           model: routing.isBotConversation ? routing.botContract?.model : nil)
                    .padding(NativeAgentSpacing.md)
                    .frame(width: 320 + NativeAgentSpacing.md * 2)
            }
        }
        .accessibilityHint(isActive(.context)
            ? "Closes the context receipt"
            : "Opens the context receipt for the last turn")
        .onKeyPress(.space) { toggleContextPopover(); return .handled }
        .onKeyPress(.return) { toggleContextPopover(); return .handled }
        .onKeyPress(.escape) {
            guard isActive(.context) else { return .ignored }
            cardState?.dismiss()
            return .handled
        }
        .onKeyPress(keys: [.tab, .backTab]) { press in tab(.context, press) }
    }

    private func toggleContextPopover() {
        if isActive(.context) { cardState?.dismiss() }
        else { cardState?.open(.context) }
    }

    /// Hand Tab back to the window at either end of the words.
    private func tab(_ card: ChatComposerCard, _ press: KeyPress) -> KeyPress.Result {
        let ring = ChatComposerSettings.ring
        guard let index = ring.firstIndex(of: card) else { return .ignored }
        let next = index + (press.modifiers.contains(.shift) ? -1 : 1)
        guard ring.indices.contains(next) else { return .ignored }
        cardState?.dismiss()
        focusedWord = ring[next]
        return .handled
    }

    /// Let native submenus own model navigation and placement.
    @ViewBuilder
    private var modelMenuWord: some View {
        if routing.isBotConversation {
            word(
                .model,
                text: routing.modelWord,
                help: "This conversation uses its helper's model. Tell me in chat to change it.",
                accessibility: "Helper model. Tell me in chat to change it",
                identifier: "chat.composer.model"
            )
        } else {
            nativeMenuWord(.model, text: routing.modelWord,
                           help: "\(appModel.chatProvider) · \(appModel.chatModel). Choose the model for Chat.",
                           identifier: "chat.composer.model")
        }
    }

    private func menuWordLabel(_ text: String, minWidth: CGFloat? = nil) -> some View {
        Text(text)
            .font(ShellType.labelMedium)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(NativeAgentShell.secondary)
            .frame(minWidth: minWidth)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
    }

    private func word(
        _ card: ChatComposerCard, text: String, help: String,
        accessibility: String, identifier: String
    ) -> some View {
        Button {
            NotificationCenter.default.post(name: .openCommandRouteRequest, object: "bots")
        } label: {
            menuWordLabel(text, minWidth: card == .effort ? widestEffortWordWidth : nil)
        }
        .buttonStyle(.plain)
        .buttonFocusable()
        .focused($focusedWord, equals: card)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibility)
        .onKeyPress(keys: [.tab, .backTab]) { tab(card, $0) }
    }

    private func nativeMenuWord(_ card: ChatComposerCard, text: String,
                                help: String, identifier: String) -> some View {
        Button { cardState?.open(card) } label: {
            menuWordLabel(text, minWidth: card == .effort ? widestEffortWordWidth : nil)
        }
        .disabled(card != .trust && routing.residentPresentation == nil)
        .buttonStyle(.plain)
        .buttonFocusable()
        .focused($focusedWord, equals: card)
        .background(ComposerMenuAnchor(card: card, state: cardState,
                                      live: chatPageIsVisible && !quietOffscreenRead,
                                      build: { makeMenu(card) }))
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityHint("Opens a menu")
        .onKeyPress(.space) { cardState?.open(card); return .handled }
        .onKeyPress(.return) { cardState?.open(card); return .handled }
        .onKeyPress(keys: [.tab, .backTab]) { tab(card, $0) }
    }

    private func makeMenu(_ card: ChatComposerCard) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if card != .trust && routing.residentPresentation == nil { return menu }
        switch card {
        case .model:
            for group in routing.providerGroups {
                let providers = NSMenu()
                providers.autoenablesItems = false
                if let vendors = group.vendorGroups {
                    for vendor in vendors {
                        let models = NSMenu()
                        models.autoenablesItems = false
                        addModels(vendor.models, provider: group.id, to: models)
                        addSubmenu(vendor.provider, submenu: models, to: providers)
                    }
                } else { addModels(group.models, provider: group.id, to: providers) }
                addSubmenu(group.provider, submenu: providers, to: menu,
                           selected: group.id == appModel.chatProvider)
            }
            menu.addItem(.separator())
            if routing.selectedModelSupportsFast {
                menu.addItem(ComposerMenuItem("fast", "Fast", selected: routing.fastIsOn) {
                    guard routing.residentPresentation != nil else { return }
                    appModel.chatFastMode.toggle()
                    appModel.enqueueChatBrainDefaultsSave()
                })
            }
            menu.addItem(ComposerMenuItem("more_models", "More models…") {
                NotificationCenter.default.post(name: .openCommandRouteRequest, object: "providers")
            })
            addScope("Saved default for Chat", to: menu)
        case .effort:
            if routing.efforts.isEmpty {
                let knownEmpty = routing.presentation?.selectedModel?.supportedReasoningEfforts == []
                addScope(knownEmpty ? "This model has no configurable thinking levels."
                         : "Thinking choices unavailable. Reload Providers to read this model's capabilities.", to: menu)
            }
            for (index, effort) in routing.efforts.enumerated() {
                menu.addItem(ComposerMenuItem(effort.id, effort.label, selected: index == routing.effortIndex) {
                    routing.setEffort(index: index)
                })
            }
        case .trust:
            if appModel.engine.trust.policy == nil {
                addScope("Reading the saved posture…", to: menu)
            } else {
                for preset in MobileTrustAction.Preset.allCases {
                    let item = ComposerMenuItem(preset.rawValue, preset.title,
                                                selected: routing.activeTrustPreset == preset,
                                                enabled: cardState?.savingTrust != true) {
                        cardState?.applyTrust(preset, appModel: appModel)
                    }
                    item.toolTip = preset.summary
                    item.subtitle = preset.summary
                    menu.addItem(item)
                }
            }
            addScope("Saved default throughout the app", to: menu)
        case .context: break
        }
        return menu
    }

    private func addModels(_ models: [ModelCatalogItem], provider: String, to menu: NSMenu) {
        for model in models {
            menu.addItem(ComposerMenuItem(provider + ":" + model.id, model.displayName,
                                         selected: model.id == appModel.chatModel && provider == appModel.chatProvider) {
                _ = routing.select(model: model, provider: provider)
            })
        }
    }

    private func addSubmenu(_ title: String, submenu: NSMenu, to menu: NSMenu, selected: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.state = selected ? .on : .off
        menu.addItem(item)
    }

    private func addScope(_ title: String, to menu: NSMenu) {
        menu.addItem(.separator())
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}
