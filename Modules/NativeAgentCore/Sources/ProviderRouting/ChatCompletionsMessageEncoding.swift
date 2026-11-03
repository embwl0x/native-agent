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

/// Retained calls and catalog schemas must carry the object that was recorded.
/// The provider codecs share this boundary rather than inventing empty objects.
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

/// Chat Completions block encoding shared by OpenAI, OpenRouter, Moonshot,
/// and xAI. Tool-use messages precede their tool results; image parts are
/// retained only on messages without tool calls. Moonshot supplies its
/// separately retrieved reasoning replay when encoding an assistant tool call.
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
        case .toolResult(let toolUseID, let content, _):
            toolResults.append(["role": "tool", "tool_call_id": toolUseID, "content": content])
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
    } else if !contentParts.isEmpty {
        let hasImage = message.content.contains { if case .image = $0 { return true }; return false }
        output.append([
            "role": role,
            "content": hasImage ? contentParts : textParts.joined(separator: "\n"),
        ])
    }
    output.append(contentsOf: toolResults)
    return output
}
