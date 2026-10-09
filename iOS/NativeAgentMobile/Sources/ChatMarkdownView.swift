import SwiftUI
import NativeAgentShared

// iPhone markdown for settled replies (fluid-glass plan, 2026-10-04).
//
// Fences split first through the Mac's shared `ChatRichContentParser`, so code
// stays literal. Prose is read line by line: headings and list rows get their
// own shape, everything else groups into paragraphs, and each piece parses
// with `.inlineOnlyPreservingWhitespace` (bold, italic, links, inline code).
// Links pass the shared `ChatLinkPolicy` allowlist.
//
// Streaming text never comes here; a reply parses once when it settles. Its
// paragraphs do take `inline`, so the live reply is never raw markdown.

enum ChatMarkdownBlock {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case listItem(marker: String, indent: Int, text: AttributedString)
    case code(language: String?, code: String)
}

@MainActor
enum MobileChatMarkdown {
    private struct Key: Hashable {
        let id: UUID
        let contentHash: Int
    }

    private static var entries: [Key: [ChatMarkdownBlock]] = [:]

    static func blocks(id: UUID, content: String) -> [ChatMarkdownBlock] {
        let key = Key(id: id, contentHash: content.hashValue)
        if let hit = entries[key] { return hit }
        if entries.count >= 300 { entries.removeAll(keepingCapacity: true) }
        let parsed = parse(content)
        entries[key] = parsed
        return parsed
    }

    static func parse(_ content: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        for block in ChatRichContentParser.blocks(content) {
            switch block {
            case .code(let language, let code):
                blocks.append(.code(language: language, code: code))
            case .prose(let prose):
                blocks.append(contentsOf: parseProse(prose))
            }
        }
        return blocks
    }

    private static func parseProse(_ prose: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [Substring] = []

        func flush() {
            let text = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.paragraph(inline(text)))
        }

        for row in ChatRichContentParser.listRows(prose) {
            if let marker = row.marker {
                flush()
                blocks.append(.listItem(marker: marker, indent: row.indent / 2, text: inline(row.text)))
            } else {
                for line in row.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.drop { $0 == " " || $0 == "\t" }
                    if trimmed.isEmpty {
                        flush()
                    } else if let heading = heading(trimmed) {
                        flush()
                        blocks.append(.heading(level: heading.level, text: inline(heading.text)))
                    } else {
                        paragraph.append(line)
                    }
                }
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ line: Substring) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Also the live reply's parse, so it streams in the settled look.
    nonisolated static func inline(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        // The reply's text colour wins over link tint, so underline live
        // links to keep them visible (teal stays for "needs you").
        var out = ChatLinkPolicy.sanitized(parsed)
        let links = out.runs.compactMap { $0.link == nil ? nil : $0.range }
        for range in links { out[range].underlineStyle = Text.LineStyle(pattern: .solid) }
        return out
    }
}

struct ChatMarkdownView: View {
    let blocks: [ChatMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .paragraph(let text):
                    prose(Text(text))
                case .heading(let level, let text):
                    prose(Text(text).font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                case .listItem(let marker, let indent, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .foregroundStyle(AlivePalette.secondary)
                            .monospacedDigit()
                        prose(Text(text))
                    }
                    .padding(.leading, CGFloat(min(indent, 4)) * 16)
                case .code(let language, let code):
                    codeBlock(language: language, code: code)
                }
            }
        }
        .font(.body)
        .foregroundStyle(AlivePalette.text)
        .textSelection(.enabled)
    }

    private func prose(_ text: Text) -> some View {
        text
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(AlivePalette.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
    }
}
