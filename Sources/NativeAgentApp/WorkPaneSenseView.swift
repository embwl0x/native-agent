import SwiftUI
import WebKit
import Senses
import PersistenceCore

/// A separate WebKit host, never the browser or Make host. Its only channel
/// is pinned to the presenting sense version and cannot invoke door actions.
struct WorkPaneSenseView: View {
    let presentation: SenseInteractiveView
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title).font(ShellType.labelMedium)
            if let error {
                Text(error).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
            }
            SealedSenseWebView(presentation: presentation, error: $error)
                .id(presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.bottom, NativeAgentShellLayout.roomGutter)
    }
}

private struct SealedSenseWebView: NSViewRepresentable {
    let presentation: SenseInteractiveView
    @Binding var error: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(presentation: presentation, report: { error = $0 })
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
        // Content blockers do not cover WebRTC sockets. Remove that API
        // before authored code; CSP prevents fresh realms via frames/workers.
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
        coordinator.prepare(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "senseEvent")
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let presentation: SenseInteractiveView
        private let report: (String?) -> Void
        private let address = URL(string: "sense-view://sealed/view")!
        private var prepareTask: Task<Void, Never>?
        private var eventTask: Task<Void, Never>?
        private var cancelled = false

        private static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; frame-src 'none'; worker-src 'none'; media-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; sandbox allow-scripts"
        private static let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^sense-view://sealed/view$"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]
        """

        init(presentation: SenseInteractiveView, report: @escaping (String?) -> Void) {
            self.presentation = presentation
            self.report = report
        }

        func prepare(_ view: WKWebView) {
            guard presentation.html.utf8.count <= 1_000_000 else {
                report("This sense view is too large to open.")
                return
            }
            prepareTask = Task { [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: "NativeAgentSealedSenseView", encodedContentRuleList: Self.rules)
                    guard !Task.isCancelled, !cancelled else { return }
                    guard let rules else {
                        report("The offline guard did not compile, so this sense view was not opened.")
                        return
                    }
                    view.configuration.userContentController.add(rules)
                    view.load(URLRequest(url: address))
                } catch {
                    if !cancelled { report("This sense view could not open: \(error.localizedDescription)") }
                }
            }
        }

        func cancel() {
            cancelled = true
            prepareTask?.cancel()
            eventTask?.cancel()
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard !cancelled, task.request.url == address else {
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            // The response policy cannot be removed or relaxed by supplied HTML.
            let response = HTTPURLResponse(url: address, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": Self.policy,
                "X-DNS-Prefetch-Control": "off",
                "Permissions-Policy": "camera=(), microphone=(), geolocation=(), display-capture=()",
            ])!
            task.didReceive(response)
            task.didReceive(Data(("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\""
                + Self.policy + "\"><meta name=\"referrer\" content=\"no-referrer\">" + presentation.html).utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && action.request.url == address ? .allow : .cancel
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
            if !cancelled { report("This sense view could not open: \(error.localizedDescription)") }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !cancelled, message.name == "senseEvent", message.frameInfo.isMainFrame,
                  message.frameInfo.request.url == address else { return }
            guard eventTask == nil else {
                report("This sense is still handling the previous event.")
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: message.body, options: [.fragmentsAllowed])
                guard data.count <= 16_384 else {
                    report("This sense event is too large.")
                    return
                }
                let event = try JSONDecoder().decode(JSONValue.self, from: data)
                eventTask = Task { [weak self] in
                    guard let self else { return }
                    defer { eventTask = nil }
                    let hub = SensesHub.shared
                    guard let registry = hub.registry, let source = hub.source,
                          let receiver = hub.runner as? any SenseViewEventReceiver else {
                        report("This sense cannot receive view events yet.")
                        return
                    }
                    do {
                        guard let record = try await registry.all().first(where: {
                            $0.id == presentation.senseID && $0.version == presentation.version && $0.status == .on
                        }), !Task.isCancelled else {
                            if !cancelled { report("This sense is off or its view has changed.") }
                            return
                        }
                        try await receiver.receiveViewEvent(event, for: record, source: source)
                        if !cancelled { report(nil) }
                    } catch {
                        if !cancelled { report("This sense could not handle the event: \(error.localizedDescription)") }
                    }
                }
            } catch {
                report("This sense sent an invalid event: \(error.localizedDescription)")
            }
        }
    }
}
