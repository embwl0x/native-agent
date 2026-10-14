import Foundation
import NativeAgentCore
import PersistenceCore

/// Physical browser work and app integration; route decisions belong to Browser.
public protocol BrowserRouteEffects: Sendable {
    @MainActor func acquireBrowser(runID: String) throws
    @MainActor func releaseBrowser(runID: String)
    @MainActor func navigate(_ url: URL, runID: String) async throws -> BrowserNavigationResult
    @MainActor func currentURL() -> String?
    @MainActor func readText() async throws -> String
    @MainActor func readLinks() async throws -> [BrowserLink]
    @MainActor func screenshot() async throws -> Data
    @MainActor func cancelVisibleNavigation(runID: String)
    func beginNavigation(_ url: URL, runID: String, captureSource: Bool, captureScreenshot: Bool, dataRoot: URL) async -> BrowserNavigationTask
    @MainActor func finishNavigation(runID: String, token: UUID)
    func cancelNavigation(runID: String) async
    func observeMotorAction(_ model: MotorActionReadModel) async
    func annotateApprovalExecution(id: String, executedAction: JSONValue, detail: String, dataRoot: URL) async throws
    func showProducedImage(at path: URL, name: String) -> (shown: Bool, note: String)
    func appendNativeActionReceipt(action: NativeActionRecord, status: String, dryRun: Bool, output: JSONValue,
                                   dataRoot: URL) async throws -> NativeActionReceipt
}

public struct BrowserNavigationTask: Sendable {
    public let task: Task<BrowserVisibleCapture, Error>
    public let token: UUID
    public init(task: Task<BrowserVisibleCapture, Error>, token: UUID) {
        self.task = task
        self.token = token
    }
}

public struct BrowserNavigationResult: Sendable {
    public let url: String
    public let title: String
    public let httpStatus: Int?
    public init(url: String, title: String, httpStatus: Int?) {
        self.url = url
        self.title = title
        self.httpStatus = httpStatus
    }
}

public struct BrowserVisibleCapture: Sendable {
    public var url: URL
    public var nav: BrowserNavigationResult
    public var text: String?
    public var textChars: Int?
    public var links: [BrowserLink]?
    public var screenshot: Data?
    public init(url: URL, nav: BrowserNavigationResult, text: String?, textChars: Int?, links: [BrowserLink]?, screenshot: Data?) {
        self.url = url
        self.nav = nav
        self.text = text
        self.textChars = textChars
        self.links = links
        self.screenshot = screenshot
    }
}

extension BrowserRouteEffects {
    public func beginNavigation(_ url: URL, runID: String, captureSource: Bool, captureScreenshot: Bool, dataRoot: URL) async -> BrowserNavigationTask {
        let cancellationLatch = BrowserRunCancellationLatch()
        let activeToken = await BrowserActiveRunRegistry.shared.register(runID: runID) {
            cancellationLatch.cancel()
        }
        let captureTask = await MainActor.run {
            let task = Task { @MainActor in
                try await BrowserActionRoutes(effects: self).navigateVisibleBrowser(
                    url,
                    runID: runID,
                    captureSource: captureSource,
                    captureScreenshot: captureScreenshot,
                    dataRoot: dataRoot
                )
            }
            // Creating and attaching are one non-suspending MainActor turn, so
            // WebKit cannot begin between task creation and cancellation hookup.
            cancellationLatch.install {
                task.cancel()
                cancelVisibleNavigation(runID: runID)
            }
            return task
        }
        return BrowserNavigationTask(task: captureTask, token: activeToken)
    }

    @MainActor
    public func finishNavigation(runID: String, token: UUID) {
        BrowserActiveRunRegistry.shared.unregister(runID: runID, token: token)
    }

    public func cancelNavigation(runID: String) async {
        _ = await BrowserActiveRunRegistry.shared.cancel(runID: runID)
    }

}
