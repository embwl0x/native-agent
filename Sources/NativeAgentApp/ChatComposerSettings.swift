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
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatComposerSettings.swift` | Native composer menus and context receipt: keyboard access and shared routing/actions |

/// Composer controls share native menus and a context receipt.
enum ChatComposerCard: String, Hashable, CaseIterable {
    case model, effort = "think", trust, context
}

struct ComposerSessionRefresh: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let sessionID: String
    var live = true
    @AppStorage("nativeagent.contextWindowMode") private var windowMode = ""
    @AppStorage("nativeagent.compactionThresholdTokens") private var windowSize = 0

    func body(content: Content) -> some View {
        content.quietReadTask(id: "\(sessionID):\(windowMode):\(windowSize):\(live)") {
            if quietOffscreenRead { await appModel.engine.providers.refreshSession(sessionID) }
            else if live { await appModel.engine.providers.observeSession(sessionID) }
        }
    }
}

/// The three words on the composer row. Observes routing and policy here,
/// never in the draft or transcript owner.
struct ChatComposerSettings: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(ComposerShellState.self) var cardState: ComposerShellState?

    private var routing: QuietComposerCommands.Routing { .init(appModel: appModel) }

    /// Bumped by the draft when Tab should move into the words.
    var focusWordToken: Int
    /// The hand-back shows only while it would do something.
    @State private var handoffWouldChange = false
    @AppStorage(ShotgunController.enabledKey) private var shotgunEnabled = true

    @FocusState private var focusedWord: ChatComposerCard?

    init(focusWordToken: Int = 0) {
        self.focusWordToken = focusWordToken
    }

    /// The local Tab ring. The window-wide order skips plain buttons, so the
    /// three words walk themselves and hand Tab back at either end.
    private static let ring: [ChatComposerCard] = [.context, .model, .effort, .trust]

    var body: some View {
        HStack(spacing: 0) {
            // Only while it would change something: a Mac action wants the
            // driver, User holds it, and the posture is below Full Mac.
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
            // Shotgun moves this window aside while the agent drives the Mac.
            Toggle("Shotgun", isOn: $shotgunEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text.opacity(0.85))
                .help("On: when I start driving the Mac, this window steps aside into Shotgun, a small chat you can keep typing in. Off: I work in the background and this window stays put. Its shortcut (Settings) or View ▸ Show Shotgun shows it either way.")
                .accessibilityIdentifier("chat.composer.shotgun")
            Spacer(minLength: 0)

            // Fast leads the trailing cluster to keep other controls fixed; bot Fast settings open Bots.
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
                .help(routing.isBotConversation ? "Fast is on for this bot. Edit it in Bots." : "Fast is on. Click to turn it off.")
                .accessibilityIdentifier("chat.composer.fast")
                .accessibilityLabel("Fast is on")
                .accessibilityHint(routing.isBotConversation ? "Opens Bots" : "Turns Fast off")
            }

            // How full the context is, at a glance — and the receipt behind
            // it: click the ring and the last turn's assembled context opens
            // in a native popover above the ring.
            contextRing

            separator

            modelMenuWord
            // At most 220, but no wider than the name: a greedy frame held
            // the ring out in the middle of the bar.
            .frame(maxWidth: 220, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)

            separator

            if routing.isBotConversation {
                word(
                    .effort,
                    text: routing.effortWord,
                    help: "This conversation uses its bot's own thinking level. Edit it in Bots.",
                    accessibility: "Bot thinking: \(routing.effortWord). Edit in Bots",
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
        // Re-read on every driver change, and when the posture moves.
        .task(id: routing.activeTrustPreset) {
            for await _ in await MacAttentionSessionStore.shared.driverChanges() {
                handoffWouldChange = await MacAttentionSessionStore.shared.handoffWouldChange()
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
            Text("I can read and change files anywhere, run commands, control your Mac, and move files or put them in the Trash. I can act on my own, and files are backed up before changes. macOS privacy permissions still apply. This stays active until you change Trust.")
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

    /// A setting rendered as the word that names it. Quiet at rest is less
    /// decoration, never dimmer text (Agent's note 8): both states are at or
    /// above `secondary`.
    /// Width of the widest thinking label this model offers, measured with
    /// the word's own font. Cheap: a handful of short strings per render.
    ///
    /// The size is the SCALED one, not the ramp's 13: measured at a fixed 13
    /// while the words render larger, the reservation is too narrow and the
    /// row moves under an open pane on every "Low" → "Medium" — the exact
    /// thing this reservation exists to stop.
    private var widestEffortWordWidth: CGFloat? {
        let labels = routing.efforts.map(\.label)
        guard !labels.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: ShellType.labelSize, weight: .medium)
        return labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max()
            .map { ceil($0) }
    }

    /// The live native menu or receipt belongs to this word.
    private func isActive(_ card: ChatComposerCard) -> Bool {
        cardState?.activePane == card
    }

    /// Punctuation between two hit targets, not a control.
    private var separator: some View {
        Text("·")
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }

    /// Mouse and keyboard open the same native context receipt.
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

    /// The words hand Tab back to the window at either end.
    private func tab(_ card: ChatComposerCard, _ press: KeyPress) -> KeyPress.Result {
        let ring = ChatComposerSettings.ring
        guard let index = ring.firstIndex(of: card) else { return .ignored }
        let next = index + (press.modifiers.contains(.shift) ? -1 : 1)
        guard ring.indices.contains(next) else { return .ignored }
        cardState?.dismiss()
        focusedWord = ring[next]
        return .handled
    }

    /// Native menu submenus own model navigation and placement.
    @ViewBuilder
    private var modelMenuWord: some View {
        if routing.isBotConversation {
            word(
                .model,
                text: routing.modelWord,
                help: "This conversation uses its bot's own model. Edit it in Bots.",
                accessibility: "Bot model. Edit in Bots",
                identifier: "chat.composer.model"
            )
        } else {
            nativeMenuWord(.model, text: routing.modelWord,
                           help: "\(appModel.chatProvider) · \(appModel.chatModel). Choose the model for Chat.",
                           identifier: "chat.composer.model")
        }
    }

    /// A composer word that opens a native menu.
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
