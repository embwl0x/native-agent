import SwiftUI
import AppKit
import ChatToolRuntime
import ToolRegistry
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

// Blueprint: | `ToolsView.swift` | Tools screen, scoped refresh feedback and Trust navigation through AppModel |
struct ToolsView: View {
    @Environment(AppModel.self) private var appModel

    /// Route through ContentView so Trust navigation also expands Advanced and sets focus.
    private func jumpToTrust() {
        ToolsNavigation.openTrustCenter()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let message = ToolsRefreshPresentation.message(for: appModel.toolsRefreshState) {
                    Text(message)
                        .font(ShellType.label)
                        .foregroundStyle(
                            appModel.toolsRefreshState == .refreshed
                                ? NativeAgentShell.calm
                                : NativeAgentShell.trouble
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                catalogContent(ChatToolCatalogPresentation.catalogState(
                    catalog: appModel.engine.tools.catalog,
                    authored: appModel.engine.tools.authored,
                    loadFailed: appModel.engine.tools.catalogLoadError != nil,
                    loadError: appModel.engine.tools.catalogLoadError
                ))

                if !appModel.engine.tools.authored.isEmpty {
                    AuthoredToolsSection(tools: appModel.engine.tools.authored, appModel: appModel)
                }

                if !appModel.toolOperationStatusReceipts.isEmpty {
                    AdvancedSection(title: "Recent tool activity", card: .single) {
                        ForEach(appModel.toolOperationStatusReceipts) { receipt in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(receipt.outcome == .succeeded ? "Completed" : "Needs attention")
                                    .font(ShellType.labelSemibold)
                                    .foregroundStyle(
                                        receipt.outcome == .succeeded
                                            ? NativeAgentShell.calm
                                            : NativeAgentShell.trouble
                                    )
                                Text(receipt.message)
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageActions {
            Button {
                Task { await appModel.refreshToolsFromToolbar() }
            } label: {
                if appModel.isRefreshingTools {
                    Label("Refreshing tools", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(appModel.isRefreshingTools)
            .accessibilityIdentifier("tools.refresh")
        }
        .liveTask {
            await appModel.refreshForSidebarItem(.tools)
        }
    }

    @ViewBuilder
    private func catalogContent(_ catalogState: ChatToolCatalogPresentation.CatalogState) -> some View {
        switch catalogState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading the tools…")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .padding(.vertical, 8)
        case .empty:
            catalogMessage(title: "No tools available", detail: "The tool list loaded, but there were no tools in it.")
        case .unavailable(let detail):
            catalogMessage(title: "The tool list could not be read", detail:
                detail.map { "The tool catalog could not be read: \($0). Open Diagnostics → Health checks to inspect the cause; use Refresh after fixing it." }
                    ?? "No tool catalog loaded. Use Refresh to load it.")
        case let .available(catalog, bucketResult), let .stale(catalog, bucketResult, _):
            let detail: String? = if case let .stale(_, _, detail) = catalogState { detail } else { nil }
            ChatToolCatalogSection(
                catalog: catalog,
                bucketResult: bucketResult,
                staleDetail: detail,
                trustPolicy: appModel.engine.trust.policy,
                trustRefreshStatus: appModel.panelRefreshStatus[.tools],
                jumpToTrust: jumpToTrust
            )
        }
    }

    private func catalogMessage(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            Text(detail)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ToolsNavigation {
    static func openTrustCenter(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: .openCommandRouteRequest, object: "trust")
    }
}

/// The toolbar reports the outcome of its scoped refresh rather than treating
/// a tap, or completion of only the side reads, as proof that the tool catalog
/// itself was refreshed.
enum ToolsRefreshPresentation {
    enum State: Equatable {
        case idle
        case refreshing
        case refreshed
        case partial
        case unavailable
        case alreadyRefreshing
    }

    static func completion(
        panelRefresh: AppModel.PanelRefreshStatus?,
        catalogLoadFailed: Bool,
        hasCatalog: Bool
    ) -> State {
        if catalogLoadFailed && !hasCatalog { return .unavailable }
        if catalogLoadFailed || panelRefresh?.isStale == true { return .partial }
        return panelRefresh == nil ? .unavailable : .refreshed
    }

    static func message(for state: State) -> String? {
        switch state {
        case .idle, .refreshing:
            return nil
        case .refreshed:
            return "Tools refreshed from current sources."
        case .partial:
            return "Some Tools data could not be refreshed; retained rows are marked stale."
        case .unavailable:
            return "The Tools catalog could not be refreshed. Check the displayed diagnostics and try again."
        case .alreadyRefreshing:
            return "Tools refresh is already in progress."
        }
    }

}
