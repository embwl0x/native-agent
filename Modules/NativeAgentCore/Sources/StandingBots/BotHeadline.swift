import Foundation

/// The one line a bot card shows for a reply (2026-09-11, found by Agent
/// driving her first bot: the headline was the first 240 bytes of a markdown
/// table, pipes and all). The first line of prose, with markdown marks
/// stripped; table rows, fences and rules are skipped. Falls back to a plain
/// word when the reply has no prose at all.
public enum BotHeadline {
    public static func make(from reply: String, cap: Int = 240) -> String {
        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("|") || line.hasPrefix("```") || line.hasPrefix("---") || line.hasPrefix("***") { continue }
            if line.allSatisfy({ "-=|: ".contains($0) }) { continue }
            while let first = line.first, "#>-*•".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if line.isEmpty { continue }
            return String(line.prefix(cap))
        }
        let flat = reply.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return flat.isEmpty ? "Reply saved" : String(flat.prefix(cap))
    }
}
