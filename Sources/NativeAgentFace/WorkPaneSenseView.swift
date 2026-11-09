import SwiftUI
import WebKit
import Foundation
import NativeAgentShared
// Blueprint: | `WorkPaneSenseView.swift` | Shared Sense page and sealed revision-bound WebKit event leaf |

/// Pin the isolated host channel to the presenting sense version; it must never invoke door actions.
struct WorkPaneSenseView: View {
    let presentation: SenseViewFace
    @Environment(AppModel.self) private var appModel
    @State private var error: String?
    private struct Identity: Hashable { let sense: String?; let revision: String? }

    @State private var session = FacePageSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FaceReadStatus(state: presentation.state)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            FaceView(face: WorkPaneFace.sense(presentation), door: ReadOnlyFaceDoor(), session: session, leaf: { block in
                guard block.key == "sense-view", block.ref == presentation.senseID, block.revision == presentation.revision else {
                    return AnyView(Text("This Sense leaf does not match its owner's current presentation.").foregroundStyle(.red))
                }
                return AnyView(SealedSenseWebView(presentation: presentation, client: appModel.client, error: $error)
                    .id(Identity(sense: presentation.senseID, revision: presentation.revision))
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity))
            })
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.bottom, NativeAgentShellLayout.roomGutter)
        .onChange(of: Identity(sense: presentation.senseID, revision: presentation.revision)) { error = nil }
    }
}

private struct SealedSenseWebView: NSViewRepresentable {
    let presentation: SenseViewFace
    let client: any FaceClient
    @Binding var error: String?
    @Environment(\.quietCaptureSession) private var capture

    func makeCoordinator() -> InteractiveSenseView {
        InteractiveSenseView(presentation: presentation, client: client, report: { error = $0 })
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "sense-view")
        let content = configuration.userContentController
        content.add(coordinator, name: "senseEvent")
        // Remove WebRTC before authored code because content blockers miss sockets; CSP blocks fresh realms.
        content.addUserScript(WKUserScript(source: """
        for (const name of ['RTCPeerConnection','webkitRTCPeerConnection',
                            'RTCDataChannel','WebSocket','WebTransport','Worker',
                            'SharedWorker','EventSource']) {
          Object.defineProperty(globalThis, name, {value: undefined, configurable: false, writable: false});
        }
        for (const name of ['geolocation','mediaDevices','serviceWorker']) {
          Object.defineProperty(navigator, name, {value: undefined, configurable: false, writable: false});
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsLinkPreview = false
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        if let capture {
            coordinator.capture = capture.register(view, cancel: { [weak coordinator] in coordinator?.cancel() })
        }
        coordinator.prepare(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: InteractiveSenseView) {
        coordinator.cancel()
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "senseEvent")
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class InteractiveSenseView: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var capture: QuietWebCapture?
        private let presentation: SenseViewFace
        private let client: any FaceClient
        private let report: (String?) -> Void
        private let address = URL(string: "sense-view://sealed/view")
        private var prepareTask: Task<Void, Never>?
        private var eventTasks: [UUID: Task<Void, Never>] = [:]
        private var cancelled = false

        private static let policy = """
            default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; \
            frame-src 'none'; worker-src 'none'; media-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; sandbox \
            allow-scripts
            """
        private static let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^sense-view://sealed/view$"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]
        """

        init(presentation: SenseViewFace, client: any FaceClient, report: @escaping (String?) -> Void) {
            self.presentation = presentation
            self.client = client
            self.report = report
        }

        private func fail(_ message: String) {
            report(message)
            capture?.failed(QuietCaptureSession.failure(message))
        }

        func prepare(_ view: WKWebView) {
            guard let address else {
                fail("The sealed sense view address could not be constructed.")
                return
            }
            guard presentation.html != nil, presentation.senseID != nil, presentation.revision != nil else {
                fail("The body did not supply this sense presentation’s content and identity.")
                return
            }
            prepareTask = Task { [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: "NativeAgentSealedSenseView", encodedContentRuleList: Self.rules)
                    guard !Task.isCancelled, !cancelled else { capture?.failed(CancellationError()); return }
                    guard let rules else {
                        fail("The offline guard did not compile, so this sense view was not opened.")
                        return
                    }
                    view.configuration.userContentController.add(rules)
                    view.load(URLRequest(url: address))
                } catch {
                    if !cancelled { fail("This sense view could not open: \(error.localizedDescription)") }
                }
            }
        }

        func cancel() {
            cancelled = true
            prepareTask?.cancel()
            for task in eventTasks.values { task.cancel() }
            eventTasks.removeAll()
            capture?.close()
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard !cancelled, let address, task.request.url == address else {
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            // The response policy cannot be removed or relaxed by supplied HTML.
            guard let response = HTTPURLResponse(url: address, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": Self.policy,
                "X-DNS-Prefetch-Control": "off",
                "Permissions-Policy": "camera=(), microphone=(), geolocation=(), display-capture=()",
            ]) else {
                fail("The sealed sense view response could not be constructed.")
                task.didFailWithError(URLError(.badServerResponse))
                return
            }
            task.didReceive(response)
            guard let html = presentation.html else {
                task.didFailWithError(URLError(.cannotDecodeContentData)); return
            }
            task.didReceive(Data(("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\""
                + Self.policy + "\"><meta name=\"referrer\" content=\"no-referrer\">" + html).utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let address else { return .cancel }
            let allowed = action.navigationType == .other && action.targetFrame?.isMainFrame == true && action.request.url == address
            if !allowed, action.targetFrame?.isMainFrame == true {
                capture?.failed(QuietCaptureSession.failure("The Sense preview requested navigation outside its sealed content."))
            }
            return allowed ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !cancelled { fail("This sense view could not open: \(error.localizedDescription)") }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { capture?.navigationFinished() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { capture?.failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            capture?.failed(QuietCaptureSession.failure("The Sense preview's WebKit process terminated."))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !cancelled, let address, message.name == "senseEvent", message.frameInfo.isMainFrame,
                  message.frameInfo.request.url == address else { return }
            if let capture {
                capture.failed(QuietCaptureSession.failure("A read-only Sense capture cannot dispatch a Sense event."))
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: message.body, options: [.fragmentsAllowed])
                let event = try JSONDecoder().decode(PartFace.Value.self, from: data)
                guard let identity = presentation.senseID, let revision = presentation.revision else {
                    report("The sense event has no presentation identity."); return
                }
                let id = UUID()
                eventTasks[id] = Task { [weak self] in
                    guard let self else { return }
                    defer { eventTasks[id] = nil }
                    do {
                        let message = try FaceWindowReply.message(await client.act(.senseViewEvent(
                            presentation: identity, revision: revision, event: event)))
                        if !cancelled { report(message) }
                    } catch { if !cancelled { report(error.localizedDescription) } }
                }
            } catch {
                report("This sense sent an invalid event: \(error.localizedDescription)")
            }
        }
    }
}
