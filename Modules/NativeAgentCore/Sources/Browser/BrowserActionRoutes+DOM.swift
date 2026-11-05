import Foundation
import WebKit
// Blueprint: | `BrowserActionRoutes+DOM.swift` | DOM reads use one 3750ms deadline; cleanup and decoding preserve unknown outcomes |

extension BrowserActionRoutes {
    /// Isolated-world readiness shares one observer, cleanup boundary and 3750ms deadline.
    private static func domReadScript(read: String, ready: String) -> String {
        """
        return await new Promise((resolve, reject) => {
          let done = false, timer, observer;
          const read = () => { \(read) };
          const finish = (value, error) => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            observer.disconnect();
            document.removeEventListener('DOMContentLoaded', check);
            document.removeEventListener('readystatechange', check);
            window.removeEventListener('pageshow', check);
            window.removeEventListener('pagehide', end);
            if (error) reject(error); else resolve(value);
          };
          const check = () => {
            try { const value = read(); if (\(ready)) finish(value); }
            catch (error) { finish(undefined, error); }
          };
          const end = () => { try { finish(read()); } catch (error) { finish(undefined, error); } };
          observer = new MutationObserver(check);
          observer.observe(document, {subtree:true, childList:true, characterData:true, attributes:true});
          document.addEventListener('DOMContentLoaded', check);
          document.addEventListener('readystatechange', check);
          window.addEventListener('pageshow', check);
          window.addEventListener('pagehide', end);
          timer = setTimeout(end, 3750);
          check();
        });
        """
    }

    // JSON-encode interpolated values so selector or text metacharacters cannot inject JavaScript.
    private static func jsStringLiteral(_ s: String) throws -> String {
        // Foundation requires fragmentsAllowed for scalar strings or raises an Objective-C exception before Swift can catch it.
        let data = try JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor public static func click(selector: String, runJS: @MainActor (String) async throws -> Any?) async throws {
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

    /// Keep the script's bounded explanation: WebKit hides it in localizedDescription; transport failures stay distinct.
    public static func fillFailure(_ error: Error) -> Error {
        let failure = error as NSError
        guard failure.domain == WKError.errorDomain,
              failure.code == WKError.Code.javaScriptExceptionOccurred.rawValue,
              let message = failure.userInfo["WKJavaScriptExceptionMessage"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return error }
        return BrowserError.fillFailed(String(message.prefix(1024)))
    }

    /// Immediate DOM readback cannot prove framework persistence or prevent later page updates.
    public static func fillScript(selector: String, text: String) throws -> String {
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

    @MainActor public static func readText(runDOMRead: @MainActor (String) async throws -> Any?) async throws -> String {
        try Task.checkCancellation()
        let result = try await runDOMRead(domReadScript(read: """
              var body = document.body;
              var root = document.documentElement;
              return ((body && (body.innerText || body.textContent)) ||
                      (root && (root.innerText || root.textContent)) ||
                      '').trim();
            """, ready: "typeof value === 'string' && value.trim().length > 0"))
        try Task.checkCancellation()
        return result as? String ?? ""
    }

    @MainActor public static func readLinks(runDOMRead: @MainActor (String) async throws -> Any?) async throws -> [BrowserLink] {
        try Task.checkCancellation()
        let js = domReadScript(read: """
          return Array.from(document.querySelectorAll('a[href]')).slice(0,200).map(function(a){
            return {url: a.href, text: (a.innerText || a.textContent || '').trim()};
          });
        """, ready: "value.length > 0")
        let raw = try await runDOMRead(js)
        try Task.checkCancellation()
        return try raw.map(decodeBrowserLinks) ?? []
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
    case busy
    case timeout
    case outcomeUnknown
    case contentProcessTerminated
    case unsafeScheme(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Browser window is not ready"
        case .screenshotFailed: return "Failed to capture screenshot"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .fillFailed(let detail): return "Browser fill failed: \(detail)"
        case .busy: return "Browser is busy with another navigation — try again shortly"
        case .timeout: return """
            Browser operation exceeded its native deadline; its outcome is unknown. The page was retired; open it explicitly before \
            further use.
            """
        case .outcomeUnknown: return """
            Browser operation was interrupted after dispatch; its outcome is unknown. The page was retired; open it explicitly before \
            further use.
            """
        case .contentProcessTerminated: return """
            Browser content process terminated; its outcome is unknown. The page was retired; open it explicitly before further use.
            """
        case .unsafeScheme(let scheme): return "Current page scheme '\(scheme)' is not allowed; only http/https are permitted"
        }
    }

    var hasUnknownOutcome: Bool {
        switch self {
        case .timeout, .outcomeUnknown, .contentProcessTerminated: return true
        default: return false
        }
    }
}
