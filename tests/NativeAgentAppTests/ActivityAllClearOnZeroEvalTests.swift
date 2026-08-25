import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.activity.allClearOnZero

@MainActor
@Suite("Activity all-clear evidence", .serialized)
struct ActivityAllClearOnZeroEvalTests {
    private let refreshedAt = Date(timeIntervalSince1970: 1_000_000)

    private var completeRefresh: AppModel.PanelRefreshStatus {
        AppModel.PanelRefreshStatus(
            lastAttemptAt: refreshedAt,
            lastSuccessAt: refreshedAt,
            failedEndpoints: []
        )
    }

    @Test("all five Activity queues reserve All clear for measured zero")
    func allClearRequiresACompleteZeroRead() {
        let appQueues: [(count: Int, endpoints: Set<String>)] = [
            (0, ["approvals"]),
            (0, ["inbox"]),
            (0, ["memory proposals"]),
            (0, ["training proposals", "promotion candidates"]),
        ]
        for queue in appQueues {
            #expect(ActivityQueuePresentation.appModel(
                count: queue.count,
                requiredEndpoints: queue.endpoints,
                refresh: completeRefresh
            ) == .allClear)
        }
        #expect(ActivityQueuePresentation.cognition(count: 0, state: .active) == .allClear)
    }

    @Test("a failed required source is unavailable rather than reassuring zero")
    func failedSourceCannotRenderAllClear() {
        let appQueues: [Set<String>] = [
            ["approvals"],
            ["inbox"],
            ["memory proposals"],
            ["training proposals", "promotion candidates"],
        ]
        for endpoints in appQueues {
            let failedRefresh = AppModel.PanelRefreshStatus(
                lastAttemptAt: refreshedAt,
                lastSuccessAt: nil,
                failedEndpoints: Array(endpoints)
            )
            #expect(ActivityQueuePresentation.appModel(
                count: 0,
                requiredEndpoints: endpoints,
                refresh: failedRefresh
            ) == .unavailable)
        }
        #expect(ActivityQueuePresentation.appModel(
            count: 0,
            requiredEndpoints: ["approvals"],
            refresh: nil
        ) == .loading)
        #expect(ActivityQueuePresentation.cognition(
            count: 0,
            state: .unavailable("runtime unavailable")
        ) == .unavailable)
    }

    @Test("the sidebar status projection visibly distinguishes measured zero from unavailable")
    func sidebarStatusProjectionDoesNotShowAllClearForUnavailableData() {
        let clear = ActivityQueuePresentation.allClear.sidebarStatus
        let unavailable = ActivityQueuePresentation.unavailable.sidebarStatus

        #expect(clear == ActivityQueuePresentation.SidebarStatus(
            text: "All clear", systemImage: nil
        ))
        #expect(unavailable == ActivityQueuePresentation.SidebarStatus(
            text: "Unavailable", systemImage: "exclamationmark.triangle.fill"
        ))
        #expect(clear.text != unavailable.text)
        #expect(unavailable.systemImage != nil)
    }
}
