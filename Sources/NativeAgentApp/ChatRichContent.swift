import Foundation
import NativeAgentShared

// Fence splitting (`ChatRichContentParser`) and link sanitizing
// (`ChatLinkPolicy`) live in NativeAgentShared so the iPhone uses the same rules.

/// Prose-only list projection: fenced code never reaches this parser. Keep
/// ordinary prose on its bare Text path and preserve inline Markdown in items.
enum ChatProseListParser {
    typealias Row = ChatRichContentParser.ProseRow
    private static let cache = ChatContentCache<[Row]>()

    static func rows(_ content: String) -> [Row] {
        if let hit = cache.lookup(content) { return hit }
        let rows = ChatRichContentParser.listRows(content)
        cache.insertIfAbsent(rows, for: content)
        return rows
    }
}

// Splitting is cheap but it is NOT free, and `body` re-evaluates on every
// coalesce tick for every visible bubble. Pay once per distinct content
// string, exactly like `ChatMarkdownCache` — same bounds, same eviction.
final class ChatRichContentCache: @unchecked Sendable {
    static let shared = ChatRichContentCache()
    private let cache = ChatContentCache<[ChatContentBlock]>()

    static func blocks(_ content: String) -> [ChatContentBlock] {
        shared._blocks(content)
    }

    private func _blocks(_ content: String) -> [ChatContentBlock] {
        if let hit = cache.lookup(content) {
            return hit
        }

        // Only fenced content is worth an entry: the fast path already returns
        // a single prose block without allocating, so caching it would evict
        // real work to store a wrapper.
        guard content.contains("```") else { return [.prose(ChatRichContentParser.visibleText(content))] }

        RenderAudit.bump("richcontent.split")
        let parsed = ChatRichContentParser.blocks(content)

        cache.insertIfAbsent(parsed, for: content)
        return parsed
    }
}
