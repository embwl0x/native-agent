import Foundation
import NativeAgentCore
import PersistenceCore
import Privacy
import ApprovalInbox

/// Browser operation orchestration. The canonical reducer remains the sole
/// owner of persisted transitions and derived native-action receipts.
public struct BrowserActionRoutes: Sendable {
    let effects: any BrowserRouteEffects

    public init(effects: any BrowserRouteEffects) {
        self.effects = effects
    }

    public func observeBrowserMotorAction(
        runID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard dataRoot.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL,
              let model = try? await SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
                .motorActionReadModel(actionId: runID) else { return }
        await effects.observeMotorAction(model)
    }

    public func runBrowser<T>(
        url: String,
        dryRun: Bool,
        captureSource: Bool,
        captureScreenshot: Bool,
        dataRoot: URL,
        decode: (JSONValue, String) throws -> BrowserRouteDecodedRun<T>
    ) async throws -> T {
        // Browser Core owns every canonical operation transition and derived
        // receipt. The app owns only the visible WKWebView effect adapter.
        let bodyValue: JSONValue = .object([
            "url": .string(url),
            "dryRun": .bool(dryRun),
            "readOnly": .bool(true),
            "captureSource": .bool(false),
            "captureScreenshot": .bool(false),
        ])
        let writer = makeBrowserWriter(
            dataRoot: dataRoot
        )
        // `try`: nil means declined before any side effect; a THROW means a
        // native write already began, so the error propagates.
        if let envelope = try await writer.runBrowserAction(body: bodyValue) {
            let decoded = try decode(envelope, "runBrowser(swiftNative)")
            if !dryRun {
                await observeBrowserMotorAction(runID: decoded.id)
            }
            return decoded.value
        }
        guard !dryRun else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "Browser dry-run body was not handled by the Swift browser writer."
            ])
        }
        let runID = UUID().uuidString.lowercased()
        let run = try await executeVisibleBrowserRun(
            parsed: try validBrowserURL(url),
            runID: runID,
            approvalId: nil,
            captureSource: captureSource,
            captureScreenshot: captureScreenshot
        )
        return try decode(run, "runBrowser(swiftVisibleDirect)").value
    }

    public func cancelBrowserRun<T>(
        id: String?,
        dataRoot: URL,
        decode: (JSONValue, String) throws -> BrowserRouteDecodedRun<T>
    ) async throws -> T {
        // Subsystem #27 wave 34 W17: cancel_browser_run is a pure flock'd
        // runs.json read-find-mutate-write + one receipt append — fully ported.
        // SwiftNativeBrowserClient handles it in-process; any IO failure fails
        // closed instead of replaying the cancel.
        var swiftBody: [String: JSONValue] = ["dryRun": .bool(true)]
        if let id, !id.isEmpty {
            swiftBody["id"] = .string(id)
        }
        let writer = makeBrowserWriter(
            dataRoot: dataRoot
        )
        // `try`: a THROW means the cancel already persisted to runs.json. nil
        // only occurs for a non-object body.
        if let envelope = try await writer.cancelBrowserRun(body: .object(swiftBody)) {
            let run = try decode(envelope, "cancelBrowserRun(swiftNative)")
            if run.status == "canceled" {
                await effects.cancelNavigation(runID: run.id)
            }
            return run.value
        }
        throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
            NSLocalizedDescriptionKey: "Browser cancel body was not handled by the Swift browser writer."
        ])
    }

    public func executeVisibleBrowserRun(
        parsed: ValidBrowserURL,
        runID: String,
        approvalId: String?,
        captureSource: Bool,
        captureScreenshot: Bool
    ) async throws -> JSONValue {
        var status = "succeeded"
        var opened = false
        var screenshotReceipt: JSONValue = .null
        var sourceReceipt: [String: JSONValue] = [
            "url": .string(parsed.url.absoluteString),
            "captureSource": .bool(captureSource),
        ]
        let browser = SwiftNativeBrowserClient.defaultClient()
        let start = BrowserOperationStart(
            id: runID,
            url: parsed.url.absoluteString,
            domain: parsed.domain,
            initialState: .running,
            visible: true,
            approvalId: approvalId,
            captureSource: captureSource,
            captureScreenshot: captureScreenshot,
            // BrowserWindowController owns and enforces the same 30-second
            // navigation timeout. Core persists it for restart recovery.
            deadlineSeconds: 30
        )
        let requestDigest = SwiftNativeBrowserClient.browserRequestDigest(for: start)
        _ = try await browser.executeBrowserOperation(.start(start))

        let navigation = await effects.beginNavigation(
            parsed.url, runID: runID, captureSource: captureSource, captureScreenshot: captureScreenshot
        )
        let captureTask = navigation.task
        defer {
            Task { @MainActor in
                effects.finishNavigation(runID: runID, token: navigation.token)
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await captureTask.value
            } onCancel: {
                captureTask.cancel()
            }
            try Task.checkCancellation()
            opened = true
            status = "succeeded"
            sourceReceipt["ipcUrl"] = .string(result.nav.url)
            sourceReceipt["ipcTitle"] = .string(result.nav.title)
            if let code = result.nav.httpStatus {
                sourceReceipt["httpStatus"] = .int(Int64(code))
            }
            if let chars = result.textChars {
                sourceReceipt["textChars"] = .int(Int64(chars))
            }
            if captureSource, let text = result.text {
                try Task.checkCancellation()
                let persisted = try await persistBrowserTextCapture(
                    id: runID,
                    url: parsed.url,
                    text: text,
                    links: result.links
                )
                for (key, value) in persisted {
                    sourceReceipt[key] = value
                }
            }
            if captureScreenshot, let png = result.screenshot {
                try Task.checkCancellation()
                screenshotReceipt = .object(try await persistBrowserScreenshotCapture(
                    id: runID,
                    url: parsed.url,
                    png: png
                ))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            status = "canceled"
            sourceReceipt["canceled"] = .bool(true)
        } catch {
            status = "failed"
            sourceReceipt["openError"] = .string(error.localizedDescription)
        }

        let terminalState: BrowserOperationTerminalState
        switch status {
        case "succeeded": terminalState = .succeeded
        case "canceled": terminalState = .canceled
        default: terminalState = .failed
        }
        let completion = BrowserOperationCompletion(
            id: runID,
            requestDigest: requestDigest,
            state: terminalState,
            opened: opened,
            sourceReceipt: .object(sourceReceipt),
            screenshotReceipt: screenshotReceipt
        )
        guard let committed = try await browser.executeBrowserOperation(.complete(completion)).run else {
            throw NSError(domain: "NativeAgentBrowser", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Browser canonical completion returned no run"
            ])
        }
        // The Core reducer makes terminal state absorbing, so an explicit
        // cancel committed during WebKit/capture always defeats late success.
        await observeBrowserMotorAction(runID: runID)
        return committed
    }

    public struct ValidBrowserURL: Sendable {
        public var url: URL
        public var domain: String
    }

    public func validBrowserURL(_ raw: String) throws -> ValidBrowserURL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Browser URL is required"
            ])
        }
        guard let url = URL(string: trimmed),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Only http/https browser URLs are allowed"
            ])
        }
        guard let host = comps.host?.lowercased(), !host.isEmpty else {
            throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Browser URL must include a host"
            ])
        }
        return ValidBrowserURL(url: url, domain: host)
    }

    public func executeApprovedBrowserRun(from approval: ApprovalRecord) async throws {
        guard case .object(let payload) = approval.payload,
              case .string(let rawURL)? = payload["url"],
              case .string(let runID)? = payload["runId"] ?? payload["run_id"] else {
            // Malformed payload: annotate FAILED so the approved record never
            // reads as silently executed.
            try? await effects.annotateApprovalExecution(
                id: approval.id,
                executedAction: .object([
                    "action": .string(approval.action),
                    "error": .string("malformed payload: missing url/runId"),
                ]),
                detail: "Browser navigation FAILED: malformed payload (missing url/runId)")
            return
        }
        do {
            let captureSource = connectorInputBool(
                payload["captureSource"] ?? payload["capture_source"],
                default: false
            )
            let captureScreenshot = connectorInputBool(
                payload["captureScreenshot"] ?? payload["capture_screenshot"],
                default: false
            )
            let run = try await executeVisibleBrowserRun(
                parsed: try validBrowserURL(rawURL),
                runID: runID,
                approvalId: approval.id,
                captureSource: captureSource,
                captureScreenshot: captureScreenshot
            )
            let status = jsonString(run, "status") ?? "succeeded"
            try await effects.annotateApprovalExecution(id: approval.id, executedAction: run, detail: "Browser navigation \(status)")
        } catch {
            // Mirror the self_improvement pattern: never leave an approved
            // record without an execution annotation when the executor threw.
            NSLog("[approvals] browser run failed for \(approval.id): \(error)")
            try? await effects.annotateApprovalExecution(
                id: approval.id,
                executedAction: .object([
                    "action": .string(approval.action),
                    "error": .string("\(error)"),
                ]),
                detail: "Browser navigation FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    public func finishRejectedBrowserRun(from approval: ApprovalRecord, status: String) async throws {
        guard case .object(let payload) = approval.payload,
              case .string(let rawURL)? = payload["url"],
              case .string(let runID)? = payload["runId"] ?? payload["run_id"],
              let parsed = try? validBrowserURL(rawURL) else {
            return
        }
        let browser = SwiftNativeBrowserClient.defaultClient()
        let start = BrowserOperationStart(
            id: runID,
            url: parsed.url.absoluteString,
            domain: parsed.domain,
            initialState: .waitingApproval,
            visible: true,
            approvalId: approval.id
        )
        let digest = SwiftNativeBrowserClient.browserRequestDigest(for: start)
        _ = try await browser.executeBrowserOperation(.start(start))
        let terminal: BrowserOperationTerminalState = status == "denied" ? .denied : .canceled
        let result = try await browser.executeBrowserOperation(.complete(.init(
            id: runID,
            requestDigest: digest,
            state: terminal,
            opened: false,
            sourceReceipt: .object([
                "url": .string(parsed.url.absoluteString),
                "decision": .string(status),
            ])
        )))
        guard let committed = result.run else {
            throw NSError(domain: "NativeAgentBrowser", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Browser rejection returned no canonical run"
            ])
        }
        let committedStatus = jsonString(committed, "status") ?? status
        try await effects.annotateApprovalExecution(
            id: approval.id,
            executedAction: committed,
            detail: "Browser navigation \(committedStatus)"
        )
        await observeBrowserMotorAction(runID: runID)
    }

    @MainActor
    public func navigateVisibleBrowser(
        _ url: URL,
        runID: String,
        captureSource: Bool,
        captureScreenshot: Bool
    ) async throws -> BrowserVisibleCapture {
        let nav = try await effects.navigate(url, runID: runID)
        try Task.checkCancellation()
        let text = captureSource ? (try await effects.readText()) : nil
        try Task.checkCancellation()
        let links = captureSource ? (try? await effects.readLinks()) : nil
        try Task.checkCancellation()
        let textChars: Int?
        if let text {
            textChars = text.count
        } else {
            textChars = try? await effects.readText().count
        }
        let screenshot = captureScreenshot ? (try await effects.screenshot()) : nil
        try Task.checkCancellation()
        return BrowserVisibleCapture(
            url: url,
            nav: nav,
            text: text,
            textChars: textChars,
            links: links,
            screenshot: screenshot
        )
    }

    @MainActor
    public func captureCurrentVisibleBrowser(
        readText: Bool,
        readLinks: Bool,
        screenshot: Bool
    ) async throws -> BrowserVisibleCapture {
        guard let current = effects.currentURL(),
              let url = URL(string: current),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Visible browser is not on an http/https page"
            ])
        }
        let nav = BrowserNavigationResult(url: current, title: "", httpStatus: nil)
        let text = readText ? (try await effects.readText()) : nil
        let links = readLinks ? (try await effects.readLinks()) : nil
        let png = screenshot ? (try await effects.screenshot()) : nil
        return BrowserVisibleCapture(
            url: url,
            nav: nav,
            text: text,
            textChars: text?.count,
            links: links,
            screenshot: png
        )
    }


    public func persistBrowserTextCapture(
        id: String,
        url: URL,
        text: String,
        links: [BrowserLink]?
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient()
        var artifacts: [BrowserCaptureCache.Kind: Data] = [.text: Data(text.utf8)]
        if let links { artifacts[.links] = try JSONEncoder().encode(links) }
        let paths = try await BrowserCaptureCache.shared.store(
            id: id, artifacts: artifacts, browserRoot: browser.sourcesDir.deletingLastPathComponent())
        guard let textPath = paths[.text] else { throw CocoaError(.fileWriteUnknown) }
        var receipt: [String: JSONValue] = [
            "url": .string(url.absoluteString),
            "textPath": .string(textPath.path),
            "textChars": .int(Int64(text.count)),
            "textPreview": .string(NativeAppSecretRedactor.redactText(String(text.prefix(3_000)))),
            "captureRetention": BrowserCaptureCache.shared.policy.receipt,
        ]
        if let links, let linksPath = paths[.links] {
            receipt["linksPath"] = .string(linksPath.path)
            receipt["linkCount"] = .int(Int64(links.count))
            receipt["linksPreview"] = try JSONValue.fromEncodable(Array(links.prefix(25)))
        }
        return receipt
    }

    public func persistBrowserLinksCapture(
        id: String,
        url: URL,
        links: [BrowserLink]
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient()
        let data = try JSONEncoder().encode(links)
        let paths = try await BrowserCaptureCache.shared.store(
            id: id, artifacts: [.links: data], browserRoot: browser.sourcesDir.deletingLastPathComponent())
        guard let path = paths[.links] else { throw CocoaError(.fileWriteUnknown) }
        return [
            "url": .string(url.absoluteString),
            "linksPath": .string(path.path),
            "linkCount": .int(Int64(links.count)),
            "linksPreview": try JSONValue.fromEncodable(Array(links.prefix(25))),
            "captureRetention": BrowserCaptureCache.shared.policy.receipt,
        ]
    }

    public func persistBrowserScreenshotCapture(
        id: String,
        url: URL,
        png: Data
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient()
        let paths = try await BrowserCaptureCache.shared.store(
            id: id, artifacts: [.screenshot: png], browserRoot: browser.screenshotsDir.deletingLastPathComponent())
        guard let path = paths[.screenshot] else { throw CocoaError(.fileWriteUnknown) }
        // A screenshot exists to be LOOKED at. 2026-09-13: it came back as a
        // path, so seeing it cost a second turn with read_file — the same
        // complaint Agent raised about image_generate. The thumbnail rides
        // back on this result; the full-size PNG stays at pngPath. Outside a
        // model turn (the wander lane) there is no sink and `shown` is false.
        let shown = effects.showProducedImage(at: path, name: "\(id).png")
        return [
            "url": .string(url.absoluteString),
            "pngPath": .string(path.path),
            "bytes": .int(Int64(png.count)),
            "shownToModel": .bool(shown.shown),
            "visionNote": .string(shown.note),
            "captureRetention": BrowserCaptureCache.shared.policy.receipt,
        ]
    }

    private func jsonString(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = value, case .string(let string)? = object[key] else { return nil }
        return string
    }

    private func connectorInputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        ConnectorInputValue.bool(raw, default: defaultValue)
    }
}
