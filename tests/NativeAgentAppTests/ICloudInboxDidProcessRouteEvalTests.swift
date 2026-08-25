import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / route.iCloudInboxDidProcess
@MainActor
@Suite("iCloud inbox processed route", .serialized)
struct ICloudInboxDidProcessRouteEvalTests {
    @Test("Activity and its restored aliases receive a full Activity refresh")
    func activityRouteNormalizesRestoredSelections() async {
        #expect(ICloudInboxDidProcessRoute.resolve(selectionRaw: SidebarItem.activity.rawValue) == .refreshActivity)
        #expect(ICloudInboxDidProcessRoute.resolve(selectionRaw: SidebarItem.approvals.rawValue) == .refreshActivity)
        #expect(ICloudInboxDidProcessRoute.resolve(selectionRaw: SidebarItem.autoImprovement.rawValue) == .refreshActivity)

        let status = refreshStatus(failedEndpoints: [])
        var activityRefreshes = 0
        var badgeRefreshes = 0
        let receipt = await ICloudInboxDidProcessRefreshReceipt.execute(
            route: .refreshActivity,
            refreshActivity: {
                activityRefreshes += 1
                return status
            },
            refreshBadge: {
                badgeRefreshes += 1
                return refreshStatus(failedEndpoints: ["inbox"])
            }
        )
        #expect(receipt == .activity(status))
        #expect(activityRefreshes == 1)
        #expect(badgeRefreshes == 0)
    }

    @Test("inactive or malformed selections refresh only the Activity badge and retain failure evidence")
    func inactiveRouteUsesBadgeAndDoesNotInventSuccess() async {
        #expect(ICloudInboxDidProcessRoute.resolve(selectionRaw: SidebarItem.chat.rawValue) == .refreshActivityBadge)
        #expect(ICloudInboxDidProcessRoute.resolve(selectionRaw: "not-a-sidebar-item") == .refreshActivityBadge)

        let stale = refreshStatus(failedEndpoints: ["approvals", "inbox"])
        var activityRefreshes = 0
        var badgeRefreshes = 0
        let receipt = await ICloudInboxDidProcessRefreshReceipt.execute(
            route: .refreshActivityBadge,
            refreshActivity: {
                activityRefreshes += 1
                return refreshStatus(failedEndpoints: [])
            },
            refreshBadge: {
                badgeRefreshes += 1
                return stale
            }
        )
        #expect(receipt == .activityBadge(stale))
        #expect(activityRefreshes == 0)
        #expect(badgeRefreshes == 1)
        guard case .activityBadge(let returned) = receipt else {
            Issue.record("inactive selection must produce the badge receipt")
            return
        }
        #expect(returned.isStale)
        #expect(returned.failedEndpoints == ["approvals", "inbox"])
    }

    private func refreshStatus(failedEndpoints: [String]) -> AppModel.PanelRefreshStatus {
        let date = Date(timeIntervalSince1970: 1_788_912_000)
        return .init(
            lastAttemptAt: date,
            lastSuccessAt: failedEndpoints.isEmpty ? date : nil,
            failedEndpoints: failedEndpoints
        )
    }
}
