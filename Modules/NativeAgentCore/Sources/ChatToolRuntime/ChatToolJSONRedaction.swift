import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter
import ToolRegistry
// Blueprint: | `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction`, `redactedResultJSON`: Redact before preview bounds. |

package enum ChatToolJSONRedaction {
    /// Redact secret-bearing arguments before persistence or preview; malformed injection arguments cannot be inspected and are suppressed.
    package nonisolated static func injectionRedactedArgJSON(tool: String, json: String, turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> String {
        // App evidence uses the execution owner's bound names before any content policy sees the arguments.
        if MacInjectionArgRedaction.normalized(tool) == "app" {
            guard let parsed = try? JSONValue.parse(Data(json.utf8)), case .object(let input) = parsed else {
                return "[redacted: \(tool) arguments could not be read]"
            }
            return (try? JSONValue.object(MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn, catalog: catalog))
                .serialize(pretty: false)) ?? "[redacted: \(tool) arguments]"
        }
        guard MacInjectionArgRedaction.carriesSecretArgs(tool: tool, turn: turn, catalog: catalog) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)),
              case .object = parsed,
              let out = try? MacInjectionArgRedaction
                .redactedPayload(tool: tool, payload: parsed, turn: turn, catalog: catalog)
                .serialize(pretty: false) else {
            return "[redacted: \(tool) arguments]"
        }
        return out
    }

    /// Strip screen pixels, then injected values, through one parse and encode. Malformed screen-only text passes through; injection-shaped text cannot.
    package nonisolated static func redactedResultJSON(tool: String, json: String, turn: Turn?, catalog: [String: AppActionBinding]? = nil) -> String {
        let injection = MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool, turn: turn, catalog: catalog)
        let screen = MacScreenViewResultRedaction.carriesImage(tool: tool)
        guard injection || screen else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)) else {
            return injection && (json.contains("\"") || json.contains("{"))
                ? "[redacted: \(tool) result]" : json
        }
        let redacted = MacInjectionResultRedaction.redacted(tool: tool,
            result: MacScreenViewResultRedaction.redacted(tool: tool, result: parsed), turn: turn, catalog: catalog)
        guard let out = try? redacted.serialize(pretty: false) else {
            return screen || json.contains("\"") || json.contains("{")
                ? "[redacted: \(tool) result]" : json
        }
        return out
    }

}
