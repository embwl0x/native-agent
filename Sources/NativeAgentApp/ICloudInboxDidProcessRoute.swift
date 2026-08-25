import Foundation

/// Routes an iCloud inbox mutation to the smallest current Activity read. The
/// route is selected when the notification arrives, before an async refresh can
/// observe a later sidebar change.
enum ICloudInboxDidProcessRoute: Equatable, Sendable {
    case refreshActivity
    case refreshActivityBadge

    static func resolve(selectionRaw: String) -> Self {
        guard let item = SidebarItem(rawValue: selectionRaw), item.normalized == .activity else {
            return .refreshActivityBadge
        }
        return .refreshActivity
    }
}

enum ICloudInboxDidProcessRefreshReceipt: Equatable, Sendable {
    case activity(AppModel.PanelRefreshStatus)
    case activityBadge(AppModel.PanelRefreshStatus)
}

extension ICloudInboxDidProcessRefreshReceipt {
    @MainActor
    static func execute(
        route: ICloudInboxDidProcessRoute,
        refreshActivity: @escaping @MainActor () async -> AppModel.PanelRefreshStatus,
        refreshBadge: @escaping @MainActor () async -> AppModel.PanelRefreshStatus
    ) async -> Self {
        switch route {
        case .refreshActivity:
            return .activity(await refreshActivity())
        case .refreshActivityBadge:
            return .activityBadge(await refreshBadge())
        }
    }
}

@MainActor
extension AppModel {
    /// Handles the app-side consequence of an already-committed iCloud inbox
    /// mutation. This is a read refresh, not a claim that the remote action
    /// itself succeeded; the mutation owner posts only after its own durable
    /// bookkeeping path has completed.
    @discardableResult
    func refreshAfterICloudInboxDidProcess(
        route: ICloudInboxDidProcessRoute
    ) async -> ICloudInboxDidProcessRefreshReceipt {
        await ICloudInboxDidProcessRefreshReceipt.execute(
            route: route,
            refreshActivity: { await self.refreshForSidebarItem(.activity) },
            refreshBadge: { await self.refreshSidebarActivityBadge() }
        )
    }
}
