import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.nativeMacPowerPanel
@Suite("Native macOS Power panel behavior")
struct NativeMacPowerPanelBehaviorEvalTests {
    @Test("runtime tiles do not replace unknown and failed reads with zeroes")
    func tilesKeepLoadingUnavailableAndStaleEvidenceDistinct() {
        let loading = NativeMacPowerPanelPresentation.tile(
            value: nil,
            detail: nil,
            runtimeStatus: nil,
            hasRefreshAttempt: false,
            readFailed: false
        )
        #expect(loading.readState == .loading)
        #expect(loading.value == "—")
        #expect(loading.detail == "Checking status…")
        #expect(loading.status == "info")

        let unavailable = NativeMacPowerPanelPresentation.tile(
            value: nil,
            detail: nil,
            runtimeStatus: nil,
            hasRefreshAttempt: true,
            readFailed: true
        )
        #expect(unavailable.readState == .unavailable)
        #expect(unavailable.value == "—")
        #expect(unavailable.detail == "Status unavailable; refresh failed.")
        #expect(unavailable.status == "warn")

        let stale = NativeMacPowerPanelPresentation.tile(
            value: "4",
            detail: "approved-only",
            runtimeStatus: "ready",
            hasRefreshAttempt: true,
            readFailed: true
        )
        #expect(stale.readState == .stale)
        #expect(stale.value == "4")
        #expect(stale.detail == "Showing last loaded data; refresh failed.")

        let available = NativeMacPowerPanelPresentation.tile(
            value: "12",
            detail: "MiniLM",
            runtimeStatus: "ok",
            hasRefreshAttempt: true,
            readFailed: false
        )
        #expect(available.readState == .available)
        #expect(available.value == "12")
        #expect(available.detail == "MiniLM")
        #expect(available.status == "ok")
    }

    @Test("native action controls reveal whether approval or dry-run support blocks them")
    func actionAvailabilityIsExplicit() {
        let approvalRequired = NativeMacPowerPanelPresentation.action(
            requiresApproval: true,
            dryRunAvailable: true
        )
        #expect(approvalRequired.canDryRun)
        #expect(!approvalRequired.canRun)
        #expect(approvalRequired.blockedDetail == "Approval is required before this action can run.")

        let admittedYolo = NativeMacPowerPanelPresentation.action(
            requiresApproval: true,
            dryRunAvailable: true,
            fullMacYoloAdmitted: true
        )
        #expect(admittedYolo.canDryRun)
        #expect(admittedYolo.canRun)
        #expect(admittedYolo.blockedDetail == nil)

        let noDryRun = NativeMacPowerPanelPresentation.action(
            requiresApproval: false,
            dryRunAvailable: false
        )
        #expect(!noDryRun.canDryRun)
        #expect(noDryRun.canRun)
        #expect(noDryRun.blockedDetail == "Dry run is unavailable for this action.")

        let runnable = NativeMacPowerPanelPresentation.action(
            requiresApproval: false,
            dryRunAvailable: true
        )
        #expect(runnable.canDryRun)
        #expect(runnable.canRun)
        #expect(runnable.blockedDetail == nil)
    }
}
