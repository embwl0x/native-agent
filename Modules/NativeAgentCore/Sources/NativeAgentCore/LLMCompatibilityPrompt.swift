import Foundation

/// Serializes compatibility prose; callers retain role semantics and image handling.
package func llmCompatibilityPrompt(
    messages: [LLMMessage],
    rolePrefix: (LLMMessage.Role) -> String
) -> (text: String, imageCount: Int) {
    var parts: [String] = []
    var imageCount = 0
    for m in messages {
        let prefix = rolePrefix(m.role)
        for block in m.content {
            switch block {
            case .text(let t):
                parts.append("\(prefix) \(t)")
            case .toolUse(_, let name, let inputJSON):
                let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                parts.append("\(prefix) [tool_use \(name) \(argsStr)]")
            case .toolResult(_, let content, _):
                parts.append("\(prefix) [tool_result] \(content)")
            case .image:
                // Never stringify image bytes; callers own unsupported-image notes.
                imageCount += 1
            }
        }
    }
    return (parts.joined(separator: "\n"), imageCount)
}
