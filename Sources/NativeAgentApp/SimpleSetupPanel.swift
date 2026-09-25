import SwiftUI

// Simple view has no pages, so the setup a card opens — "Open full setup",
// the connectors that need their own sheet (Gmail, Google Calendar, X), and
// the pages a card sends the person to (Telegram, Trust, Providers) — opens
// in one floating glass panel over the chat, with the existing setup view
// inside it. Advanced keeps the sheet and the pages it always had.

extension View {
    /// Where a chat's inline cards open their setup.
    func inlineCardSetup(_ cards: InlineInteractionChatBinding) -> some View {
        modifier(InlineCardSetupPresentation(cards: cards))
    }
}

private struct InlineCardSetupPresentation: ViewModifier {
    let cards: InlineInteractionChatBinding
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        let simple = SimpleViewMode.isShowing
        let panelOpen = simple && (cards.panelPage != nil || cards.connectorSheet != nil)
        content
            .disabled(panelOpen)
            .overlay {
                if panelOpen {
                    SimpleSetupPanel(showsClose: cards.panelPage != nil) {
                        Task { await cards.panelClosed() }
                    } content: {
                        if let request = cards.connectorSheet {
                            ConnectorWizardView(provider: request.provider, startsSignIn: true) {
                                Task { await cards.panelClosed() }
                            }
                        } else if let page = cards.panelPage {
                            Self.page(page)
                        }
                    }
                    .task { while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        await cards.settlePanelIfDone()
                    } }
                }
            }
            // Advanced: Connectors' own setup, opened as the sheet it is.
            .sheet(item: Binding(
                get: { simple ? nil : cards.connectorSheet },
                set: { if $0 == nil { Task { await cards.connectorSheetClosed() } } }
            )) { request in
                ConnectorWizardView(provider: request.provider, startsSignIn: true) {
                    Task { await cards.connectorSheetClosed() }
                }
                .environment(appModel)
            }
    }

    /// The pages a card can open, as Advanced shows them.
    @ViewBuilder
    static func page(_ item: SidebarItem) -> some View {
        switch item {
        case .telegram: TelegramView()
        case .trust: TrustCenterView()
        case .providers: ProviderSettingsView()
        case .settings: SetupView()
        // The pairing card opens Connectors on its iPhone tab.
        case .connectors: ConnectorsRailPage()
        default: EmptyView()
        }
    }
}

/// Native glass, radius 22, a close button, Esc closes it.
struct SimpleSetupPanel<Content: View>: View {
    var showsClose = true
    let close: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var radius: CGFloat { 22 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            // Holds the chat still behind the panel; the chat is disabled too.
            // Apple's dimming layer under glass over busy content: 35% black,
            // so the card behind stops showing through the panel.
            Color.black.opacity(0.35).ignoresSafeArea()
            content
                .frame(maxWidth: 760)
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        // A fill, not glass: it sits on the panel's glass.
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NativeAgentShell.secondary)
                                .frame(width: 28, height: 28)
                                .background(NativeAgentShell.softFill, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .accessibilityLabel("Close")
                    }
                }
                .background { if reduceTransparency { shape.fill(NativeAgentShell.room) } }
                .glassEffect(reduceTransparency ? .identity : .regular, in: shape)
                .padding(32)
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
