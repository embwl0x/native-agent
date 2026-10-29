import Foundation

// Blueprint: | `InboxDigestGroupProjection.swift` | `InboxDigestGroups`: read-only platform inbox adapter preferring structured groups over legacy prose |

/// Structured digest groups take precedence over the legacy JSONL prose format.
public enum InboxDigestGroups {
    public static func groups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        if let groups = item.related_groups, !groups.isEmpty { return groups }
        return legacyGroups(item: item, allItems: allItems)
    }

    public static func legacyGroups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        guard (item.source == "autonomy_maintenance:inbox_digest"
                || item.source.hasPrefix("proactive_autonomy:inbox_digest:")),
              let detail = item.detail,
              detail.contains("Top groups:")
        else { return [] }
        let lines = detail.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Top groups:" }) else {
            return []
        }
        var groups: [InboxRelatedGroup] = []
        for rawLine in lines.dropFirst(start + 1) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.hasPrefix("- ") else { break }
            let entry = String(line.dropFirst(2))
            let parsed = parseLegacyLine(entry)
            let matchingIDs = allItems
                .filter { $0.id != item.id && $0.title == parsed.title }
                .map(\.id)
            groups.append(InboxRelatedGroup(
                id: "digest-\(groups.count)-\(parsed.title)",
                title: parsed.title,
                count: parsed.count,
                item_ids: matchingIDs,
                source: nil
            ))
        }
        return groups
    }

    private static func parseLegacyLine(_ entry: String) -> (title: String, count: Int) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (trimmed, 0)
        }
        let title = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let countText = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return (title, Int(String(countText)) ?? 0)
    }
}

