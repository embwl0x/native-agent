import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.scheduler.loadError
@Suite("Desk scheduler load error")
struct DeskSchedulerLoadErrorEvalTests {
    @Test("scheduler failures carry their own detail, independent of ambient app status")
    func schedulerRefreshResultOwnsFailureReason() {
        let partial = SchedulerJobsRefreshResult.partial(
            detail: "Schedule is partially unavailable: 2 malformed rows were withheld."
        )
        let unavailable = SchedulerJobsRefreshResult.unavailable(
            detail: "Schedule source is unavailable: permission denied"
        )

        #expect(SchedulerJobsRefreshResult.current.failureDetail == nil)
        #expect(partial.failureDetail?.contains("malformed") == true)
        #expect(unavailable.failureDetail == "Schedule source is unavailable: permission denied")
        #expect(unavailable.failureDetail != "Unrelated model refresh failed")
    }

    @Test("feed states preserve partial detail and fail closed for absent or unavailable sources")
    func schedulerFeedMapsToVisibleLoadResult() {
        #expect(SchedulerJobsRefreshResult.make(from: .current([])) == .current)
        #expect(SchedulerJobsRefreshResult.make(from: .partial([], rejectedRows: 1)).failureDetail?
            .contains("1 malformed row") == true)
        #expect(SchedulerJobsRefreshResult.make(from: .sourceAbsent).failureDetail?
            .contains("source is absent") == true)
        #expect(SchedulerJobsRefreshResult.make(from: .unavailable("disk unavailable")).failureDetail?
            .contains("disk unavailable") == true)
    }

    @Test("mounted Scheduler uses the refresh result, retains rows on a failed read, and never reads ambient statusText")
    func schedulerViewUsesDedicatedResult() throws {
        let view = try AppSourceScraping.appSource("SchedulerView.swift")
        #expect(view.contains("jobsLoadResult = await appModel.refreshSchedulerJobs()"))
        #expect(view.contains("if isLoadingJobs, appModel.jobs.isEmpty"))
        #expect(view.contains("Text(\"Refreshing schedule…\")"))
        #expect(view.contains("if let detail = jobsLoadResult?.failureDetail, appModel.jobs.isEmpty"))
        #expect(view.contains("StalePanelNotice(text: detail)"))
        #expect(view.contains("guard refreshCoalescer.requestRefresh() else { return }"))
        #expect(!view.contains("jobsLoadError = appModel.statusText"))

        let model = try AppSourceScraping.appSource("AppModel+WorkshopPolicy.swift")
        #expect(model.contains("let result = SchedulerJobsRefreshResult.make(from: feed)"))
        #expect(model.contains("func refreshSchedulerJobs() async -> SchedulerJobsRefreshResult"))
    }

    @Test("overlapping live and manual refreshes collapse into one trailing snapshot")
    func schedulerRefreshesAreBoundedSingleFlight() {
        var coalescer = SchedulerJobsRefreshCoalescer()

        let startsInitial = coalescer.requestRefresh()
        #expect(startsInitial)
        #expect(coalescer.isRefreshing)
        let startsOverlapping = coalescer.requestRefresh()
        #expect(!startsOverlapping)
        let startsRepeated = coalescer.requestRefresh()
        #expect(!startsRepeated)
        #expect(coalescer.trailingRefreshQueued)

        let startsTrailing = coalescer.completeRefresh()
        #expect(startsTrailing)
        #expect(coalescer.isRefreshing)
        #expect(!coalescer.trailingRefreshQueued)
        let startsDuringTrailing = coalescer.requestRefresh()
        #expect(!startsDuringTrailing)
        #expect(coalescer.trailingRefreshQueued)

        let startsNewest = coalescer.completeRefresh()
        #expect(startsNewest)
        #expect(coalescer.isRefreshing)
        #expect(!coalescer.trailingRefreshQueued)

        let startsAfterBurst = coalescer.completeRefresh()
        #expect(!startsAfterBurst)
        #expect(!coalescer.isRefreshing)
    }

    @Test("a cancelled mounted refresh releases its single-flight latch")
    func schedulerRefreshCancellationRecovers() {
        var coalescer = SchedulerJobsRefreshCoalescer()
        let startsInitial = coalescer.requestRefresh()
        #expect(startsInitial)
        let startsOverlapping = coalescer.requestRefresh()
        #expect(!startsOverlapping)

        coalescer.cancel()

        #expect(!coalescer.isRefreshing)
        #expect(!coalescer.trailingRefreshQueued)
        let startsAfterCancellation = coalescer.requestRefresh()
        #expect(startsAfterCancellation)
    }
}
