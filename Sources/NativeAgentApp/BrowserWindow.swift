import EngineRuntime
// PATCH-2026-05-06: wkwebview-browser Real WKWebView browser window + NWListener IPC server on this install's fixed port (8766)
import SwiftUI
import WebKit
import Network
import AppKit
import PersistenceCore
import ApprovalInbox
import AppToolRuntime
import Browser
import Dispatcher
import NativeAgentCore

// MARK: - Models

struct NavResult: Codable, Sendable {
    let url: String
    let title: String
    let httpStatus: Int?
}

typealias BrowserLink = EngineRuntime.BrowserLink

// MARK: - Nav delegate helper (nonisolated, bridges WKWebView callbacks to actor)

final class BrowserNavDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    // Continuation is set before navigation begins and consumed on load/fail.
    var onFinish: ((Result<NavResult, Error>) -> Void)?
    /// The one navigation whose completion may settle `onFinish`.  A newly
    /// created WKWebView can finish its implicit about:blank navigation after
    /// the caller has armed a real load; accepting that callback used to return
    /// a successful result for about:blank and leave the requested page loading
    /// invisibly in the background.
    var expectedNavigation: WKNavigation?
    // Real status captured from the main-frame navigation response. nil when no
    // HTTP response was seen — didFinish must NOT fabricate a 200 (404/500 pages
    // load "successfully" and would persist receipts claiming success).
    private var lastHTTPStatus: Int?
    /// A rejected top-level redirect is carried into WebKit's failure callback
    /// so callers receive the exact policy reason instead of a generic cancel.
    var rejectedScheme: String?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Reset per navigation so a prior page's status can't leak into a
        // navigation that never produces an HTTP response.
        lastHTTPStatus = nil
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // The explicit entry URL is checked by every route, but redirects are
        // new navigation actions. Keep subframes compatible with the web while
        // refusing a top-level hop into file:, data:, javascript:, or another
        // local/custom scheme before it becomes capture authority.
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https"
            || (scheme == "about" && onFinish == nil) {
            decisionHandler(.allow)
            return
        }
        rejectedScheme = scheme.isEmpty ? "unknown" : scheme
        decisionHandler(.cancel)
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            lastHTTPStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === expectedNavigation else { return }
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        let scheme = webView.url?.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            onFinish?(.success(NavResult(url: url, title: title, httpStatus: lastHTTPStatus)))
        } else {
            onFinish?(.failure(BrowserError.unsafeScheme(scheme.isEmpty ? "unknown" : scheme)))
        }
        onFinish = nil
        expectedNavigation = nil
        rejectedScheme = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === expectedNavigation else { return }
        finishFailure(error)
    }

    private func finishFailure(_ error: Error) {
        // WebKit may reject some restricted schemes before delivering the
        // navigation-action policy callback. Recover the exact destination
        // from its failure metadata so the caller still receives the perimeter
        // reason instead of an opaque WebKit error.
        let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let failingScheme = failingURL?.scheme?.lowercased()
        let unsafeFailingScheme = failingScheme.flatMap { scheme in
            scheme == "http" || scheme == "https" ? nil : scheme
        }
        let failure: Error = (rejectedScheme ?? unsafeFailingScheme)
            .map(BrowserError.unsafeScheme) ?? error
        onFinish?(.failure(failure))
        onFinish = nil
        expectedNavigation = nil
        rejectedScheme = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === expectedNavigation else { return }
        finishFailure(error)
    }
}

// MARK: - BrowserWindowController

@MainActor
final class BrowserWindowController: NSObject, ObservableObject {
    static let shared = BrowserWindowController()

    /// The production controller uses the canonical data root.  Tests may give
    /// the real loopback listener a disposable root so its discovery token can
    /// be exercised without ever touching a resident app's IPC files.
    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
        super.init()
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private let navDelegate = BrowserNavDelegate()
    fileprivate var navigationInProgress: Bool { navDelegate.onFinish != nil }
    private var activeNavigationID: String?
    private var browserOwnerID: String?

    private let ipcTransport = NativeLoopbackListener(port: InstallPaths.current.loopbackPorts().browserIPC, label: "BrowserIPC")
    private lazy var ipcServer = BrowserIPCServer(dataRoot: dataRoot, transport: ipcTransport, effects: AppBrowserRouteEffects())
    private let dataRoot: URL
    nonisolated var ipcListenerHealth: NativeLoopbackListener.Health { ipcTransport.health }
    var ipcPort: UInt16 { ipcServer.ipcPort }
    func startIPCServer() { ipcServer.start() }
    func stopIPCServer() { ipcServer.stop() }

    // MARK: - Window lifecycle

    func ensureWindow() {
        guard window == nil else { return }

        let config = WKWebViewConfiguration()
        // Browser routes enforce http/https before navigation and read/screenshot
        // actions. WKPreferences KVC file-access keys are not stable across macOS
        // and can throw NSUnknownKeyException during window creation.
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.customUserAgent = "NativeAgent/1.0 WKWebView"
        wv.navigationDelegate = navDelegate
        self.webView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "NativeAgent Browser"
        win.identifier = NSUserInterfaceItemIdentifier("visible-browser")
        win.contentView = wv
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
    }

    func showWindow() {
        ensureWindow()
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// Load-capable WITHOUT stealing the screen (2026-07-12, User's 3:30am
    /// incident): agent-lane navigations (dream/trigger/background turns,
    /// bridge routes) were force-fronting the browser + activating the app
    /// via showWindow() on every navigate — a Google window popping over
    /// whatever User was doing, twice a night at dream time. Navigation now
    /// only ensures the window EXISTS (WKWebView needs a window to render
    /// for text/screenshot capture); it never orders it front, never
    /// activates the app, and never yanks it out of miniaturization. The
    /// explicit show surfaces (UI menu, /browser/show, browser_show tool)
    /// still call showWindow() — deliberate showing stays deliberate.
    func ensureWindowLoadedQuietly() {
        ensureWindow()
    }

    func hideWindow() {
        window?.orderOut(nil)
    }

    // MARK: - Browser actions

    func acquireBrowser(runID: String) throws {
        guard browserOwnerID == nil, navDelegate.onFinish == nil else { throw BrowserError.busy }
        browserOwnerID = runID
    }

    func releaseBrowser(runID: String) {
        if browserOwnerID == runID { browserOwnerID = nil }
    }

    func navigate(_ url: URL, runID: String, ownerID: String) async throws -> NavResult {
        ensureWindow()
        guard let webView else { throw BrowserError.notReady }

        // Ownership spans navigation and captures; every navigation has an owner.
        if navDelegate.onFinish != nil || browserOwnerID != ownerID {
            throw BrowserError.busy
        }

        activeNavigationID = runID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          let self,
                          self.activeNavigationID == runID,
                          let finish = self.navDelegate.onFinish else { return }
                    self.webView?.stopLoading()
                    self.navDelegate.onFinish = nil
                    self.navDelegate.expectedNavigation = nil
                    self.activeNavigationID = nil
                    finish(.failure(BrowserError.timeout))
                }
                navDelegate.rejectedScheme = nil
                navDelegate.onFinish = { [weak self] result in
                    timeoutTask.cancel()
                    self?.activeNavigationID = nil
                    cont.resume(with: result)
                }
                guard let navigation = webView.load(URLRequest(url: url)) else {
                    timeoutTask.cancel()
                    navDelegate.onFinish = nil
                    activeNavigationID = nil
                    cont.resume(throwing: BrowserError.notReady)
                    return
                }
                navDelegate.expectedNavigation = navigation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                _ = self?.cancelNavigation(runID: runID)
            }
        }
    }

    /// Stop exactly the active navigation (or whichever navigation is active
    /// when runID is nil) and resume its awaiting Task as canceled. Clearing the
    /// delegate callback before stopLoading prevents WebKit's later failure
    /// callback from double-resuming the continuation.
    @discardableResult
    func cancelNavigation(runID: String?) -> Bool {
        guard let activeNavigationID,
              runID == nil || runID?.isEmpty == true || runID == activeNavigationID,
              let finish = navDelegate.onFinish else { return false }
        webView?.stopLoading()
        navDelegate.onFinish = nil
        navDelegate.expectedNavigation = nil
        self.activeNavigationID = nil
        finish(.failure(CancellationError()))
        return true
    }

    func screenshot() async throws -> Data {
        ensureWindow()
        guard let webView else { throw BrowserError.notReady }
        let config = WKSnapshotConfiguration()
        return try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiff),
                      let png = bitmapRep.representation(using: .png, properties: [:]) else {
                    cont.resume(throwing: BrowserError.screenshotFailed)
                    return
                }
                cont.resume(returning: png)
            }
        }
    }

    func runJS(_ js: String) async throws -> Any? {
        guard let webView else { throw BrowserError.notReady }
        // Wrap the untyped result in a sendable box to satisfy Swift 6 strict concurrency.
        final class Box: @unchecked Sendable { let value: Any?; init(_ v: Any?) { value = v } }
        let box: Box = try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(js) { result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: Box(result)) }
            }
        }
        return box.value
    }

    func click(selector: String) async throws {
        try await BrowserActionRoutes.click(selector: selector, runJS: runJS)
    }

    func fill(selector: String, text: String) async throws {
        try await BrowserActionRoutes.fill(selector: selector, text: text, runJS: runJS)
    }

    func readText() async throws -> String {
        try await BrowserActionRoutes.readText(runJS: runJS)
    }

    func readLinks() async throws -> [BrowserLink] {
        try await BrowserActionRoutes.readLinks(runJS: runJS)
    }

    func currentURL() -> String? {
        webView?.url?.absoluteString
    }

    fileprivate func statusPayload() -> [String: Any] {
        [
            "ok": true,
            "visible": window?.isVisible ?? false,
            "currentUrl": currentURL() ?? NSNull(),
            "ready": webView != nil,
            "windowTitle": window?.title ?? NSNull(),
            "miniaturized": window?.isMiniaturized ?? false,
            "keyWindow": window?.isKeyWindow ?? false,
            "mainWindow": window?.isMainWindow ?? false,
            "ipcPort": ipcPort,
        ]
    }

}

// MARK: - Browser route effects

extension BrowserActionRoutes {
    /// Browser Core's routes over this app's visible browser window.
    static var app: BrowserActionRoutes { BrowserActionRoutes(effects: AppBrowserRouteEffects()) }
}

private struct AppBrowserRouteEffects: BrowserIPCWindowEffects {
    @MainActor var navigationInProgress: Bool { BrowserWindowController.shared.navigationInProgress }
    @MainActor func click(selector: String) async throws { try await BrowserWindowController.shared.click(selector: selector) }
    @MainActor func fill(selector: String, text: String) async throws { try await BrowserWindowController.shared.fill(selector: selector, text: text) }
    @MainActor func showWindow() { BrowserWindowController.shared.showWindow() }
    @MainActor func hideWindow() { BrowserWindowController.shared.hideWindow() }
    @MainActor func statusPayload() -> [String: Any] { BrowserWindowController.shared.statusPayload() }

    @MainActor
    func acquireBrowser(runID: String) throws {
        try BrowserWindowController.shared.acquireBrowser(runID: runID)
    }

    @MainActor
    func releaseBrowser(runID: String) {
        BrowserWindowController.shared.releaseBrowser(runID: runID)
    }

    func appendNativeActionReceipt(action: NativeActionRecord, status: String, dryRun: Bool, output: JSONValue,
                                   dataRoot: URL) async throws -> NativeActionReceipt {
        try await NativeActionRoutes.appendNativeActionReceipt(
            action: action, status: status, dryRun: dryRun, output: output, dataRoot: dataRoot
        )
    }

    @MainActor
    func navigate(_ url: URL, runID: String) async throws -> BrowserNavigationResult {
        let controller = BrowserWindowController.shared
        // Navigation must not imply fronting (User's 3:30am dream-time popups):
        // load quietly; only the explicit show surfaces front the window.
        controller.ensureWindowLoadedQuietly()
        let nav = try await controller.navigate(url, runID: runID, ownerID: runID)
        return BrowserNavigationResult(url: nav.url, title: nav.title, httpStatus: nav.httpStatus)
    }

    @MainActor func currentURL() -> String? { BrowserWindowController.shared.currentURL() }
    @MainActor func readText() async throws -> String { try await BrowserWindowController.shared.readText() }
    @MainActor func readLinks() async throws -> [BrowserLink] { try await BrowserWindowController.shared.readLinks() }
    @MainActor func screenshot() async throws -> Data { try await BrowserWindowController.shared.screenshot() }

    @MainActor
    func cancelVisibleNavigation(runID: String) {
        _ = BrowserWindowController.shared.cancelNavigation(runID: runID)
    }

    func observeMotorAction(_ model: MotorActionReadModel) async {
        await NativeAgentEngine.liveCognition.observeMotorActionState(model)
    }

    func annotateApprovalExecution(id: String, executedAction: JSONValue, detail: String, dataRoot: URL) async throws {
        try await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
            id, executedAction: executedAction, detail: detail
        )
    }

    func showProducedImage(at path: URL, name: String) -> (shown: Bool, note: String) {
        let shown = LocalToolImage.showProducedImage(at: path, name: name)
        return (shown.shown, shown.note)
    }
}
