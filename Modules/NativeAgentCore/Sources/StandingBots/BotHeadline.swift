import Foundation
// Blueprint: | `BotHeadline.swift` | `BotHeadline` enum; `make`, `clipped` preserve whole-word reply headlines |

/// Headlines use the first prose line without markdown; replies without prose have no headline.
public enum BotHeadline {
    public static func make(from reply: String, cap: Int = 240) -> String {
        var fence: (mark: Character, length: Int)?
        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let first = line.first, first == "`" || first == "~" {
                let length = line.prefix(while: { $0 == first }).count
                if let open = fence {
                    if first == open.mark, length >= open.length,
                       line.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                } else if length >= 3 {
                    fence = (first, length)
                }
                if length >= 3 { continue }
            }
            if fence != nil { continue }
            if line.isEmpty { continue }
            if line.hasPrefix("|") || line.hasPrefix("---") || line.hasPrefix("***") { continue }
            if line.allSatisfy({ "-=|: ".contains($0) }) { continue }
            while let first = line.first, "#>-*•".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if line.isEmpty { continue }
            return clipped(line, cap: cap)
        }
        return ""
    }

    /// Keep whole words, including when reading headlines saved by older builds.
    public static func clipped(_ text: String, cap: Int = 240) -> String {
        guard cap > 0 else { return "" }
        guard text.count > cap else { return text }
        let end = text.index(text.startIndex, offsetBy: cap)
        let prefix = text[..<end]
        if text[end].isWhitespace { return prefix.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let boundary = prefix.lastIndex(where: { $0.isWhitespace }) else { return "…" }
        return prefix[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
