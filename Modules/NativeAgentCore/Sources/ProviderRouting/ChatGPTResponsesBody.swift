import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ChatGPTResponsesBody.swift` | ChatGPTTransport Responses wire body, structured input roles and native tool encoding |
extension ChatGPTTransport {
    /// Build the Responses-API request body from a structured message array.
    /// Each LLMMessage / content block maps to an `input` item:
    ///   - text user message       → {type:"message",role:"user",content:[{type:"input_text",text}]}
    ///   - text assistant message  → {type:"message",role:"assistant",content:[{type:"output_text",text}]}
    ///   - toolUse (assistant)     → {type:"function_call",name,arguments:<jsonString>,call_id}
    ///   - toolResult (user)       → {type:"function_call_output",call_id,output:<string>}
    ///   - text system message     → {type:"message",role:"developer",content:[{type:"input_text",text}]}
    /// `instructions` carries the system prompt. The single-prompt `complete`
    /// is one user message through this same builder.
    ///
    /// MID-CONVERSATION SYSTEM (`LLMMessage.Role.system`): a Responses `input`
    /// message item takes role `user`, `assistant`, `system` or `developer`.
    /// `developer` is the Responses-era name for the instruction role that
    /// outranks user text and is the one OpenAI documents for
    /// mid-conversation instructions, so that is what we emit; its content
    /// parts are INPUT parts (`input_text`), same as a user message —
    /// `output_text` is assistant-only and is rejected on an input item.
    /// Parts' `model.call` message interface accepts this role. Turn context
    /// always uses a leading user text block instead.
    static let midConversationSystemRole = "developer"

    /// Three-way input-item role. `.system` becomes the mid-conversation
    /// instruction role; the turn-level system prompt still rides in
    /// `instructions`.
    static func responsesRole(_ role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return midConversationSystemRole
        }
    }
    /// `output_text` is assistant-only; every INPUT item (user and the
    /// mid-conversation instruction role alike) carries `input_text`.
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
        supportsFast: Bool? = nil
    ) throws -> [String: Any] {
        var inputItems: [[String: Any]] = []
        for m in messages {
            // Group adjacent text/pixels on vision turns, flushing before each
            // tool item so helper feedback keeps both its call output and pixels
            // in transcript order. Text-only turns retain their per-block shape.
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
                    let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
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
        // The OAuth endpoint returns 400 "Instructions are required" without
        // this field, and a blank one counts as missing: every caller says
        // what it is, and none is given a stand-in. `max_output_tokens` is
        // left out because the chatgpt.com backend rejects it.
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["instructions"] = system
        }
        OpenAIExecutionControls.applyResponsesControls(
            to: &body,
            model: model,
            transport: transport,
            supportedEfforts: supportedEfforts,
            supportsFast: supportsFast
        )
        // Stable prompt-cache routing is present only for a bound session.
        if let cacheKey = Self.currentPromptCacheKey() {
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
                do {
                    entry["parameters"] = try JSONSerialization.jsonObject(with: t.parametersJSON)
                } catch {
                    if transport == .publicAPI { throw error }
                    entry["parameters"] = ["type": "object", "properties": [:] as [String: Any]] as [String: Any]
                }
                toolList.append(entry)
            }
            body["tools"] = toolList
        }
        return body
    }
}
