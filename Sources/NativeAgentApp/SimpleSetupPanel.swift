import AppToolRuntime
import SwiftUI

// Blueprint: | `SimpleSetupPanel.swift` | `InlineCardSetupPresentation`: existing setup controls in a floating Simple panel or Advanced sheet/page |

// Simple has no pages; host canonical setup views over chat while Advanced uses its page routes.

extension View {
    func inlineCardSetup(_ cards: InlineInteractionChatBinding) -> some View {
        modifier(InlineCardSetupPresentation(cards: cards))
    }
}

struct InlineCardSetupPresentation: ViewModifier {
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
                            ConnectorWizardView(provider: request.provider) {
                                Task { await cards.panelClosed() }
                            }
                        } else if let page = cards.panelPage {
                            Self.page(page, appModel: appModel)
                        }
                    }
                    .task { while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        await cards.settlePanelIfDone()
                    } }
                }
            }
            .sheet(item: Binding(
                get: { simple ? nil : cards.connectorSheet },
                set: { if $0 == nil { Task { await cards.connectorSheetClosed() } } }
            )) { request in
                ConnectorWizardView(provider: request.provider) {
                    Task { await cards.connectorSheetClosed() }
                }
                .environment(appModel)
            }
    }

    @ViewBuilder
    static func page(_ item: SidebarItem, appModel: AppModel) -> some View {
        switch item {
        case .telegram: TelegramView()
        case .trust: FacePageView(page: "trust")
        case .providers:
            FacePageView(page: "providers", isReading: appModel.panelRefreshCounts[.providers, default: 0] > 0)
                .quietReadTask { _ = await appModel.refreshForSidebarItem(.providers) }
        case .settings: FacePageView(page: "settings")
        // Pairing must select the iPhone tab instead of Connectors' default.
        case .connectors: ConnectorsRailPage()
        default: EmptyView()
        }
    }
}

struct SimpleSetupPanel<Content: View>: View {
    var showsClose = true
    let close: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var radius: CGFloat { 22 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            // Disable background chat and dim it 35% so text behind glass cannot compete with the panel.
            Color.black.opacity(0.35).ignoresSafeArea()
            content
                .frame(maxWidth: 760)
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .sheetCloseButton()
                        .padding(12)
                    }
                }
                // Full pages need an opaque room fill so chat text cannot show through their content.
                .background { shape.fill(NativeAgentShell.room) }
                .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
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
