import Foundation
import WebKit

extension BrowserActionRoutes {
    private static let readRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    // N9 fix: JSON-encode every interpolated value so crafted selectors or text
    // containing quotes, backslashes, or other JS metacharacters cannot inject
    // arbitrary JavaScript.  JSONSerialization produces a properly escaped JS
    // string literal including the surrounding double-quotes.
    private static func jsStringLiteral(_ s: String) throws -> String {
        // A JavaScript string literal is a JSON *fragment*, not an object or
        // array.  Without `.fragmentsAllowed`, Foundation raises an Objective-C
        // exception for ordinary selector/text input before Swift can handle it.
        let data = try JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor public static func click(selector: String, runJS: @MainActor (String) async throws -> Any?) async throws {
        // N9 fix: use JSON-encoded selector literal to prevent JS injection.
        let jsSel = try Self.jsStringLiteral(selector)
        _ = try await runJS("document.querySelector(\(jsSel)).click()")
    }

    @MainActor public static func fill(selector: String, text: String, runJS: @MainActor (String) async throws -> Any?) async throws {
        do {
            _ = try await runJS(Self.fillScript(selector: selector, text: text))
        } catch {
            throw Self.fillFailure(error)
        }
    }

    /// WebKit's localized description hides the script's outcome explanation.
    /// Keep that bounded detail for the caller, without reclassifying transport
    /// failures or cancellation as a DOM rejection.
    public static func fillFailure(_ error: Error) -> Error {
        let failure = error as NSError
        guard failure.domain == WKError.errorDomain,
              failure.code == WKError.Code.javaScriptExceptionOccurred.rawValue,
              let message = failure.userInfo["WKJavaScriptExceptionMessage"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return error }
        return BrowserError.fillFailed(String(message.prefix(1024)))
    }

    /// Success means this immediate DOM readback matched, not that a framework
    /// persisted the edit or a later page update cannot undo it.
    public static func fillScript(selector: String, text: String) throws -> String {
        // N9 fix: use JSON-encoded selector and text literals to prevent JS injection.
        let jsSel = try jsStringLiteral(selector)
        let jsText = try jsStringLiteral(text)
        return """
        (function(){
          var el = document.querySelector(\(jsSel));
          if(!el) throw new Error('Element not found: ' + \(jsSel));
          var editableContent = el.isContentEditable === true;
          if(!editableContent && !('value' in el)) {
            throw new Error('Element has no fillable value or editable content');
          }
          var requested = \(jsText);
          if(editableContent) el.textContent = requested;
          else el.value = requested;
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          var observed = editableContent ? el.textContent : el.value;
          if(observed !== requested) {
            throw new Error('Fill outcome mismatch after input/change events; the page did not retain the requested text. Do not blindly retry.');
          }
        })()
        """
    }

    @MainActor public static func readText(runJS: @MainActor (String) async throws -> Any?) async throws -> String {
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

    @MainActor public static func readLinks(runJS: @MainActor (String) async throws -> Any?) async throws -> [BrowserLink] {
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

    private static func decodeBrowserLinks(_ raw: Any) throws -> [BrowserLink] {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([BrowserLink].self, from: data)
    }

}

// MARK: - Errors

public enum BrowserError: LocalizedError {
    case notReady
    case screenshotFailed
    case badRequest(String)
    case fillFailed(String)
    /// C7 fix: returned when navigate is called while another navigation is in progress.
    case busy
    case timeout
    /// C7 fix (N8): returned when the current page's URL scheme is not http/https.
    case unsafeScheme(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Browser window is not ready"
        case .screenshotFailed: return "Failed to capture screenshot"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .fillFailed(let detail): return "Browser fill failed: \(detail)"
        case .busy: return "Browser is busy with another navigation — try again shortly"
        case .timeout: return "Browser navigation timed out"
        case .unsafeScheme(let scheme): return "Current page scheme '\(scheme)' is not allowed; only http/https are permitted"
        }
    }
}
