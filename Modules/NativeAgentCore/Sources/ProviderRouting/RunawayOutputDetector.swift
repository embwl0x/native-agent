import Foundation
import os
import PersistenceCore

/// 2026-09-23 (turn 4976a970): Agent streamed 97k chars for 404s until
/// max_tokens, and the whole reply was replaced by the length notice. This
/// watches reply text as it streams and says when it is looping, so the stream
/// can be stopped early and the prose before the loop kept.
///
/// Fed one delta at a time; only the new characters are scanned and each
/// completed line is hashed once, so the cost per delta is its own length.
///
/// Trips on either:
/// - a dense loop: one line seen `lineRepeatLimit` (6) times within the last
///   `window` (24) counted lines, the window at least `minWindow` (12) lines
///   long and at least half repeats. A short run of intentional copies (four
///   identical code lines, a refrain) stays under it; a real runaway goes on
///   for thousands of lines, so waiting a dozen costs nothing (live false
///   trip 09-23 at 4-of-4).
///   Density is the point (Sol, 09-23): a refrain or a log line that recurs
///   across a long reply is scattered, a loop is not. A line only counts when
///   it is at least 40 characters with at least 20 letters, does not start
///   with `|` (tables share headers), and is not inside a code fence.
/// - `headerLimit` (3) lines that START with "NativeAgent tool result #", the
///   app's own result header. Tool results come from the app, never from the
///   model; a mention of the phrase inside a sentence is not one.
///
/// Text tool lane only (`endsAtToolBoundary`), 2026-09-23 (cutoffs c5b405e6,
/// de3b9224): Opus 5.5 writes bare `<invoke>` blocks with no `<function_calls>`
/// wrapper, so no server stop fires and she wrote the same call until
/// max_tokens (98k chars of `agent_contacts`; `read_file` x12). Complete
/// `<invoke>`/`<tool_use>` blocks are counted as they stream; a block that
/// repeats the one just before it, an action repeated anywhere in the reply
/// (reads may recur), or a 9th block, sets `toolBoundary` just after the
/// last good block's closing tag. The adapter ends the stream there like a
/// server stop sequence, so the complete calls before it dispatch. A block
/// only counts once its closing tag has arrived, and the offending block's
/// closing tag is never passed on, so no half-written call can run.
public struct RunawayOutputDetector: Sendable {
    public static let loopNotice = "I started repeating myself, so I stopped here."
    static let fabricatedHeader = "NativeAgent tool result #"
    static let lineRepeatLimit = 6
    static let headerLimit = 3
    static let window = 24
    static let minWindow = 12
    static let toolBlockLimit = 8

    /// UTF-8 offset where the reply ends at a tool-call boundary.
    public private(set) var toolBoundary: Int?
    private let endsAtToolBoundary: Bool
    private var blockCursor = 0
    private var openBlock: (start: Int, close: String)?
    private var lastSignature: String?
    private var blockSignatures: Set<String> = []
    private var blockCount = 0

    /// Whether a call is a read, safe to run twice in one reply: `(tool name,
    /// the call has no arguments)`. ProviderRouting cannot see the tool
    /// tables, so ChatOrchestration registers its read-only classification;
    /// until then every call counts as an action (fail closed).
    public static func registerReadOnlyCalls(_ isReadOnly: @escaping @Sendable (String, Bool) -> Bool) {
        readOnlyCalls.withLock { $0 = isReadOnly }
    }
    private static let readOnlyCalls = OSAllocatedUnfairLock<(@Sendable (String, Bool) -> Bool)?>(initialState: nil)
    private var lastBlockEnd = 0
    /// Where the text after the last complete call starts being checked.
    private var gapStart = 0
    private var bytes: [UInt8] = []

    /// Everything fed so far.
    public private(set) var text = ""
    /// UTF-8 offset where the loop begins (the prose worth keeping ends here).
    public private(set) var loopStart: Int?
    public private(set) var reason: String?
    private var lineStart = 0
    private var pending = ""
    /// The last `window` counted lines: hash and where each starts.
    private var recent: [(key: Int, start: Int)] = []
    private var inFence = false
    private var headers = 0
    private var firstHeader = 0

    public init(endsAtToolBoundary: Bool = false) {
        self.endsAtToolBoundary = endsAtToolBoundary
    }

    /// Feed one text delta. Returns true once the stream should stop: the reply
    /// is looping, or (when `toolBoundary` is set) it reached a tool-call
    /// boundary. Further input is ignored.
    public mutating func feed(_ delta: String) -> Bool {
        text += delta
        guard loopStart == nil, toolBoundary == nil else { return true }
        var rest = Substring(delta)
        while let nl = rest.unicodeScalars.firstIndex(of: "\n") {
            pending += Substring(rest.unicodeScalars[..<nl])
            let start = lineStart
            lineStart += pending.utf8.count + 1
            if check(pending, at: start) { return true }
            pending = ""
            rest = Substring(rest.unicodeScalars[rest.unicodeScalars.index(after: nl)...])
        }
        pending += rest
        // After the lines, so a fence opened in this same delta is known.
        if endsAtToolBoundary {
            bytes.append(contentsOf: delta.utf8)
            if scanToolBlocks() { return true }
        }
        return false
    }

    private mutating func check(_ line: String, at start: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Fences only guard the header rule (a quoted header in a code block is
        // not a fabricated one); loops are loops inside code too, and density
        // keeps real code safe, so an unclosed fence never blinds the guard.
        if trimmed.hasPrefix("```") { inFence.toggle(); return false }
        if !inFence, trimmed.hasPrefix(Self.fabricatedHeader) {
            if headers == 0 { firstHeader = start }
            headers += 1
            if headers >= Self.headerLimit {
                return trip(at: firstHeader, "\(headers) fabricated tool-result headers")
            }
        }
        guard trimmed.count >= 40, !trimmed.hasPrefix("|"),
              trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count >= 20
        else { return false }
        let key = trimmed.hashValue
        recent.append((key, start))
        if recent.count > Self.window { recent.removeFirst() }
        let copies = recent.filter { $0.key == key }
        guard recent.count >= Self.minWindow, copies.count >= Self.lineRepeatLimit else { return false }
        let repeats = recent.count - Set(recent.map(\.key)).count
        guard repeats * 2 >= recent.count else { return false }
        return trip(at: copies[1].start, "line repeated \(copies.count)x in \(recent.count) lines")
    }

    private mutating func trip(at offset: Int, _ why: String) -> Bool {
        loopStart = offset
        reason = why
        let chars = text.count
        Logger(subsystem: "NativeAgent", category: "Cutoff")
            .error("runaway output: \(why, privacy: .public) chars=\(chars, privacy: .public) keep=\(offset, privacy: .public)B")
        return true
    }

    /// Finds tool blocks completed since the last call; true once the boundary is set.
    private mutating func scanToolBlocks() -> Bool {
        while true {
            if let open = openBlock {
                guard let close = Self.find(open.close, in: bytes, from: blockCursor) else {
                    blockCursor = max(blockCursor, bytes.count - open.close.utf8.count + 1)
                    return false
                }
                let end = close + open.close.utf8.count
                openBlock = nil
                blockCursor = end
                // An example inside a code fence is prose, not a call (Sol).
                if inFence { continue }
                let block = String(decoding: bytes[open.start..<end], as: UTF8.self)
                // Runaway repeats are byte-identical; only the outer edges
                // are trimmed, so "red fox" and "redfox" stay different (Sol).
                // A runaway writes the SAME block back to back, which always
                // ends the reply. A READ made again after another call is a
                // sequence — home between rooms (09-25: 21 of 24 repeat trips
                // were `workspace {}` between rooms, each costing a round) —
                // but an action repeated anywhere in the reply (send, read,
                // send) still ends it: a double send is real harm. The block
                // limit counts every block, so an A-B-A-B loop stops at 8.
                let signature = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if signature == lastSignature {
                    return setToolBoundary("tool block repeated")
                }
                if !blockSignatures.insert(signature).inserted, !Self.isReadOnly(signature) {
                    return setToolBoundary("tool action repeated")
                }
                lastSignature = signature
                blockCount += 1
                if blockCount > Self.toolBlockLimit {
                    return setToolBoundary("tool block \(blockCount) of \(Self.toolBlockLimit)")
                }
                lastBlockEnd = end
                gapStart = end
            } else {
                // After a complete call, a result she writes herself or a long
                // run of prose with no new call ends the reply there, so the
                // calls dispatch — desk-walk 8795fd5b: three bare <invoke>s,
                // then invented "<system>Tool ran without output</system>"
                // lines until the loop guard cut the reply and nothing ran.
                // Short narration between two calls stays (Sol).
                if blockCount > 0, let why = gapAfterCall() {
                    return setToolBoundary(why)
                }
                let opens = [("<invoke", "</invoke>"), ("<tool_use", "</tool_use>")].compactMap { tag, close in
                    Self.find(tag, in: bytes, from: blockCursor, tag: true).map { ($0, tag, close) }
                }
                guard let (start, tag, close) = opens.min(by: { $0.0 < $1.0 }) else {
                    blockCursor = max(blockCursor, bytes.count - "<tool_use".utf8.count)
                    return false
                }
                openBlock = (start, close)
                blockCursor = start + tag.utf8.count
            }
        }
    }

    /// A complete `<invoke name=…>` / `<tool_use name=…>` block is a read by
    /// the registered classification; no classification means an action.
    static func isReadOnly(_ block: String) -> Bool {
        guard let classify = readOnlyCalls.withLock({ $0 }),
              let open = block.range(of: "name=\""),
              let close = block[open.upperBound...].firstIndex(of: "\""),
              let tagEnd = block[close...].firstIndex(of: ">")
        else { return false }
        let name = String(block[open.upperBound..<close])
        let body = block[block.index(after: tagEnd)...]
            .replacingOccurrences(of: "</invoke>", with: "")
            .replacingOccurrences(of: "</tool_use>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return classify(name, body.isEmpty || body == "{}")
    }

    static let fabricatedResultMarkers = ["<system>", "<function_results", "<tool_result", "Tool ran without output",
                                          "NativeAgent tool result"]
    static let gapBudget = 400

    /// Why the text since the last complete call ends the reply, or nil.
    private func gapAfterCall() -> String? {
        let next = ["<invoke", "<tool_use", "<function_calls"].compactMap { Self.find($0, in: bytes, from: gapStart) }.min()
        let gap = String(decoding: bytes[gapStart..<(next ?? bytes.count)], as: UTF8.self)
        if let marker = Self.fabricatedResultMarkers.first(where: gap.contains) { return "invented result after a call (\(marker))" }
        if next == nil, gap.trimmingCharacters(in: .whitespacesAndNewlines).count > Self.gapBudget {
            return "prose after a call past \(Self.gapBudget) characters"
        }
        return nil
    }

    /// First `needle` in `bytes` at or after `from`; with `tag`, only where the
    /// next byte is whitespace or `>` (and known), so `<invoker` is not a block.
    private static func find(_ needle: String, in bytes: [UInt8], from: Int, tag: Bool = false) -> Int? {
        let n = Array(needle.utf8)
        var i = max(0, from)
        while i + n.count <= bytes.count {
            if bytes[i] == n[0], bytes[i..<i + n.count].elementsEqual(n) {
                guard tag else { return i }
                let next = i + n.count
                if next == bytes.count { return nil }
                if [0x20, 0x09, 0x0A, 0x0D, 0x3E].contains(bytes[next]) { return i }
            }
            i += 1
        }
        return nil
    }

    private mutating func setToolBoundary(_ why: String) -> Bool {
        let end = lastBlockEnd, chars = text.count
        toolBoundary = end
        reason = "tool_marker_boundary: \(why)"
        Logger(subsystem: "NativeAgent", category: "Cutoff")
            .error("tool_marker_boundary: \(why, privacy: .public) chars=\(chars, privacy: .public) end=\(end, privacy: .public)B")
        Self.writeDiagnostic(text, reason: reason ?? "tool_marker_boundary")
        return true
    }

    /// After `feed(delta)`: the part of `delta` the reply keeps, which is all
    /// of it unless the tool boundary falls at or before its end.
    public func keptPart(of delta: String) -> String {
        guard let toolBoundary else { return delta }
        let start = text.utf8.count - delta.utf8.count
        return String(decoding: delta.utf8.prefix(max(0, toolBoundary - start)), as: UTF8.self)
    }

    /// Text before the loop (all of it when there is none).
    public var kept: String {
        guard let loopStart else { return text }
        return String(decoding: text.utf8.prefix(loopStart), as: UTF8.self)
    }

    /// The stream ends here: truncated, so no tool marker in it may dispatch.
    public var stopError: LLMError { .outputLengthLimit(partial: text) }

    /// A cut-off reply (max_tokens, a runaway trip, a spent budget) as the
    /// person should see it: the prose before any loop or fabricated tool
    /// result, plus the notice saying why it stopped. Writes the raw text to
    /// `diagnostics/cutoffs/` for the post-mortem.
    public static func cutoffReply(_ raw: String) -> (kept: String, notice: String) {
        var detector = RunawayOutputDetector()
        let looped = detector.feed(raw + "\n")
        var kept = String(detector.kept.dropLast(looped ? 0 : 1))
        // Cut at a fabricated result header only where one starts a line
        // outside a code fence.
        var fenced = false, offset = kept.startIndex
        for line in kept.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { fenced.toggle() }
            else if !fenced, trimmed.hasPrefix(fabricatedHeader) { kept = String(kept[..<offset]); break }
            offset = line.endIndex < kept.endIndex ? kept.index(after: line.endIndex) : kept.endIndex
        }
        writeDiagnostic(raw, reason: detector.reason ?? "cutoff")
        return (kept, looped ? loopNotice : LLMError.outputLengthLimitNotice)
    }

    static func writeDiagnostic(_ raw: String, reason: String) {
        let dir = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("diagnostics/cutoffs", isDirectory: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = (TurnTraceContext.turnId?.filter { $0.isLetter || $0.isNumber || $0 == "-" })
            .flatMap { $0.isEmpty ? nil : $0 } ?? "\(stamp)"
        // A turn can trip more than once (a boundary each round); a later dump
        // must not overwrite the first (turn d48a7f96: 6 trips, 1 file).
        var file = dir.appendingPathComponent("\(name).txt")
        if FileManager.default.fileExists(atPath: file.path) {
            file = dir.appendingPathComponent("\(name)-\(stamp).txt")
        }
        let body = "reason: \(reason)\nchars: \(raw.count)\n\n" + String(decoding: raw.utf8.prefix(200_000), as: UTF8.self)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(body.utf8).write(to: file, options: .atomic)
        Logger(subsystem: "NativeAgent", category: "Cutoff")
            .error("cutoff \(reason, privacy: .public) chars=\(raw.count, privacy: .public) raw=\(file.path, privacy: .public)")
    }
}
