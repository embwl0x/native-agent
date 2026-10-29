import Foundation
// Blueprint: | `ChatRichContentParser.swift` | `ChatRichContentParser`: shared fence, list and sanitized inline grammar; `ChatContentCache`: bounded content-keyed FIFO storage |

// Split fences before inline parsing so code remains literal on both platforms.
/// Identity is deliberately NOT derived from the block's contents: a message
/// can repeat the same prose or the same snippet twice, and content-derived ids
/// would collide inside one `ForEach`. The list is recomputed atomically from a
/// single content string, so positional identity is both correct and stable.
public enum ChatContentBlock: Equatable, Sendable {
    case prose(String)
    /// `language` is the fence info string when the model supplied one.
    case code(language: String?, code: String)
}

public enum ChatRichContentParser {
    /// Uncached for growing streaming text; settled callers retain by content.
    public static func inline(_ content: String) -> AttributedString? {
        guard let raw = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        return ChatLinkPolicy.sanitized(raw)
    }

    public struct ProseRow: Equatable, Sendable {
        public var marker: String?
        public var indent: Int
        public var text: String
    }

    private static let listMarker = try! NSRegularExpression(
        pattern: #"^( *)([-+*]|[0-9]{1,9}[.)])[ \t]+(.*)$"#
    )

    /// The same list grammar and soft continuations on every chat surface.
    public static func listRows(_ content: String) -> [ProseRow] {
        var rows: [ProseRow] = []
        for line in content.components(separatedBy: "\n") {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let ns = expanded as NSString
            let compact = expanded.filter { !$0.isWhitespace }
            let isRule = compact.count >= 3 && Set(compact).count == 1
                && compact.first.map { "-*".contains($0) } == true
            if !isRule, let match = listMarker.firstMatch(
                in: expanded, range: NSRange(location: 0, length: ns.length)
            ) {
                let token = ns.substring(with: match.range(at: 2))
                rows.append(ProseRow(marker: "-+*".contains(token) ? "•" : token,
                    indent: match.range(at: 1).length, text: ns.substring(with: match.range(at: 3))))
            } else if let last = rows.last, last.marker != nil,
                      !expanded.trimmingCharacters(in: .whitespaces).isEmpty,
                      !isRule,
                      !expanded.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      !expanded.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                rows[rows.count - 1].text += "\n" + expanded.trimmingCharacters(in: .whitespaces)
            } else if rows.last?.marker == nil, !rows.isEmpty {
                rows[rows.count - 1].text += "\n" + line
            } else {
                rows.append(ProseRow(marker: nil, indent: 0, text: line))
            }
        }
        return rows
    }

    private static let providerCitation = try! NSRegularExpression(
        pattern: "\u{E200}cite[^\u{E201}]*[\u{E201}]|\u{E200}(?:c(?:i(?:t(?:e[^\u{E201}]*)?)?)?)?$"
    )

    /// Provider reference IDs have no visible source URL. Hide whole tokens,
    /// including an unfinished streamed token, before Markdown sees them.
    public static func visibleText(_ content: String) -> String {
        guard content.contains("\u{E200}") else { return content }
        return providerCitation.stringByReplacingMatches(
            in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
    }

    /// Split `content` into prose and fenced-code blocks.
    ///
    /// Only backtick fences are recognised. An UNTERMINATED fence takes the
    /// remainder of the message as code — a truncated or cancelled turn still
    /// shows its snippet as a snippet rather than as mangled prose.
    public static func blocks(_ content: String) -> [ChatContentBlock] {
        let content = visibleText(content)
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
                // A backtick fence's info string cannot contain a backtick.
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

// Untrusted links outside the allowlist lose their link attribute, retaining text.
public enum ChatLinkPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Strip the `.link` attribute from every run whose URL is not allowlisted.
    /// Collect ranges before mutation, since clearing links coalesces runs.
    public static func sanitized(_ attributed: AttributedString) -> AttributedString {
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

/// Process-local FIFO storage; callers own parsing and admission outside the lock.
public final class ChatContentCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Value] = [:]
    private var order: [String] = []
    private var totalChars = 0
    private let capacity = 300
    private let charBudget = 4_000_000

    public init() {}

    public func lookup(_ content: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return cache[content]
    }

    public func insertIfAbsent(_ parsed: Value, for content: String) {
        lock.lock()
        defer { lock.unlock() }
        if cache[content] == nil {
            cache[content] = parsed
            order.append(content)
            totalChars += content.count
            while order.count > capacity || (totalChars > charBudget && order.count > 1) {
                let evicted = order.removeFirst()
                totalChars -= evicted.count
                cache.removeValue(forKey: evicted)
            }
        }
    }
}
