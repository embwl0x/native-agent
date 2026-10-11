import Foundation
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace

/// Correctness boundaries retain complete calls before a repeated action or
/// fabricated result. Text after a boundary is withheld; the turn continues
/// with the retained calls and the boundary reason.
public struct RunawayOutputDetector: Sendable {
    static let fabricatedHeader = "NativeAgent tool result #"

    /// UTF-8 offset where the reply ends at a tool-call boundary.
    public private(set) var toolBoundary: Int?
    public private(set) var toolBoundaryReason: LLMToolBoundaryReason?
    private let endsAtToolBoundary: Bool
    private var blockCursor = 0
    private var openBlock: (start: Int, close: String)?
    private var lastSignature: String?
    private var blockSignatures: [String: Int] = [:]
    private var blockCount = 0

    /// Classification receives the complete block so the parser and registry
    /// owners can distinguish reads from actions without a second XML parser.
    public static func registerReadOnlyCalls(_ classify: @escaping @Sendable (String) -> Bool) {
        let box = Classifier(classify)
        readOnlyCalls.withLock { $0 = box }
    }
    // Boxed: a closure read back through withLock's inout state gains a
    // reabstraction thunk on every read and eventually overflows the stack.
    private final class Classifier<Input>: Sendable {
        let call: @Sendable (Input) -> Bool
        init(_ call: @escaping @Sendable (Input) -> Bool) { self.call = call }
    }
    private static let readOnlyCalls = OSAllocatedUnfairLock<Classifier<String>?>(initialState: nil)

    public static func registerAppReadOnlyCalls(_ classify: @escaping @Sendable ([String: JSONValue]) -> Bool) {
        let box = Classifier(classify)
        appReadOnlyCalls.withLock { $0 = box }
    }
    private static let appReadOnlyCalls = OSAllocatedUnfairLock<Classifier<[String: JSONValue]>?>(initialState: nil)

    public static func isAppReadOnly(_ input: [String: JSONValue]) -> Bool {
        appReadOnlyCalls.withLock { $0 }?.call(input) ?? false
    }
    private var lastBlockEnd = 0
    /// Where the text after the last complete call starts being checked.
    private var gapStart = 0
    private var bytes: [UInt8] = []

    /// Everything fed so far.
    public private(set) var text = ""
    public private(set) var reason: String?
    private var lineStart = 0
    private var pending = ""
    private var inFence = false
    private var fenceStarts: [Int] = []
    private var firstHeader: Int?

    public init(endsAtToolBoundary: Bool = false) {
        self.endsAtToolBoundary = endsAtToolBoundary
    }

    /// Feed one text delta; true when a correctness boundary ends the stream.
    public mutating func feed(_ delta: String) -> Bool {
        guard toolBoundary == nil else { return true }
        text += delta
        var rest = Substring(delta)
        while let nl = rest.unicodeScalars.firstIndex(of: "\n") {
            pending += Substring(rest.unicodeScalars[..<nl])
            let start = lineStart
            lineStart += pending.utf8.count + 1
            check(pending, at: start)
            pending = ""
            rest = Substring(rest.unicodeScalars[rest.unicodeScalars.index(after: nl)...])
        }
        pending += rest
        check(pending, at: lineStart)
        if endsAtToolBoundary {
            bytes.append(contentsOf: delta.utf8)
            if scanToolBlocks() { return true }
        }
        if let firstHeader {
            return setToolBoundary(.fabricatedResult, "fabricated tool-result header", at: firstHeader)
        }
        return false
    }

    private mutating func check(_ line: String, at start: Int) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            guard line.utf8.count + start < lineStart else { return }
            inFence.toggle()
            fenceStarts.append(start)
            return
        }
        if !inFence, trimmed.hasPrefix(Self.fabricatedHeader) {
            if firstHeader == nil { firstHeader = start }
        }
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
                let fenced = fenceStarts.prefix { $0 <= open.start }.count % 2 != 0
                let pendingFence = open.start >= lineStart
                    && pending.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                if fenced != pendingFence { continue }
                let block = String(decoding: bytes[open.start..<end], as: UTF8.self)
                // Runaway repeats are byte-identical; only the outer edges
                // are trimmed, so "red fox" and "redfox" stay different (Sol).
                let signature = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if signature == lastSignature {
                    return setToolBoundary(.repeatedBlock, "tool block repeated", at: lastBlockEnd)
                }
                let copies = blockSignatures[signature, default: 0] + 1
                blockSignatures[signature] = copies
                if copies > 1, !Self.isReadOnly(signature) {
                    return setToolBoundary(.repeatedAction, "tool action repeated", at: lastBlockEnd)
                }
                if copies >= 3 {
                    return setToolBoundary(.repeatedBlock, "read-only tool block repeated \(copies) times", at: lastBlockEnd)
                }
                lastSignature = signature
                blockCount += 1
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
                    return setToolBoundary(why.kind, why.detail, at: lastBlockEnd)
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
        readOnlyCalls.withLock { $0 }?.call(block) ?? false
    }

    static let fabricatedResultMarkers = ["<system>", "<function_results", "<tool_result", "Tool ran without output",
                                          "NativeAgent tool result"]
    static let gapBudget = 400

    /// Why the text since the last complete call ends the reply, or nil.
    private func gapAfterCall() -> (kind: LLMToolBoundaryReason, detail: String)? {
        let next = ["<invoke", "<tool_use", "<function_calls"].compactMap { Self.find($0, in: bytes, from: gapStart) }.min()
        let gap = String(decoding: bytes[gapStart..<(next ?? bytes.count)], as: UTF8.self)
        if let marker = Self.fabricatedResultMarkers.first(where: gap.contains) { return (.fabricatedResult, "invented result after a call (\(marker))") }
        if next == nil, gap.trimmingCharacters(in: .whitespacesAndNewlines).count > Self.gapBudget {
            return (.postCallProse, "prose after a call past \(Self.gapBudget) characters")
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

    private mutating func setToolBoundary(_ kind: LLMToolBoundaryReason, _ why: String, at end: Int) -> Bool {
        let chars = text.count
        toolBoundary = end
        toolBoundaryReason = kind
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

    private static let diagnosticLock = OSAllocatedUnfairLock(initialState: ())

    static func writeDiagnostic(_ raw: String, reason: String) {
        diagnosticLock.withLock { _ in
            writeDiagnosticLocked(raw, reason: reason)
        }
    }

    private static func writeDiagnosticLocked(_ raw: String, reason: String) {
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
        if let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) {
            let diagnostics = files.compactMap { url -> (URL, Date)? in
                guard url.pathExtension == "txt",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
            for (old, _) in diagnostics.prefix(max(0, diagnostics.count - 100)) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        Logger(subsystem: "NativeAgent", category: "Cutoff")
            .error("cutoff \(reason, privacy: .public) chars=\(raw.count, privacy: .public) raw=\(file.path, privacy: .public)")
    }
}
