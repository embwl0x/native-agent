import Foundation

// 658.13 — assistant rich content that earns its keep.
//
// AUDIT FINDING THAT MOTIVATES THIS FILE. The transcript parses message
// content with `.inlineOnlyPreservingWhitespace`, which is lossless for every
// block construct EXCEPT the fenced code block. Measured, not assumed:
//
//     input:  "Here:\n```swift\nlet x = 1\n```\ndone"
//     output: "Here:\nswift let x = 1 \ndone"
//
// The fence markers are eaten, the language tag is glued onto the first line
// of code, and the interior newlines COLLAPSE TO SPACES. A multi-line snippet
// arrives in the transcript as one mangled line. That is data destruction, not
// missing styling — and it is the only construct where that happens. Lists,
// headings, blockquotes and tables all survive verbatim as plain text today.
//
// Fences are split first so code stays literal. The prose renderer then uses
// ChatProseListParser for bullet and numbered rows with hanging indents.
//
// PURE PROJECTION. Splitting is a total function of the content string. No
// clock, no network, no side effects, no renderer-local state machine.
/// Identity is deliberately NOT derived from the block's contents: a message
/// can repeat the same prose or the same snippet twice, and content-derived ids
/// would collide inside one `ForEach`. The list is recomputed atomically from a
/// single content string, so positional identity is both correct and stable.
enum ChatContentBlock: Equatable {
    case prose(String)
    /// `language` is the fence info string when the model supplied one.
    case code(language: String?, code: String)

    var isProse: Bool {
        if case .prose = self { return true }
        return false
    }
}

enum ChatRichContentParser {
    /// Split `content` into prose and fenced-code blocks.
    ///
    /// Only backtick fences are recognised. An UNTERMINATED fence takes the
    /// remainder of the message as code — a truncated or cancelled turn still
    /// shows its snippet as a snippet rather than as mangled prose.
    static func blocks(_ content: String) -> [ChatContentBlock] {
        // Fast path: the overwhelming majority of messages carry no fence at
        // all, and they must not pay for line splitting or array building.
        guard content.contains("```") else { return [.prose(content)] }

        var blocks: [ChatContentBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var fence: (ticks: Int, language: String?)?

        // `omittingEmptySubsequences: false` keeps blank lines, which carry the
        // paragraph structure the inline parser preserves.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        func flushProse() {
            guard !prose.isEmpty else { return }
            let text = prose.joined(separator: "\n")
            prose.removeAll()
            // A fence sitting between two paragraphs leaves a trailing newline
            // on the prose above it; dropping whitespace-only prose avoids an
            // empty Text view opening a gap in the bubble.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.prose(text))
        }

        func flushCode(language: String?) {
            blocks.append(.code(language: language, code: code.joined(separator: "\n")))
            code.removeAll()
        }

        for line in lines {
            let leading = line.drop { $0 == " " || $0 == "\t" }
            let ticks = leading.prefix { $0 == "`" }.count

            if let open = fence {
                // A closing fence is backticks alone, at least as long as the
                // opener. A line of code that merely CONTAINS backticks (an
                // inline-code example) must not terminate the block.
                let isClose = ticks >= open.ticks
                    && leading.dropFirst(ticks).trimmingCharacters(in: .whitespaces).isEmpty
                if isClose {
                    flushCode(language: open.language)
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }

            if ticks >= 3 {
                let info = leading.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
                // 2026-09-06: CommonMark — a backtick fence's info string may
                // not contain a backtick. Without that rule a one-line
                // ```inline``` example opened a code block that swallowed the
                // rest of the reply.
                if !info.contains("`") {
                    flushProse()
                    fence = (ticks: ticks, language: info.isEmpty ? nil : info)
                    continue
                }
            }

            prose.append(line)
        }

        if let open = fence {
            flushCode(language: open.language)
        } else {
            flushProse()
        }

        return blocks.isEmpty ? [.prose(content)] : blocks
    }
}

/// Prose-only list projection: fenced code never reaches this parser. Keep
/// ordinary prose on its bare Text path and preserve inline Markdown in items.
enum ChatProseListParser {
    struct Row: Equatable {
        var marker: String?
        var indent: Int
        var text: String
    }

    private static let marker = try! NSRegularExpression(
        pattern: #"^( *)([-+*]|[0-9]{1,9}[.)])[ \t]+(.*)$"#
    )
    private static let cache = ChatContentCache<[Row]>()

    static func rows(_ content: String) -> [Row] {
        if let hit = cache.lookup(content) { return hit }
        var rows: [Row] = []
        for line in content.components(separatedBy: "\n") {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let ns = expanded as NSString
            // A thematic break is not an empty bullet sequence.
            let compact = expanded.filter { !$0.isWhitespace }
            let isRule = compact.count >= 3 && Set(compact).count == 1
                && compact.first.map { "-*".contains($0) } == true
            if !isRule, let match = marker.firstMatch(
                in: expanded, range: NSRange(location: 0, length: ns.length)
            ) {
                let token = ns.substring(with: match.range(at: 2))
                rows.append(Row(
                    marker: "-+*".contains(token) ? "•" : token,
                    indent: match.range(at: 1).length,
                    text: ns.substring(with: match.range(at: 3))
                ))
            } else if let last = rows.last, last.marker != nil,
                      !expanded.trimmingCharacters(in: .whitespaces).isEmpty,
                      !isRule,
                      !expanded.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      !expanded.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                // Markdown permits a soft continuation without source indent.
                rows[rows.count - 1].text += "\n" + expanded.trimmingCharacters(in: .whitespaces)
            } else {
                if rows.last?.marker == nil, !rows.isEmpty {
                    rows[rows.count - 1].text += "\n" + line
                } else {
                    rows.append(Row(marker: nil, indent: 0, text: line))
                }
            }
        }
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
        guard content.contains("```") else { return [.prose(content)] }

        RenderAudit.bump("richcontent.split")
        let parsed = ChatRichContentParser.blocks(content)

        cache.insertIfAbsent(parsed, for: content)
        return parsed
    }
}

// Assistant output is untrusted data. `AttributedString(markdown:)` will happily
// build a live `.link` for ANY scheme — measured: `[click](javascript:alert(1))`
// and `[f](file:///etc/passwd)` both survive into a run attribute, and SwiftUI
// `Text` hands a clicked link straight to the system opener. Nothing in the
// transcript validated the scheme before this.
//
// Allowlist, not denylist: an unknown scheme loses its link and renders as
// plain text. The label is never hidden, so the user still sees what was
// written — the link just stops being a live control.
enum ChatLinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Strip the `.link` attribute from every run whose URL is not allowlisted.
    ///
    /// Ranges are collected BEFORE any mutation. `runs` is a view computed over
    /// the string's attribute storage, and clearing an attribute coalesces
    /// adjacent runs. Measured 2026-08-19: mutating mid-iteration happens to
    /// produce the right answer on the current toolchain, so this is DEFENSIVE
    /// — the collect-then-mutate form does not depend on an unspecified
    /// invalidation rule. `sanitizingManyAdjacentBadLinksIsStable` pins the
    /// observable contract (12 adjacent doomed runs, text untouched); it does
    /// NOT fail on the mid-iteration form, and that is expected.
    static func sanitized(_ attributed: AttributedString) -> AttributedString {
        let doomed = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link, !isAllowed(url) else { return nil }
            return run.range
        }
        guard !doomed.isEmpty else { return attributed }
        var copy = attributed
        for range in doomed { copy[range].link = nil }
        return copy
    }
}
