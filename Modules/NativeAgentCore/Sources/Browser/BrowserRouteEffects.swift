import Foundation
import NativeAgentCore
import PersistenceCore

public struct BrowserRouteDecodedRun<Value> {
    public let value: Value
    public let id: String
    public let status: String
    public init(value: Value, id: String, status: String) {
        self.value = value
        self.id = id
        self.status = status
    }
}

/// Physical browser work and app integration; route decisions belong to Browser.
public protocol BrowserRouteEffects: Sendable {
    @MainActor func navigate(_ url: URL, runID: String) async throws -> BrowserNavigationResult
    @MainActor func currentURL() -> String?
    @MainActor func readText() async throws -> String
    @MainActor func readLinks() async throws -> [BrowserLink]
    @MainActor func screenshot() async throws -> Data
    func beginNavigation(_ url: URL, runID: String, captureSource: Bool, captureScreenshot: Bool) async -> BrowserNavigationTask
    @MainActor func finishNavigation(runID: String, token: UUID)
    func cancelNavigation(runID: String) async
    func observeMotorAction(_ model: MotorActionReadModel) async
    func annotateApprovalExecution(id: String, executedAction: JSONValue, detail: String) async throws
    func showProducedImage(at path: URL, name: String) -> (shown: Bool, note: String)
    func appendNativeActionReceipt(action: NativeActionRecord, status: String, dryRun: Bool, output: JSONValue) async throws -> NativeActionReceipt
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
