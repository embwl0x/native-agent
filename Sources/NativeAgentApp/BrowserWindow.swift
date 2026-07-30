// PATCH-2026-05-06: wkwebview-browser Real WKWebView browser window + NWListener IPC server preferring port 8766
import SwiftUI
import WebKit
import Network
import AppKit

// MARK: - Models

struct NavResult: Codable, Sendable {
    let url: String
    let title: String
    let httpStatus: Int?
}

struct BrowserLink: Codable, Sendable, Hashable {
    let url: String
    let text: String
}

// MARK: - Nav delegate helper (nonisolated, bridges WKWebView callbacks to actor)

final class BrowserNavDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    // Continuation is set before navigation begins and consumed on load/fail.
    var onFinish: ((Result<NavResult, Error>) -> Void)?
    // Real status captured from the main-frame navigation response. nil when no
    // HTTP response was seen — didFinish must NOT fabricate a 200 (404/500 pages
    // load "successfully" and would persist receipts claiming success).
    private var lastHTTPStatus: Int?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Reset per navigation so a prior page's status can't leak into a
        // navigation that never produces an HTTP response.
        lastHTTPStatus = nil
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
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        onFinish?(.success(NavResult(url: url, title: title, httpStatus: lastHTTPStatus)))
        onFinish = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish?(.failure(error))
        onFinish = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFinish?(.failure(error))
        onFinish = nil
    }
}

// MARK: - Active browser run ownership

/// Process-local owner for live visible-browser work. Canonical lifecycle still
/// lives in Browser/runs.json; this registry exists only so a persisted cancel
/// can target the exact in-flight Task and WebKit navigation before a late
/// capture or success receipt is produced. Tokens prevent stale defer cleanup
/// from unregistering a newer run that reused the same id.
@MainActor
final class BrowserActiveRunRegistry {
    static let shared = BrowserActiveRunRegistry()

    private struct Entry {
        var token: UUID
        var cancel: @MainActor () -> Void
    }

    private var entries: [String: Entry] = [:]

    @discardableResult
    func register(runID: String, cancel: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        entries[runID] = Entry(token: token, cancel: cancel)
        return token
    }

    func unregister(runID: String, token: UUID) {
        guard entries[runID]?.token == token else { return }
        entries.removeValue(forKey: runID)
    }

    @discardableResult
    func cancel(runID: String?) -> Bool {
        let key: String?
        if let runID, !runID.isEmpty {
            key = entries[runID] == nil ? nil : runID
        } else {
            key = entries.keys.sorted().first
        }
        guard let key, let entry = entries[key] else { return false }
        entry.cancel()
        return true
    }

    func contains(runID: String) -> Bool {
        entries[runID] != nil
    }
}

// MARK: - BrowserWindowController

@MainActor
final class BrowserWindowController: NSObject, ObservableObject {
    static let shared = BrowserWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private let navDelegate = BrowserNavDelegate()
    private var activeNavigationID: String?

    // IPC server state
    private let ipcListener = NativeLoopbackPortFallbackListener(
        preferredPort: BrowserWindowController.preferredIPCPort,
        label: "BrowserIPC"
    )
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    private(set) var ipcToken: String = ""
    private(set) var ipcPort: UInt16 = 0

    private static let preferredIPCPort: UInt16 = 8766
    /// Drop a connection that hasn't completed its request/response within this window
    /// so stalled/half-open peers can't accumulate in `connections` indefinitely.
    private static let ipcIdleTimeout: Duration = .seconds(15)
    private static let readRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    // MARK: - App support dir + token

    // Phase 11c: use the shared resolver so browser_ipc_token goes to
    // <repo>/data/ rather than ~/Library/Application Support/NativeAgent/.
    private var appSupportDir: URL {
        NativeAgentPaths.dataRoot
    }

    private var tokenFileURL: URL {
        appSupportDir.appendingPathComponent("browser_ipc_token")
    }

    private var descriptorFileURL: URL {
        appSupportDir.appendingPathComponent("browser_ipc.json")
    }

    private func writeDiscovery(token: String, port: UInt16) {
        let dir = appSupportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "host": "127.0.0.1",
            "port": Int(port),
            "url": "http://127.0.0.1:\(port)",
            "token": token,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            _ = NativePrivateFile.write(data, to: descriptorFileURL)
        }
        _ = NativePrivateFile.write(Data(token.utf8), to: tokenFileURL)
    }

    private func removeDiscoveryFiles() {
        try? FileManager.default.removeItem(at: tokenFileURL)
        try? FileManager.default.removeItem(at: descriptorFileURL)
    }

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

    /// C7 / N9 fix (R16): check the WebView's current URL scheme before operating on it.
    /// Returns true only for http and https — the two schemes that can be navigated
    /// to legitimately.  about:, file:, javascript:, data:, and all other schemes are
    /// rejected.  The prior code allowed "about" (e.g. about:blank) as a workaround
    /// for empty-page state, but any bearer-token holder could redirect to about:srcdoc
    /// or use a JS-injected data: URL to side-step the check.
    /// If no page is loaded yet (url is nil) we return true to allow the first navigate.
    private func currentPageSchemeAllowed() -> Bool {
        guard let current = webView?.url else { return true }  // no page loaded yet — allow
        let scheme = current.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    func navigate(_ url: URL, runID: String) async throws -> NavResult {
        ensureWindow()
        guard let webView else { throw BrowserError.notReady }

        // C7 fix: serialize navigation — if a previous navigate is still in
        // progress (onFinish is set), return a busy error rather than letting the
        // second call overwrite onFinish and cause the first continuation to hang.
        if navDelegate.onFinish != nil {
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
                    self.activeNavigationID = nil
                    finish(.failure(BrowserError.timeout))
                }
                navDelegate.onFinish = { [weak self] result in
                    timeoutTask.cancel()
                    self?.activeNavigationID = nil
                    cont.resume(with: result)
                }
                webView.load(URLRequest(url: url))
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

    // N9 fix: JSON-encode every interpolated value so crafted selectors or text
    // containing quotes, backslashes, or other JS metacharacters cannot inject
    // arbitrary JavaScript.  JSONSerialization produces a properly escaped JS
    // string literal including the surrounding double-quotes.
    private func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s),
              let str = String(data: data, encoding: .utf8) else {
            // Fallback: escape the string manually (handles cases where JSON
            // serialisation somehow fails, which shouldn't happen for plain strings).
            let safe = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(safe)\""
        }
        return str
    }

    func click(selector: String) async throws {
        // N9 fix: use JSON-encoded selector literal to prevent JS injection.
        let jsSel = jsStringLiteral(selector)
        _ = try await runJS("document.querySelector(\(jsSel)).click()")
    }

    func fill(selector: String, text: String) async throws {
        // N9 fix: use JSON-encoded selector and text literals to prevent JS injection.
        let jsSel = jsStringLiteral(selector)
        let jsText = jsStringLiteral(text)
        let js = """
        (function(){
          var el = document.querySelector(\(jsSel));
          if(!el) throw new Error('Element not found: ' + \(jsSel));
          el.value = \(jsText);
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
        })()
        """
        _ = try await runJS(js)
    }

    func readText() async throws -> String {
        var last = ""
        for index in 0...Self.readRetryDelays.count {
            let result = try await runJS("""
            (function(){
              var body = document.body;
              var root = document.documentElement;
              return ((body && (body.innerText || body.textContent)) ||
                      (root && (root.innerText || root.textContent)) ||
                      '').trim();
            })()
            """)
            last = result as? String ?? ""
            if !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return last
            }
            if index < Self.readRetryDelays.count {
                try? await Task.sleep(for: Self.readRetryDelays[index])
            }
        }
        return last
    }

    func readLinks() async throws -> [BrowserLink] {
        let js = """
        (function(){
          return Array.from(document.querySelectorAll('a[href]')).slice(0,200).map(function(a){
            return {url: a.href, text: (a.innerText || a.textContent || '').trim()};
          });
        })()
        """
        var links: [BrowserLink] = []
        for index in 0...Self.readRetryDelays.count {
            guard let raw = try await runJS(js) else { return [] }
            links = try decodeBrowserLinks(raw)
            if !links.isEmpty {
                return links
            }
            if index < Self.readRetryDelays.count {
                try? await Task.sleep(for: Self.readRetryDelays[index])
            }
        }
        return links
    }

    private func decodeBrowserLinks(_ raw: Any) throws -> [BrowserLink] {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([BrowserLink].self, from: data)
    }

    func currentURL() -> String? {
        webView?.url?.absoluteString
    }

    private func statusPayload() -> [String: Any] {
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

    // MARK: - IPC server

    private static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }
        let value = "\(host)".lowercased()
        return value == "localhost"
            || value == "127.0.0.1"
            || value == "::1"
            || value.contains("127.0.0.1")
            || value.contains("::1")
    }

    func startIPCServer() {
        guard !ipcListener.isActive, ipcToken.isEmpty else { return }

        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            NSLog("NativeAgent browser IPC failed to generate a secure token")
            return
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        ipcToken = token
        ipcPort = 0
        removeDiscoveryFiles()
        let started = ipcListener.start(
            onReady: { [weak self] port in
                Task { @MainActor in self?.handleIPCListenerReady(token: token, port: port) }
            },
            onConnection: { [weak self] connection in
                Task { @MainActor in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.acceptIPC(connection)
                }
            },
            onTerminated: { [weak self] in
                Task { @MainActor in self?.handleIPCListenerTerminated(token: token) }
            }
        )
        if !started { handleIPCListenerTerminated(token: token) }
    }

    private func handleIPCListenerReady(token: String, port: UInt16) {
        guard ipcToken == token else { return }
        ipcPort = port
        writeDiscovery(token: token, port: port)
        print("[BrowserIPC] listening on 127.0.0.1:\(port)")
    }

    private func handleIPCListenerTerminated(token: String) {
        guard ipcToken == token else { return }
        ipcToken = ""
        ipcPort = 0
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for timeout in connectionTimeouts.values { timeout.cancel() }
        connectionTimeouts.removeAll()
        removeDiscoveryFiles()
    }

    func stopIPCServer() {
        ipcListener.stop()
        ipcToken = ""
        ipcPort = 0
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for timeout in connectionTimeouts.values { timeout.cancel() }
        connectionTimeouts.removeAll()
        removeDiscoveryFiles()
    }

    private func acceptIPC(_ conn: NWConnection) {
        guard ipcListener.isActive, !ipcToken.isEmpty, ipcPort != 0 else {
            conn.cancel()
            return
        }
        guard Self.endpointIsLoopback(conn.endpoint) else {
            conn.cancel()
            return
        }
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { Task { @MainActor in self?.dropIPCConnection(key) } }
            if case .failed = state    { Task { @MainActor in self?.dropIPCConnection(key) } }
        }
        conn.start(queue: .global(qos: .userInitiated))
        // Idle/read timeout: a peer that connects but never completes a request would
        // otherwise sit in `connections` forever. Cancel it after the timeout; the
        // connection's .cancelled handler then evicts it from the dict.
        connectionTimeouts[key] = Task { [weak self, weak conn] in
            try? await Task.sleep(for: Self.ipcIdleTimeout)
            guard !Task.isCancelled else { return }
            conn?.cancel()
            _ = self
        }
        Self.readIPCRequest(conn, buffered: Data(), server: self)
    }

    /// Evict a connection and tear down its idle-timeout Task. Safe to call multiple times.
    private func dropIPCConnection(_ key: ObjectIdentifier) {
        connections.removeValue(forKey: key)
        connectionTimeouts.removeValue(forKey: key)?.cancel()
    }

    // MARK: - HTTP parsing (nonisolated)

    nonisolated private static func readIPCRequest(_ conn: NWConnection, buffered: Data, server: BrowserWindowController) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak server] data, _, isComplete, error in
            guard let server else { return }
            if error != nil { conn.cancel(); return }
            var buf = buffered
            if let d = data { buf.append(d) }

            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { conn.cancel() } else { Self.readIPCRequest(conn, buffered: buf, server: server) }
                return
            }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else { conn.cancel(); return }

            let lines = headerStr.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else { conn.cancel(); return }
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = parts[0]
            let path = parts[1].components(separatedBy: "?").first ?? parts[1]

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    let k = String(line[..<colon]).lowercased()
                    let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[k] = v
                }
            }

            guard let contentLength = Self.parseContentLength(headers, maxBytes: 2 * 1024 * 1024) else {
                Self.writeRawJSON(conn, status: 413, obj: ["error": "invalid_content_length"])
                return
            }
            let bodyStart = headerEnd.upperBound
            let bodyAlready = buf.subdata(in: bodyStart..<buf.count)

            if bodyAlready.count >= contentLength {
                let body = Data(bodyAlready.prefix(contentLength))
                Task { @MainActor in
                    server.routeIPC(conn: conn, method: method, path: path, headers: headers, body: body)
                }
            } else {
                Self.readIPCBody(conn, have: bodyAlready, need: contentLength, method: method, path: path, headers: headers, server: server)
            }
        }
    }

    nonisolated private static func parseContentLength(_ headers: [String: String], maxBytes: Int) -> Int? {
        guard let raw = headers["content-length"], !raw.isEmpty else { return 0 }
        guard let length = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              length >= 0,
              length <= maxBytes
        else {
            return nil
        }
        return length
    }

    nonisolated private static func readIPCBody(_ conn: NWConnection, have: Data, need: Int, method: String, path: String, headers: [String: String], server: BrowserWindowController) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: max(1, need - have.count)) { [weak server] data, _, _, _ in
            guard let server else { return }
            var acc = have
            if let d = data { acc.append(d) }
            if acc.count >= need {
                let body = Data(acc.prefix(need))
                Task { @MainActor in
                    server.routeIPC(conn: conn, method: method, path: path, headers: headers, body: body)
                }
            } else {
                Self.readIPCBody(conn, have: acc, need: need, method: method, path: path, headers: headers, server: server)
            }
        }
    }

    // MARK: - Routing

    private func routeIPC(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // Request fully read & routed — swap the 15s idle/read deadline for a
        // generous routed-OPERATION deadline. The 15s would kill a legitimate slow
        // navigate mid-flight; removing the timeout entirely would leak a connection
        // wedged on a hung WebKit callback. Re-arm to 120s: long enough for any real
        // browser op, short enough to reap a wedge. dropIPCConnection cancels it when
        // the connection ends.
        let timeoutKey = ObjectIdentifier(conn)
        connectionTimeouts[timeoutKey]?.cancel()
        connectionTimeouts[timeoutKey] = Task { [weak self, weak conn] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            conn?.cancel()
            _ = self
        }
        // Auth check (unauthenticated health only)
        if path != "/browser/status" {
            let auth = headers["authorization"] ?? ""
            guard auth == "Bearer \(ipcToken)" else {
                writeIPCJSON(conn, status: 401, obj: ["error": "unauthorized"])
                return
            }
        }

        Task {
            do {
                let response = try await self.handleIPCRoute(method: method, path: path, body: body)
                self.writeIPCJSON(conn, status: 200, obj: response)
            } catch {
                self.writeIPCJSON(conn, status: 500, obj: ["error": error.localizedDescription])
            }
        }
    }

    private func handleIPCRoute(method: String, path: String, body: Data) async throws -> [String: Any] {
        let json = body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])

        switch path {
        case "/browser/navigate":
            guard let urlStr = json["url"] as? String, let url = URL(string: urlStr) else {
                throw BrowserError.badRequest("url required")
            }
            // C7 fix: reject non-http/https schemes so bearer-token holders
            // cannot exfiltrate local files via file:// URLs.
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" else {
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Only http and https URLs are permitted; got '\(scheme)://'"]
            }
            // C7 busy rejection: serialise navigation
            if navDelegate.onFinish != nil {
                return ["ok": false, "error": "browser_busy",
                        "detail": "Another navigation is already in progress — retry after it completes"]
            }
            let requestedRunID = (json["runId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let runID = requestedRunID?.isEmpty == false
                ? requestedRunID!
                : "ipc-\(UUID().uuidString.lowercased())"
            let result = try await navigate(url, runID: runID)
            // httpStatus is Optional after the real-status fix — a bare
            // `as Any` wraps .none, which JSONSerialization rejects and the
            // whole response drops exactly on the nil-status path (gpt-5.5
            // review blocker). NSNull is the JSON-safe absent marker.
            return ["ok": true, "url": result.url, "title": result.title,
                    "httpStatus": result.httpStatus.map { $0 as Any } ?? NSNull()]

        case "/browser/screenshot":
            // N8 fix: check current page scheme before operating — a JS redirect to
            // file:// after a validated navigate would otherwise let read/screenshot
            // exfiltrate local files.
            if !currentPageSchemeAllowed() {
                let cur = webView?.url?.scheme ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            let png = try await screenshot()
            return ["ok": true, "png_base64": png.base64EncodedString()]

        case "/browser/click":
            guard let sel = json["selector"] as? String else { throw BrowserError.badRequest("selector required") }
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed() {
                let cur = webView?.url?.scheme ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            try await click(selector: sel)
            return ["ok": true]

        case "/browser/fill":
            guard let sel = json["selector"] as? String,
                  let text = json["text"] as? String else { throw BrowserError.badRequest("selector and text required") }
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed() {
                let cur = webView?.url?.scheme ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            try await fill(selector: sel, text: text)
            return ["ok": true]

        case "/browser/read_text":
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed() {
                let cur = webView?.url?.scheme ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            let text = try await readText()
            return ["ok": true, "text": text]

        case "/browser/read_links":
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed() {
                let cur = webView?.url?.scheme ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            let links = try await readLinks()
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(links))
            return ["ok": true, "links": encoded]

        case "/browser/show":
            showWindow()
            return statusPayload()

        case "/browser/hide":
            hideWindow()
            return statusPayload()

        case "/browser/status":
            return statusPayload()

        default:
            throw BrowserError.badRequest("unknown path: \(path)")
        }
    }

    // MARK: - HTTP response helpers

    private func writeIPCJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        Self.writeRawJSON(conn, status: status, obj: obj)
    }

    nonisolated private static func writeRawJSON(_ conn: NWConnection, status: Int, obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { conn.cancel(); return }
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 413: statusText = "Payload Too Large"
        default:  statusText = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(data)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Errors

enum BrowserError: LocalizedError {
    case notReady
    case screenshotFailed
    case badRequest(String)
    /// C7 fix: returned when navigate is called while another navigation is in progress.
    case busy
    case timeout
    /// C7 fix (N8): returned when the current page's URL scheme is not http/https.
    case unsafeScheme(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "Browser window is not ready"
        case .screenshotFailed: return "Failed to capture screenshot"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .busy: return "Browser is busy with another navigation — try again shortly"
        case .timeout: return "Browser navigation timed out"
        case .unsafeScheme(let scheme): return "Current page scheme '\(scheme)' is not allowed; only http/https are permitted"
        }
    }
}
