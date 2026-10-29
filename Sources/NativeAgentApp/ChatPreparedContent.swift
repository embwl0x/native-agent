import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import StandingBots
import ApprovalInbox
import AppKit
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `ChatPreparedContent.swift` | Settled rich text, list/table preparation and bounded Markdown/content caches |

// Settled inline Markdown is shared with Copy and streaming paragraphs.
final class ChatMarkdownCache: @unchecked Sendable {
    static let shared = ChatMarkdownCache()
    private let cache = ChatContentCache<AttributedString>()

    static func attributed(_ content: String) -> AttributedString? {
        shared._attributed(content)
    }

    private func _attributed(_ content: String) -> AttributedString? {
        if let hit = cache.lookup(content) {
            return hit
        }
        RenderAudit.bump("markdown.parse")
        guard let parsed = ChatRichContentParser.inline(content) else { return nil }
        cache.insertIfAbsent(parsed, for: content)
        return parsed
    }

    /// What Copy puts on the clipboard: the words as the bubble draws them,
    /// so a pasted reply carries no `**` (fenced code stays as written).
    static func plainText(_ content: String) -> String {
        ChatRichContentCache.blocks(content).map { block in
            switch block {
            case .prose(let text): attributed(text).map { String($0.characters) } ?? text
            case .code(_, let code): code
            }
        }.joined(separator: "\n\n")
    }
}

/// Match streaming paragraph gaps with blank-line height paragraphGap − lineSpacing; collapse extra blanks.
enum ChatParagraphGap {
    private static let cache = ChatContentCache<AttributedString>()

    static func applied(_ parsed: AttributedString, content: String, lineSpacing: CGFloat) -> AttributedString {
        guard content.contains("\n\n") else { return parsed }
        let key = "\(lineSpacing)|" + content
        if let hit = cache.lookup(key) { return hit }
        var out = parsed
        // Character offsets of each run of 2+ newlines, last first, so an
        // edit never moves an offset still to be visited.
        var runs: [(start: Int, count: Int)] = []
        var offset = 0
        var runStart = -1
        for character in out.characters {
            if character == "\n" {
                if runStart < 0 { runStart = offset }
            } else {
                if runStart >= 0, offset - runStart >= 2 { runs.append((runStart, offset - runStart)) }
                runStart = -1
            }
            offset += 1
        }
        if runStart >= 0, offset - runStart >= 2 { runs.append((runStart, offset - runStart)) }
        let height = max(0, StreamingParagraphText.paragraphGap - lineSpacing)
        for run in runs.reversed() {
            let blank = out.characters.index(out.startIndex, offsetBy: run.start + 1)
            let afterBlank = out.characters.index(after: blank)
            if run.count > 2 {
                out.removeSubrange(afterBlank..<out.characters.index(out.startIndex, offsetBy: run.start + run.count))
            }
            out[blank..<out.characters.index(after: blank)].lineHeight = .exact(points: height)
        }
        cache.insertIfAbsent(out, for: key)
        return out
    }
}

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

/// A settled prose projection is retained by its leaf, so cache eviction cannot
/// turn a later render into a synchronous parse.
struct ChatPreparedContent: View {
    let text: String
    let lineSpacing: CGFloat
    var seatsRight = false
    var proseOnly = false
    private typealias Row = (marker: String?, indent: Int, text: AttributedString)
    private enum Segment: Sendable {
        case text([[Row]], CGFloat)
        case table(ChatMarkdownTable, [[AttributedString]])
    }
    private struct Source: Equatable {
        let text: String
        let spacing: CGFloat
        let proseOnly: Bool
    }
    private enum Block: Sendable {
        case prose([Segment])
        case code(String?, String)
    }
    @State private var blocks: [Block] = []
    @State private var preparedSource: Source?

    private var source: Source { Source(text: text, spacing: lineSpacing, proseOnly: proseOnly) }

    /// Prepare ordinary replies before mounting to preserve settle geometry; long text prepares off-main.
    init(text: String, lineSpacing: CGFloat, seatsRight: Bool = false, proseOnly: Bool = false) {
        self.text = text
        self.lineSpacing = lineSpacing
        self.seatsRight = seatsRight
        self.proseOnly = proseOnly
        let source = Source(text: text, spacing: lineSpacing, proseOnly: proseOnly)
        if text.utf8.count <= 24_000 {
            _blocks = State(initialValue: Self.prepared(source))
            _preparedSource = State(initialValue: source)
        }
    }

    private static let preparedCache = ChatContentCache<[Block]>()

    nonisolated private static func prepared(_ source: Source) -> [Block] {
        let key = "\(source.proseOnly ? 1 : 0)|\(source.spacing)|\(source.text)"
        if let hit = preparedCache.lookup(key) { return hit }
        let raw = source.proseOnly ? [.prose(source.text)] : ChatRichContentCache.blocks(source.text)
        let blocks = raw.map { block -> Block in
            switch block {
            case .prose(let text): return .prose(segments(text, lineSpacing: source.spacing))
            case .code(let language, let code): return .code(language, code)
            }
        }
        preparedCache.insertIfAbsent(blocks, for: key)
        return blocks
    }

    var body: some View {
        // Keep a mounted task host even while no content has finished preparing.
        VStack(alignment: seatsRight ? .trailing : .leading, spacing: 0) {
            // While a changed text prepares, the last prepared words stay up.
            if preparedSource == source || !blocks.isEmpty {
                if blocks.count == 1, case .prose(let segments) = blocks[0] {
                    proseSegments(segments)
                } else {
                    VStack(alignment: seatsRight ? .trailing : .leading, spacing: NativeAgentSpacing.sm) {
                        ForEach(blocks.indices, id: \.self) { index in
                            switch blocks[index] {
                            case .prose(let segments): proseSegments(segments)
                            case .code(let language, let code): ChatCodeBlockView(language: language, code: code)
                            }
                        }
                    }
                }
            }
        }
        .task(id: source) {
            let source = source
            guard preparedSource != source else { return }
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepared(source) }.value
            guard !Task.isCancelled else { return }
            blocks = prepared
            preparedSource = source
        }
    }

    @ViewBuilder private func proseSegments(_ segments: [Segment]) -> some View {
        if segments.count == 1, case .text(let paragraphs, let width) = segments[0] {
            prose(paragraphs, markerWidth: width)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(segments.indices, id: \.self) { index in
                    switch segments[index] {
                    case .text(let paragraphs, let width): prose(paragraphs, markerWidth: width)
                    case .table(let table, let cells): ChatMarkdownTableView(table: table, cells: cells)
                    }
                }
            }
        }
    }

    nonisolated private static func segments(_ text: String, lineSpacing: CGFloat) -> [Segment] {
        func styled(_ source: String) -> AttributedString {
            ChatParagraphGap.applied(ChatMarkdownCache.attributed(source) ?? AttributedString(source),
                                     content: source, lineSpacing: lineSpacing)
        }
        return ChatMarkdownTableParser.segments(text).map { segment in
            switch segment {
            case .table(let table):
                let columns = table.columnCount
                let cells = ([table.header] + table.rows).map { row in
                    (0..<columns).map { ChatMarkdownCache.attributed(table.cell(row, $0)) ?? AttributedString(table.cell(row, $0)) }
                }
                return .table(table, cells)
            case .text(let text):
                let rows = ChatProseListParser.rows(text)
                let width = CGFloat(rows.compactMap(\.marker).map(\.count).max() ?? 1) * 10
                let paragraphs = StreamingParagraphText.paragraphs(text[...])
                var blocks: [String] = []
                if paragraphs.count > 1, rows.contains(where: { $0.marker != nil }) {
                    var run: [Substring] = []
                    for paragraph in paragraphs {
                        if ChatProseListParser.rows(String(paragraph)).contains(where: { $0.marker != nil }) {
                            if !run.isEmpty { blocks.append(run.joined(separator: "\n\n")) }
                            run = []
                            blocks.append(String(paragraph))
                        } else { run.append(paragraph) }
                    }
                    if !run.isEmpty { blocks.append(run.joined(separator: "\n\n")) }
                } else { blocks = [text.trimmingCharacters(in: .newlines)] }
                return .text(blocks.map { block in
                    let rows = ChatProseListParser.rows(block)
                    if rows.contains(where: { $0.marker != nil }) {
                        return rows.filter { $0.marker != nil || !$0.text.isEmpty }
                            .map { ($0.marker, $0.indent, styled($0.text)) }
                    }
                    return [(nil, 0, styled(block))]
                }, width)
            }
        }
    }

    @ViewBuilder
    private func prose(_ paragraphs: [[Row]], markerWidth: CGFloat) -> some View {
        if paragraphs.count == 1 {
            paragraph(paragraphs[0], markerWidth: markerWidth)
        } else {
            VStack(alignment: .leading, spacing: lineSpacing + StreamingParagraphText.paragraphGap) {
                ForEach(paragraphs.indices, id: \.self) { paragraph(paragraphs[$0], markerWidth: markerWidth) }
            }
        }
    }

    @ViewBuilder
    private func paragraph(_ rows: [Row], markerWidth: CGFloat) -> some View {
        if rows.count == 1, rows[0].marker == nil {
            Text(rows[0].text)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    if let marker = row.marker {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(marker).monospacedDigit()
                                .frame(width: max(20, markerWidth), alignment: .trailing).fixedSize()
                            Text(row.text).multilineTextAlignment(.leading)
                        }
                        .padding(.leading, CGFloat(row.indent) * 7)
                    } else { Text(row.text) }
                }
            }
        }
    }
}

// Cache fenced-content splitting once per distinct string within the shared bounds.
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
