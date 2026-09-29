import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter

package enum ChatToolJSONRedaction {
    /// W2/W3-FIX-R2 — redact an injection tool's ARGUMENT json before it is
    /// persisted or previewed. Works on the serialized string because that is
    /// what this layer is handed. A body that will not parse is dropped
    /// entirely for a secret-bearing tool: an unparseable payload we cannot
    /// redact is not a payload worth keeping.
    package nonisolated static func injectionRedactedArgJSON(tool: String, json: String) -> String {
        guard MacInjectionArgRedaction.carriesSecretArgs(tool: tool) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)),
              case .object = parsed,
              let out = try? MacInjectionArgRedaction
                .redactedPayload(tool: tool, payload: parsed)
                .serialize(pretty: false) else {
            return "[redacted: \(tool) arguments]"
        }
        return out
    }

    /// Same, for an injection tool's RESULT (an `ax_act` re-reads and returns
    /// the value it just wrote).
    package nonisolated static func injectionRedactedResultJSON(tool: String, json: String) -> String {
        guard MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)),
              let out = try? MacInjectionResultRedaction
                .redacted(tool: tool, result: parsed)
                .serialize(pretty: false) else {
            // A non-JSON summary from an injection tool cannot be inspected for
            // the written value, so it is not kept verbatim.
            return json.contains("\"") || json.contains("{")
                ? "[redacted: \(tool) result]"
                : json
        }
        return out
    }

    /// W3.5-FIX 3 — strip `mac_view`'s base64 picture out of a serialized
    /// RESULT before it is persisted or previewed. Unlike the injection
    /// redactors this cannot fall back to "[redacted]" on a parse failure: a
    /// summary that will not parse also cannot contain a JSON `image` key we
    /// put there, and blanking every unparseable read result would destroy the
    /// transcript. A parse failure therefore leaves the (image-free) text.
    package nonisolated static func screenViewRedactedResultJSON(tool: String, json: String) -> String {
        guard MacScreenViewResultRedaction.carriesImage(tool: tool) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)) else { return json }
        let stripped = MacScreenViewResultRedaction.redacted(tool: tool, result: parsed)
        guard let out = try? stripped.serialize(pretty: false) else {
            return "[redacted: \(tool) result]"
        }
        return out
    }

}
