import Foundation
import NativeAgentCore
import PersistenceCore
import Browser
import ApprovalInbox
import ApprovalTransactions
import Cognition
import Dispatcher

extension NativeClient {
    static var browserActionRoutes: BrowserActionRoutes {
        BrowserActionRoutes(effects: NativeBrowserRouteEffects())
    }

    func runBrowser(url: String, dryRun: Bool) async throws -> BrowserRun {
        try await runBrowser(url: url, dryRun: dryRun, captureSource: false, captureScreenshot: false)
    }

    func runBrowser(url: String, dryRun: Bool, captureSource: Bool, captureScreenshot: Bool) async throws -> BrowserRun {
        try await Self.browserActionRoutes.runBrowser(
            url: url, dryRun: dryRun, captureSource: captureSource, captureScreenshot: captureScreenshot,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            decode: Self.decodeBrowserRouteRun
        )
    }

    static func decodeBrowserRouteRun(_ value: JSONValue, _ context: String) throws -> BrowserRouteDecodedRun<BrowserRun> {
        let run = try decodeJSONValue(value, as: BrowserRun.self, context: context)
        return BrowserRouteDecodedRun(value: run, id: run.id, status: run.status)
    }

    static func executeApprovedBrowserRun(from approval: ApprovalRecord) async throws {
        try await browserActionRoutes.executeApprovedBrowserRun(from: approval)
    }

    static func finishRejectedBrowserRun(from approval: ApprovalRecord, status: String) async throws {
        try await browserActionRoutes.finishRejectedBrowserRun(from: approval, status: status)
    }

    static func observeBrowserMotorAction(
        runID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await browserActionRoutes.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
    }

    /// `root` is injectable so the memory.repair executor (and its launch
    /// reconciliation) can run against a test data root; every other caller
    /// uses the production default.
    static func annotateApprovalExecution(
        id: String,
        executedAction: JSONValue,
        detail: String,
        root: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws {
        try await ApprovalExecutionAnnotation.annotateApprovalExecution(
            id: id,
            executedAction: executedAction,
            detail: detail,
            root: root
        )
    }

    static func jsonString(_ value: JSONValue, _ key: String) -> String? {
        ApprovalTransactionCoordinator.jsonString(value, key)
    }

    func cancelBrowserRun(id: String?) async throws -> BrowserRun {
        try await Self.browserActionRoutes.cancelBrowserRun(
            id: id,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            decode: Self.decodeBrowserRouteRun
        )
    }
}

private struct NativeBrowserRouteEffects: BrowserRouteEffects {
    func appendNativeActionReceipt(action: NativeActionRecord, status: String, dryRun: Bool, output: JSONValue) async throws -> NativeActionReceipt {
        try await NativeClient.appendNativeActionReceipt(action: action, status: status, dryRun: dryRun, output: output)
    }

    @MainActor
    func navigate(_ url: URL, runID: String) async throws -> BrowserNavigationResult {
        let controller = BrowserWindowController.shared
        // Navigation must not imply fronting (User's 3:30am dream-time popups):
        // load quietly; only the explicit show surfaces front the window.
        controller.ensureWindowLoadedQuietly()
        let nav = try await controller.navigate(url, runID: runID)
        return BrowserNavigationResult(url: nav.url, title: nav.title, httpStatus: nav.httpStatus)
    }

    @MainActor func currentURL() -> String? { BrowserWindowController.shared.currentURL() }
    @MainActor func readText() async throws -> String { try await BrowserWindowController.shared.readText() }
    @MainActor func readLinks() async throws -> [BrowserLink] { try await BrowserWindowController.shared.readLinks() }
    @MainActor func screenshot() async throws -> Data { try await BrowserWindowController.shared.screenshot() }

    func beginNavigation(_ url: URL, runID: String, captureSource: Bool, captureScreenshot: Bool) async -> BrowserNavigationTask {
        let cancellationLatch = BrowserRunCancellationLatch()
        let activeToken = await BrowserActiveRunRegistry.shared.register(runID: runID) {
            cancellationLatch.cancel()
        }
        let captureTask = await MainActor.run {
            let task = Task { @MainActor in
                try await NativeClient.browserActionRoutes.navigateVisibleBrowser(
                    url,
                    runID: runID,
                    captureSource: captureSource,
                    captureScreenshot: captureScreenshot
                )
            }
            // Creating and attaching are one non-suspending MainActor turn, so
            // WebKit cannot begin between task creation and cancellation hookup.
            cancellationLatch.install {
                task.cancel()
                _ = BrowserWindowController.shared.cancelNavigation(runID: runID)
            }
            return task
        }
        return BrowserNavigationTask(task: captureTask, token: activeToken)
    }

    @MainActor
    func finishNavigation(runID: String, token: UUID) {
        BrowserActiveRunRegistry.shared.unregister(runID: runID, token: token)
    }

    func cancelNavigation(runID: String) async {
        _ = await BrowserActiveRunRegistry.shared.cancel(runID: runID)
    }

    func observeMotorAction(_ model: MotorActionReadModel) async {
        await NativeAgentEngine.liveCognition.observeMotorActionState(model)
    }

    func annotateApprovalExecution(id: String, executedAction: JSONValue, detail: String) async throws {
        try await NativeClient.annotateApprovalExecution(id: id, executedAction: executedAction, detail: detail)
    }

    func showProducedImage(at path: URL, name: String) -> (shown: Bool, note: String) {
        let shown = LocalToolImage.showProducedImage(at: path, name: name)
        return (shown.shown, shown.note)
    }
}
