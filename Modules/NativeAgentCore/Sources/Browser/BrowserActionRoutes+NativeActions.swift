import Foundation
import NativeAgentCore
import PersistenceCore

extension BrowserActionRoutes {
    public func runBrowserNativeAction(
        action: NativeActionRecord,
        dryRun: Bool,
        input: [String: Any],
        dataRoot: URL,
        decode: (JSONValue, String) throws -> BrowserRouteDecodedRun<BrowserRun>
    ) async throws -> NativeActionReceipt {
        let jsonInput = try NativeActionRouteSupport.jsonValueBody(input)
        switch action.id {
        case "browser.open_url", "browser.navigate":
            let url = Self.stringInput(input, "url")
                ?? Self.stringInput(input, "href")
                ?? Self.stringInput(input, "target")
                ?? ""
            let captureSource = ConnectorInputValue.bool(
                jsonInput["captureSource"] ?? jsonInput["capture_source"],
                default: false
            )
            let captureScreenshot = ConnectorInputValue.bool(
                jsonInput["captureScreenshot"] ?? jsonInput["capture_screenshot"],
                default: false
            )
            let run = try await runBrowser(
                url: url,
                dryRun: dryRun,
                captureSource: captureSource,
                captureScreenshot: captureScreenshot,
                dataRoot: dataRoot,
                decode: decode
            )
            // Browser Core projects the one canonical terminal transition into
            // the native-action receipt feed for both public aliases. Do not
            // append a second app-owned receipt for browser.navigate.
            if action.id == "browser.open_url" || action.id == "browser.navigate" {
                return NativeActionReceipt(
                    id: run.id,
                    actionId: action.id,
                    name: action.name,
                    kind: action.kind,
                    status: run.status,
                    dryRun: run.dryRun,
                    approvalId: run.approvalId,
                    createdAt: run.createdAt
                )
            }
            return try await effects.appendNativeActionReceipt(
                action: action,
                status: run.status,
                dryRun: dryRun,
                output: try JSONValue.fromEncodable(run)
            )

        case "browser.read_text":
            if dryRun {
                return try await effects.appendNativeActionReceipt(
                    action: action,
                    status: "dry_run",
                    dryRun: true,
                    output: .object(["actionId": .string(action.id), "status": .string("dry_run")])
                )
            }
            let capture = try await captureCurrentVisibleBrowser(
                readText: true,
                readLinks: false,
                screenshot: false
            )
            let receipt = try await persistBrowserTextCapture(
                id: "browser-text-\(UUID().uuidString.lowercased())",
                url: capture.url,
                text: capture.text ?? "",
                links: nil
            )
            return try await effects.appendNativeActionReceipt(
                action: action,
                status: "completed",
                dryRun: false,
                output: .object(receipt)
            )

        case "browser.read_links":
            if dryRun {
                return try await effects.appendNativeActionReceipt(
                    action: action,
                    status: "dry_run",
                    dryRun: true,
                    output: .object(["actionId": .string(action.id), "status": .string("dry_run")])
                )
            }
            let capture = try await captureCurrentVisibleBrowser(
                readText: false,
                readLinks: true,
                screenshot: false
            )
            let receipt = try await persistBrowserLinksCapture(
                id: "browser-links-\(UUID().uuidString.lowercased())",
                url: capture.url,
                links: capture.links ?? []
            )
            return try await effects.appendNativeActionReceipt(
                action: action,
                status: "completed",
                dryRun: false,
                output: .object(receipt)
            )

        case "browser.screenshot":
            if dryRun {
                return try await effects.appendNativeActionReceipt(
                    action: action,
                    status: "dry_run",
                    dryRun: true,
                    output: .object(["actionId": .string(action.id), "status": .string("dry_run")])
                )
            }
            let capture = try await captureCurrentVisibleBrowser(
                readText: false,
                readLinks: false,
                screenshot: true
            )
            guard let png = capture.screenshot else {
                throw NSError(domain: "NativeAgentBrowser", code: -500, userInfo: [
                    NSLocalizedDescriptionKey: "Browser screenshot capture returned no image data"
                ])
            }
            let receipt = try await persistBrowserScreenshotCapture(
                id: "browser-shot-\(UUID().uuidString.lowercased())",
                url: capture.url,
                png: png
            )
            return try await effects.appendNativeActionReceipt(
                action: action,
                status: "completed",
                dryRun: false,
                output: .object(receipt)
            )

        default:
            throw NativeActionRouteSupport.notImplemented(
                method: "runNativeAction",
                reason: "Swift browser action '\(action.id)' is not implemented",
                followup: "vault://nativeagent/zombie_stub_audit#runNativeAction"
            )
        }
    }

    static func stringInput(_ input: [String: Any], _ key: String) -> String? {
        guard let raw = input[key] else { return nil }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = raw as? NSNumber {
            return n.stringValue
        }
        return nil
    }

}
