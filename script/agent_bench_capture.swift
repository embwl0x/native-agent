#!/usr/bin/env swift
//
//  agent_bench_capture.swift — fixture capture for the TURN-REPLAY BENCH
//  (item 2 of docs/build_plans/agent-improvement-instrument.md).
//
//  Usage:
//    swift script/agent_bench_capture.swift --data-root ./data [--turns 5]
//                                           [--days 7] [--sessions id,id]
//                                           [--persona-root ./persona]
//                                           [--out local/bench_fixtures/<name>]
//
//  What it produces: a SELF-CONTAINED hermetic data root plus per-turn
//  EXPECTATIONS taken from the live turn traces, so a candidate build can
//  replay those same turns through its OWN context-assembly code and be
//  graded on envelope invariants (see tests/NativeAgentAppTests/
//  TurnReplayBenchTests.swift).
//
//  Hard rules — same discipline as script/agent_instrument.swift:
//    1. READ-ONLY on the source data root. SQLite is COPIED (db + -wal + -shm)
//       before anything opens it; JSONL is streamed read-only. The tool
//       REFUSES to run if --out resolves inside the data root or the persona
//       root.
//    2. Absent is not zero. Anything the capture could not find is recorded by
//       name in the fixture manifest as MISSING, never as an empty success.
//    3. A capture that yields ZERO turns is a FAILURE (exit 3), not an empty
//       fixture. A bench that replays nothing proves nothing.
//
//  PRIVACY: a real fixture contains User's actual memory, persona, cognition
//  state, and chat text. Every fixture dir is stamped with a FIXTURE-PRIVATE
//  marker and the default output location is `local/bench_fixtures/`, which is
//  gitignored (`local/` in .gitignore). Never move one into the repo tree.
//
//  Zero-python repo: single-file Swift script, Foundation + the system sqlite3
//  CLI via Process. No SPM target, no third-party deps.
//

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Utilities
// ─────────────────────────────────────────────────────────────────────────────

let fm = FileManager.default

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("agent_bench_capture: " + message + "\n").utf8))
    exit(code)
}

func note(_ message: String) {
    print(message)
}

/// Streams a file line by line as raw bytes — a turn-trace day file is
/// routinely 5–10 MB and a naive whole-file split degrades badly.
final class LineStream {
    private let handle: FileHandle
    private let chunkSize = 1 << 20

    init?(path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        handle = h
    }

    func forEachLine(_ body: (Data) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let nl = buffer[cursor...].firstIndex(of: 0x0A) {
                if nl > cursor { body(buffer[cursor..<nl]) }
                cursor = buffer.index(after: nl)
            }
            if cursor > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<cursor) }
        }
        if !buffer.isEmpty { body(buffer) }
        try? handle.close()
    }
}

func bytesOf(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Byte-level substring test so JSON parsing is only paid on lines we want.
func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let first = needle[0]
    return haystack.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let b = raw.bindMemory(to: UInt8.self)
        let limit = b.count - needle.count
        var i = 0
        while i <= limit {
            if b[i] == first {
                var j = 1
                while j < needle.count && b[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}

let isoNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseTimestamp(_ raw: String) -> Date? {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return nil }
    if let dot = s.firstIndex(of: ".") {
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        s.removeSubrange(dot..<end)
    }
    if s.contains(" ") && !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") }
    if let d = isoNoFraction.date(from: s) { return d }
    if let d = isoNoFraction.date(from: s + "Z") { return d }
    return nil
}

func isoString(_ d: Date) -> String { isoNoFraction.string(from: d) }

/// Is `candidate` inside `root` (or the same path)? Used by the refusal gates.
func isInside(_ candidate: URL, _ root: URL) -> Bool {
    let c = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    let r = root.standardizedFileURL.resolvingSymlinksInPath().path
    if c == r { return true }
    return c.hasPrefix(r.hasSuffix("/") ? r : r + "/")
}

@discardableResult
func runProcess(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "spawn failed: \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Arguments
// ─────────────────────────────────────────────────────────────────────────────

var dataRootArg = "./data"
var personaRootArg: String?
var outArg: String?
var turnLimit = 5
var lookbackDays = 7
var sessionFilter: Set<String> = []

var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    let a = argv[i]
    func next() -> String {
        guard i + 1 < argv.count else { fail("\(a) needs a value") }
        i += 1
        return argv[i]
    }
    switch a {
    case "--data-root": dataRootArg = next()
    case "--persona-root": personaRootArg = next()
    case "--out": outArg = next()
    case "--turns": turnLimit = Int(next()) ?? turnLimit
    case "--days": lookbackDays = Int(next()) ?? lookbackDays
    case "--sessions":
        for s in next().split(separator: ",") {
            let v = s.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { sessionFilter.insert(v.uppercased()) }
        }
    case "-h", "--help":
        print("""
        usage: swift script/agent_bench_capture.swift --data-root <path>
                   [--turns N] [--days N] [--sessions id,id]
                   [--persona-root <path>] [--out <dir>]
        """)
        exit(0)
    default: fail("unknown argument \(a)")
    }
    i += 1
}

guard turnLimit > 0 else { fail("--turns must be >= 1") }
guard lookbackDays > 0 else { fail("--days must be >= 1") }

let dataRoot = URL(fileURLWithPath: dataRootArg).standardizedFileURL
guard fm.fileExists(atPath: dataRoot.path) else { fail("data root not found: \(dataRoot.path)") }

let personaRoot = URL(
    fileURLWithPath: personaRootArg ?? dataRoot.deletingLastPathComponent()
        .appendingPathComponent("persona", isDirectory: true).path
).standardizedFileURL

let stampName: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.timeZone = TimeZone(identifier: "UTC")
    return "fixture-" + f.string(from: Date())
}()

let outRoot = URL(
    fileURLWithPath: outArg ?? "local/bench_fixtures/\(stampName)"
).standardizedFileURL

// REFUSAL GATES — the fixture can never be written into the sources it reads.
if isInside(outRoot, dataRoot) {
    fail("refusing to write the fixture inside the source data root (\(outRoot.path))")
}
if isInside(outRoot, personaRoot) {
    fail("refusing to write the fixture inside the persona root (\(outRoot.path))")
}
if fm.fileExists(atPath: outRoot.path) {
    let contents = (try? fm.contentsOfDirectory(atPath: outRoot.path)) ?? []
    if !contents.isEmpty {
        fail("refusing to overwrite a non-empty output dir: \(outRoot.path)")
    }
}

let fixtureDataRoot = outRoot.appendingPathComponent("root", isDirectory: true)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Copy discipline
// ─────────────────────────────────────────────────────────────────────────────

/// Names every source we looked for, whether it was there, and how it was read.
/// Absent is recorded by name — never silently dropped.
struct Manifest {
    struct Entry {
        let relative: String
        let present: Bool
        let detail: String
    }
    private(set) var entries: [Entry] = []
    mutating func record(_ relative: String, present: Bool, detail: String) {
        entries.append(Entry(relative: relative, present: present, detail: detail))
    }
    var missing: [String] { entries.filter { !$0.present }.map(\.relative) }
}

var manifest = Manifest()

func ensureDirectory(_ url: URL) {
    do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    catch { fail("cannot create \(url.path): \(error.localizedDescription)") }
}

/// Copy one plain file if it exists. Returns whether it landed.
@discardableResult
func copyPlain(_ relative: String, to destinationRelative: String? = nil) -> Bool {
    let src = dataRoot.appendingPathComponent(relative)
    let dstRel = destinationRelative ?? relative
    guard fm.fileExists(atPath: src.path) else {
        manifest.record(relative, present: false, detail: "absent in source data root")
        return false
    }
    let dst = fixtureDataRoot.appendingPathComponent(dstRel)
    ensureDirectory(dst.deletingLastPathComponent())
    do {
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        manifest.record(relative, present: true, detail: "copied read-only")
        return true
    } catch {
        manifest.record(relative, present: false, detail: "copy failed: \(error.localizedDescription)")
        return false
    }
}

/// SQLite copy discipline, identical in shape to `agent_instrument.swift`:
/// copy db + `-wal` + `-shm` together, then gate the COPY on
/// `PRAGMA quick_check`. A torn copy answers every later query with a
/// plausible-looking wrong number; the gate turns that into a hard failure.
func copySQLite(_ relative: String) {
    let src = dataRoot.appendingPathComponent(relative)
    guard fm.fileExists(atPath: src.path) else {
        manifest.record(relative, present: false, detail: "absent in source data root")
        return
    }
    if let attrs = try? fm.attributesOfItem(atPath: src.path),
       (attrs[.size] as? Int ?? 0) == 0 {
        fail("\(relative) is present but ZERO BYTES — not a live store")
    }
    let dst = fixtureDataRoot.appendingPathComponent(relative)
    ensureDirectory(dst.deletingLastPathComponent())

    var lastFailure = "unknown"
    for attempt in 1...2 {
        var copyFailed: String?
        for suffix in ["", "-wal", "-shm"] {
            let s = src.path + suffix, d = dst.path + suffix
            if fm.fileExists(atPath: d) { try? fm.removeItem(atPath: d) }
            if !suffix.isEmpty && !fm.fileExists(atPath: s) { continue }
            do { try fm.copyItem(atPath: s, toPath: d) }
            catch {
                copyFailed = (suffix.isEmpty ? "database" : "sidecar \(suffix)")
                    + " copy failed: \(error.localizedDescription)"
                break
            }
        }
        if let copyFailed {
            lastFailure = copyFailed
            continue
        }
        let check = runProcess("/usr/bin/sqlite3", [dst.path, "PRAGMA quick_check;"])
        let verdict = check.out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if check.status != 0 || verdict != "ok" {
            lastFailure = "PRAGMA quick_check on the copy returned "
                + (verdict.isEmpty ? "nothing" : "\"\(String(verdict.prefix(120)))\"")
            continue
        }
        manifest.record(
            relative,
            present: true,
            detail: "copied before query (db + wal + shm); quick_check ok"
                + (attempt > 1 ? " after \(attempt) attempts" : "")
        )
        return
    }
    fail("\(relative): copy/integrity gate failed after 2 attempts: \(lastFailure)")
}

/// Copy every `*.md` in a persona root (plus a `surfaces/` subdirectory when
/// present) into `<fixture>/root/persona/`. The bench opens the fixture with
/// `SwiftNativePersonaEngine.isolated(dataRoot:)`, whose root IS
/// `<dataRoot>/persona` — that is the mapping this copy exists to satisfy.
func copyPersonaDocs() {
    guard fm.fileExists(atPath: personaRoot.path) else {
        manifest.record("persona/", present: false, detail: "persona root absent: \(personaRoot.path)")
        return
    }
    let dst = fixtureDataRoot.appendingPathComponent("persona", isDirectory: true)
    ensureDirectory(dst)
    var copied = 0
    let entries = (try? fm.contentsOfDirectory(
        at: personaRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    )) ?? []
    for entry in entries where entry.pathExtension.lowercased() == "md" {
        let target = dst.appendingPathComponent(entry.lastPathComponent)
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        if (try? fm.copyItem(at: entry, to: target)) != nil { copied += 1 }
    }
    let surfaces = personaRoot.appendingPathComponent("surfaces", isDirectory: true)
    if fm.fileExists(atPath: surfaces.path) {
        let sDst = dst.appendingPathComponent("surfaces", isDirectory: true)
        if fm.fileExists(atPath: sDst.path) { try? fm.removeItem(at: sDst) }
        if (try? fm.copyItem(at: surfaces, to: sDst)) != nil {
            manifest.record("persona/surfaces/", present: true, detail: "copied read-only")
        }
    }
    manifest.record(
        "persona/*.md",
        present: copied > 0,
        detail: copied > 0
            ? "\(copied) persona doc(s) copied from \(personaRoot.path)"
            : "no *.md found in \(personaRoot.path)"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Turn expectations from the live traces
// ─────────────────────────────────────────────────────────────────────────────

struct CapturedTurn {
    var turnId: String
    var sessionId: String?
    var surface: String
    var ts: Date
    var counts: [String: Int]
    var flags: [String: Bool]
    var capsuleBytes: Int?
    var containsCognitiveSubstrate: Bool?
    var containsOrganismBehavior: Bool?
    var userMessage: String?
    /// Counts from the turn's FIRST `context.history.summary` row — the
    /// session-history path's own receipt (`history.priorCount`,
    /// `history.recallQueryChars`, `historyBlockChars`, ...). Kept apart from
    /// `counts` (the inner `context.summary`) so the two receipts never
    /// overwrite each other's `system.*Chars`.
    var historyCounts: [String: Int] = [:]
    /// The bounded transcript window this turn actually saw (see
    /// `transcriptWindow(forTurn:sessionId:)`). nil when the session file
    /// could not be read — recorded by name, never as an empty window.
    var transcript: TranscriptWindow?
}

/// The rows of `chat/messages/<sessionId>.jsonl` that preceded the source
/// user row, bounded the way the production reader bounds its own read:
/// the HEAD anchors (first `headAnchorLines` raw lines) plus a TAIL of at most
/// `tailMaximumLines` raw lines / `tailMaximumBytes` bytes immediately before
/// the user row. Rows at or after the user row (the user row itself, the
/// tool/assistant rows of the same run) post-date the source assembly and are
/// never included.
struct TranscriptWindow {
    /// Mirrors `SessionHistoryReader`: anchorLimit 3, tailLimit
    /// max(64, historyLimit(40) * 2) = 80 lines, promptTailMaximumBytes 192KB.
    static let headAnchorLines = 3
    static let tailMaximumLines = 80
    static let tailMaximumBytes = 192 * 1024

    var lines: [Data]
    /// Raw lines in the source file strictly before the user row.
    var sourceLinesBefore: Int
    var truncated: Bool
    var bytes: Int { lines.reduce(0) { $0 + $1.count + 1 } }
}

/// Scan a raw trace line for `"<key>": <int>` — the capsule numbers live inside
/// an ESCAPED JSON string (`payload._preview`) once the trace row is truncated,
/// so a structured decode of the payload cannot see them. A tolerant text scan
/// reads both shapes.
func scanInt(_ line: String, key: String) -> Int? {
    guard let r = line.range(of: key) else { return nil }
    var idx = r.upperBound
    var sawColon = false
    var digits = ""
    while idx < line.endIndex {
        let c = line[idx]
        if !sawColon {
            if c == ":" { sawColon = true } else if c == "\"" || c == "\\" || c == " " {
                // still inside the key's closing quote/escape run
            } else { return nil }
        } else if c.isNumber {
            digits.append(c)
        } else if c == " " {
            if !digits.isEmpty { break }
        } else {
            break
        }
        idx = line.index(after: idx)
    }
    return digits.isEmpty ? nil : Int(digits)
}

func scanBool(_ line: String, key: String) -> Bool? {
    guard let r = line.range(of: key) else { return nil }
    let tail = line[r.upperBound...].prefix(24)
    if tail.contains("true") { return true }
    if tail.contains("false") { return false }
    return nil
}

let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86_400)
let tracesDir = dataRoot.appendingPathComponent("turn_traces", isDirectory: true)
var byTurn: [String: CapturedTurn] = [:]

let traceFiles = ((try? fm.contentsOfDirectory(atPath: tracesDir.path)) ?? [])
    .filter { $0.hasSuffix(".jsonl") }
    .sorted()

if traceFiles.isEmpty {
    manifest.record("turn_traces/*.jsonl", present: false, detail: "no trace day files found")
} else {
    manifest.record(
        "turn_traces/*.jsonl",
        present: true,
        detail: "\(traceFiles.count) day file(s) streamed read-only"
    )
}

let needleSummary = bytesOf("\"context.summary\"")
let needleHistorySummary = bytesOf("\"context.history.summary\"")
let needleSnapshot = bytesOf("\"context.snapshot\"")
let needleReady = bytesOf("\"context.ready\"")

/// The history receipt's keys the bench grades. Captured by name so a fixture
/// carries exactly what the invariants cite.
let historyCountKeys: Set<String> = [
    "history.priorCount",
    "history.recallQueryChars",
    "historyBlockChars",
    "history.prompt.returned",
    "system.dynamicChars",
    "userMessageChars",
]

for file in traceFiles {
    let path = tracesDir.appendingPathComponent(file).path
    guard let stream = LineStream(path: path) else { continue }
    stream.forEachLine { raw in
        let isSummary = contains(raw, needleSummary)
        let isHistorySummary = contains(raw, needleHistorySummary)
        let isSnapshot = contains(raw, needleSnapshot)
        let isReady = contains(raw, needleReady)
        guard isSummary || isHistorySummary || isSnapshot || isReady else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let kind = object["kind"] as? String,
              let turnId = object["turnId"] as? String,
              let tsRaw = object["ts"] as? String,
              let ts = parseTimestamp(tsRaw), ts >= cutoff else { return }
        let sessionId = object["sessionId"] as? String
        let surface = (object["surface"] as? String) ?? "chat"

        var entry = byTurn[turnId] ?? CapturedTurn(
            turnId: turnId, sessionId: nil, surface: surface, ts: ts,
            counts: [:], flags: [:], capsuleBytes: nil,
            containsCognitiveSubstrate: nil, containsOrganismBehavior: nil,
            userMessage: nil
        )
        if entry.sessionId == nil, let sessionId, !sessionId.isEmpty {
            entry.sessionId = sessionId
        }
        switch kind {
        case "context.summary":
            // ONE user turn can emit several context.summary rows (one rebuild
            // per tool-loop iteration). Keep the FIRST — that is the assembly
            // the user's message actually produced.
            guard entry.counts.isEmpty else { break }
            entry.ts = ts
            entry.surface = surface
            if let payload = object["payload"] as? [String: Any] {
                if let counts = payload["counts"] as? [String: Any] {
                    for (k, v) in counts {
                        if let n = v as? Int { entry.counts[k] = n }
                        else if let d = v as? Double { entry.counts[k] = Int(d) }
                    }
                }
                if let flags = payload["flags"] as? [String: Any] {
                    for (k, v) in flags where v is Bool { entry.flags[k] = (v as! Bool) }
                }
            }
        case "context.history.summary":
            // Same FIRST-row rule as context.summary: one row per tool-loop
            // iteration; the first is the assembly the user's message saw.
            guard entry.historyCounts.isEmpty else { break }
            if let payload = object["payload"] as? [String: Any],
               let counts = payload["counts"] as? [String: Any] {
                for (k, v) in counts where historyCountKeys.contains(k) {
                    if let n = v as? Int { entry.historyCounts[k] = n }
                    else if let d = v as? Double { entry.historyCounts[k] = Int(d) }
                }
            }
        case "context.snapshot":
            let text = String(decoding: raw, as: UTF8.self)
            if entry.capsuleBytes == nil {
                entry.capsuleBytes = scanInt(text, key: "cognitiveCapsuleBytes")
            }
            if entry.containsCognitiveSubstrate == nil {
                entry.containsCognitiveSubstrate = scanBool(text, key: "containsCognitiveSubstrate")
            }
            if entry.containsOrganismBehavior == nil {
                entry.containsOrganismBehavior = text.contains("[OrganismBehavior]")
            }
        default:
            break
        }
        byTurn[turnId] = entry
    }
}

// A turn is only usable if it carries the assembly counts AND names a session
// (the session is the only route back to the user's message).
var candidates = byTurn.values
    .filter { !$0.counts.isEmpty && ($0.sessionId?.isEmpty == false) }
    .sorted { $0.ts > $1.ts }

if !sessionFilter.isEmpty {
    candidates = candidates.filter { sessionFilter.contains(($0.sessionId ?? "").uppercased()) }
}

// ── The user messages: from the chat session store.
//
// Verified empirically against the live root (2026-08-21): session messages
// persist at `<dataRoot>/chat/messages/<sessionId>.jsonl`, one JSON object per
// line with `role`, `content`, `createdAt`, `runId`, and — on assistant rows —
// `metadata.turnTraceId`, which is the trace `turnId`. The user message for a
// turn is the preceding user row with the assistant's runId. Only legacy
// assistant rows without a runId may use the nearest preceding user row.
func sessionMessagesPath(_ sessionId: String) -> String {
    dataRoot
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl").path
}

/// Pass 1: locate the user row. Returns the message and the 0-based RAW LINE
/// INDEX of that row in the session file (the window boundary for pass 2).
func userMessage(forTurn turnId: String, sessionId: String) -> (message: String, lineIndex: Int)? {
    guard let stream = LineStream(path: sessionMessagesPath(sessionId)) else { return nil }
    var lastUser: (String, Int)?
    var matched: (String, Int)?
    var foundAssistant = false
    var runIdUser: [String: (String, Int)] = [:]
    var lineIndex = -1
    stream.forEachLine { raw in
        lineIndex += 1
        guard !foundAssistant,
              let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let role = object["role"] as? String else { return }
        let content = (object["content"] as? String) ?? ""
        let runId = object["runId"] as? String
        if role == "user" {
            lastUser = (content, lineIndex)
            if let runId { runIdUser[runId] = (content, lineIndex) }
            return
        }
        guard role == "assistant" else { return }
        let metadata = object["metadata"] as? [String: Any]
        if (metadata?["turnTraceId"] as? String) == turnId {
            foundAssistant = true
            if let runId, !runId.isEmpty {
                // A later interleaved user message is not this turn's input.
                // Never recover from rows after the matched assistant either:
                // those were not available when the source turn assembled.
                matched = runIdUser[runId]
            } else {
                matched = lastUser
            }
        }
    }
    if let matched, !matched.0.isEmpty { return (matched.0, matched.1) }
    return nil
}

/// Pass 2: the bounded window the source turn actually saw — every raw line
/// strictly BEFORE `userLineIndex`, reduced to head anchors + bounded tail
/// exactly the way `SessionHistoryReader.promptMessagesWithStats` bounds its
/// own read. Lines are copied VERBATIM (the bench's reader decodes the same
/// bytes production decoded); nothing is rewritten.
func transcriptWindow(sessionId: String, userLineIndex: Int) -> TranscriptWindow? {
    guard let stream = LineStream(path: sessionMessagesPath(sessionId)) else { return nil }
    var head: [Data] = []
    var tail: [Data] = []
    var tailBytes = 0
    var lineIndex = -1
    stream.forEachLine { raw in
        lineIndex += 1
        guard lineIndex < userLineIndex else { return }
        let line = Data(raw)
        if head.count < TranscriptWindow.headAnchorLines { head.append(line) }
        tail.append(line)
        tailBytes += line.count + 1
        while tail.count > TranscriptWindow.tailMaximumLines
            || (tailBytes > TranscriptWindow.tailMaximumBytes && tail.count > 1) {
            tailBytes -= tail.removeFirst().count + 1
        }
    }
    let before = max(0, min(lineIndex + 1, userLineIndex))
    // When the whole prefix fits in the tail the head IS the start of the
    // tail — emit it once, in file order. Otherwise head anchors, then a gap
    // (the middle the production reader also does not read exactly), then
    // the tail. The reader dedups by (timestamp, role, content) in both
    // shapes, exactly as it does on the live file.
    let lines: [Data]
    if before <= tail.count {
        lines = tail
    } else {
        lines = head + tail
    }
    return TranscriptWindow(lines: lines, sourceLinesBefore: before, truncated: before > tail.count)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Write the fixture
// ─────────────────────────────────────────────────────────────────────────────

ensureDirectory(outRoot)
ensureDirectory(fixtureDataRoot)

// Stores the candidate build's context assembly actually opens.
copySQLite("cognition/cognition.sqlite")
copySQLite("memory/memory.sqlite")

// Config the assembly path reads. Each is recorded present/absent by name.
for relative in [
    "memory/profile.json",
    "memory/embedding_epoch_receipt.json",
    "providers/surfaces.json",
    "providers/active.json",
    "rem_pins.json",
    "cognition/organism_state.json",
    "user_prefs.json",
] {
    copyPlain(relative)
}

copyPersonaDocs()

// ContextFlow builds its own derived store; the directory just has to exist.
ensureDirectory(fixtureDataRoot.appendingPathComponent("context", isDirectory: true))
ensureDirectory(fixtureDataRoot.appendingPathComponent("turn_traces", isDirectory: true))

// Turn selection + user-message resolution.
//
// SPREAD FIRST, then fill. Newest-first alone lands every captured turn inside
// one burst on one surface in one session — a fixture that measures one lane
// and calls it the system. Pass 1 takes at most one turn per (session,
// surface); pass 2 backfills from the remainder.
func resolve(_ turn: CapturedTurn) -> CapturedTurn? {
    guard let sessionId = turn.sessionId else { return nil }
    guard let located = userMessage(forTurn: turn.turnId, sessionId: sessionId) else { return nil }
    guard !located.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var out = turn
    out.userMessage = located.message
    // The transcript window the turn saw. A session file that vanished between
    // pass 1 and pass 2 leaves this nil — recorded by name below, never as an
    // empty window the bench would replay as "no history".
    out.transcript = transcriptWindow(sessionId: sessionId, userLineIndex: located.lineIndex)
    return out
}

var captured: [CapturedTurn] = []
var takenTurnIds = Set<String>()
var seenLanes = Set<String>()
for turn in candidates {
    guard captured.count < turnLimit else { break }
    let lane = "\((turn.sessionId ?? "").uppercased())|\(turn.surface)"
    guard !seenLanes.contains(lane) else { continue }
    guard let resolved = resolve(turn) else { continue }
    seenLanes.insert(lane)
    takenTurnIds.insert(resolved.turnId)
    captured.append(resolved)
}
for turn in candidates {
    guard captured.count < turnLimit else { break }
    guard !takenTurnIds.contains(turn.turnId), let resolved = resolve(turn) else { continue }
    takenTurnIds.insert(resolved.turnId)
    captured.append(resolved)
}
captured.sort { $0.ts > $1.ts }

// VACUITY GATE. An empty fixture replays nothing and would grade every future
// build green. It is a capture FAILURE, not an empty success.
if captured.isEmpty {
    try? fm.removeItem(at: outRoot)
    fail("""
    captured ZERO replayable turns from \(dataRoot.path) in the last \(lookbackDays) day(s).
    A bench fixture with no turns can never fail, so it is refused.
    Checked \(traceFiles.count) trace day file(s); \(byTurn.count) turn(s) seen, \
    \(candidates.count) with both context.summary counts and a session id.
    """, code: 3)
}

// ── The transcript windows: one file per captured turn.
//
// Production keys the session file by sessionId, but two captured turns from
// ONE session saw two DIFFERENT windows — so the fixture stores them per
// turn under `root/chat/transcripts/<turnId>.jsonl` and the bench stages each
// one into `root/chat/messages/<sessionId>.jsonl` for the duration of that
// turn's replay. Raw lines are copied verbatim.
func safeFileStem(_ raw: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    let filtered = String(raw.filter { allowed.contains($0) })
    return filtered.isEmpty ? "turn" : String(filtered.prefix(120))
}

let transcriptsDir = fixtureDataRoot
    .appendingPathComponent("chat", isDirectory: true)
    .appendingPathComponent("transcripts", isDirectory: true)
ensureDirectory(transcriptsDir)
var transcriptRelativePaths: [String: String] = [:]
var transcriptsWritten = 0
var transcriptsMissing: [String] = []
for turn in captured {
    guard let window = turn.transcript else {
        transcriptsMissing.append(turn.turnId)
        continue
    }
    let relative = "chat/transcripts/\(safeFileStem(turn.turnId)).jsonl"
    var payload = Data()
    for line in window.lines {
        payload.append(line)
        payload.append(0x0A)
    }
    do {
        try payload.write(to: fixtureDataRoot.appendingPathComponent(relative))
        transcriptRelativePaths[turn.turnId] = relative
        transcriptsWritten += 1
    } catch {
        fail("cannot write transcript window \(relative): \(error.localizedDescription)")
    }
}
manifest.record(
    "chat/messages/<sessionId>.jsonl (bounded windows)",
    present: transcriptsWritten > 0,
    detail: transcriptsWritten > 0
        ? "\(transcriptsWritten) per-turn window(s) copied verbatim to chat/transcripts/"
            + " (head \(TranscriptWindow.headAnchorLines) + tail ≤\(TranscriptWindow.tailMaximumLines)"
            + " lines/≤\(TranscriptWindow.tailMaximumBytes / 1024)KB before the user row)"
            + (transcriptsMissing.isEmpty ? "" : "; unreadable for turn(s): \(transcriptsMissing.joined(separator: ", "))")
        : "no session file could be re-read for any captured turn"
)

func jsonValue(_ turn: CapturedTurn) -> [String: Any] {
    var capsule: [String: Any] = [:]
    if let b = turn.capsuleBytes { capsule["bytes"] = b }
    if let v = turn.containsCognitiveSubstrate { capsule["containsCognitiveSubstrate"] = v }
    if let v = turn.containsOrganismBehavior { capsule["containsOrganismBehavior"] = v }
    // The history receipt's counts join the expectation namespace under their
    // own `history.*` / `historyBlockChars` keys; the two receipts' shared
    // `system.*Chars` / `userMessageChars` are kept apart under
    // `historyCounts` so neither overwrites the other.
    var counts = turn.counts
    for (k, v) in turn.historyCounts
    where k.hasPrefix("history.") || k == "historyBlockChars" {
        counts[k] = v
    }
    var object: [String: Any] = [
        "turnId": turn.turnId,
        "sessionId": turn.sessionId ?? "",
        "surface": turn.surface,
        "ts": isoString(turn.ts),
        "userMessage": turn.userMessage ?? "",
        "counts": counts,
        "historyCounts": turn.historyCounts,
        "flags": turn.flags,
    ]
    if !capsule.isEmpty { object["capsule"] = capsule }
    if let window = turn.transcript, let relative = transcriptRelativePaths[turn.turnId] {
        object["transcript"] = [
            "relativePath": relative,
            "lines": window.lines.count,
            "bytes": window.bytes,
            "sourceLinesBefore": window.sourceLinesBefore,
            "headAnchorLines": TranscriptWindow.headAnchorLines,
            "truncated": window.truncated,
        ] as [String: Any]
    }
    return object
}

let expectations: [String: Any] = [
    // v2 (2026-08-21): per-turn `transcript` windows + `history.*` counts so
    // the bench replays the SESSION-HISTORY path. The bench still accepts v1.
    "schema": "turn-replay-bench.expectations.v2",
    "capturedAt": isoString(Date()),
    "sourceDataRoot": dataRoot.path,
    "sourcePersonaRoot": personaRoot.path,
    "lookbackDays": lookbackDays,
    "fixtureDataRoot": "root",
    "turns": captured.map(jsonValue),
    "manifest": manifest.entries.map {
        ["source": $0.relative, "present": $0.present, "detail": $0.detail]
    },
    "missingSources": manifest.missing,
]

do {
    let data = try JSONSerialization.data(
        withJSONObject: expectations,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: outRoot.appendingPathComponent("expectations.json"))
} catch {
    fail("cannot write expectations.json: \(error.localizedDescription)")
}

let marker = """
FIXTURE-PRIVATE — DO NOT COMMIT, DO NOT SHARE

This directory is a snapshot of a REAL NativeAgent data root. It contains real
personal data: memory records, persona documents, cognition/affect state, the
verbatim text of real chat turns, AND per-turn bounded transcript windows
(chat/transcripts/*.jsonl — the prior conversation rows each captured turn saw,
copied verbatim).

Captured: \(isoString(Date()))
Source data root: \(dataRoot.path)
Source persona root: \(personaRoot.path)
Turns: \(captured.count)

It is written under `local/` by default, which is gitignored. If you move it,
keep it outside the repository working tree. Delete it when you are done.

Replay it with:
  NATIVEAGENT_BENCH_FIXTURE=<this dir> swift test --filter TurnReplayBench
"""
try? Data(marker.utf8).write(to: outRoot.appendingPathComponent("FIXTURE-PRIVATE"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Report
// ─────────────────────────────────────────────────────────────────────────────

note("agent_bench_capture: fixture written")
note("  out          : \(outRoot.path)")
note("  data root    : \(fixtureDataRoot.path)")
note("  source       : \(dataRoot.path) (READ-ONLY — sqlite copied, jsonl streamed)")
note("  persona      : \(personaRoot.path)")
note("  turns        : \(captured.count) (of \(candidates.count) replayable candidates)")
for turn in captured {
    let counts = turn.counts
    note("    - \(turn.turnId) \(isoString(turn.ts)) surface=\(turn.surface)"
         + " attn(terms/atoms/act)=\(counts["contextFlow.attentionTerms"] ?? 0)"
         + "/\(counts["contextFlow.attentionWorkingAtoms"] ?? 0)"
         + "/\(counts["contextFlow.attentionActivation"] ?? 0)"
         + " mem=\(counts["contextFlow.memoryRecords"] ?? 0)"
         + " docs=\(counts["persona.docCount"] ?? 0)"
         + " stable/dynamic=\(counts["system.stableChars"] ?? 0)/\(counts["system.dynamicChars"] ?? 0)"
         + " capsule=\(turn.capsuleBytes.map(String.init) ?? "-")"
         + " history(prior/recallQ/block)=\(turn.historyCounts["history.priorCount"] ?? 0)"
         + "/\(turn.historyCounts["history.recallQueryChars"] ?? 0)"
         + "/\(turn.historyCounts["historyBlockChars"] ?? 0)"
         + " window=\(turn.transcript.map { "\($0.lines.count)l/\($0.bytes / 1024)KB" + ($0.truncated ? "(bounded)" : "") } ?? "MISSING")")
}
if !manifest.missing.isEmpty {
    note("  MISSING (recorded, never treated as zero):")
    for m in manifest.missing { note("    - \(m)") }
}
note("  marker       : FIXTURE-PRIVATE (real personal data — keep out of the repo)")
