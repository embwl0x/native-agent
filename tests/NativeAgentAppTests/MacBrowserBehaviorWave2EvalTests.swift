import Foundation
import Network
import Testing
@testable import NativeAgentApp

// Real loopback transport evaluations for the visible-browser IPC server.
// They deliberately speak HTTP over a real NWConnection instead of calling the
// private router: this is the boundary that a local companion actually sees.

private func browserIPCWave2Root() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentBrowserIPCWave2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private enum BrowserIPCWave2Error: Error {
    case connection(String)
    case incompleteResponse
}

/// A deliberately tiny HTTP peer for WKWebView integration.  It is local,
/// per-test, and does not depend on Internet reachability or browser state.
private final class BrowserHTTPWave2Fixture: @unchecked Sendable {
    private let listener: NWListener

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    deinit { listener.cancel() }

    func url(path: String) async throws -> URL {
        for _ in 0..<80 {
            if let port = listener.port, port.rawValue != 0 {
                return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)\(path)"))
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BrowserIPCWave2Error.connection("fixture did not bind a port")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: "\n", maxSplits: 1).first
                .flatMap { $0.split(separator: " ").dropFirst().first }
                .map(String.init) ?? "/"
            // Keep a navigation pending so the test can prove cancellation
            // clears BrowserWindowController's real single-flight latch.
            guard path != "/slow" else { return }

            if path == "/redirect-data" {
                let response = "HTTP/1.1 302 Found\r\nLocation: data:text/html,blocked\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            let status = path == "/missing" ? 404 : 200
            let reason = status == 404 ? "Not Found" : "OK"
            let body: String
            switch path {
            case "/form":
                body = "<html><head><title>Fixture form</title></head><body><input id=\"target\"><button id=\"go\" onclick=\"document.body.dataset.clicked='yes'\">Go</button></body></html>"
            case "/delayed-text":
                body = "<html><body><script src=\"/delayed-text-script\"></script></body></html>"
            case "/delayed-text-script":
                body = "setTimeout(function(){document.body.innerText='late text';}, 300);"
            case "/delayed-links":
                body = "<html><body><script src=\"/delayed-links-script\"></script></body></html>"
            case "/delayed-links-script":
                body = "setTimeout(function(){document.body.innerHTML='<a href=\"/target\">Late link</a>';}, 300);"
            default:
                body = "<html><head><title>Fixture \(status)</title></head><body>fixture</body></html>"
            }
            let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private func browserIPCWave2Request(port: UInt16, request: String) async throws -> String {
    let connection = NWConnection(
        host: NWEndpoint.Host("127.0.0.1"),
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
    )
    connection.start(queue: .global(qos: .userInitiated))
    defer { connection.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: BrowserIPCWave2Error.connection(error.localizedDescription))
            } else {
                continuation.resume()
            }
        })
    }

    return try await withCheckedThrowingContinuation { continuation in
        final class Receiver: @unchecked Sendable {
            var bytes = Data()
            let continuation: CheckedContinuation<String, Error>

            init(_ continuation: CheckedContinuation<String, Error>) {
                self.continuation = continuation
            }

            func receive(from connection: NWConnection) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) { data, _, complete, error in
                    if let error {
                        self.continuation.resume(throwing: BrowserIPCWave2Error.connection(error.localizedDescription))
                        return
                    }
                    if let data { self.bytes.append(data) }
                    if complete {
                        guard let text = String(data: self.bytes, encoding: .utf8) else {
                            self.continuation.resume(throwing: BrowserIPCWave2Error.incompleteResponse)
                            return
                        }
                        self.continuation.resume(returning: text)
                    } else {
                        self.receive(from: connection)
                    }
                }
            }
        }
        Receiver(continuation).receive(from: connection)
    }
}

private func browserIPCWave2JSON(_ response: String) throws -> [String: Any] {
    guard let separator = response.range(of: "\r\n\r\n") else { throw BrowserIPCWave2Error.incompleteResponse }
    return try #require(JSONSerialization.jsonObject(with: Data(response[separator.upperBound...].utf8)) as? [String: Any])
}

@Suite("Mac browser IPC behavior — wave 2", .serialized)
struct MacBrowserBehaviorWave2EvalTests {
    @Test("WebKit fill/click JSON-encodes hostile text and reads delayed page content through the real retry ladder")
    @MainActor
    func browserJavaScriptActionsAndReadRetriesExecuteAgainstLocalWebKit() async throws {
        let root = try browserIPCWave2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BrowserHTTPWave2Fixture()
        let controller = BrowserWindowController(dataRoot: root)
        let hostileText = #"x'; document.body.dataset.injected = 'yes'; //"#

        let formURL = try await fixture.url(path: "/form")
        let form = try await controller.navigate(formURL, runID: "form")
        #expect(form.url == formURL.absoluteString)
        // WKWebView may deliver didFinish one run-loop turn before its content
        // process accepts evaluateJavaScript.  Wait on the observed URL rather
        // than adding an arbitrary whole-test delay.
        for _ in 0..<20 where controller.currentURL() != formURL.absoluteString {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.currentURL() == formURL.absoluteString)
        try await controller.fill(selector: "#target", text: hostileText)
        let saved = try await controller.runJS("document.querySelector('#target').value") as? String
        let injected = try await controller.runJS("document.body.dataset.injected || null") as? String
        #expect(saved == hostileText)
        #expect(injected == nil)

        try await controller.click(selector: "#go")
        let clicked = try await controller.runJS("document.body.dataset.clicked") as? String
        #expect(clicked == "yes")

        try await controller.navigate(try await fixture.url(path: "/delayed-text"), runID: "delayed-text")
        let delayedText = try await controller.readText()
        #expect(delayedText == "late text")

        try await controller.navigate(try await fixture.url(path: "/delayed-links"), runID: "delayed-links")
        let links = try await controller.readLinks()
        let expectedURL = try await fixture.url(path: "/target").absoluteString
        #expect(links == [BrowserLink(url: expectedURL, text: "Late link")])
    }

    @Test("quiet WebKit navigation observes the real HTTP result without showing the browser window, and cancellation permits a retry")
    @MainActor
    func browserNavigationIsQuietAndItsSingleFlightLatchRecovers() async throws {
        let root = try browserIPCWave2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BrowserHTTPWave2Fixture()
        let controller = BrowserWindowController(dataRoot: root)
        defer { controller.stopIPCServer() }
        controller.startIPCServer()
        for _ in 0..<80 where controller.ipcPort == 0 { try await Task.sleep(for: .milliseconds(25)) }
        let ipcPort = try #require(controller.ipcPort == 0 ? nil : controller.ipcPort)

        let missing = try await controller.navigate(try await fixture.url(path: "/missing"), runID: "missing")
        #expect(missing.httpStatus == 404)
        #expect(missing.url.contains("/missing"))

        let quietStatus = try await browserIPCWave2Request(
            port: ipcPort,
            request: "GET /browser/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        let quietPayload = try browserIPCWave2JSON(quietStatus)
        #expect(quietPayload["ready"] as? Bool == true)
        #expect(quietPayload["visible"] as? Bool == false)

        let slowTask = Task { @MainActor in
            try await controller.navigate(try await fixture.url(path: "/slow"), runID: "slow")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.cancelNavigation(runID: "slow"))
        do {
            _ = try await slowTask.value
            Issue.record("cancelled navigation unexpectedly succeeded")
        } catch is CancellationError {
            // expected
        }

        let retry = try await controller.navigate(try await fixture.url(path: "/ok"), runID: "retry")
        #expect(retry.httpStatus == 200)
        #expect(retry.url.contains("/ok"))
    }

    @Test("main-frame redirects cannot escape HTTP(S) capture authority")
    @MainActor
    func browserNavigationRejectsUnsafeRedirectAndRecoversItsLatch() async throws {
        let root = try browserIPCWave2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BrowserHTTPWave2Fixture()
        let controller = BrowserWindowController(dataRoot: root)

        do {
            _ = try await controller.navigate(
                try await fixture.url(path: "/redirect-data"),
                runID: "unsafe-redirect"
            )
            Issue.record("a data: redirect unexpectedly became browser capture authority")
        } catch BrowserError.unsafeScheme(let scheme) {
            #expect(scheme == "data")
        } catch {
            Issue.record("unsafe redirect returned the wrong failure: \(error)")
        }

        let retry = try await controller.navigate(
            try await fixture.url(path: "/ok"),
            runID: "safe-retry"
        )
        #expect(retry.httpStatus == 200)
        #expect(retry.url.contains("/ok"))
    }

    @Test("real loopback IPC publishes a live descriptor, exposes only status without a bearer, and removes it on stop")
    @MainActor
    func browserIPCLifecycleAndStatusTruth() async throws {
        let root = try browserIPCWave2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserWindowController(dataRoot: root)
        defer { controller.stopIPCServer() }

        controller.startIPCServer()
        for _ in 0..<80 where controller.ipcPort == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let port = try #require(controller.ipcPort == 0 ? nil : controller.ipcPort)
        let descriptorURL = root.appendingPathComponent("browser_ipc.json")
        let descriptor = try #require(
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL))) as? [String: Any]
        )
        #expect(descriptor["host"] as? String == "127.0.0.1")
        #expect(descriptor["port"] as? Int == Int(port))
        #expect(descriptor["token"] as? String == controller.ipcToken)

        let response = try await browserIPCWave2Request(
            port: port,
            request: "GET /browser/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 200"))
        let status = try browserIPCWave2JSON(response)
        #expect(status["ok"] as? Bool == true)
        #expect(status["ready"] as? Bool == false)
        #expect(status["ipcPort"] as? Int == Int(port))

        controller.stopIPCServer()
        #expect(!FileManager.default.fileExists(atPath: descriptorURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("browser_ipc_token").path))
    }

    @Test("real IPC rejects unauthenticated mutations and never creates a browser window as a side effect")
    @MainActor
    func browserIPCRejectsUnauthenticatedMutationBeforeWebKit() async throws {
        let root = try browserIPCWave2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserWindowController(dataRoot: root)
        defer { controller.stopIPCServer() }
        controller.startIPCServer()
        for _ in 0..<80 where controller.ipcPort == 0 { try await Task.sleep(for: .milliseconds(25)) }
        let port = try #require(controller.ipcPort == 0 ? nil : controller.ipcPort)

        let denied = try await browserIPCWave2Request(
            port: port,
            request: "POST /browser/navigate HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        #expect(denied.hasPrefix("HTTP/1.1 401"))
        #expect((try browserIPCWave2JSON(denied))["error"] as? String == "unauthorized")

        let status = try await browserIPCWave2Request(
            port: port,
            request: "GET /browser/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect((try browserIPCWave2JSON(status))["ready"] as? Bool == false)
    }

    @Test("real IPC enforces request bounds and rejects a bearer-authorized non-web navigation before WebKit")
    @MainActor
    func browserIPCRequestBoundsAndUnsafeURLTruth() async throws {
        let root = try browserIPCWave2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserWindowController(dataRoot: root)
        defer { controller.stopIPCServer() }
        controller.startIPCServer()
        for _ in 0..<80 where controller.ipcPort == 0 { try await Task.sleep(for: .milliseconds(25)) }
        let port = try #require(controller.ipcPort == 0 ? nil : controller.ipcPort)

        let oversized = try await browserIPCWave2Request(
            port: port,
            request: "POST /browser/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097153\r\nConnection: close\r\n\r\n"
        )
        #expect(oversized.hasPrefix("HTTP/1.1 413"))
        #expect((try browserIPCWave2JSON(oversized))["error"] as? String == "invalid_content_length")

        let body = #"{"url":"file:///private/secret.txt"}"#
        let rejected = try await browserIPCWave2Request(
            port: port,
            request: "POST /browser/navigate HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(controller.ipcToken)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        )
        #expect(rejected.hasPrefix("HTTP/1.1 200"))
        let payload = try browserIPCWave2JSON(rejected)
        #expect(payload["ok"] as? Bool == false)
        #expect(payload["error"] as? String == "url_scheme_not_allowed")

        let status = try await browserIPCWave2Request(
            port: port,
            request: "GET /browser/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect((try browserIPCWave2JSON(status))["ready"] as? Bool == false)
    }
}
