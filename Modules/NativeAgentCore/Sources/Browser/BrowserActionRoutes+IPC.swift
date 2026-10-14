import Foundation

public protocol BrowserIPCWindowEffects: BrowserRouteEffects {
    @MainActor var navigationInProgress: Bool { get }
    @MainActor func navigateFromIPC(_ url: URL, runID: String) async throws -> BrowserNavigationResult
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

    private static func currentPageSchemeAllowed(_ currentURL: String?) -> Bool {
        guard let currentURL else { return true }
        let scheme = URL(string: currentURL)?.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    @MainActor public static func handleIPCRoute(method: String, path: String, body: Data, effects: any BrowserIPCWindowEffects) async throws -> [String: Any] {
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
            if effects.navigationInProgress {
                return ["ok": false, "error": "browser_busy",
                        "detail": "Another navigation is already in progress — retry after it completes"]
            }
            let requestedRunID = (json["runId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let runID = requestedRunID?.isEmpty == false
                ? requestedRunID!
                : "ipc-\(UUID().uuidString.lowercased())"
            let result = try await effects.navigateFromIPC(url, runID: runID)
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
            if !currentPageSchemeAllowed(effects.currentURL()) {
                let cur = effects.currentURL().flatMap { URL(string: $0)?.scheme } ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            let png = try await effects.screenshot()
            return ["ok": true, "png_base64": png.base64EncodedString()]

        case "/browser/click":
            guard let sel = json["selector"] as? String else { throw BrowserError.badRequest("selector required") }
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed(effects.currentURL()) {
                let cur = effects.currentURL().flatMap { URL(string: $0)?.scheme } ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            try await effects.click(selector: sel)
            return ["ok": true]

        case "/browser/fill":
            guard let sel = json["selector"] as? String,
                  let text = json["text"] as? String else { throw BrowserError.badRequest("selector and text required") }
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed(effects.currentURL()) {
                let cur = effects.currentURL().flatMap { URL(string: $0)?.scheme } ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            try await effects.fill(selector: sel, text: text)
            return ["ok": true]

        case "/browser/read_text":
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed(effects.currentURL()) {
                let cur = effects.currentURL().flatMap { URL(string: $0)?.scheme } ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            let text = try await effects.readText()
            return ["ok": true, "text": text]

        case "/browser/read_links":
            // N8 fix: scheme check before operating
            if !currentPageSchemeAllowed(effects.currentURL()) {
                let cur = effects.currentURL().flatMap { URL(string: $0)?.scheme } ?? "unknown"
                return ["ok": false, "error": "url_scheme_not_allowed",
                        "detail": "Current page scheme '\(cur)' is not allowed; only http/https are permitted"]
            }
            let links = try await effects.readLinks()
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(links))
            return ["ok": true, "links": encoded]

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
