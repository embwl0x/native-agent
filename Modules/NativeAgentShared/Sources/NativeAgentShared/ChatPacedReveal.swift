import SwiftUI

// Shared by the Mac transcript and the iPhone chat (2026-10-04): the live
// reply's paced reveal, its edge fade and the settle crossfade, so both
// platforms stream with one feel.

/// The streaming reply, one `Text` per paragraph.
///
/// User, 2026-09-23: one `Text` holding the whole growing reply was re-typeset
/// from its first word on every published chunk (~1 ms at the start of a
/// 1,500-word reply, ~70 ms at the end), so a long reply pinned the main
/// thread at 14 chunks a second and starved its own stream. Split at blank
/// lines, finished paragraphs are unchanged `Text`s that keep their cached
/// layout and only the last one re-lays out (~2 ms at the end).
///
/// Wave 3 (Grok's rhythm): a paragraph break is the line gap plus
/// `paragraphGap`, not a whole blank line; the Mac's settled reply splits at
/// the same breaks (`paragraphs`) with the same gap, so the settle does not
/// move a line. Its inline parse comes through here too (below).
///
/// Fluid glass A1: the last paragraph carries the paced reveal's edge fade.
/// Finished paragraphs get a constant renderer, so a frame redraws one `Text`.
///
/// User, 2026-10-07: her replies streamed with literal `**` and snapped to
/// bold when they settled (half her replies carry bold). Each paragraph now
/// goes through `inline`, the platform's own settled-reply inline parse, so
/// the words look the same before and after. A finished paragraph is an
/// equatable leaf that parses once and is skipped after; only the last one
/// parses per frame. A marker she has opened but not closed yet is closed at
/// the edge (or hidden, with nothing after it). Paragraphs in or around a
/// code fence stay raw, as the settled reply keeps code literal.
@available(macOS 15, iOS 18, *)
public struct StreamingParagraphText: View {
    let text: Substring
    /// The newest revealed runs, still fading in. Empty when not paced.
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

    /// Between paragraphs, on top of the line spacing: 10pt, Grok's gap.
    public static let paragraphGap: CGFloat = 10

    public var body: some View {
        let paragraphs = Self.paragraphs(text)
        let last = paragraphs.count - 1
        let styled = Self.styledParagraphs(paragraphs, enabled: inline != nil)
        VStack(alignment: .leading, spacing: lineSpacing + Self.paragraphGap) {
            // Positional ids: paragraphs only append while a reply streams,
            // so a finished one keeps its id and its layout.
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

    /// Which paragraphs take markdown: none inside, opening or closing a
    /// code fence.
    static func styledParagraphs(_ paragraphs: [Substring], enabled: Bool) -> [Bool] {
        guard enabled else { return Array(repeating: false, count: paragraphs.count) }
        var inFence = false
        return paragraphs.map { paragraph in
            let fences = paragraph.contains("```") ? paragraph.components(separatedBy: "```").count - 1 : 0
            defer { if fences % 2 == 1 { inFence.toggle() } }
            return !inFence && fences == 0
        }
    }

    /// One paragraph, its still-fading runs tagged with when they appeared.
    /// Fade offsets are UTF-8 offsets into the whole reply.
    static func paragraph(
        _ text: Substring,
        fades: [ChatStreamPacer.Fade],
        inline: ChatInlineMarkdown? = nil,
        atEdge: Bool = false
    ) -> Text {
        if let inline, let styled = inline.parse(atEdge ? closingEdge(text) : String(text)) {
            return paragraph(text, styled: styled, fades: fades)
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

    /// The styled paragraph, split where each fade starts. The parse drops
    /// markers, so a fade's source offset maps to the first drawn character
    /// that came from at or after it (drawn characters are a subsequence of
    /// the source).
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

    /// The live edge with a marker she has opened but not yet closed closed,
    /// so `**bold` streams bold; with nothing after it yet, the marker is
    /// hidden. Only live markers count: a backslash-escaped `*` and anything
    /// inside a closed code span are literal, and inside a code span still
    /// open at the edge `**` is literal too.
    static func closingEdge(_ text: Substring) -> String {
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
            // The closing marker's first half already arrived.
            if tail.hasSuffix("*"), !tail.hasSuffix("\\*") { tail = tail.dropLast() }
            // A closing `**` after a space does not close.
            let words = tail[..<(tail.lastIndex { !$0.isWhitespace }.map(tail.index(after:)) ?? tail.startIndex)]
            edge = words.isEmpty ? String(edge[..<open.lowerBound]) : String(edge[..<words.endIndex]) + "**"
        } else if edge.hasSuffix("*"), edge.dropLast().last?.isWhitespace ?? true {
            // A marker's first half, alone at the edge.
            edge.removeLast()
        }
        return edge
    }

    /// Splits at each blank line, dropping the break. A break still at the
    /// stream's edge adds nothing until the next paragraph's first word.
    public static func paragraphs(_ text: Substring) -> [Substring] {
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

/// A paragraph the stream has moved past. Its text no longer changes, so it
/// parses once and its body is skipped on every later frame.
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

/// The platform's settled-reply inline markdown parse, handed to the live
/// reply so both draw the same words. Nil from `parse` streams raw text.
public struct ChatInlineMarkdown: Sendable {
    let parse: @Sendable (String) -> AttributedString?

    public init(_ parse: @escaping @Sendable (String) -> AttributedString?) {
        self.parse = parse
    }
}

/// The live reply, revealed at a steady pace instead of in chunks
/// (fluid glass A1).
///
/// The Mac stream publishes every 70 ms, the iPhone's every ~1 s; this leaf
/// turns either into about 80 words a second, a word or two a frame. Only it
/// runs per frame: the bubble re-renders per publish as before, the list and
/// the chat view never. The display link is a `TimelineView(.animation)` that
/// pauses once the text has caught up and the last words have faded in.
///
/// Agent: no artificial suspense. A mount shows what is already there (a
/// swapped row, a reopened chat, a session switch); a hidden window and a
/// backlog past `maxLagBytes` jump; and the settled reply replaces this view
/// the moment the turn settles, so nothing dribbles out after the answer is
/// done. Reduce Motion shows the text as published, with no fade.
@available(macOS 15, iOS 18, *)
public struct PacedStreamingText: View {
    let text: String
    /// Further behind than this, jump. The iPhone's ~1 s batches run up to
    /// ~1,200 bytes, so it passes a larger lag than the Mac's 70 ms publishes.
    var maxLagBytes: Int
    var inline: ChatInlineMarkdown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pacer = ChatStreamPacer()
    /// The text length the pacer last came to rest at; paused only while
    /// that is still the whole text, so a jump to the end also pauses.
    @State private var restedAt = -1

    public init(text: String, maxLagBytes: Int = ChatStreamPacer.maxLagBytes, inline: ChatInlineMarkdown? = nil) {
        self.text = text
        self.maxLagBytes = maxLagBytes
        self.inline = inline
    }

    public var body: some View {
        if reduceMotion {
            visible(text[...])
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: restedAt == text.utf8.count)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let shown = pacer.advance(text, now: now, maxLagBytes: maxLagBytes)
                let restMark = pacer.isResting(text) ? text.utf8.count : -1
                visible(text[..<text.utf8.index(text.utf8.startIndex, offsetBy: shown)], now: now)
                    .onChange(of: restMark, initial: true) { _, mark in restedAt = mark }
            }
        }
    }

    /// Nothing visible yet keeps the one blank line the empty bubble drew.
    @ViewBuilder
    private func visible(_ revealed: Substring, now: TimeInterval = 0) -> some View {
        if revealed.contains(where: { !$0.isWhitespace }) {
            StreamingParagraphText(text: revealed, fades: reduceMotion ? [] : pacer.fades, now: now, inline: inline)
        } else {
            StreamingParagraphText(text: " ")
        }
    }
}

/// The paced reveal's clock. Lives in `PacedStreamingText`'s state, is read
/// and advanced only inside its timeline, and is never observed.
///
/// Muse's numbers: 80 words a second over a buffer of about 50 characters,
/// 0.9× while under 37.5 are buffered, 1× to 75, then ramping to 1.75× at
/// 150 and capped at 2×. At most one word a frame, two while catching up.
@available(macOS 15, iOS 18, *)
@MainActor
public final class ChatStreamPacer {
    public struct Fade: Equatable {
        /// UTF-8 offset where this frame's reveal starts.
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

    /// Caught up, and the last words have finished fading in.
    func isResting(_ text: String) -> Bool {
        shown == text.utf8.count && fades.isEmpty
    }

    /// Reveals what is due at `now` and returns the revealed UTF-8 length,
    /// always on a scalar boundary.
    func advance(_ text: String, now: TimeInterval, maxLagBytes: Int) -> Int {
        let utf8 = text.utf8
        let target = utf8.count
        let gap = max(0, now - (lastTick ?? now))
        lastTick = now
        // First look, a reset (a retried turn starts over), or a window that
        // was hidden while text waited: show it all, never replay it.
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
        // A same-instant re-read (a publish while paused) is not a frame; the
        // first real frame after a rest must pace, not count as hidden.
        if gap > 0 { waitingAtLastTick = shown < target }
        return shown
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }

    /// The end of the next word, taking the spaces before it along.
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

/// When a run of the live reply appeared, for its fade-in.
@available(macOS 15, iOS 18, *)
struct ChatEdgeFade: TextAttribute {
    /// ChatGPT's number: only the new edge fades, over about 150 ms, ease-out.
    static let duration = 0.15
    let revealedAt: TimeInterval
}

/// Draws the newest words of the live reply fading in and everything else as
/// it is. Only opacity changes per frame: a redraw, never a re-layout.
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

/// Overlays its children and takes the size of the one tagged `current`.
///
/// Fluid glass A1: a phase swapped in place (the streamed reply becoming its
/// settled rendering, the live tool box becoming its row) crossfades here. In
/// a VStack the outgoing phase would stack on the incoming one for the whole
/// fade; here it only draws, and the size goes to the incoming phase's.
public struct ChatCrossfadeStack: Layout {
    public var current: Int

    public init(current: Int) {
        self.current = current
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let shown = subviews.last { $0[ChatCrossfadePhase.self] == current } ?? subviews.last
        return shown?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The parent's width, not the incoming phase's: an outgoing reply
        // keeps wrapping where it did while it fades.
        let width = ProposedViewSize(width: proposal.width ?? bounds.width, height: nil)
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: width)
        }
    }
}

public struct ChatCrossfadePhase: LayoutValueKey {
    public static let defaultValue = -1
}
