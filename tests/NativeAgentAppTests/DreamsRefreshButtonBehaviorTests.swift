import Testing
@testable import NativeAgentApp

@Suite("Dreams refresh button behavior")
struct DreamsRefreshButtonBehaviorTests {
    private func entry(_ date: String = "2026-08-24") -> DreamEntry {
        DreamEntry(date: date, content: "A retained dream entry.")
    }

    // app.mind / ui.dreams.button.refresh
    @Test("a failed refresh labels retained diary entries as stale instead of empty")
    func retainedEntriesStayVisibleAndExplicitlyStale() {
        let presentation = DreamDiaryRefreshPresentation.resolve(
            entries: [entry()], didFail: true
        )
        #expect(presentation == .retainedStale(entryCount: 1))
        #expect(presentation.banner == "Couldn't refresh the diary — showing previously loaded entries.")
        #expect(!presentation.unavailableEmptyState)
    }

    // app.mind / ui.dreams.button.refresh
    @Test("a first-read failure is unavailable while a successful empty refresh remains honest")
    func unavailableAndHonestEmptyRemainDistinctAfterRefresh() {
        let unavailable = DreamDiaryRefreshPresentation.resolve(entries: [], didFail: true)
        #expect(unavailable == .unavailable)
        #expect(unavailable.banner?.contains("couldn't be checked") == true)
        #expect(unavailable.unavailableEmptyState)

        let emptySuccess = DreamDiaryRefreshPresentation.resolve(entries: [], didFail: false)
        #expect(emptySuccess == .current)
        #expect(emptySuccess.banner == nil)
        #expect(!emptySuccess.unavailableEmptyState)
    }
}
