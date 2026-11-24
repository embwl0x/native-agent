import CoreGraphics
import Foundation

// Blueprint: | `ChatPacedReveal.swift` | `ChatStreamPacer`: paragraph reveal, fade and settle shared by Mac/phone |

public enum StreamingParagraphText {
    nonisolated public static let paragraphGap: CGFloat = 10

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

/// The paced reveal's clock. 80 words/s over a ~50-character buffer balances smooth reveal and catch-up; cap at two words per frame.
@MainActor
public final class ChatStreamPacer {
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
            budget = 0
            waitingAtLastTick = false
            return shown
        }
        if target - shown > maxLagBytes {
            shown = Self.boundary(utf8, atOrAfter: target - Self.bufferBytes, limit: target)
        }
        let backlog = target - shown
        if backlog > 0 {
            let multiplier = Self.multiplier(backlog: backlog)
            budget = min(budget + Self.wordsPerSecond * multiplier * gap, multiplier > 1 ? 2 : 1)
            while budget >= 1, shown < target {
                shown = Self.wordEnd(utf8, from: shown, limit: target)
                budget -= 1
            }
        } else {
            budget = 0
        }
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
