import Foundation
// Blueprint: | `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |

/// Bundled completion policy; substitution never interprets evidence as a template.
package func completionPolicy(_ job: String, section: String = "prompt", arguments: [String] = []) throws -> String {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/prompts/\(job).md")
    let text = try String(contentsOf: url, encoding: .utf8)
    let marker = "<!-- \(section) -->\n"
    let matches = text.components(separatedBy: "\n<!-- end -->\n").filter { $0.hasPrefix(marker) }
    guard matches.count == 1, let match = matches.first else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "Completion policy \(job).\(section) is missing or repeated."])
    }
    let template = String(match.dropFirst(marker.count))
    guard template.components(separatedBy: "%@").count - 1 == arguments.count,
          !template.replacingOccurrences(of: "%@", with: "").contains("%") else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "Completion policy \(job).\(section) has invalid substitutions."])
    }
    return String(format: template, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments.map { $0 as CVarArg })
}

/// Serializes compatibility prose and image disclosure; callers retain role semantics and traces.
package func llmCompatibilityPrompt(
    messages: [LLMMessage],
    rolePrefix: (LLMMessage.Role) -> String
) throws -> (text: String, imageCount: Int) {
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
                // Never stringify image bytes.
                imageCount += 1
            }
        }
    }
    if imageCount > 0 {
        parts.insert(try completionPolicy("unsupported-images", arguments: [String(imageCount)]), at: 0)
    }
    return (parts.joined(separator: "\n"), imageCount)
}
