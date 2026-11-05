import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ChatGPTResponsesBody.swift` | ChatGPTTransport Responses wire body, structured input roles and native tool encoding |
extension ChatGPTTransport {
    /// Mid-conversation instructions use developer/input_text; output_text is assistant-only. The turn-level prompt stays in instructions.
    static let midConversationSystemRole = "developer"

    /// Mid-conversation system messages become developer input; the turn-level prompt stays in instructions.
    static func responsesRole(_ role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return midConversationSystemRole
        }
    }
    /// `output_text` is assistant-only; every INPUT item (user and the mid-conversation instruction role alike) carries `input_text`.
    static func responsesTextType(_ role: LLMMessage.Role) -> String {
        role == .assistant ? "output_text" : "input_text"
    }
    static func buildResponsesBodyFromMessages(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?,
        transport: OpenAIExecutionControls.Transport = .chatGPTOAuth,
        supportedEfforts: [String]? = nil,
        supportsFast: Bool? = nil, call: LLMCall
    ) throws -> [String: Any] {
        var inputItems: [[String: Any]] = []
        for m in messages {
            // Group adjacent text/pixels on vision turns, flushing before each tool item so helper feedback keeps both its call output and pixels in
            // transcript order. Text-only turns retain their per-block shape.
            let hasImage = m.content.contains { if case .image = $0 { return true }; return false }
            var content: [[String: Any]] = []
            func flushContent() {
                guard !content.isEmpty else { return }
                inputItems.append([
                    "type": "message",
                    "role": Self.responsesRole(m.role),
                    "content": content,
                ])
                content.removeAll()
            }
            for block in m.content {
                switch block {
                case .text(let t):
                    content.append(["type": Self.responsesTextType(m.role), "text": t])
                    if !hasImage { flushContent() }
                case .toolUse(let id, let name, let inputJSON):
                    flushContent()
                    let argsStr = try checkedProviderJSONText(inputJSON, owner: "Recorded tool call \(name) (\(id))")
                    inputItems.append([
                        "type": "function_call",
                        "name": name,
                        "arguments": argsStr,
                        "call_id": id,
                    ])
                case .toolResult(let toolUseId, let content, _):
                    flushContent()
                    inputItems.append([
                        "type": "function_call_output",
                        "call_id": toolUseId,
                        "output": content,
                    ])
                case .image(let mediaType, let base64, _, _):
                    content.append([
                        "type": "input_image",
                        "image_url": "data:\(mediaType);base64,\(base64)",
                    ])
                }
            }
            flushContent()
        }
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "input": inputItems,
            "text": ["verbosity": "medium"],
            "tool_choice": "auto",
            "parallel_tool_calls": true,
        ]
        // The OAuth endpoint rejects blank instructions and max_output_tokens, so every caller supplies its own instructions without an output cap.
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["instructions"] = system
        }
        try OpenAIExecutionControls.applyResponsesControls(
            to: &body,
            model: model,
            transport: transport,
            supportedEfforts: supportedEfforts,
            supportsFast: supportsFast, call: call
        )
        // Stable prompt-cache routing is present only for a bound session.
        if let cacheKey = Self.currentPromptCacheKey(call: call) {
            body["prompt_cache_key"] = cacheKey
        }
        if let tools, !tools.isEmpty {
            var toolList: [[String: Any]] = []
            for t in tools {
                var entry: [String: Any] = [
                    "type": "function",
                    "name": t.name,
                    "description": t.description,
                ]
                if transport == .publicAPI { entry["strict"] = false }
                entry["parameters"] = try t.checkedParameters().foundationObject
                toolList.append(entry)
            }
            body["tools"] = toolList
        }
        return body
    }
}
