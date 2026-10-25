import Foundation
import PersistenceCore
// Blueprint: | `BrowserActionRoutes+IPC.swift` | authenticated IPC route decisions over window effects |

public protocol BrowserIPCWindowEffects: BrowserRouteEffects {
    @MainActor var navigationInProgress: Bool { get }
    @MainActor func click(selector: String) async throws
    @MainActor func fill(selector: String, text: String) async throws
    @MainActor func showWindow()
    @MainActor func hideWindow()
    @MainActor func statusPayload() -> [String: Any]
}

extension BrowserActionRoutes {
    @MainActor public static func authenticatedIPCRoute(
        method: String, path: String, headers: [String: String], body: Data,
        token: String, effects: any BrowserIPCWindowEffects
    ) async -> (status: Int, object: [String: Any]) {
        let auth = headers["authorization"] ?? ""
        guard auth == "Bearer \(token)" else {
            return (401, ["error": "unauthorized"])
        }
        do {
            return (200, try await handleIPCRoute(method: method, path: path, body: body, effects: effects))
        } catch {
            return (500, ["error": error.localizedDescription])
        }
    }

    /// Every IPC page effect enters the browser the way a run does: it owns
    /// the window for its duration (so it cannot touch a page another run is
    /// capturing) and acts only on an http(s) page (N8: a JS redirect to
    /// file:// after a validated navigate must not open local files).
    @MainActor private static func owningPage(
        _ effects: any BrowserIPCWindowEffects, _ body: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        if let current = effects.currentURL(), !["http", "https"].contains(URL(string: current)?.scheme?.lowercased() ?? "") {
            let cur = URL(string: current)?.scheme ?? "unknown"
            return ["ok": false, "error": "url_scheme_not_allowed",
                    "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
        }
        let owner = "ipc-\(UUID().uuidString.lowercased())"
        try effects.acquireBrowser(runID: owner)
        defer { effects.releaseBrowser(runID: owner) }
        return try await body()
    }

    /// A click or fill is a run like a navigation: the one operation owner
    /// persists its start and completion and can cancel or recover it.
    @MainActor private static func pageEffect(
        _ effects: any BrowserIPCWindowEffects, _ name: String, _ detail: [String: JSONValue],
        _ effect: @escaping @MainActor () async throws -> Void
    ) async throws -> [String: Any] {
        let run = try BrowserRun(row: try await BrowserActionRoutes(effects: effects).executePageEffect(name, detail: detail, effect))
        let receipt = (run.sourceReceipt.flatMap { try? $0.serializedData(pretty: false) })
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return ["ok": run.status == "succeeded", "runId": run.id, "status": run.status,
                "error": receipt["error"] ?? NSNull(), "outcomeKind": receipt["outcomeKind"] ?? NSNull()]
    }

    @MainActor public static func handleIPCRoute(method: String, path: String, body: Data, effects: any BrowserIPCWindowEffects) async throws -> [String: Any] {
        try Task.checkCancellation()
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
            let requestedRunID = (json["runId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let runID = requestedRunID?.isEmpty == false
                ? requestedRunID!
                : "ipc-\(UUID().uuidString.lowercased())"
            // The same operation owner as every other navigation: a persisted
            // run with its ownership, cancellation and recovery. Its atomic
            // start reports a duplicate before any window effects run; distinct
            // runs still acquire exclusive browser ownership at the effect.
            let routes = BrowserActionRoutes(effects: effects)
            let run = try BrowserRun(row: try await routes.executeVisibleBrowserRun(
                parsed: try routes.validBrowserURL(urlStr), runID: runID, approvalId: nil,
                captureSource: false, captureScreenshot: false))
            let receipt = (run.sourceReceipt.flatMap { try? $0.serializedData(pretty: false) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return ["ok": run.status == "succeeded", "runId": run.id, "status": run.status,
                    "outcomeKind": receipt["outcomeKind"] ?? NSNull(),
                    "url": receipt["ipcUrl"] ?? NSNull(), "title": receipt["ipcTitle"] ?? NSNull(),
                    "httpStatus": receipt["httpStatus"] ?? NSNull(), "error": receipt["openError"] ?? NSNull()]

        case "/browser/screenshot":
            return try await owningPage(effects) {
                ["ok": true, "png_base64": try await effects.screenshot().base64EncodedString()]
            }

        case "/browser/click":
            guard let sel = json["selector"] as? String else { throw BrowserError.badRequest("selector required") }
            return try await pageEffect(effects, "click", ["selector": .string(sel)]) { try await effects.click(selector: sel) }

        case "/browser/fill":
            guard let sel = json["selector"] as? String,
                  let text = json["text"] as? String else { throw BrowserError.badRequest("selector and text required") }
            return try await pageEffect(effects, "fill", ["selector": .string(sel)]) { try await effects.fill(selector: sel, text: text) }

        case "/browser/read_text":
            return try await owningPage(effects) { ["ok": true, "text": try await effects.readText()] }

        case "/browser/read_links":
            return try await owningPage(effects) {
                let links = try await effects.readLinks()
                return ["ok": true, "links": try JSONSerialization.jsonObject(with: JSONEncoder().encode(links))]
            }

        case "/browser/show":
            effects.showWindow()
            return effects.statusPayload()

        case "/browser/hide":
            effects.hideWindow()
            return effects.statusPayload()

        case "/browser/status":
            return effects.statusPayload()

        default:
            throw BrowserError.badRequest("unknown path: \(path)")
        }
    }

}
