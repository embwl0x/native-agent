import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ChatCompletionsMessageEncoding.swift` | `chatCompletionsMessages` |

public extension LLMToolSchema {
    func checkedParameters() throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: parametersJSON)
        guard case .object = value else {
            throw LLMError.providerError(message: "Tool schema \(name) must be a JSON object. Repair its catalog declaration before using it.")
        }
        return value
    }
}

/// Retained calls and catalog schemas must carry the object that was recorded. The provider codecs share this boundary rather than inventing empty objects.
func checkedProviderJSONObject(_ data: Data, owner: String) throws -> [String: Any] {
    guard String(data: data, encoding: .utf8) != nil,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LLMError.providerError(message: "\(owner) is not a UTF-8 JSON object. Repair the recorded call or tool catalog before sending it.")
    }
    return object
}

func checkedProviderJSONText(_ data: Data, owner: String) throws -> String {
    _ = try checkedProviderJSONObject(data, owner: owner)
    // The checked object read above establishes UTF-8; keep the original bytes.
    guard let text = String(data: data, encoding: .utf8) else {
        throw LLMError.providerError(message: "\(owner) is not UTF-8")
    }
    return text
}

package func providerToolResultContent(_ content: String, isError: Bool) -> String {
    guard isError else { return content }
    return jsonToolResultContent(content, isError: true)
}

package func markerToolResultContent(_ content: String, isError: Bool) -> String {
    jsonToolResultContent(content, isError: isError)
        .replacingOccurrences(of: "<", with: #"\u003c"#)
}

private func jsonToolResultContent(_ content: String, isError: Bool) -> String {
    let flag = "tool_result_is_error"
    let prefix = "{\"\(flag)\":true"
    if case .object(let fields)? = try? JSONValue.parse(Data(content.utf8)) {
        let object = content.hasPrefix("\u{feff}") ? String(content.dropFirst()) : content
        guard isError else { return object }
        if fields[flag] != nil {
            return prefix + ",\"result\":" + object + "}"
        }
        let fieldsAndClose = object.drop(while: \.isWhitespace).dropFirst()
        return prefix + (fields.isEmpty ? "" : ",") + String(fieldsAndClose)
    }
    var encoded = isError ? prefix + ",\"error\":" : ""
    JSONValue.encodeString(content, into: &encoded)
    return isError ? encoded + "}" : encoded
}

/// Tool results follow their calls before any accompanying image message. Moonshot replays its retained reasoning with assistant calls.
func chatCompletionsMessages(
    from message: LLMMessage,
    reasoning: String? = nil
) throws -> [[String: Any]] {
    let role = message.role.rawValue
    var textParts: [String] = []
    var contentParts: [[String: Any]] = []
    var toolCalls: [[String: Any]] = []
    var toolResults: [[String: Any]] = []
    for block in message.content {
        switch block {
        case .text(let text):
            textParts.append(text)
            contentParts.append(["type": "text", "text": text])
        case .image(let mediaType, let base64, _, _):
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mediaType);base64,\(base64)"],
            ])
        case .toolUse(let id, let name, let inputJSON):
            toolCalls.append([
                "id": id,
                "type": "function",
                "function": [
                    "name": name,
                    "arguments": try checkedProviderJSONText(inputJSON, owner: "Recorded tool call \(name) (\(id))"),
                ],
            ])
        case .toolResult(let toolUseID, let content, let isError):
            toolResults.append(["role": "tool", "tool_call_id": toolUseID,
                "content": providerToolResultContent(content, isError: isError)])
        }
    }
    var output: [[String: Any]] = []
    if !toolCalls.isEmpty {
        var assistant: [String: Any] = [
            "role": "assistant",
            "content": textParts.isEmpty ? NSNull() : textParts.joined(separator: "\n"),
            "tool_calls": toolCalls,
        ]
        if let reasoning {
            assistant["reasoning_content"] = reasoning
        }
        output.append(assistant)
    }
    output.append(contentsOf: toolResults)
    if toolCalls.isEmpty, !contentParts.isEmpty {
        let hasImage = message.content.contains { if case .image = $0 { return true }; return false }
        output.append([
            "role": role,
            "content": hasImage ? contentParts : textParts.joined(separator: "\n"),
        ])
    }
    return output
}
