import SwiftUI

// Blueprint: | `ChatPacedReveal.swift` | `ChatStreamPacer`: paragraph reveal, fade and settle shared by Mac/phone |


/// One Text per paragraph, with the same gap and inline styling as settled replies.
@available(macOS 15, iOS 18, *)
public struct StreamingParagraphText: View {
    let text: Substring
    var fades: [ChatStreamPacer.Fade] = []
    var now: TimeInterval = 0
    /// The settled reply's inline markdown parse; nil streams raw text.
    var inline: ChatInlineMarkdown?
    @Environment(\.lineSpacing) private var lineSpacing

    public init(
        text: Substring,
        fades: [ChatStreamPacer.Fade] = [],
        now: TimeInterval = 0,
        inline: ChatInlineMarkdown? = nil
    ) {
        self.text = text
        self.fades = fades
        self.now = now
        self.inline = inline
    }

    nonisolated public static let paragraphGap: CGFloat = 10

    public var body: some View {
        let paragraphs = Self.paragraphs(text)
        let last = paragraphs.count - 1
        let styled = Self.styledParagraphs(paragraphs, enabled: inline != nil)
        VStack(alignment: .leading, spacing: lineSpacing + Self.paragraphGap) {
            // Positional ids: paragraphs only append while a reply streams, so a finished one keeps its id and its layout.
            ForEach(paragraphs.indices, id: \.self) { index in
                let parse = styled[index] ? inline : nil
                if index == last {
                    Self.paragraph(paragraphs[index], fades: fades, inline: parse, atEdge: true)
                        .textRenderer(ChatEdgeFadeRenderer(now: now))
                } else {
                    FinishedParagraph(text: paragraphs[index], inline: parse).equatable()
                }
            }
        }
    }

    /// Code fences must remain literal while prose receives markdown styling.
    static func styledParagraphs(_ paragraphs: [Substring], enabled: Bool) -> [Bool] {
        guard enabled else { return Array(repeating: false, count: paragraphs.count) }
        var inFence = false
        return paragraphs.map { paragraph in
            let fences = paragraph.contains("```") ? paragraph.components(separatedBy: "```").count - 1 : 0
            defer { if fences % 2 == 1 { inFence.toggle() } }
            return !inFence && fences == 0
        }
    }

    /// Fade offsets address UTF-8 bytes in the whole reply.
    static func paragraph(
        _ text: Substring,
        fades: [ChatStreamPacer.Fade],
        inline: ChatInlineMarkdown? = nil,
        atEdge: Bool = false
    ) -> Text {
        if let inline {
            let outcome = inline.parse(atEdge ? closingEdge(text) : String(text))
            switch outcome {
            case .parsed(let styled):
                return paragraph(text, styled: styled, fades: fades)
            case .failed(_, let reason):
                // The notice is not a subsequence of the source, so source fade offsets must not be applied to it. Show the actual revealed source,
                // without the live edge's closing markers.
                return Text(ChatRichContentParser.InlineOutcome.failed(
                    source: String(text), reason: reason).presentation)
            }
        }
        guard let first = fades.first else { return Text(text) }
        let utf8 = text.base.utf8
        let start = utf8.distance(from: utf8.startIndex, to: text.startIndex)
        let end = start + text.utf8.count
        func slice(_ from: Int, _ to: Int) -> Substring {
            text.base[utf8.index(utf8.startIndex, offsetBy: from)..<utf8.index(utf8.startIndex, offsetBy: to)]
        }
        var composed = Text(slice(start, min(max(first.start, start), end)))
        for index in fades.indices {
            let from = max(fades[index].start, start)
            let to = index + 1 < fades.count ? min(fades[index + 1].start, end) : end
            guard to > from else { continue }
            let run = Text(slice(from, to)).customAttribute(ChatEdgeFade(revealedAt: fades[index].at))
            composed = Text("\(composed)\(run)")
        }
        return composed
    }

    /// The styled paragraph, split where each fade starts. The parse drops markers, so a fade's source offset maps to the first drawn character that
    /// came from at or after it (drawn characters are a subsequence of the source).
    static func paragraph(_ text: Substring, styled: AttributedString, fades: [ChatStreamPacer.Fade]) -> Text {
        guard !fades.isEmpty else { return Text(styled) }
        let start = text.base.utf8.distance(from: text.base.utf8.startIndex, to: text.startIndex)
        let starts = fades.map { $0.start - start }
        var cuts: [AttributedString.Index] = []
        var source = text.startIndex
        var offset = 0
        let characters = styled.characters
        for index in characters.indices where cuts.count < starts.count {
            let character = characters[index]
            while source < text.endIndex, text[source] != character {
                offset += text[source].utf8.count
                source = text.index(after: source)
            }
            while cuts.count < starts.count, starts[cuts.count] <= offset { cuts.append(index) }
            if source < text.endIndex {
                offset += text[source].utf8.count
                source = text.index(after: source)
            }
        }
        while cuts.count < starts.count { cuts.append(styled.endIndex) }
        var composed = Text(AttributedString(styled[styled.startIndex..<cuts[0]]))
        for index in cuts.indices {
            let to = index + 1 < cuts.count ? cuts[index + 1] : styled.endIndex
            guard to > cuts[index] else { continue }
            let run = Text(AttributedString(styled[cuts[index]..<to]))
                .customAttribute(ChatEdgeFade(revealedAt: fades[index].at))
            composed = Text("\(composed)\(run)")
        }
        return composed
    }

    /// Close live Markdown markers while preserving escapes and literal code.
    nonisolated public static func closingEdge(_ text: Substring) -> String {
        var edge = String(text)
        var bold: [Range<String.Index>] = []
        var index = edge.startIndex
        while index < edge.endIndex {
            let character = edge[index]
            if character == "\\" {
                index = edge.index(after: index)
                if index < edge.endIndex { index = edge.index(after: index) }
            } else if character == "`" {
                let ticks = edge[index...].prefix { $0 == "`" }
                if let close = edge[ticks.endIndex...].range(of: String(ticks)) {
                    index = close.upperBound
                    continue
                }
                if ticks.endIndex == edge.endIndex {
                    edge.removeSubrange(index...)
                } else {
                    edge += ticks
                }
                return edge
            } else if character == "*", edge[edge.index(after: index)...].first == "*" {
                let next = edge.index(index, offsetBy: 2)
                bold.append(index..<next)
                index = next
            } else {
                index = edge.index(after: index)
            }
        }
        if bold.count % 2 == 1, let open = bold.last {
            var tail = edge[open.upperBound...]
            if tail.hasSuffix("*"), !tail.hasSuffix("\\*") { tail = tail.dropLast() }
            // A closing `**` after a space does not close.
            let words = tail[..<(tail.lastIndex { !$0.isWhitespace }.map(tail.index(after:)) ?? tail.startIndex)]
            edge = words.isEmpty ? String(edge[..<open.lowerBound]) : String(edge[..<words.endIndex]) + "**"
        } else if edge.hasSuffix("*"), edge.dropLast().last?.isWhitespace ?? true {
            edge.removeLast()
        }
        return edge
    }

    /// Splits at each blank line, dropping the break. A break still at the stream's edge adds nothing until the next paragraph's first word.
    nonisolated public static func paragraphs(_ text: Substring) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        while let range = text[start...].range(of: "\n\n") {
            if range.lowerBound > start { out.append(text[start..<range.lowerBound]) }
            start = range.upperBound
            while start < text.endIndex, text[start] == "\n" { start = text.index(after: start) }
        }
        if start < text.endIndex || out.isEmpty { out.append(text[start...]) }
        return out
    }
}

/// A paragraph the stream has moved past. Its text no longer changes, so it parses once and its body is skipped on every later frame.
@available(macOS 15, iOS 18, *)
private struct FinishedParagraph: View, Equatable {
    let text: Substring
    let inline: ChatInlineMarkdown?

    var body: some View {
        StreamingParagraphText.paragraph(text, fades: [], inline: inline)
            .textRenderer(ChatEdgeFadeRenderer(now: 0))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && (lhs.inline == nil) == (rhs.inline == nil)
    }
}

/// The platform's settled-reply inline markdown parse, handed to the live reply so both draw the same words and expose the same parse failures.
public struct ChatInlineMarkdown: Sendable {
    let parse: @Sendable (String) -> ChatRichContentParser.InlineOutcome

    public init(_ parse: @escaping @Sendable (String) -> ChatRichContentParser.InlineOutcome) {
        self.parse = parse
    }
}

/// The paced reveal's clock. 80 words/s over a ~50-character buffer balances smooth reveal and catch-up; cap at two words per frame.
@available(macOS 15, iOS 18, *)
@MainActor
public final class ChatStreamPacer {
    public struct Fade: Equatable {
        let start: Int
        let at: TimeInterval
    }

    static let wordsPerSecond = 80.0
    /// Further behind than this, jump to `bufferBytes` short of the end.
    nonisolated public static let maxLagBytes = 600
    static let bufferBytes = 50
    /// A run with no spaces (CJK, a URL) still flows, a few bytes a step.
    static let maxWordBytes = 12
    /// Frames this far apart while text was waiting: the window was hidden.
    static let hiddenGap = 0.25

    /// Revealed UTF-8 length; -1 until the first look.
    private(set) var shown = -1
    private(set) var fades: [Fade] = []
    private var budget = 0.0
    private var lastTick: TimeInterval?
    private var waitingAtLastTick = false

    public init() {}

    static func multiplier(backlog: Int) -> Double {
        let buffered = Double(backlog)
        if buffered < 37.5 { return 0.9 }
        if buffered <= 75 { return 1 }
        return min(2, 1 + 0.75 * (buffered - 75) / 75)
    }

    /// Reveals what is due at `now` and returns the revealed UTF-8 length, always on a scalar boundary.
    public func advance(_ text: String, now: TimeInterval, maxLagBytes: Int) -> Int {
        let utf8 = text.utf8
        let target = utf8.count
        let gap = max(0, now - (lastTick ?? now))
        lastTick = now
        // First look, a reset (a retried turn starts over), or a window that was hidden while text waited: show it all, never replay it.
        guard shown >= 0, shown <= target, !(waitingAtLastTick && gap > Self.hiddenGap) else {
            shown = target
            fades.removeAll()
            budget = 0
            waitingAtLastTick = false
            return shown
        }
        if target - shown > maxLagBytes {
            shown = Self.boundary(utf8, atOrAfter: target - Self.bufferBytes, limit: target)
            fades.removeAll()
        }
        let backlog = target - shown
        if backlog > 0 {
            let multiplier = Self.multiplier(backlog: backlog)
            budget = min(budget + Self.wordsPerSecond * multiplier * gap, multiplier > 1 ? 2 : 1)
            let from = shown
            while budget >= 1, shown < target {
                shown = Self.wordEnd(utf8, from: shown, limit: target)
                budget -= 1
            }
            if shown > from { fades.append(Fade(start: from, at: now)) }
        } else {
            budget = 0
        }
        fades.removeAll { now - $0.at >= ChatEdgeFade.duration }
        // A same-instant re-read (a publish while paused) is not a frame; the first real frame after a rest must pace, not count as hidden.
        if gap > 0 { waitingAtLastTick = shown < target }
        return shown
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }

    static func wordEnd(_ utf8: String.UTF8View, from: Int, limit: Int) -> Int {
        var offset = from
        var index = utf8.index(utf8.startIndex, offsetBy: from)
        while offset < limit, isSpace(utf8[index]) {
            offset += 1
            index = utf8.index(after: index)
        }
        let wordStart = offset
        while offset < limit, !isSpace(utf8[index]) {
            if offset - wordStart >= maxWordBytes, !UTF8.isContinuation(utf8[index]) { break }
            offset += 1
            index = utf8.index(after: index)
        }
        return offset
    }

    /// The first space at or after `offset`, so a jump lands between words.
    static func boundary(_ utf8: String.UTF8View, atOrAfter offset: Int, limit: Int) -> Int {
        var offset = max(0, offset)
        var index = utf8.index(utf8.startIndex, offsetBy: offset)
        while offset < limit, !isSpace(utf8[index]) {
            offset += 1
            index = utf8.index(after: index)
        }
        return offset
    }
}

@available(macOS 15, iOS 18, *)
struct ChatEdgeFade: TextAttribute {
    /// Only the new edge fades, over about 150 ms, ease-out.
    static let duration = 0.15
    let revealedAt: TimeInterval
}

/// Draws the newest words of the live reply fading in and everything else as it is. Only opacity changes per frame: a redraw, never a re-layout.
@available(macOS 15, iOS 18, *)
struct ChatEdgeFadeRenderer: TextRenderer, Equatable {
    var now: TimeInterval

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let fade = run[ChatEdgeFade.self] else {
                    ctx.draw(run)
                    continue
                }
                let progress = min(1, max(0, (now - fade.revealedAt) / ChatEdgeFade.duration))
                var faded = ctx
                faded.opacity = 1 - (1 - progress) * (1 - progress)
                faded.draw(run)
            }
        }
    }
}
