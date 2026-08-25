import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Capabilities status text line", .serialized)
struct CapabilitiesStatusTextLineEvalTests {
    @Test("the line distinguishes unloaded, current, stale, and unavailable capability data")
    func scopedRefreshStatesAreHonest() {
        #expect(CapabilitiesStatusLinePresentation.resolve(refresh: nil)
            == .init(text: "Capabilities data has not loaded yet.", status: "info"))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let current = AppModel.PanelRefreshStatus(lastAttemptAt: now, lastSuccessAt: now, failedEndpoints: [])
        #expect(CapabilitiesStatusLinePresentation.resolve(refresh: current)
            == .init(text: "Capabilities data is current.", status: "ok"))

        let stale = AppModel.PanelRefreshStatus(lastAttemptAt: now, lastSuccessAt: now.addingTimeInterval(-60), failedEndpoints: ["catalog", "mcp"])
        let staleState = CapabilitiesStatusLinePresentation.resolve(refresh: stale)
        #expect(staleState.status == "warn")
        #expect(staleState.text.contains("last known data"))

        let unavailable = AppModel.PanelRefreshStatus(lastAttemptAt: now, lastSuccessAt: nil, failedEndpoints: ["catalog"])
        let unavailableState = CapabilitiesStatusLinePresentation.resolve(refresh: unavailable)
        #expect(unavailableState.status == "failed")
        #expect(unavailableState.text.contains("unavailable"))
    }

    @Test("the capabilities-scoped presenter ignores unrelated global status text")
    func scopedPresenterUsesCapabilitiesRefreshOnly() {
        let app = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        app.statusText = "Chat message sent"
        app.panelRefreshStatus[.capabilities] = .init(
            lastAttemptAt: Date(), lastSuccessAt: nil, failedEndpoints: ["capability summary"]
        )
        let state = CapabilitiesStatusLinePresentation.resolve(
            refresh: app.panelRefreshStatus[.capabilities]
        )
        #expect(state == .init(
            text: "Capabilities data is unavailable: 1 source did not load.",
            status: "failed"
        ))
        #expect(state.text != app.statusText)
    }
}
