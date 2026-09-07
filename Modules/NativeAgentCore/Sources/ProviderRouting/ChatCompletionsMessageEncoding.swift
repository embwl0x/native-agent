import Foundation
import NativeAgentCore

/// Chat Completions block encoding shared by OpenAI, OpenRouter, Moonshot,
/// and xAI. Tool-use messages precede their tool results; image parts are
/// retained only on messages without tool calls. Moonshot supplies its
/// separately retrieved reasoning replay when encoding an assistant tool call.
func chatCompletionsMessages(
    from message: LLMMessage,
    reasoning: String? = nil
) -> [[String: Any]] {
    let role = message.role == .user ? "user" : "assistant"
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
                    "arguments": String(data: inputJSON, encoding: .utf8) ?? "{}",
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
