import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter
// Blueprint: | `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction`: typed argument redaction; `redactedResultJSON` parses once, strips screen pixels then injected values and encodes once; malformed screen-only text passes through, malformed injection-shaped text is suppressed |

package enum ChatToolJSONRedaction {
    /// Redact secret-bearing arguments before persistence or preview; malformed
    /// injection arguments cannot be inspected and are suppressed.
    package nonisolated static func injectionRedactedArgJSON(tool: String, json: String) -> String {
        // The app door: only an action whose args carry a key or token, or a
        // script naming one, is rewritten, so every other call keeps its
        // exact arguments.
        if MacInjectionArgRedaction.normalized(tool) == "app" {
            guard let parsed = try? JSONValue.parse(Data(json.utf8)), case .object(let input) = parsed,
                  MacInjectionArgRedaction.appDoorCarriesSecret(input) else { return json }
            return (try? JSONValue.object(MacInjectionArgRedaction.redacted(tool: tool, input: input))
                .serialize(pretty: false)) ?? "[redacted: \(tool) arguments]"
        }
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

    /// Strip screen pixels, then injected values, through one parse and encode.
    /// Malformed screen-only text passes through; injection-shaped text cannot.
    package nonisolated static func redactedResultJSON(tool: String, json: String) -> String {
        let injection = MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool)
        let screen = MacScreenViewResultRedaction.carriesImage(tool: tool)
        guard injection || screen else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)) else {
            return injection && (json.contains("\"") || json.contains("{"))
                ? "[redacted: \(tool) result]" : json
        }
        let redacted = MacInjectionResultRedaction.redacted(tool: tool,
            result: MacScreenViewResultRedaction.redacted(tool: tool, result: parsed))
        guard let out = try? redacted.serialize(pretty: false) else {
            return screen || json.contains("\"") || json.contains("{")
                ? "[redacted: \(tool) result]" : json
        }
        return out
    }

}
