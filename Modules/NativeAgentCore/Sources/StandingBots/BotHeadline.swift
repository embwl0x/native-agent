import Foundation

/// The one line a bot card shows for a reply (2026-09-11, found by Agent
/// driving her first bot: the headline was the first 240 bytes of a markdown
/// table, pipes and all). The first line of prose, with markdown marks
/// stripped; table rows, fences and rules are skipped. Falls back to a plain
/// nothing at all when the reply has no prose: a run that said nothing has no
/// headline, and "Reply saved" over an empty reply was a claim the record did
/// not support (Agent, 2026-09-13 — an interrupted, empty run read as a saved
/// reply). The card derives the line from the run's status instead.
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
            return String(line.prefix(cap))
        }
        return ""
    }
}
