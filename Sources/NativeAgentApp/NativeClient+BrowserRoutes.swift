import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

extension NativeClient {
    func runBrowser(url: String, dryRun: Bool) async throws -> BrowserRun {
        try await runBrowser(
            url: url,
            dryRun: dryRun,
            captureSource: false,
            captureScreenshot: false
        )
    }

    func runBrowser(
        url: String,
        dryRun: Bool,
        captureSource: Bool,
        captureScreenshot: Bool
    ) async throws -> BrowserRun {
        // Browser Core owns every canonical operation transition and derived
        // receipt. The app owns only the visible WKWebView effect adapter.
        let bodyValue: JSONValue = .object([
            "url": .string(url),
            "dryRun": .bool(dryRun),
            "readOnly": .bool(true),
            "captureSource": .bool(false),
            "captureScreenshot": .bool(false),
        ])
        let writer = makeBrowserWriter()
        // `try`: nil means declined before any side effect; a THROW means a
        // native write already began, so the error propagates.
        if let envelope = try await writer.runBrowserAction(body: bodyValue) {
            let decoded = try Self.decodeJSONValue(
                envelope,
                as: BrowserRun.self,
                context: "runBrowser(swiftNative)"
            )
            if !dryRun {
                await Self.observeBrowserMotorAction(runID: decoded.id)
            }
            return decoded
        }
        guard !dryRun else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "Browser dry-run body was not handled by the Swift browser writer."
            ])
        }
        let runID = UUID().uuidString.lowercased()
        let run = try await Self.executeVisibleBrowserRun(
            parsed: try Self.validBrowserURL(url),
            runID: runID,
            approvalId: nil,
            captureSource: captureSource,
            captureScreenshot: captureScreenshot
        )
        return try Self.decodeJSONValue(run, as: BrowserRun.self, context: "runBrowser(swiftVisibleDirect)")
    }

    static func executeVisibleBrowserRun(
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

        let captureTask = Task { @MainActor in
            try await navigateVisibleBrowser(
                parsed.url,
                runID: runID,
                captureSource: captureSource,
                captureScreenshot: captureScreenshot
            )
        }
        let activeToken = await BrowserActiveRunRegistry.shared.register(runID: runID) {
            captureTask.cancel()
            _ = BrowserWindowController.shared.cancelNavigation(runID: runID)
        }
        defer {
            Task { @MainActor in
                BrowserActiveRunRegistry.shared.unregister(runID: runID, token: activeToken)
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

    static func observeBrowserMotorAction(
        runID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard dataRoot.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL,
              let model = try? await SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
                .motorActionReadModel(actionId: runID) else { return }
        await NativeCognitionRuntime.shared.observeMotorActionState(model)
    }

    static func createBrowserApproval(
        url: URL,
        domain: String,
        runID: String,
        captureSource: Bool,
        captureScreenshot: Bool
    ) async throws -> ApprovalRecord {
        let inbox = SwiftNativeApprovalInbox(root: SwiftNativeApprovalInbox.defaultDataRoot())
        let risk = await browserDomainHasReducedApprovalRisk(domain) ? "medium" : "high"
        return try await inbox.create(.object([
            "title": .string("Browser approval: \(domain)"),
            "action": .string("browser.open_url"),
            "risk": .string(risk),
            "reason": .string("Visible browser navigation was staged before direct browser autonomy was enabled."),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
            "payload": .object([
                "surface": .string("browser"),
                "url": .string(url.absoluteString),
                "domain": .string(domain),
                "runId": .string(runID),
                "visible": .bool(true),
                "dryRun": .bool(false),
                "captureSource": .bool(captureSource),
                "captureScreenshot": .bool(captureScreenshot),
            ]),
        ]))
    }

    struct ValidBrowserURL {
        var url: URL
        var domain: String
    }

    static func validBrowserURL(_ raw: String) throws -> ValidBrowserURL {
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

    static func browserDomainHasReducedApprovalRisk(_ domain: String) async -> Bool {
        if domain.hasSuffix(".localhost") { return true }
        let persistence = SwiftNativePersistenceCore()
        let policyPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let defaultDomains = ["example.com", "openai.com", "github.com", "linear.app", "localhost", "127.0.0.1"]
        let raw = await persistence.readJSON(policyPath, defaultValue: .object([:]))
        var configured: [String]? = nil
        if case .object(let policy) = raw,
           case .object(let browserPolicy)? = policy["browserPolicy"],
           case .array(let domains)? = browserPolicy["approvedDomains"] {
            configured = domains.compactMap { value -> String? in
                switch value {
                case .string(let s): return s
                case .int(let i): return String(i)
                case .double(let d): return String(d)
                case .bool(let b): return b ? "True" : "False"
                case .null: return "None"
                case .array, .object: return nil
                }
            }
        }
        let approved = Set((configured ?? defaultDomains).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        return approved.contains(domain)
    }

    // W-H Band 1 lift (move-only): visibility raised private→internal so the
    // relocated approval-executor cluster in NativeClient+ApprovalExecutors.swift
    // can still call it across the file boundary. No behavior change.
    static func executeApprovedBrowserRun(from approval: ApprovalRecord) async throws {
        guard case .object(let payload) = approval.payload,
              case .string(let rawURL)? = payload["url"],
              case .string(let runID)? = payload["runId"] ?? payload["run_id"] else {
            // Malformed payload: annotate FAILED so the approved record never
            // reads as silently executed.
            try? await annotateApprovalExecution(
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
            try await annotateApprovalExecution(id: approval.id, executedAction: run, detail: "Browser navigation \(status)")
        } catch {
            // Mirror the self_improvement pattern: never leave an approved
            // record without an execution annotation when the executor threw.
            NSLog("[approvals] browser run failed for \(approval.id): \(error)")
            try? await annotateApprovalExecution(
                id: approval.id,
                executedAction: .object([
                    "action": .string(approval.action),
                    "error": .string("\(error)"),
                ]),
                detail: "Browser navigation FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    // W-H Band 1 lift (move-only): visibility raised private→internal for the
    // relocated approval-executor cluster. No behavior change.
    static func finishRejectedBrowserRun(from approval: ApprovalRecord, status: String) async throws {
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
        let committedStatus = Self.jsonString(committed, "status") ?? status
        try await annotateApprovalExecution(
            id: approval.id,
            executedAction: committed,
            detail: "Browser navigation \(committedStatus)"
        )
        await observeBrowserMotorAction(runID: runID)
    }

    struct VisibleBrowserCapture: Sendable {
        var url: URL
        var nav: NavResult
        var text: String?
        var textChars: Int?
        var links: [BrowserLink]?
        var screenshot: Data?
    }

    @MainActor
    static func navigateVisibleBrowser(
        _ url: URL,
        runID: String,
        captureSource: Bool,
        captureScreenshot: Bool
    ) async throws -> VisibleBrowserCapture {
        let controller = BrowserWindowController.shared
        // Navigation must not imply fronting (User's 3:30am dream-time popups):
        // load quietly; only the explicit show surfaces front the window.
        controller.ensureWindowLoadedQuietly()
        let nav = try await controller.navigate(url, runID: runID)
        try Task.checkCancellation()
        let text = captureSource ? (try await controller.readText()) : nil
        try Task.checkCancellation()
        let links = captureSource ? (try? await controller.readLinks()) : nil
        try Task.checkCancellation()
        let textChars: Int?
        if let text {
            textChars = text.count
        } else {
            textChars = try? await controller.readText().count
        }
        let screenshot = captureScreenshot ? (try await controller.screenshot()) : nil
        try Task.checkCancellation()
        return VisibleBrowserCapture(
            url: url,
            nav: nav,
            text: text,
            textChars: textChars,
            links: links,
            screenshot: screenshot
        )
    }

    @MainActor
    static func captureCurrentVisibleBrowser(
        readText: Bool,
        readLinks: Bool,
        screenshot: Bool
    ) async throws -> VisibleBrowserCapture {
        let controller = BrowserWindowController.shared
        guard let current = controller.currentURL(),
              let url = URL(string: current),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "NativeAgentBrowser", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Visible browser is not on an http/https page"
            ])
        }
        let nav = NavResult(url: current, title: "", httpStatus: nil)
        let text = readText ? (try await controller.readText()) : nil
        let links = readLinks ? (try await controller.readLinks()) : nil
        let png = screenshot ? (try await controller.screenshot()) : nil
        return VisibleBrowserCapture(
            url: url,
            nav: nav,
            text: text,
            textChars: text?.count,
            links: links,
            screenshot: png
        )
    }

    static func persistBrowserTextCapture(
        id: String,
        url: URL,
        text: String,
        links: [BrowserLink]?
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient()
        let fm = FileManager.default
        try fm.createDirectory(at: browser.sourcesDir, withIntermediateDirectories: true)
        let textPath = browser.sourcesDir.appendingPathComponent("\(id).txt")
        try text.write(to: textPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: textPath.path)
        var receipt: [String: JSONValue] = [
            "url": .string(url.absoluteString),
            "textPath": .string(textPath.path),
            "textChars": .int(Int64(text.count)),
            "textPreview": .string(NativeAppSecretRedactor.redactText(String(text.prefix(3_000)))),
        ]
        if let links {
            let linksReceipt = try await persistBrowserLinksCapture(id: id, url: url, links: links)
            for (key, value) in linksReceipt where key != "url" {
                receipt[key] = value
            }
        }
        return receipt
    }

    static func persistBrowserLinksCapture(
        id: String,
        url: URL,
        links: [BrowserLink]
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient()
        let fm = FileManager.default
        try fm.createDirectory(at: browser.sourcesDir, withIntermediateDirectories: true)
        let path = browser.sourcesDir.appendingPathComponent("\(id)-links.json")
        let data = try JSONEncoder().encode(links)
        try data.write(to: path, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return [
            "url": .string(url.absoluteString),
            "linksPath": .string(path.path),
            "linkCount": .int(Int64(links.count)),
            "linksPreview": try Self.codableJSON(Array(links.prefix(25))),
        ]
    }

    static func persistBrowserScreenshotCapture(
        id: String,
        url: URL,
        png: Data
    ) async throws -> [String: JSONValue] {
        let browser = SwiftNativeBrowserClient.defaultClient()
        let fm = FileManager.default
        try fm.createDirectory(at: browser.screenshotsDir, withIntermediateDirectories: true)
        let path = browser.screenshotsDir.appendingPathComponent("\(id).png")
        try png.write(to: path, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return [
            "url": .string(url.absoluteString),
            "pngPath": .string(path.path),
            "bytes": .int(Int64(png.count)),
        ]
    }

    /// `root` is injectable so the memory.repair executor (and its launch
    /// reconciliation) can run against a test data root; every other caller
    /// uses the production default.
    // W-H Band 1 lift (move-only): visibility raised private→internal for the
    // relocated approval-executor cluster. No behavior change.
    static func annotateApprovalExecution(
        id: String,
        executedAction: JSONValue,
        detail: String,
        root: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws {
        let path = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            guard case .array(var rows) = raw else { return }
            for idx in rows.indices {
                guard case .object(var obj) = rows[idx],
                      case .string(let rowID)? = obj["id"],
                      rowID == id else {
                    continue
                }
                obj["executedAction"] = executedAction
                obj["detail"] = .string(detail)
                rows[idx] = .object(obj)
                break
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

    // W-H Band 1 lift (move-only): visibility raised private→internal for the
    // relocated approval-executor cluster. No behavior change.
    static func jsonString(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let obj) = value else { return nil }
        if case .string(let s)? = obj[key] { return s }
        return nil
    }

    static func browserNowISO(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter.string(from: date)
    }

    func cancelBrowserRun(id: String?) async throws -> BrowserRun {
        // Subsystem #27 wave 34 W17: cancel_browser_run is a pure flock'd
        // runs.json read-find-mutate-write + one receipt append — fully ported.
        // SwiftNativeBrowserClient handles it in-process; any IO failure fails
        // closed instead of replaying the cancel.
        var body: [String: Any] = ["dryRun": true]
        if let id, !id.isEmpty {
            body["id"] = id
        }
        var swiftBody: [String: JSONValue] = ["dryRun": .bool(true)]
        if let id, !id.isEmpty {
            swiftBody["id"] = .string(id)
        }
        let writer = makeBrowserWriter()
        // `try`: a THROW means the cancel already persisted to runs.json. nil
        // only occurs for a non-object body.
        if let envelope = try await writer.cancelBrowserRun(body: .object(swiftBody)) {
            let run = try Self.decodeJSONValue(envelope, as: BrowserRun.self, context: "cancelBrowserRun(swiftNative)")
            if run.status == "canceled" {
                _ = await BrowserActiveRunRegistry.shared.cancel(runID: run.id)
            }
            return run
        }
        throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
            NSLocalizedDescriptionKey: "Browser cancel body was not handled by the Swift browser writer."
        ])
    }

}
