import Foundation
import NativeAgentCore
import PersistenceCore
import Privacy
import ApprovalInbox
import NativeAgentShared
// Blueprint: | `BrowserActionRoutes.swift` | `BrowserActionRoutes` struct; `observeBrowserMotorAction`, `runBrowser`, direct dry-run/cancel commands to the canonical operation store, task-local `retainRead` delivery of the exact visible read capture |

/// Browser operation orchestration. The canonical reducer remains the sole
/// owner of persisted transitions and derived native-action receipts.
public struct BrowserActionRoutes: Sendable {
    /// The read door retains this exact capture before disposable artifacts
    /// can expire. It never needs another visible read to recover the evidence.
    @TaskLocal public static var retainRead: (@Sendable (BrowserVisibleCapture) -> Void)?
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

    public func runBrowser(
        url: String,
        dryRun: Bool,
        captureSource: Bool,
        captureScreenshot: Bool,
        dataRoot: URL
    ) async throws -> BrowserRun {
        // Browser Core owns every canonical operation transition and derived
        // receipt. The app owns only the visible WKWebView effect adapter.
        if dryRun {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = try? ValidBrowserURL(trimmed) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                    NSLocalizedDescriptionKey: "Browser dry-run body was not handled by the Swift browser writer."
                ])
            }
            let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
            let result = try await browser.executeBrowserOperation(.start(.init(
                id: UUID().uuidString, url: trimmed, domain: parsed.domain,
                initialState: .dryRun
            )))
            guard let run = result.run else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                    NSLocalizedDescriptionKey: "Browser dry-run body was not handled by the Swift browser writer."
                ])
            }
            return try BrowserRun(row: run)
        }
        let runID = UUID().uuidString.lowercased()
        let run = try await executeVisibleBrowserRun(
            parsed: try ValidBrowserURL(url),
            runID: runID,
            approvalId: nil,
            captureSource: captureSource,
            captureScreenshot: captureScreenshot,
            dataRoot: dataRoot
        )
        return try BrowserRun(row: run)
    }

    public func cancelBrowserRun(id: String?, dataRoot: URL) async throws -> BrowserRun {
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
        do {
            let result = try await browser.executeBrowserOperation(.cancel(id: id))
            guard let envelope = result.run else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                    NSLocalizedDescriptionKey: "Browser cancel body was not handled by the Swift browser writer."
                ])
            }
            if envelope.objectValue?["status"]?.stringValue == "canceled",
               let runID = envelope.objectValue?["id"]?.stringValue {
                await effects.cancelNavigation(runID: runID)
            }
            return try BrowserRun(row: envelope)
        } catch let error as BrowserCancellationProjectionError {
            if let runID = error.run.objectValue?["id"]?.stringValue {
                await effects.cancelNavigation(runID: runID)
            }
            throw error
        }
    }

    public func executeVisibleBrowserRun(
        parsed: ValidBrowserURL,
        runID: String,
        approvalId: String?,
        captureSource: Bool,
        captureScreenshot: Bool,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        var status = "succeeded"
        var sourceReceipt: [String: JSONValue] = [
            "url": .string(parsed.url.absoluteString),
            "captureSource": .bool(captureSource),
        ]
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
        let start = BrowserOperationStart(
            id: runID,
            url: parsed.url.absoluteString,
            domain: parsed.domain,
            initialState: .running,
            approvalId: approvalId,
            captureSource: captureSource,
            captureScreenshot: captureScreenshot,
            // BrowserWindowController owns and enforces the same 30-second
            // navigation timeout. Core persists it for restart recovery.
            deadlineSeconds: 30
        )
        let requestDigest = SwiftNativeBrowserClient.browserRequestDigest(for: start)
        let claim = try await browser.executeBrowserOperation(.start(start))
        // Only the canonical start claimant may attach cancellation, execute
        // effects or settle this run. A duplicate reports the original row.
        guard claim.didTransition else {
            guard let existing = claim.run else { throw BrowserOperationStoreError.runNotFound }
            return existing
        }

        let navigation = await effects.beginNavigation(
            parsed.url, runID: runID, captureSource: captureSource, captureScreenshot: captureScreenshot,
            dataRoot: dataRoot
        )
        let captureTask = navigation.task
        var capture: BrowserVisibleCapture?
        do {
            // Adopt the returned capture before observing cancellation. Produced
            // material belongs to settlement even when Stop won the outcome.
            capture = try await withTaskCancellationHandler {
                try await captureTask.value
            } onCancel: { captureTask.cancel() }
            try Task.checkCancellation()
            if capture?.readFailures["canceled"] != nil { status = "canceled" }
            else if capture?.readFailures["capture"] != nil { status = "failed" }
        } catch is CancellationError { status = "canceled" }
        catch {
            status = "failed"
            sourceReceipt["openError"] = .string(error.localizedDescription)
            if (error as? BrowserError)?.hasUnknownOutcome == true {
                sourceReceipt["outcomeKind"] = .string("outcome_unknown")
            }
        }
        let outcome = await settle { [capture, status, sourceReceipt] () -> Result<JSONValue, Error> in
            var status = status
            var sourceReceipt = sourceReceipt
            var screenshotReceipt: JSONValue = .null
            let opened = capture != nil
            if let result = capture {
                sourceReceipt["ipcUrl"] = .string(result.nav.url)
                sourceReceipt["ipcTitle"] = .string(result.nav.title)
                if let code = result.nav.httpStatus { sourceReceipt["httpStatus"] = .int(Int64(code)) }
                if let chars = result.textChars { sourceReceipt["textChars"] = .int(Int64(chars)) }
                if !result.readFailures.isEmpty {
                    sourceReceipt["readFailures"] = .object(result.readFailures.mapValues(JSONValue.string))
                }
                if captureSource, let text = result.text {
                    do {
                        let saved = try await persistBrowserTextCapture(id: runID, url: parsed.url,
                            text: text, links: result.links, dataRoot: dataRoot)
                        sourceReceipt.merge(saved) { _, new in new }
                    } catch {
                        sourceReceipt["textPersistenceError"] = .string(error.localizedDescription)
                        if status != "canceled" { status = "failed" }
                    }
                }
                if captureScreenshot, let png = result.screenshot {
                    do {
                        screenshotReceipt = .object(try await persistBrowserScreenshotCapture(
                            id: runID, url: parsed.url, png: png, dataRoot: dataRoot, showToModel: false))
                    } catch {
                        sourceReceipt["screenshotPersistenceError"] = .string(error.localizedDescription)
                        if status != "canceled" { status = "failed" }
                    }
                }
            }
            if status == "canceled" {
                sourceReceipt["canceled"] = .bool(true)
                if capture == nil { sourceReceipt["outcomeKind"] = .string("outcome_unknown") }
            }
            let terminal: BrowserOperationTerminalState = status == "canceled" ? .canceled
                : status == "succeeded" ? .succeeded : .failed
            do {
                let completion = BrowserOperationCompletion(id: runID, requestDigest: requestDigest,
                    state: terminal, opened: opened, sourceReceipt: .object(sourceReceipt),
                    screenshotReceipt: screenshotReceipt)
                guard let committed = try await browser.executeBrowserOperation(.complete(completion)).run else {
                    throw BrowserOperationStoreError.runNotFound
                }
                await effects.finishNavigation(runID: runID, token: navigation.token)
                await observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
                return .success(committed)
            } catch {
                await effects.finishNavigation(runID: runID, token: navigation.token)
                return .failure(error)
            }
        }
        let committed = try outcome.get()
        // Inline pixels belong to this caller's admitted turn context, which
        // settle deliberately does not inherit. The canonical receipt already
        // owns the artifact; delivery metadata is this response's projection.
        if case .object(var fields) = committed,
           case .object(var screenshot)? = fields["screenshotReceipt"],
           case .string(let path)? = screenshot["pngPath"] {
            let shown = effects.showProducedImage(at: URL(fileURLWithPath: path), name: "\(runID).png")
            screenshot["shownToModel"] = .bool(shown.shown)
            screenshot["visionNote"] = .string(shown.note)
            fields["screenshotReceipt"] = .object(screenshot)
            return .object(fields)
        }
        return committed
    }

    /// A page effect that is not a navigation (a click, a fill) under the one
    /// operation owner. The window is owned before the first suspension and
    /// the run is cancellable before its start is persisted; after the start,
    /// the canonical state is read again and the page must still be the one
    /// it started on, so a cancel committed meanwhile, or a replacement page,
    /// gets no input. The completion says what it did.
    @MainActor
    public func executePageEffect(
        _ name: String, detail: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot(),
        _ effect: @escaping @MainActor () async throws -> Void
    ) async throws -> JSONValue {
        let page = effects.currentURL() ?? ""
        let parsed = try ValidBrowserURL(page)
        let runID = "page-\(UUID().uuidString.lowercased())"
        try effects.acquireBrowser(runID: runID)
        defer { effects.releaseBrowser(runID: runID) }
        let latch = BrowserRunCancellationLatch()
        let token = BrowserActiveRunRegistry.shared.register(runID: runID) { latch.cancel() }
        defer { BrowserActiveRunRegistry.shared.unregister(runID: runID, token: token) }
        let start = BrowserOperationStart(id: runID, url: parsed.url.absoluteString, domain: parsed.domain, initialState: .running)
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
        _ = try await browser.executeBrowserOperation(.start(start))
        let phase = try await browser.motorActionReadModel(actionId: runID)?.phase
        var receipt = detail
        receipt["action"] = .string(name)
        var state = BrowserOperationTerminalState.succeeded
        let task = Task { @MainActor in
            guard phase == .running else { throw CancellationError() }
            guard effects.currentURL() == page else {
                throw NSError(domain: "NativeAgentBrowser", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "The page changed before the \(name) could land; nothing was sent to it."
                ])
            }
            try Task.checkCancellation()
            try await effect()
        }
        latch.install { task.cancel() }
        // The caller's cancel reaches the effect the way navigation's does.
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if Task.isCancelled || task.isCancelled { state = .canceled }
        } catch is CancellationError { state = .canceled } catch {
            state = .failed
            receipt["error"] = .string(error.localizedDescription)
            if (error as? BrowserError)?.hasUnknownOutcome == true {
                receipt["outcomeKind"] = .string("outcome_unknown")
            }
        }
        // Settlement outlives the caller's cancellation, as for a navigation.
        let completion = BrowserOperationCompletion(
            id: runID, requestDigest: SwiftNativeBrowserClient.browserRequestDigest(for: start),
            state: state, opened: false, sourceReceipt: .object(receipt))
        let settled = await settle { () -> Result<JSONValue, Error> in
            do {
                guard let committed = try await browser.executeBrowserOperation(.complete(completion)).run else {
                    throw BrowserOperationStoreError.runNotFound
                }
                await observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
                return .success(committed)
            } catch { return .failure(error) }
        }
        return try settled.get()
    }

    public struct ValidBrowserURL: Sendable {
        public var url: URL
        public var domain: String
        public init(_ raw: String) throws {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Browser URL is required"
                ])
            }
            let parsedURL = URL(string: trimmed)
            let scheme = parsedURL?.scheme?.lowercased() ?? ""
            guard let url = parsedURL,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  scheme == "http" || scheme == "https" else {
                throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Only http/https browser URLs are allowed",
                    "scheme": scheme, "url_parse_failed": parsedURL == nil
                ])
            }
            guard let host = comps.host?.lowercased(), !host.isEmpty else {
                throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Browser URL must include a host"
                ])
            }
            self.url = url; domain = host
        }
    }

    public func executeApprovedBrowserRun(from approval: ApprovalRecord, dataRoot: URL) async throws {
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
                detail: "Browser navigation FAILED: malformed payload (missing url/runId)", dataRoot: dataRoot)
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
                parsed: try ValidBrowserURL(rawURL),
                runID: runID,
                approvalId: approval.id,
                captureSource: captureSource,
                captureScreenshot: captureScreenshot,
                dataRoot: dataRoot
            )
            let status = run.objectValue?["status"]?.stringValue ?? "succeeded"
            try await effects.annotateApprovalExecution(id: approval.id, executedAction: run,
                                                        detail: "Browser navigation \(status)", dataRoot: dataRoot)
        } catch {
            // Mirror the self_improvement pattern: never leave an approved
            // record without an execution annotation when the executor threw.
            nativeLog("[approvals] browser run failed for \(approval.id): \(error)")
            try? await effects.annotateApprovalExecution(
                id: approval.id,
                executedAction: .object([
                    "action": .string(approval.action),
                    "error": .string("\(error)"),
                ]),
                detail: "Browser navigation FAILED: \(error.localizedDescription)", dataRoot: dataRoot)
            throw error
        }
    }

    public func finishRejectedBrowserRun(from approval: ApprovalRecord, status: String, dataRoot: URL) async throws {
        guard case .object(let payload) = approval.payload,
              case .string(let rawURL)? = payload["url"],
              case .string(let runID)? = payload["runId"] ?? payload["run_id"],
              let parsed = try? ValidBrowserURL(rawURL) else {
            return
        }
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
        let start = BrowserOperationStart(
            id: runID,
            url: parsed.url.absoluteString,
            domain: parsed.domain,
            initialState: .waitingApproval,
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
        let committedStatus = committed.objectValue?["status"]?.stringValue ?? status
        try await effects.annotateApprovalExecution(
            id: approval.id,
            executedAction: committed,
            detail: "Browser navigation \(committedStatus)",
            dataRoot: dataRoot
        )
        await observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
    }

    @MainActor
    public func navigateVisibleBrowser(
        _ url: URL,
        runID: String,
        captureSource: Bool,
        captureScreenshot: Bool,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> BrowserVisibleCapture {
        // The app installs the cancellation hook before this task starts.
        // Catch a canonical cancel that landed before that registration.
        try Task.checkCancellation()
        let model = try await SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
            .motorActionReadModel(actionId: runID)
        if model?.phase == .cancelled { throw CancellationError() }
        guard model?.phase == .running else { throw BrowserOperationStoreError.invalidTransition }
        try Task.checkCancellation()
        try effects.acquireBrowser(runID: runID)
        defer { effects.releaseBrowser(runID: runID) }
        let nav = try await effects.navigate(url, runID: runID)
        var text: String?
        var textChars: Int?
        var links: [BrowserLink]?
        var screenshot: Data?
        var readFailures: [String: String] = [:]
        do {
            try Task.checkCancellation()
            if captureSource { text = try await effects.readText(); textChars = text?.count }
            try Task.checkCancellation()
            if captureSource {
                do { links = try await effects.readLinks() }
                catch { readFailures["links"] = error.localizedDescription }
            }
            try Task.checkCancellation()
            if text == nil {
                do { textChars = try await effects.readText().count }
                catch { readFailures["textChars"] = error.localizedDescription }
            }
            try Task.checkCancellation()
            if captureScreenshot { screenshot = try await effects.screenshot() }
        } catch is CancellationError { readFailures["canceled"] = "Capture stopped after navigation." }
        catch { readFailures["capture"] = error.localizedDescription }
        if Task.isCancelled { readFailures["canceled"] = "Capture stopped after navigation." }
        return BrowserVisibleCapture(
            url: url,
            nav: nav,
            text: text,
            textChars: textChars,
            links: links,
            screenshot: screenshot,
            readFailures: readFailures
        )
    }

    private static func canReadVisiblePage(_ url: URL?) -> Bool {
        ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
    }

    @MainActor
    public func visibleBrowserStatus(_ status: JSONValue) throws -> JSONValue {
        guard case .object(var fields) = status else {
            throw NSError(domain: "NativeAgentBrowser", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Browser status is not an object"
            ])
        }
        let current = effects.currentURL()
        let url = current.flatMap { URL(string: $0) }
        let readable = Self.canReadVisiblePage(url)
        fields["current_url"] = current.map(JSONValue.string) ?? .null
        fields["url_scheme"] = url?.scheme.map { .string($0.lowercased()) } ?? .null
        fields["readable"] = .object(["browser.text": .bool(readable),
            "browser.links": .bool(readable), "browser.screenshot": .bool(readable)])
        fields["read_note"] = .string("Page reads require an HTTP(S) page. Preview app {action:\"browser.open\",args:{url:\"<http/https URL>\"},preview:true} first, then open the page if authorized.")
        return .object(fields)
    }

    @MainActor
    public func captureCurrentVisibleBrowser(
        readText: Bool,
        readLinks: Bool,
        screenshot: Bool
    ) async throws -> BrowserVisibleCapture {
        let runID = UUID().uuidString
        try effects.acquireBrowser(runID: runID)
        defer { effects.releaseBrowser(runID: runID) }
        guard let current = effects.currentURL(),
              let url = URL(string: current),
              Self.canReadVisiblePage(url) else {
            throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Visible browser is not on an http/https page. Preview app {action:\"browser.open\",args:{url:\"<http/https URL>\"},preview:true} first, then open the page if authorized."
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
        links: [BrowserLink]?,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
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
            receipt["linksPreview"] = NativeAppSecretRedactor.redactValue(try JSONValue.fromEncodable(Array(links.prefix(25))))
        }
        return receipt
    }

    public func persistBrowserLinksCapture(
        id: String,
        url: URL,
        links: [BrowserLink],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
        let data = try JSONEncoder().encode(links)
        let paths = try await BrowserCaptureCache.shared.store(
            id: id, artifacts: [.links: data], browserRoot: browser.sourcesDir.deletingLastPathComponent())
        guard let path = paths[.links] else { throw CocoaError(.fileWriteUnknown) }
        return [
            "url": .string(url.absoluteString),
            "linksPath": .string(path.path),
            "linkCount": .int(Int64(links.count)),
            "linksPreview": NativeAppSecretRedactor.redactValue(try JSONValue.fromEncodable(Array(links.prefix(25)))),
            "captureRetention": BrowserCaptureCache.shared.policy.receipt,
        ]
    }

    public func persistBrowserScreenshotCapture(
        id: String,
        url: URL,
        png: Data,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        showToModel: Bool = true
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
        let paths = try await BrowserCaptureCache.shared.store(
            id: id, artifacts: [.screenshot: png], browserRoot: browser.screenshotsDir.deletingLastPathComponent())
        guard let path = paths[.screenshot] else { throw CocoaError(.fileWriteUnknown) }
        // The turn image sink shows the thumbnail (no sink means shown is false); the full-size PNG stays at pngPath.
        var receipt: [String: JSONValue] = [
            "url": .string(url.absoluteString),
            "pngPath": .string(path.path),
            "bytes": .int(Int64(png.count)),
            "captureRetention": BrowserCaptureCache.shared.policy.receipt,
        ]
        if showToModel {
            let shown = effects.showProducedImage(at: path, name: "\(id).png")
            receipt["shownToModel"] = .bool(shown.shown)
            receipt["visionNote"] = .string(shown.note)
        }
        return receipt
    }

    private func connectorInputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        ConnectorInputValue.bool(raw, default: defaultValue)
    }
}
