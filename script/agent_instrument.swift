#!/usr/bin/env swift
//
//  agent_instrument.swift — the "hook in and take a look" instrument.
//
//  Usage:  swift script/agent_instrument.swift --data-root <path> [--days 7] [--out report.md]
//
//  A READ-ONLY instrument any agent (Claude, codex, a fresh session) can run
//  against a NativeAgent data root to get a truthful read of how Agent is doing
//  AS A COMPANION / ORGANIZER — memory recall, subconscious liveness, desk
//  throughput, responsiveness, cost. Never code-task benchmarks.
//
//  Hard rules, codified here and not just in the plan:
//    1. Metrics query a transactional SQLite backup in a temp dir. A short
//       read-only source connection creates that backup; never copy a live
//       database and its WAL independently or mutate the source database.
//    2. JSONL is streamed read-only; nothing is ever written inside the data root.
//       The tool REFUSES to run if --out resolves inside the data root.
//    3. A metric whose source is missing is rendered "source absent" — never a
//       zero. Silent-zero is the exact bug class this instrument exists to catch.
//
//  Zero-python repo: single-file Swift script, Foundation + the system sqlite3
//  CLI via Process. No SPM target, no third-party deps.
//

import Foundation
import SQLite3

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Small utilities
// ─────────────────────────────────────────────────────────────────────────────

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("agent_instrument: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

/// Streams a file line by line as raw bytes. One `removeSubrange` per chunk, so
/// a 10 MB trace file does not degrade into quadratic memmove.
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

/// Byte-level substring test, so we only pay JSON parsing on lines we want.
func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let first = needle[0]
    return haystack.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let bytes = raw.bindMemory(to: UInt8.self)
        let limit = bytes.count - needle.count
        var i = 0
        while i <= limit {
            if bytes[i] == first {
                var j = 1
                while j < needle.count && bytes[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

let isoNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Robust across every timestamp shape actually present in the data root:
/// "2026-08-20T05:50:01.921Z", "2026-08-16T08:38:04Z",
/// "2026-08-12T12:30:31.242000+00:00", "2026-08-21 07:27:03".
func parseTimestamp(_ raw: String) -> Date? {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return nil }
    // Normalize fractional width for the base formatter without losing it:
    // dropping milliseconds turns valid short lifecycle intervals negative
    // relative to their separately stamped duration counters.
    var fractionalSeconds: TimeInterval = 0
    if let dot = s.firstIndex(of: ".") {
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        guard let fraction = Double("0" + s[dot..<end]), fraction >= 0, fraction < 1 else { return nil }
        fractionalSeconds = fraction
        s.removeSubrange(dot..<end)
    }
    if s.contains(" ") && !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") }
    if let d = isoNoFraction.date(from: s) { return d.addingTimeInterval(fractionalSeconds) }
    // Naive local-time form with no zone designator.
    if let d = isoNoFraction.date(from: s + "Z") { return d.addingTimeInterval(fractionalSeconds) }
    return nil
}

let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

func stamp(_ d: Date) -> String { stampFormatter.string(from: d) }

func dayKeyFormatterUTC() -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}
let dayKeyFmt = dayKeyFormatterUTC()

func fmt(_ v: Double, _ places: Int = 2) -> String {
    if v.isNaN || v.isInfinite { return "n/a" }
    return String(format: "%.\(places)f", v)
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let idx = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[max(0, min(sorted.count - 1, idx))]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Markdown escaping — one helper per sink context
//
// Every string in this report that came out of a STORE is attacker-shaped as
// far as the renderer is concerned: a lane key, a surface name, a desk title, a
// feed path and an error signature are all producer-controlled. Unescaped they
// can open a heading, close a table row, forge a link, or inject raw HTML — so
// the report would be lying about its own structure, which is the same sin the
// instrument exists to catch.
//
//   mdCode(_:)      → the string is going INSIDE a `backtick span`.
//                     Backticks are STRIPPED (nothing can close the span),
//                     `|` escaped for tables, newlines flattened.
//   mdText(_:)      → the string is prose: a table cell, a bullet, a heading.
//                     Full punctuation + HTML escaping.
//   mdLinkText(_:)  → an ALREADY-COMPOSED markdown fragment used as `[...]`
//                     link text. Only the two characters that can break the
//                     link are escaped, so the composed backtick spans survive.
//   mdHeading(_:)   → an ALREADY-COMPOSED markdown fragment used after `### `.
//                     Newlines flattened so no injected line can start a
//                     heading of its own.
// ─────────────────────────────────────────────────────────────────────────────

/// Collapses every line/paragraph separator to a space. A newline is the one
/// character that can move injected text to column 0, where `#`, `|`, `-` and
/// `<` all become structural.
func flattenLines(_ s: String) -> String {
    var out = s
    for nl in ["\r\n", "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
        out = out.replacingOccurrences(of: nl, with: " ")
    }
    return out
}

func mdCode(_ s: String) -> String {
    flattenLines(s)
        .replacingOccurrences(of: "`", with: "")        // cannot close the span
        .replacingOccurrences(of: "|", with: "\\|")     // GFM cell separator
}

func mdText(_ s: String) -> String {
    var out = flattenLines(s)
    out = out.replacingOccurrences(of: "\\", with: "\\\\")
    // HTML first: after this the only `&` left are the entities we just wrote.
    out = out.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    for c in ["`", "[", "]", "(", ")", "#", "|", "*", "_", "~"] {
        out = out.replacingOccurrences(of: c, with: "\\" + c)
    }
    return out
}

func mdLinkText(_ s: String) -> String {
    flattenLines(s)
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
}

/// For a string THIS FILE composed, whose data-derived fragments were already
/// escaped at composition time (lead titles/evidence, coverage measurements).
/// Escaping it again would mangle the backtick spans we deliberately wrote, so
/// only the two structural hazards a composed fragment can still carry are
/// handled: an embedded newline, and a `|` that would split a table row.
func mdComposed(_ s: String) -> String {
    flattenLines(s).replacingOccurrences(of: "|", with: "\\|")
}

func mdHeading(_ s: String) -> String {
    let t = flattenLines(s)
    return t.hasPrefix("#") ? " " + t : t
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Truncated-JSON shallow scalar scanner
//
// `context.snapshot` rows persist their payload as `_preview`: a JSON *string*
// that is itself cut off mid-object. JSONSerialization refuses it, so we scan
// depth-1 scalar (number/bool) members out of the surviving prefix. Keys are
// emitted alphabetically by the producer, so truncation drops the TAIL of the
// key space — which is why the report labels these lanes truncation-limited
// rather than claiming a missing key is dormant.
// ─────────────────────────────────────────────────────────────────────────────

func shallowScalars(fromTruncatedJSONObject text: String) -> [String: Double] {
    var out: [String: Double] = [:]
    let b = Array(text.utf8)
    var depth = 0
    var inStr = false
    var esc = false
    var literal = [UInt8]()
    var lastKey: String?
    var awaitingValue = false
    var scalar = [UInt8]()

    func flushScalar() {
        defer { scalar.removeAll(keepingCapacity: true) }
        guard awaitingValue, depth == 1, let key = lastKey, !scalar.isEmpty else { return }
        let token = String(decoding: scalar, as: UTF8.self)
        if token == "true" { out[key] = 1 }
        else if token == "false" { out[key] = 0 }
        else if let d = Double(token) { out[key] = d }
        lastKey = nil
        awaitingValue = false
    }

    var i = 0
    while i < b.count {
        let c = b[i]
        if inStr {
            if esc { esc = false }
            else if c == 0x5C { esc = true }               // backslash
            else if c == 0x22 {                            // closing quote
                inStr = false
                let token = String(decoding: literal, as: UTF8.self)
                if depth == 1 {
                    if awaitingValue { awaitingValue = false; lastKey = nil }   // string value
                    else { lastKey = token }
                }
                literal.removeAll(keepingCapacity: true)
            } else { literal.append(c) }
            i += 1
            continue
        }
        switch c {
        case 0x22:                                          // "
            flushScalar()
            inStr = true
            literal.removeAll(keepingCapacity: true)
        case 0x7B, 0x5B:                                    // { [
            flushScalar()
            if depth == 1 && awaitingValue { awaitingValue = false; lastKey = nil }
            depth += 1
        case 0x7D, 0x5D:                                    // } ]
            flushScalar()
            depth -= 1
        case 0x3A:                                          // :
            if depth == 1 { awaitingValue = true }
        case 0x2C:                                          // ,
            flushScalar()
            if depth == 1 { awaitingValue = false; lastKey = nil }
        case 0x20, 0x09, 0x0A, 0x0D:
            flushScalar()
        default:
            if awaitingValue && depth == 1 { scalar.append(c) }
        }
        i += 1
    }
    return out
}

/// Flattens a decoded JSON object into numeric "lanes": numbers as-is, bools as
/// 0/1, arrays as their element count. Strings are ignored (not measurable).
func flattenNumeric(_ obj: Any, prefix: String, into dict: inout [String: Double]) {
    if let d = obj as? [String: Any] {
        for (k, v) in d {
            flattenNumeric(v, prefix: prefix.isEmpty ? k : prefix + "." + k, into: &dict)
        }
    } else if let a = obj as? [Any] {
        dict[prefix + "[]"] = Double(a.count)
    } else if let n = obj as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { dict[prefix] = n.boolValue ? 1 : 0 }
        else { dict[prefix] = n.doubleValue }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - sqlite3 CLI over a copy
// ─────────────────────────────────────────────────────────────────────────────

let fieldSep = "\u{1}"

/// The outcome of one sqlite3 invocation. There is deliberately NO way to get
/// rows out of this without also seeing whether the query succeeded: a launch
/// failure, a nonzero exit and a schema error each used to fall through to `[]`
/// and then to `?? 0`, which renders "0 nodes" for an unreadable store. That is
/// the exact silent-zero this whole instrument exists to catch, committed by
/// the instrument itself.
enum QueryOutcome {
    case ok([[String]])
    case failed(String)          // human-readable reason
}

final class SQLiteCopy {
    let originalPath: String
    let copyPath: String
    let label: String
    /// First failure seen on this handle. Once set, the SOURCE is unreadable —
    /// not "partially readable": a store that cannot answer one query has no
    /// standing to have its other answers believed.
    private(set) var failureReason: String?

    init(originalPath: String, copyPath: String, label: String) {
        self.originalPath = originalPath
        self.copyPath = copyPath
        self.label = label
    }

    func run(_ sql: String) -> QueryOutcome {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            let r = "/usr/bin/sqlite3 is not executable"
            failureReason = failureReason ?? r
            return .failed(r)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-batch", "-noheader", "-separator", fieldSep, copyPath, sql]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            let r = "sqlite3 failed to launch: \(error.localizedDescription)"
            failureReason = failureReason ?? r
            return .failed(r)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard p.terminationStatus == 0 else {
            let r = "sqlite3 exited \(p.terminationStatus)"
                + (errText.isEmpty ? "" : ": " + String(errText.prefix(200)))
            failureReason = failureReason ?? r
            return .failed(r)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            let r = "sqlite3 output was not valid UTF-8"
            failureReason = failureReason ?? r
            return .failed(r)
        }
        return .ok(text.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.components(separatedBy: fieldSep)
        })
    }

    /// Rows, or `[]` **only after** the failure has been recorded on this handle
    /// (which flips the whole source to UNREADABLE upstream). Callers may still
    /// spell `?? 0` — it is now unreachable as a rendered value, because an
    /// unreadable source never reaches a rendering site.
    func query(_ sql: String) -> [[String]] {
        switch run(sql) {
        case .ok(let rows): return rows
        case .failed: return []
        }
    }

    func scalar(_ sql: String) -> String? { query(sql).first?.first }
    func int(_ sql: String) -> Int? { scalar(sql).flatMap { Int($0) } }
}

/// A store is exactly one of these three. `absent` and `unreadable` are
/// different facts and the report never collapses them into each other, or into
/// a zero.
enum StoreState {
    case ok(SQLiteCopy)
    case absent
    case unreadable(String)

    var handle: SQLiteCopy? { if case .ok(let db) = self { return db }; return nil }
    var unreadableReason: String? { if case .unreadable(let r) = self { return r }; return nil }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Source registry (present vs absent — never a silent zero)
// ─────────────────────────────────────────────────────────────────────────────

final class SourceRegistry {
    struct Entry {
        let label: String
        let path: String
        let present: Bool
        var rows: Int?
        var note: String
        /// Non-nil ⇒ the source EXISTS but could not be read truthfully. Its
        /// sections are skipped with an explicit line; none of its numbers are
        /// rendered, least of all as zeros.
        var unreadableReason: String?
        /// Lines seen / lines that would not parse. Surfaced in the table so a
        /// partly-corrupt feed can never masquerade as a complete one.
        var lines: Int?
        var malformed: Int = 0
    }
    private(set) var entries: [Entry] = []

    @discardableResult
    func register(_ label: String, _ path: String, note: String = "") -> Bool {
        let present = FileManager.default.fileExists(atPath: path)
        entries.append(Entry(label: label, path: path, present: present, rows: nil, note: note))
        return present
    }

    func setRows(_ label: String, _ n: Int) {
        if let i = entries.firstIndex(where: { $0.label == label }) { entries[i].rows = n }
    }
    func note(_ label: String, _ text: String) {
        if let i = entries.firstIndex(where: { $0.label == label }) { entries[i].note = text }
    }
    func setParse(_ label: String, lines: Int, malformed: Int) {
        if let i = entries.firstIndex(where: { $0.label == label }) {
            entries[i].lines = lines
            entries[i].malformed = malformed
        }
    }
    func markUnreadable(_ label: String, _ reason: String) {
        if let i = entries.firstIndex(where: { $0.label == label }),
           entries[i].unreadableReason == nil {
            entries[i].unreadableReason = reason
        }
    }
    func isUnreadable(_ label: String) -> Bool {
        entries.first(where: { $0.label == label })?.unreadableReason != nil
    }
    func reason(_ label: String) -> String {
        entries.first(where: { $0.label == label })?.unreadableReason ?? "unknown"
    }
    func isPresent(_ label: String) -> Bool {
        entries.first(where: { $0.label == label })?.present ?? false
    }
    func path(_ label: String) -> String {
        entries.first(where: { $0.label == label })?.path ?? "?"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Leads
// ─────────────────────────────────────────────────────────────────────────────

struct Lead {
    let rank: Int          // lower = more urgent
    let title: String
    let evidence: String
    let action: String
}

var leads: [Lead] = []
func addLead(rank: Int, _ title: String, evidence: String, action: String) {
    leads.append(Lead(rank: rank, title: title, evidence: evidence, action: action))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Malformed-line accounting for JSONL feeds
//
// A truncated tail line (the writer was mid-append) or a garbage line used to
// be dropped by a bare `guard let obj = ... else { return }`, so a feed that
// was 90% unparseable reported its 10% as if it were the whole story. Every
// JSONL reader now counts what it could not parse, the Sources table shows it,
// and a feed past the threshold is UNREADABLE rather than quietly thin.
// ─────────────────────────────────────────────────────────────────────────────

/// Cheap structural test for "this line is a complete JSON object". Used on the
/// hot trace path where parsing every line would cost more than the whole run.
func looksLikeCompleteJSONObject(_ d: Data) -> Bool {
    var start = d.startIndex, end = d.endIndex
    while start < end, d[start] == 0x20 || d[start] == 0x09 || d[start] == 0x0D { start = d.index(after: start) }
    while end > start {
        let prev = d.index(before: end)
        if d[prev] == 0x20 || d[prev] == 0x09 || d[prev] == 0x0D { end = prev } else { break }
    }
    guard start < end else { return false }
    return d[start] == 0x7B && d[d.index(before: end)] == 0x7D
}

/// THE GUARD. A source is unreadable when malformed lines are ≥10% of what it
/// holds, or when every line of a present, non-empty source is malformed.
func malformedRatioTooHigh(lines: Int, malformed: Int) -> Bool {
    guard lines > 0, malformed > 0 else { return false }
    if malformed == lines { return true }
    return Double(malformed) >= Double(lines) * 0.10
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Argument parsing
// ─────────────────────────────────────────────────────────────────────────────

var dataRootArg: String?
var personaRootArg: String?
var bridgeConfigRootArg: String?
var bridgeConfigDisabled = false
/// Machine-global state OUTSIDE the data root that is not a bridge lane — the
/// installed app bundle's `Info.plist` and the app's own preferences domain,
/// which are the ONLY places the update lane (SYS-14) persists anything. Same
/// hermeticity rule as the bridge lanes: read by default only when the data
/// root is a real install root, and switchable off entirely.
var machineStateDisabled = false
/// Pinned wall clock. `Date()` moves between two runs over the same frozen
/// bytes, so every "Nd ago" and every window boundary moves with it and a
/// whole-report byte-comparison can never be made. `--now` freezes it. It is
/// read-only and always DECLARED in the report header, so a pinned run can
/// never be mistaken for a live one.
var nowOverride: Date?
var days = 7
var outPath: String?

var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    let a = argv[ai]
    switch a {
    case "--data-root":
        ai += 1
        guard ai < argv.count else { fail("--data-root requires a path") }
        dataRootArg = argv[ai]
    case "--persona-root":
        ai += 1
        guard ai < argv.count else { fail("--persona-root requires a path") }
        personaRootArg = argv[ai]
    case "--bridge-config-root":
        ai += 1
        guard ai < argv.count else { fail("--bridge-config-root requires a path") }
        bridgeConfigRootArg = argv[ai]
    case "--no-bridge-config":
        bridgeConfigDisabled = true
    case "--no-machine-state":
        machineStateDisabled = true
    case "--now":
        ai += 1
        guard ai < argv.count else { fail("--now requires an ISO-8601 instant") }
        guard let d = parseTimestamp(argv[ai]) else {
            fail("--now could not be parsed as an instant: \(argv[ai])")
        }
        nowOverride = d
    case "--days":
        ai += 1
        guard ai < argv.count, let d = Int(argv[ai]), d > 0 else { fail("--days requires a positive integer") }
        days = d
    case "--out":
        ai += 1
        guard ai < argv.count else { fail("--out requires a path") }
        outPath = argv[ai]
    case "-h", "--help":
        print("""
        usage: swift script/agent_instrument.swift [--data-root <path>] [--days N] [--out <file.md>]
                                                  [--persona-root <path>]
                                                  [--bridge-config-root <path> | --no-bridge-config]

          --data-root  NativeAgent data root to inspect (default: ./data if present)
          --persona-root  persona doc dir holding GROWTH.md (trait dials); default
                       <data-root>/../persona. Read-only, outside the data root.
          --bridge-config-root  where the agent wake lanes live — the same
                       `configRootOverride` the app's own bridge tools take
                       (`<root>/claude-bridge`, `<root>/codex-nativeagent-bridge`,
                       `<root>/omp-bridge`). Default `~/.config` when it exists.
                       Read-only, OUTSIDE the data root, so a frozen-root
                       determinism check should pass --no-bridge-config or point
                       this at a frozen copy.
          --no-bridge-config  do not read the bridge lanes at all. SYS-01 then
                       renders "not read" — never a zero.
          --no-machine-state  do not read machine-global update state (the
                       installed app bundle's Info.plist and the app's
                       preferences domain). SYS-14 then renders "not read".
                       Both are outside the data root and, like the bridge
                       lanes, are read by default only on a real install root.
          --now        pin the wall clock to this ISO-8601 instant instead of
                       "right now". For frozen-root determinism checks: two
                       runs over the same bytes can only be byte-compared when
                       the clock does not move between them. The pinned instant
                       is DECLARED in the report header.
          --days       report window in days (default: 7)
          --out        also write the markdown report to this file
                       (REFUSED if it resolves inside the data root — the
                        instrument never writes into Agent's stores)
        """)
        exit(0)
    default:
        fail("unknown argument: \(a)")
    }
    ai += 1
}

let fm = FileManager.default
let cwd = fm.currentDirectoryPath

func absolutize(_ p: String) -> String {
    let expanded = (p as NSString).expandingTildeInPath
    let abs = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
    return (abs as NSString).standardizingPath
}

let resolvedDataRoot: String = {
    if let r = dataRootArg { return absolutize(r) }
    let def = absolutize("./data")
    if fm.fileExists(atPath: def) { return def }
    fail("no --data-root given and ./data does not exist")
}()

var isDir: ObjCBool = false
guard fm.fileExists(atPath: resolvedDataRoot, isDirectory: &isDir), isDir.boolValue else {
    fail("data root is not a directory: \(resolvedDataRoot)")
}

/// Machine-global readers are allowed only for the repo's live data root or
/// the app-support install root. Fixture roots stay hermetic.
let dataRootIsInstallRoot: Bool = {
    let real = [
        absolutize("./data"),
        absolutize("~/Library/Application Support/NativeAgent"),
    ]
    return real.contains(resolvedDataRoot)
}()

/// POSIX realpath(3) — the ONLY resolver that tells the truth on macOS.
/// Neither `NSString.resolvingSymlinksInPath` nor `URL.resolvingSymlinksInPath()`
/// gets you `/private/var/...`: both deliberately STRIP a leading `/private`
/// again, so a `$TMPDIR` path compared against them silently fails to match.
/// The directory enumerator, and the kernel, both use the realpath spelling.
func realPathOf(_ p: String) -> String? {
    guard let c = realpath(p, nil) else { return nil }
    defer { free(c) }
    return String(cString: c)
}

// Resolve symlinks so a symlinked --out can't sneak inside the data root.
let canonicalDataRoot = (resolvedDataRoot as NSString).resolvingSymlinksInPath
/// Every spelling of the data root a resolved path could legitimately carry.
let dataRootSpellings: Set<String> = Set([
    resolvedDataRoot,
    canonicalDataRoot,
    URL(fileURLWithPath: resolvedDataRoot).resolvingSymlinksInPath().path,
    realPathOf(resolvedDataRoot) ?? resolvedDataRoot,
])

func matchesDataRoot(_ candidate: String) -> Bool {
    if dataRootSpellings.contains(candidate) { return true }
    for r in dataRootSpellings where candidate.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return true }
    return false
}

func isInsideDataRoot(_ path: String) -> Bool {
    let abs = absolutize(path)
    // The path itself, when it already exists.
    for spelling in [(abs as NSString).resolvingSymlinksInPath, realPathOf(abs)].compactMap({ $0 })
    where matchesDataRoot(spelling) { return true }
    // And its parent: an --out file that does not exist yet has no resolvable
    // path of its own, but the directory it would land in does — and THAT is
    // where a symlink hop into the data root hides.
    let parent = (abs as NSString).deletingLastPathComponent
    for spelling in [(parent as NSString).resolvingSymlinksInPath, realPathOf(parent)].compactMap({ $0 })
    where matchesDataRoot(spelling) { return true }
    return false
}

if let out = outPath, isInsideDataRoot(out) {
    fail("""
    REFUSED: --out "\(out)" resolves inside the data root (\(canonicalDataRoot)).
             This instrument is read-only on Agent's stores and will not write there.
    """)
}

// Temp workspace for sqlite copies — never inside the data root.
let workDir = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("agent_instrument-\(ProcessInfo.processInfo.processIdentifier)")
/// The same path with the pid elided. THE REPORT ONLY EVER PRINTS THIS ONE.
/// The scratch dir is created per-process and deleted on exit, so its pid is
/// worthless to a reader — and it is the one token that would make two runs
/// over identical frozen bytes differ, which would cost the whole-report
/// determinism check the ability to exist. The real path still appears in the
/// stderr messages and in `fail()`, where it is actionable.
let workDirDisplay = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("agent_instrument-<pid>")
if isInsideDataRoot(workDir) {
    fail("REFUSED: temp dir \(workDir) resolves inside the data root")
}
do { try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true) }
catch { fail("cannot create temp workspace \(workDir): \(error)") }
defer { try? fm.removeItem(atPath: workDir) }

let now = nowOverride ?? Date()
let windowStart = now.addingTimeInterval(-Double(days) * 86400)
/// When available, provider/tool health describes the currently installed
/// executable rather than folding failures from earlier builds into its score.
/// The full retained history remains visible elsewhere in the report.
let installedBuildEpoch: Date? = {
    guard !machineStateDisabled, dataRootIsInstallRoot else { return nil }
    let bundles = [
        absolutize("/Applications/NativeAgent.app"),
        absolutize("~/Applications/NativeAgent.app"),
    ]
    for bundle in bundles where fm.fileExists(atPath: bundle) {
        let infoPath = (bundle as NSString).appendingPathComponent("Contents/Info.plist")
        guard let infoData = fm.contents(atPath: infoPath),
              let info = try? PropertyListSerialization.propertyList(
                  from: infoData, format: nil
              ) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String
        else { continue }
        let executablePath = (bundle as NSString)
            .appendingPathComponent("Contents/MacOS/\(executable)")
        if let modified = (try? fm.attributesOfItem(atPath: executablePath)[.modificationDate]) as? Date {
            return modified
        }
    }
    return nil
}()
let runtimeEvidenceStart = max(windowStart, installedBuildEpoch ?? windowStart)
let runtimeEvidenceLabel = installedBuildEpoch.map {
    "current installed build since \(stamp($0))"
} ?? "\(days)d window"
// Lane liveness needs history behind the window to answer "days since last non-zero".
let lookbackDays = days + 30
let lookbackStart = now.addingTimeInterval(-Double(lookbackDays) * 86400)

let sources = SourceRegistry()
func rootPath(_ rel: String) -> String { (resolvedDataRoot as NSString).appendingPathComponent(rel) }

/// Applies the malformed-line guard to one registered JSONL source: records the
/// counts, and on a breach marks the source unreadable and raises a lead.
func settleJSONLSource(_ label: String, lines: Int, malformed: Int) {
    sources.setParse(label, lines: lines, malformed: malformed)
    guard malformedRatioTooHigh(lines: lines, malformed: malformed) else { return }
    let pct = Double(malformed) / Double(lines) * 100
    let reason = "\(malformed) of \(lines) line(s) would not parse (\(fmt(pct, 1))%)"
    sources.markUnreadable(label, reason)
    addLead(rank: 3, "Source `\(mdCode(label))` is UNREADABLE — \(malformed)/\(lines) lines malformed",
            evidence: "`\(mdCode(label))`: \(reason). Its sections are skipped; no number is derived from "
                + "the surviving lines, because a feed this damaged cannot say what its good rows are a sample OF.",
            action: "Find the writer that truncates or corrupts this feed (an unflushed append, a crash mid-write, "
                + "a concurrent writer without a lock) before trusting any metric that reads it.")
}

/// Raises the matching lead for a sqlite store that could not be read. Same
/// contract as the JSONL guard: sections skipped, nothing rendered as zero.
func markStoreUnreadable(_ label: String, _ reason: String) {
    guard !sources.isUnreadable(label) else { return }
    sources.markUnreadable(label, reason)
    addLead(rank: 3, "Store `\(mdCode(label))` is UNREADABLE — \(mdCode(reason))",
            evidence: "`\(mdCode(label))`: \(mdCode(reason)). Every section that reads this store is skipped; "
                + "none of its counters are rendered, because \"0\" and \"we could not ask\" are different facts.",
            action: "Check the file is a real sqlite database, that /usr/bin/sqlite3 exists, and that the schema "
                + "still carries the tables this instrument queries. Until it reads clean, treat every derived "
                + "metric for this store as unknown, not as zero.")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - transactional SQLite snapshots (read-only source, private query copy)
// ─────────────────────────────────────────────────────────────────────────────

var copyLog: [String] = []

/// SQLite's backup API captures one consistent committed database, including
/// its WAL. Independent physical copies can mix generations even when they
/// pass quick_check. Never issue application queries against the live source.
func copySQLiteOnce(src: String, dest: String) throws {
    func failure(_ reason: String) -> NSError {
        NSError(domain: "agent_instrument", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    // Refuse an unreadable sidecar explicitly, including a stale sidecar that
    // SQLite might otherwise ignore. Retain the existing diagnostic contract.
    for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: src + suffix) {
        guard fm.isReadableFile(atPath: src + suffix) else { throw failure("sidecar \(suffix) copy failed: unreadable") }
    }
    var source: OpaquePointer?, destination: OpaquePointer?
    guard sqlite3_open_v2(src, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        if let source { sqlite3_close(source) }
        throw failure("read-only snapshot source unavailable")
    }
    defer { sqlite3_close(source) }
    guard sqlite3_open_v2(dest, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        if let destination { sqlite3_close(destination) }
        throw failure("snapshot destination unavailable")
    }
    defer { sqlite3_close(destination) }
    guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
        throw failure("transactional snapshot initialization failed")
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK else {
        throw failure("transactional snapshot unavailable (SQLite \(step)/\(finish)); source unchanged")
    }
}

/// Structural validation on the private snapshot. Transactional consistency
/// comes from sqlite3_backup, not from quick_check.
func integrityDetail(_ db: SQLiteCopy) -> String? {
    switch db.run("PRAGMA quick_check;") {
    case .failed(let r): return r
    case .ok(let rows):
        let verdict = rows.first?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if verdict.lowercased() == "ok" { return nil }
        return "PRAGMA quick_check returned \(verdict.isEmpty ? "no rows" : "\"\(String(verdict.prefix(200)))\"")"
    }
}

func copySQLite(label: String, relative: String) -> StoreState {
    let src = rootPath(relative)
    let present = sources.register(label, src, note: "copied before query (read-only rule)")
    guard present else { return .absent }
    if let attrs = try? fm.attributesOfItem(atPath: src), (attrs[.size] as? Int ?? 0) == 0 {
        let reason = "present but ZERO BYTES — not a live store"
        sources.note(label, reason)
        markStoreUnreadable(label, reason)
        return .unreadable(reason)
    }
    let dest = (workDir as NSString).appendingPathComponent((relative as NSString).lastPathComponent)

    var lastFailure = "unknown"
    // Two attempts handle transient SQLite contention without an unbounded wait.
    for attempt in 1...2 {
        do { try copySQLiteOnce(src: src, dest: dest) }
        catch {
            lastFailure = error.localizedDescription
            continue
        }
        let probe = SQLiteCopy(originalPath: src, copyPath: dest, label: label)
        let integrityFailure = integrityDetail(probe)
        // INTEGRITY GATE
        if let detail = integrityFailure {
            lastFailure = detail
            continue
        }
        copyLog.append("\(relative) → \((workDirDisplay as NSString).appendingPathComponent((dest as NSString).lastPathComponent))"
                       + (attempt > 1 ? " (copy retried \(attempt)×)" : "")
                       + " — PRAGMA quick_check: ok")
        sources.note(label, "copied before query (read-only rule); quick_check ok"
                     + (attempt > 1 ? " after \(attempt) copy attempt(s)" : ""))
        return .ok(SQLiteCopy(originalPath: src, copyPath: dest, label: label))
    }
    let reason = "copy/integrity gate failed after 2 attempt(s): \(lastFailure)"
    sources.note(label, "UNREADABLE — \(reason)")
    markStoreUnreadable(label, reason)
    return .unreadable(reason)
}

/// Called after a store's reads: any query failure retroactively condemns the
/// whole source, because a store that cannot answer one question has no
/// standing to have its other answers believed.
func settleStore(_ state: inout StoreState, _ label: String) {
    let condemnOnQueryFailure = true          // THE GUARD (mutation target)
    guard condemnOnQueryFailure, let db = state.handle, let r = db.failureReason else { return }
    state = .unreadable("query failed: \(r)")
    markStoreUnreadable(label, "query failed: \(r)")
}

var cognitionState = copySQLite(label: "cognition.sqlite", relative: "cognition/cognition.sqlite")
var memoryState = copySQLite(label: "memory.sqlite", relative: "memory/memory.sqlite")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Turn traces — the context lanes
// ─────────────────────────────────────────────────────────────────────────────

struct LaneStat {
    var observationsInWindow = 0
    var nonZeroInWindow = 0
    var sumInWindow: Double = 0
    var lastNonZeroAt: Date?
    var lastObservedAt: Date?
    var everObserved = false
    var source = ""
}

var lanes: [String: LaneStat] = [:]
func record(lane: String, value: Double, at ts: Date, source: String, inWindow: Bool) {
    var s = lanes[lane] ?? LaneStat()
    s.everObserved = true
    s.source = source
    if s.lastObservedAt == nil || ts > s.lastObservedAt! { s.lastObservedAt = ts }
    if value != 0, s.lastNonZeroAt == nil || ts > s.lastNonZeroAt! { s.lastNonZeroAt = ts }
    if inWindow {
        s.observationsInWindow += 1
        s.sumInWindow += value
        if value != 0 { s.nonZeroInWindow += 1 }
    }
    lanes[lane] = s
}

let turnTraceDir = rootPath("turn_traces")
let turnTracesPresent = sources.register("turn_traces/", turnTraceDir, note: "streamed read-only")

var traceFilesScanned: [String] = []
var traceLinesSeen = 0
var traceMalformedLines = 0
var summaryRowsWindow = 0
var snapshotRowsWindow = 0
var snapshotRowsTruncated = 0
var capsulePresentRows = 0
var capsuleBytes: [Double] = []
var recallRowValues: [Double] = []
var atomValues: [Double] = []
var memoryRecordValues: [Double] = []
var attentionAtomValues: [Double] = []
var modelCountsFromSnapshots: [String: Int] = [:]

// ── Turn speed: one record per turnId, assembled from five row kinds ─────────
//
//   turn.accepted   → the turn started (lifecycle milestone)
//   paired turn.accepted → turn.terminal timestamps = lifecycle wall clock
//   turn.terminal.payload.turnElapsedMs = engine clock; may exclude prebuilt context
//   context.summary → payload.totalMs + payload.stageMs.* = assembly breakdown
//   llm.call        → payload.durationMs / ttftMs = model time
//   tool.dispatch   → payload.durationMs on phase="end" = tool time
//
// Everything else (UI render, scheduling, the gaps between) is *unattributed*
// and reported as such — never folded into one of the named buckets.
struct TurnRecord {
    var surface = "(unlabeled)"
    var day = ""
    var startedAt: Date?
    var terminalPayloadMs: Double?
    var lifecycleElapsedMs: Double?
    var elapsedMs: Double? { lifecycleElapsedMs ?? terminalPayloadMs }
    var assemblyMs: Double?
    var modelMs: Double = 0
    var modelCalls = 0
    var firstTtftMs: Double?
    var toolMs: Double = 0
    var toolCalls = 0
    var toolFailures = 0
    var status: String?
}
var turns: [String: TurnRecord] = [:]
var turnRowsSeen = 0
/// Per-stage samples inside the window, keyed by the `stageMs.<name>` lane.
var stageSamples: [String: [Double]] = [:]
/// Every stage name ever seen in the lookback, even if always zero.
var stageNamesSeen: Set<String> = []
/// Capsule anatomy, parsed from the canonical `context.snapshot` cognitive
/// preview (with a legacy truncated-preview fallback for older trace rows).
var fingerprintWordCounts: [String: Int] = [:]
var capsuleLineCounts: [String: Int] = [:]      // "- Inner:" etc → turns carrying it
var capsuleParsedTurns = 0
var posturesSeen: [String: Int] = [:]

func touchTurn(_ id: String, _ ts: Date, _ surface: String?, _ body: (inout TurnRecord) -> Void) {
    var r = turns[id] ?? TurnRecord()
    if let s = surface, s != "(unlabeled)" { r.surface = s }
    if r.day.isEmpty { r.day = dayKeyFmt.string(from: ts) }
    if r.startedAt == nil || ts < r.startedAt! { r.startedAt = ts }
    body(&r)
    turns[id] = r
}

/// Pulls the fingerprint words and the gated capsule lines out of one
/// `cognitivePreview` blob. The blob is a JSON *string* inside an already
/// truncated payload, so a missing tail is "unparsed", never "absent".
func recordCapsule(preview: String) {
    capsuleParsedTurns += 1
    var fingerprintWordsInCapsule: Set<String> = []
    let unescaped = preview
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\u2014", with: "—")
        .replacingOccurrences(of: "\\\"", with: "\"")
    let lines = unescaped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (i, l) in lines.enumerated() {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t == "How you feel:" {
            // The headline is the next non-empty line: bare comma-separated words.
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j < lines.count {
                let headline = lines[j].trimmingCharacters(in: .whitespaces)
                if !headline.isEmpty, !headline.hasPrefix("-"), !headline.hasPrefix("[") {
                    capsuleLineCounts["fingerprint"] = (capsuleLineCounts["fingerprint"] ?? 0) + 1
                    for w in headline.split(separator: ",") {
                        let word = w.trimmingCharacters(in: .whitespaces)
                        if !word.isEmpty, word.count <= 24 { fingerprintWordsInCapsule.insert(word) }
                    }
                }
            }
        }
        for marker in ["- Inner:", "- Body:", "- Settling:", "- Since:"] where t.hasPrefix(marker) {
            capsuleLineCounts[marker, default: 0] += 1
        }
        if t.hasPrefix("- Sound:") {
            // Sound has two distinct producers: the healthy exemplar echo and
            // the cadence-exempt repeated-word warning.  Folding them into a
            // single rate makes the latter look permanently noisy.
            let soundKind = t.contains("same words keep echoing")
                ? "- Sound: rut awareness"
                : "- Sound: exemplar echo"
            capsuleLineCounts[soundKind, default: 0] += 1
        }
        if t.hasPrefix("posture:") {
            let v = t.dropFirst("posture:".count).split(separator: " ").first.map(String.init) ?? "(none)"
            posturesSeen[v, default: 0] += 1
        }
    }
    for word in fingerprintWordsInCapsule {
        fingerprintWordCounts[word, default: 0] += 1
    }
}

/// `TurnContextSnapshotTrace` writes the cognitive preview as arbitrary
/// character chunks. Reassembly must be lossless: inserting a separator can
/// split a marker exactly where the tracer split a 1,800-character chunk.
/// Older trace rows could carry it only inside `_preview`, so callers retain
/// that fallback without making it the primary production path.
func canonicalCognitivePreview(from value: Any?) -> String? {
    if let chunks = value as? [Any] {
        let strings = chunks.compactMap { $0 as? String }
        return strings.isEmpty ? nil : strings.joined()
    }
    return nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WAVE 3 — turn-trace KIND VOCABULARY and lifecycle pairing
//
// The feed `turn_traces/<day>.jsonl` was graded here by its context lanes, its
// turn-speed rows and its malformed-line ratio. What was NEVER graded is the
// feed's own VOCABULARY: which kinds the codebase can emit, which of them
// actually appear, and whether the six lifecycle milestones pair up per turn.
//
// Why that matters (docs/evals/ledger.json, fence `feeds`):
//   • 2835 `context.ready` rows/window and NOTHING read them. A milestone that
//     stops firing does not raise anything — the rows just stop, and "stopped"
//     and "never happened" look identical from every other section.
//   • `turn.reaction`, `thinking.delta` and `context.attention.late-completion`
//     have emitters in the tree and ZERO rows in a 37-day lookback. From a
//     source read you cannot tell an unreachable emit from a quiet lane. The
//     honest instrument answer is a RECHABILITY TABLE: every declared kind gets
//     a row even at zero, so a producer that goes silent is NAMED rather than
//     merely absent.
//   • `stream.tick` alone is ~39% of the feed. It is the largest consumer of
//     the retention budget, so it silently evicts the small load-bearing kinds
//     — and nothing bounds its per-turn cadence.
//
// Three rules, same as every reader above: absent is not zero, unreadable is
// not zero, and a number that could not be derived is not rendered.
// ─────────────────────────────────────────────────────────────────────────────

/// Cheap byte-level read of one `"key": "value"` STRING out of a raw JSONL line
/// WITHOUT paying `JSONSerialization` on it.
///
/// This exists because the vocabulary census has to see EVERY row in
/// `turn_traces/`, and `stream.tick` alone is ~39% of that feed on the live
/// root. A census too expensive to run is a census nobody runs.
///
/// Deliberately conservative — it is only ever used for keys the tracer writes
/// at the TOP level (`kind`, `ts`, `turnId`), it returns nil for anything that
/// is not a plain quoted string, and it returns nil (never a half-unescaped
/// guess) when the value contains an escape. Every nil is counted, and the
/// scanner is CROSS-CHECKED against the real parser on every row this file
/// parses anyway (`traceScanDisagreements`) — a scanner that silently drifts
/// from the parser would poison the whole section.
func rawJSONStringValue(_ line: Data, forKey key: String) -> String? {
    let needle = bytes("\"" + key + "\"")
    guard !needle.isEmpty, line.count > needle.count else { return nil }
    return line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
        let b = raw.bindMemory(to: UInt8.self)
        let limit = b.count - needle.count
        var i = 0
        var start = -1
        while i <= limit {
            if b[i] == needle[0] {
                var j = 1
                while j < needle.count && b[i + j] == needle[j] { j += 1 }
                if j == needle.count { start = i + needle.count; break }
            }
            i += 1
        }
        guard start >= 0 else { return nil }
        var k = start
        while k < b.count, b[k] == 0x20 || b[k] == 0x09 { k += 1 }
        guard k < b.count, b[k] == 0x3A else { return nil }          // ':'
        k += 1
        while k < b.count, b[k] == 0x20 || b[k] == 0x09 { k += 1 }
        guard k < b.count, b[k] == 0x22 else { return nil }          // opening '"'
        k += 1
        var out: [UInt8] = []
        out.reserveCapacity(48)
        while k < b.count {
            let c = b[k]
            if c == 0x5C { return nil }                              // escape → not cheap-readable
            if c == 0x22 { return String(decoding: out, as: UTF8.self) }
            if out.count >= 256 { return nil }                       // bounded, never a blob
            out.append(c)
            k += 1
        }
        return nil
    }
}

/// Cheap byte-level read of one `"key": 123` INTEGER out of a raw JSONL line,
/// the numeric sibling of `rawJSONStringValue` above. Same contract: hot-path
/// only, conservative (nil for anything that is not a plain non-negative
/// integer literal), used for keys with a single unambiguous spelling on the
/// line (`chunks` appears only inside a `stream.tick` payload).
func rawJSONIntValue(_ line: Data, forKey key: String) -> Int? {
    let needle = bytes("\"" + key + "\"")
    guard !needle.isEmpty, line.count > needle.count else { return nil }
    return line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
        let b = raw.bindMemory(to: UInt8.self)
        let limit = b.count - needle.count
        var i = 0
        var start = -1
        while i <= limit {
            if b[i] == needle[0] {
                var j = 1
                while j < needle.count && b[i + j] == needle[j] { j += 1 }
                if j == needle.count { start = i + needle.count; break }
            }
            i += 1
        }
        guard start >= 0 else { return nil }
        var k = start
        while k < b.count, b[k] == 0x20 || b[k] == 0x09 { k += 1 }
        guard k < b.count, b[k] == 0x3A else { return nil }          // ':'
        k += 1
        while k < b.count, b[k] == 0x20 || b[k] == 0x09 { k += 1 }
        var value = 0
        var digits = 0
        while k < b.count, b[k] >= 0x30, b[k] <= 0x39 {              // '0'-'9'
            if digits >= 15 { return nil }                           // bounded, never a blob
            value = value * 10 + Int(b[k] - 0x30)
            digits += 1
            k += 1
        }
        return digits > 0 ? value : nil
    }
}

/// The DECLARED turn-trace kind vocabulary: every kind the codebase can put on
/// the turn-trace bus, with the emitter that puts it there.
///
/// This list is a CONTRACT, not documentation. A kind that appears in the feed
/// and is not here is vocabulary DRIFT (an emitter landed and nobody decided
/// what reads it); a kind that is here and has no row in the lookback is an
/// INERT lane (either the emit is unreachable or the producer went quiet).
/// Both are named below; neither can be inferred from a source read alone.
let declaredTraceKinds: [String: String] = [
    // The six FC0 lifecycle milestones — ContextStageTrace.swift:79-116.
    "turn.accepted": "ContextStageTrace.swift:80 TurnLifecycleMilestone",
    "context.ready": "ContextStageTrace.swift:81 TurnLifecycleMilestone",
    "provider.requestStarted": "ContextStageTrace.swift:82 TurnLifecycleMilestone",
    "provider.firstDelta": "ContextStageTrace.swift:83 TurnLifecycleMilestone",
    "surface.outputEnqueued": "ContextStageTrace.swift:84 TurnLifecycleMilestone",
    "surface.firstRender": "ContextStageTrace.swift:85 TurnLifecycleMilestone",
    // Assembly / context lanes.
    "assembly.stage": "TurnTraceBus.fire (assembly)",
    "context.stage": "ContextStageTrace.swift:290 emitStage",
    "context.summary": "ChatOrchestration+TurnEngine.swift",
    "context.snapshot": "TurnContextSnapshotTrace.swift",
    "context.compact": "ChatOrchestration+SessionHistory.swift",
    "context.history.summary": "ChatOrchestration+SessionHistory.swift",
    "context.attention.late-completion": "ChatOrchestration+TurnEngine.swift:1102",
    // Provider / stream.
    "llm.call": "ChatOrchestration streaming + LLMCallTelemetry",
    "stream.tick": "ChatOrchestration+Streaming.swift:554",
    "thinking.delta": "LLMClient+AnthropicOAuthDirectAdapter.swift:211",
    // Turn outcome.
    "turn.plan": "TurnPlanning.swift:595 (bus, turn.plan.v1)",
    "turn.terminal": "ChatOrchestrationClient+StructuredChat.swift",
    "turn.failed": "ChatOrchestrationClient+TextCompatibility.swift:772/:802",
    "turn.reaction": "ChatOrchestrationClient+MessagePersistence.swift:846",
    // Tools / effects / organism.
    "tool.dispatch": "SwiftToolDispatcher",
    "file.touch": "SwiftToolDispatcher (file effects)",
    "memory.commit": "SwiftToolDispatcher+MemoryTools.swift:280",
    "motor.state": "NativeCognitionRuntime+Events.swift:223 (motor.action.read-model.v1)",
    "pump.distress": "TurnTraceBus.fire (cognition pump)",
    "pump.integration": "TurnTraceBus.fire (cognition pump)",
    "vision.attachment_unsupported": "TurnTraceBus.fire (vision)",
]

/// Kinds this reader FULLY parses (the low-volume ones whose payload carries
/// the pairing evidence). `stream.tick` is deliberately NOT here: it is read on
/// the cheap path, because parsing 39% of the feed to count ticks would cost
/// more than the rest of the run.
let wave3ParsedKinds: Set<String> = [
    "context.ready", "provider.requestStarted", "provider.firstDelta",
    "surface.outputEnqueued", "surface.firstRender",
    "context.stage", "context.attention.late-completion",
    "turn.failed", "turn.plan", "memory.commit", "motor.state",
]

/// Terminal motor phases — mirrors `MotorActionPhase.isTerminal`
/// (Modules/NativeAgentCore/Sources/PersistenceCore/MotorActionReadModel.swift:24).
/// `blocked` is deliberately NOT terminal there, and is not here either: a
/// blocked action is still open, and calling it finished would hide exactly the
/// half-open lane this check exists to find.
let motorTerminalPhases: Set<String> = ["succeeded", "failed", "cancelled", "expired"]
let motorDeclaredPhases: Set<String> = [
    "proposed", "ready", "running", "awaiting_approval", "awaiting_human",
    "waiting_external", "verifying", "blocked", "succeeded", "failed",
    "cancelled", "expired", "unknown",
]

/// `UnifiedPolicyOutcome` (TrustCenter/UnifiedPolicyDecision.swift:4) — the only
/// three values a turn.plan policy decision can carry.
let declaredPolicyOutcomes: Set<String> = ["allow", "confirm", "deny"]

// Census (the whole lookback, so a lane that died last week is still dated).
var traceKindLookback: [String: Int] = [:]
var traceKindWindow: [String: Int] = [:]
var traceKindNewest: [String: Date] = [:]
var traceKindUnscannable = 0            // rows whose `kind` the cheap scan could not read
var traceScanDisagreements = 0          // cheap scan vs JSONSerialization, on rows we parse anyway
var traceScanCrossChecked = 0

/// Per-turn lifecycle evidence, window only. Bounded by the number of turns in
/// the window; the tick gap list is capped per turn so one pathological stream
/// cannot grow this without bound.
struct TurnLifecycle {
    var surface = "(unlabeled)"
    var accepted: Date?
    var readyRows = 0
    var readyFirst: Date?
    var requestStarted: Date?
    var firstDelta: Date?
    var outputEnqueued = 0
    var firstRender = 0
    var terminal: Date?
    var terminalStatus: String?
    var failedRows = 0
    var llmCalls = 0
    var llmWithTtft = 0
    var ticks = 0
    var lastTick: Date?
    var lastTickChunks: Int?
    var tickGaps: [Double] = []
    var interRoundGaps: [Double] = []
    var lateCompletion = 0
    var attentionAdmissionMs: Double?
}
var lifecycles: [String: TurnLifecycle] = [:]
let tickGapCapPerTurn = 512

func touchLifecycle(_ id: String, _ surface: String?, _ body: (inout TurnLifecycle) -> Void) {
    var r = lifecycles[id] ?? TurnLifecycle()
    if let s = surface, !s.isEmpty, s != "(unlabeled)" { r.surface = s }
    body(&r)
    lifecycles[id] = r
}

var traceStageNames: [String: Int] = [:]
var traceStageRowsWindow = 0
var turnFailedReasons: [String: Int] = [:]
var turnFailedRowsWindow = 0
var motorActionLastPhase: [String: (phase: String, domain: String, ts: Date)] = [:]
var motorPhaseCounts: [String: Int] = [:]
var motorRowsWindow = 0
var motorUndeclaredPhases: [String: Int] = [:]
var memoryCommitTraceRows = 0
var turnPlanTraceRows = 0
var turnPlanTraceFieldCounts: Set<Int> = []
var traceWave3Unparsed = 0

// Filled from `traces/events.jsonl` further down — the SAME two kinds written
// to a SECOND feed with a DIFFERENT payload shape. A consumer written against
// one silently reads nothing from the other, so the two are compared here
// rather than each being reported alone.
var memoryCommitEventRows = 0
var turnPlanEventRows = 0
var turnPlanEventFieldCounts: Set<Int> = []
var turnPlanPolicyOutcomes: [String: Int] = [:]
var turnPlanPermissionLevels: [String: Int] = [:]
var turnPlanNullPolicy = 0

// Per-DAY readability of the trace feed. `TurnTraceReplayReader.read` returns
// `([], 0)` when the day file cannot be read (TurnInspectorModel.swift:429-432),
// so an unreadable day is byte-identical to a day on which no turns happened.
// This instrument refuses that: `opened` is a separate column from `rows`.
struct TraceDayRead {
    var name: String
    var opened = false
    var rows = 0
    var malformed = 0
    var bytes: Int64 = 0
}
var traceDays: [TraceDayRead] = []
var traceDayOpenFailures: [String] = []

/// Guard flag for the per-day readability rule, hoisted so a mutation test can
/// switch it off and prove the assertion that depends on it goes red. `false`
/// restores the OLD behaviour — a day file that cannot be opened is skipped
/// silently and never appears in the table at all, which is exactly the shape
/// the live reader still has.
let traceDayOpenGuard = true

/// NAMED BOUNDS for the streaming lane. These are asserted envelopes, not
/// measurements: `stream.tick` is the largest consumer of the feed's retention
/// budget, so a tick storm silently evicts the small load-bearing kinds. The
/// gap bound applies to INTRA-ROUND gaps only — ticks within one provider
/// stream. It grades chunk-delivery evenness, nothing more: the ticker is
/// chunk-gated (it fires only when a chunk arrives), so a zero-chunk freeze
/// emits no tick at all and is structurally invisible to this metric.
let streamTickPerTurnCeiling = 2000
let streamTickGapCeilingMs = 5000.0

if turnTracesPresent {
    let needleSummary = bytes("\"context.summary\"")
    let needleSnapshot = bytes("\"context.snapshot\"")
    let needleTerminal = bytes("\"turn.terminal\"")
    let needleAccepted = bytes("\"turn.accepted\"")
    let needleLLM = bytes("\"llm.call\"")
    // Match the KIND value, never a `"key":"value"` pair: the tracer writes
    // `"phase": "end"` WITH a space, so a needle spelled `"phase":"end"` matches
    // nothing and tool time silently reads 0 — the exact bug class this tool
    // exists to catch, found in its own first draft. Phase is filtered after
    // parsing, where whitespace cannot lie.
    let needleToolEnd = bytes("\"tool.dispatch\"")
    let files = ((try? fm.contentsOfDirectory(atPath: turnTraceDir)) ?? [])
        .filter { $0.hasSuffix(".jsonl") }
        .sorted()
    for name in files {
        let dayString = String(name.dropLast(6))            // strip ".jsonl"
        guard let day = dayKeyFmt.date(from: dayString) else { continue }
        // Keep a day whose 24h span can overlap the lookback window.
        guard day.addingTimeInterval(86400) >= lookbackStart else { continue }
        let path = (turnTraceDir as NSString).appendingPathComponent(name)
        // PER-DAY READABILITY. A day file that is present and cannot be opened
        // used to be `continue`d silently, which is the very defect the live
        // reader has (`TurnTraceReplayReader.read` returns `([], 0)` on a failed
        // read, TurnInspectorModel.swift:429-432): an unreadable day and a day
        // with no turns render identically. Here they never can — `opened` is
        // its own column, and a failure raises a lead.
        var dayRead = TraceDayRead(name: name)
        dayRead.bytes = Int64((try? fm.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0) ?? 0)
        guard let stream = LineStream(path: path) else {
            guard traceDayOpenGuard else { continue }     // the old silent skip
            traceDayOpenFailures.append(name)
            traceDays.append(dayRead)
            continue
        }
        dayRead.opened = true
        traceFilesScanned.append(name)
        stream.forEachLine { line in
            dayRead.rows += 1
            // Malformed accounting on the HOT path: parsing every line of a
            // multi-MB trace would cost more than the whole run, so the cheap
            // structural test carries it (a truncated tail line is the shape
            // that actually occurs), and lines that pass the byte-prefilter but
            // still fail to parse are counted properly below.
            traceLinesSeen += 1
            guard looksLikeCompleteJSONObject(line) else {
                traceMalformedLines += 1
                dayRead.malformed += 1
                return
            }

            // ── WAVE 3: kind census on the CHEAP path ───────────────────────
            // Every row is counted by kind here — including the ~39% that are
            // `stream.tick` — using a byte scan instead of a JSON parse. The
            // census is what turns "kind X has no rows" from an absence into a
            // NAMED inert lane below.
            let scannedKind = rawJSONStringValue(line, forKey: "kind")
            let scannedTS = (rawJSONStringValue(line, forKey: "ts")
                             ?? rawJSONStringValue(line, forKey: "createdAt")).flatMap(parseTimestamp)
            if let k = scannedKind {
                traceKindLookback[k, default: 0] += 1
                if let t = scannedTS {
                    traceKindNewest[k] = newer(traceKindNewest[k], t)
                    if t >= windowStart { traceKindWindow[k, default: 0] += 1 }
                }
            } else {
                traceKindUnscannable += 1
            }
            // `stream.tick` cadence, window only, on the cheap path.
            //
            // ROUND ATTRIBUTION: the emitter's ticker state (`lastTickNs`,
            // `chunkIndex`) is local to ONE streamTurn call, and the tool loop
            // calls streamTurn once PER provider round (ChatOrchestration+
            // Streaming.swift:321-326, :467-477). So a turn's ticks span
            // several streams, and the wall gap between the last tick of round
            // N and the first tick of round N+1 is tool dispatch + next-round
            // TTFT — NOT streaming cadence. The boundary is visible in the
            // payload itself: the first tick of every stream fires on its
            // first chunk (`lastTickNs` starts at 0), so `chunks` is 1 there,
            // while WITHIN a stream `chunks` strictly increases between ticks.
            // A non-increasing `chunks` therefore marks a new round, and that
            // gap is bucketed separately instead of poisoning the cadence p95.
            // An unreadable `chunks` (old rows without the field) falls back
            // to the old single-bucket behaviour rather than guessing.
            if scannedKind == "stream.tick", let t = scannedTS, t >= windowStart,
               let tid = rawJSONStringValue(line, forKey: "turnId") {
                let chunks = rawJSONIntValue(line, forKey: "chunks")
                touchLifecycle(tid, rawJSONStringValue(line, forKey: "surface")) { r in
                    r.ticks += 1
                    if let last = r.lastTick {
                        let gapMs = max(0, t.timeIntervalSince(last) * 1000)
                        let newRound = (chunks ?? Int.max) <= (r.lastTickChunks ?? 0)
                        if newRound {
                            if r.interRoundGaps.count < tickGapCapPerTurn {
                                r.interRoundGaps.append(gapMs)
                            }
                        } else if r.tickGaps.count < tickGapCapPerTurn {
                            r.tickGaps.append(gapMs)
                        }
                    }
                    r.lastTick = t
                    r.lastTickChunks = chunks
                }
            }
            // The low-volume kinds whose PAYLOAD carries the evidence.
            if let k = scannedKind, wave3ParsedKinds.contains(k),
               let t = scannedTS, t >= windowStart {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    // Cross-check: the cheap scanner must agree with the real
                    // parser on every row both of them see. A scanner that
                    // drifts would poison the census invisibly.
                    traceScanCrossChecked += 1
                    if (obj["kind"] as? String) != k { traceScanDisagreements += 1 }
                    let payload = (obj["payload"] as? [String: Any]) ?? [:]
                    let tid = obj["turnId"] as? String
                    let rowSurface = obj["surface"] as? String
                    switch k {
                    case "context.ready":
                        if let tid { touchLifecycle(tid, rowSurface) { r in
                            r.readyRows += 1
                            if r.readyFirst == nil || t < r.readyFirst! { r.readyFirst = t }
                        } }
                    case "provider.requestStarted":
                        if let tid { touchLifecycle(tid, rowSurface) { r in
                            if r.requestStarted == nil || t < r.requestStarted! { r.requestStarted = t }
                        } }
                    case "provider.firstDelta":
                        if let tid { touchLifecycle(tid, rowSurface) { r in
                            if r.firstDelta == nil || t < r.firstDelta! { r.firstDelta = t }
                        } }
                    case "surface.outputEnqueued":
                        if let tid { touchLifecycle(tid, rowSurface) { r in r.outputEnqueued += 1 } }
                    case "surface.firstRender":
                        if let tid { touchLifecycle(tid, rowSurface) { r in r.firstRender += 1 } }
                    case "context.stage":
                        traceStageRowsWindow += 1
                        traceStageNames[(payload["stage"] as? String) ?? "(no stage field)", default: 0] += 1
                    case "context.attention.late-completion":
                        if let tid { touchLifecycle(tid, rowSurface) { r in r.lateCompletion += 1 } }
                    case "turn.failed":
                        turnFailedRowsWindow += 1
                        turnFailedReasons[(payload["reason"] as? String) ?? "(no reason field)", default: 0] += 1
                        if let tid { touchLifecycle(tid, rowSurface) { r in r.failedRows += 1 } }
                    case "turn.plan":
                        turnPlanTraceRows += 1
                        turnPlanTraceFieldCounts.insert(payload.count)
                    case "memory.commit":
                        memoryCommitTraceRows += 1
                    case "motor.state":
                        motorRowsWindow += 1
                        let phase = (payload["phase"] as? String) ?? "(no phase field)"
                        motorPhaseCounts[phase, default: 0] += 1
                        if !motorDeclaredPhases.contains(phase) {
                            motorUndeclaredPhases[phase, default: 0] += 1
                        }
                        if let id = payload["actionIdentity"] as? String {
                            if let prev = motorActionLastPhase[id], prev.ts > t { break }
                            motorActionLastPhase[id] = (
                                phase,
                                (payload["domain"] as? String) ?? "(no domain field)",
                                t
                            )
                        }
                    default:
                        break
                    }
                } else {
                    traceWave3Unparsed += 1
                }
            }

            let isSummary = contains(line, needleSummary)
            let isSnapshot = isSummary ? false : contains(line, needleSnapshot)
            let isTerminal = (isSummary || isSnapshot) ? false : contains(line, needleTerminal)
            let isAccepted = (isSummary || isSnapshot || isTerminal) ? false : contains(line, needleAccepted)
            let isLLM = (isSummary || isSnapshot || isTerminal || isAccepted) ? false : contains(line, needleLLM)
            let isToolEnd = (isSummary || isSnapshot || isTerminal || isAccepted || isLLM)
                ? false : contains(line, needleToolEnd)
            guard isSummary || isSnapshot || isTerminal || isAccepted || isLLM || isToolEnd else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                traceMalformedLines += 1
                return
            }
            guard let kind = obj["kind"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { return }
            guard let ts = (obj["ts"] as? String).flatMap(parseTimestamp) else { return }
            guard ts >= lookbackStart else { return }
            let inWindow = ts >= windowStart
            let turnId = obj["turnId"] as? String
            let rowSurface = obj["surface"] as? String

            // ── Turn-speed rows (window only; the lookback exists for lane dating) ──
            if inWindow, let tid = turnId {
                switch kind {
                case "turn.accepted":
                    turnRowsSeen += 1
                    touchTurn(tid, ts, rowSurface) { _ in }
                    touchLifecycle(tid, rowSurface) { r in
                        if r.accepted == nil || ts < r.accepted! { r.accepted = ts }
                    }
                case "turn.terminal":
                    turnRowsSeen += 1
                    touchTurn(tid, ts, rowSurface) { r in
                        if let e = (payload["turnElapsedMs"] as? NSNumber)?.doubleValue { r.terminalPayloadMs = e }
                        if let s = payload["status"] as? String { r.status = s }
                    }
                    touchLifecycle(tid, rowSurface) { r in
                        r.terminal = newer(r.terminal, ts)
                        if let s = payload["status"] as? String { r.terminalStatus = s }
                    }
                case "llm.call":
                    turnRowsSeen += 1
                    touchTurn(tid, ts, (payload["surface"] as? String) ?? rowSurface) { r in
                        if let d = (payload["durationMs"] as? NSNumber)?.doubleValue {
                            r.modelMs += d
                            r.modelCalls += 1
                        }
                        if let t = (payload["ttftMs"] as? NSNumber)?.doubleValue {
                            if r.firstTtftMs == nil || t < r.firstTtftMs! { r.firstTtftMs = t }
                        }
                    }
                    touchLifecycle(tid, (payload["surface"] as? String) ?? rowSurface) { r in
                        r.llmCalls += 1
                        if (payload["ttftMs"] as? NSNumber) != nil { r.llmWithTtft += 1 }
                    }
                case "tool.dispatch":
                    guard (payload["phase"] as? String) == "end" else { return }
                    turnRowsSeen += 1
                    touchTurn(tid, ts, rowSurface) { r in
                        if let d = (payload["durationMs"] as? NSNumber)?.doubleValue {
                            r.toolMs += d
                            r.toolCalls += 1
                        }
                        if (payload["status"] as? String) == "failed" { r.toolFailures += 1 }
                    }
                default:
                    break
                }
            }
            guard isSummary || isSnapshot else { return }

            if kind == "context.summary" {
                if let tid = turnId, inWindow,
                   let total = (payload["totalMs"] as? NSNumber)?.doubleValue {
                    touchTurn(tid, ts, rowSurface) { r in r.assemblyMs = total }
                }
                if let stages = payload["stageMs"] as? [String: Any] {
                    for (name, v) in stages {
                        stageNamesSeen.insert(name)
                        guard inWindow, let d = (v as? NSNumber)?.doubleValue else { continue }
                        stageSamples[name, default: []].append(d)
                    }
                }
                if inWindow { summaryRowsWindow += 1 }
                var flat: [String: Double] = [:]
                flattenNumeric(payload, prefix: "", into: &flat)
                for (k, v) in flat {
                    record(lane: k, value: v, at: ts, source: "context.summary", inWindow: inWindow)
                }
                if inWindow {
                    if let c = flat["counts.budget.recallRowLimit"] { recallRowValues.append(c) }
                    if let c = flat["counts.contextFlow.selectedAtoms"] { atomValues.append(c) }
                    if let c = flat["counts.contextFlow.memoryRecords"] { memoryRecordValues.append(c) }
                    if let c = flat["counts.contextFlow.attentionWorkingAtoms"] { attentionAtomValues.append(c) }
                }
            } else if kind == "context.snapshot" {
                if inWindow {
                    snapshotRowsWindow += 1
                    if let m = payload["model"] as? String { modelCountsFromSnapshots[m, default: 0] += 1 }
                    if (payload["_truncated"] as? Bool) == true { snapshotRowsTruncated += 1 }
                }
                var flat: [String: Double] = [:]
                for (k, v) in payload where k != "_preview" {
                    flattenNumeric(v, prefix: "snapshot." + k, into: &flat)
                }
                // Production shape: TurnContextSnapshotTrace writes this as a
                // direct `[String]` payload field.  Read it before considering
                // the legacy truncated `_preview` representation.
                let directCognitivePreview = canonicalCognitivePreview(from: payload["cognitivePreview"])
                if inWindow, let directCognitivePreview,
                   directCognitivePreview.contains("[CognitiveSubstrate]") {
                    recordCapsule(preview: directCognitivePreview)
                }
                if let preview = payload["_preview"] as? String {
                    for (k, v) in shallowScalars(fromTruncatedJSONObject: preview) {
                        flat["snapshot._preview." + k] = v
                    }
                    // The capsule the model actually received rides inside the
                    // preview as a doubly-encoded string. Slice it out by key
                    // marker; a clipped tail simply yields fewer lines.
                    if inWindow, directCognitivePreview == nil,
                       let start = preview.range(of: "\"cognitivePreview\"") {
                        var chunk = preview[start.upperBound...]
                        for endKey in ["\"cognitiveRedactedChars\"", "\"cognitiveTruncated\"", "\"containsCognitiveSubstrate\""] {
                            if let e = chunk.range(of: endKey) { chunk = chunk[..<e.lowerBound] }
                        }
                        if chunk.contains("[CognitiveSubstrate]") { recordCapsule(preview: String(chunk)) }
                    }
                }
                for (k, v) in flat {
                    record(lane: k, value: v, at: ts, source: "context.snapshot", inWindow: inWindow)
                }
                if inWindow {
                    if let b = flat["snapshot._preview.cognitiveCapsuleBytes"] {
                        capsuleBytes.append(b)
                        if b > 0 { capsulePresentRows += 1 }
                    } else if let c = flat["snapshot._preview.containsCognitiveSubstrate"], c > 0 {
                        capsulePresentRows += 1
                    }
                }
            }
        }
        traceDays.append(dayRead)
    }
    sources.setRows("turn_traces/", summaryRowsWindow + snapshotRowsWindow)
    sources.note("turn_traces/",
                 "streamed read-only; \(traceFilesScanned.count) day file(s) in \(lookbackDays)d lookback")
    settleJSONLSource("turn_traces/", lines: traceLinesSeen, malformed: traceMalformedLines)
}
/// Once the trace feed is unreadable, every lane, capsule and turn-speed number
/// derived from it is withdrawn — a report that keeps quoting them "from the
/// good rows" is the same silent-partial-truth this tool exists to refuse.
let turnTracesUnreadable = sources.isUnreadable("turn_traces/")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LLM telemetry
// ─────────────────────────────────────────────────────────────────────────────

struct SurfaceStat {
    var calls = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheRead = 0
    var cacheCreation = 0
    var durations: [Double] = []
    var ttfts: [Double] = []
    var substituted = 0
    var models: [String: Int] = [:]
    var substitutionPairs: [String: Int] = [:]
}

var surfaceStats: [String: SurfaceStat] = [:]
var llmCallsInWindow = 0
var llmRowsTotal = 0
var llmEarliest: Date?
var llmLatest: Date?

// ── wave-2 accumulators filled by the SAME single pass over the events feed ──
//
// `traces/events.jsonl` is 3 MB and growing; SYS-09 (providers/routing) and
// SYS-10 (tools) both need rows out of it. Streaming it a second and a third
// time would triple the read for no new information, so both organs' counters
// are filled here, in the one pass that was already happening. They are
// DECLARED here and READ far below in the wave-2 reader block — the alternative
// is three passes over the same bytes.
//
// Every counter below is guarded at render time on `traces/events.jsonl`
// being present and readable, exactly like every other cell: an unread events
// feed leaves these at their initial 0 and `sysCell` renders the house label
// instead of that 0.
struct ProviderRouteStat {
    var calls = 0
    var providers: [String: Int] = [:]
    var models: [String: Int] = [:]
    var substituted = 0
    var nonOK = 0
}
/// Per-surface provider/model traffic in window, for SYS-09's pin-vs-observed table.
var routeStats: [String: ProviderRouteStat] = [:]
// File modification time is a conservative lower bound, not a fabricated
// per-surface change timestamp. Unknown/moving configuration cannot prove drift.
func routingPinEpoch() -> Date? {
    let paths = ["providers/surfaces.json", "providers/active.json"]
    let dates = paths.compactMap { (try? fm.attributesOfItem(atPath: rootPath($0)))?[.modificationDate] as? Date }
    return dates.count == paths.count ? dates.max() : nil
}
let capturedRoutingPinEpoch = routingPinEpoch()
var currentPinRouteStats: [String: ProviderRouteStat] = [:]
/// llm.call rows whose `status` is not `ok`, clustered by status and by the
/// error text the row carries. An EMPTY cluster map on a feed that read is a
/// real "no rejected call in window" — it is only the unread case that must
/// never render as zero, and `sysCell` handles that.
var llmNonOKByStatus: [String: Int] = [:]
var llmNonOKSignatures: [String: Int] = [:]
var llmNonOKInWindow = 0
var llmSubstitutionPairsAll: [String: Int] = [:]

struct ToolDispatchStat {
    var ok = 0
    var failed = 0
    var otherStatus: [String: Int] = [:]
    var durations: [Double] = []
    var errorClasses: [String: Int] = [:]
    /// `receipt.errorDetail` (bounded, redacted failure text written by the
    /// tracer since 2026-08-21) → count. Absent on older rows; a failed row
    /// with no detail is counted under "(no errorDetail on row)" so the
    /// column never reads as "no reason" when the writer predates the field.
    var errorDetails: [String: Int] = [:]
    var surfaces: [String: Int] = [:]
    var total: Int { ok + failed + otherStatus.values.reduce(0, +) }
}
/// Per-tool dispatch outcomes in window (SYS-10).
var toolStats: [String: ToolDispatchStat] = [:]
var toolDispatchRowsTotal = 0
var toolDispatchInWindow = 0
var toolDispatchNewest: Date?
var toolDecisions: [String: Int] = [:]
var toolOutcomes: [String: Int] = [:]
var toolPermanence: [String: Int] = [:]
/// tool.preload rows: which capability groups the router pre-loaded, and how
/// often. A group that never preloads is a routing wire nobody is pulling.
var toolPreloadGroups: [String: Int] = [:]
var toolPreloadInWindow = 0

let eventsPath = rootPath("traces/events.jsonl")
let eventsPresent = sources.register("traces/events.jsonl", eventsPath, note: "streamed read-only")
var eventsLines = 0, eventsMalformed = 0
if eventsPresent, LineStream(path: eventsPath) == nil {
    // Present-but-unopenable is UNREADABLE, never zeros — SYS-09/10 gate on
    // this source (gpt-5.5 wave-2 review).
    markFeedUnreadable("traces/events.jsonl", "present but could not be opened for reading")
}
if eventsPresent, let stream = LineStream(path: eventsPath) {
    let needle = bytes("\"llm.call\"")
    let toolNeedle = bytes("\"tool.dispatch\"")
    let preloadNeedle = bytes("\"tool.preload\"")
    // WAVE 3: the two kinds that are written to BOTH feeds with DIFFERENT
    // payload shapes. Reading only one of them is how a consumer ends up
    // silently reading nothing — so both halves are counted and compared.
    let planNeedle = bytes("\"turn.plan\"")
    let memoryCommitNeedle = bytes("\"memory.commit\"")
    stream.forEachLine { line in
        eventsLines += 1
        if !looksLikeCompleteJSONObject(line) { eventsMalformed += 1; return }
        let isLLM = contains(line, needle)
        let isTool = contains(line, toolNeedle)
        let isPreload = contains(line, preloadNeedle)
        let isPlan = contains(line, planNeedle)
        let isMemoryCommit = contains(line, memoryCommitNeedle)
        guard isLLM || isTool || isPreload || isPlan || isMemoryCommit else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            eventsMalformed += 1
            return
        }
        let kind = (obj["kind"] as? String) ?? ""
        // ── WAVE 3: turn.plan — the richest policy record in the system, and
        // read by nothing outside production code. Only the DECISION vocabulary
        // and the payload SHAPE are taken out of it.
        if kind == "turn.plan" {
            guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp), ts >= windowStart else { return }
            turnPlanEventRows += 1
            let payload = (obj["payload"] as? [String: Any]) ?? [:]
            turnPlanEventFieldCounts.insert(payload.count)
            if let level = payload["permissionLevel"] as? String {
                turnPlanPermissionLevels[level, default: 0] += 1
            }
            if let decision = payload["policyDecision"] as? [String: Any] {
                turnPlanPolicyOutcomes[(decision["outcome"] as? String) ?? "(no outcome field)", default: 0] += 1
            } else {
                turnPlanNullPolicy += 1
            }
            return
        }
        if kind == "memory.commit" {
            guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp), ts >= windowStart else { return }
            memoryCommitEventRows += 1
            return
        }
        // ── SYS-10: tool dispatch outcomes ──
        if kind == "tool.dispatch", let payload = obj["payload"] as? [String: Any] {
            toolDispatchRowsTotal += 1
            let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp)
            if let ts { toolDispatchNewest = newer(toolDispatchNewest, ts) }
            guard let ts, ts >= runtimeEvidenceStart else { return }
            toolDispatchInWindow += 1
            let receipt = (payload["receipt"] as? [String: Any]) ?? [:]
            // The tool's name is the row title; the receipt's `target` is the
            // same string on every row seen live. Prefer the receipt, fall back
            // to the title, and NEVER invent a name — an unnamed dispatch is
            // bucketed explicitly so it cannot vanish into another tool's count.
            let name = (receipt["target"] as? String)
                ?? (obj["title"] as? String)
                ?? "(no target/title field)"
            var t = toolStats[name] ?? ToolDispatchStat()
            switch (obj["status"] as? String) ?? "(no status field)" {
            case "ok": t.ok += 1
            case "failed": t.failed += 1
            case let other: t.otherStatus[other, default: 0] += 1
            }
            if let d = (payload["durationMs"] as? NSNumber)?.doubleValue { t.durations.append(d) }
            if let ec = receipt["errorClass"] as? String { t.errorClasses[ec, default: 0] += 1 }
            if (obj["status"] as? String) == "failed" {
                let detail = (receipt["errorDetail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                t.errorDetails[detail ?? "(no errorDetail on row)", default: 0] += 1
            }
            t.surfaces[(payload["surface"] as? String) ?? "(no surface field)", default: 0] += 1
            toolStats[name] = t
            toolDecisions[(receipt["decision"] as? String) ?? "(no decision field)", default: 0] += 1
            toolOutcomes[(receipt["outcome"] as? String) ?? "(no outcome field)", default: 0] += 1
            toolPermanence[(receipt["permanence"] as? String) ?? "(no permanence field)", default: 0] += 1
            return
        }
        if kind == "tool.preload", let payload = obj["payload"] as? [String: Any] {
            guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp), ts >= windowStart else { return }
            toolPreloadInWindow += 1
            for g in (payload["groups"] as? [Any])?.compactMap({ $0 as? String }) ?? [] {
                toolPreloadGroups[g, default: 0] += 1
            }
            return
        }
        guard kind == "llm.call",
              let payload = obj["payload"] as? [String: Any] else { return }
        llmRowsTotal += 1
        guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp) else { return }
        if llmEarliest == nil || ts < llmEarliest! { llmEarliest = ts }
        if llmLatest == nil || ts > llmLatest! { llmLatest = ts }
        guard ts >= windowStart else { return }
        llmCallsInWindow += 1
        let surface = (payload["surface"] as? String) ?? "(unlabeled)"
        var s = surfaceStats[surface] ?? SurfaceStat()
        s.calls += 1
        s.inputTokens += (payload["inputTokens"] as? NSNumber)?.intValue ?? 0
        s.outputTokens += (payload["outputTokens"] as? NSNumber)?.intValue ?? 0
        s.cacheRead += (payload["cacheReadInputTokens"] as? NSNumber)?.intValue ?? 0
        s.cacheCreation += (payload["cacheCreationInputTokens"] as? NSNumber)?.intValue ?? 0
        if let d = (payload["durationMs"] as? NSNumber)?.doubleValue { s.durations.append(d) }
        if let t = (payload["ttftMs"] as? NSNumber)?.doubleValue { s.ttfts.append(t) }
        let model = (payload["model"] as? String) ?? "(unknown)"
        s.models[model, default: 0] += 1
        if let from = payload["substitutedFrom"] as? String {
            s.substituted += 1
            s.substitutionPairs["\(from) → \(model)", default: 0] += 1
        }
        surfaceStats[surface] = s

        // ── SYS-09: what the router ACTUALLY reached for, per surface ──
        // The provider label is only present on rows the client stamped; a row
        // without one gets an explicit bucket rather than being folded into
        // whichever provider happened to be commonest.
        var r = routeStats[surface] ?? ProviderRouteStat()
        r.calls += 1
        r.providers[(payload["provider"] as? String) ?? "(no provider field)", default: 0] += 1
        r.models[model, default: 0] += 1
        if let from = payload["substitutedFrom"] as? String {
            r.substituted += 1
            llmSubstitutionPairsAll["\(from) → \(model)", default: 0] += 1
        }
        let status = (obj["status"] as? String) ?? "(no status field)"
        if status != "ok" {
            r.nonOK += 1
            llmNonOKInWindow += 1
            llmNonOKByStatus[status, default: 0] += 1
            // First clause of whatever error text the row carries, same
            // collapse rule the background-loop signatures use.
            let raw = (payload["error"] as? String)
                ?? (payload["errorClass"] as? String)
                ?? (payload["reason"] as? String)
            if let raw {
                let head = raw.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? raw
                llmNonOKSignatures[String(head.prefix(90)), default: 0] += 1
            } else {
                llmNonOKSignatures["(row carries no error/errorClass/reason field)", default: 0] += 1
            }
        }
        routeStats[surface] = r
        if let epoch = capturedRoutingPinEpoch, ts >= epoch {
            var current = currentPinRouteStats[surface] ?? ProviderRouteStat()
            current.calls += 1
            current.models[model, default: 0] += 1
            currentPinRouteStats[surface] = current
        }
    }
    sources.setRows("traces/events.jsonl", llmRowsTotal)
    settleJSONLSource("traces/events.jsonl", lines: eventsLines, malformed: eventsMalformed)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Desk / notifications / delegation
// ─────────────────────────────────────────────────────────────────────────────

var deskOpCounts: [String: Int] = [:]
var deskOpsInWindow = 0
let deskOpsPath = rootPath("desk/desk_ops.jsonl")
let deskOpsPresent = sources.register("desk/desk_ops.jsonl", deskOpsPath, note: "streamed read-only")
if deskOpsPresent, let stream = LineStream(path: deskOpsPath) {
    var total = 0, malformed = 0
    stream.forEachLine { line in
        total += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformed += 1
            return
        }
        guard let ts = (obj["ts"] as? String).flatMap(parseTimestamp), ts >= windowStart else { return }
        deskOpsInWindow += 1
        deskOpCounts[(obj["op"] as? String) ?? "(no op field)", default: 0] += 1
    }
    sources.setRows("desk/desk_ops.jsonl", total - malformed)
    settleJSONLSource("desk/desk_ops.jsonl", lines: total, malformed: malformed)
}

// Learned poll cadence is a separate, cross-process desk store.  It needs its
// own reader: desk activity can remain live while this writer has stopped, and
// the refresh loop would then make timing decisions from a stale snapshot.
var cadenceStatsRefs = 0
var cadenceStatsObservations = 0
var cadenceStatsChanges = 0
var cadenceStatsConfidentRefs = 0
var cadenceStatsPinnedFloor = 0
var cadenceStatsPinnedCeiling = 0
var cadenceStatsMissingObservedStamp = 0
var cadenceStatsInvalidRows = 0
var cadenceStatsNewestObservedAt: Date?
let cadenceStatsPath = rootPath("desk/cadence_stats.json")
let cadenceStatsPresent = sources.register("desk/cadence_stats.json", cadenceStatsPath,
                                            note: "read-only learned cadence stats")
if cadenceStatsPresent {
    if let data = fm.contents(atPath: cadenceStatsPath),
       let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let refs = top["refs"] as? [String: Any] {
        for (_, rawRow) in refs {
            guard let row = rawRow as? [String: Any],
                  let observations = row["observations"] as? Int, observations >= 0,
                  let changes = row["changes"] as? Int, changes >= 0 else {
                cadenceStatsInvalidRows += 1
                continue
            }
            cadenceStatsRefs += 1
            cadenceStatsObservations += observations
            cadenceStatsChanges += changes
            if let observed = (row["lastObservedAt"] as? String).flatMap(parseTimestamp) {
                cadenceStatsNewestObservedAt = newer(cadenceStatsNewestObservedAt, observed)
            } else {
                cadenceStatsMissingObservedStamp += 1
            }

            // This mirrors DeskCadenceLearner.learnedIntervalSeconds exactly:
            // three changes make an EWMA trustworthy, then its half-interval
            // poll target is clamped to 15m...24h.  Pinned intervals are not
            // an error by themselves, but they are the evidence needed to
            // distinguish a natural rhythm from a saturated learner.
            guard changes >= 3,
                  let ewma = row["ewmaChangeIntervalSec"] as? Double,
                  ewma.isFinite, ewma > 0 else { continue }
            cadenceStatsConfidentRefs += 1
            let rawPoll = ewma * 0.5
            if rawPoll <= 900 { cadenceStatsPinnedFloor += 1 }
            if rawPoll >= 86_400 { cadenceStatsPinnedCeiling += 1 }
        }
        sources.setRows("desk/cadence_stats.json", cadenceStatsRefs)
        if cadenceStatsInvalidRows > 0 {
            sources.note("desk/cadence_stats.json", "read-only learned cadence stats; \(cadenceStatsInvalidRows) malformed ref row(s) ignored")
        }
    } else if fm.contents(atPath: cadenceStatsPath) == nil {
        let reason = "present but could not be read"
        sources.note("desk/cadence_stats.json", "UNREADABLE — " + reason)
        sources.markUnreadable("desk/cadence_stats.json", reason)
        addLead(rank: 3, "Source `desk/cadence_stats.json` is UNREADABLE — \(reason)",
                evidence: "The Desk refresh learner cannot be inspected while its stats file is unreadable.",
                action: "Check the file's permissions and writer; do not treat an unreadable learned cadence as zero activity.")
    } else {
        let reason = "present but top level is not an object with a refs object"
        sources.note("desk/cadence_stats.json", "UNREADABLE — " + reason)
        sources.markUnreadable("desk/cadence_stats.json", reason)
        addLead(rank: 3, "Source `desk/cadence_stats.json` is UNREADABLE — \(reason)",
                evidence: "The Desk refresh learner's persisted shape cannot be decoded.",
                action: "Repair or replace the malformed stats file; the desk will relearn safely, but timing is unknowable until then.")
    }
}

// Canonical since the 2026-08-13 migration.  Do not fall back to the frozen
// inbox/ sibling here: an old state can look perfectly healthy while the
// scheduler's real claim file has stopped advancing.
let triggerStateStaleHours = 36.0
var triggerStateRows: [(name: String, lastFiredAt: Date?)] = []
var triggerStateInvalidEntries = 0
var triggerStateNewest: Date?
let triggerStatePath = rootPath("triggers/trigger_state.json")
let triggerStatePresent = sources.register("triggers/trigger_state.json", triggerStatePath,
                                            note: "canonical read-only inbox trigger claim state")
if triggerStatePresent {
    if let data = fm.contents(atPath: triggerStatePath),
       let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for (name, rawEntry) in state {
            guard let entry = rawEntry as? [String: Any] else {
                triggerStateInvalidEntries += 1
                continue
            }
            let firedAt = (entry["last_fired_at"] as? String).flatMap(parseTimestamp)
            if entry["last_fired_at"] != nil && firedAt == nil {
                triggerStateInvalidEntries += 1
            }
            triggerStateRows.append((name, firedAt))
            triggerStateNewest = newer(triggerStateNewest, firedAt)
        }
        sources.setRows("triggers/trigger_state.json", triggerStateRows.count)
        if triggerStateInvalidEntries > 0 {
            sources.note("triggers/trigger_state.json", "canonical read-only claim state; \(triggerStateInvalidEntries) invalid entry field(s)")
        }
    } else if fm.contents(atPath: triggerStatePath) == nil {
        let reason = "present but could not be read"
        sources.note("triggers/trigger_state.json", "UNREADABLE — " + reason)
        sources.markUnreadable("triggers/trigger_state.json", reason)
        addLead(rank: 3, "Source `triggers/trigger_state.json` is UNREADABLE — \(reason)",
                evidence: "The canonical scheduler claim state cannot be inspected; trigger liveness is unknown, not zero.",
                action: "Repair the canonical `triggers/` state file permissions and rerun the instrument. Do not use `inbox/trigger_state.json` as a substitute.")
    } else {
        let reason = "present but top level is not a JSON object"
        sources.note("triggers/trigger_state.json", "UNREADABLE — " + reason)
        sources.markUnreadable("triggers/trigger_state.json", reason)
        addLead(rank: 3, "Source `triggers/trigger_state.json` is UNREADABLE — \(reason)",
                evidence: "A corrupt canonical trigger state makes periodic firing fail safe, so its liveness cannot be inferred.",
                action: "Repair the canonical `triggers/trigger_state.json`; leave the legacy inbox copy untouched.")
    }
}

var enabledTimeTriggerNames: Set<String> = []
let triggerConfigPath = rootPath("triggers/trigger_config.json")
let triggerConfigPresent = sources.register("triggers/trigger_config.json", triggerConfigPath,
                                             note: "canonical read-only trigger configuration")
if triggerConfigPresent {
    if let data = fm.contents(atPath: triggerConfigPath),
       let configs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        for config in configs where (config["enabled"] as? Bool) == true && (config["kind"] as? String) == "time" {
            if let name = config["name"] as? String, !name.isEmpty { enabledTimeTriggerNames.insert(name) }
        }
        sources.setRows("triggers/trigger_config.json", configs.count)
    } else {
        let reason = fm.contents(atPath: triggerConfigPath) == nil
            ? "present but could not be read"
            : "present but top level is not a JSON array"
        sources.note("triggers/trigger_config.json", "UNREADABLE — " + reason)
        sources.markUnreadable("triggers/trigger_config.json", reason)
        addLead(rank: 3, "Source `triggers/trigger_config.json` is UNREADABLE — \(reason)",
                evidence: "The enabled time-trigger set cannot be determined, so state freshness cannot be judged.",
                action: "Repair the canonical trigger configuration before treating a quiet state map as healthy.")
    }
}

// The backup registry is a restore-time promise, not a log: validate the
// newest local UUID directory against the scope the registry claims.  The
// current writer bounds the registry to 200 rows; older installed generations
// use flat component JSON while current generations use data/ + manifest.json,
// so this reader recognises both without ever trusting the stored absolute path.
let backupGenerationCeiling = 200
let legacyBackupComponentFiles: [String: String] = [
    "chat_sessions": "chat_sessions.json", "connectors": "connectors.json",
    "trust": "trust.json", "tools": "tools.json", "memory": "memory.json",
    "skills": "skills.json", "config": "config.json", "improvements": "improvements.json",
    "jobs": "jobs.json", "workspaces": "workspaces.json", "missions": "missions.json",
]
func safeBackupRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
    return value.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
var backupRegistryRows = 0
var backupRegistryInvalidRows = 0
var backupNewestID: String?
var backupNewestCreatedAt: Date?
var backupNewestFormat: String?
var backupClaimedComponents = 0
var backupPresentComponents = 0
var backupMissingComponents: [String] = []
var backupZeroByteFiles: [String] = []
var backupVerifiedFiles = 0
let backupsPath = rootPath("backups")
let backupRegistryPath = rootPath("backups/registry.json")
let backupRegistryPresent = sources.register("backups/registry.json", backupRegistryPath,
                                              note: "read-only registry; newest generation checked locally")
if backupRegistryPresent {
    if let data = fm.contents(atPath: backupRegistryPath),
       let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        var candidates: [(id: String, createdAt: Date, scope: [String])] = []
        for row in rows {
            guard let id = row["id"] as? String,
                  UUID(uuidString: id) != nil,
                  let createdAt = (row["createdAt"] as? String).flatMap(parseTimestamp),
                  let scope = row["scope"] as? [String] else {
                backupRegistryInvalidRows += 1
                continue
            }
            candidates.append((id.lowercased(), createdAt, scope))
        }
        backupRegistryRows = candidates.count
        sources.setRows("backups/registry.json", backupRegistryRows)
        if backupRegistryInvalidRows > 0 {
            sources.note("backups/registry.json", "read-only registry; \(backupRegistryInvalidRows) invalid row(s) ignored")
        }
        if let newest = candidates.max(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) {
            backupNewestID = newest.id
            backupNewestCreatedAt = newest.createdAt
            let generationPath = (backupsPath as NSString).appendingPathComponent(newest.id)
            let dataPath = (generationPath as NSString).appendingPathComponent("data")
            let manifestPath = (generationPath as NSString).appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: dataPath),
               let manifestData = fm.contents(atPath: manifestPath),
               let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
               let copied = manifest["copied"] as? [String],
               let files = manifest["files"] as? [[String: Any]] {
                backupNewestFormat = "sealed manifest"
                backupClaimedComponents = copied.count
                for component in copied {
                    guard safeBackupRelativePath(component) else {
                        backupMissingComponents.append("invalid scope path")
                        continue
                    }
                    let componentPath = (dataPath as NSString).appendingPathComponent(component)
                    if fm.fileExists(atPath: componentPath) {
                        backupPresentComponents += 1
                    } else {
                        backupMissingComponents.append(component)
                    }
                }
                for file in files {
                    guard let relative = file["path"] as? String,
                          safeBackupRelativePath(relative) else {
                        backupMissingComponents.append("invalid manifest file entry")
                        continue
                    }
                    let filePath = (dataPath as NSString).appendingPathComponent(relative)
                    let declared = (file["sizeBytes"] as? NSNumber)?.int64Value
                    let actual = ((try? fm.attributesOfItem(atPath: filePath))?[.size] as? NSNumber)?.int64Value
                    guard let declared, let actual, declared == actual else {
                        backupMissingComponents.append(relative)
                        continue
                    }
                    backupVerifiedFiles += 1
                    if actual == 0 { backupZeroByteFiles.append(relative) }
                }
            } else {
                backupNewestFormat = "legacy flat generation"
                backupClaimedComponents = newest.scope.count
                for component in newest.scope {
                    guard let fileName = legacyBackupComponentFiles[component] else {
                        backupMissingComponents.append(component + " (unknown legacy component)")
                        continue
                    }
                    let filePath = (generationPath as NSString).appendingPathComponent(fileName)
                    guard let size = ((try? fm.attributesOfItem(atPath: filePath))?[.size] as? NSNumber)?.int64Value else {
                        backupMissingComponents.append(component)
                        continue
                    }
                    backupPresentComponents += 1
                    backupVerifiedFiles += 1
                    if size == 0 { backupZeroByteFiles.append(component) }
                }
            }
        }
    } else {
        let reason = fm.contents(atPath: backupRegistryPath) == nil
            ? "present but could not be read"
            : "present but top level is not a JSON array"
        sources.note("backups/registry.json", "UNREADABLE — " + reason)
        sources.markUnreadable("backups/registry.json", reason)
        addLead(rank: 3, "Source `backups/registry.json` is UNREADABLE — \(reason)",
                evidence: "A backup registry that cannot be decoded cannot name a recoverable newest generation.",
                action: "Repair the registry before relying on any backup at restore time.")
    }
}

var deskStatusCounts: [String: Int] = [:]
var deskOpenAging: [(String, Double)] = []       // (handle/title, days open)
var deskItemsTotal = 0
let deskStatePath = rootPath("desk/desk_state.json")
let deskStatePresent = sources.register("desk/desk_state.json", deskStatePath, note: "read-only JSON")
if deskStatePresent,
   let data = fm.contents(atPath: deskStatePath),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let items = obj["items"] as? [[String: Any]] {
    deskItemsTotal = items.count
    for item in items {
        let status = (item["status"] as? String) ?? "(none)"
        deskStatusCounts[status, default: 0] += 1
        if status != "done" && status != "archived" && status != "closed",
           let opened = (item["openedAt"] as? String).flatMap(parseTimestamp) {
            let age = now.timeIntervalSince(opened) / 86400
            let label = (item["title"] as? String) ?? (item["handle"] as? String) ?? "(untitled)"
            deskOpenAging.append((label, age))
        }
    }
    sources.setRows("desk/desk_state.json", deskItemsTotal)
}

var notifyStatusWindow: [String: Int] = [:]
var notifySeverityWindow: [String: Int] = [:]
var notifyUnreadTotal = 0
var notifyErrorSignatures: [String: Int] = [:]
let inboxPath = rootPath("notifications/inbox.jsonl")
let inboxPresent = sources.register("notifications/inbox.jsonl", inboxPath, note: "streamed read-only")
if inboxPresent, LineStream(path: inboxPath) == nil {
    // Present-but-unopenable must mark unreadable, never fall through with
    // initialized zeros (gpt-5.5 final review) — same contract as organJSONL.
    markFeedUnreadable("notifications/inbox.jsonl", "present but could not be opened for reading")
}
if inboxPresent, let stream = LineStream(path: inboxPath) {
    var total = 0, malformed = 0
    stream.forEachLine { line in
        total += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformed += 1
            return
        }
        let status = (obj["status"] as? String) ?? "(none)"
        if status == "unread" { notifyUnreadTotal += 1 }
        guard let ts = (obj["created_at"] as? String).flatMap(parseTimestamp), ts >= windowStart else { return }
        notifyStatusWindow[status, default: 0] += 1
        notifySeverityWindow[(obj["severity"] as? String) ?? "(none)", default: 0] += 1
        if let sig = obj["error_signature"] as? String { notifyErrorSignatures[sig, default: 0] += 1 }
    }
    sources.setRows("notifications/inbox.jsonl", total - malformed)
    settleJSONLSource("notifications/inbox.jsonl", lines: total, malformed: malformed)
}

var delegationKinds: [String: Int] = [:]
var delegationRowsWindow = 0
var delegationHasStatusField = false
let ledgerPath = rootPath("orchestration/task_ledger.jsonl")
let ledgerPresent = sources.register("orchestration/task_ledger.jsonl", ledgerPath, note: "streamed read-only")
if ledgerPresent, LineStream(path: ledgerPath) == nil {
    markFeedUnreadable("orchestration/task_ledger.jsonl", "present but could not be opened for reading")
}
if ledgerPresent, let stream = LineStream(path: ledgerPath) {
    var total = 0, malformed = 0
    stream.forEachLine { line in
        total += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformed += 1
            return
        }
        if obj["status"] != nil { delegationHasStatusField = true }
        guard let ts = (obj["ts"] as? String).flatMap(parseTimestamp), ts >= windowStart else { return }
        delegationRowsWindow += 1
        delegationKinds[(obj["kind"] as? String) ?? "(no kind field)", default: 0] += 1
    }
    sources.setRows("orchestration/task_ledger.jsonl", total - malformed)
    settleJSONLSource("orchestration/task_ledger.jsonl", lines: total, malformed: malformed)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Cognition store reads (all on the copy)
// ─────────────────────────────────────────────────────────────────────────────

var nodeKindCounts: [(String, Int)] = []
var nodesTotal = 0
var nodesWithMemoryStamp = 0
var memoryStampedIDTotal = 0
var nodeLatest: Date?
var artifactByKindStatus: [(String, String, Int)] = []
var standingActive = 0, standingProposed = 0
var receiptKindsWindow: [(String, Int, Date?)] = []
var consolidationRunsInWindow = 0
var reflectionRunsInWindow = 0
var replayIntegrationsInWindow = 0
var affectAxes: [String: Double] = [:]
var affectUpdatedAt: Date?
var dispositionValence: Double?
var emotionalTagNonZeroNodes = 0
var consolidationCalmed: Int?
var consolidationReinforced: Int?
var consolidationRanAt: Date?
var thoughtSeedsOpen: Int?

if let db = cognitionState.handle {
    nodesTotal = db.int("SELECT COUNT(*) FROM cognitive_nodes;") ?? 0
    nodeKindCounts = db.query("SELECT kind, COUNT(*) FROM cognitive_nodes GROUP BY 1 ORDER BY 2 DESC;")
        .compactMap { r in r.count >= 2 ? (r[0], Int(r[1]) ?? 0) : nil }
    nodesWithMemoryStamp = db.int(
        "SELECT COUNT(*) FROM cognitive_nodes WHERE metadata_json LIKE '%memoryRecordIds%';") ?? 0
    emotionalTagNonZeroNodes = db.int(
        "SELECT COUNT(*) FROM cognitive_nodes WHERE emotional_valence != 0 OR emotional_arousal != 0 OR emotional_warmth != 0;") ?? 0
    if let t = db.scalar("SELECT MAX(last_activated_at) FROM cognitive_nodes;"), let d = Double(t) {
        nodeLatest = Date(timeIntervalSince1970: d)
    }
    // Count stamped record ids without dragging free text through the separator.
    for row in db.query("SELECT metadata_json FROM cognitive_nodes WHERE metadata_json LIKE '%memoryRecordIds%';") {
        guard let raw = row.first, let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ids = obj["memoryRecordIds"] as? [Any] else { continue }
        memoryStampedIDTotal += ids.count
    }

    artifactByKindStatus = db.query("SELECT kind, status, COUNT(*) FROM cognitive_artifacts GROUP BY 1,2 ORDER BY 1,2;")
        .compactMap { r in r.count >= 3 ? (r[0], r[1], Int(r[2]) ?? 0) : nil }
    standingActive = db.int("SELECT COUNT(*) FROM cognitive_artifacts WHERE kind='standing_view' AND status='active';") ?? 0
    standingProposed = db.int("SELECT COUNT(*) FROM cognitive_artifacts WHERE kind='standing_view' AND status='proposed';") ?? 0

    let windowEpoch = windowStart.timeIntervalSince1970
    receiptKindsWindow = db.query("""
        SELECT kind, COUNT(*), MAX(created_at) FROM cognitive_receipts
        WHERE created_at >= \(windowEpoch) GROUP BY 1 ORDER BY 2 DESC;
        """).compactMap { r in
            guard r.count >= 3 else { return nil }
            let last = Double(r[2]).map { Date(timeIntervalSince1970: $0) }
            return (r[0], Int(r[1]) ?? 0, last)
        }
    for (kind, count, _) in receiptKindsWindow {
        if kind == "emotional_consolidation" { consolidationRunsInWindow = count }
        if kind.hasPrefix("reflection.") { reflectionRunsInWindow += count }
        if kind == "replay.integration" { replayIntegrationsInWindow = count }
    }

    if let raw = db.scalar("SELECT payload_json FROM cognitive_artifacts WHERE kind='affect' LIMIT 1;"),
       let d = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        for axis in ["arousal", "uncertainty", "taskPressure", "socialWarmth"] {
            if let v = (obj[axis] as? NSNumber)?.doubleValue { affectAxes[axis] = v }
        }
        if let u = (obj["updatedAt"] as? NSNumber)?.doubleValue {
            affectUpdatedAt = Date(timeIntervalSince1970: u)
        }
    }
    if let raw = db.scalar("SELECT payload_json FROM cognitive_artifacts WHERE kind='emotional_consolidation' LIMIT 1;"),
       let d = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        consolidationCalmed = (obj["calmed"] as? NSNumber)?.intValue
        consolidationReinforced = (obj["reinforced"] as? NSNumber)?.intValue
        if let r = (obj["ranAt"] as? NSNumber)?.doubleValue { consolidationRanAt = Date(timeIntervalSince1970: r) }
    }
    thoughtSeedsOpen = db.int("SELECT COUNT(*) FROM cognitive_artifacts WHERE kind='thought_seed' AND status='open';")
    if let raw = db.scalar("SELECT payload_json FROM cognitive_artifacts WHERE kind='disposition' LIMIT 1;"),
       let d = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        dispositionValence = (obj["valence"] as? NSNumber)?.doubleValue
    }
}
settleStore(&cognitionState, "cognition.sqlite")
/// Convenience for the many `cognition != nil` readability tests below. It is
/// nil for an ABSENT store and for an UNREADABLE one alike — the sections
/// distinguish the two by asking `cognitionState` directly.
let cognition = cognitionState.handle

// Organism state (JSON, read-only — no copy needed, we never open it for write)
var chemistry: [String: Double] = [:]
var organismSavedAt: Date?
var organismSignalCount: Int?
// Somatic signals — the body-schema flags (Layer III, "body beliefs").
var bodySchema: [String: Bool] = [:]
var bodySchemaPresent = false
// Prediction ledger — bound ≤96, statuses, per-path body confidence.
var predictionsByStatus: [String: Int] = [:]
var predictionsTotal: Int?
var predictionSatisfied: Int?
var predictionViolated: Int?
var predictionExpired: Int?
var predictionLedgerUpdatedAt: Date?
var bodyConfidence: [String: Double] = [:]
var predictionLedgerPresent = false
// Continuity field as the organism persists it (nodes/edges + generation).
var organismFieldNodes: Int?
var organismFieldEdges: Int?

let organismPath = rootPath("cognition/organism_state.json")
let organismPresent = sources.register("cognition/organism_state.json", organismPath, note: "read-only JSON")
if organismPresent,
   let data = fm.contents(atPath: organismPath),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let chem = obj["chemicalState"] as? [String: Any] {
        for (k, v) in chem { if let n = (v as? NSNumber)?.doubleValue { chemistry[k] = n } }
    }
    organismSavedAt = (obj["savedAt"] as? String).flatMap(parseTimestamp)
    organismSignalCount = (obj["signalCount"] as? NSNumber)?.intValue
    if let body = obj["bodySchema"] as? [String: Any] {
        bodySchemaPresent = true
        for (k, v) in body {
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { bodySchema[k] = n.boolValue }
            else if let s = v as? String {
                let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // BodySchema.resourcePressure is an enum, not a health boolean.
                // Only nominal is the healthy state; elevated/high/critical
                // intentionally surface as pressure. Treating every unknown
                // string as false previously made a nominal live organism look
                // unhealthy in every report.
                bodySchema[k] = k == "resourcePressure"
                    ? normalized == "nominal"
                    : ["true", "healthy", "available"].contains(normalized)
            }
        }
    }
    if let ledger = obj["predictionLedger"] as? [String: Any] {
        predictionLedgerPresent = true
        if let preds = ledger["predictions"] as? [String: Any] {
            predictionsTotal = preds.count
            for (_, v) in preds {
                let st = ((v as? [String: Any])?["status"] as? String) ?? "(no status)"
                predictionsByStatus[st, default: 0] += 1
            }
        }
        predictionSatisfied = (ledger["satisfiedCount"] as? NSNumber)?.intValue
        predictionViolated = (ledger["violatedCount"] as? NSNumber)?.intValue
        predictionExpired = (ledger["expiredCount"] as? NSNumber)?.intValue
        predictionLedgerUpdatedAt = (ledger["lastUpdatedAt"] as? String).flatMap(parseTimestamp)
        if let conf = ledger["bodyConfidence"] as? [String: Any] {
            for (k, v) in conf { if let n = (v as? NSNumber)?.doubleValue { bodyConfidence[k] = n } }
        }
    }
    if let field = obj["field"] as? [String: Any] {
        if let n = field["nodes"] as? [Any] { organismFieldNodes = n.count }
        else if let n = field["nodes"] as? [String: Any] { organismFieldNodes = n.count }
        if let e = field["edges"] as? [Any] { organismFieldEdges = e.count }
        else if let e = field["edges"] as? [String: Any] { organismFieldEdges = e.count }
    }
}

// Passive bridge sampler. It is intentionally NOT folded into organism-state
// counters: a quiet or dormant sampler says nothing about the organism's value,
// only whether this observation lane still ran. The writer retains 10,000 rows
// by default; report the bound so a growing timeline cannot look healthy merely
// because it remains parseable.
let organismWatchRowCeiling = 10_000
let organismWatchPath = rootPath("cognition/organism_watch.jsonl")
let organismWatchRunMarkerPath = organismWatchPath + ".lock"
var organismWatchMarkerIsDirectory = ObjCBool(false)
let organismWatchRunActive = fm.fileExists(
    atPath: organismWatchRunMarkerPath,
    isDirectory: &organismWatchMarkerIsDirectory
) && organismWatchMarkerIsDirectory.boolValue
let organismWatchPresent = sources.register(
    "cognition/organism_watch.jsonl", organismWatchPath,
    note: "streamed read-only; newest valid `at` is sampler freshness"
)
var organismWatchRows = 0
var organismWatchMalformed = 0
var organismWatchTimestampless = 0
var organismWatchFutureStamped = 0
var organismWatchRowsInWindow = 0
var organismWatchSuccessfulRowsInWindow = 0
var organismWatchUnreachableRowsInWindow = 0
var organismWatchNewest: Date?

if organismWatchPresent, let stream = LineStream(path: organismWatchPath) {
    stream.forEachLine { line in
        organismWatchRows += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            organismWatchMalformed += 1
            return
        }
        guard let timestamp = (obj["at"] as? String).flatMap(parseTimestamp) else {
            organismWatchTimestampless += 1
            return
        }
        // A future stamp cannot prove freshness: clock skew is an observation
        // error, not an organism event. Keep it visible and refuse to count it
        // toward the window instead of letting one bad wall clock mask dormancy.
        guard timestamp <= now.addingTimeInterval(5 * 60) else {
            organismWatchFutureStamped += 1
            return
        }
        organismWatchNewest = newer(organismWatchNewest, timestamp)
        guard timestamp >= windowStart else { return }
        organismWatchRowsInWindow += 1
        if (obj["ok"] as? Bool) == true {
            organismWatchSuccessfulRowsInWindow += 1
        } else if (obj["reason"] as? String) == "bridge_unreachable" {
            organismWatchUnreachableRowsInWindow += 1
        }
    }
    sources.setRows("cognition/organism_watch.jsonl", organismWatchRows)
    if organismWatchRunActive {
        settleJSONLSource(
            "cognition/organism_watch.jsonl",
            lines: organismWatchRows,
            malformed: organismWatchMalformed
        )
    } else {
        // Historical observation residue remains honestly parse-graded, but it
        // is not a current resident lane and therefore cannot raise a live
        // source-failure lead.
        sources.setParse(
            "cognition/organism_watch.jsonl",
            lines: organismWatchRows,
            malformed: organismWatchMalformed
        )
        if malformedRatioTooHigh(lines: organismWatchRows, malformed: organismWatchMalformed) {
            sources.markUnreadable(
                "cognition/organism_watch.jsonl",
                "historical/inactive sampler has \(organismWatchMalformed) malformed row(s)"
            )
        }
    }
} else if organismWatchPresent {
    let reason = "present but could not open for streamed read"
    sources.markUnreadable("cognition/organism_watch.jsonl", reason)
    if organismWatchRunActive {
        addLead(rank: 3, "Source `cognition/organism_watch.jsonl` is UNREADABLE — \(reason)",
                evidence: "The active sampler timeline exists but its rows could not be opened read-only. Its freshness is unknown, not zero.",
                action: "Repair file permissions or ownership, then rerun the instrument; do not infer organism activity from an unreadable sampler.")
    }
}

// Dream diary — one file per night
var dreamNightsInWindow: [String] = []
let dreamDir = rootPath("dream_diary")
let dreamPresent = sources.register("dream_diary/", dreamDir, note: "filenames only, read-only")
if dreamPresent {
    for name in ((try? fm.contentsOfDirectory(atPath: dreamDir)) ?? []).sorted() {
        guard name.hasSuffix(".md") else { continue }
        guard let d = dayKeyFmt.date(from: String(name.dropLast(3))) else { continue }
        if d.addingTimeInterval(86400) >= windowStart { dreamNightsInWindow.append(String(name.dropLast(3))) }
    }
    sources.setRows("dream_diary/", dreamNightsInWindow.count)
}

// ── REM / GROWTH: pins, proposals ────────────────────────────────────────────
var remPinsByDoc: [String: Int] = [:]
var remPinsTotal: Int?
var remPinNewest: Date?
let remPinsPath = rootPath("rem_pins.json")
let remPinsPresent = sources.register("rem_pins.json", remPinsPath, note: "read-only JSON")
if remPinsPresent,
   let data = fm.contents(atPath: remPinsPath),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    var total = 0
    for (doc, v) in obj {
        guard let arr = v as? [[String: Any]] else { continue }
        remPinsByDoc[doc] = arr.count
        total += arr.count
        for pin in arr {
            if let d = (pin["createdAt"] as? String).flatMap(parseTimestamp),
               remPinNewest == nil || d > remPinNewest! { remPinNewest = d }
        }
    }
    remPinsTotal = total
    sources.setRows("rem_pins.json", total)
}

var remProposalsByStatus: [String: Int] = [:]
var remProposalsTotal = 0
var remProposalsInWindow = 0
var remProposalNewest: Date?
let remProposalsPath = rootPath("rem_proposals.jsonl")
let remProposalsPresent = sources.register("rem_proposals.jsonl", remProposalsPath, note: "streamed read-only")
var remProposalLines = 0, remProposalMalformed = 0
if remProposalsPresent, let stream = LineStream(path: remProposalsPath) {
    stream.forEachLine { line in
        remProposalLines += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            remProposalMalformed += 1
            return
        }
        remProposalsTotal += 1
        remProposalsByStatus[(obj["status"] as? String) ?? "(no status)", default: 0] += 1
        guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp) else { return }
        if remProposalNewest == nil || ts > remProposalNewest! { remProposalNewest = ts }
        if ts >= windowStart { remProposalsInWindow += 1 }
    }
    sources.setRows("rem_proposals.jsonl", remProposalsTotal)
    settleJSONLSource("rem_proposals.jsonl", lines: remProposalLines, malformed: remProposalMalformed)
}

// ── Delivery envelope telemetry (documented as telemetry-only) ───────────────
var envelopeRowsTotal = 0
var envelopeRowsWindow = 0
var envelopeInsideBand = 0
var envelopeOneBeat = 0
var envelopeReplyChars: [Double] = []
var envelopeNewest: Date?
let envelopePath = rootPath("logs/delivery_envelope_telemetry.jsonl")
let envelopePresent = sources.register("logs/delivery_envelope_telemetry.jsonl", envelopePath,
                                       note: "streamed read-only")
var envelopeLines = 0, envelopeMalformed = 0
if envelopePresent, let stream = LineStream(path: envelopePath) {
    stream.forEachLine { line in
        envelopeLines += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            envelopeMalformed += 1
            return
        }
        envelopeRowsTotal += 1
        guard let ts = (obj["at"] as? String).flatMap(parseTimestamp) else { return }
        if envelopeNewest == nil || ts > envelopeNewest! { envelopeNewest = ts }
        guard ts >= windowStart else { return }
        envelopeRowsWindow += 1
        if (obj["insideBand"] as? NSNumber)?.boolValue == true { envelopeInsideBand += 1 }
        if (obj["envelopeOneBeat"] as? NSNumber)?.boolValue == true { envelopeOneBeat += 1 }
        if let c = (obj["replyCharacters"] as? NSNumber)?.doubleValue { envelopeReplyChars.append(c) }
    }
    sources.setRows("logs/delivery_envelope_telemetry.jsonl", envelopeRowsTotal)
    settleJSONLSource("logs/delivery_envelope_telemetry.jsonl",
                      lines: envelopeLines, malformed: envelopeMalformed)
}

// ── Trait dials — GROWTH.md frontmatter, which lives OUTSIDE the data root ───
let personaRoot: String = {
    if let p = personaRootArg { return absolutize(p) }
    return absolutize((resolvedDataRoot as NSString).deletingLastPathComponent + "/persona")
}()
let growthPath = (personaRoot as NSString).appendingPathComponent("GROWTH.md")
let growthPresent = sources.register("persona/GROWTH.md (outside data root)", growthPath,
                                     note: "read-only; trait-dial frontmatter source")
let traitDialNames = ["warmth", "brevity", "humor", "curiosity", "directness",
                      "playfulness", "caution", "formality"]
var traitDials: [String: Double] = [:]
var growthHasFrontmatter = false
if growthPresent, let text = try? String(contentsOfFile: growthPath, encoding: .utf8) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
        growthHasFrontmatter = true
        for l in lines.dropFirst() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[t.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if traitDialNames.contains(key), let d = Double(val) { traitDials[key] = d }
        }
    }
    sources.note("persona/GROWTH.md (outside data root)",
                 growthHasFrontmatter ? "frontmatter present; \(traitDials.count) dial(s) parsed"
                                      : "no `---` frontmatter block — all dials at the neutral default")
}

// Memory store (copy)
var memoriesTotal: Int?
var memoriesActive: Int?
var memoriesCreatedInWindow: Int?
var memoriesUsedInWindow: Int?
var memoryLatestUpdated: Date?
var proposalsByStatus: [(String, Int)] = []
var kgEntities: Int?
var kgRelationships: Int?
var kgIndexed: Int?
var kgEligible: Int?
var tombstonesInStore: Int?
var tombstoneNewestInStore: Date?
var proposalsPending: Int?
var proposalsNewestStaged: Date?
var embeddingEpochActive: String?
var embeddingEpochPrevious: String?
var embeddingEpochActivatedAt: Date?
var embeddingRollbackAvailable: Int?
var embeddingPreviousRows: Int?
var proposalsOffEpoch: Int?
var memoriesOffEpoch: Int?

if let db = memoryState.handle {
    memoriesTotal = db.int("SELECT COUNT(*) FROM memories;")
    memoriesActive = db.int("SELECT COUNT(*) FROM memories WHERE status='active';")
    let winISO = isoNoFraction.string(from: windowStart)
    memoriesCreatedInWindow = db.int("SELECT COUNT(*) FROM memories WHERE created_at >= '\(winISO)';")
    memoriesUsedInWindow = db.int("SELECT COUNT(*) FROM memories WHERE last_used_at >= '\(winISO)';")
    if let s = db.scalar("SELECT MAX(updated_at) FROM memories;") { memoryLatestUpdated = parseTimestamp(s) }
    proposalsByStatus = db.query("SELECT status, COUNT(*) FROM proposals GROUP BY 1 ORDER BY 2 DESC;")
        .compactMap { r in r.count >= 2 ? (r[0], Int(r[1]) ?? 0) : nil }
    kgEntities = db.int("SELECT COUNT(*) FROM kg_entities;")
    kgRelationships = db.int("SELECT COUNT(*) FROM kg_relationships;")
    kgIndexed = db.int("SELECT COUNT(*) FROM kg_memory_index;")
    // The indexer only covers ACTIVE, non-corrected, non-skill-pointer rows
    // (KnowledgeGraph+MemoryIndexing.swift rebuild query) — compare against
    // that, not `memories` total, or archived rows read as "unindexed".
    kgEligible = db.int("""
        SELECT COUNT(*) FROM memories WHERE status = 'active'
          AND TRIM(COALESCE(content, '')) <> ''
          AND lower(COALESCE(NULLIF(TRIM(lifecycle), ''), 'confirmed')) NOT IN ('corrected', 'contradicted', 'deleted')
          AND id NOT LIKE 'skill-pointer:%';
        """)
    // SYS-05 additions: the store's own housekeeping tables. Read here, on the
    // same copy and before `settleStore`, so a query failure condemns the whole
    // source exactly as it does for the section-(c) counters.
    tombstonesInStore = db.int("SELECT COUNT(*) FROM tombstones;")
    proposalsPending = db.int("SELECT COUNT(*) FROM proposals WHERE status='pending';")
    if let s = db.scalar("SELECT MAX(staged_at) FROM proposals;") { proposalsNewestStaged = parseTimestamp(s) }
    if let s = db.scalar("SELECT MAX(rejected_at) FROM tombstones;") { tombstoneNewestInStore = parseTimestamp(s) }
    embeddingEpochActive = db.scalar("SELECT active_epoch FROM memory_embedding_state WHERE id=1;")
    embeddingEpochPrevious = db.scalar("SELECT previous_epoch FROM memory_embedding_state WHERE id=1;")
    if let s = db.scalar("SELECT activated_at FROM memory_embedding_state WHERE id=1;") {
        embeddingEpochActivatedAt = parseTimestamp(s)
    }
    embeddingRollbackAvailable = db.int("SELECT rollback_available FROM memory_embedding_state WHERE id=1;")
    embeddingPreviousRows = db.int("SELECT COUNT(*) FROM memory_embedding_previous;")
    proposalsOffEpoch = db.int("""
        SELECT COUNT(*) FROM proposals WHERE embedding IS NOT NULL AND (
          embedding_epoch IS NULL OR
          embedding_epoch <> (SELECT active_epoch FROM memory_embedding_state WHERE id=1));
        """)
    memoriesOffEpoch = db.int("""
        SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL AND (
          embedding_epoch IS NULL OR
          embedding_epoch <> (SELECT active_epoch FROM memory_embedding_state WHERE id=1));
        """)
}
settleStore(&memoryState, "memory.sqlite")
let memoryDB = memoryState.handle

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SYSTEM ORGANS — wave-1 readers
//
// Sections (a)–(g) grade the COGNITIVE system against `docs/SUBCONSCIOUS.md`.
// These readers feed section (h), the SYSTEM MATRIX, which grades the
// FUNCTIONAL system — "all the inner workings" — against
// `docs/ARCHITECTURE_BLUEPRINT.md`: the bridges, the background loops, the
// delegation ledger, the notification/push lanes, the memory store's own
// housekeeping, Workshop, the GitHub command lane, and the heartbeat.
//
// Same three rules as every reader above, no exceptions:
//   • sqlite is queried on a COPY (these organs reuse the copies made at the
//     top; no organ opens a live database),
//   • JSONL is streamed read-only with its malformed lines counted,
//   • a missing source is `source absent` and an unreadable one is
//     `source unreadable` — NEVER a zero. An organ whose feed did not read is
//     `not-yet`, and its reading says which of the two it was.
// ─────────────────────────────────────────────────────────────────────────────

/// What happened when a feed was read. `.absent` and `.unreadable` are
/// different facts and neither is a number.
enum FeedState {
    case absent
    case unreadable(String)
    case read(rows: Int)

    var didRead: Bool { if case .read = self { return true }; return false }
    /// The label to render INSTEAD of any derived number. nil when the feed read.
    var blockedLabel: String? {
        switch self {
        case .absent: return "source absent"
        case .unreadable(let r): return "source unreadable — " + r
        case .read: return nil
        }
    }
}

/// Marks a registered source unreadable AND raises the matching lead. Same
/// contract as `settleJSONLSource` / `markStoreUnreadable`: sections skipped,
/// nothing rendered, least of all a zero.
func markFeedUnreadable(_ label: String, _ reason: String) {
    guard !sources.isUnreadable(label) else { return }
    sources.note(label, "UNREADABLE — " + reason)
    sources.markUnreadable(label, reason)
    addLead(rank: 3, "Source `\(mdCode(label))` is UNREADABLE — \(mdCode(reason))",
            evidence: "`\(mdCode(label))`: \(mdCode(reason)). Nothing is derived from it — not even a zero, "
                + "because \"we could not read it\" and \"it is empty\" are different facts.",
            action: "Check the file's permissions, that it is not mid-rewrite, and that its writer still "
                + "produces the shape this reader expects. Until it reads clean, every organ metric that "
                + "depends on it is unknown, not zero.")
}

/// Register + stream one JSONL organ feed. The body sees only rows that PARSED;
/// malformed lines are counted and the shared 10% guard decides unreadability.
@discardableResult
func organJSONL(_ label: String, _ path: String, note: String = "streamed read-only",
                _ body: ([String: Any]) -> Void) -> FeedState {
    guard sources.register(label, path, note: note) else { return .absent }
    guard let stream = LineStream(path: path) else {
        let reason = "present but could not be opened for reading"
        markFeedUnreadable(label, reason)
        return .unreadable(reason)
    }
    var total = 0, malformed = 0
    stream.forEachLine { line in
        total += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformed += 1
            return
        }
        body(obj)
    }
    sources.setRows(label, total - malformed)
    settleJSONLSource(label, lines: total, malformed: malformed)
    if sources.isUnreadable(label) { return .unreadable(sources.reason(label)) }
    return .read(rows: total - malformed)
}

/// Register + parse one JSON organ file. A present file that will not parse is
/// UNREADABLE, not an empty object — the difference is the whole point.
func organJSON(_ label: String, _ path: String, note: String = "read-only JSON") -> (Any?, FeedState) {
    guard sources.register(label, path, note: note) else { return (nil, .absent) }
    guard let data = fm.contents(atPath: path) else {
        let reason = "present but could not be read"
        markFeedUnreadable(label, reason)
        return (nil, .unreadable(reason))
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) else {
        let reason = "present but is not valid JSON (\(data.count) byte(s))"
        markFeedUnreadable(label, reason)
        return (nil, .unreadable(reason))
    }
    return (obj, .read(rows: 1))
}

func organJSONObject(_ label: String, _ path: String, note: String = "read-only JSON")
    -> ([String: Any]?, FeedState) {
    let (raw, state) = organJSON(label, path, note: note)
    guard state.didRead else { return (nil, state) }
    guard let obj = raw as? [String: Any] else {
        let reason = "present but the top level is not a JSON object"
        markFeedUnreadable(label, reason)
        return (nil, .unreadable(reason))
    }
    return (obj, state)
}

/// Guard flag for the directory-listing rule below, hoisted so a mutation test
/// can switch it off and prove the assertion that depends on it goes red.
let organDirGuard = true

/// List a DIRECTORY that a reader enumerates BY HAND, with the same contract as
/// `organJSONL` / `organJSON`.
///
/// `(try? fm.contentsOfDirectory(atPath:)) ?? []` was the hole: a directory that
/// EXISTS and cannot be listed — mode 000, a dead mount, an ACL — came back as
/// an empty array, and the reader downstream reported "present, 0 entries". That
/// is the silent zero wearing a directory's clothes, and it ranks the organ
/// HEALTHY on a feed nobody could read. A listing failure is now UNREADABLE,
/// carries its reason, and drops the organ to severity rank 0.
func organDirectory(_ label: String, _ path: String) -> (entries: [String], state: FeedState) {
    guard organDirGuard else { return (((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted(), .read(rows: 0)) }
    // An ABSENT directory is absent, never unreadable: an optional child dir
    // (e.g. mobile_snapshot_cache/responses on a fresh install) must not
    // condemn its parent organ and win worst-organ (gpt-5.5 wave-2 review).
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return ([], .absent)
    }
    do {
        return (try fm.contentsOfDirectory(atPath: path).sorted(), .read(rows: 0))
    } catch {
        let reason = "directory present but could not be listed — "
            + (error as NSError).localizedDescription
        markFeedUnreadable(label, reason)
        return ([], .unreadable(reason))
    }
}

/// Guard flag for the unparseable-family rule, hoisted for the same reason.
let organUnparseableGuard = true

/// The directory-family twin of `settleJSONLSource`'s malformed-ratio gate: a
/// family where EVERY record (or >= 10% of them) will not parse is UNREADABLE,
/// not a thin one — the surviving records cannot say what they are a sample OF.
/// Below that bar the count is surfaced in the organ's row instead of hidden.
/// Returns the unreadable state when it condemns, nil when it does not.
func condemnUnparseableFamily(_ label: String, total: Int, unparseable: Int) -> FeedState? {
    guard organUnparseableGuard,
          malformedRatioTooHigh(lines: total, malformed: unparseable) else { return nil }
    let pct = Double(unparseable) / Double(total) * 100
    let reason = "\(unparseable) of \(total) record(s) in this family would not parse (\(fmt(pct, 1))%)"
    markFeedUnreadable(label, reason)
    return .unreadable(reason)
}

/// A reader that genuinely enumerates an instance-named FAMILY (every
/// `workshop/executions/<id>/execution.json`, every `*.claim`) declares the
/// family key here so the reach walk stops calling it a blind spot. Only a
/// family the reader actually opens may be claimed — an inventory-only glance
/// is NOT coverage, and those stay in NOT COVERED on purpose.
var extraFeedClaims: [String: String] = [:]
func claimFeedFamily(_ normalizedKey: String, by label: String) {
    extraFeedClaims[normalizedKey] = label
}

/// Labels whose registered path is a DIRECTORY used only to test presence, and
/// which must NOT claim their whole subtree. `workshop/executions/` holds a
/// `timeline.jsonl` and per-step receipt files this instrument does not parse;
/// claiming them because the reader opened `execution.json` next door would be
/// exactly the overclaim the NOT COVERED list exists to prevent.
var noAutoClaimLabels: Set<String> = []

func daysSince(_ d: Date) -> Double { now.timeIntervalSince(d) / 86400 }
func hoursSince(_ d: Date) -> Double { now.timeIntervalSince(d) / 3600 }

/// Ages for display. `now` is captured once at startup and a full run takes
/// seconds, so on a LIVE root a loop tick or a lease renewal that lands
/// mid-run is genuinely stamped after `now`. That is normal, not a clock bug —
/// render it as zero and say why, rather than printing `-0.0h` and inviting
/// somebody to go hunting for a subtraction error. The staleness comparisons
/// are all `>` against a positive bound, so a future stamp never trips one.
func ageDaysText(_ d: Date) -> String {
    let v = daysSince(d)
    return v < 0 ? "0.0d (stamped during this run)" : fmt(v, 1) + "d"
}
func ageHoursText(_ d: Date) -> String {
    let v = hoursSince(d)
    return v < 0 ? "0.0h (stamped during this run)" : fmt(v, 1) + "h"
}
func newer(_ a: Date?, _ b: Date?) -> Date? {
    guard let a else { return b }
    guard let b else { return a }
    return a > b ? a : b
}

// ContextFlow's SQLite store replaced the old per-generation JSON receipts.
// Those receipts remain intentionally readable for an explicitly named run,
// but a current-context resolver must never rediscover them by scanning the
// directory.  This census opens no receipt content: it only measures the
// direct `context/*.json` fossils and the cache subtree against the SQLite
// file's birth time, which is the durable on-disk cutover marker.
struct LegacyContextCensus {
    var files = 0
    var bytes: Int64 = 0
    var newest: Date?
}

func scanLegacyContextFiles(
    at directory: String,
    recursive: Bool,
    including: (URL) -> Bool = { _ in true }
) -> (LegacyContextCensus?, String?) {
    var census = LegacyContextCensus()
    let urls: [URL]
    if recursive {
        var listingError: String?
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                listingError = "could not enumerate \(url.path): \(error.localizedDescription)"
                return false
            }
        ) else {
            return (nil, "directory present but could not be enumerated")
        }
        var collected: [URL] = []
        for case let url as URL in enumerator { collected.append(url) }
        if let listingError { return (nil, listingError) }
        urls = collected
    } else {
        do {
            urls = try fm.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                             .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return (nil, "directory present but could not be listed — \(error.localizedDescription)")
        }
    }

    for url in urls where including(url) {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                       .fileSizeKey, .contentModificationDateKey])
        } catch {
            return (nil, "could not read metadata for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
        census.files += 1
        census.bytes += Int64(values.fileSize ?? 0)
        census.newest = newer(census.newest, values.contentModificationDate)
    }
    return (census, nil)
}

let contextSQLitePath = rootPath("context/context.sqlite")
let contextSQLitePresent = sources.register("context/context.sqlite", contextSQLitePath,
                                             note: "filesystem metadata only; birth time is the JSON cutover")
var contextSQLiteCutover: Date?
if contextSQLitePresent {
    do {
        let attributes = try fm.attributesOfItem(atPath: contextSQLitePath)
        guard let birth = attributes[.creationDate] as? Date else {
            markFeedUnreadable("context/context.sqlite", "file has no filesystem creation date for the cutover")
            throw NSError(domain: "agent_instrument", code: 1)
        }
        contextSQLiteCutover = birth
    } catch {
        if !sources.isUnreadable("context/context.sqlite") {
            markFeedUnreadable("context/context.sqlite", "could not read filesystem metadata — \(error.localizedDescription)")
        }
    }
}

let legacyContextJSONLabel = "context/*.json"
let legacyContextDirectory = rootPath("context")
let legacyContextJSONPresent = sources.register(legacyContextJSONLabel, legacyContextDirectory,
                                                 note: "direct legacy generation receipts; metadata only")
// The source path is the parent directory solely so it can be listed.  Do not
// let that presence claim context.sqlite, feedback, or any future context feed.
noAutoClaimLabels.insert(legacyContextJSONLabel)
claimFeedFamily("context/*.json", by: legacyContextJSONLabel)
var legacyContextJSONCensus: LegacyContextCensus?
if legacyContextJSONPresent {
    let (census, reason) = scanLegacyContextFiles(
        at: legacyContextDirectory,
        recursive: false,
        including: { url in
            url.pathExtension.lowercased() == "json"
                && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
    )
    if let reason {
        markFeedUnreadable(legacyContextJSONLabel, reason)
    } else if let census {
        legacyContextJSONCensus = census
        sources.setRows(legacyContextJSONLabel, census.files)
    }
}

let legacyContextCacheLabel = "context/cache/"
let legacyContextCachePath = rootPath("context/cache")
let legacyContextCachePresent = sources.register(legacyContextCacheLabel, legacyContextCachePath,
                                                  note: "legacy context cache subtree; metadata only")
var legacyContextCacheCensus: LegacyContextCensus?
if legacyContextCachePresent {
    let (census, reason) = scanLegacyContextFiles(at: legacyContextCachePath, recursive: true)
    if let reason {
        markFeedUnreadable(legacyContextCacheLabel, reason)
    } else if let census {
        legacyContextCacheCensus = census
        sources.setRows(legacyContextCacheLabel, census.files)
    }
}

func legacyContextCutoverStatus(_ census: LegacyContextCensus?, _ cutover: Date?) -> String {
    guard let census else { return "unmeasured" }
    guard census.files > 0 else { return "EMPTY (no legacy files)" }
    guard let newest = census.newest, let cutover else { return "CUTOVER UNAVAILABLE" }
    return newest < cutover ? "FROZEN before SQLite cutover" : "ACTIVE AFTER CUTOVER"
}
/// Table-cell rendering of an errorDetail histogram: each reason is clipped
/// to 90 chars (the receipt already caps at 200; a table cell wants less) and
/// wrapped in a code span so GFM pipes/backticks cannot break the row.
func shortDetail(_ s: String, _ limit: Int = 90) -> String {
    let flat = flattenLines(s)
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
}
/// `inTable: true` (the SYS-10 detail table) escapes GFM pipes inside the code
/// span; `false` (LEAD evidence, a bullet) leaves them for `mdComposed`, which
/// already escapes once — pre-escaping there would print `\\|`.
func topDetails(_ d: [String: Int], _ n: Int = 2, inTable: Bool = true) -> String {
    d.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(n)
        .map { entry -> String in
            let text = shortDetail(entry.key).replacingOccurrences(of: "`", with: "")
            return "`\(inTable ? mdCode(text) : text)`×\(entry.value)"
        }.joined(separator: ", ")
}
func topCounts(_ d: [String: Int], _ n: Int = 4) -> String {
    d.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(n)
        .map { "\(mdText($0.key))=\($0.value)" }.joined(separator: ", ")
}

// ── SYS-01: agent bridges (claude / codex / OMP wake lanes) ─────────────────
//
// The wake lanes are the app's own `bridgeConfigDirectory(named:)` layout and
// live OUTSIDE the data root (`~/.config/<lane>-bridge/…` by default), exactly
// like `persona/GROWTH.md`. They are read-only here and never participate in
// the reach walk's coverage map; `--no-bridge-config` turns them off entirely
// for a frozen-root determinism check.

/// Machine-global state (the `~/.config` bridge lanes, the installed app
/// bundle, the app's preferences domain) is read BY DEFAULT only when the data
/// root is a real install root — the repo's `./data` or the app-support
/// default. A fixture/synthetic root must stay hermetic: the same rule the app
/// uses for process-global tools (`allowProcessGlobalTools: dataRoot ==
/// default`). Every organ that reaches outside the data root gates on this.
let bridgeConfigRoot: String? = {
    if bridgeConfigDisabled { return nil }
    if let a = bridgeConfigRootArg { return absolutize(a) }
    // Explicit --bridge-config-root overrides for unusual layouts.
    guard dataRootIsInstallRoot else { return nil }
    let def = absolutize("~/.config")
    return fm.fileExists(atPath: def) ? def : nil
}()


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Triage acknowledgments (docs/eval_acknowledgments.json)
//
// An acknowledgment NEVER deletes or hides data: it moves rows matching a
// detector + created-before horizon out of the ALARMING count into a quiet
// "acknowledged" count, with the ledger file as the receipt. Rows after the
// horizon still alarm. The ledger lives in the REPO (docs/), not the data
// root — triage verdicts are versioned engineering judgments. Resolved only
// when the data root's parent actually carries the ledger; otherwise every
// finding stays fresh (fixture roots, foreign roots).
// ─────────────────────────────────────────────────────────────────────────────
struct EvalAcknowledgment {
    let detector: String
    let horizon: Date
    let verdict: String
    let tracked: String
}
let evalAcknowledgments: [EvalAcknowledgment] = {
    let ledgerPath = ((resolvedDataRoot as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("docs/eval_acknowledgments.json")
    guard let data = fm.contents(atPath: ledgerPath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = obj["acknowledgments"] as? [[String: Any]] else { return [] }
    return entries.compactMap { e in
        guard let d = e["detector"] as? String,
              let h = (e["horizon"] as? String).flatMap(parseTimestamp),
              let v = e["verdict"] as? String else { return nil }
        return EvalAcknowledgment(detector: d, horizon: h, verdict: v,
                                  tracked: (e["tracked"] as? String) ?? "(untracked)")
    }
}()
func acknowledgmentHorizon(_ detector: String) -> Date? {
    evalAcknowledgments.first { $0.detector == detector }?.horizon
}

struct BridgeLane {
    var name: String
    var dirPath: String
    var dirPresent = false
    var inbox: FeedState = .absent
    var inboxRows = 0
    var inboxInWindow = 0
    var inboxUnread = 0
    var inboxNewest: Date?
    var deliveries: FeedState = .absent
    var deliveriesInWindow = 0
    var deliveryStatuses: [String: Int] = [:]
    var deliveryNewest: Date?
    var terminalFailedUnread = 0
    var terminalFailedOldest: Date?
    var undeliveredOver24h = 0
    var undeliveredAcknowledged = 0   // pre-horizon rows covered by the triage ledger
    var undeliveredOldest: Date?
    var jobsPresent = false
    /// The jobs DIRECTORY's own read outcome. `jobsPresent` only says the
    /// directory exists; this says whether it could be listed and parsed. A
    /// present-but-unlistable directory is `.unreadable`, never "0 jobs".
    var jobs: FeedState = .absent
    var jobsTotal = 0
    var jobsInWindow = 0
    var jobStates: [String: Int] = [:]
    var jobsUnparseable = 0
    var jobsStaleHeartbeat = 0
    var jobsHeldUnreleased = 0
    var jobsSettledHoldResidue = 0   // inert: settled jobs whose hold was never formally released
    var jobsCapped = false
    /// `<jobsDir>/undelivered/` — replies the codex bridge PRESERVED (full text)
    /// because their delivery settled ambiguous (409 / outcome_unknown) and
    /// nothing may replay them. Completed work nobody acknowledged. The
    /// directory is created lazily by the first preserve, so "no directory"
    /// is a genuine "nothing preserved", rendered as `—`, never as 0 and never
    /// as a missing source; a directory that exists is read like any other
    /// job family (unlistable → unreadable, garbage → condemned).
    var preservedDirPresent = false
    var preserved: FeedState = .absent
    var preservedCount = 0
    var preservedUnparseable = 0
    var preservedOldest: Date?
    var preservedCapped = false

    /// Did any feed of this lane actually read?
    var measured: Bool { inbox.didRead || deliveries.didRead || jobs.didRead }
}

/// The per-file cap on wake-job directories. A lane with more jobs than this is
/// reported as capped — a truncated count that SAYS it is truncated.
let wakeJobFileCap = 512

/// Every messageId that has a delivery receipt, per lane. Filled by the
/// delivery pass and consumed by the inbox pass, which is why the delivery feed
/// is read FIRST: with an empty set every message looks undelivered, and a
/// fabricated backlog is the same silent-zero sin in the other direction.
var deliveredMessageIDs: [String: Set<String>] = [:]

func readBridgeLane(_ name: String, dirName: String, inboxFile: String,
                    deliveryFile: String, jobsDirName: String?) -> BridgeLane {
    guard let cfgRoot = bridgeConfigRoot else {
        return BridgeLane(name: name, dirPath: "(bridge config root not read)")
    }
    let dir = (cfgRoot as NSString).appendingPathComponent(dirName)
    var lane = BridgeLane(name: name, dirPath: dir)
    var isD: ObjCBool = false
    lane.dirPresent = fm.fileExists(atPath: dir, isDirectory: &isD) && isD.boolValue

    // Read reply deliveries first as a compatibility fallback for old inbox
    // rows that predate explicit consumption stamps.
    let deliveryLabel = "bridge/\(name)/\(deliveryFile)"
    lane.deliveries = organJSONL(deliveryLabel, (dir as NSString).appendingPathComponent(deliveryFile),
                                 note: "streamed read-only (outside the data root)") { obj in
        var ids: [String] = []
        if let one = obj["messageId"] as? String { ids.append(one) }
        if let many = obj["messageIds"] as? [Any] { ids.append(contentsOf: many.compactMap { $0 as? String }) }
        deliveredMessageIDs[name, default: []].formUnion(ids)
        // Status lives at the top level (`status`) on the claude/OMP lanes and
        // inside `turnResult.status` on the codex reply lane. A row with
        // neither is counted under an explicit "(no status field)" bucket —
        // never dropped, because a delivery nobody can grade is a finding.
        var status = obj["status"] as? String
        if status == nil, let tr = obj["turnResult"] as? [String: Any] {
            status = tr["status"] as? String
        }
        if status == nil, let attempts = obj["attempts"] as? [Any],
           let last = attempts.last as? [String: Any],
           let tr = last["turnResult"] as? [String: Any] {
            status = tr["status"] as? String
        }
        let ts = ((obj["createdAt"] as? String) ?? (obj["at"] as? String)).flatMap(parseTimestamp)
        if let ts { lane.deliveryNewest = newer(lane.deliveryNewest, ts) }
        guard let ts, ts >= windowStart else { return }
        lane.deliveriesInWindow += 1
        lane.deliveryStatuses[status ?? "(no status field)", default: 0] += 1
    }

    let delivered = deliveredMessageIDs[name] ?? []
    let inboxLabel = "bridge/\(name)/\(inboxFile)"
    lane.inbox = organJSONL(inboxLabel, (dir as NSString).appendingPathComponent(inboxFile),
                            note: "streamed read-only (outside the data root)") { obj in
        lane.inboxRows += 1
        let read = (obj["read"] as? Bool) ?? false
        if !read { lane.inboxUnread += 1 }
        let ts = ((obj["createdAt"] as? String) ?? (obj["created_at"] as? String)).flatMap(parseTimestamp)
        if let ts { lane.inboxNewest = newer(lane.inboxNewest, ts) }
        if let ts, ts >= windowStart { lane.inboxInWindow += 1 }
        // An inbound bridge message is handed to its agent when the INBOX row
        // is consumed/read. reply-deliveries.jsonl describes a later, optional
        // outbound reply and cannot be the primary consumption receipt: using
        // it made acknowledged fire-and-forget messages look abandoned. Keep a
        // matching reply receipt only as a compatibility proof for older rows.
        let consumedAt = ((obj["consumedAt"] as? String) ?? (obj["readAt"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let consumed = read || !(consumedAt ?? "").isEmpty
        // A dead-letter is neither consumed nor still waiting: delivery
        // terminally failed and the durable brief remains unread for review.
        // Keep that actionable class separate so it cannot masquerade as a
        // wedged inbox consumer.
        let deliveryStatus = (obj["deliveryStatus"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !read, deliveryStatus == "dead_letter" {
            lane.terminalFailedUnread += 1
            let terminalAt = (obj["deliveryTerminalAt"] as? String).flatMap(parseTimestamp) ?? ts
            if let terminalAt,
               lane.terminalFailedOldest == nil || terminalAt < lane.terminalFailedOldest! {
                lane.terminalFailedOldest = terminalAt
            }
            return
        }
        guard let id = obj["messageId"] as? String ?? obj["id"] as? String,
              !consumed, !delivered.contains(id), let ts, hoursSince(ts) > 24 else { return }
        if let hz = acknowledgmentHorizon("bridge.undelivered"), ts < hz {
            lane.undeliveredAcknowledged += 1
            return
        }
        lane.undeliveredOver24h += 1
        if lane.undeliveredOldest == nil || ts < lane.undeliveredOldest! { lane.undeliveredOldest = ts }
    }

    guard let jobsDirName else { return lane }
    let jobsDir = (dir as NSString).appendingPathComponent(jobsDirName)
    let jobsLabel = "bridge/\(name)/\(jobsDirName)/"
    var isJobDir: ObjCBool = false
    lane.jobsPresent = fm.fileExists(atPath: jobsDir, isDirectory: &isJobDir) && isJobDir.boolValue
    sources.register(jobsLabel, jobsDir, note: "job files read read-only (outside the data root)")
    guard lane.jobsPresent else { return lane }
    // A jobs directory that EXISTS and will not list is UNREADABLE, not empty.
    let (jobEntries, jobDirState) = organDirectory(jobsLabel, jobsDir)
    guard jobDirState.didRead else { lane.jobs = jobDirState; return lane }
    let names = jobEntries.filter { $0.hasSuffix(".json") }
    lane.jobsCapped = names.count > wakeJobFileCap
    for fileName in names.prefix(wakeJobFileCap) {
        let p = (jobsDir as NSString).appendingPathComponent(fileName)
        guard let data = fm.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lane.jobStates["(unparseable job file)", default: 0] += 1
            lane.jobsUnparseable += 1
            lane.jobsTotal += 1
            continue
        }
        lane.jobsTotal += 1
        // Window membership comes from the job's own `createdAt`. A job file
        // with no parseable stamp counts toward the total and NOT toward the
        // window — an undated job is not evidence of recent traffic.
        if let c = (obj["createdAt"] as? String).flatMap(parseTimestamp), c >= windowStart {
            lane.jobsInWindow += 1
        }
        let state = (obj["state"] as? String) ?? "(no state field)"
        lane.jobStates[state, default: 0] += 1
        // A job that is not settled and whose heartbeat stopped an hour ago is
        // a stalled worker — the single most useful thing this lane can say.
        if state != "settled", let hb = (obj["heartbeatAt"] as? String).flatMap(parseTimestamp),
           hoursSince(hb) > 1 {
            lane.jobsStaleHeartbeat += 1
        }
        let releasedAt = obj["holdReleasedAt"]
        let stillHeld = releasedAt == nil || (releasedAt as? NSNull) != nil
        // A hold matters only while the job is LIVE. A settled job whose hold
        // was never formally released is inert residue — the wake finished,
        // nothing waits on the release (triage 2026-08-21: all 46 flagged
        // holds were state=settled). Counting those as an alarm teaches
        // readers to ignore the lead; they get their own quiet residue count.
        if (obj["commitPolicy"] as? String) == "hold", stillHeld {
            if state == "settled" { lane.jobsSettledHoldResidue += 1 }
            else { lane.jobsHeldUnreleased += 1 }
        }
    }
    sources.setRows(jobsLabel, lane.jobsTotal - lane.jobsUnparseable)
    // A jobs family where every file (or >= 10% of them) is garbage is a broken
    // writer, not a quiet lane: condemn it rather than reporting job states
    // derived from the handful that happened to survive.
    lane.jobs = condemnUnparseableFamily(jobsLabel, total: lane.jobsTotal,
                                         unparseable: lane.jobsUnparseable)
        ?? .read(rows: lane.jobsTotal)

    // Preserved replies: `<jobsDir>/undelivered/`. The jobs scan above filters
    // `*.json` files and so never descends here — which is exactly why the
    // bridge moves a reply there (out of the relaunch scan path), and exactly
    // why this lane was blind to 13 completed-but-unacknowledged replies for
    // two weeks (triage 2026-08-21). Registered ONLY when the directory exists:
    // it is created lazily by the first preserve, so on a lane that never
    // preserved anything an "absent" registration would mark a healthy organ
    // partial forever.
    let preservedDir = (jobsDir as NSString).appendingPathComponent("undelivered")
    var isPreservedDir: ObjCBool = false
    lane.preservedDirPresent = fm.fileExists(atPath: preservedDir, isDirectory: &isPreservedDir)
        && isPreservedDir.boolValue
    guard lane.preservedDirPresent else { return lane }
    let preservedLabel = "bridge/\(name)/\(jobsDirName)/undelivered/"
    sources.register(preservedLabel, preservedDir,
                     note: "preserved (undeliverable) reply files read read-only (outside the data root)")
    let (preservedEntries, preservedState) = organDirectory(preservedLabel, preservedDir)
    guard preservedState.didRead else { lane.preserved = preservedState; return lane }
    let preservedNames = preservedEntries.filter { $0.hasSuffix(".json") }
    lane.preservedCapped = preservedNames.count > wakeJobFileCap
    for fileName in preservedNames.prefix(wakeJobFileCap) {
        let p = (preservedDir as NSString).appendingPathComponent(fileName)
        lane.preservedCount += 1
        guard let data = fm.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lane.preservedUnparseable += 1
            continue
        }
        // Age is the reply's OWN completion stamp (completedExecution.turnResult
        // .completedAt), falling back to the job's createdAt. The file's mtime
        // is deliberately not used: a rename keeps it, a chmod does not, and
        // "how long has this completed work sat unacknowledged" is a question
        // about the work, not the inode.
        var stamp: Date?
        if let exec = obj["completedExecution"] as? [String: Any],
           let tr = exec["turnResult"] as? [String: Any] {
            stamp = (tr["completedAt"] as? String).flatMap(parseTimestamp)
        }
        if stamp == nil { stamp = (obj["createdAt"] as? String).flatMap(parseTimestamp) }
        if let stamp, lane.preservedOldest == nil || stamp < lane.preservedOldest! {
            lane.preservedOldest = stamp
        }
    }
    sources.setRows(preservedLabel, lane.preservedCount - lane.preservedUnparseable)
    lane.preserved = condemnUnparseableFamily(preservedLabel, total: lane.preservedCount,
                                              unparseable: lane.preservedUnparseable)
        ?? .read(rows: lane.preservedCount)
    return lane
}

var bridgeLanes: [BridgeLane] = []
if bridgeConfigRoot != nil {
    bridgeLanes = [
        readBridgeLane("claude", dirName: "claude-bridge", inboxFile: "claude-inbox.jsonl",
                       deliveryFile: "wake-deliveries.jsonl", jobsDirName: "wake-jobs"),
        readBridgeLane("codex", dirName: "codex-nativeagent-bridge", inboxFile: "codex-inbox.jsonl",
                       deliveryFile: "reply-deliveries.jsonl", jobsDirName: "reply-jobs"),
        readBridgeLane("omp", dirName: "omp-bridge", inboxFile: "omp-inbox.jsonl",
                       deliveryFile: "wake-deliveries.jsonl", jobsDirName: "wake-jobs"),
    ]
}

// ── SYS-02: background loops ────────────────────────────────────────────────
// Blueprint § Background Loops: `LoopRunner.tickOutcome()` is the scheduler's
// truth boundary and the production scheduler records bounded failure evidence
// at `data/logs/background_loop_failures.jsonl`. Two caveats this reader states
// rather than hides: that feed is LINE-CAPPED (old rows are evicted, so counts
// are a lower bound) and offline-classified errors are deliberately never
// written — an absent failure row is not proof of a healthy tick.

var loopLastRun: [String: Date] = [:]
var loopStateVersion: String?
let (loopStateObj, loopStateFeed) = organJSONObject("logs/background_loop_state.json",
                                                    rootPath("logs/background_loop_state.json"))
if let loopStateObj {
    loopStateVersion = loopStateObj["version"] as? String
    if let loops = loopStateObj["loops"] as? [String: Any] {
        for (k, v) in loops {
            if let s = v as? String, let d = parseTimestamp(s) { loopLastRun[k] = d }
        }
    }
    sources.setRows("logs/background_loop_state.json", loopLastRun.count)
}

var loopFailuresInWindow = 0
var loopFailuresByLoop: [String: Int] = [:]
var loopFailureNewest: [String: Date] = [:]
var loopFailureSignatures: [String: Int] = [:]
var loopPushStampsInWindow = 0
var loopFailureRowsTotal = 0
let loopFailuresFeed = organJSONL("logs/background_loop_failures.jsonl",
                                  rootPath("logs/background_loop_failures.jsonl")) { obj in
    let kind = (obj["kind"] as? String) ?? "(no kind field)"
    if kind == "failure_push" {
        if let ts = (obj["pushedAt"] as? String).flatMap(parseTimestamp), ts >= windowStart {
            loopPushStampsInWindow += 1
        }
        return
    }
    loopFailureRowsTotal += 1
    let loopId = (obj["loopId"] as? String) ?? "(no loopId field)"
    guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp) else { return }
    loopFailureNewest[loopId] = newer(loopFailureNewest[loopId], ts)
    guard ts >= windowStart else { return }
    loopFailuresInWindow += 1
    loopFailuresByLoop[loopId, default: 0] += 1
    // First clause of the error string, so 2,000 distinct URLSession messages
    // collapse into the handful of real signatures behind them.
    if let e = obj["error"] as? String {
        let head = e.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? e
        loopFailureSignatures[String(head.prefix(90)), default: 0] += 1
    }
}

// Oldest tick first, TIES BROKEN ON LOOP ID. Loops driven by the same scheduler
// pass land on the identical second; without the id tiebreak `loopsStale.first`
// — which names the loop in SYS-02's BOOM severity reason — flips between runs
// over the very same bytes.
let loopsStale = loopLastRun.filter { daysSince($0.value) > 1 }
    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
let loopWorstFailing = loopFailuresByLoop.sorted {
    $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
}.first

// ── SYS-03: delegation / orchestration ──────────────────────────────────────
// Blueprint § Desk Work Ownership + § State Ownership. Three feeds: the append
// ledger (already read for section (d)), its reduced state, and the cursor the
// delegation-outcome loop keeps per bridge store — that cursor's `last_seen` is
// the one number that says whether outcomes are still being carded.

var taskStateCounts: [String: Int] = [:]
var taskStateNewest: Date?
var taskStateTotal = 0
var taskStateGeneratedAt: Date?
let (taskStateObj, taskStateFeed) = organJSONObject("orchestration/task_ledger_state.json",
                                                    rootPath("orchestration/task_ledger_state.json"))
if let taskStateObj {
    taskStateGeneratedAt = (taskStateObj["generatedTs"] as? String).flatMap(parseTimestamp)
    if let tasks = taskStateObj["tasks"] as? [[String: Any]] {
        taskStateTotal = tasks.count
        for t in tasks {
            taskStateCounts[(t["status"] as? String) ?? "(no status field)", default: 0] += 1
            if let u = (t["updatedTs"] as? String).flatMap(parseTimestamp) {
                taskStateNewest = newer(taskStateNewest, u)
            }
        }
    }
    sources.setRows("orchestration/task_ledger_state.json", taskStateTotal)
}

struct DelegationCursorStore { var name: String; var carded: Int; var lastSeen: Date?; var lastSeenRaw: String? }
var delegationCursors: [DelegationCursorStore] = []
let (cursorObj, cursorFeed) = organJSONObject("logs/delegation_outcome_cursor.json",
                                              rootPath("logs/delegation_outcome_cursor.json"))
if let cursorObj, let stores = cursorObj["stores"] as? [String: Any] {
    for (name, raw) in stores.sorted(by: { $0.key < $1.key }) {
        let o = raw as? [String: Any] ?? [:]
        let lastSeenRaw = o["last_seen"] as? String
        delegationCursors.append(DelegationCursorStore(
            name: name,
            carded: (o["carded_ids"] as? [Any])?.count ?? 0,
            lastSeen: lastSeenRaw.flatMap(parseTimestamp),
            lastSeenRaw: lastSeenRaw))
    }
    sources.setRows("logs/delegation_outcome_cursor.json", delegationCursors.count)
}

var deskArchivedInWindow = 0
var deskArchivedTotal = 0
var deskArchiveNewest: Date?
let deskArchiveFeed = organJSONL("desk/desk_archive.jsonl", rootPath("desk/desk_archive.jsonl")) { obj in
    deskArchivedTotal += 1
    let ts = ((obj["archivedAt"] as? String) ?? (obj["ts"] as? String) ?? (obj["closedAt"] as? String))
        .flatMap(parseTimestamp)
    if let ts { deskArchiveNewest = newer(deskArchiveNewest, ts) }
    if let ts, ts >= windowStart { deskArchivedInWindow += 1 }
}

// ── SYS-04: notifications / push delivery ───────────────────────────────────
// Blueprint § State Ownership: "Notifications/activity/inbox: app-owned ledgers
// under data/; APNS sends through Swift app paths." Section (d) already counts
// the inbox cards; this organ goes one layer deeper, to whether the send
// actually LANDED — APNs receipts, iCloud/CloudKit chat receipts, token age.

var pushStatusInWindow: [String: Int] = [:]
var pushErrorsInWindow: [String: Int] = [:]
var pushRowsInWindow = 0
var pushNewest: Date?
var pushMaxTokenAgeDays: Double?
let pushFeed = organJSONL("mobile_push/receipts.jsonl", rootPath("mobile_push/receipts.jsonl")) { obj in
    guard let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp) else { return }
    pushNewest = newer(pushNewest, ts)
    guard ts >= windowStart else { return }
    pushRowsInWindow += 1
    let status = (obj["status"] as? String) ?? "(no status field)"
    pushStatusInWindow[status, default: 0] += 1
    if status != "ok", let e = obj["error"] as? String, !e.isEmpty {
        pushErrorsInWindow[String(e.prefix(90)), default: 0] += 1
    }
    if let age = obj["tokenAgeSeconds"] as? Double {
        let d = age / 86400
        if pushMaxTokenAgeDays == nil || d > pushMaxTokenAgeDays! { pushMaxTokenAgeDays = d }
    }
}

var pushTokenCount: Int?
var pushTokenNewest: Date?
let (pushTokensObj, pushTokensFeed) = organJSONObject("notifications/push_tokens.json",
                                                      rootPath("notifications/push_tokens.json"))
if let pushTokensObj {
    let tokens = (pushTokensObj["tokens"] as? [Any])?.count
        ?? (pushTokensObj["devices"] as? [Any])?.count
        ?? pushTokensObj.count
    pushTokenCount = tokens
    for (_, v) in pushTokensObj {
        if let o = v as? [String: Any], let u = (o["updatedAt"] as? String).flatMap(parseTimestamp) {
            pushTokenNewest = newer(pushTokenNewest, u)
        }
    }
    sources.setRows("notifications/push_tokens.json", tokens)
}

var icloudStatusInWindow: [String: Int] = [:]
var icloudDirectionInWindow: [String: Int] = [:]
var icloudRowsInWindow = 0
var icloudUnverified = 0
var icloudNewest: Date?
let icloudFeed = organJSONL("icloud/chat_delivery_receipts.jsonl",
                            rootPath("icloud/chat_delivery_receipts.jsonl")) { obj in
    guard let ts = ((obj["at"] as? String) ?? (obj["createdAt"] as? String)).flatMap(parseTimestamp) else { return }
    icloudNewest = newer(icloudNewest, ts)
    guard ts >= windowStart else { return }
    icloudRowsInWindow += 1
    icloudStatusInWindow[(obj["status"] as? String) ?? "(no status field)", default: 0] += 1
    icloudDirectionInWindow[(obj["direction"] as? String) ?? "(no direction field)", default: 0] += 1
    if let verified = obj["signatureVerified"] as? Bool, !verified { icloudUnverified += 1 }
}

// ── SYS-05: memory V2 store housekeeping ────────────────────────────────────
// Blueprint § State Ownership: "Memory source of truth: MemoryV2 SQLite under
// data/". The store's own counters are read in section (c); this organ covers
// the housekeeping that keeps it honest — tombstones, the embedding epoch, the
// hygiene run, and the provenance of every hygiene pass.

var memTombstonesFile = 0
var memTombstoneNewest: Date?
let memTombstoneFeed = organJSONL("memory/tombstones.jsonl", rootPath("memory/tombstones.jsonl")) { obj in
    memTombstonesFile += 1
    if let ts = (obj["deletedAt"] as? String).flatMap(parseTimestamp) {
        memTombstoneNewest = newer(memTombstoneNewest, ts)
    }
}

var memProvenanceEvents: [String: Int] = [:]
var memProvenanceNewest: Date?
let memProvenanceFeed = organJSONL("memory/provenance.jsonl", rootPath("memory/provenance.jsonl")) { obj in
    memProvenanceEvents[(obj["event"] as? String) ?? "(no event field)", default: 0] += 1
    if let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp) {
        memProvenanceNewest = newer(memProvenanceNewest, ts)
    }
}

var memConsolidationRows = 0
var memConsolidationNewest: Date?
let memConsolidationFeed = organJSONL("memory/consolidations.jsonl",
                                      rootPath("memory/consolidations.jsonl")) { obj in
    memConsolidationRows += 1
    if let ts = (obj["createdAt"] as? String).flatMap(parseTimestamp) {
        memConsolidationNewest = newer(memConsolidationNewest, ts)
    }
}

var memDedupShadowRows = 0
let memDedupFeed = organJSONL("memory/dedup_shadow.jsonl", rootPath("memory/dedup_shadow.jsonl")) { _ in
    memDedupShadowRows += 1
}

var hygieneStatus: String?
var hygieneRanAt: Date?
var hygieneNextScheduled: Date?
var hygieneBefore: Int?
var hygieneAfter: Int?
let (hygieneObj, hygieneFeed) = organJSONObject("memory/hygiene_last_run.json",
                                                rootPath("memory/hygiene_last_run.json"))
if let hygieneObj {
    hygieneStatus = hygieneObj["status"] as? String
    hygieneRanAt = (hygieneObj["createdAt"] as? String).flatMap(parseTimestamp)
    hygieneNextScheduled = (hygieneObj["nextScheduled"] as? String).flatMap(parseTimestamp)
    hygieneBefore = hygieneObj["beforeCount"] as? Int
    hygieneAfter = hygieneObj["afterCount"] as? Int
}

// Memory maintenance residue is deliberately inspected read-only.  These
// artifacts can be large, but none of them are authority: the instrument only
// reports whether their lifecycle remains bounded and whether the two hygiene
// receipts describe the same latest run.
let memoryBackupGenerationCeiling = 8
let stagedMemoryRepairMaxAgeDays = 7.0
let hygieneReceiptMaxSkewSeconds: TimeInterval = 5 * 60

let memoryBackupsLabel = "memory/backups/*/memory.sqlite"
let memoryBackupsPath = rootPath("memory/backups")
let memoryBackupsPresent = sources.register(
    memoryBackupsLabel,
    memoryBackupsPath,
    note: "read-only backup-generation inventory; counts only generations containing memory.sqlite"
)
var memoryBackupGenerations = 0
var memoryBackupNewest: Date?
var memoryBackupsFeed: FeedState = .absent
if memoryBackupsPresent {
    let (entries, state) = organDirectory(memoryBackupsLabel, memoryBackupsPath)
    memoryBackupsFeed = state
    if state.didRead {
        for entry in entries {
            let generationPath = (memoryBackupsPath as NSString).appendingPathComponent(entry)
            let sqlitePath = (generationPath as NSString).appendingPathComponent("memory.sqlite")
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: sqlitePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            memoryBackupGenerations += 1
            if let modified = (try? fm.attributesOfItem(atPath: sqlitePath))?[.modificationDate] as? Date {
                memoryBackupNewest = newer(memoryBackupNewest, modified)
            }
        }
        sources.setRows(memoryBackupsLabel, memoryBackupGenerations)
    }
}

let stagedMemoryRepairsLabel = "memory/repairs/*.staged.json"
let stagedMemoryRepairsPath = rootPath("memory/repairs")
let stagedMemoryRepairsPresent = sources.register(
    stagedMemoryRepairsLabel,
    stagedMemoryRepairsPath,
    note: "read-only staged-repair inventory; file age is a lifecycle bound"
)
var stagedMemoryRepairCount = 0
var stagedMemoryRepairOldest: Date?
var stagedMemoryRepairsFeed: FeedState = .absent
if stagedMemoryRepairsPresent {
    let (entries, state) = organDirectory(stagedMemoryRepairsLabel, stagedMemoryRepairsPath)
    stagedMemoryRepairsFeed = state
    if state.didRead {
        for entry in entries where entry.hasSuffix(".staged.json") {
            let repairPath = (stagedMemoryRepairsPath as NSString).appendingPathComponent(entry)
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: repairPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            stagedMemoryRepairCount += 1
            if let modified = (try? fm.attributesOfItem(atPath: repairPath))?[.modificationDate] as? Date {
                if stagedMemoryRepairOldest == nil || modified < stagedMemoryRepairOldest! {
                    stagedMemoryRepairOldest = modified
                }
            }
        }
        sources.setRows(stagedMemoryRepairsLabel, stagedMemoryRepairCount)
    }
}

var hygieneLedgerRows = 0
var hygieneLedgerNewest: Date?
let hygieneLedgerFeed = organJSONL(
    "memory/hygiene.jsonl",
    rootPath("memory/hygiene.jsonl"),
    note: "streamed read-only; newest timestamp cross-checks hygiene_last_run.json"
) { row in
    hygieneLedgerRows += 1
    for key in ["createdAt", "created_at", "at", "lastRun", "last_run"] {
        if let timestamp = (row[key] as? String).flatMap(parseTimestamp) {
            hygieneLedgerNewest = newer(hygieneLedgerNewest, timestamp)
            break
        }
    }
}

let hygieneReceiptsAgree: Bool? = {
    guard hygieneLedgerFeed.didRead, hygieneFeed.didRead,
          let ledger = hygieneLedgerNewest, let lastRun = hygieneRanAt else {
        return nil
    }
    return abs(ledger.timeIntervalSince(lastRun)) <= hygieneReceiptMaxSkewSeconds
}()

var epochStatus: String?
var epochActive: String?
var epochAt: Date?
var epochProtected: Bool?
let (epochObj, epochFeed) = organJSONObject("memory/embedding_epoch_receipt.json",
                                            rootPath("memory/embedding_epoch_receipt.json"))
if let epochObj {
    epochStatus = epochObj["status"] as? String
    epochActive = epochObj["active_epoch"] as? String
    epochAt = (epochObj["at"] as? String).flatMap(parseTimestamp)
    epochProtected = epochObj["protected"] as? Bool
}

// ── SYS-06: Workshop ────────────────────────────────────────────────────────
// Blueprint § State Ownership (Workshop owns a durable verification object
// inside its canonical execution record) + § Background Loops (Workshop pump).

var workshopReceiptsInWindow = 0
var workshopDispositions: [String: Int] = [:]
var workshopStatuses: [String: Int] = [:]
var workshopReceiptNewest: Date?
var workshopReceiptsTotal = 0
let workshopReceiptFeed = organJSONL("workshop/receipts.jsonl", rootPath("workshop/receipts.jsonl")) { obj in
    workshopReceiptsTotal += 1
    // Receipts carry no timestamp field of their own; the reservation id is
    // date-stamped (`wres_<handle>_2026-08-21_2026-08-21-b5`), so window
    // membership is derived from that rather than invented.
    let rid = (obj["reservationId"] as? String) ?? ""
    var stamped: Date?
    for token in rid.split(separator: "_") where token.count == 10 {
        if let d = parseTimestamp(String(token) + "T00:00:00Z") { stamped = newer(stamped, d) }
    }
    if let stamped { workshopReceiptNewest = newer(workshopReceiptNewest, stamped) }
    guard let stamped, stamped >= windowStart else { return }
    workshopReceiptsInWindow += 1
    workshopDispositions[(obj["disposition"] as? String) ?? "(no disposition field)", default: 0] += 1
    workshopStatuses[(obj["status"] as? String) ?? "(no status field)", default: 0] += 1
}

var leaseAcquiredAt: Date?
var leaseClaims = 0
var leaseHolders: [String: Int] = [:]
var leaseNewestClaim: Date?
let (leaseObj, leaseFeed) = organJSONObject("workshop/background_lease.json",
                                            rootPath("workshop/background_lease.json"))
if let leaseObj {
    leaseAcquiredAt = (leaseObj["acquiredAt"] as? String).flatMap(parseTimestamp)
    if let claims = leaseObj["claims"] as? [[String: Any]] {
        leaseClaims = claims.count
        for c in claims {
            leaseHolders[(c["holder"] as? String) ?? "(no holder field)", default: 0] += 1
            if let a = (c["acquiredAt"] as? String).flatMap(parseTimestamp) {
                leaseNewestClaim = newer(leaseNewestClaim, a)
            }
        }
    }
    sources.setRows("workshop/background_lease.json", leaseClaims)
}

var executionStatuses: [String: Int] = [:]
var executionsTotal = 0
var executionNewest: Date?
var executionsUnparseable = 0
let executionsDir = rootPath("workshop/executions")
let executionsPresent = sources.register("workshop/executions/*/execution.json", executionsDir,
                                         note: "every execution record opened read-only")
noAutoClaimLabels.insert("workshop/executions/*/execution.json")
noAutoClaimLabels.insert("workshop/reservation_claims/*.claim")
if executionsPresent {
    claimFeedFamily("workshop/executions/*/execution.json", by: "workshop/executions/*/execution.json")
    let (executionEntries, executionsDirState) =
        organDirectory("workshop/executions/*/execution.json", executionsDir)
    for entry in executionEntries {
        let p = ((executionsDir as NSString).appendingPathComponent(entry) as NSString)
            .appendingPathComponent("execution.json")
        guard fm.fileExists(atPath: p) else { continue }
        executionsTotal += 1
        guard let data = fm.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            executionsUnparseable += 1
            executionStatuses["(unparseable execution record)", default: 0] += 1
            continue
        }
        executionStatuses[(obj["status"] as? String) ?? "(no status field)", default: 0] += 1
        if let c = (obj["created_at"] as? String).flatMap(parseTimestamp) {
            executionNewest = newer(executionNewest, c)
        }
    }
    sources.setRows("workshop/executions/*/execution.json", executionsTotal - executionsUnparseable)
    // Below the ratio bar the unparseable count is surfaced in the SYS-06 row
    // (and raises its own lead); at or above it the family is UNREADABLE, so
    // the organ reports nothing rather than statuses from the survivors.
    if executionsDirState.didRead {
        _ = condemnUnparseableFamily("workshop/executions/*/execution.json",
                                     total: executionsTotal, unparseable: executionsUnparseable)
    }
}

var reservationClaims = 0
var reservationsUnparseable = 0
var reservationNewest: Date?
let claimsDir = rootPath("workshop/reservation_claims")
let claimsPresent = sources.register("workshop/reservation_claims/*.claim", claimsDir,
                                     note: "every claim file opened read-only")
if claimsPresent {
    claimFeedFamily("workshop/reservation_claims/*.claim", by: "workshop/reservation_claims/*.claim")
    claimFeedFamily("workshop/reservation_claims/*.claim.lock", by: "workshop/reservation_claims/*.claim")
    let (claimEntries, claimsDirState) = organDirectory("workshop/reservation_claims/*.claim", claimsDir)
    for entry in claimEntries where entry.hasSuffix(".claim") {
        let p = (claimsDir as NSString).appendingPathComponent(entry)
        reservationClaims += 1
        // A claim file that will not parse is COUNTED as unparseable rather
        // than skipped — a claim nobody can read is a finding, and silently
        // continuing past it is how "42 claims" hides 42 corrupt ones.
        guard let data = fm.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            reservationsUnparseable += 1
            continue
        }
        guard let c = (obj["claimedAt"] as? String).flatMap(parseTimestamp) else { continue }
        reservationNewest = newer(reservationNewest, c)
    }
    sources.setRows("workshop/reservation_claims/*.claim", reservationClaims - reservationsUnparseable)
    if claimsDirState.didRead {
        _ = condemnUnparseableFamily("workshop/reservation_claims/*.claim",
                                     total: reservationClaims, unparseable: reservationsUnparseable)
    }
}

// ── SYS-07: GitHub command lane ─────────────────────────────────────────────
// Blueprint § State Ownership (GitHub Watcher): `GitHubCommandStore` is the
// sole append/reducer/state owner, an actionable key updates Desk and claims
// one durable deduplicated notification, and it never starts repository work.

var githubOpsInWindow = 0
var githubOpKinds: [String: Int] = [:]
var githubOpsNewest: Date?
var githubOpsTotal = 0
let githubOpsPath = rootPath("workshop/github_command/ops.jsonl")
let githubOpsFeed = organJSONL("workshop/github_command/ops.jsonl", githubOpsPath) { obj in
    githubOpsTotal += 1
    guard let ts = ((obj["at"] as? String) ?? (obj["ts"] as? String)).flatMap(parseTimestamp) else { return }
    githubOpsNewest = newer(githubOpsNewest, ts)
    guard ts >= windowStart else { return }
    githubOpsInWindow += 1
    // The op's kind is the single key of its `body` envelope.
    let kind = (obj["body"] as? [String: Any])?.keys.sorted().first ?? "(no body field)"
    githubOpKinds[kind, default: 0] += 1
}

// `ops_base.json` is the compaction snapshot paired with the retained JSONL
// tail. It is optional before the first compaction, but once it exists a
// malformed or unreadable base makes replay unsafe: the tail alone cannot
// truthfully represent the older accepted/refused/failed command receipts.
// Read only its structural envelope and byte size — never its GitHub titles,
// callback prose, or any other descriptive item payload.
let githubBasePath = rootPath("workshop/github_command/ops_base.json")
var githubBaseKeyCount = 0
var githubBaseItemCount: Int?
var githubBaseCompactedOpCount: Int?
var githubBaseBytes: Int64?
let (githubBaseObj, githubBaseFeed) = organJSONObject(
    "workshop/github_command/ops_base.json", githubBasePath,
    note: "read-only JSON compaction envelope (top-level shape and size only)"
)
if let githubBaseObj {
    githubBaseKeyCount = githubBaseObj.count
    githubBaseBytes = Int64(((try? fm.attributesOfItem(atPath: githubBasePath))?[.size] as? Int64) ?? 0)
    let requiredBaseKeys: Set<String> = [
        "state", "lastCompactedOpId", "compactedAt", "compactedOpCount", "tailFirstOpId",
    ]
    let missingBaseKeys = requiredBaseKeys.subtracting(githubBaseObj.keys)
    let hasValidBaseState: Bool = {
        guard let baseState = githubBaseObj["state"] as? [String: Any] else { return false }
        return baseState["items"] is [Any] && baseState["dispatchedEventKeys"] is [Any]
    }()
    if !missingBaseKeys.isEmpty || !hasValidBaseState {
        markFeedUnreadable(
            "workshop/github_command/ops_base.json",
            "missing required compaction keys or reduced-state arrays"
        )
        // The source's unreadable state gates every base-derived number below.
        // Do not use a partial object as though it were a zero-item snapshot.
        githubBaseItemCount = nil
        githubBaseCompactedOpCount = nil
    }
    if !sources.isUnreadable("workshop/github_command/ops_base.json"),
       let baseState = githubBaseObj["state"] as? [String: Any] {
        githubBaseItemCount = (baseState["items"] as? [Any])?.count
        githubBaseCompactedOpCount = (githubBaseObj["compactedOpCount"] as? NSNumber)?.intValue
        sources.setRows("workshop/github_command/ops_base.json", githubBaseKeyCount)
    }
}
let githubOpsBytes: Int64? = githubOpsFeed.didRead
    ? Int64(((try? fm.attributesOfItem(atPath: githubOpsPath))?[.size] as? Int64) ?? 0)
    : nil

var githubItems = 0
var githubItemsOpen = 0
var githubNotificationReceipts = 0
var githubNotificationClaims = 0
var githubDispatchedKeys = 0
var githubItemNewest: Date?
let (githubStateObj, githubStateFeed) = organJSONObject("workshop/github_command/github_command_state.json",
                                                        rootPath("workshop/github_command/github_command_state.json"))
if let githubStateObj {
    githubDispatchedKeys = (githubStateObj["dispatchedEventKeys"] as? [Any])?.count ?? 0
    if let items = githubStateObj["items"] as? [[String: Any]] {
        githubItems = items.count
        for it in items {
            if let obs = it["observation"] as? [String: Any], (obs["isOpen"] as? Bool) == true {
                githubItemsOpen += 1
            }
            githubNotificationReceipts += (it["notificationReceipts"] as? [Any])?.count ?? 0
            githubNotificationClaims += (it["notificationClaims"] as? [Any])?.count ?? 0
            if let u = (it["motorUpdatedAt"] as? String).flatMap(parseTimestamp) {
                githubItemNewest = newer(githubItemNewest, u)
            }
        }
    }
    sources.setRows("workshop/github_command/github_command_state.json", githubItems)
}

var githubApprovalStates: [String: Int] = [:]
let (githubApprovalsObj, githubApprovalsFeed) = organJSONObject("notify/github_approvals.json",
                                                                rootPath("notify/github_approvals.json"))
if let githubApprovalsObj, let rs = githubApprovalsObj["reviewStates"] as? [String: Any] {
    for (_, v) in rs { githubApprovalStates[(v as? String) ?? "(non-string state)", default: 0] += 1 }
    sources.setRows("notify/github_approvals.json", rs.count)
}

var githubTrackingKeys = 0
var githubTrackingNewest: Date?
let (githubTrackingObj, githubTrackingFeed) = organJSONObject("connectors/github/tracking_snapshot.json",
                                                                rootPath("connectors/github/tracking_snapshot.json"))
if let githubTrackingObj {
    githubTrackingKeys = githubTrackingObj.count
    for key in ["updatedAt", "generatedAt", "capturedAt", "refreshedAt", "at"] {
        if let d = (githubTrackingObj[key] as? String).flatMap(parseTimestamp) {
            githubTrackingNewest = newer(githubTrackingNewest, d)
        }
    }
    sources.setRows("connectors/github/tracking_snapshot.json", githubTrackingKeys)
}

// ── SYS-08: heartbeat / self-healing ────────────────────────────────────────
// Blueprint § Background Loops, "heartbeat/self-healing: app health and
// self-improvement checks".

var heartbeatStatus: String?
var heartbeatCondition: String?
var heartbeatLastTick: Date?
var heartbeatNextTick: Date?
var heartbeatIssues: Int?
var heartbeatCadence: Double?
let (heartbeatObj, heartbeatFeed) = organJSONObject("heartbeat/status.json", rootPath("heartbeat/status.json"))
if let heartbeatObj {
    heartbeatStatus = heartbeatObj["status"] as? String
    heartbeatCondition = heartbeatObj["condition_id"] as? String
    heartbeatLastTick = (heartbeatObj["last_tick_at"] as? String).flatMap(parseTimestamp)
    heartbeatNextTick = (heartbeatObj["next_tick_no_earlier_than"] as? String).flatMap(parseTimestamp)
    heartbeatIssues = (heartbeatObj["issues"] as? [Any])?.count
    heartbeatCadence = heartbeatObj["cadence_seconds"] as? Double
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SYSTEM ORGANS — wave-2 readers (SYS-09..14)
//
// Wave 1 (SYS-01..08) took the biggest/most active organs off the reach walk's
// blind-spot list. Wave 2 takes the remainder named in
// `docs/build_plans/full-system-eval-coverage.md`: providers/routing, tools,
// sync, chat sessions, security/trust, and the update lane.
//
// Identical three rules, no exceptions: copy-before-query for sqlite, streamed
// read-only for JSONL, and a missing source is `source absent` while an
// unreadable one is `source unreadable` — NEVER a zero.
//
// One rule wave 2 adds, because wave 2 is the first to read CREDENTIAL files:
//
//   SECRET DISCIPLINE. `data/providers/<id>.json` holds live API keys and OAuth
//   access tokens. This instrument prints its evidence, so a reader that
//   "reads the provider config" would print User's Anthropic token into a
//   markdown file. The provider reader therefore has an ALLOWLIST of keys it
//   is even permitted to look at (`auth_mode`, `default_model`) and copies
//   nothing else out of those objects — not into a variable, not into a count
//   keyed by value. Everything else about a credential file is reported as
//   shape only: whether it parsed, and how many keys it has.
// ─────────────────────────────────────────────────────────────────────────────

/// The ONLY keys any provider credential file may contribute to this report.
/// See the secret-discipline note above. Adding a key here means it will be
/// printed verbatim in a markdown report — treat this list as a security
/// boundary, not a convenience.
let providerSafeKeys: Set<String> = ["auth_mode", "default_model"]

/// Mirror of ProviderRouting.MODEL_SURFACES. This script deliberately has no
/// package dependency, so keep the vocabulary explicit at the external
/// persisted-state boundary. An unknown picker key is not a harmless extra:
/// it is a pin no turn can ever consume.
let canonicalProviderSurfaces: Set<String> = [
    "chat", "ios", "telegram", "slack", "workshop", "autonomy", "swarms", "dream", "rem", "training",
    "memory", "heartbeat", "diagnostics", "cognition_reflection", "compaction", "self_improvement", "desk", "studio_wander",
]
/// Persisted compatibility keys that shipped previously but no current route
/// consumes. They are historical state to drain, not unknown surface drift.
let retiredProviderSurfaces: Set<String> = ["cognition_cue"]

// ── SYS-09: providers / routing ─────────────────────────────────────────────
// Blueprint § Providers & Routing. Three files decide which model answers a
// turn: `providers/surfaces.json` (the per-surface MODEL pin),
// `providers/active.json` (the per-surface PROVIDER pin), and the credential
// file each provider id resolves to. The fourth input is the trace: what the
// router actually reached for. A pin nobody honours and a provider nobody has
// credentials for are both silent failures, so all four are read and compared.

struct SurfacePin {
    var surface: String
    var model: String?
    var reasoningEffort: String?
    var serviceTier: String?
    var provider: String?
    /// Does `provider` resolve to a credential file on disk?
    var providerConfigured = false
    /// What the trace shows this surface actually used in window.
    var observedModels: [String: Int] = [:]
    var observedProviders: [String: Int] = [:]
    var calls = 0
    var substituted = 0
}

var surfacePins: [String: SurfacePin] = [:]
var providerCredentialFiles: [String: (parsed: Bool, authMode: String?, defaultModel: String?, keyCount: Int)] = [:]
var providerUnparseable = 0
var providerFilesTotal = 0

let (surfacesObj, surfacesFeed) = organJSONObject("providers/surfaces.json",
                                                  rootPath("providers/surfaces.json"))
if let surfacesObj {
    for (surface, raw) in surfacesObj {
        guard let o = raw as? [String: Any] else {
            // A surface whose pin is not an object is a malformed pin, not an
            // unpinned surface. Name it rather than dropping it.
            surfacePins[surface] = SurfacePin(surface: surface, model: "(pin is not an object)")
            continue
        }
        surfacePins[surface] = SurfacePin(surface: surface,
                                          model: o["model"] as? String,
                                          reasoningEffort: o["reasoningEffort"] as? String,
                                          serviceTier: o["serviceTier"] as? String)
    }
    sources.setRows("providers/surfaces.json", surfacePins.count)
}

let (activeProvidersObj, activeProvidersFeed) = organJSONObject("providers/active.json",
                                                                rootPath("providers/active.json"))
if let activeProvidersObj {
    for (surface, raw) in activeProvidersObj {
        let providerId = raw as? String
        if surfacePins[surface] == nil { surfacePins[surface] = SurfacePin(surface: surface) }
        surfacePins[surface]?.provider = providerId ?? "(provider id is not a string)"
    }
    sources.setRows("providers/active.json", activeProvidersObj.count)
}

// The provider REGISTRY on disk: every `providers/*.json` that is not a
// routing pin file, a catalog cache, or transactional pin state. The
// directory must NOT auto-claim its subtree (gpt-5.5 wave-2 review: the
// caches and any stray file are never opened, and a directory claim would
// erase them from NOT COVERED without a reader) — instead each file this
// loop actually opens claims itself below. Nothing outside
// `providerSafeKeys` leaves those objects.
let providersDir = rootPath("providers")
let providersDirPresent = sources.register("providers/", providersDir,
                                           note: "credential configs opened read-only; only "
                                               + "`auth_mode`/`default_model` are read out; caches stay uncovered")
noAutoClaimLabels.insert("providers/")
/// Files in `providers/` that are NOT provider credential configs and are NOT
/// opened by this loop: the two pin files (read by their own SYS-09 readers),
/// the two catalog caches, and the pending-pin transaction marker. Counting a
/// cache as a "configured provider" would inflate the registry; opening it
/// just to justify a coverage claim would be claim-washing.
let providerNonCredentialFiles: Set<String> = ["active.json", "surfaces.json",
                                               "openrouter-models-cache.json",
                                               "moonshot-models-cache.json",
                                               "pending-surface-configuration.json"]
var providersDirState: FeedState = .absent
if providersDirPresent {
    let (entries, state) = organDirectory("providers/", providersDir)
    providersDirState = state
    if state.didRead {
        for entry in entries where entry.hasSuffix(".json") && !providerNonCredentialFiles.contains(entry) {
            let id = String(entry.dropLast(".json".count))
            providerFilesTotal += 1
            // This file IS opened right below — it earns its coverage claim.
            claimFeedFamily(normalizeRelativePath("providers/\(entry)"), by: "providers/")
            guard let data = fm.contents(atPath: (providersDir as NSString).appendingPathComponent(entry)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                providerUnparseable += 1
                providerCredentialFiles[id] = (parsed: false, authMode: nil, defaultModel: nil, keyCount: 0)
                continue
            }
            // ONLY the two allowlisted keys are copied out. `keyCount` is shape,
            // not content.
            providerCredentialFiles[id] = (
                parsed: true,
                authMode: providerSafeKeys.contains("auth_mode") ? obj["auth_mode"] as? String : nil,
                defaultModel: providerSafeKeys.contains("default_model") ? obj["default_model"] as? String : nil,
                keyCount: obj.count)
        }
        sources.setRows("providers/", providerFilesTotal - providerUnparseable)
        _ = condemnUnparseableFamily("providers/", total: providerFilesTotal,
                                     unparseable: providerUnparseable)
    }
}

// Resolve each surface's pinned provider against the registry, and fold in what
// the trace observed. Both halves are optional and each says so on its own.
for (surface, var pin) in surfacePins {
    if let p = pin.provider {
        pin.providerConfigured = providerCredentialFiles[p]?.parsed == true
    }
    if let r = routeStats[surface] {
        pin.calls = r.calls
        pin.observedModels = r.models
        pin.observedProviders = r.providers
        pin.substituted = r.substituted
    }
    surfacePins[surface] = pin
}

/// Only compare calls after both routing files' captured modification epoch.
/// Historical calls remain in the table but cannot accuse a newer pin.
/// Ties on surface name so two runs over the same bytes name the same surface.
let pinDrifts: [(surface: String, pinned: String, observed: String, calls: Int)] =
    surfacePins.values.compactMap { pin in
        guard capturedRoutingPinEpoch != nil, routingPinEpoch() == capturedRoutingPinEpoch,
              let current = currentPinRouteStats[pin.surface], current.calls > 0 else { return nil }
        guard !retiredProviderSurfaces.contains(pin.surface),
              pin.calls > 0, let pinned = pin.model, !pin.observedModels.isEmpty else { return nil }
        guard current.models[pinned] == nil else { return nil }
        let top = current.models.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first
        return (surface: pin.surface, pinned: pinned, observed: top?.key ?? "(none)", calls: current.calls)
    }.sorted { $0.calls == $1.calls ? $0.surface < $1.surface : $0.calls > $1.calls }

/// Surfaces pinned to a provider with no credential file on disk. These cannot
/// be derived from a count — an absent `active.json` leaves the list EMPTY, and
/// the SYS-09 cell gates on the feed rather than on the emptiness.
let unresolvedProviderPins: [(surface: String, provider: String)] = surfacePins.values
    .compactMap { pin in
        guard !retiredProviderSurfaces.contains(pin.surface),
              let p = pin.provider, !pin.providerConfigured else { return nil }
        return (surface: pin.surface, provider: p)
    }.sorted { $0.surface == $1.surface ? $0.provider < $1.provider : $0.surface < $1.surface }

/// Existing picker bytes may outlive a routing-surface rename. They must be
/// named as orphan pins rather than folded into the healthy pin count: such a
/// row can look configured forever while no provider dispatch reads it.
let unservedProviderPins = surfacePins.keys
    .filter { !canonicalProviderSurfaces.contains($0) && !retiredProviderSurfaces.contains($0) }
    .sorted()
let retiredProviderPins = surfacePins.keys
    .filter { retiredProviderSurfaces.contains($0) }
    .sorted()

var openrouterModelCount: Int?
var openrouterCacheNewest: Date?
let openrouterPath = rootPath("providers/openrouter-models-cache.json")
if fm.fileExists(atPath: openrouterPath) {
    // Already claimed by the `providers/` directory registration above; parsed
    // here for its one useful number. A cache that will not parse is counted in
    // the unparseable tally, not silently skipped.
    if let data = fm.contents(atPath: openrouterPath),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let models = obj["models"] as? [Any] {
        openrouterModelCount = models.count
    }
    openrouterCacheNewest = (try? fm.attributesOfItem(atPath: openrouterPath)[.modificationDate]) as? Date
}

var providerStatusStatus: String?
var providerStatusDetail: String?
var providerStatusCheckedAt: Date?
let (providerStatusObj, providerStatusFeed) = organJSONObject("llm/provider_status.json",
                                                              rootPath("llm/provider_status.json"))
if let providerStatusObj {
    providerStatusStatus = providerStatusObj["status"] as? String
    providerStatusDetail = providerStatusObj["detail"] as? String
    providerStatusCheckedAt = (providerStatusObj["checkedAt"] as? String).flatMap(parseTimestamp)
}

// ── SYS-10: tools ───────────────────────────────────────────────────────────
// Blueprint § Tool Dispatch. The dispatch outcomes were collected in the events
// pass far above (one stream, three organs). What is left here is the signed
// tool registry on disk and the per-tool DENIAL side, which lives in the
// security audit feed read by SYS-13 below — so SYS-10's own numbers are
// finished after that reader runs, and the row is composed later still.

var toolRegistryEntries: Int?
var toolRegistryInstalled = 0
var toolRegistryIDs: Set<String> = []
let (toolRegistryRaw, toolRegistryFeed) = organJSON("tools/registry.json", rootPath("tools/registry.json"))
if toolRegistryFeed.didRead {
    if let arr = toolRegistryRaw as? [Any] {
        toolRegistryEntries = arr.count
        for e in arr {
            guard let o = e as? [String: Any] else { continue }
            if let id = o["id"] as? String, !id.isEmpty { toolRegistryIDs.insert(id) }
            if (o["installed"] as? Bool) == true || (o["status"] as? String) == "active" {
                toolRegistryInstalled += 1
            }
        }
    } else {
        markFeedUnreadable("tools/registry.json",
                           "present but the top level is not the canonical registry array")
    }
    if let n = toolRegistryEntries { sources.setRows("tools/registry.json", n) }
}

// Skills are guidance-only artifacts, but their registry is still the durable
// discovery boundary for the lazy `list_skills` / `read_skill` path. Keep the
// reader deliberately tolerant of legacy rows: some valid historical entries
// have only a name, while an object at the top level is not a registry at all.
var skillRegistryEntries: Int?
var skillRegistryStatuses: [String: Int] = [:]
var skillRegistryNonObjectRows = 0
var skillRegistryNewest: Date?
let (skillRegistryRaw, skillRegistryFeed) = organJSON("skills/registry.json", rootPath("skills/registry.json"))
if skillRegistryFeed.didRead {
    if let rows = skillRegistryRaw as? [Any] {
        skillRegistryEntries = rows.count
        for row in rows {
            guard let entry = row as? [String: Any] else {
                skillRegistryNonObjectRows += 1
                continue
            }
            let status = (entry["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            skillRegistryStatuses[(status?.isEmpty == false ? status! : "(no status)"), default: 0] += 1
            for key in ["updatedAt", "createdAt"] {
                if let timestamp = (entry[key] as? String).flatMap(parseTimestamp) {
                    skillRegistryNewest = newer(skillRegistryNewest, timestamp)
                    break
                }
            }
        }
        sources.setRows("skills/registry.json", rows.count)
    } else {
        markFeedUnreadable("skills/registry.json",
                           "present but the top level is not the canonical registry array")
    }
}

/// The tool registry alone cannot distinguish a genuinely unused lane from a
/// read path that silently collapsed damage to `[]`. Reconcile its IDs against
/// the three artifact directories, preserving absent/unreadable/empty as
/// distinct operator-visible states. Directory names are opaque IDs only; no
/// artifact content is opened by this health reader.
struct ToolArtifactDirectory {
    let relativePath: String
    let present: Bool
    let readable: Bool
    let ids: Set<String>
    let newest: Date?
    /// An active tool is always a directory. A regular file at this boundary
    /// cannot be promoted, signed, or safely swept, so it is damage rather
    /// than a zero-entry lane.
    let nonDirectoryEntries: Set<String>
}

func readToolArtifactDirectory(_ relativePath: String) -> ToolArtifactDirectory {
    let path = rootPath(relativePath)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
        return ToolArtifactDirectory(relativePath: relativePath, present: false, readable: false, ids: [], newest: nil,
                                     nonDirectoryEntries: [])
    }
    guard isDirectory.boolValue else {
        return ToolArtifactDirectory(relativePath: relativePath, present: true, readable: false, ids: [], newest: nil,
                                     nonDirectoryEntries: ["(root is not a directory)"])
    }
    do {
        let names = try fm.contentsOfDirectory(atPath: path)
        var newest: Date?
        var ids = Set<String>()
        var nonDirectories = Set<String>()
        for name in names {
            let child = (path as NSString).appendingPathComponent(name)
            var childIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child, isDirectory: &childIsDirectory) else { continue }
            if relativePath == "tools/active", !childIsDirectory.boolValue {
                nonDirectories.insert(name)
                continue
            }
            ids.insert(name)
            if let modified = (try? fm.attributesOfItem(atPath: child)[.modificationDate]) as? Date {
                newest = newer(newest, modified)
            }
        }
        return ToolArtifactDirectory(relativePath: relativePath, present: true, readable: nonDirectories.isEmpty,
                                     ids: ids, newest: newest, nonDirectoryEntries: nonDirectories)
    } catch {
        return ToolArtifactDirectory(relativePath: relativePath, present: true, readable: false, ids: [], newest: nil,
                                     nonDirectoryEntries: [])
    }
}

let toolArtifactDirectories = [
    readToolArtifactDirectory("tools/active"),
    readToolArtifactDirectory("tools/proposals"),
    readToolArtifactDirectory("tools/quarantine"),
]
let activeToolArtifactIDs = toolArtifactDirectories.first { $0.relativePath == "tools/active" }?.ids ?? []
let registryWithoutActiveArtifact = toolRegistryIDs.subtracting(activeToolArtifactIDs).sorted()
let activeArtifactWithoutRegistry = activeToolArtifactIDs.subtracting(toolRegistryIDs).sorted()

/// Worst-failing tools in window, ties on the tool NAME.
let toolWorstFailing: [(name: String, stat: ToolDispatchStat)] = toolStats
    .filter { $0.value.failed > 0 }
    .map { (name: $0.key, stat: $0.value) }
    .sorted { $0.stat.failed == $1.stat.failed ? $0.name < $1.name : $0.stat.failed > $1.stat.failed }
let toolDispatchOK = toolStats.values.reduce(0) { $0 + $1.ok }
let toolDispatchFailed = toolStats.values.reduce(0) { $0 + $1.failed }

// ── SYS-11: sync (iCloud bridge + paired-device snapshot cache) ──────────────
// Blueprint § State Ownership (iCloud/CloudKit companion). Four independent
// persisted surfaces: the chat receipt feed (already read by SYS-04, reused
// here rather than re-streamed), the processed-id ledger, the snapshot digest
// map, and the snapshot cache the companion actually reads — plus the
// transaction queue the phone writes back through.

var icloudProcessedIDs: Int?
let (icloudProcessedRaw, icloudProcessedFeed) = organJSON("icloud/processed_ids.json",
                                                          rootPath("icloud/processed_ids.json"))
if icloudProcessedFeed.didRead {
    if let arr = icloudProcessedRaw as? [Any] {
        icloudProcessedIDs = arr.count
        sources.setRows("icloud/processed_ids.json", arr.count)
    } else if let obj = icloudProcessedRaw as? [String: Any] {
        icloudProcessedIDs = obj.count
        sources.setRows("icloud/processed_ids.json", obj.count)
    } else {
        markFeedUnreadable("icloud/processed_ids.json",
                           "present but the top level is neither an array nor an object")
    }
}

var snapshotDigestKeys: [String] = []
let (digestObj, digestFeed) = organJSONObject("icloud/snapshot_digests.json",
                                              rootPath("icloud/snapshot_digests.json"))
if let digestObj {
    snapshotDigestKeys = digestObj.keys.sorted()
    sources.setRows("icloud/snapshot_digests.json", snapshotDigestKeys.count)
}

struct SnapshotFile { var name: String; var bytes: Int64; var modified: Date? }
var snapshotFiles: [SnapshotFile] = []
var snapshotCacheResponses = 0
var snapshotResponseStatuses: [String: Int] = [:]
var snapshotResponseChannels: [String: Int] = [:]
var snapshotResponsesUnparseable = 0
var syncTransactionsTotal = 0
var syncTransactionsUnparseable = 0
var syncTransactionDirections: [String: Int] = [:]
var syncTransactionsUnanswered = 0
var syncTransactionsRetried = 0
var syncTransactionNewest: Date?
var snapshotCacheStrays = 0   // non-.json entries this reader does not parse — visible, never absorbed

let snapshotCacheDir = rootPath("mobile_snapshot_cache")
let snapshotCachePresent = sources.register("mobile_snapshot_cache/", snapshotCacheDir,
                                            note: "every snapshot, response and transaction opened read-only")
var snapshotCacheState: FeedState = .absent
if snapshotCachePresent {
    let snapshotsDir = (snapshotCacheDir as NSString).appendingPathComponent("snapshots")
    let (snapEntries, snapState) = organDirectory("mobile_snapshot_cache/", snapshotsDir)
    snapshotCacheState = snapState
    if snapState.didRead {
        snapshotCacheStrays += snapEntries.filter { !$0.hasSuffix(".json") && !$0.hasSuffix(".lock") }.count
        for entry in snapEntries where entry.hasSuffix(".json") {
            let p = (snapshotsDir as NSString).appendingPathComponent(entry)
            let attrs = try? fm.attributesOfItem(atPath: p)
            snapshotFiles.append(SnapshotFile(name: entry,
                                              bytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                                              modified: attrs?[.modificationDate] as? Date))
        }
        snapshotFiles.sort { $0.name < $1.name }
    }
    // Companion acks. Each is a tiny object; a response that will not parse is
    // COUNTED, never skipped.
    let responsesDir = (snapshotCacheDir as NSString).appendingPathComponent("responses")
    let (respEntries, respState) = organDirectory("mobile_snapshot_cache/", responsesDir)
    if respState.didRead {
        snapshotCacheStrays += respEntries.filter { !$0.hasSuffix(".json") && !$0.hasSuffix(".lock") }.count
        for entry in respEntries where entry.hasSuffix(".json") {
            snapshotCacheResponses += 1
            guard let data = fm.contents(atPath: (responsesDir as NSString).appendingPathComponent(entry)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                snapshotResponsesUnparseable += 1
                continue
            }
            snapshotResponseStatuses[(obj["status"] as? String) ?? "(no status field)", default: 0] += 1
            snapshotResponseChannels[(obj["channel"] as? String) ?? "(no channel field)", default: 0] += 1
        }
    }
    // The write-back queue the phone posts into. `attempts > 1` is a retry and
    // a transaction with no `response` object has not been answered yet — the
    // queue depth this organ exists to report.
    let txRoot = (snapshotCacheDir as NSString).appendingPathComponent("transactions")
    let (txDirs, txDirState) = organDirectory("mobile_snapshot_cache/", txRoot)
    if txDirState.didRead {
        for lane in txDirs {
            let laneDir = (txRoot as NSString).appendingPathComponent(lane)
            var isD: ObjCBool = false
            guard fm.fileExists(atPath: laneDir, isDirectory: &isD), isD.boolValue else { continue }
            let (txEntries, txState) = organDirectory("mobile_snapshot_cache/", laneDir)
            guard txState.didRead else { continue }
            snapshotCacheStrays += txEntries.filter { !$0.hasSuffix(".json") && !$0.hasSuffix(".lock") }.count
            for entry in txEntries where entry.hasSuffix(".json") {
                syncTransactionsTotal += 1
                guard let data = fm.contents(atPath: (laneDir as NSString).appendingPathComponent(entry)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    syncTransactionsUnparseable += 1
                    continue
                }
                syncTransactionDirections[(obj["direction"] as? String) ?? "(no direction field)", default: 0] += 1
                if obj["response"] == nil || obj["response"] is NSNull { syncTransactionsUnanswered += 1 }
                if let a = (obj["attempts"] as? NSNumber)?.intValue, a > 1 { syncTransactionsRetried += 1 }
                if let c = (obj["createdAt"] as? String).flatMap(parseTimestamp) {
                    syncTransactionNewest = newer(syncTransactionNewest, c)
                }
            }
        }
    }
    sources.setRows("mobile_snapshot_cache/",
                    snapshotFiles.count + snapshotCacheResponses + syncTransactionsTotal
                        - snapshotResponsesUnparseable - syncTransactionsUnparseable)
    _ = condemnUnparseableFamily("mobile_snapshot_cache/",
                                 total: snapshotCacheResponses + syncTransactionsTotal,
                                 unparseable: snapshotResponsesUnparseable + syncTransactionsUnparseable)
}

/// Snapshot names the digest map knows about but that are NOT cached, and vice
/// versa. Both directions are a real drift: a digest with no file means the
/// companion is told a snapshot exists that it cannot fetch. Sorted by name.
let digestsWithoutSnapshot: [String] = snapshotDigestKeys
    .filter { key in !snapshotFiles.contains { $0.name == key } }.sorted()
let snapshotsWithoutDigest: [String] = snapshotFiles.map { $0.name }
    .filter { !snapshotDigestKeys.contains($0) }.sorted()
/// Oldest cached snapshot, ties on name.
let stalestSnapshot: SnapshotFile? = snapshotFiles
    .filter { $0.modified != nil }
    .min { a, b in
        let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
        return x == y ? a.name < b.name : x < y
    }

var peerEvidenceChannel: String?
var peerEvidenceObservedAt: Date?
var peerEvidenceSkewSeconds: Double?
let (peerObj, peerFeed) = organJSONObject("mobile/signed_peer_evidence.json",
                                          rootPath("mobile/signed_peer_evidence.json"))
if let peerObj {
    peerEvidenceChannel = peerObj["channel"] as? String
    peerEvidenceObservedAt = (peerObj["observedAt"] as? String).flatMap(parseTimestamp)
    if let o = peerEvidenceObservedAt,
       let p = (peerObj["peerCreatedAt"] as? String).flatMap(parseTimestamp) {
        peerEvidenceSkewSeconds = o.timeIntervalSince(p)
    }
}

var publicSyncResult: String?
var publicSyncStage: String?
var publicSyncRecordedAt: Date?
var publicSyncExitCode: Int?
let (publicSyncObj, publicSyncFeed) = organJSONObject("public_sync/last_status.json",
                                                      rootPath("public_sync/last_status.json"))
if let publicSyncObj {
    publicSyncResult = publicSyncObj["result"] as? String
    publicSyncStage = publicSyncObj["stage"] as? String
    publicSyncRecordedAt = (publicSyncObj["recorded_at"] as? String).flatMap(parseTimestamp)
    publicSyncExitCode = (publicSyncObj["exit_code"] as? NSNumber)?.intValue
}

var mobilePushTokenCount: Int?
var mobilePushTokenNewest: Date?
// SECRET DISCIPLINE, second instance: this file holds live APNs device tokens.
// The reader takes the COUNT and the freshest `updatedAt` and nothing else —
// no token value ever reaches a variable that is rendered. Its shape differs
// from `notifications/push_tokens.json` (an ARRAY of device records here, a
// dict keyed by device id there), so both shapes are accepted; treating the
// array as "not an object" was a false UNREADABLE, which is its own kind of
// lie about a healthy feed.
let (mobileTokensRaw, mobileTokensFeed) = organJSON("mobile_push/tokens.json",
                                                    rootPath("mobile_push/tokens.json"))
if mobileTokensFeed.didRead {
    func noteToken(_ o: [String: Any]) {
        if let u = ((o["updatedAt"] as? String) ?? (o["registeredAt"] as? String)
                    ?? (o["lastSeen"] as? String)).flatMap(parseTimestamp) {
            mobilePushTokenNewest = newer(mobilePushTokenNewest, u)
        }
    }
    if let arr = mobileTokensRaw as? [Any] {
        mobilePushTokenCount = arr.count
        for e in arr { if let o = e as? [String: Any] { noteToken(o) } }
    } else if let obj = mobileTokensRaw as? [String: Any] {
        mobilePushTokenCount = (obj["tokens"] as? [Any])?.count
            ?? (obj["devices"] as? [Any])?.count
            ?? obj.count
        for (_, v) in obj { if let o = v as? [String: Any] { noteToken(o) } }
    } else {
        markFeedUnreadable("mobile_push/tokens.json",
                           "present but the top level is neither an array nor an object")
    }
    if let n = mobilePushTokenCount { sources.setRows("mobile_push/tokens.json", n) }
}

// ── SYS-12: chat sessions ───────────────────────────────────────────────────
// Blueprint § State Ownership (chat store). `chat/sessions.json` is the reduced
// index; `chat/archive/sessions.jsonl` is the retention tail.
//
// `chat/messages/*.jsonl` is discovered directly and every canonical file is
// scanned for in-window rows. `chat/session_state/*/…` and compacted transcript
// families remain explicit NOT COVERED lanes; reading the canonical population
// does not imply those sibling stores were inspected.

struct ChatSessionRow {
    var id: String
    var source: String
    var createdAt: Date?
    var updatedAt: Date?
    var messageCount: Int?
    var archived: Bool
}
var chatSessions: [ChatSessionRow] = []
var chatSessionsBySource: [String: Int] = [:]
var chatSessionsInWindow = 0
var chatOldestCreated: Date?
var chatNewestUpdated: Date?
var chatIndexedMessageTotal = 0
var chatSessionsWithoutCount = 0

let (chatSessionsRaw, chatSessionsFeed) = organJSON("chat/sessions.json", rootPath("chat/sessions.json"))
if chatSessionsFeed.didRead, !(chatSessionsRaw is [Any]) {
    markFeedUnreadable("chat/sessions.json", "present but the top level is not a JSON array")
}
if chatSessionsFeed.didRead, let arr = chatSessionsRaw as? [Any] {
    for e in arr {
        guard let o = e as? [String: Any] else { continue }
        let row = ChatSessionRow(
            id: (o["id"] as? String) ?? "(no id field)",
            source: (o["source"] as? String) ?? "(no source field)",
            createdAt: (o["createdAt"] as? String).flatMap(parseTimestamp),
            updatedAt: (o["updatedAt"] as? String).flatMap(parseTimestamp),
            messageCount: (o["messageCount"] as? NSNumber)?.intValue,
            archived: (o["archived"] as? Bool) ?? false)
        chatSessions.append(row)
        chatSessionsBySource[row.source, default: 0] += 1
        if let c = row.createdAt {
            if chatOldestCreated == nil || c < chatOldestCreated! { chatOldestCreated = c }
        }
        if let u = row.updatedAt {
            chatNewestUpdated = newer(chatNewestUpdated, u)
            if u >= windowStart { chatSessionsInWindow += 1 }
        }
        if let m = row.messageCount { chatIndexedMessageTotal += m } else { chatSessionsWithoutCount += 1 }
    }
    sources.setRows("chat/sessions.json", chatSessions.count)
}

var chatArchivedTotal = 0
var chatArchiveOldest: Date?
var chatArchiveNewest: Date?
/// Archived session ids, collected so the WAVE-3 `chat/session_state/` orphan
/// check can tell "this directory belongs to a session that was archived" from
/// "this directory belongs to no session that ever existed".
var chatArchivedIds: Set<String> = []
let chatArchiveFeed = organJSONL("chat/archive/sessions.jsonl",
                                 rootPath("chat/archive/sessions.jsonl")) { obj in
    chatArchivedTotal += 1
    if let id = obj["id"] as? String { chatArchivedIds.insert(id) }
    guard let ts = ((obj["archivedAt"] as? String) ?? (obj["updatedAt"] as? String)
                    ?? (obj["createdAt"] as? String)).flatMap(parseTimestamp) else { return }
    chatArchiveNewest = newer(chatArchiveNewest, ts)
    if chatArchiveOldest == nil || ts < chatArchiveOldest! { chatArchiveOldest = ts }
}

var chatPinnedSessions: Int?
let (chatPinnedRaw, chatPinnedFeed) = organJSON("chat/pinned_session_ids.json",
                                                rootPath("chat/pinned_session_ids.json"))
if chatPinnedFeed.didRead {
    if let arr = chatPinnedRaw as? [Any] { chatPinnedSessions = arr.count }
    else if let obj = chatPinnedRaw as? [String: Any] {
        chatPinnedSessions = (obj["ids"] as? [Any])?.count ?? obj.count
    }
    if let n = chatPinnedSessions { sources.setRows("chat/pinned_session_ids.json", n) }
    // A present, parseable file of an unexpected SHAPE is unreadable, not a
    // zero — and saying so here is what lets the SYS-12 cell below render a
    // plain count and rely on the per-feed guard for the absent case.
    if chatPinnedSessions == nil {
        markFeedUnreadable("chat/pinned_session_ids.json",
                           "present but the top level is neither an array nor an object")
    }
}

// Per-surface TURN volumes in window, from the message files of the sessions
// the index says moved in window. `chat/sessions.json` carries a total
// `messageCount`, never an in-window one, so this is the only honest way to
// get the number — and it is why the reader opens files at all.
var chatTurnsBySurfaceInWindow: [String: Int] = [:]
var chatUserTurnsInWindow = 0
var chatAssistantTurnsInWindow = 0
var chatMessageFilesOpened = 0
var chatMessageFilesMissing = 0
var chatMessageRowsMalformed = 0
var chatMessageRowsRead = 0
let chatOutcomeDimensions = [
    "responsePersistence", "context", "provider", "tools", "motor", "reaction",
]
let chatOutcomeClosedStates: Set<String> = [
    "observed", "verified", "unverified", "unknown", "censored", "not_applicable",
]
var chatOutcomeAssistantRows = 0
var chatOutcomeObservationsAbsent = 0
var chatOutcomeObservationsInvalid = 0
var chatOutcomeStateCounts: [String: [String: Int]] = Dictionary(
    uniqueKeysWithValues: chatOutcomeDimensions.map { ($0, [:]) }
)
let outcomeReactionKey: (String, String, String) -> String = { sessionID, messageID, turnID in
    [sessionID, messageID, turnID].joined(separator: "\u{1F}")
}
var chatStructuredReactionKeys: Set<String> = []
let chatFeedbackFeed = organJSONL(
    "context/feedback.jsonl",
    rootPath("context/feedback.jsonl")
) { object in
    guard let schema = object["schema"] as? String,
          schema == "response.feedback.v2" || schema == "response.reaction.v2",
          let sessionID = object["sessionId"] as? String,
          let messageID = object["messageId"] as? String,
          let turnID = object["turnId"] as? String else { return }
    chatStructuredReactionKeys.insert(outcomeReactionKey(sessionID, messageID, turnID))
}
var chatCanonicalContinuationKeys: Set<String> = []
var chatValidOutcomeObservations: [(states: [String: String], reactionKey: String?)] = []
let chatMessagesDir = rootPath("chat/messages")
var chatMessagesIsDirectory: ObjCBool = false
let chatMessagesPathExists = fm.fileExists(
    atPath: chatMessagesDir,
    isDirectory: &chatMessagesIsDirectory
)
let chatMessagesPopulationAvailable = chatMessagesPathExists && chatMessagesIsDirectory.boolValue
_ = sources.register("chat/messages/", chatMessagesDir, note: "canonical transcript population")
var chatMessagesPopulationReadable = chatMessagesPopulationAvailable
var transcriptFiles: [String] = []
if chatMessagesPopulationAvailable {
    do {
        transcriptFiles = try fm.contentsOfDirectory(atPath: chatMessagesDir)
            .filter { $0.hasSuffix(".jsonl") }
            .sorted()
        sources.setRows("chat/messages/", transcriptFiles.count)
    } catch {
        chatMessagesPopulationReadable = false
        markFeedUnreadable("chat/messages/", "directory listing failed: \(type(of: error))")
    }
}
if chatMessagesPopulationReadable {
    var indexedSurface: [String: String] = [:]
    for session in chatSessions where indexedSurface[session.id] == nil {
        indexedSurface[session.id] = session.source
    }
    let inWindowIndexed = chatSessions.filter { ($0.updatedAt ?? .distantPast) >= windowStart }
    for row in inWindowIndexed {
        let path = (chatMessagesDir as NSString).appendingPathComponent(row.id + ".jsonl")
        if !fm.fileExists(atPath: path) { chatMessageFilesMissing += 1 }
    }
    // Discover the canonical population from the directory itself. Sessions
    // index rows are useful metadata, but are not an authority for whether a
    // transcript exists; orphan/unindexed JSONL files must remain observable.
    for filename in transcriptFiles {
        let sessionID = String(filename.dropLast(".jsonl".count))
        let p = (chatMessagesDir as NSString).appendingPathComponent(filename)
        guard let stream = LineStream(path: p) else { continue }
        chatMessageFilesOpened += 1
        var priorRows: [[String: Any]] = []
        stream.forEachLine { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                chatMessageRowsMalformed += 1
                return
            }
            chatMessageRowsRead += 1
            // Read-side compatibility for outcomes written before structured
            // continuation receipts existed. This is the same strict
            // transcript adjacency contract as OutcomeDimensionStatePopulationReader:
            // request(user) -> anchored assistant(same run) -> next user.
            if (obj["role"] as? String) == "user", priorRows.count >= 2 {
                let assistant = priorRows[priorRows.count - 1]
                let request = priorRows[priorRows.count - 2]
                if (assistant["role"] as? String) == "assistant",
                   (request["role"] as? String) == "user",
                   let requestRunID = request["runId"] as? String,
                   (assistant["runId"] as? String) == requestRunID,
                   (request["sessionId"] as? String) == sessionID,
                   (assistant["sessionId"] as? String) == sessionID,
                   (obj["sessionId"] as? String) == sessionID,
                   let metadata = assistant["metadata"] as? [String: Any],
                   let outcome = metadata["outcomeObservation"] as? [String: Any],
                   let messageID = assistant["id"] as? String,
                   let turnID = outcome["turnID"] as? String,
                   (outcome["messageID"] as? String) == messageID,
                   (outcome["sessionID"] as? String) == sessionID {
                    chatCanonicalContinuationKeys.insert(
                        outcomeReactionKey(sessionID, messageID, turnID)
                    )
                }
            }
            priorRows.append(obj)
            if priorRows.count > 2 { priorRows.removeFirst(priorRows.count - 2) }
            guard let ts = ((obj["createdAt"] as? String) ?? (obj["ts"] as? String))
                    .flatMap(parseTimestamp), ts >= windowStart else { return }
            // The message's OWN source wins; the session's index source is the
            // fallback, because a session can carry messages from more than one
            // surface and folding them together would invent the mix.
            let surface = (obj["source"] as? String) ?? indexedSurface[sessionID] ?? "unknown"
            chatTurnsBySurfaceInWindow[surface, default: 0] += 1
            switch (obj["role"] as? String) ?? "" {
            case "user": chatUserTurnsInWindow += 1
            case "assistant":
                chatAssistantTurnsInWindow += 1
                chatOutcomeAssistantRows += 1
                guard let metadata = obj["metadata"] as? [String: Any],
                      let outcome = metadata["outcomeObservation"] as? [String: Any] else {
                    // Absent is a population fact, never six zero buckets.
                    chatOutcomeObservationsAbsent += 1
                    break
                }
                guard let states = outcome["dimensionStates"] as? [String: Any],
                      Set(states.keys) == Set(chatOutcomeDimensions),
                      states.values.allSatisfy({ value in
                          guard let state = value as? String else { return false }
                          return chatOutcomeClosedStates.contains(state)
                      }) else {
                    chatOutcomeObservationsAbsent += 1
                    chatOutcomeObservationsInvalid += 1
                    break
                }
                let closedStates = Dictionary(uniqueKeysWithValues: chatOutcomeDimensions.compactMap {
                    dimension -> (String, String)? in
                    guard let state = states[dimension] as? String else { return nil }
                    return (dimension, state)
                })
                let reactionKey: String? = {
                    guard let messageID = obj["id"] as? String,
                          let rowSessionID = obj["sessionId"] as? String,
                          rowSessionID == sessionID,
                          let turnID = outcome["turnID"] as? String,
                          (outcome["messageID"] as? String) == messageID,
                          (outcome["sessionID"] as? String) == sessionID else { return nil }
                    return outcomeReactionKey(sessionID, messageID, turnID)
                }()
                chatValidOutcomeObservations.append((closedStates, reactionKey))
            default: break
            }
        }
    }
}

// Outcome observations are initial snapshots. Reaction is intentionally
// promoted later by exact structured feedback or strict transcript adjacency;
// counting only the embedded snapshot falsely reports a permanently dark lane.
for observation in chatValidOutcomeObservations {
    let promoted = observation.reactionKey.map {
        chatStructuredReactionKeys.contains($0) || chatCanonicalContinuationKeys.contains($0)
    } ?? false
    for dimension in chatOutcomeDimensions {
        let state = dimension == "reaction" && promoted
            ? "observed"
            : observation.states[dimension]
        if let state {
            chatOutcomeStateCounts[dimension, default: [:]][state, default: 0] += 1
        }
    }
}

var chatOutcomeDarkDimensions: [(dimension: String, state: String, count: Int, total: Int)] = []
for dimension in chatOutcomeDimensions {
    let counts = chatOutcomeStateCounts[dimension] ?? [:]
    let total = counts.values.reduce(0, +)
    guard total > 0 else { continue }
    for state in ["unknown", "censored"] {
        let count = counts[state, default: 0]
        if Double(count) / Double(total) > 0.95 {
            chatOutcomeDarkDimensions.append((dimension, state, count, total))
        }
    }
}
if chatOutcomeObservationsAbsent > 0 {
    addLead(
        rank: 7,
        "Outcome observation is absent on \(chatOutcomeObservationsAbsent) of \(chatOutcomeAssistantRows) assistant rows",
        evidence: "SYS-12 opened \(chatMessageFilesOpened) canonical message file(s); absent rows were counted separately rather than folded into zero-valued dimension buckets.",
        action: "Inspect the assistant persistence paths and malformed outcome observations before interpreting dimension totals."
    )
}
if chatSessionsFeed.didRead, !chatMessagesPopulationReadable {
    let populationCondition = chatMessagesPopulationAvailable ? "unreadable" : "absent"
    addLead(
        rank: 7,
        "Outcome dimension population source is \(populationCondition)",
        evidence: "SYS-12 found the session index but no readable canonical `chat/messages/` directory; this is source \(populationCondition), not six zero-valued dimensions.",
        action: "Restore or locate the canonical transcript population before interpreting outcome dimension totals."
    )
}
for dark in chatOutcomeDarkDimensions {
    addLead(
        rank: 8,
        "Outcome dimension `\(mdCode(dark.dimension))` has no promoter wired",
        evidence: "`\(mdCode(dark.state))` occupies \(dark.count) of \(dark.total) observations (\(fmt(100 * Double(dark.count) / Double(dark.total), 1))%), above the 95% non-terminal threshold.",
        action: "Verify the canonical producer/promoter for this dimension; do not read the dominant non-terminal bucket as measured negative evidence."
    )
}

var macTurnLifecycleKeys: Int?
var macTurnLifecycleNewest: Date?
let (macLifecycleObj, macLifecycleFeed) = organJSONObject("chat/mac_turn_lifecycle.json",
                                                          rootPath("chat/mac_turn_lifecycle.json"))
if let macLifecycleObj {
    macTurnLifecycleKeys = macLifecycleObj.count
    for key in ["updatedAt", "at", "lastTurnAt", "createdAt"] {
        if let d = (macLifecycleObj[key] as? String).flatMap(parseTimestamp) {
            macTurnLifecycleNewest = newer(macTurnLifecycleNewest, d)
        }
    }
    sources.setRows("chat/mac_turn_lifecycle.json", macLifecycleObj.count)
}

// ── SYS-13: security / trust ────────────────────────────────────────────────
// Blueprint § Security & Trust. `security/audit.jsonl` is the gate's own
// append ledger — every tool call the policy engine graded, allowed or not.
// The approval inbox (`workflows/approvals/requests.json`) is the human edge of
// the same lane: what the gate escalated, and whether anybody answered.

var auditRowsTotal = 0
var auditRowsInWindow = 0
var auditDecisions: [String: Int] = [:]
var auditRisk: [String: Int] = [:]
var auditAutonomy: [String: Int] = [:]
var auditRefusalsInWindow = 0
var auditRefusalsByTool: [String: Int] = [:]
var auditRefusalReasons: [String: Int] = [:]
var auditApprovalRequiredInWindow = 0
var auditUntrustedOriginInWindow = 0
var auditNewest: Date?
var auditOldest: Date?
let auditFeed = organJSONL("security/audit.jsonl", rootPath("security/audit.jsonl")) { obj in
    auditRowsTotal += 1
    let ts = ((obj["created_at"] as? String) ?? (obj["createdAt"] as? String) ?? (obj["at"] as? String))
        .flatMap(parseTimestamp)
    if let ts {
        auditNewest = newer(auditNewest, ts)
        if auditOldest == nil || ts < auditOldest! { auditOldest = ts }
    }
    guard let ts, ts >= windowStart else { return }
    auditRowsInWindow += 1
    let decision = (obj["decision"] as? String) ?? "(no decision field)"
    auditDecisions[decision, default: 0] += 1
    auditRisk[(obj["risk"] as? String) ?? "(no risk field)", default: 0] += 1
    auditAutonomy[(obj["autonomy_level"] as? String) ?? "(no autonomy_level field)", default: 0] += 1
    if (obj["requires_approval"] as? Bool) == true { auditApprovalRequiredInWindow += 1 }
    if (obj["origin_trusted"] as? Bool) == false { auditUntrustedOriginInWindow += 1 }
    // A refusal is the gate saying no. `allowed:false` is the authoritative
    // field; the decision string is the human-readable half of the same fact.
    guard (obj["allowed"] as? Bool) == false else { return }
    auditRefusalsInWindow += 1
    auditRefusalsByTool[(obj["tool"] as? String) ?? "(no tool field)", default: 0] += 1
    if let reasons = obj["reasons"] as? [Any] {
        // Bucket to the reason's leading token only — audit rows can carry
        // path fragments or user-adjacent detail in their tails, and this
        // report must render security METADATA, never quoted audit content
        // (gpt-5.5 wave-2 review). The first token is the machine-readable
        // reason class (e.g. "persona_write_guard", "confirm_required").
        for r in reasons.compactMap({ $0 as? String }) {
            let bucket = r.split(separator: " ").first.map(String.init) ?? "(empty)"
            auditRefusalReasons[String(bucket.prefix(48)), default: 0] += 1
        }
    }
}

var canaryTripsTotal = 0
var canaryTripsInWindow = 0
var canaryKinds: [String: Int] = [:]
var canaryNewest: Date?
let canaryFeed = organJSONL("security/canary_trips.jsonl", rootPath("security/canary_trips.jsonl")) { obj in
    canaryTripsTotal += 1
    guard let ts = ((obj["at"] as? String) ?? (obj["createdAt"] as? String)).flatMap(parseTimestamp) else { return }
    canaryNewest = newer(canaryNewest, ts)
    guard ts >= windowStart else { return }
    canaryTripsInWindow += 1
    canaryKinds[(obj["kind"] as? String) ?? "(no kind field)", default: 0] += 1
}

var macControlRowsTotal = 0
var macControlInWindow = 0
var macControlBlocked = 0
var macControlNonZeroExit = 0
var macControlApprovalRequired = 0
var macControlNewest: Date?
var macControlCategories: [String: Int] = [:]
for (label, rel) in [("mac_control_audit.jsonl", "mac_control_audit.jsonl"),
                     ("mac_control_bridge_audit.jsonl", "mac_control_bridge_audit.jsonl")] {
    _ = organJSONL(label, rootPath(rel)) { obj in
        macControlRowsTotal += 1
        let ts = ((obj["executed_at"] as? String) ?? (obj["at"] as? String)
                  ?? (obj["createdAt"] as? String)).flatMap(parseTimestamp)
        if let ts { macControlNewest = newer(macControlNewest, ts) }
        guard let ts, ts >= windowStart else { return }
        macControlInWindow += 1
        // The two feeds label a call differently: the direct audit carries
        // `category`/`method`, the bridge audit carries `argv0`/`status`. Both
        // spellings are accepted rather than folding the bridge's 471 rows into
        // one "(no category)" bucket that says nothing.
        macControlCategories[(obj["category"] as? String)
                             ?? (obj["method"] as? String)
                             ?? (obj["argv0"] as? String)
                             ?? (obj["status"] as? String)
                             ?? "(no category/method/argv0/status field)", default: 0] += 1
        if (obj["blocked"] as? Bool) == true { macControlBlocked += 1 }
        if (obj["approval_required"] as? Bool) == true { macControlApprovalRequired += 1 }
        if let ec = (obj["exit_code"] as? NSNumber)?.intValue, ec != 0 { macControlNonZeroExit += 1 }
    }
}
let macControlLabels = ["mac_control_audit.jsonl", "mac_control_bridge_audit.jsonl"]

// The permissions file is a two-level map: `<integration>: {read: Bool, write:
// Bool}`. Counting only top-level Bools scored 0/11 granted on a file where
// every integration has at least one grant — a zero produced by reading the
// wrong level, which is the same lie as an absent-as-zero. Both levels count.
var macPermissionKeys: Int?
var macPermissionGrants: Int?
var macPermissionGranted = 0
let (macPermObj, macPermFeed) = organJSONObject("security/mac_integration_permissions.json",
                                                rootPath("security/mac_integration_permissions.json"))
if let macPermObj {
    macPermissionKeys = macPermObj.count
    var grantSlots = 0
    for (_, v) in macPermObj {
        if let b = v as? Bool {
            grantSlots += 1
            if b { macPermissionGranted += 1 }
        } else if let inner = v as? [String: Any] {
            for (_, iv) in inner {
                guard let b = iv as? Bool else { continue }
                grantSlots += 1
                if b { macPermissionGranted += 1 }
            }
        }
    }
    macPermissionGrants = grantSlots
    sources.setRows("security/mac_integration_permissions.json", macPermObj.count)
}

var autonomyLastScan: Date?
let autonomyScanPath = rootPath("security/autonomy_promotion/last_scan")
if sources.register("security/autonomy_promotion/last_scan", autonomyScanPath,
                    note: "read-only stamp file") {
    if let data = fm.contents(atPath: autonomyScanPath),
       let text = String(data: data, encoding: .utf8) {
        autonomyLastScan = parseTimestamp(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if autonomyLastScan == nil {
            markFeedUnreadable("security/autonomy_promotion/last_scan",
                               "present but its contents are not a parseable instant")
        } else {
            sources.setRows("security/autonomy_promotion/last_scan", 1)
        }
    } else {
        markFeedUnreadable("security/autonomy_promotion/last_scan", "present but could not be read as UTF-8")
    }
}

var trustPolicyKeys: Int?
let (trustPolicyObj, trustPolicyFeed) = organJSONObject("trust/policy.json", rootPath("trust/policy.json"))
if let trustPolicyObj {
    trustPolicyKeys = trustPolicyObj.count
    sources.setRows("trust/policy.json", trustPolicyObj.count)
}

// The instrument cannot link the runtime module, so this is a deliberately
// narrow mirror of `TrustPolicyAuthorizationSnapshot.securityPolicyProvenance`.
// Keep it exhaustive: the report distinguishes an operator-authored saved
// value from the default the checked TrustCenter reader will enforce. A missing
// policy file therefore remains source-absent in SYS-13 (the default is detail
// provenance, not a measured healthy posture), while malformed authority is
// unreadable/fail-closed rather than defaulted.
enum SecurityPolicyDefault: Equatable {
    case bool(Bool)
    case string(String)

    var rendered: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .string(let value): return "`\(mdCode(value))`"
        }
    }

    func explicitValue(_ raw: Any) -> SecurityPolicyDefault? {
        switch self {
        case .bool:
            guard let value = raw as? Bool else { return nil }
            return .bool(value)
        case .string:
            guard let value = raw as? String else { return nil }
            return .string(value)
        }
    }
}

// Keep case meaning and report spelling aligned with the runtime's
// TrustPolicySecurityValueProvenance. The instrument cannot import the module,
// but it must never collapse the canonical distinctions while rendering them.
enum SecurityPolicyProvenance: Equatable {
    case explicit
    case defaultMissingKey
    case defaultMissingBlock
    case defaultSourceAbsent
    case unreadable

    var reportText: String {
        switch self {
        case .explicit: return "explicit"
        case .defaultMissingKey: return "default (key missing)"
        case .defaultMissingBlock: return "default (block missing)"
        case .defaultSourceAbsent: return "default (policy source absent)"
        case .unreadable: return "unreadable"
        }
    }
}

struct SecurityPolicyPostureRow {
    let key: String
    let value: SecurityPolicyDefault
    let effectiveValue: String
    let provenance: SecurityPolicyProvenance
}

let canonicalSecurityPolicyDefaults: [(key: String, value: SecurityPolicyDefault)] = [
    ("securityCenterEnabled", .bool(true)),
    ("capabilityPolicyEnabled", .bool(true)),
    ("originTrustEnabled", .bool(true)),
    ("signedRemoteCommandsRequired", .bool(true)),
    ("promptInjectionShieldEnabled", .bool(true)),
    ("dangerGatesEnabled", .bool(true)),
    ("rollbackByDefault", .bool(true)),
    ("secretFirewallEnabled", .bool(true)),
    ("toolSigningRequired", .bool(false)),
    ("auditReceiptsEnabled", .bool(true)),
    ("allowAppNotifications", .bool(true)),
    ("killSwitchEnabled", .bool(false)),
    ("remoteHighRiskDefault", .string("block")),
    ("criticalRequiresDeveloperMode", .bool(false)),
]

var securityPolicyPostureRows: [SecurityPolicyPostureRow] = []
if trustPolicyFeed.didRead, let trustPolicyObj {
    if let rawBlock = trustPolicyObj["securityPolicy"] {
        if let savedSecurity = rawBlock as? [String: Any] {
            for entry in canonicalSecurityPolicyDefaults {
                if let raw = savedSecurity[entry.key] {
                    guard let value = entry.value.explicitValue(raw) else {
                        markFeedUnreadable("trust/policy.json",
                                          "securityPolicy.\(entry.key) has the wrong JSON type")
                        securityPolicyPostureRows = []
                        break
                    }
                    securityPolicyPostureRows.append(SecurityPolicyPostureRow(
                        key: entry.key, value: value,
                        effectiveValue: value.rendered, provenance: .explicit))
                } else {
                    securityPolicyPostureRows.append(SecurityPolicyPostureRow(
                        key: entry.key, value: entry.value, effectiveValue: entry.value.rendered,
                        provenance: .defaultMissingKey))
                }
            }
        } else {
            // Existing authority with a malformed type is unavailable. Do not
            // invent effective values from a file TrustCenter will refuse.
            markFeedUnreadable("trust/policy.json", "securityPolicy exists but is not an object")
            securityPolicyPostureRows = []
        }
    } else {
        securityPolicyPostureRows = canonicalSecurityPolicyDefaults.map {
            SecurityPolicyPostureRow(key: $0.key, value: $0.value, effectiveValue: $0.value.rendered,
                                     provenance: .defaultMissingBlock)
        }
    }
} else if case .absent = trustPolicyFeed {
    securityPolicyPostureRows = canonicalSecurityPolicyDefaults.map {
        SecurityPolicyPostureRow(key: $0.key, value: $0.value, effectiveValue: $0.value.rendered,
                                 provenance: .defaultSourceAbsent)
    }
}
let securityPolicyExplicitCount = securityPolicyPostureRows.filter { $0.provenance == .explicit }.count
let securityPolicyDefaultedCount = securityPolicyPostureRows.count - securityPolicyExplicitCount

// These are the policy switches the live SecurityCenter actually consults at
// authorization/record time. The defaults intentionally leave *tool* signing
// and critical Developer Mode relaxed for this installation, so those are shown
// in the posture table but are NOT silently treated as failures here. Conversely,
// every key below removes a concrete protection when false: remote-origin
// blocking, remote-signature checks, injection review, secret egress blocking,
// rollback evidence, or the audit evidence itself. This makes SYS-13 fail on
// a truly weakened saved posture instead of calling every parseable policy
// healthy merely because no canary happened to fire.
let securityPolicyProtectedKeys: [(key: String, label: String)] = [
    ("originTrustEnabled", "origin trust"),
    ("signedRemoteCommandsRequired", "remote command signing"),
    ("promptInjectionShieldEnabled", "prompt-injection shield"),
    ("secretFirewallEnabled", "secret firewall"),
    ("rollbackByDefault", "rollback receipts"),
    ("auditReceiptsEnabled", "audit receipts"),
]
let securityPolicyPostureByKey = Dictionary(
    uniqueKeysWithValues: securityPolicyPostureRows.map { ($0.key, $0) }
)
let securityPolicyPostureKnown = trustPolicyFeed.didRead
    && !sources.isUnreadable("trust/policy.json")
    && securityPolicyPostureRows.count == canonicalSecurityPolicyDefaults.count
let securityPolicyWeakened = securityPolicyProtectedKeys.compactMap { protected -> String? in
    guard securityPolicyPostureKnown,
          let row = securityPolicyPostureByKey[protected.key],
          case .bool(false) = row.value else { return nil }
    return protected.label
}
let securityPolicyProtectedEnabledCount = securityPolicyProtectedKeys.count - securityPolicyWeakened.count

// The approval inbox: what the gate escalated to a human, and what happened.
var approvalsTotal = 0
var approvalDecisions: [String: Int] = [:]
var approvalStatuses: [String: Int] = [:]
var approvalPending = 0
var approvalLatenciesHours: [Double] = []
var approvalOldestPending: Date?
var approvalNewest: Date?
var approvalsInWindow = 0
let (approvalsRaw, approvalsFeed) = organJSON("workflows/approvals/requests.json",
                                              rootPath("workflows/approvals/requests.json"))
if approvalsFeed.didRead {
    if let arr = approvalsRaw as? [Any] {
        for e in arr {
            guard let o = e as? [String: Any] else { continue }
            approvalsTotal += 1
            let created = (o["createdAt"] as? String).flatMap(parseTimestamp)
            let resolved = (o["resolvedAt"] as? String).flatMap(parseTimestamp)
            if let c = created {
                approvalNewest = newer(approvalNewest, c)
                if c >= windowStart { approvalsInWindow += 1 }
            }
            // A null decision is a request nobody answered — the whole point of
            // reading this file. It is bucketed explicitly, not defaulted.
            let decision = (o["decision"] as? String)
            approvalDecisions[decision ?? "(unanswered — decision is null)", default: 0] += 1
            approvalStatuses[(o["status"] as? String) ?? "(no status field)", default: 0] += 1
            if decision == nil {
                approvalPending += 1
                if let c = created, approvalOldestPending == nil || c < approvalOldestPending! {
                    approvalOldestPending = c
                }
            }
            if let c = created, let r = resolved, r >= c {
                approvalLatenciesHours.append(r.timeIntervalSince(c) / 3600)
            }
        }
        sources.setRows("workflows/approvals/requests.json", approvalsTotal)
    } else {
        markFeedUnreadable("workflows/approvals/requests.json",
                           "present but the top level is not a JSON array")
    }
}

var effectSpends: Int?
var effectSpendNewest: Date?
let (effectSpendObj, effectSpendFeed) = organJSONObject("workflows/approvals/effect_spends.json",
                                                        rootPath("workflows/approvals/effect_spends.json"))
if let effectSpendObj {
    let spends = (effectSpendObj["spends"] as? [String: Any]) ?? [:]
    effectSpends = spends.count
    for (_, v) in spends {
        if let o = v as? [String: Any], let s = (o["spentAt"] as? String).flatMap(parseTimestamp) {
            effectSpendNewest = newer(effectSpendNewest, s)
        }
    }
    sources.setRows("workflows/approvals/effect_spends.json", spends.count)
}

// The workflow run ledger is a three-source family.  `runs.jsonl` is durable
// append history, `registry.json` declares whether each workflow is runnable,
// and `run_state/` is the relaunch authority for anything not terminal.  Read
// each source independently: a missing or damaged member is evidence about the
// family, never a reason to print a reassuring zero.
let workflowSupportedStepKinds: Set<String> = [
    "approval", "mcp_tool", "memory", "research", "router", "tool_run", "trace",
]
var workflowRegistryStatuses: [String: Int] = [:]
var workflowUnsupportedKinds: [String: Int] = [:]
let (workflowRegistryRaw, workflowRegistryFeed) = organJSON(
    "workflows/registry.json", rootPath("workflows/registry.json")
)
if workflowRegistryFeed.didRead {
    if let rows = workflowRegistryRaw as? [[String: Any]] {
        for row in rows {
            workflowRegistryStatuses[(row["status"] as? String) ?? "(missing)", default: 0] += 1
            for step in (row["steps"] as? [[String: Any]] ?? []) {
                let kind = ((step["kind"] as? String) ?? "manual")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !workflowSupportedStepKinds.contains(kind) {
                    workflowUnsupportedKinds[kind.isEmpty ? "manual" : kind, default: 0] += 1
                }
            }
        }
        sources.setRows("workflows/registry.json", rows.count)
    } else {
        markFeedUnreadable("workflows/registry.json", "present but the top level is not a JSON array")
    }
}

var workflowRunStatuses: [String: Int] = [:]
var workflowRunNewest: Date?
let workflowRunsFeed = organJSONL("workflows/runs.jsonl", rootPath("workflows/runs.jsonl")) { row in
    workflowRunStatuses[(row["status"] as? String) ?? "(missing)", default: 0] += 1
    if let stamp = ((row["createdAt"] as? String) ?? (row["completedAt"] as? String)).flatMap(parseTimestamp) {
        workflowRunNewest = newer(workflowRunNewest, stamp)
    }
}

let workflowRunStateLabel = "workflows/run_state/"
let workflowRunStatePath = rootPath("workflows/run_state")
let workflowRunStatePresent = sources.register(workflowRunStateLabel, workflowRunStatePath,
                                                note: "read-only state-file inventory and status stamps")
var workflowRunStateFeed: FeedState = .absent
var workflowRunStateStatuses: [String: Int] = [:]
var workflowStaleNonTerminalStates: [String] = []
var workflowOldApprovalWaits: [String] = []
var workflowOldPersistedAttempts: [String] = []
if workflowRunStatePresent {
    var runStateIsDirectory = ObjCBool(false)
    if fm.fileExists(atPath: workflowRunStatePath, isDirectory: &runStateIsDirectory), !runStateIsDirectory.boolValue {
        let reason = "present but is not a directory"
        markFeedUnreadable(workflowRunStateLabel, reason)
        workflowRunStateFeed = .unreadable(reason)
    } else {
        let (entries, directoryState) = organDirectory(workflowRunStateLabel, workflowRunStatePath)
        workflowRunStateFeed = directoryState
        if directoryState.didRead {
            var malformed = 0
            var parsed = 0
            let terminalStates: Set<String> = ["succeeded", "completed", "done", "failed", "canceled", "cancelled", "rolled_back", "expired"]
            for entry in entries where entry.hasSuffix(".json") {
                let path = (workflowRunStatePath as NSString).appendingPathComponent(entry)
                guard let data = fm.contents(atPath: path),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    malformed += 1
                    continue
                }
                parsed += 1
                let status = (state["status"] as? String) ?? "(missing)"
                workflowRunStateStatuses[status, default: 0] += 1
                let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                if !terminalStates.contains(status), let modified, now.timeIntervalSince(modified) > 60 * 60 {
                    let id = (state["id"] as? String) ?? (entry as NSString).deletingPathExtension
                    if let attempt = state["activeStepAttempt"] as? [String: Any], !attempt.isEmpty {
                        workflowOldPersistedAttempts.append(id)
                    } else if status == "waiting_approval",
                              state["activeStepAttempt"] == nil || state["activeStepAttempt"] is NSNull {
                        workflowOldApprovalWaits.append(id)
                    } else {
                        workflowStaleNonTerminalStates.append(id)
                    }
                }
            }
            workflowStaleNonTerminalStates.sort()
            workflowOldApprovalWaits.sort()
            workflowOldPersistedAttempts.sort()
            sources.setRows(workflowRunStateLabel, parsed)
            if let condemned = condemnUnparseableFamily(workflowRunStateLabel, total: parsed + malformed, unparseable: malformed) {
                workflowRunStateFeed = condemned
            } else if malformed > 0 {
                sources.note(workflowRunStateLabel, "PARTIAL — \(malformed) malformed state file(s) skipped")
            }
        }
    }
}

/// Tools the gate refused most in window, ties on tool name.
let auditWorstRefused = auditRefusalsByTool
    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }

// ── SYS-14: the update lane ─────────────────────────────────────────────────
// Blueprint § Distribution / `docs` update-honesty pipeline.
//
// THE DATA ROOT PERSISTS NOTHING FOR THIS ORGAN. That is a finding, not a gap
// in this reader: `UpdateController` keeps its notice in `UserDefaults` and the
// publish-honesty flag lives in the INSTALLED BUNDLE's `Info.plist`
// (`NativeAgentUpdateFeedPublished`), alongside `SUFeedURL`. Both are
// machine-global, so — exactly like the SYS-01 bridge lanes — they are read
// only when the data root is a real install root, and `--no-machine-state`
// turns them off. On a fixture root SYS-14 correctly reads `source absent`.

let machineStateEnabled = !machineStateDisabled && dataRootIsInstallRoot

/// Reads a binary/XML plist without shelling out. A plist that EXISTS and will
/// not parse is unreadable — same rule as every JSON reader above.
func organPlist(_ label: String, _ path: String, note: String) -> ([String: Any]?, FeedState) {
    guard sources.register(label, path, note: note) else { return (nil, .absent) }
    guard let data = fm.contents(atPath: path) else {
        let reason = "present but could not be read"
        markFeedUnreadable(label, reason)
        return (nil, .unreadable(reason))
    }
    guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        let reason = "present but is not a parseable property list (\(data.count) byte(s))"
        markFeedUnreadable(label, reason)
        return (nil, .unreadable(reason))
    }
    return (obj, .read(rows: obj.count))
}

var updateBundlePath: String?
var updateBundleVersion: String?
var updateBundleBuild: String?
var updateBundleID: String?
var updateFeedURL: String?
var updateFeedPublished: Bool?
var updateSigningKeyPresent = false
var updateDefaultsPath: String?
var updateSparkleKeys: [String: String] = [:]
var updateNoticePersisted: Bool?
var updateAutomaticChecksEnabled: Bool?
var updateScheduledCheckInterval = 24 * 60 * 60.0
var updateScheduleActivatedAt: Date?
var updateLastScheduledCheckAt: Date?
var updateLastScheduledFailureAt: Date?
var updateScheduleContextMatches = false
var updateLabels: [String] = []

if machineStateEnabled {
    // Fixed, sorted candidate list — never a glob, so two runs pick the same
    // bundle. First hit wins and the row NAMES which one it read.
    let candidates = [
        absolutize("/Applications/NativeAgent.app"),
        absolutize("~/Applications/NativeAgent.app"),
    ]
    let bundle = candidates.first { fm.fileExists(atPath: $0) }
    let infoPath = ((bundle ?? candidates[0]) as NSString).appendingPathComponent("Contents/Info.plist")
    let infoLabel = "update/Info.plist"
    updateLabels.append(infoLabel)
    let (info, infoState) = organPlist(infoLabel, infoPath,
                                       note: "installed app bundle, read-only (outside the data root)")
    if let info, infoState.didRead {
        updateBundlePath = bundle
        updateBundleVersion = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        updateBundleBuild = info["CFBundleVersion"] as? String
        updateBundleID = info["CFBundleIdentifier"] as? String
        updateFeedURL = (info["SUFeedURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        updateFeedPublished = info["NativeAgentUpdateFeedPublished"] as? Bool
        updateSigningKeyPresent = (info["SUPublicEDKey"] as? String)?.isEmpty == false
        if let interval = (info["SUScheduledCheckInterval"] as? NSNumber)?.doubleValue,
           interval.isFinite,
           interval >= 60 {
            updateScheduledCheckInterval = interval
        }
    }
    // The app's own preferences domain, where BOTH Sparkle and
    // `UpdateController.persistedNoticeKey` write. Its name is the bundle id,
    // so it is only looked for once the bundle has actually been read.
    if let bid = updateBundleID {
        let prefsPath = absolutize("~/Library/Preferences/\(bid).plist")
        let prefsLabel = "update/\(bid).plist"
        updateLabels.append(prefsLabel)
        updateDefaultsPath = prefsPath
        let (prefs, prefsState) = organPlist(prefsLabel, prefsPath,
                                             note: "app preferences domain, read-only (outside the data root)")
        if let prefs, prefsState.didRead {
            // ALLOWLIST, same discipline as the provider credential files: this
            // domain holds arbitrary app state and must not be dumped. Only the
            // update-lane keys are read out.
            for key in ["SULastCheckTime", "SUEnableAutomaticChecks", "SUSkippedVersion",
                        "SUAutomaticallyUpdate", "SUFeedURL", "SUHasLaunchedBefore",
                        "NativeAgent.updateScheduleActivatedAt.v1",
                        "NativeAgent.updateLastScheduledCheckAt.v1",
                        "NativeAgent.updateLastScheduledFailureAt.v1"] {
                guard let v = prefs[key] else { continue }
                if let d = v as? Date { updateSparkleKeys[key] = stamp(d) }
                else if let b = v as? Bool { updateSparkleKeys[key] = b ? "true" : "false" }
                else { updateSparkleKeys[key] = String(describing: v).prefix(60).description }
            }
            updateNoticePersisted = prefs["NativeAgent.updateNotice.v1"] != nil
            updateAutomaticChecksEnabled = prefs["SUEnableAutomaticChecks"] as? Bool
            updateScheduleActivatedAt = prefs["NativeAgent.updateScheduleActivatedAt.v1"] as? Date
            updateLastScheduledCheckAt = prefs["NativeAgent.updateLastScheduledCheckAt.v1"] as? Date
            updateLastScheduledFailureAt = prefs["NativeAgent.updateLastScheduledFailureAt.v1"] as? Date
            if let version = updateBundleVersion,
               let feed = updateFeedURL,
               let context = prefs["NativeAgent.updateScheduleContext.v1"] as? String {
                updateScheduleContextMatches = context == "\(version)\u{1F}\(feed)"
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WAVE 3 readers — the uncovered ACTIVE feeds
//
// Every feed below was NOT COVERED by any reader in this instrument and is
// written by the live app. They were picked by silent-failure class from
// `docs/evals/ledger.json` (fence `feeds`), not by size:
//
//   state-lifecycle leak  chat/session_state/**, chat/sessions/*/cancelled.flag,
//                         chat/sessions/*/messages.compact.*.jsonl, builder_audit/
//   silent zero           telegram/errors.jsonl + slack/errors.jsonl (a surface
//                         that is FAILING, not idle), doctor/latest.json
//   dropped row           activity/events.jsonl (the SECOND events feed; its
//                         5000-line cap only bites once the file crosses 4 MiB,
//                         so the first trim drops the rarest kinds)
//   wrong value           mac_control/operations.json vs the tool.dispatch rows
//   credential boundary   oauth_tokens/*.json — SHAPE ONLY, never material
//
// Same three rules as every reader above. Nothing here opens a live sqlite
// file, nothing writes anywhere, and a feed that is absent or unreadable is
// labelled — never rendered as a zero.
// ─────────────────────────────────────────────────────────────────────────────

// ── W3-A: chat/session_state/ + per-session residue ─────────────────────────
// `SessionDigestProvider` writes `chat/session_state/<sessionId>/digest.txt` for
// every session ever created and NOTHING prunes it — there are digests for
// long-dead test ids. The eval is a BOUND on orphans, not a count: an orphan
// directory is one whose id is in neither the live index nor the archive tail.
var sessionStateDirs = 0
var sessionStateOrphans: [String] = []
var sessionStateBytes: Int64 = 0
var sessionStateProviderUsageFiles = 0
var sessionStateDigestFiles = 0
let sessionStateRoot = rootPath("chat/session_state")
let sessionStateLabel = "chat/session_state/"
let sessionStatePresent = sources.register(sessionStateLabel, sessionStateRoot,
                                           note: "directory listing + per-session file names; "
                                               + "digest/provider_usage CONTENTS are never opened")
noAutoClaimLabels.insert(sessionStateLabel)
var sessionStateState: FeedState = .absent
if sessionStatePresent {
    let (entries, state) = organDirectory(sessionStateLabel, sessionStateRoot)
    sessionStateState = state
    if state.didRead {
        let liveIds = Set(chatSessions.map { $0.id })
        for entry in entries where !entry.hasPrefix(".") {
            let dir = (sessionStateRoot as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            sessionStateDirs += 1
            // Orphan only when BOTH indexes read. If `chat/sessions.json` could
            // not be read, every directory would look orphaned — that is the
            // silent-zero shape inverted, and it is refused here.
            if chatSessionsFeed.didRead, !liveIds.contains(entry), !chatArchivedIds.contains(entry) {
                sessionStateOrphans.append(entry)
            }
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let full = (dir as NSString).appendingPathComponent(f)
                sessionStateBytes += Int64(((try? fm.attributesOfItem(atPath: full))?[.size] as? Int64) ?? 0)
                if f == "provider_usage.json" { sessionStateProviderUsageFiles += 1 }
                if f == "digest.txt" { sessionStateDigestFiles += 1 }
            }
            claimFeedFamily(normalizeRelativePath("chat/session_state/\(entry)/digest.txt"), by: sessionStateLabel)
            claimFeedFamily(normalizeRelativePath("chat/session_state/\(entry)/provider_usage.json"),
                            by: sessionStateLabel)
        }
        sources.setRows(sessionStateLabel, sessionStateDirs)
    }
}

// `chat/sessions/<id>/` — the autocompactor's output and the cancellation flag.
// A compact artifact that is NOT smaller than its source means compaction cost
// storage instead of saving it; a `cancelled.flag` is a TRANSIENT, so one that
// outlives its turn would cancel a live turn on a reused session id.
var compactGenerationsBySession: [String: Int] = [:]
var compactBytes: Int64 = 0
var compactNotSmaller: [String] = []
var cancelledFlags: [(session: String, age: Double)] = []
/// NAMED BOUNDS. A compaction lane with no retention and a transient flag that
/// outlives its turn are both invisible without a stated bound to cross.
let compactGenerationCeiling = 5
let cancelledFlagMaxAgeDays = 1.0
let sessionStateOrphanCeiling = 50
let chatSessionsDirRoot = rootPath("chat/sessions")
let chatSessionsDirLabel = "chat/sessions/"
let chatSessionsDirPresent = sources.register(chatSessionsDirLabel, chatSessionsDirRoot,
                                              note: "per-session directory NAMES and file sizes only; "
                                                  + "transcript contents are never opened")
noAutoClaimLabels.insert(chatSessionsDirLabel)
var chatSessionsDirState: FeedState = .absent
if chatSessionsDirPresent {
    let (entries, state) = organDirectory(chatSessionsDirLabel, chatSessionsDirRoot)
    chatSessionsDirState = state
    if state.didRead {
        for entry in entries where !entry.hasPrefix(".") {
            let dir = (chatSessionsDirRoot as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            var liveBytes: Int64 = 0
            var compactTotal: Int64 = 0
            for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
                let full = (dir as NSString).appendingPathComponent(f)
                let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
                let size = Int64((attrs[.size] as? Int64) ?? 0)
                if f == "messages.jsonl" { liveBytes = size }
                if f.hasPrefix("messages.compact.") && f.hasSuffix(".jsonl") {
                    compactGenerationsBySession[entry, default: 0] += 1
                    compactBytes += size
                    compactTotal += size
                    claimFeedFamily(normalizeRelativePath("chat/sessions/\(entry)/\(f)"),
                                    by: chatSessionsDirLabel)
                }
                if f == "cancelled.flag" {
                    claimFeedFamily(normalizeRelativePath("chat/sessions/\(entry)/cancelled.flag"),
                                    by: chatSessionsDirLabel)
                    if let m = attrs[.modificationDate] as? Date {
                        cancelledFlags.append((entry, daysSince(m)))
                    }
                }
            }
            // Only comparable when BOTH sides are present — a session with no
            // live transcript says nothing about compaction, and guessing here
            // would be the wrong-value failure this check exists to catch.
            if liveBytes > 0, compactTotal > 0, compactTotal >= liveBytes {
                compactNotSmaller.append(entry)
            }
        }
        sources.setRows(chatSessionsDirLabel, compactGenerationsBySession.values.reduce(0, +))
    }
}

// ── W3-B: activity/events.jsonl — the SECOND events feed ────────────────────
// Five-plus co-writers, ACTIVE, zero readers in any tier. The eviction shape is
// the sharp part: `JSONLLineCaps.activityEvents = 5000` is only enforced once
// the file crosses `activityTrimTriggerBytes = 4 MiB`
// (PersistenceCore.swift:970 / :1188-1192), so the first trim drops the OLDEST
// rows — which is exactly where the single-row kinds live.
let activityEventsLineCap = 5000
let activityTrimTriggerBytes: Int64 = 4 << 20
var activityKinds: [String: Int] = [:]
var activityRows = 0
var activityNewest: Date?
var activityBytes: Int64 = 0
let activityEventsPath = rootPath("activity/events.jsonl")
activityBytes = Int64(((try? fm.attributesOfItem(atPath: activityEventsPath))?[.size] as? Int64) ?? 0)
let activityFeed = organJSONL("activity/events.jsonl", activityEventsPath) { obj in
    activityRows += 1
    activityKinds[(obj["kind"] as? String) ?? "(no kind field)", default: 0] += 1
    if let ts = ((obj["createdAt"] as? String) ?? (obj["ts"] as? String)).flatMap(parseTimestamp) {
        activityNewest = newer(activityNewest, ts)
    }
}
/// Kinds represented by so few rows that the FIRST eviction takes them out
/// entirely. Named BEFORE the trim, not after — after, there is nothing left to
/// name.
let activityRareKinds = activityKinds.filter { $0.value <= 2 }.keys.sorted()

// ── W3-C: builder_audit/ — one permanent file per builder-tool call ─────────
var builderAuditFiles = 0
var builderAuditReceiptFiles = 0
var builderAuditSidecarFiles = 0
var builderAuditBytes: Int64 = 0
var builderAuditOldest: Date?
var builderAuditNewest: Date?
let builderAuditRoot = rootPath("builder_audit")
let builderAuditLabel = "builder_audit/"
let builderAuditPresent = sources.register(builderAuditLabel, builderAuditRoot,
                                           note: "file names, sizes and mtimes only — audit CONTENTS "
                                               + "are never opened (they carry command text)")
noAutoClaimLabels.insert(builderAuditLabel)
var builderAuditState: FeedState = .absent
if builderAuditPresent {
    let (entries, state) = organDirectory(builderAuditLabel, builderAuditRoot)
    builderAuditState = state
    if state.didRead {
        for f in entries where !f.hasPrefix(".") {
            let full = (builderAuditRoot as NSString).appendingPathComponent(f)
            let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
            builderAuditFiles += 1
            let stem = (f as NSString).deletingPathExtension
            if (f as NSString).pathExtension == "json", UUID(uuidString: stem) != nil {
                builderAuditReceiptFiles += 1
            } else {
                builderAuditSidecarFiles += 1
            }
            builderAuditBytes += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if let m = attrs[.modificationDate] as? Date {
                builderAuditNewest = newer(builderAuditNewest, m)
                if builderAuditOldest == nil || m < builderAuditOldest! { builderAuditOldest = m }
            }
            claimFeedFamily(normalizeRelativePath("builder_audit/\(f)"), by: builderAuditLabel)
        }
        sources.setRows(builderAuditLabel, builderAuditFiles)
    }
}
/// Named ceilings. These are BOUNDS this report asserts, not measurements — a
/// directory with no rotation crosses them and says so, instead of growing to
/// the 1 GB disk-hygiene tripwire in silence.
let builderAuditReceiptCeiling = 500

// ── W3-D: surface ERROR feeds — "failing, not idle" ─────────────────────────
// Generalized rule: a surface whose ERROR feed is live while its RECEIPT/state
// feed is stale is not quiet, it is broken. `slack/errors.jsonl` sits AT its
// 5000-row cap while `slack/receipts.jsonl` is dormant; `telegram/errors.jsonl`
// is the noisiest channel in the data root. Both read clean everywhere else.
struct SurfaceErrorFeed {
    var name: String
    var errorRows = 0
    var errorRowsInWindow = 0
    var errorNewest: Date?
    var codes: [String: Int] = [:]
    var errorState: FeedState = .absent
    var receiptNewest: Date?
    var receiptRows = 0
    var receiptState: FeedState = .absent
    var errorBytes: Int64 = 0
    var lineCap: Int?
    var byteCap: Int64?
}
var surfaceErrorFeeds: [SurfaceErrorFeed] = []

// Slack's canonical runtime state is the current liveness owner. A bounded
// historical error ledger must not overrule a fresh connected heartbeat.
var slackRuntimeConnected: Bool?
var slackRuntimeUpdatedAt: Date?
let slackRuntimeStaleAfter: TimeInterval = 90
let (slackRuntimeObj, slackRuntimeFeed) = organJSONObject(
    "slack/state.json", rootPath("slack/state.json"),
    note: "read-only connection flag + updatedAt heartbeat; error text is never copied out"
)
if let slackRuntimeObj {
    slackRuntimeConnected = slackRuntimeObj["connected"] as? Bool
    slackRuntimeUpdatedAt = (slackRuntimeObj["updatedAt"] as? String).flatMap(parseTimestamp)
    sources.setRows("slack/state.json", 1)
}
let slackRuntimeIsCurrentConnected: Bool = {
    guard slackRuntimeFeed.didRead,
          slackRuntimeConnected == true,
          let updated = slackRuntimeUpdatedAt,
          updated <= now else { return false }
    return now.timeIntervalSince(updated) <= slackRuntimeStaleAfter
}()

func readSurfaceErrorFeed(
    _ name: String,
    errorsRel: String,
    receiptsRel: String,
    lineCap: Int? = nil,
    byteCap: Int64? = nil
) {
    var f = SurfaceErrorFeed(name: name, lineCap: lineCap, byteCap: byteCap)
    if let attrs = try? fm.attributesOfItem(atPath: rootPath(errorsRel)) {
        f.errorBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
    f.errorState = organJSONL(errorsRel, rootPath(errorsRel)) { obj in
        f.errorRows += 1
        let ts = ((obj["ts"] as? String) ?? (obj["createdAt"] as? String)
                  ?? (obj["at"] as? String)).flatMap(parseTimestamp)
        if let ts {
            f.errorNewest = newer(f.errorNewest, ts)
            if ts >= windowStart { f.errorRowsInWindow += 1 }
        }
        // A code, never the message: error text can carry chat content.
        let code = (obj["code"] as? String)
            ?? ((obj["code"] as? NSNumber).map { "\($0.intValue)" })
            ?? (obj["errorClass"] as? String)
            ?? (obj["kind"] as? String)
            ?? "(no code/errorClass/kind field)"
        f.codes[code, default: 0] += 1
    }
    f.receiptState = organJSONL(receiptsRel, rootPath(receiptsRel)) { obj in
        f.receiptRows += 1
        if let ts = ((obj["ts"] as? String) ?? (obj["createdAt"] as? String)
                     ?? (obj["at"] as? String)).flatMap(parseTimestamp) {
            f.receiptNewest = newer(f.receiptNewest, ts)
        }
    }
    surfaceErrorFeeds.append(f)
}
// TelegramErrorLog rotates the live file at 5 MiB and keeps one `.1` backup;
// it has no line cap. Slack's JSONL owner uses the shared 5,000-line policy.
readSurfaceErrorFeed("telegram", errorsRel: "telegram/errors.jsonl",
                     receiptsRel: "telegram/receipts.jsonl", byteCap: 5 * 1024 * 1024)
readSurfaceErrorFeed("slack", errorsRel: "slack/errors.jsonl",
                     receiptsRel: "slack/receipts.jsonl", lineCap: 5000)

// ── W3-E: logs/*.txt + errors.jsonl — a second error lane cannot hide ──────
// `logs/` contains both the scheduler's structured failures (read above) and
// general errors plus human-readable reports. The latter were neither bounded
// nor named in a report, so a daemon fossil could grow forever while the loop
// health row still looked clean. Inspect names, sizes and mtimes only for txt
// files; JSONL error rows are parsed only for timestamps and a safe code label.
struct LogTextFile {
    let name: String
    let bytes: Int64
    let modified: Date?
}
let logTextByteCeiling: Int64 = 8 << 20
let logsDirectoryRoot = rootPath("logs")
let logsTextLabel = "logs/*.txt"
let logsTextPresent = sources.register(logsTextLabel, logsDirectoryRoot,
                                       note: "flat *.txt names, sizes and mtimes only; log contents are never opened")
noAutoClaimLabels.insert(logsTextLabel)
var logsTextState: FeedState = .absent
var logTextFiles: [LogTextFile] = []
if logsTextPresent {
    let (entries, state) = organDirectory(logsTextLabel, logsDirectoryRoot)
    logsTextState = state
    if state.didRead {
        for entry in entries.sorted() where entry.hasSuffix(".txt") {
            let path = (logsDirectoryRoot as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            logTextFiles.append(LogTextFile(
                name: entry,
                bytes: Int64((attrs[.size] as? Int64) ?? 0),
                modified: attrs[.modificationDate] as? Date
            ))
            claimFeedFamily(normalizeRelativePath("logs/\(entry)"), by: logsTextLabel)
        }
        sources.setRows(logsTextLabel, logTextFiles.count)
    }
}
var generalErrorRows = 0
var generalErrorsInWindow = 0
var generalErrorNewest: Date?
var generalErrorCodes: [String: Int] = [:]
let generalErrorFeed = organJSONL("logs/errors.jsonl", rootPath("logs/errors.jsonl")) { obj in
    generalErrorRows += 1
    let timestamp = ((obj["ts"] as? String) ?? (obj["createdAt"] as? String)
                     ?? (obj["at"] as? String) ?? (obj["timestamp"] as? String)).flatMap(parseTimestamp)
    if let timestamp {
        generalErrorNewest = newer(generalErrorNewest, timestamp)
        if timestamp >= windowStart { generalErrorsInWindow += 1 }
    }
    let code = (obj["code"] as? String)
        ?? ((obj["code"] as? NSNumber).map { "\($0.intValue)" })
        ?? (obj["errorClass"] as? String)
        ?? (obj["kind"] as? String)
        ?? "(no code/errorClass/kind field)"
    generalErrorCodes[code, default: 0] += 1
}

// ── W3-F: from_codex/ — retained audit envelopes and sidecars ───────────────
// `invoke_codex` emits one JSON audit plus a `-last-message.txt` sidecar. The
// writer retains 100 JSON audits and removes a sidecar only after its matching
// audit has been evicted; this observer checks the data-root half independently
// of SYS-01's ~/.config reply-jobs reader. Never read prompt/reply text here.
struct FromCodexArtifact {
    let name: String
    let bytes: Int64
    let modified: Date?
}
let fromCodexAuditRetention = 100
let fromCodexUnpairedGraceDays = 1.0
let fromCodexRoot = rootPath("from_codex")
let fromCodexLabel = "from_codex/"
let fromCodexPresent = sources.register(fromCodexLabel, fromCodexRoot,
                                        note: "audit and sidecar names, sizes and mtimes only; prompts and replies are never opened")
noAutoClaimLabels.insert(fromCodexLabel)
var fromCodexState: FeedState = .absent
var fromCodexAudits: [String: FromCodexArtifact] = [:]
var fromCodexSidecars: [String: FromCodexArtifact] = [:]
if fromCodexPresent {
    let (entries, state) = organDirectory(fromCodexLabel, fromCodexRoot)
    fromCodexState = state
    if state.didRead {
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = (fromCodexRoot as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let artifact = FromCodexArtifact(
                name: entry,
                bytes: Int64((attrs[.size] as? Int64) ?? 0),
                modified: attrs[.modificationDate] as? Date
            )
            if entry.hasSuffix(".json") {
                let runID = String(entry.dropLast(".json".count))
                fromCodexAudits[runID] = artifact
                claimFeedFamily(normalizeRelativePath("from_codex/\(entry)"), by: fromCodexLabel)
            } else if entry.hasSuffix("-last-message.txt") {
                let runID = String(entry.dropLast("-last-message.txt".count))
                fromCodexSidecars[runID] = artifact
                claimFeedFamily(normalizeRelativePath("from_codex/\(entry)"), by: fromCodexLabel)
            }
        }
        sources.setRows(fromCodexLabel, fromCodexAudits.count + fromCodexSidecars.count)
    }
}
let fromCodexUnpairedSidecars = fromCodexSidecars.filter { fromCodexAudits[$0.key] == nil }
let fromCodexStaleUnpairedSidecars = fromCodexUnpairedSidecars.values.filter {
    ($0.modified.map { daysSince($0) } ?? 0) > fromCodexUnpairedGraceDays
}

// ── W3-G: disabled/ — a shadow tree, never a live lane ─────────────────────
// A disabled snapshot carries near-identical paths to live operational stores.
// It must be listed outside normal feed rollups, otherwise a human (or future
// reader) can pin to the fossil and report its mtime as the live system's.
struct DisabledShadowArtifact {
    let snapshot: String
    let relativePath: String
    let bytes: Int64
    let modified: Date?
    let shadowsLivePath: Bool
}
let disabledShadowRoot = rootPath("disabled")
let disabledShadowLabel = "disabled/"
let disabledShadowPresent = sources.register(disabledShadowLabel, disabledShadowRoot,
                                             note: "snapshot names and file metadata only; disabled contents are never opened")
noAutoClaimLabels.insert(disabledShadowLabel)
var disabledShadowState: FeedState = .absent
var disabledShadowArtifacts: [DisabledShadowArtifact] = []
var disabledShadowEnumerationError: String?
if disabledShadowPresent {
    let (snapshots, state) = organDirectory(disabledShadowLabel, disabledShadowRoot)
    disabledShadowState = state
    if state.didRead {
        for snapshot in snapshots.sorted() where !snapshot.hasPrefix(".") {
            let snapshotURL = URL(fileURLWithPath: disabledShadowRoot).appendingPathComponent(snapshot, isDirectory: true)
            let snapshotBasePath = snapshotURL.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: snapshotURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let enumerator = fm.enumerator(
                at: snapshotURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    disabledShadowEnumerationError = "could not enumerate \(url.lastPathComponent): \(error.localizedDescription)"
                    return false
                }
            ) else {
                disabledShadowEnumerationError = "could not enumerate snapshot \(snapshot)"
                break
            }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let canonicalFilePath = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonicalFilePath.hasPrefix(snapshotBasePath + "/") else { continue }
                let relative = String(canonicalFilePath.dropFirst(snapshotBasePath.count + 1))
                let livePath = rootPath(relative)
                disabledShadowArtifacts.append(DisabledShadowArtifact(
                    snapshot: snapshot,
                    relativePath: relative,
                    bytes: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate,
                    shadowsLivePath: fm.fileExists(atPath: livePath)
                ))
            }
            if disabledShadowEnumerationError != nil { break }
        }
        if let disabledShadowEnumerationError {
            markFeedUnreadable(disabledShadowLabel, disabledShadowEnumerationError)
            disabledShadowState = .unreadable(disabledShadowEnumerationError)
            disabledShadowArtifacts.removeAll()
        } else {
            sources.setRows(disabledShadowLabel, disabledShadowArtifacts.count)
        }
    }
}

// ── W3-H: telegram offset + update_inbox drain ──────────────────────────────
// A `last_offset.json` that rolls BACKWARDS re-delivers every update; one that
// jumps forward drops messages permanently. Neither is observable from turn
// counts. A single read-only run cannot prove monotonicity across runs — what it
// CAN prove is that the offset is a non-negative integer that exists and is
// fresh, and that `update_inbox/` DRAINS. Both failures are silent today.
var telegramOffset: Int?
var telegramOffsetRaw: String?
var telegramOffsetModified: Date?
let (telegramOffsetObj, telegramOffsetFeed) = organJSONObject("telegram/last_offset.json",
                                                              rootPath("telegram/last_offset.json"))
if let telegramOffsetObj {
    if let n = (telegramOffsetObj["offset"] as? NSNumber) ?? (telegramOffsetObj["last_offset"] as? NSNumber) {
        telegramOffset = n.intValue
    } else {
        telegramOffsetRaw = "(no numeric `offset`/`last_offset` key; keys: \(telegramOffsetObj.keys.sorted().prefix(6).joined(separator: ", ")))"
    }
    telegramOffsetModified = (try? fm.attributesOfItem(atPath: rootPath("telegram/last_offset.json")))?[.modificationDate] as? Date
}
var telegramInboxClaimFiles = 0
var telegramInboxLockFiles = 0
var telegramInboxPending = 0
var telegramInboxProcessing = 0
var telegramInboxCompleted = 0
var telegramInboxOutcomeUnknown = 0
var telegramInboxOtherPhases = 0
var telegramInboxWorkOldest: Date?
let telegramInboxRoot = rootPath("telegram/update_inbox")
let telegramInboxLabel = "telegram/update_inbox/"
let telegramInboxPresent = sources.register(telegramInboxLabel, telegramInboxRoot,
                                            note: "claim/lock metadata plus claims_index phase counts; "
                                                + "retained update payload files are never opened")
noAutoClaimLabels.insert(telegramInboxLabel)
var telegramInboxState: FeedState = .absent
if telegramInboxPresent {
    let (entries, state) = organDirectory(telegramInboxLabel, telegramInboxRoot)
    telegramInboxState = state
    if state.didRead {
        for f in entries where !f.hasPrefix(".") {
            if f.hasSuffix(".json.lock") { telegramInboxLockFiles += 1 }
            if f.hasSuffix(".json"), f != "claims_index.json",
               Int(String(f.dropLast(".json".count))) != nil {
                telegramInboxClaimFiles += 1
            }
            claimFeedFamily(normalizeRelativePath("telegram/update_inbox/\(f)"), by: telegramInboxLabel)
        }
        sources.setRows(telegramInboxLabel, telegramInboxClaimFiles)
    }
}
let telegramInboxIndexPath = rootPath("telegram/update_inbox/claims_index.json")
let (telegramInboxIndexObj, telegramInboxIndexFeed) = organJSONObject(
    "telegram/update_inbox/claims_index.json", telegramInboxIndexPath,
    note: "phase/index metadata only; retained Telegram update payloads are never opened"
)
if let telegramInboxIndexObj,
   let entries = telegramInboxIndexObj["entries"] as? [String: Any] {
    var validEntries = 0
    for (rawID, value) in entries {
        guard let id = Int(rawID),
              let entry = value as? [String: Any],
              (entry["updateId"] as? NSNumber)?.intValue == id,
              let phase = entry["phase"] as? String else {
            telegramInboxOtherPhases += 1
            continue
        }
        validEntries += 1
        switch phase {
        case "pending": telegramInboxPending += 1
        case "processing": telegramInboxProcessing += 1
        case "completed": telegramInboxCompleted += 1
        case "outcome_unknown": telegramInboxOutcomeUnknown += 1
        default: telegramInboxOtherPhases += 1
        }
        if phase == "pending" || phase == "processing" {
            let claimPath = (telegramInboxRoot as NSString).appendingPathComponent("\(id).json")
            if let modified = (try? fm.attributesOfItem(atPath: claimPath))?[.modificationDate] as? Date,
               telegramInboxWorkOldest == nil || modified < telegramInboxWorkOldest! {
                telegramInboxWorkOldest = modified
            }
        }
    }
    sources.setRows("telegram/update_inbox/claims_index.json", validEntries)
}
/// A drained inbox holds only what arrived recently. Anything older than this is
/// a message the loop took in and never finished with.
let telegramInboxDrainAgeDays = 1.0
let telegramInboxTerminalRetention = 256

// ── W3-F: doctor/latest.json — what self-healing believes ───────────────────
// `SelfHealingHook.swift:213` reads "healthy = no check has status fail" from
// this file. A doctor run that crashes before writing leaves the PREVIOUS
// healthy verdict in place and self-healing keeps believing it. Freshness is
// therefore the whole check; the statuses are secondary.
var doctorChecks: [String: String] = [:]
var doctorFailing: [String] = []
var doctorModified: Date?
var doctorGeneratedAt: Date?
let doctorPath = rootPath("doctor/latest.json")
let (doctorObj, doctorFeed) = organJSONObject("doctor/latest.json", doctorPath)
if let doctorObj {
    doctorModified = (try? fm.attributesOfItem(atPath: doctorPath))?[.modificationDate] as? Date
    doctorGeneratedAt = ((doctorObj["generatedAt"] as? String) ?? (doctorObj["ranAt"] as? String)
                         ?? (doctorObj["at"] as? String)).flatMap(parseTimestamp)
    let rawChecks = (doctorObj["checks"] as? [Any]) ?? []
    for c in rawChecks {
        guard let o = c as? [String: Any] else { continue }
        let name = (o["id"] as? String) ?? (o["name"] as? String) ?? "(unnamed check)"
        let status = (o["status"] as? String) ?? "(no status field)"
        doctorChecks[name] = status
        if status.lowercased() == "fail" { doctorFailing.append(name) }
    }
    sources.setRows("doctor/latest.json", doctorChecks.count)
}
/// Self-healing acts on this file every day; a verdict older than this is a
/// verdict about a system that no longer exists.
let doctorStaleAgeDays = 2.0

// ── W3-G: oauth_tokens/ — SHAPE ONLY ────────────────────────────────────────
//
// SECRET DISCIPLINE, same boundary as `providerSafeKeys` above and for the same
// reason: this instrument prints its evidence into a markdown file. These files
// hold live OAuth access and refresh tokens. The reader is allowed to look at
// exactly two keys, and NOTHING else from those objects reaches a variable —
// not a value, not a count keyed by value, not a prefix.
//
// Treat this list as a security boundary, not a convenience. There is a
// mutation test that widens it and proves the report then leaks.
let oauthSafeKeys: Set<String> = ["expires_at", "scope"]
struct OAuthTokenFile {
    var id: String
    var parsed: Bool
    var keyCount: Int
    var modified: Date?
    var expiresAt: String?
    var scope: String?
}
var oauthTokenFiles: [OAuthTokenFile] = []
var oauthUnparseable = 0
let oauthRoot = rootPath("oauth_tokens")
let oauthLabel = "oauth_tokens/"
let oauthPresent = sources.register(oauthLabel, oauthRoot,
                                    note: "SHAPE ONLY — presence, mtime, key COUNT, and the two "
                                        + "allowlisted keys `expires_at`/`scope`; no token material")
noAutoClaimLabels.insert(oauthLabel)
var oauthState: FeedState = .absent
if oauthPresent {
    let (entries, state) = organDirectory(oauthLabel, oauthRoot)
    oauthState = state
    if state.didRead {
        for entry in entries where entry.hasSuffix(".json") {
            let id = String(entry.dropLast(".json".count))
            let full = (oauthRoot as NSString).appendingPathComponent(entry)
            claimFeedFamily(normalizeRelativePath("oauth_tokens/\(entry)"), by: oauthLabel)
            let modified = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
            guard let data = fm.contents(atPath: full),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                oauthUnparseable += 1
                oauthTokenFiles.append(OAuthTokenFile(id: id, parsed: false, keyCount: 0,
                                                      modified: modified, expiresAt: nil, scope: nil))
                continue
            }
            // ONLY the two allowlisted keys are copied out of this object.
            let expires: String? = oauthSafeKeys.contains("expires_at")
                ? ((obj["expires_at"] as? String)
                   ?? (obj["expires_at"] as? NSNumber).map { "\($0.intValue)" })
                : nil
            let scope: String? = oauthSafeKeys.contains("scope") ? (obj["scope"] as? String) : nil
            oauthTokenFiles.append(OAuthTokenFile(id: id, parsed: true, keyCount: obj.count,
                                                  modified: modified,
                                                  expiresAt: expires, scope: scope))
        }
        sources.setRows(oauthLabel, oauthTokenFiles.count)
        _ = condemnUnparseableFamily(oauthLabel, total: oauthTokenFiles.count, unparseable: oauthUnparseable)
    }
}
func oauthExpiryDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let epoch = Double(trimmed), epoch.isFinite, epoch > 0 {
        return Date(timeIntervalSince1970: epoch)
    }
    return parseTimestamp(trimmed)
}

// ── W3-H: mac_control/operations.json vs the dispatch trace ─────────────────
// The operation store is 231 KB of ONE JSON object with no rotation, and the
// `mac.*` failure leads in this report come from `traces/events.jsonl`, NOT from
// here. A divergence between what dispatch recorded and what the operation store
// recorded is therefore undetectable — which is what this compares.
var macOperationCount = 0
var macOperationsInWindow = 0
var macOperationsInRuntimeEvidence = 0
var macOperationStatuses: [String: Int] = [:]
var macOperationNewest: Date?
var macOperationBytes: Int64 = 0
let macOperationsPath = rootPath("mac_control/operations.json")
macOperationBytes = Int64(((try? fm.attributesOfItem(atPath: macOperationsPath))?[.size] as? Int64) ?? 0)
let (macOperationsObj, macOperationsFeed) = organJSONObject("mac_control/operations.json", macOperationsPath)
if let macOperationsObj {
    // The store is a single object; the operations live under whichever key
    // holds an array. Anything else is reported as shape, never guessed at.
    var rows: [[String: Any]] = []
    for (_, v) in macOperationsObj.sorted(by: { $0.key < $1.key }) {
        if let arr = v as? [Any] { rows += arr.compactMap { $0 as? [String: Any] } }
        if let obj = v as? [String: Any] {
            rows += obj.values.compactMap { $0 as? [String: Any] }
        }
    }
    macOperationCount = rows.count
    for r in rows {
        macOperationStatuses[
            (r["status"] as? String) ?? (r["state"] as? String)
                ?? (r["outcomeCode"] as? String) ?? "(no status field)",
            default: 0
        ] += 1
        if let ts = ((r["terminalAt"] as? String) ?? (r["updatedAt"] as? String)
                     ?? (r["startedAt"] as? String) ?? (r["acceptedAt"] as? String)
                     ?? (r["createdAt"] as? String) ?? (r["at"] as? String)).flatMap(parseTimestamp) {
            macOperationNewest = newer(macOperationNewest, ts)
            if ts >= windowStart { macOperationsInWindow += 1 }
            if ts >= runtimeEvidenceStart { macOperationsInRuntimeEvidence += 1 }
        }
    }
    sources.setRows("mac_control/operations.json", macOperationCount)
}
/// `mac.*` dispatches counted from the trace, for the divergence comparison.
let macToolDispatchInWindow = toolStats
    .filter { $0.key.hasPrefix("mac") }
    .reduce(0) { $0 + $1.value.ok + $1.value.failed + $1.value.otherStatus.values.reduce(0, +) }
/// A single-object store with no rotation. Named bound, so the growth is a
/// finding rather than a surprise at the 1 GB tripwire.
let macOperationsByteCeiling: Int64 = 512 << 10

// ── W3-I: Mac-control bridge + browser IPC discovery descriptors ────────────
// These are local loopback discovery records, not configuration. They include
// bearer material, so this reader validates only their public shape and token
// *presence*. It never renders or opens the browser token file, and never
// probes a port: a frozen data root must remain a read-only observation.
func localDiscoveryPort(_ value: Any?) -> Int? {
    let port: Int?
    if let number = value as? NSNumber { port = number.intValue }
    else if let text = value as? String { port = Int(text) }
    else { port = nil }
    guard let port, (1...65_535).contains(port) else { return nil }
    return port
}

let macctlBridgeDescriptorLabel = "macctl_bridge.json"
let browserIPCDescriptorLabel = "browser_ipc.json"
let browserIPCTokenLabel = "browser_ipc_token"
let macctlBridgeDescriptorPath = rootPath(macctlBridgeDescriptorLabel)
let browserIPCDescriptorPath = rootPath(browserIPCDescriptorLabel)
let browserIPCTokenPath = rootPath(browserIPCTokenLabel)

var macctlBridgePort: Int?
var macctlBridgeWrittenAt: Date?
var macctlBridgeBearerPresent = false
let (macctlBridgeDescriptor, macctlBridgeFeed) = organJSONObject(
    macctlBridgeDescriptorLabel, macctlBridgeDescriptorPath,
    note: "read-only loopback discovery shape; bearer value is never rendered"
)
if let descriptor = macctlBridgeDescriptor {
    macctlBridgePort = localDiscoveryPort(descriptor["port"])
    macctlBridgeWrittenAt = (descriptor["writtenAt"] as? String).flatMap(parseTimestamp)
    macctlBridgeBearerPresent = !((descriptor["token"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if macctlBridgePort == nil || macctlBridgeWrittenAt == nil || !macctlBridgeBearerPresent {
        markFeedUnreadable(macctlBridgeDescriptorLabel,
                           "descriptor lacks a bounded port, writtenAt timestamp, or bearer presence")
        // Keep the invalid descriptor visible as damage; no partial numeric
        // value is rendered below.
        macctlBridgePort = nil
        macctlBridgeWrittenAt = nil
        macctlBridgeBearerPresent = false
    } else {
        sources.setRows(macctlBridgeDescriptorLabel, 1)
    }
}

var browserIPCPort: Int?
var browserIPCWrittenAt: Date?
var browserIPCBearerPresent = false
var browserIPCLoopback = false
var browserIPCURLMatches = false
let (browserIPCDescriptor, browserIPCFeed) = organJSONObject(
    browserIPCDescriptorLabel, browserIPCDescriptorPath,
    note: "read-only loopback discovery shape; bearer value is never rendered"
)
if let descriptor = browserIPCDescriptor {
    browserIPCPort = localDiscoveryPort(descriptor["port"])
    browserIPCWrittenAt = (descriptor["writtenAt"] as? String).flatMap(parseTimestamp)
    browserIPCBearerPresent = !((descriptor["token"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    browserIPCLoopback = (descriptor["host"] as? String) == "127.0.0.1"
    if let port = browserIPCPort {
        browserIPCURLMatches = (descriptor["url"] as? String) == "http://127.0.0.1:\(port)"
    }
    if browserIPCPort == nil || browserIPCWrittenAt == nil || !browserIPCBearerPresent || !browserIPCLoopback || !browserIPCURLMatches {
        markFeedUnreadable(browserIPCDescriptorLabel,
                           "descriptor must name matching loopback URL/host, bounded port, writtenAt, and bearer presence")
        browserIPCPort = nil
        browserIPCWrittenAt = nil
        browserIPCBearerPresent = false
        browserIPCLoopback = false
        browserIPCURLMatches = false
    } else {
        sources.setRows(browserIPCDescriptorLabel, 1)
    }
}

var browserIPCTokenBytes: Int64?
var browserIPCTokenPrivate: Bool?
let browserIPCTokenPresent = sources.register(
    browserIPCTokenLabel, browserIPCTokenPath,
    note: "metadata-only browser IPC bearer file; contents are never opened"
)
if browserIPCTokenPresent {
    var isDirectory = ObjCBool(false)
    if !fm.fileExists(atPath: browserIPCTokenPath, isDirectory: &isDirectory) || isDirectory.boolValue {
        markFeedUnreadable(browserIPCTokenLabel, "bearer path is not a regular file")
    } else if let attributes = try? fm.attributesOfItem(atPath: browserIPCTokenPath),
              let size = attributes[.size] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber {
        browserIPCTokenBytes = size.int64Value
        browserIPCTokenPrivate = permissions.intValue & 0o077 == 0
        if browserIPCTokenBytes == 0 || browserIPCTokenPrivate != true {
            markFeedUnreadable(browserIPCTokenLabel,
                               browserIPCTokenBytes == 0 ? "bearer file is empty" : "bearer file is group/world-readable")
            browserIPCTokenBytes = nil
            browserIPCTokenPrivate = nil
        } else {
            sources.setRows(browserIPCTokenLabel, 1)
        }
    } else {
        markFeedUnreadable(browserIPCTokenLabel, "bearer file metadata could not be read")
    }
}

// ── W3-J: research connector configuration, lab runs, and call receipts ────
//
// Research has three persisted authorities with deliberately different
// meanings. A non-empty `searxng_base_url` says the connector is configured;
// it does NOT claim the endpoint is reachable. `lab/runs.json` says whether a
// research-lab pass was actually attempted and what it reported. The direct
// search/fetch receipt family is separate evidence of connector calls. Reading
// only one of these used to make a dark research lane indistinguishable from
// an unused one, so each is registered and gated independently below.
let researchConfigLabel = "research/config.json"
let researchLabRunsLabel = "research/lab/runs.json"
let researchReceiptsLabel = "research/receipt-files/"
let researchConfigPath = rootPath("research/config.json")
let researchLabRunsPath = rootPath("research/lab/runs.json")
let researchRootPath = rootPath("research")

var researchConfigured: Bool?
var researchLabRunsCount: Int?
var researchLabNewest: Date?
var researchLabStatusCounts: [String: Int] = [:]
var researchReceiptCount: Int?
var researchReceiptNewest: Date?

let (researchConfigObj, researchConfigFeed) = organJSONObject(
    researchConfigLabel, researchConfigPath,
    note: "read-only research connector configuration; only configuration presence is reported")
if researchConfigFeed.didRead, let config = researchConfigObj {
    if let base = config["searxng_base_url"] as? String {
        // Do not render an endpoint from this operational config into the
        // report. Presence is enough to answer the observability question.
        researchConfigured = !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sources.setRows(researchConfigLabel, 1)
    } else if config["searxng_base_url"] == nil || config["searxng_base_url"] is NSNull {
        researchConfigured = false
        sources.setRows(researchConfigLabel, 1)
    } else {
        let reason = "`searxng_base_url` is present but not a string"
        markFeedUnreadable(researchConfigLabel, reason)
    }
}

let (researchLabRaw, researchLabRunsFeed) = organJSON(
    researchLabRunsLabel, researchLabRunsPath,
    note: "read-only persisted ResearchLabRun array")
if researchLabRunsFeed.didRead {
    if (researchLabRaw as? [Any]) == nil {
        let reason = "present but top level is not a ResearchLabRun array"
        markFeedUnreadable(researchLabRunsLabel, reason)
    }
    if let rows = researchLabRaw as? [Any] {
        var parsedNewest: Date?
        var parsedStatuses: [String: Int] = [:]
        var shapeError: String?
        for (index, raw) in rows.enumerated() {
            guard let run = raw as? [String: Any] else {
                shapeError = "run #\(index + 1) is not a JSON object"
                break
            }
            guard let createdAt = run["createdAt"] as? String,
                  let created = parseTimestamp(createdAt) else {
                shapeError = "run #\(index + 1) has no parseable `createdAt`"
                break
            }
            guard let status = run["status"] as? String,
                  !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                shapeError = "run #\(index + 1) has no non-empty `status`"
                break
            }
            parsedNewest = newer(parsedNewest, created)
            parsedStatuses[status, default: 0] += 1
        }
        if let shapeError {
            markFeedUnreadable(researchLabRunsLabel, shapeError)
        } else {
            researchLabRunsCount = rows.count
            researchLabNewest = parsedNewest
            researchLabStatusCounts = parsedStatuses
            sources.setRows(researchLabRunsLabel, rows.count)
        }
    }
}

// `research/` also holds config.json and lab/. Claim only the receipt-shaped
// direct children that this reader opens; letting a directory presence check
// claim its whole subtree would hide a future unmeasured research producer.
let researchReceiptsRegistered = sources.register(
    researchReceiptsLabel, researchRootPath,
    note: "read-only direct search/fetch receipts (`<uuid>.json` and `source-<id>.json`)")
noAutoClaimLabels.insert(researchReceiptsLabel)
if researchReceiptsRegistered {
    let listing = organDirectory(researchReceiptsLabel, researchRootPath)
    switch listing.state {
    case .unreadable:
        break // `organDirectory` already registered the unreadable source fact.
    case .absent:
        // The path exists (register above said so) but is not a directory.
        let reason = "present but is not a research receipt directory"
        markFeedUnreadable(researchReceiptsLabel, reason)
    case .read:
        var count = 0
        var newest: Date?
        var receiptError: String?
        for entry in listing.entries where entry.hasSuffix(".json") {
            let stem = String(entry.dropLast(".json".count))
            let isReceipt = stem.hasPrefix("source-") || UUID(uuidString: stem) != nil
            guard isReceipt else { continue }
            let path = (researchRootPath as NSString).appendingPathComponent(entry)
            claimFeedFamily(normalizeRelativePath("research/\(entry)"), by: researchReceiptsLabel)
            guard let data = fm.contents(atPath: path),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  parsed is [String: Any] else {
                receiptError = "receipt `\(entry)` could not be read as a JSON object"
                break
            }
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
                receiptError = "receipt `\(entry)` has no readable modification time"
                break
            }
            count += 1
            newest = newer(newest, modified)
        }
        if let receiptError {
            markFeedUnreadable(researchReceiptsLabel, receiptError)
        } else {
            researchReceiptCount = count
            researchReceiptNewest = newest
            sources.setRows(researchReceiptsLabel, count)
        }
    }
}

// ── W3-J: Browser operation store and derived-receipt projection ───────────
//
// Browser's canonical run store is bounded. A full store, a process-local
// `running` row that survived a restart, and a transition whose projection
// remains queued are different recovery cases. Read the canonical writer's
// two public stores separately: runs are the authority for capacity/state/
// outbox; receipts only establish the newest retained derived receipt.
let browserRunsLabel = "native_power/browser/runs.json"
let browserReceiptsLabel = "native_power/browser/receipts.jsonl"
let browserRunsPath = rootPath(browserRunsLabel)
let browserReceiptsPath = rootPath(browserReceiptsLabel)
let browserRunRetentionCeiling = 200
let browserStaleRunningHours = 1.0
let browserStaleProjectionHours = 1.0

var browserRunCount: Int?
var browserRunStatusCounts: [String: Int] = [:]
var browserStaleRunning: [(id: String, createdAt: Date)] = []
var browserStaleProjectionRuns: [(id: String, pendingAt: Date, entries: Int)] = []
var browserPendingProjectionEntries = 0
var browserLatestReceipt: Date?

var browserRunsFeed: FeedState = .absent
let (browserRunsRaw, initialBrowserRunsFeed) = organJSON(
    browserRunsLabel, browserRunsPath,
    note: "read-only BrowserOperationStore canonical runs (capacity, state, projection outbox)")
browserRunsFeed = initialBrowserRunsFeed
if initialBrowserRunsFeed.didRead {
    if let rows = browserRunsRaw as? [Any] {
        var parsedStatuses: [String: Int] = [:]
        var parsedStaleRunning: [(id: String, createdAt: Date)] = []
        var parsedStaleProjections: [(id: String, pendingAt: Date, entries: Int)] = []
        var parsedPendingEntries = 0
        var shapeError: String?
        for (index, raw) in rows.enumerated() {
            guard let run = raw as? [String: Any] else {
                shapeError = "run #\(index + 1) is not a JSON object"
                break
            }
            guard let status = run["status"] as? String,
                  !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                shapeError = "run #\(index + 1) has no non-empty `status`"
                break
            }
            guard let createdRaw = run["createdAt"] as? String,
                  let createdAt = parseTimestamp(createdRaw) else {
                shapeError = "run #\(index + 1) has no parseable `createdAt`"
                break
            }
            let rawID = (run["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayID = rawID?.isEmpty == false ? rawID! : "run-#\(index + 1)"
            parsedStatuses[status, default: 0] += 1
            if status == "running", hoursSince(createdAt) > browserStaleRunningHours {
                parsedStaleRunning.append((id: displayID, createdAt: createdAt))
            }
            if let rawOutbox = run["projectionOutbox"] {
                guard let outbox = rawOutbox as? [Any] else {
                    shapeError = "run #\(index + 1) has a non-array `projectionOutbox`"
                    break
                }
                if !outbox.isEmpty {
                    for (outboxIndex, rawEntry) in outbox.enumerated() {
                        guard let entry = rawEntry as? [String: Any],
                              let projectionID = entry["id"] as? String,
                              !projectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              entry["run"] as? [String: Any] != nil else {
                            shapeError = "run #\(index + 1) has malformed projection outbox entry #\(outboxIndex + 1)"
                            break
                        }
                    }
                    if shapeError != nil { break }
                    // Production transitions refresh `updatedAt` before
                    // staging. Older compatible rows have only `createdAt`.
                    let pendingAt: Date
                    if let updatedRaw = run["updatedAt"] as? String {
                        guard let updatedAt = parseTimestamp(updatedRaw) else {
                            shapeError = "run #\(index + 1) has an unparseable `updatedAt` for a pending projection"
                            break
                        }
                        pendingAt = updatedAt
                    } else {
                        pendingAt = createdAt
                    }
                    parsedPendingEntries += outbox.count
                    if hoursSince(pendingAt) > browserStaleProjectionHours {
                        parsedStaleProjections.append((id: displayID, pendingAt: pendingAt, entries: outbox.count))
                    }
                }
            }
        }
        if let shapeError {
            markFeedUnreadable(browserRunsLabel, shapeError)
            browserRunsFeed = .unreadable(shapeError)
        } else {
            browserRunCount = rows.count
            browserRunStatusCounts = parsedStatuses
            browserStaleRunning = parsedStaleRunning
            browserStaleProjectionRuns = parsedStaleProjections
            browserPendingProjectionEntries = parsedPendingEntries
            sources.setRows(browserRunsLabel, rows.count)
        }
    } else {
        let reason = "present but top level is not a BrowserOperationStore run array"
        markFeedUnreadable(browserRunsLabel, reason)
        browserRunsFeed = .unreadable(reason)
    }
}

var browserReceiptsFeed: FeedState = .absent
var browserReceiptShapeError: String?
browserReceiptsFeed = organJSONL(
    browserReceiptsLabel, browserReceiptsPath,
    note: "read-only BrowserOperationStore derived receipt stream") { receipt in
        guard let createdRaw = receipt["createdAt"] as? String,
              let createdAt = parseTimestamp(createdRaw) else {
            browserReceiptShapeError = "a receipt has no parseable `createdAt`"
            return
        }
        browserLatestReceipt = newer(browserLatestReceipt, createdAt)
    }
if browserReceiptsFeed.didRead, let browserReceiptShapeError {
    markFeedUnreadable(browserReceiptsLabel, browserReceiptShapeError)
    browserReceiptsFeed = .unreadable(browserReceiptShapeError)
    browserLatestReceipt = nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Self-auditing reach walker
//
// Walks the ENTIRE data root and inventories every file, aggregating instance-
// named siblings into one "feed" (turn_traces/2026-08-20.jsonl and its 27
// siblings collapse to `turn_traces/*.jsonl`). Any feed no reader above has
// claimed is reported as NOT COVERED with path, size, row estimate and mtime.
//
// This is the property that makes the instrument expand with the system: a new
// subsystem that starts writing under the data root shows up as a named blind
// spot on its first run, without anyone editing this file.
// ─────────────────────────────────────────────────────────────────────────────

/// True when a path component is an *instance* name (a date, a UUID, a
/// timestamped backup) rather than a stable subsystem name.
func isInstanceComponent(_ s: String) -> Bool {
    if s.isEmpty { return false }
    let chars = Array(s)
    // A run of 8+ digits (20260724T161507Z, 1787315255) — an id or a stamp.
    var run = 0
    for c in chars {
        if c.isNumber { run += 1; if run >= 8 { return true } } else { run = 0 }
    }
    // ISO date prefix: 2026-08-20…
    if chars.count >= 10, chars[0..<4].allSatisfy({ $0.isNumber }), chars[4] == "-",
       chars[5].isNumber, chars[6].isNumber, chars[7] == "-",
       chars[8].isNumber, chars[9].isNumber { return true }
    // UUID: 8-4-4-4-12 hex.
    if chars.count == 36 {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        var ok = true
        for (i, c) in chars.enumerated() {
            if [8, 13, 18, 23].contains(i) { if c != "-" { ok = false; break } }
            else if c.unicodeScalars.allSatisfy({ hex.contains($0) }) == false { ok = false; break }
        }
        if ok { return true }
    }
    // Long bare hex blob (content-addressed names).
    if chars.count >= 24, chars.allSatisfy({ $0.isHexDigit }) { return true }
    // A dash/underscore-separated token that is a long hex id: `drive-2DEDE43E`.
    // Requiring a digit keeps ordinary words (all of a–f) from matching.
    for token in s.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == ":" }) {
        if token.count >= 8, token.allSatisfy({ $0.isHexDigit }), token.contains(where: { $0.isNumber }) {
            return true
        }
    }
    return false
}

func normalizeRelativePath(_ rel: String) -> String {
    var comps = (rel as NSString).pathComponents
    guard let last = comps.popLast() else { return rel }
    var out = comps.map { isInstanceComponent($0) ? "*" : $0 }
    // Normalize EVERY dot-separated segment of the basename, not just the stem.
    // The instance token lives wherever the producer put it:
    //   <uuid>.jsonl.lock                              → *.jsonl.lock
    //   messages.compact.20260819-185056.06d75ae4.jsonl → messages.compact.*.jsonl
    // Splitting on one dot only is what turns a single feed into 900 "blind spots".
    var segs = last.split(separator: ".", omittingEmptySubsequences: false)
        .map { isInstanceComponent(String($0)) ? "*" : String($0) }
    var segsCollapsed: [String] = []
    for s in segs where !(s == "*" && segsCollapsed.last == "*") { segsCollapsed.append(s) }
    segs = segsCollapsed
    out.append(segs.joined(separator: "."))
    // Collapse runs of `*` directories so chat/<uuid>/<uuid>/x.json stays one feed.
    var collapsed: [String] = []
    for c in out {
        if c == "*" && collapsed.last == "*" { continue }
        collapsed.append(c)
    }
    return collapsed.joined(separator: "/")
}

struct Feed {
    var key: String
    var files = 0
    var bytes: Int64 = 0
    var newest: Date?
    var oldest: Date?
    var sampleAbsolutePath = ""
    var covered = false
    var coveredBy: [String] = []
    var rowEstimate: String = "—"
}

var feeds: [String: Feed] = [:]
var walkFilesSeen = 0
var walkBytesSeen: Int64 = 0
var walkSkippedSymlinks = 0

// The enumerator hands back symlink-RESOLVED paths (`/private/var/...`) while
// `standardizingPath` leaves `/var/...` alone, so a prefix test against the
// resolved root alone silently matches nothing and the walk reports zero files.
// Accept every spelling of the root (see `realPathOf` up top for why only
// realpath(3) tells the truth here), and prove the walk ran below.
let walkPrefixes: [String] = Array(dataRootSpellings)
func relativeInDataRoot(_ abs: String) -> String? {
    for p in walkPrefixes where abs.hasPrefix(p + "/") { return String(abs.dropFirst(p.count + 1)) }
    return nil
}

// Reader claims, expressed as normalized keys / directory prefixes.
var coveredFileKeys: [String: String] = [:]      // normalized key → reader label
var coveredDirPrefixes: [String: String] = [:]   // relative dir (no trailing /) → reader label
for e in sources.entries {
    // Only sources inside the data root participate in the walk's coverage map.
    let abs = (e.path as NSString).standardizingPath
    guard let rel = relativeInDataRoot(abs) else { continue }
    guard !noAutoClaimLabels.contains(e.label) else { continue }
    var isD: ObjCBool = false
    if fm.fileExists(atPath: abs, isDirectory: &isD), isD.boolValue {
        coveredDirPrefixes[rel] = e.label
    } else if e.label.hasSuffix("/") {
        coveredDirPrefixes[rel] = e.label          // registered as a dir but absent on disk
    } else {
        coveredFileKeys[normalizeRelativePath(rel)] = e.label
    }
}
// NOTE on lock sidecars: `uniform_file_locking` puts a zero-payload
// `<feed>.lock` beside every append feed, and every sqlite store carries
// `-wal`/`-shm`. Those are NOT claimed here — the walk itself falls back to the
// stripped-suffix key below (see `lookupKeys`), so a sidecar inherits its
// feed's reader automatically. Claiming them a second time here would be
// duplicate bookkeeping that silently masks a sidecar whose base feed nobody
// reads.

// Family claims from readers that enumerate instance-named siblings themselves
// (every `executions/<id>/execution.json`, every `*.claim`). These cannot come
// from a single registered path, because the path IS the family.
for (key, label) in extraFeedClaims where coveredFileKeys[key] == nil {
    coveredFileKeys[key] = label
}

// Walk failures are counted, named and — when total — fatal. A broken or empty
// walk used to render a full report and exit 0, which reads as "we looked
// everywhere and found nothing to worry about". It is the opposite.
var walkEnumeratorFailed = false
var walkEntryErrors = 0
var walkFirstEntryError: String?
var walkUnattributedEntries = 0        // outside every spelling of the root
var walkEntriesVisited = 0

if let en = fm.enumerator(at: URL(fileURLWithPath: resolvedDataRoot),
                          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                       .fileSizeKey, .contentModificationDateKey],
                          options: [],
                          errorHandler: { url, error in
                              walkEntryErrors += 1
                              if walkFirstEntryError == nil {
                                  walkFirstEntryError = "\(url.path): \(error.localizedDescription)"
                              }
                              return true      // keep walking; the count is reported
                          }) {
    for case let url as URL in en {
        walkEntriesVisited += 1
        let vals: URLResourceValues
        do {
            vals = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                    .fileSizeKey, .contentModificationDateKey])
        } catch {
            walkEntryErrors += 1
            if walkFirstEntryError == nil {
                walkFirstEntryError = "\(url.path): \(error.localizedDescription)"
            }
            continue
        }
        if vals.isSymbolicLink == true { walkSkippedSymlinks += 1; en.skipDescendants(); continue }
        guard vals.isRegularFile == true else { continue }
        let abs = url.path
        guard let rel = relativeInDataRoot(abs) else { walkUnattributedEntries += 1; continue }
        let size = Int64(vals.fileSize ?? 0)
        walkFilesSeen += 1
        walkBytesSeen += size
        let key = normalizeRelativePath(rel)
        var f = feeds[key] ?? Feed(key: key)
        f.files += 1
        f.bytes += size
        if f.sampleAbsolutePath.isEmpty || size > 0 { f.sampleAbsolutePath = abs }
        if let m = vals.contentModificationDate {
            if f.newest == nil || m > f.newest! { f.newest = m }
            if f.oldest == nil || m < f.oldest! { f.oldest = m }
        }
        if !f.covered {
            // A store's sidecars (`-wal`, `-shm`, `.lock`) inherit the store's
            // coverage — they are the same feed, not a new subsystem.
            var lookupKeys = [key]
            for suffix in ["-wal", "-shm", ".lock"] where key.hasSuffix(suffix) {
                lookupKeys.append(String(key.dropLast(suffix.count)))
            }
            if let label = lookupKeys.compactMap({ coveredFileKeys[$0] }).first {
                f.covered = true
                f.coveredBy = [label]
            } else {
                for (prefix, label) in coveredDirPrefixes where rel == prefix || rel.hasPrefix(prefix + "/") {
                    f.covered = true
                    f.coveredBy = [label]
                    break
                }
            }
        }
        feeds[key] = f
    }
} else {
    walkEnumeratorFailed = true
}

/// THE WALK VERDICT. A nil enumerator, or a walk that enumerated no file at
/// all, means the coverage answer is vacuous — and a vacuous coverage answer
/// rendered at exit 0 is indistinguishable from a clean bill of health.
let reachWalkFailed = walkEnumeratorFailed || walkFilesSeen == 0

// Row estimates — only for feeds nobody reads (the covered ones already report
// real counts in the Sources table) and only within cost bounds we can state.
let exactLineCountCap: Int64 = 8 << 20          // 8 MB per feed: exact newline count
let sqliteCopyCap: Int64 = 8 << 20              // 8 MB: safe to copy and count
let jsonParseCap: Int64 = 2 << 20

func countLines(path: String) -> Int? {
    guard let s = LineStream(path: path) else { return nil }
    var n = 0
    s.forEachLine { _ in n += 1 }
    return n
}

func averageLineBytes(path: String) -> Double? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    let chunk = h.readData(ofLength: 1 << 20)
    try? h.close()
    guard !chunk.isEmpty else { return nil }
    let newlines = chunk.reduce(into: 0) { acc, b in if b == 0x0A { acc += 1 } }
    guard newlines > 0 else { return nil }
    return Double(chunk.count) / Double(newlines)
}

var uncoveredSQLiteCopies: [String] = []
for (key, var f) in feeds where !f.covered {
    let ext = (key as NSString).pathExtension.lowercased()
    switch ext {
    case "jsonl", "ndjson":
        if f.bytes == 0 { f.rowEstimate = "0 (empty)" }
        else if f.bytes <= exactLineCountCap, f.files == 1, let n = countLines(path: f.sampleAbsolutePath) {
            f.rowEstimate = "\(n)"
        } else if let avg = averageLineBytes(path: f.sampleAbsolutePath), avg > 0 {
            f.rowEstimate = "~\(Int(Double(f.bytes) / avg)) (sampled)"
        } else {
            f.rowEstimate = "not counted (\(f.bytes >> 20) MB)"
        }
    case "json":
        if f.files > 1 { f.rowEstimate = "\(f.files) docs" }
        else if f.bytes <= jsonParseCap, let d = fm.contents(atPath: f.sampleAbsolutePath),
                let o = try? JSONSerialization.jsonObject(with: d) {
            if let a = o as? [Any] { f.rowEstimate = "\(a.count) (top-level array)" }
            else if let m = o as? [String: Any] { f.rowEstimate = "\(m.count) top-level keys" }
            else { f.rowEstimate = "1 doc" }
        } else { f.rowEstimate = "1 doc (not parsed, \(f.bytes >> 10) KB)" }
    case "sqlite", "db", "sqlite3":
        if f.bytes <= sqliteCopyCap, f.files == 1 {
            let dest = (workDir as NSString)
                .appendingPathComponent("walk-" + key.replacingOccurrences(of: "/", with: "_"))
            if (try? fm.copyItem(atPath: f.sampleAbsolutePath, toPath: dest)) != nil {
                uncoveredSQLiteCopies.append("\(key) → \((workDirDisplay as NSString).appendingPathComponent((dest as NSString).lastPathComponent))")
                let db = SQLiteCopy(originalPath: f.sampleAbsolutePath, copyPath: dest, label: key)
                let tables = db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
                    .compactMap { $0.first }
                var total = 0
                for t in tables { total += db.int("SELECT COUNT(*) FROM \"\(t)\";") ?? 0 }
                // Same rule as the covered stores: a failed read is UNREADABLE,
                // not a row count. Uncovered feeds get the honest label too.
                if let r = db.failureReason {
                    f.rowEstimate = "UNREADABLE — \(String(r.prefix(80)))"
                } else {
                    f.rowEstimate = "\(total) rows across \(tables.count) table(s)"
                }
            } else {
                f.rowEstimate = "not counted (copy failed)"
            }
        } else {
            f.rowEstimate = "not opened (\(f.bytes >> 20) MB — over the \(sqliteCopyCap >> 20) MB copy cap)"
        }
    default:
        f.rowEstimate = f.files > 1 ? "\(f.files) files" : "—"
    }
    feeds[key] = f
}

func isDisabledShadowFeedKey(_ key: String) -> Bool {
    key == "disabled" || key.hasPrefix("disabled/")
}
let disabledShadowFeeds = feeds.values.filter { isDisabledShadowFeedKey($0.key) }
    .sorted { $0.key < $1.key }
let disabledShadowRootStandard = URL(fileURLWithPath: disabledShadowRoot).standardizedFileURL.path
let disabledShadowReaderLabels = sources.entries.compactMap { entry -> String? in
    guard entry.label != disabledShadowLabel else { return nil }
    let path = URL(fileURLWithPath: entry.path).standardizedFileURL.path
    guard path == disabledShadowRootStandard || path.hasPrefix(disabledShadowRootStandard + "/") else { return nil }
    return entry.label
}.sorted()
let coveredFeeds = feeds.values.filter { $0.covered && !isDisabledShadowFeedKey($0.key) }.sorted { $0.key < $1.key }
// Newest first, TIES ON FEED KEY. Feeds written by one pass share an mtime to
// the second, and `feeds` is a Dictionary whose order is seeded per process —
// so without the key tiebreak every table derived from this array reshuffles
// between two runs over identical frozen bytes.
let uncoveredFeeds = feeds.values.filter { !$0.covered && !isDisabledShadowFeedKey($0.key) }
    .sorted { a, b in
        let x = a.newest ?? .distantPast, y = b.newest ?? .distantPast
        return x == y ? a.key < b.key : x > y
    }
let uncoveredActive = uncoveredFeeds.filter { ($0.newest ?? .distantPast) >= windowStart }
let uncoveredBytes = uncoveredFeeds.reduce(Int64(0)) { $0 + $1.bytes }

// ── The uncovered-feed BURNDOWN ─────────────────────────────────────────────
//
// The reach walk's NOT COVERED count is a tracked number, not a fact of
// nature. Each coverage wave states what it closed and the baseline moves
// DELIBERATELY — a wave that forgets to move it is caught by the report saying
// "was N at <date>" against a number that no longer matches.
//
// The rules, so this cannot rot into decoration:
//   • The baseline is only ever edited together with a wave that shipped
//     readers. Never edit it to make the delta look better.
//   • The delta is computed against THE REAL DATA ROOT. On a fixture root the
//     absolute count is meaningless — the burndown line is still printed there,
//     but the number it compares is not the one the baseline was taken from.
//   • A RISE is not a bug in the instrument: new subsystems start writing and
//     announce themselves as blind spots. The line reports the rise plainly and
//     the next wave decides whether to close it.
//
// These two constants MUST stay above the burndown expression below: this file
// is top-level Swift, where a `let` read before its initializer has run is not
// a compile error — it reads uninitialized memory and segfaults inside the
// first string interpolation that touches it. (Found by running it.)
//
// History (real data root, --days 7):
//   774  2026-08-21  baseline, before the SYS-01..08 wave-1 readers landed.
//   742  2026-08-21  wave 1 — the drop came entirely from the walker's
//                    `extraFeedClaims` merge and its sidecar inheritance;
//                    wave 1 claimed no new family of its own.
//   see docs/build_plans/full-system-eval-coverage.md for each wave's ledger.
let uncoveredBaseline = 774
let uncoveredBaselineDate = "2026-08-21"

// The BURNDOWN, computed once and rendered in two places (the BOOM reach line
// and section (i)).
let uncoveredDelta = uncoveredFeeds.count - uncoveredBaseline
let uncoveredBurndown: String = {
    if uncoveredDelta == 0 {
        return "unchanged from the \(uncoveredBaselineDate) baseline of \(uncoveredBaseline)"
    }
    if uncoveredDelta < 0 {
        return "**\(-uncoveredDelta) closed** since the \(uncoveredBaselineDate) baseline of \(uncoveredBaseline)"
    }
    return "**\(uncoveredDelta) NEW** since the \(uncoveredBaselineDate) baseline of \(uncoveredBaseline)"
}()

/// Exhaustive rollup of the uncovered feeds by top-level directory. The detail
/// table below is bounded; this is not — every uncovered feed is counted here,
/// so a bounded table can never quietly hide a subsystem.
struct DirRollup {
    var dir: String
    var feeds = 0
    var files = 0
    var bytes: Int64 = 0
    var activeFeeds = 0
    var newest: Date?
}
var uncoveredByDir: [String: DirRollup] = [:]
for f in uncoveredFeeds {
    let dir = f.key.contains("/") ? String(f.key[f.key.startIndex..<f.key.firstIndex(of: "/")!]) + "/" : "(data root)"
    var r = uncoveredByDir[dir] ?? DirRollup(dir: dir)
    r.feeds += 1
    r.files += f.files
    r.bytes += f.bytes
    if (f.newest ?? .distantPast) >= windowStart { r.activeFeeds += 1 }
    if let n = f.newest, r.newest == nil || n > r.newest! { r.newest = n }
    uncoveredByDir[dir] = r
}
// Active directories first, then largest, TIES ON DIRECTORY NAME. Two small
// directories can share a byte count exactly (`triggers/` and `skills/` both
// round to 1.3 KB on the live root and are equal to the byte); Dictionary
// order is per-process, so the tiebreak is what makes this table reproducible.
let uncoveredRollups = uncoveredByDir.values.sorted { a, b in
    let aActive = a.activeFeeds > 0 ? 1 : 0, bActive = b.activeFeeds > 0 ? 1 : 0
    if aActive != bActive { return aActive > bActive }
    if a.bytes != b.bytes { return a.bytes > b.bytes }
    return a.dir < b.dir
}
/// Bound on the per-feed detail table. Elision is always stated, never silent.
let uncoveredDetailLimit = 40

func humanBytes(_ b: Int64) -> String {
    if b >= 1 << 30 { return fmt(Double(b) / Double(1 << 30), 1) + " GB" }
    if b >= 1 << 20 { return fmt(Double(b) / Double(1 << 20), 1) + " MB" }
    if b >= 1 << 10 { return fmt(Double(b) / Double(1 << 10), 1) + " KB" }
    return "\(b) B"
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Turn-speed derivation
// ─────────────────────────────────────────────────────────────────────────────

for id in Array(turns.keys) {
    if let accepted = lifecycles[id]?.accepted, let terminal = lifecycles[id]?.terminal,
       terminal > accepted {
        turns[id]?.lifecycleElapsedMs = (terminal.timeIntervalSince(accepted) * 1000).rounded()
    }
}
let completedTurns = turns.values.filter { $0.elapsedMs != nil }
/// Performance and lifecycle diagnostics must describe the executable that is
/// actually installed. A retained seven-day trace can legitimately straddle
/// several fixes; treating old-build rows as current regressions made repaired
/// latency clocks keep resurfacing until the window aged out. Synthetic roots
/// and machines without an inspectable bundle retain the ordinary window.
let turnEvidenceTurns = completedTurns.filter {
    guard installedBuildEpoch != nil else { return true }
    return ($0.startedAt ?? .distantPast) >= runtimeEvidenceStart
}
let excludedEarlierBuildTurns = completedTurns.count - turnEvidenceTurns.count
var turnsBySurface: [String: [TurnRecord]] = [:]
for t in turnEvidenceTurns { turnsBySurface[t.surface, default: []].append(t) }
var turnsByDay: [String: [TurnRecord]] = [:]
for t in turnEvidenceTurns where !t.day.isEmpty { turnsByDay[t.day, default: []].append(t) }

/// Stages whose every in-window sample is zero. Reported as DARK — the number
/// is not "0 ms of work", it is "this stage's clock is not being written".
struct StageRow {
    let name: String
    let samples: Int
    let nonZero: Int
    let p50: Double
    let p95: Double
    let maxMs: Double
    let dark: Bool
    let lastNonZero: Date?
}
var stageRows: [StageRow] = []
for name in stageNamesSeen.sorted() {
    let s = (stageSamples[name] ?? []).sorted()
    let nonZero = s.filter { $0 != 0 }.count
    let lane = lanes["stageMs." + name]
    stageRows.append(StageRow(
        name: name,
        samples: s.count,
        nonZero: nonZero,
        p50: percentile(s, 0.5),
        p95: percentile(s, 0.95),
        maxMs: s.last ?? .nan,
        dark: !s.isEmpty && nonZero == 0 && name != "contextFlow.attention.actorAdmission",
        lastNonZero: lane?.lastNonZeroAt))
}
let darkStages = stageRows.filter { $0.dark }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Coverage matrix vs docs/SUBCONSCIOUS.md
//
// A HAND-MAINTAINED inventory of the subsystem map, kept here on purpose: the
// walker above answers "is there a store we don't read?", this answers the
// harder question "is there a *subsystem* we don't measure?" — including the
// ones whose state never lands in a file at all.
// ─────────────────────────────────────────────────────────────────────────────

enum CoverageStatus: String {
    case measured = "measured"
    case partial = "partial"
    case notYet = "not-yet"
}
struct CoverageRow {
    let id: String
    let subsystem: String
    let status: CoverageStatus
    let source: String
    let measurement: String
    let reason: String          // required for partial / not-yet
}
var coverage: [CoverageRow] = []
func cover(_ id: String, _ subsystem: String, _ status: CoverageStatus,
           source: String, measurement: String, reason: String = "") {
    coverage.append(CoverageRow(id: id, subsystem: subsystem, status: status,
                                source: source, measurement: measurement, reason: reason))
}

// 1 — somatic signals
if bodySchemaPresent {
    let healthy = bodySchema.values.filter { $0 }.count
    cover("SUB-01", "Somatic signals (body schema)", .measured,
          source: "`cognition/organism_state.json` → `bodySchema`",
          measurement: "\(healthy)/\(bodySchema.count) signals healthy: "
            + bodySchema.sorted { $0.key < $1.key }.map { "\(mdText($0.key))=\($0.value ? "1" : "0")" }.joined(separator: ", "))
} else {
    cover("SUB-01", "Somatic signals (body schema)", .notYet,
          source: "`cognition/organism_state.json` → `bodySchema`",
          measurement: "source absent",
          reason: "organism state file missing or carries no `bodySchema` key in this data root.")
}

// 2 — 4-axis affect + per-axis half-lives
if affectAxes.isEmpty {
    cover("SUB-02", "Affect — 4 axes + per-axis half-lives", .notYet,
          source: "`cognition.sqlite` → `cognitive_artifacts` kind=`affect`",
          measurement: "source absent",
          reason: "no `affect` artifact row in this store.")
} else {
    cover("SUB-02", "Affect — 4 axes + per-axis half-lives", .partial,
          source: "`cognition.sqlite` → `cognitive_artifacts` kind=`affect`",
          measurement: "current axes " + ["arousal", "uncertainty", "taskPressure", "socialWarmth"]
            .map { "\($0)=\(affectAxes[$0].map { fmt($0, 3) } ?? "absent")" }.joined(separator: ", "),
          reason: "axis VALUES are measured; the per-axis half-lives (20/45/45/90 min) are not — only "
            + "the current snapshot is persisted (one upserted row), so no decay curve exists to fit. "
            + "Measuring half-lives needs a per-turn affect history feed that does not exist yet.")
}

// 3 — 12-dim semantic appraisal
cover("SUB-03", "Semantic appraisal (12 dimensions)", .notYet,
      source: "would be: a per-event appraisal receipt",
      measurement: "no persisted appraisal row found anywhere in the walk",
      reason: "appraisal runs inside one await-free actor segment and is never written out; only its "
        + "RESULT (the node emotional tag) survives. Nothing in the data root carries the 12 dims, so "
        + "there is nothing to read — this is a producer gap, not a reader gap.")

// 4 — felt fingerprints
if capsuleParsedTurns > 0 {
    let top = fingerprintWordCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5)
        .map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", ")
    cover("SUB-04", "Felt fingerprints (capsule headline words)", .measured,
          source: "`turn_traces/*.jsonl` → `context.snapshot.payload.cognitivePreview`",
          measurement: "\(fingerprintWordCounts.values.reduce(0, +)) word(s) across \(capsuleParsedTurns) parsed capsule(s); "
            + "\(fingerprintWordCounts.count) distinct; top: \(top.isEmpty ? "none" : top)")
} else {
    cover("SUB-04", "Felt fingerprints (capsule headline words)", .notYet,
          source: "`turn_traces/*.jsonl` → `context.snapshot.payload.cognitivePreview`",
          measurement: "source absent",
          reason: "no `context.snapshot` row in the window carried a `cognitivePreview` block.")
}

// 5 — continuity field nodes + emotional tags
if cognition != nil {
    cover("SUB-05", "Continuity field — nodes + emotional tags", .measured,
          source: "`cognition.sqlite` → `cognitive_nodes`",
          measurement: "\(nodesTotal) node(s) (bound ≤256), \(emotionalTagNonZeroNodes) carrying a non-zero emotional tag"
            + (organismFieldNodes.map { "; organism-side field: \($0) node(s)" } ?? ""))
} else {
    cover("SUB-05", "Continuity field — nodes + emotional tags", .notYet,
          source: "`cognition.sqlite` → `cognitive_nodes`", measurement: cognitionState.unreadableReason == nil ? "source absent" : "source unreadable",
          reason: cognitionState.unreadableReason.map { "cognition store present but UNREADABLE: " + mdText($0) } ?? "cognition store missing in this data root.")
}

// 6 — standing views
if cognition != nil {
    cover("SUB-06", "Standing views", .measured,
          source: "`cognition.sqlite` → `cognitive_artifacts` kind=`standing_view`",
          measurement: "\(standingActive) active (bound ≤5), \(standingProposed) proposed (bound ≤12)")
} else {
    cover("SUB-06", "Standing views", .notYet,
          source: "`cognition.sqlite` → `cognitive_artifacts` kind=`standing_view`", measurement: cognitionState.unreadableReason == nil ? "source absent" : "source unreadable",
          reason: cognitionState.unreadableReason.map { "cognition store present but UNREADABLE: " + mdText($0) } ?? "cognition store missing in this data root.")
}

// 7 — prediction ledger
if predictionLedgerPresent {
    let statuses = predictionsByStatus.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .map { "\(mdText($0.key))=\($0.value)" }.joined(separator: ", ")
    cover("SUB-07", "Prediction ledger", .measured,
          source: "`cognition/organism_state.json` → `predictionLedger`",
          measurement: "\(predictionsTotal.map(String.init) ?? "?") live prediction(s) (bound ≤96) [\(statuses)]; "
            + "lifetime satisfied=\(predictionSatisfied.map(String.init) ?? "?") "
            + "violated=\(predictionViolated.map(String.init) ?? "?") "
            + "expired=\(predictionExpired.map(String.init) ?? "?")")
} else {
    cover("SUB-07", "Prediction ledger", .notYet,
          source: "`cognition/organism_state.json` → `predictionLedger`", measurement: "source absent",
          reason: "organism state file missing or carries no `predictionLedger` key.")
}

// 8 — trait dials
if !growthPresent {
    cover("SUB-08", "Trait dials (8, from GROWTH.md frontmatter)", .notYet,
          source: "`\(growthPath)` (outside the data root)", measurement: "source absent",
          reason: "no GROWTH.md at the persona root; pass --persona-root to point at it.")
} else if traitDials.isEmpty {
    cover("SUB-08", "Trait dials (8, from GROWTH.md frontmatter)", .partial,
          source: "`\((growthPath as NSString).abbreviatingWithTildeInPath)`",
          measurement: "0 of 8 dials set — the file carries \(growthHasFrontmatter ? "frontmatter with no dial keys" : "no `---` frontmatter block")",
          reason: "with no frontmatter every dial sits at the neutral 0.5 default, which is a real and "
            + "reportable state, but the instrument cannot distinguish \"deliberately neutral\" from "
            + "\"nobody has ever set these\" — only the presence/absence of the block is measurable.")
} else {
    cover("SUB-08", "Trait dials (8, from GROWTH.md frontmatter)", .measured,
          source: "`\((growthPath as NSString).abbreviatingWithTildeInPath)`",
          measurement: traitDials.sorted { $0.key < $1.key }.map { "\(mdText($0.key))=\(fmt($0.value, 2))" }.joined(separator: ", "))
}

// 9 — attention → fluid context
let attentionLaneNames = ["counts.contextFlow.attentionWorkingAtoms", "counts.contextFlow.attentionTerms",
                          "counts.contextFlow.attentionActivation", "counts.contextFlow.attentionToolGroups"]
let attentionObserved = attentionLaneNames.compactMap { lanes[$0] }
if attentionObserved.isEmpty {
    cover("SUB-09", "Attention signals → fluid context", .notYet,
          source: "`turn_traces/*.jsonl` → `context.summary.counts.contextFlow.attention*`",
          measurement: "source absent",
          reason: "no context.summary row in the lookback carried an attention lane.")
} else {
    let live = attentionObserved.filter { $0.nonZeroInWindow > 0 }.count
    cover("SUB-09", "Attention signals → fluid context", live == attentionObserved.count ? .measured : .partial,
          source: "`turn_traces/*.jsonl` → `context.summary.counts.contextFlow.attention*`",
          measurement: attentionLaneNames.map { n in
              let s = lanes[n]
              let leaf = n.split(separator: ".").last.map(String.init) ?? n
              return "\(leaf)=\(s.map { "\($0.nonZeroInWindow)/\($0.observationsInWindow) turns non-zero" } ?? "absent")"
          }.joined(separator: ", "),
          reason: live == attentionObserved.count ? ""
            : "\(attentionObserved.count - live) of \(attentionObserved.count) attention lanes are zero on every "
              + "traced turn in the window — see the dormancy table; a zero lane here may be a correct quiet "
              + "reading or a loose wire, and the store cannot tell you which.")
}

// 10 — delivery envelope
if !envelopePresent {
    cover("SUB-10", "Delivery envelope", .notYet,
          source: "`logs/delivery_envelope_telemetry.jsonl`", measurement: "source absent",
          reason: "telemetry file not present in this data root.")
} else if envelopeRowsWindow == 0 {
    cover("SUB-10", "Delivery envelope", .partial,
          source: "`logs/delivery_envelope_telemetry.jsonl`",
          measurement: "\(envelopeRowsTotal) row(s) in the file, 0 inside the \(days)d window"
            + (envelopeNewest.map { "; newest \(stamp($0))" } ?? ""),
          reason: "the feed exists but wrote nothing in the window, so in-band rate is unmeasured here — "
            + "and it is telemetry-only by design (nothing reads it back into behavior).")
} else {
    let pct = Double(envelopeInsideBand) / Double(envelopeRowsWindow) * 100
    cover("SUB-10", "Delivery envelope", .measured,
          source: "`logs/delivery_envelope_telemetry.jsonl`",
          measurement: "\(envelopeRowsWindow) reply(ies) in window, \(envelopeInsideBand) inside band (\(fmt(pct, 1))%), "
            + "\(envelopeOneBeat) one-beat — telemetry-only by design")
}

// 11 — overnight consolidation
if cognition == nil {
    cover("SUB-11", "Overnight emotional consolidation", .notYet,
          source: "`cognition.sqlite` → `cognitive_receipts` kind=`emotional_consolidation`",
          measurement: cognitionState.unreadableReason == nil ? "source absent" : "source unreadable", reason: cognitionState.unreadableReason.map { "cognition store present but UNREADABLE: " + mdText($0) } ?? "cognition store missing in this data root.")
} else {
    let last = consolidationRanAt.map { "last run \(stamp($0)) (\(fmt(now.timeIntervalSince($0) / 3600, 1))h ago)" }
        ?? "no `emotional_consolidation` artifact row"
    cover("SUB-11", "Overnight emotional consolidation", .measured,
          source: "`cognition.sqlite` → `cognitive_receipts` + `cognitive_artifacts` kind=`emotional_consolidation`",
          measurement: "\(consolidationRunsInWindow) run(s) in \(days)d; \(last)"
            + (consolidationCalmed.map { "; calmed=\($0)" } ?? "")
            + (consolidationReinforced.map { ", reinforced=\($0)" } ?? ""))
}

// 12 — REM / GROWTH pins
if !remPinsPresent && !remProposalsPresent && !dreamPresent {
    cover("SUB-12", "REM / GROWTH pins + proposals", .notYet,
          source: "`rem_pins.json`, `rem_proposals.jsonl`, `dream_diary/`",
          measurement: "source absent", reason: "none of the three REM feeds exist in this data root.")
} else {
    let statuses = remProposalsByStatus.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .map { "\(mdText($0.key))=\($0.value)" }.joined(separator: ", ")
    cover("SUB-12", "REM / GROWTH pins + proposals", .measured,
          source: "`rem_pins.json`, `rem_proposals.jsonl`, `dream_diary/`",
          measurement: "\(remPinsTotal.map(String.init) ?? "—") pin(s) "
            + "(\(remPinsByDoc.sorted { $0.key < $1.key }.map { "\(mdText($0.key))=\($0.value)" }.joined(separator: ", ")))"
            + (remPinNewest.map { ", newest \(stamp($0))" } ?? "")
            + "; \(remProposalsTotal) proposal(s) [\(statuses)], \(remProposalsInWindow) in window"
            + "; \(dreamNightsInWindow.count) dream night(s) in window")
}

let coverageMeasured = coverage.filter { $0.status == .measured }.count
let coveragePartial = coverage.filter { $0.status == .partial }.count
let coverageNotYet = coverage.filter { $0.status == .notYet }.count

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Report rendering
// ─────────────────────────────────────────────────────────────────────────────

var md = ""
func line(_ s: String = "") { md += s + "\n" }
func absent(_ what: String, _ path: String) {
    line("**source absent** — `\(mdCode(path))` not present in this data root, so *\(mdText(what))* is NOT measured here. This is not a zero.")
    line()
}
/// The source EXISTS and could not be read. Distinct from absent, and very
/// distinct from zero: this section is SKIPPED, and says so.
func unreadable(_ what: String, _ label: String) {
    line("**source unreadable: \(mdText(sources.reason(label)))** — `\(mdCode(label))` is present but could not be")
    line("read truthfully, so *\(mdText(what))* is NOT measured here and this section is skipped. No number")
    line("below is derived from it. This is not a zero. See the ranked lead for this source in [(j) LEADS](#sec-j).")
    line()
}
/// Renders the right one of the three states for a store-backed section.
/// Returns true when the section should be skipped.
func skipStoreSection(_ state: StoreState, _ what: String, _ label: String, _ path: String) -> Bool {
    switch state {
    case .ok: return false
    case .absent: absent(what, path); return true
    case .unreadable: unreadable(what, label); return true
    }
}
/// Same three-way answer for a JSONL feed registered under `label`.
func skipFeedSection(_ present: Bool, _ what: String, _ label: String, _ path: String) -> Bool {
    if sources.isUnreadable(label) { unreadable(what, label); return true }
    if !present { absent(what, path); return true }
    return false
}

line("# NativeAgent agent instrument")
line()
line("- generated: `\(stamp(now))` (UTC)"
     + (nowOverride != nil ? " — **CLOCK PINNED by `--now`**; this is not the time of the run" : ""))
line("- data root: `\(resolvedDataRoot)`")
line("- window: **\(days) day(s)** — `\(stamp(windowStart))` → `\(stamp(now))`")
line("- lane lookback: \(lookbackDays) days (needed to date a lane's last non-zero)")
line("- read-only: sqlite stores copied to `\(workDirDisplay)` before any query; JSONL streamed; nothing written inside the data root")
line()
line("> Scope: this instrument measures the resident agent as **the best general-purpose")
line("> agent you can have — like another human there working with you at the computer**:")
line("> memory recall, subconscious/personality liveness, desk throughput, responsiveness, cost.")
line("> It contains no code-task benchmarks by design — building is graded elsewhere.")
line()

// Everything above is the fixed header. The BOOM summary is derived from the
// whole report, so it is composed last and spliced in right here.
let headerBlock = md
md = ""

line("<a id=\"sec-sources\"></a>")
line()
line("## Sources")
line()
line("Exhaustive over the reach walk: **\(feeds.count)** feed(s) discovered under the data root, "
     + "**\(coveredFeeds.count)** claimed by a reader below, **\(uncoveredFeeds.count)** with no reader "
     + "(listed in [(i) REACH WALK — NOT COVERED](#sec-i)), and **\(disabledShadowFeeds.count)** under "
     + "`disabled/` listed separately as a shadow tree in [(i.2) WAVE-3 FEEDS](#sec-i2).")
line()
line("A source is exactly one of **yes** (read), **NO** (absent — nothing to measure) or")
line("**UNREADABLE** (present, could not be read truthfully). An UNREADABLE source has its sections")
line("skipped and raises a lead; none of its numbers appear anywhere, least of all as zeros. The")
line("`rows` column names malformed lines whenever a feed has any.")
line()
line("| source | present | rows | note |")
line("|---|---|---|---|")
for e in sources.entries {
    var rows = e.rows.map(String.init) ?? "—"
    if e.malformed > 0 { rows += ", malformed \(e.malformed)" }
    let state = e.unreadableReason != nil ? "**UNREADABLE**" : (e.present ? "yes" : "**NO**")
    var note = e.note
    if let r = e.unreadableReason { note = "source unreadable: " + mdText(r) }
    line("| `\(mdCode((e.path as NSString).abbreviatingWithTildeInPath))` | \(state) | \(rows) | \(mdComposed(note)) |")
}
line()
let unreadableSources = sources.entries.filter { $0.unreadableReason != nil }
if !unreadableSources.isEmpty {
    line("**\(unreadableSources.count) source(s) UNREADABLE** — their sections below are skipped with an")
    line("explicit `source unreadable:` line rather than rendered as zeros:")
    line()
    for e in unreadableSources {
        line("- `\(mdCode(e.label))` — \(mdText(e.unreadableReason ?? "unknown"))")
    }
    line()
}
if !copyLog.isEmpty {
    line("sqlite copies made before query:")
    line()
    for c in copyLog { line("- `\(c)`") }
    line()
}

// ── (a) Context-lane liveness ────────────────────────────────────────────────
line("<a id=\"sec-a\"></a>")
line()
line("## (a) Context-lane liveness — the silent-zero detector")
line()
if skipFeedSection(turnTracesPresent, "context-lane liveness", "turn_traces/", turnTraceDir) {
    // section skipped: absent or unreadable, rendered by the helper
} else if lanes.isEmpty {
    line("**source absent (effectively)** — `turn_traces/` exists but produced no `context.summary` /")
    line("`context.snapshot` rows inside the \(lookbackDays)-day lookback. No lane values are reported;")
    line("do not read this as \"all lanes zero\".")
    line()
} else {
    line("Every numeric / boolean / array field observed in `context.summary` and `context.snapshot`")
    line("rows, with days since its last **non-zero** value. A lane at zero for ≥3 days is flagged")
    line("`SUSPECT DORMANT` — that is a wire that may have come loose, not a measurement.")
    line()
    line("- `context.summary` rows in window: **\(summaryRowsWindow)**")
    line("- `context.snapshot` rows in window: **\(snapshotRowsWindow)** (\(snapshotRowsTruncated) truncated by the tracer)")
    if snapshotRowsTruncated > 0 {
        line("- ⚠︎ `context.snapshot` payloads are persisted as a **truncated** `_preview` string. Lanes")
        line("  prefixed `snapshot._preview.` are therefore *truncation-limited*: a key absent from the")
        line("  prefix is unmeasured, not dormant. `context.summary` lanes have no such limit.")
    }
    line()

    // A lane whose leaf name names a failure/truncation condition is SUPPOSED to
    // read zero. Calling those dormant would manufacture 12 false leads a run.
    let zeroIsHealthySuffixes = ["Truncated", "Failed", "Failure", "Error", "Errors",
                                 "CancellationObserved", "Cancelled", "Aborted", "Dropped"]
    // Lanes that are zero BY DESIGN on the live path and therefore not
    // dormancy evidence: `memory.recallHits.legacy` is the legacy recall()
    // lane, skipped on every `.active` ContextFlow turn (memory rides the
    // packet; the resolved count is `memory.recallHits`).
    // `imageBlockCount` is non-zero only on turns that carry an image
    // attachment — weeks of text-only turns are not dormancy evidence.
    let zeroIsHealthyLanes: Set<String> = ["counts.memory.recallHits.legacy", "counts.imageBlockCount"]
    func zeroIsHealthy(_ lane: String) -> Bool {
        if zeroIsHealthyLanes.contains(lane) { return true }
        let leaf = lane.split(separator: ".").last.map(String.init) ?? lane
        return zeroIsHealthySuffixes.contains { leaf.hasSuffix($0) }
    }
    // Lanes with a dedicated, better-evidenced detector further down the report.
    // Raising the generic lane lead too would double-count them.
    let specialCasedLanes: Set<String> = ["counts.memory.recallHits"]

    struct LaneRow {
        let name: String, stat: LaneStat, daysSince: Double?, dormant: Bool
    }
    var rows: [LaneRow] = []
    var absentRows: [LaneRow] = []          // observed in lookback, ZERO rows in window
    var healthyZeroRows: [LaneRow] = []
    // Lane NAME order, not Dictionary order (Swift seeds hashing per
    // process). NOTE: every render site below ALSO re-sorts its own rows
    // (liveRows/dormantRows/absentRows/healthyZeroRows), so this sort is
    // belt-and-suspenders, not load-bearing — a mutation test on it proves
    // nothing; the rendered sorted-order property is pinned in the test
    // suite directly instead (sweep 2026-08-21).
    for (name, s) in lanes.sorted(by: { $0.key < $1.key }) {
        let daysSince = s.lastNonZeroAt.map { now.timeIntervalSince($0) / 86400 }
        let neverNonZero = s.lastNonZeroAt == nil
        let row = LaneRow(name: name, stat: s, daysSince: daysSince,
                          dormant: neverNonZero || (daysSince ?? 0) >= 3)
        if s.observationsInWindow == 0 {
            // The KEY stopped appearing. That is "unmeasured in this window", NOT
            // "measured as zero" — the whole point of this instrument.
            absentRows.append(row)
        } else if row.dormant && zeroIsHealthy(name) {
            healthyZeroRows.append(row)
        } else {
            rows.append(row)
        }
    }
    // Oldest last-non-zero first, TIES BROKEN ON LANE NAME. Lanes that went
    // quiet on the same trace day share a `daysSince` to the digit; Swift's
    // sort is not stable and its Dictionary order is per-process, so without
    // the name tiebreak two runs over a FROZEN root emit these rows in
    // different orders and the report stops being reproducible.
    let dormantRows = rows.filter { $0.dormant }.sorted {
        ($0.daysSince ?? 9e9) == ($1.daysSince ?? 9e9)
            ? $0.name < $1.name : ($0.daysSince ?? 9e9) > ($1.daysSince ?? 9e9)
    }
    let liveRows = rows.filter { !$0.dormant }.sorted { $0.name < $1.name }

    if dormantRows.isEmpty {
        line("**No dormant lanes.** Every observed lane produced a non-zero value within the last 3 days.")
        line()
    } else {
        line("### SUSPECT DORMANT (\(dormantRows.count))")
        line()
        line("| lane | source | last non-zero | days since | rows in window | non-zero in window |")
        line("|---|---|---|---|---|---|")
        for r in dormantRows {
            let last = r.stat.lastNonZeroAt.map { stamp($0) } ?? "**never in \(lookbackDays)d**"
            let dsince = r.daysSince.map { fmt($0, 1) } ?? "≥\(lookbackDays)"
            line("| `\(mdCode(r.name))` | \(mdCode(r.stat.source)) | \(last) | \(dsince) | \(r.stat.observationsInWindow) | \(r.stat.nonZeroInWindow) |")
        }
        line()
        // `stageMs.*` lanes raise their lead in section (f), where the report can
        // say "dark" with a p50/p95 next to it instead of a bare dormancy row.
        for r in dormantRows where !specialCasedLanes.contains(r.name) && !r.name.hasPrefix("stageMs.") {
            let last = r.stat.lastNonZeroAt.map { stamp($0) } ?? "never within \(lookbackDays)d lookback"
            let truncLimited = r.name.hasPrefix("snapshot._preview.")
            addLead(rank: truncLimited ? 25 : 10,
                    "Context lane `\(mdCode(r.name))` looks dormant\(truncLimited ? " (truncation-limited source)" : "")",
                    evidence: "\(r.stat.observationsInWindow) `\(mdCode(r.stat.source))` rows in the \(days)d window, "
                        + "\(r.stat.nonZeroInWindow) non-zero; last non-zero \(last).",
                    action: truncLimited
                        ? "Confirm against a non-truncated source before acting — the tracer clips this payload."
                        : "Trace the producer for this lane and prove it can still emit a non-zero, or delete the lane.")
        }
    }

    if !absentRows.isEmpty {
        line("### ABSENT FROM WINDOW (\(absentRows.count)) — unmeasured, NOT zero")
        line()
        line("These keys were emitted at some point in the \(lookbackDays)-day lookback but appear in")
        line("**no row inside the \(days)-day window**. The producer stopped emitting the key, or the")
        line("tracer's truncation now clips it. Either way there is nothing to average: they are")
        line("reported here instead of being rendered as a zero.")
        line()
        line("| lane | source | last observed | last non-zero |")
        line("|---|---|---|---|")
        // Newest sighting first, TIES ON LANE NAME — a whole class of these
        // keys stopped on the very same trace row and share a timestamp.
        for r in absentRows.sorted(by: {
            let x = $0.stat.lastObservedAt ?? .distantPast, y = $1.stat.lastObservedAt ?? .distantPast
            return x == y ? $0.name < $1.name : x > y
        }) {
            line("| `\(mdCode(r.name))` | \(mdCode(r.stat.source)) | \(r.stat.lastObservedAt.map { stamp($0) } ?? "—") | "
                 + "\(r.stat.lastNonZeroAt.map { stamp($0) } ?? "never in \(lookbackDays)d") |")
        }
        line()
        let newest = absentRows.compactMap { $0.stat.lastObservedAt }.max()
        addLead(rank: 26,
                "\(absentRows.count) context lane(s) stopped being emitted entirely",
                evidence: "Keys present in the \(lookbackDays)d lookback but in 0 rows of the \(days)d window"
                    + (newest.map { "; newest sighting \(stamp($0))" } ?? "")
                    + ". Examples: " + absentRows.prefix(4).map { "`\(mdCode($0.name))`" }.joined(separator: ", ") + ".",
                action: "Decide per lane: a payload-schema change (fine, update consumers) or a producer that "
                    + "went quiet (a real regression). Do NOT read these as zeros.")
    }

    if !healthyZeroRows.isEmpty {
        line("### Zero-is-healthy flags (\(healthyZeroRows.count)) — not flagged")
        line()
        line("Lanes whose leaf name states a failure/truncation condition, or that are zero BY DESIGN on the live path (`zeroIsHealthyLanes`). Zero is the *correct*")
        line("reading, so they are excluded from the dormancy detector by name, and no lead is raised.")
        line("If one of these should be non-zero, that judgment is the reader's, not the tool's.")
        line()
        for r in healthyZeroRows.sorted(by: { $0.name < $1.name }) {
            line("- `\(mdCode(r.name))` — \(r.stat.observationsInWindow) rows in window, all zero (\(mdCode(r.stat.source)))")
        }
        line()
    }

    line("### Live lanes (\(liveRows.count))")
    line()
    line("| lane | source | rows in window | non-zero | mean | last non-zero |")
    line("|---|---|---|---|---|---|")
    for r in liveRows {
        let mean = r.stat.observationsInWindow > 0
            ? fmt(r.stat.sumInWindow / Double(r.stat.observationsInWindow), 2) : "—"
        let last = r.stat.lastNonZeroAt.map { stamp($0) } ?? "—"
        line("| `\(mdCode(r.name))` | \(mdCode(r.stat.source)) | \(r.stat.observationsInWindow) | \(r.stat.nonZeroInWindow) | \(mean) | \(last) |")
    }
    line()
}

line("### Legacy context-generation cutover")
line()
if !contextSQLitePresent {
    absent("legacy context-generation cutover", contextSQLitePath)
} else if sources.isUnreadable("context/context.sqlite") {
    unreadable("legacy context-generation cutover", "context/context.sqlite")
} else if let cutover = contextSQLiteCutover {
    line("- SQLite cutover (filesystem birth): **\(stamp(cutover))**")
    func renderLegacyContextCensus(_ label: String, _ present: Bool,
                                   _ census: LegacyContextCensus?) -> String? {
        if !present { return "`\(mdCode(label))`: source absent" }
        if sources.isUnreadable(label) { return "`\(mdCode(label))`: source unreadable" }
        guard let census else { return "`\(mdCode(label))`: unmeasured" }
        let status = legacyContextCutoverStatus(census, cutover)
        let newest = census.newest.map(stamp) ?? "none"
        return "`\(mdCode(label))`: **\(census.files)** file(s) · **\(humanBytes(census.bytes))** · newest \(newest) → **\(status)**"
    }
    let jsonStatus = legacyContextCutoverStatus(legacyContextJSONCensus, cutover)
    let cacheStatus = legacyContextCutoverStatus(legacyContextCacheCensus, cutover)
    if let row = renderLegacyContextCensus(legacyContextJSONLabel, legacyContextJSONPresent,
                                           legacyContextJSONCensus) { line("- \(row)") }
    if let row = renderLegacyContextCensus(legacyContextCacheLabel, legacyContextCachePresent,
                                           legacyContextCacheCensus) { line("- \(row)") }
    line()

    let revived = [(legacyContextJSONLabel, jsonStatus), (legacyContextCacheLabel, cacheStatus)]
        .filter { $0.1 == "ACTIVE AFTER CUTOVER" }
        .map(\.0)
    if !revived.isEmpty {
        addLead(rank: 7, "Legacy context generation feed wrote at or after the SQLite cutover",
                evidence: "SQLite birth cutover is \(stamp(cutover)); \(revived.map { "`\(mdCode($0))`" }.joined(separator: ", ")) has a newest file whose mtime is not strictly older.",
                action: "Trace the writer immediately. Current-context lookup must follow a live run id, never fall back to a directory scan of pre-SQLite generations.")
    }
} else {
    line("**cutover unavailable** — `context/context.sqlite` is present but its filesystem birth time could not be read. Legacy files are not called frozen without that boundary.")
    line()
}

// ── (b) Subconscious vitals ──────────────────────────────────────────────────
line("<a id=\"sec-b\"></a>")
line()
line("## (b) Subconscious vitals")
line()
if skipStoreSection(cognitionState, "affect axes, standing views, consolidation/reflection runs",
                    "cognition.sqlite", rootPath("cognition/cognition.sqlite")) {
    // section skipped: absent or unreadable, rendered by the helper
} else {
    line("### Affect axes vs bounds")
    line()
    if affectAxes.isEmpty {
        line("**source absent** — no `affect` artifact row in `cognitive_artifacts`. Axes are NOT reported as 0.")
        line()
    } else {
        line("Documented invariant (docs/SUBCONSCIOUS.md, Layer II): all four axes are bounded `0…1`,")
        line("saturating-approach updates, per-axis half-lives.")
        line()
        line("| axis | current | in 0…1 bounds |")
        line("|---|---|---|")
        for axis in ["arousal", "uncertainty", "taskPressure", "socialWarmth"] {
            guard let v = affectAxes[axis] else {
                line("| `\(axis)` | **absent** | — |")
                continue
            }
            let ok = v >= 0 && v <= 1
            line("| `\(axis)` | \(fmt(v, 4)) | \(ok ? "yes" : "**OUT OF BOUNDS**") |")
            if !ok {
                addLead(rank: 5, "Affect axis `\(axis)` is outside its 0…1 bound",
                        evidence: "cognitive_artifacts kind='affect' → \(axis) = \(fmt(v, 4)).",
                        action: "The saturating-approach update or the decay anchor is broken; pin with a range test.")
            }
        }
        if let u = affectUpdatedAt {
            line()
            line("- affect last updated: `\(stamp(u))` (\(fmt(now.timeIntervalSince(u) / 3600, 1))h ago)")
        }
        line()
        line("**Range over the window: source absent.** Only the *current* affect snapshot is persisted")
        line("(`cognitive_artifacts` holds one `affect` row, upserted). No per-turn affect history exists")
        line("in this data root, so min/max over \(days) days cannot be measured — reporting 0 would be a lie.")
        line()
    }
    if let d = dispositionValence {
        let cap = 0.35
        line("- disposition valence: **\(fmt(d, 3))** (documented cap ±\(fmt(cap, 2)) → \(abs(d) <= cap ? "within cap" : "**OVER CAP**"))")
        if abs(d) > cap {
            addLead(rank: 5, "Disposition valence exceeds its documented ±0.35 cap",
                    evidence: "cognitive_artifacts kind='disposition' → valence = \(fmt(d, 3)).",
                    action: "One of the four disposition writers is bypassing the shared integration door.")
        }
        line()
    }

    line("### Capsule presence per turn")
    line()
    if snapshotRowsWindow == 0 {
        line("**source absent** — no `context.snapshot` rows in the window; capsule presence is unmeasured.")
        line()
    } else {
        let rate = Double(capsulePresentRows) / Double(snapshotRowsWindow) * 100
        let sortedBytes = capsuleBytes.sorted()
        line("- turns with a `[CognitiveSubstrate]` capsule: **\(capsulePresentRows) / \(snapshotRowsWindow)** (\(fmt(rate, 1))%)")
        if !sortedBytes.isEmpty {
            line("- capsule bytes: p50 \(fmt(percentile(sortedBytes, 0.5), 0)), p95 \(fmt(percentile(sortedBytes, 0.95), 0)), max \(fmt(sortedBytes.last ?? 0, 0))")
        }
        line()
        if rate < 99 {
            addLead(rank: 15, "Capsule missing on \(snapshotRowsWindow - capsulePresentRows) of \(snapshotRowsWindow) traced turns",
                    evidence: "context.snapshot rows in the \(days)d window: \(capsulePresentRows) carry a non-zero cognitiveCapsuleBytes.",
                    action: "Check the three injection seams (StructuredChat, text-compat, ephemeral-turn) — all must carry it.")
        }
    }

    line("### Standing views")
    line()
    line("- active: **\(standingActive)** (documented bound ≤5) · proposed: **\(standingProposed)** (bound ≤12, 14-day age-out)")
    if standingActive > 5 || standingProposed > 12 {
        addLead(rank: 8, "Standing-view bounds exceeded",
                evidence: "cognitive_artifacts standing_view: active=\(standingActive), proposed=\(standingProposed).",
                action: "LRU demotion / age-out is not running.")
    }
    line()

    line("### Consolidation, reflection, dreams in window")
    line()
    line("| signal | count in \(days)d | source |")
    line("|---|---|---|")
    line("| emotional consolidation runs | \(consolidationRunsInWindow) | `cognitive_receipts` kind=`emotional_consolidation` |")
    line("| reflection receipts | \(reflectionRunsInWindow) | `cognitive_receipts` kind LIKE `reflection.%` |")
    line("| replay integrations | \(replayIntegrationsInWindow) | `cognitive_receipts` kind=`replay.integration` |")
    if dreamPresent {
        line("| dream nights on disk | \(dreamNightsInWindow.count) | `dream_diary/*.md` |")
    } else {
        line("| dream nights on disk | **source absent** | `dream_diary/` missing |")
    }
    line()
    let expectedConsolidations = max(1, Int(Double(days) * 24.0 / 20.0) - 1)   // ~1 per 20h
    if consolidationRunsInWindow == 0 {
        addLead(rank: 12, "No overnight emotional consolidation ran in the window",
                evidence: "`cognitive_receipts` has 0 rows of kind `emotional_consolidation` since \(stamp(windowStart)).",
                action: "The ~20h consolidation boundary rides maintenance — check the exact-deadline maintenance wake.")
    } else if consolidationRunsInWindow < expectedConsolidations {
        addLead(rank: 22, "Consolidation cadence below the ~20h boundary",
                evidence: "\(consolidationRunsInWindow) `emotional_consolidation` receipts in \(days)d; ~\(expectedConsolidations) expected.",
                action: "Confirm the maintenance wake is re-anchored after system sleep.")
    }
    if dreamPresent && dreamNightsInWindow.count < days - 1 {
        addLead(rank: 24, "Dream diary has \(dreamNightsInWindow.count) night(s) for a \(days)-day window",
                evidence: "`dream_diary/` files dated in window: \(dreamNightsInWindow.joined(separator: ", ")).",
                action: "Dream is scheduler-owned at 03:30 local — check the scheduler ran on the missing nights.")
    }

    line("### Node population and emotional tagging")
    line()
    line("- nodes: **\(nodesTotal)** (documented ContinuityField bound ≤256)")
    if nodesTotal > 0 {
        let tagged = Double(emotionalTagNonZeroNodes) / Double(nodesTotal) * 100
        line("- nodes carrying a non-zero emotional tag: **\(emotionalTagNonZeroNodes)** (\(fmt(tagged, 1))%)")
    }
    if !nodeKindCounts.isEmpty {
        line("- by kind: " + nodeKindCounts.map { "`\(mdCode($0.0))`=\($0.1)" }.joined(separator: ", "))
    }
    if let l = nodeLatest {
        line("- newest node activation: `\(stamp(l))` (\(fmt(now.timeIntervalSince(l) / 3600, 1))h ago)")
    }
    line()

    if !organismPresent {
        absent("organism chemistry", organismPath)
    } else {
        line("### Organism chemistry")
        line()
        if chemistry.isEmpty {
            line("**source absent** — `organism_state.json` present but has no `chemicalState`. Not reported as zero.")
        } else {
            let outOfBounds = chemistry.filter { $0.value < 0 || $0.value > 1 }
            line("- 10 axes, documented bound `0…1`: " + chemistry.sorted { $0.key < $1.key }
                .map { "\(mdText($0.key))=\(fmt($0.value, 3))" }.joined(separator: ", "))
            line("- out of bounds: \(outOfBounds.isEmpty ? "none" : outOfBounds.keys.sorted().map(mdText).joined(separator: ", "))")
            if let s = organismSavedAt {
                line("- state saved: `\(stamp(s))` (\(fmt(now.timeIntervalSince(s) / 3600, 1))h ago), signalCount=\(organismSignalCount.map(String.init) ?? "—")")
            }
            for (k, v) in outOfBounds {
                addLead(rank: 6, "Organism chemistry axis `\(mdCode(k))` out of 0…1 bounds",
                        evidence: "organism_state.json chemicalState.\(mdText(k)) = \(fmt(v, 4)).",
                        action: "The analytic read-time decay curve is producing an unclamped value.")
            }
        }
        line()
    }
}

line("### Organism watch sampler")
line()
if !organismWatchPresent {
    line("**source absent** — `cognition/organism_watch.jsonl` is not present. This is not zero organism activity; the passive sampler has no evidence to report.")
} else if sources.isUnreadable("cognition/organism_watch.jsonl") {
    line(organismWatchRunActive
        ? "**source unreadable** — the explicitly active `cognition/organism_watch.jsonl` could not provide a trustworthy sampler age. No organism-activity count is inferred."
        : "**historical / inactive source unreadable** — no active-run marker exists, so this is retained observation residue rather than a current lane failure.")
} else if organismWatchRows == 0 {
    line(organismWatchRunActive
        ? "**EMPTY active sampler** — file present with 0 rows while the explicit run marker exists."
        : "**HISTORICAL / INACTIVE empty sampler** — file present with 0 rows and no active-run marker.")
} else {
    line("- retained rows: **\(organismWatchRows) / \(organismWatchRowCeiling)** default writer cap · malformed: \(organismWatchMalformed)")
    line("- run marker: " + (organismWatchRunActive
        ? "**active** (`organism_watch.jsonl.lock/` exists)"
        : "**absent — historical/inactive observation file**, not a failed resident lane"))
    if organismWatchRows > organismWatchRowCeiling, organismWatchRunActive {
        addLead(rank: 6, "`cognition/organism_watch.jsonl` exceeds its \(organismWatchRowCeiling)-row retention bound",
                evidence: "The passive sampler holds \(organismWatchRows) rows; `organism_watch.sh` defaults to retaining at most \(organismWatchRowCeiling).",
                action: "Check whether the watch was started with an intentional larger cap. Otherwise its compaction path is not running and the timeline will grow without bound.")
    }
    if organismWatchTimestampless > 0 || organismWatchFutureStamped > 0 {
        line("- **freshness indeterminate** — \(organismWatchTimestampless) row(s) lack a parseable `at`; \(organismWatchFutureStamped) row(s) are more than 5 minutes in the future. These rows do not prove the sampler is live.")
        if organismWatchRunActive {
            addLead(rank: 5, "`cognition/organism_watch.jsonl` has timestamp-invalid sampler rows",
                    evidence: "\(organismWatchTimestampless) row(s) have no parseable `at`; \(organismWatchFutureStamped) have future timestamps. The newest trustworthy sample is \(organismWatchNewest.map(stamp) ?? "none").",
                    action: "Repair the active sampler's wall clock or writer schema before using this file for liveness; an invalid timestamp must not mask a dormant observer.")
        }
    } else if let newest = organismWatchNewest {
        let ageHours = max(0, now.timeIntervalSince(newest) / 3600)
        if !organismWatchRunActive {
            line("- **HISTORICAL / INACTIVE sampler** — newest valid sample `\(stamp(newest))` (\(fmt(ageHours, 1))h ago); no active-run marker exists.")
        } else if organismWatchRowsInWindow == 0 {
            line("- **DORMANT sampler** — newest valid sample `\(stamp(newest))` (\(fmt(ageHours, 1))h ago); 0 rows inside the \(days)d window.")
            addLead(rank: 4, "`cognition/organism_watch.jsonl` is DORMANT — newest sample \(fmt(ageHours, 1))h ago",
                    evidence: "\(organismWatchRows) validly dated sampler row(s); newest `at` is \(stamp(newest)), outside the \(days)-day window that starts \(stamp(windowStart)).",
                    action: "An active-run marker exists but no current sample arrived. Inspect the explicitly started watch process or clear a stale marker after confirming no writer is running.")
        } else {
            line("- **ACTIVE sampler** — newest valid sample `\(stamp(newest))` (\(fmt(ageHours, 1))h ago); \(organismWatchRowsInWindow) row(s) in window: \(organismWatchSuccessfulRowsInWindow) reachable, \(organismWatchUnreachableRowsInWindow) bridge-unreachable.")
        }
    } else {
        line("- **freshness indeterminate** — \(organismWatchRows) JSON row(s), but none contains a parseable non-future `at`. The sampler cannot be called dormant or live.")
        if organismWatchRunActive {
            addLead(rank: 5, "`cognition/organism_watch.jsonl` has no trustworthy sample timestamp",
                    evidence: "The active sampler file carries \(organismWatchRows) JSON row(s), but no valid `at` value survives timestamp validation.",
                    action: "Repair the row schema before interpreting this active sampler. A present file with undated rows is not evidence of organism activity.")
        }
    }
}
line()

line("### Somatic signals (body schema)")
line()
if !bodySchemaPresent {
    line("**source absent** — no `bodySchema` key in `organism_state.json`. Signals are NOT reported as false.")
    line()
} else {
    let healthy = bodySchema.values.filter { $0 }.count
    line("- \(healthy) / \(bodySchema.count) signals healthy")
    line()
    line("| signal | state |")
    line("|---|---|")
    for (k, v) in bodySchema.sorted(by: { $0.key < $1.key }) {
        line("| `\(mdCode(k))` | \(v ? "healthy" : "**unhealthy**") |")
    }
    line()
    let unhealthy = bodySchema.filter { !$0.value }.keys.sorted()
    if !unhealthy.isEmpty {
        addLead(rank: 13, "\(unhealthy.count) somatic signal(s) reading unhealthy",
                evidence: "`organism_state.json` bodySchema: " + unhealthy.map { "`\(mdCode($0))`" }.joined(separator: ", ")
                    + (organismSavedAt.map { "; state saved \(stamp($0))" } ?? "") + ".",
                action: "The body colors the capsule's `- Body:` line and the posture directives — an unhealthy "
                    + "signal makes her cautious about that path in every reply until it clears.")
    }
}

line("### Prediction ledger")
line()
if !predictionLedgerPresent {
    line("**source absent** — no `predictionLedger` key in `organism_state.json`. Counters are NOT reported as zero.")
    line()
} else {
    let bound = 96
    let total = predictionsTotal ?? 0
    line("- live predictions: **\(total)** (documented bound ≤\(bound)) → \(total <= bound ? "within bound" : "**OVER BOUND**")")
    if !predictionsByStatus.isEmpty {
        line("- by status: " + predictionsByStatus.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "`\(mdCode($0.key))`=\($0.value)" }.joined(separator: ", "))
    }
    line("- lifetime: satisfied=\(predictionSatisfied.map(String.init) ?? "—"), "
         + "violated=\(predictionViolated.map(String.init) ?? "—"), "
         + "expired=\(predictionExpired.map(String.init) ?? "—")")
    if let u = predictionLedgerUpdatedAt {
        line("- ledger last updated: `\(stamp(u))` (\(fmt(now.timeIntervalSince(u) / 3600, 1))h ago)")
    }
    if !bodyConfidence.isEmpty {
        line("- body confidence per path: " + bodyConfidence.sorted { $0.key < $1.key }
            .map { "\(mdText($0.key))=\(fmt($0.value, 2))" }.joined(separator: ", "))
    }
    line()
    if total > bound {
        addLead(rank: 8, "Prediction ledger holds \(total) predictions, over its ≤\(bound) bound",
                evidence: "`organism_state.json` predictionLedger.predictions count = \(total).",
                action: "The ledger prune is not running — an unbounded ledger keeps stale braces alive and skews relief sizing.")
    }
    let expired = predictionsByStatus["expired"] ?? 0
    if total > 0, expired * 2 > total {
        addLead(rank: 21, "\(expired) of \(total) live predictions are `expired`",
                evidence: "`organism_state.json` predictionLedger: expired=\(expired) of \(total) live rows.",
                action: "A ledger dominated by expirations means she is bracing for outcomes that never resolve — "
                    + "check which paths never report back.")
    }
    let lowConfidence = bodyConfidence.filter { $0.value < 0.6 }.sorted { $0.key < $1.key }
    if !lowConfidence.isEmpty {
        addLead(rank: 22, "Body confidence is low on \(lowConfidence.count) path(s)",
                evidence: "`organism_state.json` predictionLedger.bodyConfidence: "
                    + lowConfidence.map { "\(mdText($0.key))=\(fmt($0.value, 2))" }.joined(separator: ", ") + ".",
                action: "Low path confidence feeds the `careful` posture — find what keeps failing on that path.")
    }
}

line("### Capsule anatomy (what the model actually received)")
line()
if capsuleParsedTurns == 0 {
    line("**source absent** — no `cognitivePreview` block survived in any `context.snapshot` row in the window.")
    line("Capsule line rates are NOT reported as zero.")
    line()
} else {
    line("Parsed out of the exact bytes the model saw, \(capsuleParsedTurns) capsule(s) in the window.")
    line()
    line("| capsule line | turns carrying it | rate |")
    line("|---|---|---|")
    for marker in ["fingerprint", "- Inner:", "- Body:", "- Settling:", "- Sound: exemplar echo", "- Sound: rut awareness", "- Since:"] {
        let n = capsuleLineCounts[marker] ?? 0
        line("| `\(marker)` | \(n) | \(fmt(Double(n) / Double(capsuleParsedTurns) * 100, 1))% |")
    }
    line()
    if !fingerprintWordCounts.isEmpty {
        let sorted = fingerprintWordCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        line("- felt fingerprint vocabulary in use: **\(fingerprintWordCounts.count)** distinct word(s) over "
             + "\(fingerprintWordCounts.values.reduce(0, +)) emissions")
        line("- most frequent: " + sorted.prefix(8).map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
        line()
        if let top = sorted.first, capsuleParsedTurns > 0 {
            // A fingerprint can carry several words.  Dominance is therefore
            // presence across capsules, not its share of all word emissions.
            let share = Double(top.value) / Double(capsuleParsedTurns)
            if share > 0.5 {
                addLead(rank: 20, "Felt fingerprint is dominated by one word (`\(mdCode(top.key))`, \(fmt(share * 100, 0))% of capsules)",
                        evidence: "\(capsuleParsedTurns) capsules parsed from `context.snapshot.payload.cognitivePreview`; "
                            + "`\(mdCode(top.key))` appears in \(top.value) capsule headline(s).",
                        action: "A word that fires on most turns is a floor, not a signal — check the intensity gate "
                            + "and the suppress-when-unchanged window for that family.")
            }
        }
    }
    if !posturesSeen.isEmpty {
        line("- organism posture distribution: " + posturesSeen.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
        line()
    }
}

line("### REM pins, proposals, thought seeds")
line()
if !remPinsPresent {
    absent("REM pins", remPinsPath)
} else {
    line("- pins: **\(remPinsTotal.map(String.init) ?? "—")** — "
         + (remPinsByDoc.isEmpty ? "no target doc keys"
            : remPinsByDoc.sorted { $0.key < $1.key }.map { "`\(mdCode($0.key))`=\($0.value)" }.joined(separator: ", ")))
    if let n = remPinNewest {
        line("- newest pin: `\(stamp(n))` (\(fmt(now.timeIntervalSince(n) / 86400, 1))d ago)")
    }
    line("- ≤3 latest pins ride the STABLE cached prefix (docs/SUBCONSCIOUS.md, Layer IV).")
    line()
}
if !remProposalsPresent {
    absent("REM proposals", remProposalsPath)
} else {
    line("- proposals: **\(remProposalsTotal)** total, \(remProposalsInWindow) in window — "
         + (remProposalsByStatus.isEmpty ? "no status field"
            : remProposalsByStatus.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "`\(mdCode($0.key))`=\($0.value)" }.joined(separator: ", ")))
    if let n = remProposalNewest {
        line("- newest proposal: `\(stamp(n))` (\(fmt(now.timeIntervalSince(n) / 86400, 1))d ago)")
    }
    line()
}
if let seeds = thoughtSeedsOpen {
    line("- open thought seeds: **\(seeds)** (documented bound ≤128)")
    line()
    if seeds > 128 {
        addLead(rank: 22, "Thought seeds over their ≤128 bound (\(seeds))",
                evidence: "cognition.sqlite `cognitive_artifacts` kind=`thought_seed` status=`open`: \(seeds) rows.",
                action: "Seed pruning / priority half-life is not running.")
    }
}

line("### Trait dials")
line()
if !growthPresent {
    absent("trait dials", growthPath)
} else if traitDials.isEmpty {
    line("**not set** — `\((growthPath as NSString).abbreviatingWithTildeInPath)` carries "
         + (growthHasFrontmatter ? "frontmatter with no dial keys" : "**no `---` frontmatter block**") + ",")
    line("so all 8 dials sit at the neutral 0.5 default. This is a real state, not a missing measurement:")
    line("the three live edges (warmth span, delivery-envelope center, play-mode weight) are running at")
    line("their calibrated defaults.")
    line()
} else {
    line("| dial | value | vs neutral 0.5 |")
    line("|---|---|---|")
    for name in traitDialNames {
        guard let v = traitDials[name] else { continue }
        line("| `\(name)` | \(fmt(v, 2)) | \(v > 0.5 ? "+" : "")\(fmt(v - 0.5, 2)) |")
    }
    line()
    let outOfRange = traitDials.filter { $0.value < 0 || $0.value > 1 }.keys.sorted()
    if !outOfRange.isEmpty {
        addLead(rank: 9, "Trait dial(s) outside the documented 0…1 range: \(outOfRange.joined(separator: ", "))",
                evidence: "GROWTH.md frontmatter: " + outOfRange.map { "\($0)=\(fmt(traitDials[$0] ?? .nan, 3))" }.joined(separator: ", ") + ".",
                action: "Dials map onto felt physics bounded to ±50% of a calibrated default — an out-of-range dial "
                    + "either clamps silently or skews the warmth span.")
    }
}

// ── (c) Memory performance ───────────────────────────────────────────────────
line("<a id=\"sec-c\"></a>")
line()
line("## (c) Memory performance")
line()
if skipStoreSection(memoryState, "memory store metrics", "memory.sqlite",
                    rootPath("memory/memory.sqlite")) {
    // section skipped: absent or unreadable, rendered by the helper
} else {
    line("### Store")
    line()
    line("| metric | value |")
    line("|---|---|")
    line("| memories (total / active) | \(memoriesTotal.map(String.init) ?? "—") / \(memoriesActive.map(String.init) ?? "—") |")
    line("| memories created in window | \(memoriesCreatedInWindow.map(String.init) ?? "—") |")
    line("| memories *used* in window (`last_used_at`) | \(memoriesUsedInWindow.map(String.init) ?? "—") |")
    line("| KG entities / relationships | \(kgEntities.map(String.init) ?? "—") / \(kgRelationships.map(String.init) ?? "—") |")
    line("| KG memory index rows | \(kgIndexed.map(String.init) ?? "—") |")
    if let l = memoryLatestUpdated {
        line("| newest memory `updated_at` | \(stamp(l)) (\(fmt(now.timeIntervalSince(l) / 86400, 1))d ago) |")
    } else {
        line("| newest memory `updated_at` | **source absent** |")
    }
    line()
    if !proposalsByStatus.isEmpty {
        line("- proposals by status: " + proposalsByStatus.map { "`\(mdCode($0.0))`=\($0.1)" }.joined(separator: ", "))
        line()
    }
    if let total = kgEligible, let indexed = kgIndexed, total > 0, indexed < total {
        let pct = Double(indexed) / Double(total) * 100
        addLead(rank: 14, "KG memory index covers only \(fmt(pct, 0))% of eligible memories",
                evidence: "memory.sqlite: `kg_memory_index` \(indexed) rows vs \(total) eligible `memories` rows (active, not corrected, not skill-pointer — the indexer's own filter).",
                action: "Unindexed memories cannot be reached through graph recall — re-run the KG indexer and check what stalls it.")
    }
    if let used = memoriesUsedInWindow, let active = memoriesActive, active > 0, used == 0 {
        addLead(rank: 11, "No memory was recorded as used in the \(days)-day window",
                evidence: "memory.sqlite: 0 rows with `last_used_at` >= \(stamp(windowStart)) out of \(active) active memories.",
                action: "Either recall is not stamping `last_used_at`, or recall genuinely never fired — distinguish before concluding.")
    }
    if let l = memoryLatestUpdated, now.timeIntervalSince(l) / 86400 > Double(days) {
        addLead(rank: 20, "Memory store has not been written in \(fmt(now.timeIntervalSince(l) / 86400, 1)) days",
                evidence: "memory.sqlite MAX(updated_at) = \(stamp(l)).",
                action: "Index freshness lag — confirm the memory commit path is still live on chat turns.")
    }
}

line("### Memory-record stamps on cognitive nodes")
line()
if skipStoreSection(cognitionState, "stamped-node counts", "cognition.sqlite",
                    rootPath("cognition/cognition.sqlite")) {
    // section skipped: absent or unreadable, rendered by the helper
} else {
    line("- nodes stamped with `memoryRecordIds`: **\(nodesWithMemoryStamp)** of \(nodesTotal)")
    line("- total stamped record ids: **\(memoryStampedIDTotal)**")
    line()
    if nodesWithMemoryStamp == 0 && nodesTotal > 0 {
        addLead(rank: 9, "No cognitive node carries a `memoryRecordIds` stamp",
                evidence: "cognition.sqlite: 0 of \(nodesTotal) `cognitive_nodes` rows match `%memoryRecordIds%`.",
                action: "The memory-activation attention lane is dead end-to-end — remembered material is not steering context selection.")
    }
}

line("### Per-turn recall and attention rates")
line()
if turnTracesUnreadable {
    unreadable("per-turn recall and attention rates", "turn_traces/")
} else if summaryRowsWindow == 0 {
    line("**source absent** — no `context.summary` rows in the window; per-turn rates are unmeasured.")
    line()
} else {
    func rate(_ name: String, _ values: [Double]) {
        guard !values.isEmpty else {
            line("| \(name) | **source absent** | — | — |")
            return
        }
        let nonzero = values.filter { $0 != 0 }.count
        let mean = values.reduce(0, +) / Double(values.count)
        line("| \(name) | \(fmt(mean, 2)) | \(nonzero)/\(values.count) | \(fmt(Double(nonzero) / Double(values.count) * 100, 1))% |")
    }
    line("| per-turn lane | mean | turns non-zero | non-zero rate |")
    line("|---|---|---|---|")
    rate("memory records selected (`contextFlow.memoryRecords`)", memoryRecordValues)
    rate("context atoms selected (`contextFlow.selectedAtoms`)", atomValues)
    rate("attention working atoms (`contextFlow.attentionWorkingAtoms`)", attentionAtomValues)
    rate("recall row limit (`budget.recallRowLimit`)", recallRowValues)
    line()
    if let s = lanes["counts.memory.recallHits"], s.observationsInWindow > 0, s.nonZeroInWindow == 0 {
        addLead(rank: 7, "`memory.recallHits` is structurally zero on every traced turn",
                evidence: "\(s.observationsInWindow) `context.summary` rows in the \(days)d window, 0 non-zero; "
                    + "last non-zero " + (s.lastNonZeroAt.map { stamp($0) } ?? "never within \(lookbackDays)d") + ".",
                action: "Since 2026-08-21 this lane counts the RESOLVED memory ids (legacy recall ∪ packet provenance), "
                    + "so zero here with `contextFlow.memoryRecords` non-zero means the traces predate that build "
                    + "(reinstall) or the counter regressed; zero on both means recall truly never hits. "
                    + "`memory.recallHits.legacy` is the legacy-only lane and is 0 by design on `.active` turns.")
    }
}

// ── (d) Desk / delegation ────────────────────────────────────────────────────
line("<a id=\"sec-d\"></a>")
line()
line("## (d) Desk, delegation, notifications")
line()
line("### Desk throughput (window)")
line()
if skipFeedSection(deskOpsPresent, "desk throughput", "desk/desk_ops.jsonl", deskOpsPath) {
    // section skipped: absent or unreadable, rendered by the helper
} else if deskOpsInWindow == 0 {
    line("**No desk ops in the window.** \(sources.entries.first { $0.label == "desk/desk_ops.jsonl" }?.rows ?? 0) ops exist in the log overall; none carry a `ts` inside \(stamp(windowStart)) → now.")
    line()
    addLead(rank: 18, "Desk saw no operations in the last \(days) days",
            evidence: "`desk/desk_ops.jsonl`: 0 rows with `ts` >= \(stamp(windowStart)).",
            action: "For an organizer, a silent desk is the headline symptom — confirm the desk surface is reachable.")
} else {
    let filed = deskOpCounts["create_item"] ?? 0
    let closed = (deskOpCounts["close_item"] ?? 0) + (deskOpCounts["archive_item"] ?? 0)
    line("- ops in window: **\(deskOpsInWindow)**")
    line("- cards **filed**: \(filed) · cards **resolved** (close+archive): \(closed) · net: \(filed - closed >= 0 ? "+" : "")\(filed - closed)")
    line()
    line("| op | count |")
    line("|---|---|")
    for (op, c) in deskOpCounts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) { line("| `\(mdCode(op))` | \(c) |") }
    line()
    if filed > closed * 2 && filed >= 3 {
        addLead(rank: 16, "Desk is filing faster than it resolves (\(filed) filed vs \(closed) resolved)",
                evidence: "`desk/desk_ops.jsonl` in \(days)d: create_item=\(filed), close_item+archive_item=\(closed).",
                action: "Backlog is accumulating — surface the oldest open cards in her next check-in.")
    }
}

line("### Learned Desk cadence")
line()
if sources.isUnreadable("desk/cadence_stats.json") {
    unreadable("learned Desk cadence", "desk/cadence_stats.json")
} else if !cadenceStatsPresent {
    absent("learned Desk cadence", cadenceStatsPath)
} else {
    line("- tracked refs: **\(cadenceStatsRefs)** · confident learned intervals: **\(cadenceStatsConfidentRefs)**")
    line("- observations across refs: **\(cadenceStatsObservations)** · recorded changes: **\(cadenceStatsChanges)**")
    line("- newest observation: **\(cadenceStatsNewestObservedAt.map(stamp) ?? "unknown")**"
         + (cadenceStatsMissingObservedStamp > 0 ? " · \(cadenceStatsMissingObservedStamp) row(s) carry no usable `lastObservedAt`" : ""))
    line("- intervals pinned at a learner bound: **\(cadenceStatsPinnedFloor)** at 15m floor · **\(cadenceStatsPinnedCeiling)** at 24h ceiling")
    if cadenceStatsInvalidRows > 0 {
        line("- malformed ref rows ignored: **\(cadenceStatsInvalidRows)**")
    }
    line()

    if deskOpsInWindow > 0,
       cadenceStatsNewestObservedAt == nil || cadenceStatsNewestObservedAt! < windowStart {
        addLead(rank: 9, "Desk cadence stats stopped updating while desk work continued",
                evidence: "`desk/desk_ops.jsonl` has \(deskOpsInWindow) in-window operation(s), while `desk/cadence_stats.json` newest `lastObservedAt` is \(cadenceStatsNewestObservedAt.map(stamp) ?? "unknown") (before \(stamp(windowStart))).",
                action: "Check the refresh observation writer. Desk polling may be timing itself from a stale learned rhythm.")
    }
    if cadenceStatsPinnedFloor + cadenceStatsPinnedCeiling > 0 {
        addLead(rank: 12, "Desk cadence learner is pinned at a timing bound",
                evidence: "`desk/cadence_stats.json`: \(cadenceStatsPinnedFloor) confident ref(s) resolve to the 15m floor and \(cadenceStatsPinnedCeiling) to the 24h ceiling.",
                action: "Inspect those refs' observed change rhythm; persistent saturation can make Desk polling needlessly eager or nearly dormant.")
    }
}

line("### Trigger scheduler claim state")
line()
if sources.isUnreadable("triggers/trigger_state.json") {
    unreadable("canonical trigger claim state", "triggers/trigger_state.json")
} else if !triggerStatePresent {
    absent("canonical trigger claim state", triggerStatePath)
} else {
    let stampedStates = triggerStateRows.compactMap { $0.lastFiredAt }.count
    line("- canonical state entries: **\(triggerStateRows.count)** · usable `last_fired_at` stamps: **\(stampedStates)**")
    line("- newest canonical claim: **\(triggerStateNewest.map(stamp) ?? "unknown")**")
    if sources.isUnreadable("triggers/trigger_config.json") {
        line("- enabled time triggers: **source unreadable** — freshness is not inferred")
    } else if !triggerConfigPresent {
        line("- enabled time triggers: **source absent** — freshness is not inferred")
    } else {
        let names = enabledTimeTriggerNames.sorted()
        line("- enabled time triggers: **\(names.count)**" + (names.isEmpty ? "" : " (`\(names.map(mdCode).joined(separator: "`, `"))`)") )
    }
    if triggerStateInvalidEntries > 0 {
        line("- invalid state entries: **\(triggerStateInvalidEntries)**")
    }
    if !triggerStateRows.isEmpty {
        line()
        line("| canonical trigger | last fired at | age |")
        line("|---|---|---|")
        for row in triggerStateRows.sorted(by: { $0.name < $1.name }) {
            let when = row.lastFiredAt.map(stamp) ?? "unknown"
            let age = row.lastFiredAt.map(ageHoursText) ?? "unknown"
            line("| `\(mdCode(row.name))` | \(when) | \(age) |")
        }
    }
    line()

    let enabledStateNewest = triggerStateRows
        .filter { enabledTimeTriggerNames.contains($0.name) }
        .compactMap { $0.lastFiredAt }
        .max()
    if !sources.isUnreadable("triggers/trigger_config.json"),
       triggerConfigPresent,
       !enabledTimeTriggerNames.isEmpty,
       let enabledStateNewest,
       now.timeIntervalSince(enabledStateNewest) > triggerStateStaleHours * 3600 {
        addLead(rank: 10, "Canonical trigger claims have not advanced for enabled time triggers",
                evidence: "`triggers/trigger_state.json` newest stamp for \(enabledTimeTriggerNames.count) enabled canonical time trigger(s) is \(stamp(enabledStateNewest)), older than the named \(fmt(triggerStateStaleHours, 0))h bound.",
                action: "Inspect the periodic trigger scheduler and its canonical `triggers/` files. The frozen `inbox/trigger_state.json` is not liveness evidence.")
    }
    if triggerStateInvalidEntries > 0 {
        addLead(rank: 11, "Canonical trigger state has invalid claim entries",
                evidence: "`triggers/trigger_state.json` has \(triggerStateInvalidEntries) entry field(s) without a usable `last_fired_at` stamp.",
                action: "Repair the affected canonical state entries; an invalid claim can make liveness and duplicate suppression unreliable.")
    }
}

line("### Backup generations")
line()
if sources.isUnreadable("backups/registry.json") {
    unreadable("backup registry", "backups/registry.json")
} else if !backupRegistryPresent {
    absent("backup registry", backupRegistryPath)
} else if let id = backupNewestID {
    line("- registry generations: **\(backupRegistryRows)/\(backupGenerationCeiling)**")
    line("- newest generation: `\(mdCode(id))` — \(backupNewestCreatedAt.map(stamp) ?? "unknown") (\(backupNewestFormat ?? "unknown format"))")
    line("- claimed components: **\(backupClaimedComponents)** · present: **\(backupPresentComponents)** · missing: **\(backupMissingComponents.count)**")
    line("- verified file members: **\(backupVerifiedFiles)** · zero-byte: **\(backupZeroByteFiles.count)**")
    if !backupMissingComponents.isEmpty {
        line("- missing or invalid: " + backupMissingComponents.sorted().prefix(8).map { "`\(mdCode($0))`" }.joined(separator: ", "))
    }
    if !backupZeroByteFiles.isEmpty {
        line("- zero-byte: " + backupZeroByteFiles.sorted().prefix(8).map { "`\(mdCode($0))`" }.joined(separator: ", "))
    }
    if backupRegistryInvalidRows > 0 {
        line("- invalid registry rows ignored: **\(backupRegistryInvalidRows)**")
    }
    line()

    if backupRegistryRows > backupGenerationCeiling {
        addLead(rank: 13, "Backup registry exceeded its \(backupGenerationCeiling)-generation retention bound",
                evidence: "`backups/registry.json` contains \(backupRegistryRows) valid generations; the writer retains at most \(backupGenerationCeiling).",
                action: "Inspect the backup registry writer and retention path before the recovery inventory grows without bound.")
    }
    if !backupMissingComponents.isEmpty || !backupZeroByteFiles.isEmpty {
        addLead(rank: 6, "Newest backup generation is incomplete or contains zero-byte data",
                evidence: "`backups/registry.json` newest `\(id)` claims \(backupClaimedComponents) component(s): \(backupMissingComponents.count) missing/invalid and \(backupZeroByteFiles.count) zero-byte file(s).",
                action: "Create and validate a new backup before relying on restore. A registry row alone is not recoverability evidence.")
    }
} else {
    line("**No valid backup generations** — `backups/registry.json` parsed, but no row carried a valid UUID, timestamp, and scope.")
    line()
    addLead(rank: 8, "Backup registry contains no valid recoverable generation",
            evidence: "`backups/registry.json` has \(backupRegistryInvalidRows) invalid row(s) and 0 valid generation(s).",
            action: "Create a verified backup before any restore-dependent change.")
}

line("### Desk backlog (current state)")
line()
if !deskStatePresent {
    absent("desk backlog", deskStatePath)
} else {
    line("- items: **\(deskItemsTotal)** — " + deskStatusCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .map { "`\(mdCode($0.key))`=\($0.value)" }.joined(separator: ", "))
    // Oldest first, TIES ON TITLE. Desk items created in the same import land
    // on the same age to the day; without the tiebreak the "oldest is Nd — X"
    // lead names a different item between two runs over identical bytes.
    let stale = deskOpenAging.filter { $0.1 >= 30 }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    line("- open items ≥30 days old: **\(stale.count)**")
    if !stale.isEmpty {
        line()
        for (title, age) in stale.prefix(5) { line("  - \(fmt(age, 0))d — \(mdText(String(title.prefix(90))))") }
        addLead(rank: 17, "\(stale.count) desk item(s) have been open ≥30 days",
                evidence: "`desk/desk_state.json`: oldest is \(fmt(stale[0].1, 0))d — \(mdText(String(stale[0].0.prefix(70)))).",
                action: "Stale cards make the desk untrustworthy — close, defer with a date, or archive them.")
    }
    line()
}

line("### Delegation")
line()
if skipFeedSection(ledgerPresent, "delegation outcomes", "orchestration/task_ledger.jsonl", ledgerPath) {
    // section skipped: absent or unreadable, rendered by the helper
} else {
    if !delegationHasStatusField {
        line("Note: `orchestration/task_ledger.jsonl` rows carry **no `status` field** — the ledger is")
        line("append-only event rows keyed by `kind`. Outcomes are grouped by `kind` below rather than")
        line("invented as statuses.")
        line()
    }
    if delegationRowsWindow == 0 {
        line("**No delegation rows in the window** (\(sources.entries.first { $0.label == "orchestration/task_ledger.jsonl" }?.rows ?? 0) rows in the log overall, all older than \(stamp(windowStart))).")
        line()
    } else {
        line("| kind | count |")
        line("|---|---|")
        for (k, c) in delegationKinds.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) { line("| `\(mdCode(k))` | \(c) |") }
        line()
    }
}

line("### Workflow run ledger (RETIRED 2026-09-01 — frozen history)")
line()
line("The workflow run engine was retired on 2026-09-01 (User authorized). `runs.jsonl` and `run_state/*.json` are kept as history and are read by nothing; `registry.json` is still live for the workflow list. Nothing below is an in-flight condition or an action item.")
line()
if !workflowRegistryFeed.didRead && !workflowRunsFeed.didRead && !workflowRunStateFeed.didRead {
    line("**workflow ledger sources unavailable** — no workflow activity is reported as zero.")
    line("- registry: \(workflowRegistryFeed.blockedLabel ?? "source absent")")
    line("- runs: \(workflowRunsFeed.blockedLabel ?? "source absent")")
    line("- run state: \(workflowRunStateFeed.blockedLabel ?? "source absent")")
    line()
} else {
    let registryReading: String
    if workflowRegistryFeed.didRead {
        registryReading = "\(workflowRegistryStatuses.values.reduce(0, +)) row(s)"
            + (workflowRegistryStatuses.isEmpty ? "" : " (\(topCounts(workflowRegistryStatuses, 8)))")
    } else {
        registryReading = workflowRegistryFeed.blockedLabel ?? "source absent"
    }
    let runsReading: String
    if workflowRunsFeed.didRead {
        runsReading = "\(workflowRunStatuses.values.reduce(0, +)) retained row(s)"
            + (workflowRunStatuses.isEmpty ? "" : " (\(topCounts(workflowRunStatuses, 8)))")
            + (workflowRunNewest.map { "; newest \(stamp($0)) (\(ageDaysText($0)) ago)" } ?? "")
    } else {
        runsReading = workflowRunsFeed.blockedLabel ?? "source absent"
    }
    let stateReading: String
    if workflowRunStateFeed.didRead {
        stateReading = "\(workflowRunStateStatuses.values.reduce(0, +)) state file(s)"
            + (workflowRunStateStatuses.isEmpty ? "" : " (\(topCounts(workflowRunStateStatuses, 8)))")
            + "; unchanged >1h: \(workflowOldApprovalWaits.count) approval wait(s), \(workflowOldPersistedAttempts.count) persisted attempt(s), \(workflowStaleNonTerminalStates.count) other non-terminal"
    } else {
        stateReading = workflowRunStateFeed.blockedLabel ?? "source absent"
    }
    line("- registry: \(registryReading)")
    line("- runs: \(runsReading)")
    line("- run state: \(stateReading)")
    if workflowRegistryFeed.didRead, !workflowUnsupportedKinds.isEmpty {
        line("- **unsupported step kinds:** \(topCounts(workflowUnsupportedKinds, 12))")
    }
    if !workflowStaleNonTerminalStates.isEmpty {
        line("- other non-terminal state ids unchanged >1h: \(workflowStaleNonTerminalStates.prefix(12).map { "`\(mdCode($0))`" }.joined(separator: ", "))")
    }
    if !workflowOldApprovalWaits.isEmpty {
        line("- approval wait ids unchanged >1h, no persisted active attempt: \(workflowOldApprovalWaits.prefix(12).map { "`\(mdCode($0))`" }.joined(separator: ", ")). Historical approval waits are not evidence of in-flight dispatch or a missed drain deadline; review through the approval owner, not by resending work.")
    }
    if !workflowOldPersistedAttempts.isEmpty {
        line("- persisted attempt ids unchanged >1h: \(workflowOldPersistedAttempts.prefix(12).map { "`\(mdCode($0))`" }.joined(separator: ", "))")
    }
    line()
}

line("### Notification receipts (window)")
line()
if skipFeedSection(inboxPresent, "notification receipts", "notifications/inbox.jsonl", inboxPath) {
    // section skipped: absent or unreadable, rendered by the helper
} else if notifyStatusWindow.isEmpty {
    line("**No notifications created in the window** (\(notifyUnreadTotal) unread across the whole log).")
    line()
} else {
    line("| status | count |")
    line("|---|---|")
    for (s, c) in notifyStatusWindow.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) { line("| `\(mdCode(s))` | \(c) |") }
    line()
    line("- severities: " + notifySeverityWindow.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .map { "`\(mdCode($0.key))`=\($0.value)" }.joined(separator: ", "))
    line("- unread across the whole inbox: **\(notifyUnreadTotal)**")
    line()
}
if inboxPresent && notifyUnreadTotal >= 25 {
    addLead(rank: 13, "\(notifyUnreadTotal) notifications sit unread",
            evidence: "`notifications/inbox.jsonl`: \(notifyUnreadTotal) rows with `status=\"unread\"`.",
            action: "An unread pile that large means the channel is being ignored — cut volume or add a real resolve lever per card.")
}
if !notifyErrorSignatures.isEmpty {
    line("- error-signature clusters in window: " + notifyErrorSignatures.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .prefix(6).map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
    line()
    if let top = notifyErrorSignatures.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first, top.value >= 3 {
        addLead(rank: 13, "Repeating error notification `\(mdCode(top.key))` (×\(top.value) in window)",
                evidence: "`notifications/inbox.jsonl`: \(top.value) rows with `error_signature=\"\(mdCode(top.key))\"` since \(stamp(windowStart)).",
                action: "A repeated error card is a real defect the user is being asked to absorb — fix the source or suppress the duplicate.")
    }
}

// ── (e) Cost / latency ───────────────────────────────────────────────────────
line("<a id=\"sec-e\"></a>")
line()
line("## (e) Cost and latency per surface")
line()
if skipFeedSection(eventsPresent, "LLM cost and latency", "traces/events.jsonl", eventsPath) {
    // section skipped: absent or unreadable, rendered by the helper
} else if llmCallsInWindow == 0 {
    line("**No `llm.call` rows in the window.** The file holds \(llmRowsTotal) `llm.call` rows overall"
         + (llmEarliest.map { ", spanning \(stamp($0)) → \(stamp(llmLatest ?? $0))" } ?? "")
         + ". This is a window/retention fact, not a zero-cost claim.")
    line()
    addLead(rank: 19, "LLM telemetry has no rows inside the \(days)-day window",
            evidence: "`traces/events.jsonl`: \(llmRowsTotal) llm.call rows, newest "
                + (llmLatest.map { stamp($0) } ?? "unknown") + ".",
            action: "Either telemetry stopped writing or the file was rotated — confirm before reading any cost number.")
} else {
    line("- `llm.call` rows in window: **\(llmCallsInWindow)** of \(llmRowsTotal) in the file")
    line()
    line("| surface | calls | in tok | out tok | cache read | cache create | p50 ms | p95 ms | p50 ttft | substituted |")
    line("|---|---|---|---|---|---|---|---|---|---|")
    // Busiest surface first, TIES ON SURFACE NAME — several surfaces sit on
    // one or five calls, and Dictionary order is per-process.
    for (surface, s) in surfaceStats.sorted(by: {
        $0.value.calls == $1.value.calls ? $0.key < $1.key : $0.value.calls > $1.value.calls
    }) {
        let d = s.durations.sorted(), t = s.ttfts.sorted()
        line("| `\(mdCode(surface))` | \(s.calls) | \(s.inputTokens) | \(s.outputTokens) | \(s.cacheRead) | \(s.cacheCreation) | "
             + "\(fmt(percentile(d, 0.5), 0)) | \(fmt(percentile(d, 0.95), 0)) | \(t.isEmpty ? "—" : fmt(percentile(t, 0.5), 0)) | "
             + "\(s.substituted > 0 ? "**\(s.substituted)**" : "0") |")
    }
    line()
    for (surface, s) in surfaceStats.sorted(by: { $0.value.calls > $1.value.calls }) {
        if s.substituted > 0 {
            let pairs = s.substitutionPairs.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\(mdText($0.key))×\($0.value)" }.joined(separator: ", ")
            line("- ⚠︎ surface `\(mdCode(surface))`: \(s.substituted) call(s) carry `substitutedFrom` — \(pairs)")
            addLead(rank: 12, "Model substitution on surface `\(mdCode(surface))` (\(s.substituted) call(s))",
                    evidence: "`traces/events.jsonl` llm.call rows in window with `substitutedFrom`: \(pairs).",
                    action: "A silent model swap changes who she is on that surface — confirm the routing policy intends it.")
        }
    }
    if surfaceStats.contains(where: { $0.value.substituted > 0 }) { line() }

    // Cost outlier: a surface whose token spend per call is far above the median surface.
    let perCall = surfaceStats.compactMap { (k, v) -> (String, Double)? in
        guard v.calls > 0 else { return nil }
        return (k, Double(v.inputTokens + v.outputTokens + v.cacheRead + v.cacheCreation) / Double(v.calls))
    }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    if perCall.count >= 2, let top = perCall.first {
        let median = perCall[perCall.count / 2].1
        if median > 0, top.1 > median * 3 {
            addLead(rank: 21, "Surface `\(mdCode(top.0))` costs \(fmt(top.1 / median, 1))× the median surface per call",
                    evidence: "llm.call window totals: \(fmt(top.1, 0)) tokens/call on `\(mdCode(top.0))` vs median \(fmt(median, 0)) tokens/call across \(perCall.count) surfaces.",
                    action: "Check what that surface prepends — a churning prefix defeats prompt caching and multiplies cost.")
        }
    }
    // Latency outlier.
    let allDurations = surfaceStats.values.flatMap { $0.durations }.sorted()
    if !allDurations.isEmpty {
        line("- all surfaces combined: p50 \(fmt(percentile(allDurations, 0.5), 0)) ms, p95 \(fmt(percentile(allDurations, 0.95), 0)) ms, max \(fmt(allDurations.last ?? 0, 0)) ms")
        line()
        for (surface, s) in surfaceStats where s.durations.count >= 5 {
            let p95 = percentile(s.durations.sorted(), 0.95)
            if p95 > 60_000 {
                addLead(rank: 23, "Surface `\(mdCode(surface))` p95 latency is \(fmt(p95 / 1000, 1)) s",
                        evidence: "\(s.durations.count) llm.call durations on `\(mdCode(surface))` in window; p95 = \(fmt(p95, 0)) ms.",
                        action: "For a companion surface this reads as unresponsive — check streaming and tool round-trips there.")
            }
        }
    }
    if !modelCountsFromSnapshots.isEmpty {
        line("- models seen on traced turns: " + modelCountsFromSnapshots.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "`\(mdCode($0.key))`=\($0.value)" }.joined(separator: ", "))
        line()
    }
}

// ── (f) Turn speed ───────────────────────────────────────────────────────────
line("<a id=\"sec-f\"></a>")
line()
line("## (f) Turn speed — end-to-end latency and where it goes")
line()
if skipFeedSection(turnTracesPresent, "turn latency", "turn_traces/", turnTraceDir) {
    // section skipped: absent or unreadable, rendered by the helper
} else if turnEvidenceTurns.isEmpty {
    line("**source absent** — `turn_traces/` produced neither a positive paired accepted→terminal interval nor a terminal payload clock")
    line("inside the \(runtimeEvidenceLabel), so current end-to-end turn latency is unmeasured. This is not \"0 ms\";")
    line("\(turnRowsSeen) timing row(s) of other kinds were seen.")
    if excludedEarlierBuildTurns > 0 {
        line("\(excludedEarlierBuildTurns) completed turn(s) from earlier installed builds remain in the retained \(days)-day history and are intentionally excluded from current-build diagnosis.")
    }
    line()
} else {
    let allElapsed = turnEvidenceTurns.compactMap { $0.elapsedMs }.sorted()
    let pairedCount = turnEvidenceTurns.filter { $0.lifecycleElapsedMs != nil }.count
    line("End-to-end timing uses paired `turn.accepted`→`turn.terminal` timestamps (**\(pairedCount)/\(turnEvidenceTurns.count)** turns).")
    line("`turn.terminal.payload.turnElapsedMs` is a distinct engine clock: structured tool-loop turns can exclude prebuilt context assembly.")
    line("Where a positive lifecycle interval is unavailable, latency statistics retain the payload clock as a **scope unknown fallback**, not accepted-to-terminal proof.")
    line("Assembly, provider, and tool durations are observations, not proven disjoint buckets; no percentage partition is inferred from their sum.")
    line()
    line("- turns in diagnostic cohort (\(runtimeEvidenceLabel)): **\(turnEvidenceTurns.count)**")
    if excludedEarlierBuildTurns > 0 {
        line("- earlier-build turns excluded from current diagnosis: **\(excludedEarlierBuildTurns)**")
    }
    line("- all surfaces: p50 **\(fmt(percentile(allElapsed, 0.5) / 1000, 2)) s**, "
         + "p95 **\(fmt(percentile(allElapsed, 0.95) / 1000, 2)) s**, "
         + "max \(fmt((allElapsed.last ?? 0) / 1000, 2)) s")
    line()

    line("### Per surface")
    line()
    line("| surface | turns | p50 s | p95 s | max s | mean model s | mean tool s | mean assembly ms | mean tool calls |")
    line("|---|---|---|---|---|---|---|---|---|")
    for (surface, rows) in turnsBySurface.sorted(by: {
        $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
    }) {
        let e = rows.compactMap { $0.elapsedMs }.sorted()
        guard !e.isEmpty else { continue }
        let model = rows.map { $0.modelMs }.reduce(0, +) / Double(rows.count)
        let tool = rows.map { $0.toolMs }.reduce(0, +) / Double(rows.count)
        let asmSamples = rows.compactMap { $0.assemblyMs }
        let asm = asmSamples.isEmpty ? Double.nan : asmSamples.reduce(0, +) / Double(asmSamples.count)
        let calls = Double(rows.map { $0.toolCalls }.reduce(0, +)) / Double(rows.count)
        line("| `\(mdCode(surface))` | \(rows.count) | \(fmt(percentile(e, 0.5) / 1000, 2)) | \(fmt(percentile(e, 0.95) / 1000, 2)) | "
             + "\(fmt((e.last ?? 0) / 1000, 2)) | \(fmt(model / 1000, 2)) | \(fmt(tool / 1000, 2)) | "
             + "\(asm.isNaN ? "source absent" : fmt(asm, 0)) | \(fmt(calls, 1)) |")
    }
    line()

    line("### Where the time goes")
    line()
    let attributable = turnEvidenceTurns.filter { ($0.elapsedMs ?? 0) > 0 }
    if attributable.isEmpty {
        line("**source absent** — no turn has a positive lifecycle or payload clock.")
        line()
    } else {
        let paired = attributable.filter { $0.lifecycleElapsedMs != nil }
        let totalElapsed = paired.compactMap { $0.lifecycleElapsedMs }.reduce(0, +)
        let totalPayload = attributable.compactMap { $0.terminalPayloadMs }.reduce(0, +)
        let totalModel = attributable.map { $0.modelMs }.reduce(0, +)
        let totalTool = attributable.map { $0.toolMs }.reduce(0, +)
        let totalAsm = attributable.compactMap { $0.assemblyMs }.reduce(0, +)
        let asmCoverage = attributable.filter { $0.assemblyMs != nil }.count
        // Compare only known lifecycle scopes. A sum exceeding wall clock does
        // not establish overlap, late work, or a broken terminal milestone.
        let exceeding = paired.filter {
            ($0.modelMs + $0.toolMs + ($0.assemblyMs ?? 0)) > ($0.lifecycleElapsedMs ?? 0)
        }
        line("| bucket | total s | mean s/turn | measured from |")
        line("|---|---|---|---|")
        func meanS(_ total: Double) -> String { fmt(total / Double(attributable.count) / 1000, 2) }
        line("| context / prompt assembly | \(fmt(totalAsm / 1000, 1)) | \(meanS(totalAsm)) | `context.summary.totalMs` (present on \(asmCoverage)/\(attributable.count) turns) |")
        line("| model (provider round trips) | \(fmt(totalModel / 1000, 1)) | \(meanS(totalModel)) | sum of `llm.call.durationMs` |")
        line("| tools | \(fmt(totalTool / 1000, 1)) | \(meanS(totalTool)) | sum of `tool.dispatch.durationMs` (phase=end) |")
        if !paired.isEmpty {
            line("| **paired accepted→terminal** | \(fmt(totalElapsed / 1000, 3)) | \(fmt(totalElapsed / Double(paired.count) / 1000, 3)) | lifecycle timestamps, \(paired.count)/\(attributable.count) turns; \(fmt(totalElapsed, 0)) ms total |")
        } else {
            line("| paired accepted→terminal | source absent | source absent | no positive paired lifecycle interval |")
        }
        line("| terminal payload clock (not additive) | \(fmt(totalPayload / 1000, 3)) | \(meanS(totalPayload)) | `turn.terminal.turnElapsedMs`; may exclude prebuilt assembly, scope unknown without producer context |")
        line()
        if !exceeding.isEmpty {
            let sum = exceeding.map { $0.modelMs + $0.toolMs + ($0.assemblyMs ?? 0) }.reduce(0, +)
            let wall = exceeding.compactMap { $0.lifecycleElapsedMs }.reduce(0, +)
            addLead(rank: 16, "\(exceeding.count) turns need timing-scope attribution before duration sums can be partitioned",
                    evidence: "On those turns: paired lifecycle \(fmt(wall, 0)) ms; model+tool+assembly sum \(fmt(sum, 0)) ms; excess \(fmt(sum - wall, 0)) ms.",
                    action: "Inspect producer interval boundaries and event ordering. A duration sum alone cannot prove post-terminal work, concurrent execution, or a broken terminal clock.")
        }
        let ttfts = attributable.compactMap { $0.firstTtftMs }.sorted()
        if !ttfts.isEmpty {
            line("- first-token latency (what she *feels* like to talk to): p50 **\(fmt(percentile(ttfts, 0.5) / 1000, 2)) s**, "
                 + "p95 **\(fmt(percentile(ttfts, 0.95) / 1000, 2)) s** over \(ttfts.count) turn(s)")
            line()
        }
    }

    line("### Assembly stages (`context.summary.stageMs.*`)")
    line()
    if stageRows.isEmpty {
        line("**source absent** — no `stageMs` object in any `context.summary` row in the lookback.")
        line()
    } else {
        line("All-zero stages are **DARK** (timing unresolved), not proof of a broken clock. Integer-millisecond timing can quantize fast work to zero.")
        line("Known actor-free attention admission is exempt: its integer clock commonly rounds below 1 ms to zero.")
        line()
        line("| stage | samples | non-zero | p50 ms | p95 ms | max ms | state |")
        line("|---|---|---|---|---|---|---|")
        // Dark stages first, then slowest, TIES ON STAGE NAME: every dark
        // stage has p95 0, so without the name tiebreak the dark block itself
        // reshuffles between runs.
        for r in stageRows.sorted(by: {
            ($0.dark ? 0 : 1, -$0.p95, $0.name) < ($1.dark ? 0 : 1, -$1.p95, $1.name)
        }) {
            if r.dark {
                let last = r.lastNonZero.map { "last non-zero \(stamp($0))" } ?? "never in \(lookbackDays)d lookback"
                line("| `\(mdCode(r.name))` | \(r.samples) | 0 | dark | dark | dark | **DARK** — \(last) |")
            } else if r.samples == 0 {
                line("| `\(mdCode(r.name))` | 0 | 0 | source absent | source absent | source absent | not emitted in window |")
            } else {
                line("| `\(mdCode(r.name))` | \(r.samples) | \(r.nonZero) | \(fmt(r.p50, 0)) | \(fmt(r.p95, 0)) | \(fmt(r.maxMs, 0)) | live |")
            }
        }
        line()
        for r in darkStages {
            let last = r.lastNonZero.map { "last non-zero \(stamp($0)) (\(fmt(now.timeIntervalSince($0) / 86400, 1))d ago)" }
                ?? "never within the \(lookbackDays)d lookback"
            addLead(rank: 14, "Assembly stage `stageMs.\(mdCode(r.name))` is DARK — timing needs interpretation",
                    evidence: "\(r.samples) `context.summary` sample(s) in the \(days)d window, all exactly 0; \(last). "
                        + "This may be sub-millisecond work, an unused stage, or missing instrumentation; zero alone cannot distinguish them.",
                    action: "Inspect this stage's clock resolution and whether it ran before diagnosing missing timing. Use higher-resolution timing if this stage needs measurement.")
        }
    }

    line("### Per-day trend (is she getting slower?)")
    line()
    let dayKeys = turnsByDay.keys.sorted()
    if dayKeys.count < 2 {
        line("**not enough days** — \(dayKeys.count) day(s) with terminal rows in the window; a trend needs ≥2.")
        line()
    } else {
        line("| day | turns | p50 s | p95 s | max s | mean tool calls |")
        line("|---|---|---|---|---|---|")
        for d in dayKeys {
            let rows = turnsByDay[d] ?? []
            let e = rows.compactMap { $0.elapsedMs }.sorted()
            guard !e.isEmpty else { continue }
            let calls = Double(rows.map { $0.toolCalls }.reduce(0, +)) / Double(rows.count)
            line("| \(d) | \(rows.count) | \(fmt(percentile(e, 0.5) / 1000, 2)) | \(fmt(percentile(e, 0.95) / 1000, 2)) | "
                 + "\(fmt((e.last ?? 0) / 1000, 2)) | \(fmt(calls, 1)) |")
        }
        line()
        // Split the window in half and compare p95 — a coarse but honest slope.
        let half = dayKeys.count / 2
        let earlyDays = Array(dayKeys.prefix(half))
        let lateDays = Array(dayKeys.suffix(dayKeys.count - half))
        let early = earlyDays.flatMap { turnsByDay[$0] ?? [] }.compactMap { $0.elapsedMs }.sorted()
        let late = lateDays.flatMap { turnsByDay[$0] ?? [] }.compactMap { $0.elapsedMs }.sorted()
        if early.count >= 5 && late.count >= 5 {
            let e95 = percentile(early, 0.95), l95 = percentile(late, 0.95)
            let delta = e95 > 0 ? (l95 / e95) : Double.nan
            line("- first half (\(earlyDays.joined(separator: ", "))): p95 \(fmt(e95 / 1000, 2)) s over \(early.count) turns")
            line("- second half (\(lateDays.joined(separator: ", "))): p95 \(fmt(l95 / 1000, 2)) s over \(late.count) turns")
            line("- p95 slope: **\(delta.isNaN ? "n/a" : fmt(delta, 2) + "×")**")
            line()
            if !delta.isNaN, delta >= 1.5 {
                addLead(rank: 11, "Turn p95 latency is \(fmt(delta, 1))× worse in the second half of the window",
                        evidence: "turn.terminal p95: \(fmt(e95 / 1000, 2)) s over \(early.count) turns (\(earlyDays.joined(separator: ", "))) "
                            + "→ \(fmt(l95 / 1000, 2)) s over \(late.count) turns (\(lateDays.joined(separator: ", "))).",
                        action: "Something got slower inside the window. Compare the per-surface and per-stage rows above "
                            + "for the same split before blaming the model — tool-call count per turn moves this number hardest.")
            }
        } else {
            line("- p95 slope: **not computed** — one half of the window has <5 turns "
                 + "(\(early.count) early / \(late.count) late). Reporting a slope off that would be noise.")
            line()
        }
    }

    // Slow-surface lead uses the preferred available clock, labeling fallback
    // scope instead of silently promoting an engine timer to end-to-end proof.
    for (surface, rows) in turnsBySurface where rows.count >= 5 {
        let e = rows.compactMap { $0.elapsedMs }.sorted()
        guard !e.isEmpty else { continue }
        let p95 = percentile(e, 0.95)
        if p95 > 120_000 {
            addLead(rank: 19, "Surface `\(mdCode(surface))` observed turn-clock p95 is \(fmt(p95 / 1000, 1)) s",
                    evidence: "\(e.count) timed turns on `\(mdCode(surface))` in the \(days)d window; p95 = \(fmt(p95, 0)) ms. Paired lifecycle is preferred; unpaired payload clocks have unknown scope.",
                    action: "Two minutes is past the point a companion feels present. Check the tool-call count per turn "
                        + "and the producer timing boundaries before assigning the delay to a subsystem.")
        }
    }
    let failedTurns = turnEvidenceTurns.filter { $0.status != nil && $0.status != "completed" }
    if !failedTurns.isEmpty {
        let byStatus = Dictionary(grouping: failedTurns, by: { $0.status ?? "?" }).mapValues { $0.count }
        line("- non-completed terminal statuses in window: " + byStatus.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
        line()
    }
}

// ── (g) Coverage matrix ──────────────────────────────────────────────────────
line("<a id=\"sec-g\"></a>")
line()
line("## (g) Coverage matrix — the subsystem map vs what this instrument measures")
line()
line("Hand-maintained inventory of `docs/SUBCONSCIOUS.md`'s subsystem map. The reach walk in")
line("[(i)](#sec-i) answers *\"is there a store nobody reads?\"*; this table answers the harder question:")
line("*\"is there a **subsystem** nobody measures?\"* — including the ones whose state never lands in a")
line("file at all. Every `partial` / `not-yet` row carries the reason it is not `measured`.")
line()
line("**\(coverageMeasured) measured · \(coveragePartial) partial · \(coverageNotYet) not-yet** "
     + "across \(coverage.count) subsystems.")
line()
line("| # | subsystem | status | measured from | reading |")
line("|---|---|---|---|---|")
for r in coverage {
    let badge: String
    switch r.status {
    case .measured: badge = "measured"
    case .partial: badge = "**partial**"
    case .notYet: badge = "**not-yet**"
    }
    line("| \(r.id) | \(mdComposed(r.subsystem)) | \(badge) | \(mdComposed(r.source)) | \(mdComposed(r.measurement)) |")
}
line()
let gaps = coverage.filter { $0.status != .measured }
if !gaps.isEmpty {
    line("### Why the non-`measured` rows are not measured")
    line()
    for r in gaps {
        line("- **\(r.id) \(mdComposed(r.subsystem))** (\(r.status.rawValue)) — \(mdComposed(r.reason))")
    }
    line()
}
if coverageNotYet > 0 {
    let names = coverage.filter { $0.status == .notYet }.map { "\($0.id) \($0.subsystem)" }
    addLead(rank: 27, "\(coverageNotYet) documented subsystem(s) have no measurement at all",
            evidence: "Coverage matrix not-yet rows: " + names.joined(separator: "; ") + ".",
            action: "Each is a producer gap, not a reader gap — nothing in the data root carries the state. "
                + "Deciding whether to emit it is a design call, not an instrument fix.")
}

// ── (h) System matrix (SYS) ──────────────────────────────────────────────────
//
// Sections (a)–(g) grade the COGNITIVE system. This one grades the FUNCTIONAL
// system: the eight organs read by the SYS-01..08 readers above. One row per
// organ, each carrying (1) a status, (2) the source(s) it was measured from,
// and (3) a one-line LIVE reading. An organ whose feeds did not read renders
// `source absent` / `source unreadable` in place of every number, per the same
// house rule the rest of the report obeys: "we could not read it" and "it is
// zero" are different facts and this instrument never conflates them.

/// Four states, not three. `absent` and `unreadable` are separated because the
/// house rule separates them everywhere else, and because they rank
/// differently in the severity order below.
enum SysStatus: String {
    case measured, partial, absent, unreadable
    var badge: String {
        switch self {
        case .measured: return "measured"
        case .partial: return "**partial**"
        case .absent: return "**absent**"
        case .unreadable: return "**UNREADABLE**"
        }
    }
}

/// THE SEVERITY RULE, in one place, lowest value = worst. It is deliberately
/// simple and total, so "worst organ" is reproducible rather than a judgment
/// call re-argued per run:
///
///   0 unreadable      — a feed exists and could not be read. Worst, because
///                       every number for that organ is unknown AND something
///                       is actively wrong with the file or its writer.
///   1 absentExpected  — the organ's feeds are not on disk at all. Second,
///                       because the organ is unmeasured: an unmeasured organ
///                       can hide any failure below, and silence is not health.
///   2 failureStreak   — measured, and it is failing right now (a loop with
///                       repeated failures, an undelivered backlog, a
///                       non-`ok` heartbeat). A known failure ranks below an
///                       unknown one on purpose — we can see it and act.
///   3 stale           — measured, not failing, but its clock stopped (a loop
///                       that has not ticked, a watcher snapshot going cold).
///   4 healthy         — measured and inside every bound this reader knows.
///
/// Ties break on the SYS id, so the same data always names the same organ.
enum SysSeverity: Int {
    case unreadable = 0, absentExpected = 1, failureStreak = 2, stale = 3, healthy = 4
    var badge: String {
        switch self {
        case .unreadable: return "**UNREADABLE**"
        case .absentExpected: return "**UNMEASURED**"
        case .failureStreak: return "**FAILING**"
        case .stale: return "**STALE**"
        case .healthy: return "healthy"
        }
    }
}

struct SysRow {
    let id: String
    let organ: String
    let status: SysStatus
    /// Source labels, already escaped for a backtick span.
    let sourceLabels: [String]
    /// One-line live reading — an ALREADY-COMPOSED markdown fragment whose
    /// data-derived pieces went through mdCode/mdText at composition time.
    let reading: String
    let severity: SysSeverity
    /// One phrase, for the BOOM "worst:" clause. Already escaped.
    let severityReason: String
}

/// Status from the registered source labels alone — never from a count.
func sysStatus(_ labels: [String]) -> SysStatus {
    guard !labels.isEmpty else { return .absent }
    if labels.contains(where: { sources.isUnreadable($0) }) { return .unreadable }
    let present = labels.filter { sources.isPresent($0) }
    if present.isEmpty { return .absent }
    return present.count == labels.count ? .measured : .partial
}

/// The reading a blocked organ renders INSTEAD of numbers.
func sysBlockedReading(_ status: SysStatus, _ labels: [String]) -> String? {
    switch status {
    case .measured, .partial: return nil
    case .absent:
        return "**source absent** — " + (labels.isEmpty
            ? "no feed of this organ is registered in this data root"
            : "none of \(labels.count) registered feed(s) exist here") + ". This is not a zero."
    case .unreadable:
        let bad = labels.filter { sources.isUnreadable($0) }
        return "**source unreadable** — " + bad.map { "`\(mdCode($0))`: \(mdText(sources.reason($0)))" }
            .joined(separator: "; ") + ". Nothing is derived from it, least of all a zero."
    }
}

/// Guard flag for the per-feed cell rule below, hoisted so a mutation test can
/// switch it off and prove the assertions that depend on it go red.
let sysPerFeedGuard = true

/// ONE CELL of an organ's live reading, gated on its OWN feed(s).
///
/// `sysBlockedReading` only fires when the WHOLE organ is blocked. A **partial**
/// organ is the hole it leaves: some feeds are on disk, some are not, and every
/// counter behind a missing feed is still sitting at the zero it was
/// initialized to. Rendering that zero is precisely the absent≠zero violation
/// this instrument exists to catch — "ledger rows in window: **0**" for a
/// `task_ledger.jsonl` that does not exist reads as a measured quiet lane. So
/// each counter declares the feed(s) it came from and renders the house label
/// instead when none of them read.
///
/// The bar is "NONE of them read", not "any of them". A figure summed across
/// three lanes where two read is a real, partial measurement and the organ's
/// own **partial** badge already says so; a figure summed across zero readable
/// feeds is invented.
func sysCell(_ labels: [String], _ render: @autoclosure () -> String) -> String {
    guard sysPerFeedGuard else { return render() }
    if labels.contains(where: { sources.isPresent($0) && !sources.isUnreadable($0) }) {
        return render()
    }
    if labels.contains(where: { sources.isUnreadable($0) }) { return "source unreadable" }
    return "source absent"
}

func sysCell(_ label: String, _ render: @autoclosure () -> String) -> String {
    sysCell([label], render())
}

var sysRows: [SysRow] = []

// ── SYS-01 bridges ──
let sysBridgeLabels = sources.entries.map { $0.label }.filter { $0.hasPrefix("bridge/") }
let sysBridgeStatus: SysStatus = bridgeConfigRoot == nil ? .absent : sysStatus(sysBridgeLabels)
let brJobs = bridgeLanes.reduce(0) { $0 + $1.jobsTotal }
let brJobsWindow = bridgeLanes.reduce(0) { $0 + $1.jobsInWindow }
let brDelivered = bridgeLanes.reduce(0) { $0 + $1.deliveriesInWindow }
let brUndelivered = bridgeLanes.reduce(0) { $0 + $1.undeliveredOver24h }
let brTerminalFailed = bridgeLanes.reduce(0) { $0 + $1.terminalFailedUnread }
let brTerminalFailedOldest = bridgeLanes.compactMap(\.terminalFailedOldest).min()
let brHeld = bridgeLanes.reduce(0) { $0 + $1.jobsHeldUnreleased }
let brAcked = bridgeLanes.reduce(0) { $0 + $1.undeliveredAcknowledged }
let brHoldResidue = bridgeLanes.reduce(0) { $0 + $1.jobsSettledHoldResidue }
let brStaleHB = bridgeLanes.reduce(0) { $0 + $1.jobsStaleHeartbeat }
let brCapped = bridgeLanes.contains { $0.jobsCapped }
// Preserved (undeliverable) replies, summed over lanes whose undelivered/
// directory READ. A lane with no such directory contributes nothing — not a
// zero, an absence — and the cell is omitted entirely when no lane has one.
let brPreservedLanes = bridgeLanes.filter { $0.preservedDirPresent }
let brPreserved = brPreservedLanes.filter { $0.preserved.didRead }.reduce(0) { $0 + $1.preservedCount }
let brPreservedOldest = brPreservedLanes.compactMap { $0.preserved.didRead ? $0.preservedOldest : nil }.min()
let brPreservedUnreadable = brPreservedLanes.contains { if case .unreadable = $0.preserved { return true }; return false }
var brDeliveryMix: [String: Int] = [:]
for l in bridgeLanes { for (k, v) in l.deliveryStatuses { brDeliveryMix[k, default: 0] += v } }
// Each aggregate names the lane feeds it was summed from, so a partial bridge
// organ (one lane on disk, two not) cannot render another lane's silence as 0.
let sysBridgeJobLabels = sysBridgeLabels.filter { $0.hasSuffix("-jobs/") }
let sysBridgeDeliveryLabels = sysBridgeLabels.filter { $0.hasSuffix("-deliveries.jsonl") }
do {
    let jobsCell = sysCell(sysBridgeJobLabels,
        "jobs \(days)d: **\(brJobsWindow)** of \(brJobs) on disk\(brCapped ? " (capped)" : "")")
    let deliveredCell = sysCell(sysBridgeDeliveryLabels,
        "**\(brDelivered)**" + (brDeliveryMix.isEmpty ? "" : " (\(topCounts(brDeliveryMix, 3)))"))
    // Consumption truth lives on the inbox row. Reply deliveries are a legacy
    // fallback, not a prerequisite for measuring an inbox backlog.
    let undeliveredCell = bridgeLanes.contains { $0.inbox.didRead }
        ? "**\(brUndelivered)**" : "source absent"
    let terminalFailedCell = bridgeLanes.contains { $0.inbox.didRead }
        ? "**\(brTerminalFailed)**" : "source absent"
    let heldCell = sysCell(sysBridgeJobLabels, "**\(brHeld)**")
    let staleHBCell = sysCell(sysBridgeJobLabels, "**\(brStaleHB)**")
    // Preserved replies render ONLY when some lane has an undelivered/
    // directory: an absent directory is "nothing was ever preserved", and
    // printing `0` for it would be the zero this instrument refuses to invent.
    let preservedCell: String = {
        guard !brPreservedLanes.isEmpty else { return "" }
        if brPreservedUnreadable && brPreserved == 0 { return " · preserved-undelivered: source unreadable" }
        return " · preserved-undelivered: **\(brPreserved)**"
            + (brPreservedOldest.map { " (oldest \(ageDaysText($0)))" } ?? "")
            + (brPreservedUnreadable ? " (+ a lane unreadable)" : "")
    }()
    let reading = sysBlockedReading(sysBridgeStatus, sysBridgeLabels) ?? [
        jobsCell, " · ",
        "delivered in window: ", deliveredCell,
        " · terminal failed: ", terminalFailedCell,
        " · unconsumed >24h: ", undeliveredCell, " · held-unreleased: ", heldCell, " · ",
        "stale-heartbeat: ", staleHBCell,
        preservedCell,
        (brAcked > 0 ? " · \(brAcked) acknowledged (triage ledger: docs/eval_acknowledgments.json)" : ""),
        (brHoldResidue > 0 ? " · \(brHoldResidue) settled-hold residue (inert)" : "")
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysBridgeStatus {
    case .unreadable: sev = .unreadable; why = "a bridge feed could not be read"
    case .absent: sev = .absentExpected
        why = bridgeConfigDisabled ? "bridge lanes disabled by `--no-bridge-config`"
                                   : "bridge config root not read on this data root"
    case .partial: sev = .absentExpected; why = "some bridge feeds missing on this root"
    case .measured:
        if brTerminalFailed > 0 {
            sev = .failureStreak
            why = "\(brTerminalFailed) unread message(s) terminally failed delivery"
        }
        else if brUndelivered > 0 { sev = .failureStreak; why = "\(brUndelivered) message(s) unconsumed >24h" }
        // (An unreadable undelivered/ directory is a registered, unreadable
        // feed, so the organ already reads `.unreadable` above — it never
        // reaches this branch as a measured organ.)
        else if brPreserved > 0 {
            // Completed work nobody acknowledged, sitting in a directory nothing
            // replays: stale by definition, and it only ages.
            sev = .stale
            why = "\(brPreserved) preserved undeliverable repl\(brPreserved == 1 ? "y" : "ies")"
                + (brPreservedOldest.map { " (oldest \(ageDaysText($0)))" } ?? "")
        }
        else if brHeld > 0 { sev = .stale; why = "\(brHeld) wake job(s) still under commit hold" }
        else if brStaleHB > 0 { sev = .stale; why = "\(brStaleHB) job(s) with a stopped heartbeat" }
    }
    sysRows.append(SysRow(id: "SYS-01", organ: "Agent bridges (claude / codex / OMP wake lanes)",
                          status: sysBridgeStatus, sourceLabels: sysBridgeLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-02 background loops ──
let sysLoopLabels = ["logs/background_loop_state.json", "logs/background_loop_failures.jsonl"]
let sysLoopStatus = sysStatus(sysLoopLabels)
// A loop that FAILS but keeps RECOVERING is flaky-external, not broken: its
// state file shows a successful tick AFTER its newest failure. Triage
// 2026-08-21: github_tracking's 12 window failures were all GitHub-side 5xx
// with the very next tick succeeding — ranking that as the worst organ
// teaches readers to ignore the line. Recovering loops keep their failure
// counts visible in the per-loop table and get a quiet note; only a loop
// whose LAST word is a failure (no tick recorded after it) is a streak.
let sysLoopStreaks = loopFailuresByLoop.filter { name, count in
    guard count >= 3 else { return false }
    guard let lastFail = loopFailureNewest[name] else { return true }
    guard let lastTick = loopLastRun[name] else { return true }
    return lastTick <= lastFail
}
    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
let sysLoopFlaky = loopFailuresByLoop.filter { name, count in
    count >= 3 && !sysLoopStreaks.contains { $0.key == name }
}
    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
do {
    // Same tie rule as `loopsStale`: equal ticks resolve on the loop id, or the
    // "oldest tick" this row names is whichever one the dictionary happened to
    // hand out first this process.
    let oldest = loopLastRun.min { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
    // Tick counts come from the state file, failure counts from the failure
    // feed. Either can be missing on its own — this organ reads PARTIAL then,
    // and the half that is missing must say so rather than report 0.
    let tickCell = sysCell("logs/background_loop_state.json", [
        "**\(loopLastRun.count)** loop(s) with a recorded tick",
        (oldest.map { " · oldest tick `\(mdCode($0.key))` \(ageDaysText($0.value)) ago" } ?? ""),
        " · not ticked >1d: **\(loopsStale.count)**"
    ].joined())
    let failCell = sysCell("logs/background_loop_failures.jsonl", [
        "**\(loopFailuresInWindow)** ",
        "across \(loopFailuresByLoop.count) loop(s)",
        (loopWorstFailing.map { " (worst `\(mdCode($0.key))`×\($0.value))" } ?? ""),
        " · failure rows total: \(loopFailureRowsTotal) (line-capped, a lower bound)"
    ].joined())
    // The flaky-external note rides the READING, not just the severity
    // reason — the matrix row prints the reading, so the note must survive
    // regardless of which condition wins worst-organ (gpt-5.5 review).
    let flakyNote = sysLoopFlaky.isEmpty ? "" :
        " · flaky-external: " + sysLoopFlaky.prefix(3)
            .map { "`\(mdCode($0.key))`×\($0.value) (recovers)" }.joined(separator: ", ")
    let reading = sysBlockedReading(sysLoopStatus, sysLoopLabels)
        ?? (tickCell + " · failures in window: " + failCell + flakyNote)
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysLoopStatus {
    case .unreadable: sev = .unreadable; why = "a loop feed could not be read"
    case .absent: sev = .absentExpected; why = "no loop state or failure feed on this root"
    case .partial: sev = .absentExpected; why = "one of the two loop feeds is missing"
    default:
        if let worst = sysLoopStreaks.first {
            sev = .failureStreak; why = "loop `\(mdCode(worst.key))` failed \(worst.value)× in window"
        } else if let s = loopsStale.first {
            sev = .stale; why = "loop `\(mdCode(s.key))` has not ticked in \(fmt(daysSince(s.value), 1))d"
        } else if let f = sysLoopFlaky.first {
            why = "measured; flaky-external only (`\(mdCode(f.key))` failed \(f.value)× but recovers every time)"
        }
    }
    sysRows.append(SysRow(id: "SYS-02", organ: "Background loops (scheduler tick outcomes)",
                          status: sysLoopStatus, sourceLabels: sysLoopLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-03 delegation / orchestration ──
let sysDelegationLabels = ["orchestration/task_ledger.jsonl", "orchestration/task_ledger_state.json",
                           "logs/delegation_outcome_cursor.json", "desk/desk_archive.jsonl"]
let sysDelegationStatus = sysStatus(sysDelegationLabels)
// Oldest outcome cursor, ties broken on the store NAME so two runs over the
// same bytes always name the same store.
let sysDatedCursors: [(name: String, seen: Date)] = delegationCursors.compactMap { c in
    guard let s = c.lastSeen else { return nil }
    return (name: c.name, seen: s)
}
let sysOldestCursor: (name: String, seen: Date)? = sysDatedCursors.min { a, b in
    a.seen == b.seen ? a.name < b.name : a.seen < b.seen
}
do {
    // Four independent feeds, four independently-gated cells. `task_ledger.jsonl`
    // absent while the reduced state is present is the exact partial that used
    // to print "ledger rows in window: **0**".
    let ledgerCell = sysCell("orchestration/task_ledger.jsonl",
        "**\(delegationRowsWindow)**" + (delegationKinds.isEmpty ? "" : " (\(topCounts(delegationKinds, 3)))"))
    let stateCell = sysCell("orchestration/task_ledger_state.json", [
        "**\(taskStateTotal)** task(s)",
        (taskStateCounts.isEmpty ? "" : " (\(topCounts(taskStateCounts, 3)))"),
        (taskStateNewest.map { ", newest update \(stamp($0))" } ?? "")
    ].joined())
    let cursorCell = sysCell("logs/delegation_outcome_cursor.json",
        "**\(delegationCursors.count)** store(s)"
        + (sysOldestCursor.map { ", oldest `\(mdCode($0.name))` last_seen \(ageDaysText($0.seen)) ago" } ?? ""))
    let archiveCell = sysCell("desk/desk_archive.jsonl",
        "**\(deskArchivedInWindow)** of \(deskArchivedTotal)")
    let reading = sysBlockedReading(sysDelegationStatus, sysDelegationLabels) ?? [
        "ledger rows in window: ", ledgerCell,
        " · reduced state: ", stateCell,
        " · outcome cursors: ", cursorCell,
        " · desk archive in window: ", archiveCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysDelegationStatus {
    case .unreadable: sev = .unreadable; why = "a delegation feed could not be read"
    case .absent: sev = .absentExpected; why = "no delegation ledger, state or cursor on this root"
    case .partial: sev = .absentExpected; why = "part of the delegation lane is missing on this root"
    default:
        if let c = sysOldestCursor, daysSince(c.seen) > 3 {
            sev = .stale
            why = "outcome cursor `\(mdCode(c.name))` last saw a row \(fmt(daysSince(c.seen), 1))d ago"
        }
    }
    sysRows.append(SysRow(id: "SYS-03", organ: "Delegation / orchestration (task ledger + outcome cursors)",
                          status: sysDelegationStatus, sourceLabels: sysDelegationLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-04 notifications / push delivery ──
let sysNotifyLabels = ["notifications/inbox.jsonl", "mobile_push/receipts.jsonl",
                       "notifications/push_tokens.json", "icloud/chat_delivery_receipts.jsonl"]
let sysNotifyStatus = sysStatus(sysNotifyLabels)
let sysPushFailures = pushStatusInWindow.filter { $0.key != "ok" }.reduce(0) { $0 + $1.value }
do {
    // `notifications/inbox.jsonl` absent while the APNs and iCloud feeds are
    // present is this organ's partial case — the inbox cell must say so rather
    // than report "0 cards, 0 unread" for a ledger nobody read.
    let inboxCell = sysCell("notifications/inbox.jsonl",
        "**\(notifyStatusWindow.values.reduce(0, +))**, unread overall: **\(notifyUnreadTotal)**")
    let apnsCell = sysCell("mobile_push/receipts.jsonl", [
        "**\(pushRowsInWindow)**",
        (pushStatusInWindow.isEmpty ? "" : " (\(topCounts(pushStatusInWindow, 3)))"),
        ", failed: **\(sysPushFailures)**",
        (pushMaxTokenAgeDays.map { ", max token age \(fmt($0, 1))d" } ?? "")
    ].joined())
    let tokensCell = sysCell("notifications/push_tokens.json",
        pushTokenCount.map { "**\($0)**" } ?? "source absent")
    let icloudCell = sysCell("icloud/chat_delivery_receipts.jsonl", [
        "**\(icloudRowsInWindow)**",
        (icloudStatusInWindow.isEmpty ? "" : " (\(topCounts(icloudStatusInWindow, 3)))"),
        ", signature-unverified: **\(icloudUnverified)**"
    ].joined())
    let reading = sysBlockedReading(sysNotifyStatus, sysNotifyLabels) ?? [
        "inbox cards in window: ", inboxCell, " · ",
        "APNs receipts in window: ", apnsCell,
        " · device tokens: ", tokensCell,
        " · iCloud chat receipts in window: ", icloudCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysNotifyStatus {
    case .unreadable: sev = .unreadable; why = "a notification feed could not be read"
    case .absent: sev = .absentExpected; why = "no notification, push or iCloud receipt feed on this root"
    case .partial: sev = .absentExpected; why = "part of the delivery lane is missing on this root"
    default:
        if icloudUnverified > 0 {
            sev = .failureStreak; why = "\(icloudUnverified) iCloud receipt(s) failed signature verification"
        } else if sysPushFailures > 0 {
            sev = .failureStreak; why = "\(sysPushFailures) APNs send(s) failed in window"
        } else if pushNewest != nil, let p = pushNewest, daysSince(p) > Double(days) {
            sev = .stale; why = "no APNs receipt since \(stamp(p))"
        }
    }
    sysRows.append(SysRow(id: "SYS-04", organ: "Notifications / push delivery (inbox, APNs, iCloud receipts)",
                          status: sysNotifyStatus, sourceLabels: sysNotifyLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-05 memory housekeeping ──
let sysMemoryLabels = ["memory.sqlite", "memory/tombstones.jsonl", "memory/provenance.jsonl",
                       "memory/consolidations.jsonl", "memory/dedup_shadow.jsonl",
                       "memory/hygiene_last_run.json", "memory/hygiene.jsonl",
                       "memory/embedding_epoch_receipt.json", memoryBackupsLabel,
                       stagedMemoryRepairsLabel]
let sysMemoryStatus = sysStatus(sysMemoryLabels)
do {
    let indexCoverage: String = {
        guard let idx = kgIndexed, let act = memoriesActive, act > 0 else {
            return kgIndexed == nil ? "source absent" : "n/a (0 active memories)"
        }
        return "**\(idx)**/\(act) (\(fmt(Double(idx) / Double(act) * 100, 0))%)"
    }()
    // Every cell is composed on its own line. Each `?? "source absent"` is the
    // house rule in miniature: the store's counters are Optional precisely so
    // an unread store cannot arrive here as a zero.
    let proposalCell: String = proposalsPending.map { "**\($0)** pending" } ?? "source absent"
    let tombstoneCell: String = tombstonesInStore.map { "**\($0)** in store" } ?? "source absent"
    let epochCell: String = epochActive.map { "`\(mdCode(String($0.prefix(28))))…`" } ?? "source absent"
    let epochStatusCell: String = epochStatus.map { mdText($0) } ?? "no status"
    let epochProtectedCell: String = epochProtected == true ? ", protected" : ""
    let offEpochMem: String = memoriesOffEpoch.map(String.init) ?? "?"
    let offEpochProp: String = proposalsOffEpoch.map(String.init) ?? "?"
    let hygieneCell: String = sysCell("memory/hygiene_last_run.json",
        hygieneStatus.map { "`\(mdCode($0))`" } ?? "**no `status` field**")
    // The store-backed cells above are Optional and already refuse to be zero.
    // These three are FILE-backed counters that would happily render the 0 they
    // were initialized to when their JSONL is not on this root.
    let tombstoneFileCell: String = sysCell("memory/tombstones.jsonl", "\(memTombstonesFile) in file")
    let consolidationCell: String = sysCell("memory/consolidations.jsonl", "\(memConsolidationRows)")
    let dedupCell: String = sysCell("memory/dedup_shadow.jsonl", "\(memDedupShadowRows)")
    let provenanceCell: String = sysCell("memory/provenance.jsonl",
        memProvenanceEvents.isEmpty ? "no event row" : topCounts(memProvenanceEvents, 3))
    let backupCell = sysCell(memoryBackupsLabel,
        "**\(memoryBackupGenerations)**/\(memoryBackupGenerationCeiling) generation(s)"
            + (memoryBackupNewest.map { ", newest \(stamp($0))" } ?? ""))
    let repairCell = sysCell(stagedMemoryRepairsLabel,
        "**\(stagedMemoryRepairCount)** staged"
            + (stagedMemoryRepairOldest.map { ", oldest \(stamp($0)) (\(ageDaysText($0)))" } ?? ""))
    let hygieneLedgerCell = sysCell("memory/hygiene.jsonl", {
        guard hygieneLedgerRows > 0 else { return "no ledger row" }
        guard let ledger = hygieneLedgerNewest else { return "no timestamped ledger row" }
        guard let agrees = hygieneReceiptsAgree else {
            return "newest \(stamp(ledger)); last-run receipt unavailable"
        }
        return agrees
            ? "newest \(stamp(ledger)); **agrees** with last-run receipt"
            : "newest \(stamp(ledger)); **MISMATCH** with last-run receipt"
    }())
    let reading = sysBlockedReading(sysMemoryStatus, sysMemoryLabels) ?? [
        "proposals: ", proposalCell,
        (proposalsNewestStaged.map { ", newest staged \(stamp($0))" } ?? ""),
        " · tombstones: ", tombstoneCell,
        " / ", tombstoneFileCell,
        " · epoch: ", epochCell,
        " (", epochStatusCell, epochProtectedCell, ")",
        ", off-epoch: ", offEpochMem, " memories / ", offEpochProp, " proposals",
        " · KG index coverage: ", indexCoverage,
        " · hygiene: ", hygieneCell,
        (hygieneRanAt.map { " ran \(stamp($0)) (\(ageDaysText($0)) ago)" } ?? ""),
        " · backup retention: ", backupCell,
        " · staged repairs: ", repairCell,
        " · hygiene ledger: ", hygieneLedgerCell,
        " · consolidations file rows: ", consolidationCell, ", dedup shadow: ", dedupCell,
        " · provenance: ", provenanceCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysMemoryStatus {
    case .unreadable: sev = .unreadable; why = "a memory housekeeping source could not be read"
    case .absent: sev = .absentExpected; why = "no memory store or housekeeping feed on this root"
    case .partial: sev = .absentExpected; why = "part of memory housekeeping is missing on this root"
    default:
        if (memoriesOffEpoch ?? 0) + (proposalsOffEpoch ?? 0) > 0 {
            sev = .failureStreak
            why = "\((memoriesOffEpoch ?? 0) + (proposalsOffEpoch ?? 0)) row(s) carry an off-epoch embedding"
        } else if memoryBackupGenerations > memoryBackupGenerationCeiling {
            sev = .failureStreak
            why = "\(memoryBackupGenerations) memory backup generations exceed the \(memoryBackupGenerationCeiling)-generation ceiling"
        } else if let oldest = stagedMemoryRepairOldest,
                  now.timeIntervalSince(oldest) > stagedMemoryRepairMaxAgeDays * 24 * 60 * 60 {
            sev = .stale
            why = "oldest staged memory repair is \(ageDaysText(oldest)) old (maximum \(Int(stagedMemoryRepairMaxAgeDays))d)"
        } else if hygieneReceiptsAgree == false {
            sev = .failureStreak
            why = "hygiene.jsonl and hygiene_last_run.json disagree on the latest run"
        } else if let next = hygieneNextScheduled, next < now {
            sev = .stale; why = "hygiene overdue — next was scheduled \(stamp(next))"
        }
    }
    sysRows.append(SysRow(id: "SYS-05", organ: "Memory V2 housekeeping (proposals, tombstones, epoch, hygiene)",
                          status: sysMemoryStatus, sourceLabels: sysMemoryLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-06 Workshop ──
let sysWorkshopLabels = ["workshop/receipts.jsonl", "workshop/background_lease.json",
                         "workshop/executions/*/execution.json", "workshop/reservation_claims/*.claim"]
let sysWorkshopStatus = sysStatus(sysWorkshopLabels)
// BackgroundWorkLease stores consumed windows, not a heartbeat. The pump is
// event/deadline-driven with daily missed-event recovery; only its canonical
// recorded tick can supply activity evidence. Two daily intervals is a review
// threshold, not proof that the process stopped or a session failed.
let workshopPumpReviewHours = 48.0
let workshopPumpTick = loopLastRun["workshop_pump"]
let workshopPumpTickAgeHours = workshopPumpTick.map { hoursSince($0) }
let sysLeaseAgeHours = leaseAcquiredAt.map { hoursSince($0) }
/// The lease cell, composed separately: a present-but-unstamped lease is a
/// distinct fact from an absent one, and neither may render as an age of 0.
let sysLeaseCell: String = {
    guard leaseObj != nil else { return "source absent" }
    if let claims = leaseObj?["claims"] as? [Any], claims.isEmpty,
       leaseObj?["window"] == nil, leaseAcquiredAt == nil {
        return "no consumed windows retained (empty claim history; not a heartbeat)"
    }
    let holder = mdCode((leaseObj?["holder"] as? String) ?? "(none)")
    let age = sysLeaseAgeHours.map { ", acquired \(fmt(max($0, 0), 1))h ago" } ?? ", **no `acquiredAt`**"
    return "holder `\(holder)`" + age + ", \(leaseClaims) claim(s) (consumed-window history; not a heartbeat)"
}()
let workshopPumpCell = workshopPumpTick.map {
    "last recorded tick \(stamp($0)) (\(fmt(max(hoursSince($0), 0), 1))h ago); not proof of session success or continuous uptime"
} ?? "tick unavailable (\(loopStateFeed.blockedLabel ?? "no parseable workshop_pump timestamp")); activity unknown"
do {
    let executionCell = sysCell("workshop/executions/*/execution.json", [
        "**\(executionsTotal)**",
        (executionStatuses.isEmpty ? "" : " (\(topCounts(executionStatuses, 3)))"),
        (executionsUnparseable > 0 ? ", **\(executionsUnparseable) unparseable**" : ""),
        (executionNewest.map { ", newest \(stamp($0))" } ?? "")
    ].joined())
    let receiptCell = sysCell("workshop/receipts.jsonl",
        "**\(workshopReceiptsInWindow)** in window of \(workshopReceiptsTotal)"
        + (workshopDispositions.isEmpty ? "" : " (\(topCounts(workshopDispositions, 3)))"))
    let claimCell = sysCell("workshop/reservation_claims/*.claim", [
        "**\(reservationClaims)**",
        (reservationsUnparseable > 0 ? ", **\(reservationsUnparseable) unparseable**" : ""),
        (reservationNewest.map { ", newest \(stamp($0))" } ?? "")
    ].joined())
    let reading = sysBlockedReading(sysWorkshopStatus, sysWorkshopLabels) ?? [
        "executions: ", executionCell,
        " · receipts: ", receiptCell,
        " · lease: ", sysLeaseCell,
        " · pump: ", workshopPumpCell,
        " · reservation claims: ", claimCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysWorkshopStatus {
    case .unreadable: sev = .unreadable; why = "a Workshop feed could not be read"
    case .absent: sev = .absentExpected; why = "no Workshop execution, receipt or lease state on this root"
    case .partial: sev = .absentExpected; why = "part of Workshop state is missing on this root"
    default:
        if executionsUnparseable > 0 {
            sev = .failureStreak; why = "\(executionsUnparseable) execution record(s) will not parse"
        } else if reservationsUnparseable > 0 {
            sev = .failureStreak; why = "\(reservationsUnparseable) reservation claim(s) will not parse"
        } else if let h = workshopPumpTickAgeHours, h > workshopPumpReviewHours {
            sev = .stale; why = "last recorded pump tick \(fmt(h, 1))h ago; current activity unknown"
        }
    }
    sysRows.append(SysRow(id: "SYS-06", organ: "Workshop (executions, receipts, background lease)",
                          status: sysWorkshopStatus, sourceLabels: sysWorkshopLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-07 GitHub command lane ──
var sysGithubLabels = ["workshop/github_command/ops.jsonl",
                       "workshop/github_command/github_command_state.json",
                       "notify/github_approvals.json", "connectors/github/tracking_snapshot.json"]
// The base is absent before a first compaction, which is valid and shown as an
// explicit absence below. If it EXISTS, it becomes required for a trustworthy
// replay and therefore participates in the organ's unreadable/partial state.
if sources.isPresent("workshop/github_command/ops_base.json") {
    sysGithubLabels.append("workshop/github_command/ops_base.json")
}
let sysGithubStatus = sysStatus(sysGithubLabels)
/// The tracking snapshot is the watcher's own heartbeat. Its loop is hourly on
/// the live root; a full day without a refresh means the watcher is not
/// cycling, not that GitHub went quiet.
let githubWatcherStaleHours = 24.0
let sysWatcherAgeHours = githubTrackingNewest.map { hoursSince($0) }
/// Same three-way split as the lease: absent file, present-but-unstamped, or a
/// real cycle age. A snapshot with no timestamp is a finding, not an age of 0.
let sysWatcherCell: String = {
    guard githubTrackingObj != nil else { return "source absent" }
    let age = sysWatcherAgeHours.map { ", cycle age \(fmt(max($0, 0), 1))h" } ?? ", **no timestamp field**"
    return "\(githubTrackingKeys) key(s)" + age
}()
do {
    // Items, dispatched keys and the receipt/claim pair all come out of the one
    // reduced state file; ops, optional compaction base, approvals and watcher
    // snapshot each have their own. Any source may be unavailable independently.
    let stateLabel = "workshop/github_command/github_command_state.json"
    let itemsCell = sysCell(stateLabel, "**\(githubItems)** (\(githubItemsOpen) open)"
        + (githubItemNewest.map { ", newest motor update \(stamp($0))" } ?? ""))
    let opsCell = sysCell("workshop/github_command/ops.jsonl",
        "**\(githubOpsInWindow)** of \(githubOpsTotal)"
        + (githubOpKinds.isEmpty ? "" : " (\(topCounts(githubOpKinds, 3)))"))
    let baseCell: String = {
        guard githubBaseFeed.didRead else {
            return githubBaseFeed.blockedLabel ?? "source absent (not yet compacted)"
        }
        guard !sources.isUnreadable("workshop/github_command/ops_base.json") else {
            return "source unreadable — " + sources.reason("workshop/github_command/ops_base.json")
        }
        let keyCount = "\(githubBaseKeyCount) key(s)"
        let itemCount = githubBaseItemCount.map { ", \($0) reduced item(s)" } ?? ""
        let compacted = githubBaseCompactedOpCount.map { ", after \($0) op(s)" } ?? ""
        let bytes = githubBaseBytes.map { ", \($0) byte(s)" } ?? ""
        let ratio: String = {
            guard let base = githubBaseBytes, let ops = githubOpsBytes, ops > 0 else { return "" }
            return ", base/tail \(fmt(Double(base) / Double(ops), 1))×"
        }()
        return keyCount + itemCount + compacted + bytes + ratio
    }()
    let dispatchedCell = sysCell(stateLabel, "\(githubDispatchedKeys)")
    let receiptsCell = sysCell(stateLabel, "\(githubNotificationReceipts)/\(githubNotificationClaims)")
    let approvalsCell = sysCell("notify/github_approvals.json",
        githubApprovalStates.isEmpty ? "no review state" : topCounts(githubApprovalStates, 3))
    let reading = sysBlockedReading(sysGithubStatus, sysGithubLabels) ?? [
        "items: ", itemsCell,
        " · ops in window: ", opsCell,
        " · compaction base: ", baseCell,
        " · dispatched keys: ", dispatchedCell,
        " · notification receipts/claims: ", receiptsCell,
        " · approvals: ", approvalsCell,
        " · watcher snapshot: ", sysWatcherCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysGithubStatus {
    case .unreadable: sev = .unreadable; why = "a GitHub lane feed could not be read"
    case .absent: sev = .absentExpected; why = "no GitHub command state on this root"
    case .partial: sev = .absentExpected; why = "part of the GitHub lane is missing on this root"
    default:
        if let h = sysWatcherAgeHours, h > githubWatcherStaleHours {
            sev = .stale; why = "watcher snapshot last refreshed \(fmt(h, 1))h ago"
        } else if githubTrackingObj != nil, sysWatcherAgeHours == nil {
            sev = .stale; why = "watcher snapshot carries no timestamp — its cycle age is unknowable"
        }
    }
    sysRows.append(SysRow(id: "SYS-07", organ: "GitHub command lane (watcher, ops ledger, approvals)",
                          status: sysGithubStatus, sourceLabels: sysGithubLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-08 heartbeat / self-healing ──
let sysHeartbeatLabels = ["heartbeat/status.json"]
let sysHeartbeatStatus = sysStatus(sysHeartbeatLabels)
do {
    // A missing FIELD is named as a missing field, not defaulted. `status`,
    // `last_tick_at` and `issues` are the three that decide this organ's
    // severity, so none of them may quietly become "ok" / now / 0.
    let hbStatusCell: String = heartbeatStatus.map { "`\(mdCode($0))`" } ?? "**no `status` field**"
    let hbTickCell: String = heartbeatLastTick.map { "\(stamp($0)) (\(ageHoursText($0)) ago)" }
        ?? "**no `last_tick_at` field**"
    let hbIssuesCell: String = heartbeatIssues.map { "**\($0)**" } ?? "**no `issues` array**"
    let reading = sysBlockedReading(sysHeartbeatStatus, sysHeartbeatLabels) ?? [
        "status: ", hbStatusCell,
        (heartbeatCondition.map { " (condition `\(mdCode($0))`)" } ?? ""),
        " · last tick: ", hbTickCell,
        (heartbeatNextTick.map { " · next no earlier than \(stamp($0))" } ?? ""),
        " · issues: ", hbIssuesCell,
        (heartbeatCadence.map { " · cadence \(fmt($0 / 3600, 1))h" } ?? "")
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysHeartbeatStatus {
    case .unreadable: sev = .unreadable; why = "`heartbeat/status.json` could not be read"
    case .absent, .partial: sev = .absentExpected; why = "no heartbeat status on this root"
    default:
        if let s = heartbeatStatus, s != "ok" {
            sev = .failureStreak; why = "heartbeat status is `\(mdCode(s))`, not `ok`"
        } else if (heartbeatIssues ?? 0) > 0 {
            sev = .failureStreak; why = "heartbeat reports \(heartbeatIssues ?? 0) open issue(s)"
        } else if let t = heartbeatLastTick, let c = heartbeatCadence, hoursSince(t) > (c / 3600) * 2 {
            sev = .stale; why = "last tick \(fmt(hoursSince(t), 1))h ago, over 2× its \(fmt(c / 3600, 1))h cadence"
        }
    }
    sysRows.append(SysRow(id: "SYS-08", organ: "Heartbeat / self-healing", status: sysHeartbeatStatus,
                          sourceLabels: sysHeartbeatLabels, reading: reading,
                          severity: sev, severityReason: why))
}

// ── SYS-09 providers / routing ──
let sysProviderLabels = ["providers/surfaces.json", "providers/active.json", "providers/",
                         "llm/provider_status.json", "traces/events.jsonl"]
let sysProviderStatus = sysStatus(sysProviderLabels)
let sysSurfacesPinned = surfacePins.values.filter { $0.model != nil }.count
let sysProvidersConfigured = providerCredentialFiles.values.filter { $0.parsed }.count
do {
    let pinCell = sysCell(["providers/surfaces.json", "providers/active.json"],
        "**\(sysSurfacesPinned)** model-pinned / \(surfacePins.count) surface(s)")
    let registryCell = sysCell("providers/", [
        "**\(sysProvidersConfigured)** configured",
        (providerUnparseable > 0 ? ", **\(providerUnparseable) unparseable**" : ""),
        (openrouterModelCount.map { " · openrouter cache \($0) model(s)" } ?? "")
    ].joined())
    // Drift, substitutions and rejections all come off the TRACE. With no
    // events feed there is no observation at all — not an observation of zero.
    let driftCell = sysCell("traces/events.jsonl", pinDrifts.isEmpty
        ? "**0**"
        : "**\(pinDrifts.count)** (" + pinDrifts.prefix(3)
            .map { "`\(mdCode($0.surface))` pinned `\(mdCode($0.pinned))` → `\(mdCode($0.observed))`" }
            .joined(separator: ", ") + ")")
    let substitutionCell = sysCell("traces/events.jsonl",
        "**\(llmSubstitutionPairsAll.values.reduce(0, +))**"
        + (llmSubstitutionPairsAll.isEmpty ? "" : " (\(topCounts(llmSubstitutionPairsAll, 3)))"))
    let rejectionCell = sysCell("traces/events.jsonl",
        "**\(llmNonOKInWindow)**"
        + (llmNonOKByStatus.isEmpty ? "" : " (\(topCounts(llmNonOKByStatus, 3)))"))
    // A pin whose provider has no credential file is a route that cannot fire.
    let unresolvedCell = sysCell("providers/active.json", unresolvedProviderPins.isEmpty
        ? "**0**"
        : "**\(unresolvedProviderPins.count)** (" + unresolvedProviderPins.prefix(3)
            .map { "`\(mdCode($0.surface))`→`\(mdCode($0.provider))`" }.joined(separator: ", ") + ")")
    let unservedCell = sysCell(["providers/surfaces.json", "providers/active.json"], unservedProviderPins.isEmpty
        ? "**0**"
        : "**\(unservedProviderPins.count)** (" + unservedProviderPins.prefix(3)
            .map { "`\(mdCode($0))`" }.joined(separator: ", ") + ")")
    let retiredCell = sysCell(["providers/surfaces.json", "providers/active.json"], retiredProviderPins.isEmpty
        ? "**0**"
        : "**\(retiredProviderPins.count)** (" + retiredProviderPins.prefix(3)
            .map { "`\(mdCode($0))`" }.joined(separator: ", ") + ")")
    let statusCell = sysCell("llm/provider_status.json", [
        providerStatusStatus.map { "`\(mdCode($0))`" } ?? "**no `status` field**",
        (providerStatusDetail.map { " (\(mdText($0)))" } ?? ""),
        (providerStatusCheckedAt.map { " checked \(stamp($0)) (\(ageDaysText($0)) ago)" } ?? "")
    ].joined())
    let reading = sysBlockedReading(sysProviderStatus, sysProviderLabels) ?? [
        "surface pins: ", pinCell,
        " · provider registry: ", registryCell,
        " · pins unresolvable: ", unresolvedCell,
        " · pins on unknown surfaces: ", unservedCell,
        " · retired compatibility pins: ", retiredCell,
        " · pin-vs-observed drift: ", driftCell,
        " · substitutions in window: ", substitutionCell,
        " · non-`ok` llm.call rows in window: ", rejectionCell,
        " · last provider check: ", statusCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysProviderStatus {
    case .unreadable: sev = .unreadable; why = "a provider/routing source could not be read"
    case .absent: sev = .absentExpected; why = "no provider pin, registry or trace feed on this root"
    case .partial: sev = .absentExpected; why = "part of the provider lane is missing on this root"
    default:
        if !unservedProviderPins.isEmpty {
            sev = .failureStreak
            why = "\(unservedProviderPins.count) picker pin(s) use an unknown routing surface"
        } else if !unresolvedProviderPins.isEmpty {
            sev = .failureStreak
            why = "\(unresolvedProviderPins.count) surface pin(s) name a provider with no config file"
        } else if llmNonOKInWindow > 0 {
            sev = .failureStreak; why = "\(llmNonOKInWindow) non-`ok` llm.call row(s) in window"
        } else if providerUnparseable > 0 {
            sev = .failureStreak; why = "\(providerUnparseable) provider config file(s) will not parse"
        } else if let d = pinDrifts.first {
            sev = .stale
            why = "surface `\(mdCode(d.surface))` never used its pinned model `\(mdCode(d.pinned))` in window"
        } else if let c = providerStatusCheckedAt, c.timeIntervalSinceNow > 5 * 60 {
            sev = .unreadable
            why = "provider status `checkedAt` is more than 5 minutes in the future"
        } else {
            switch providerStatusStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "error", "failed":
                sev = .failureStreak
                why = "the last native provider check reported `\(mdCode(providerStatusStatus ?? "error"))`"
            case "unavailable", "unknown":
                sev = .absentExpected
                why = "the last provider check had no available native probe"
            case "ok":
                guard let c = providerStatusCheckedAt else {
                    sev = .unreadable
                    why = "provider status is `ok` but has no readable `checkedAt` timestamp"
                    break
                }
                if daysSince(c) > 30 {
                    sev = .stale
                    why = "provider status last checked \(fmt(daysSince(c), 0))d ago"
                }
            case .none:
                sev = .unreadable
                why = "provider status has no `status` field"
            default:
                sev = .unreadable
                why = "provider status has an unknown status value"
            }
        }
    }
    sysRows.append(SysRow(id: "SYS-09", organ: "Providers / routing (surface pins, registry, substitutions)",
                          status: sysProviderStatus, sourceLabels: sysProviderLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-10 tools ──
// The dispatch side comes from the trace; the DENIAL side comes from the
// security audit feed. They are separate sources and each cell says which.
let sysToolLabels = ["traces/events.jsonl", "tools/registry.json", "security/audit.jsonl"]
let sysToolStatus = sysStatus(sysToolLabels)
let sysToolFailRate: Double? = toolDispatchInWindow > 0
    ? Double(toolDispatchFailed) / Double(toolDispatchInWindow) * 100 : nil
let sysToolFailureCeiling = 25.0
let sysToolEnvelopePass: Bool? = sysToolFailRate.map { overall in
    overall <= sysToolFailureCeiling && toolStats.values.allSatisfy { stat in
        stat.total < 10 || (Double(stat.failed) / Double(stat.total) * 100) <= sysToolFailureCeiling
    }
}
/// A tool is a failure streak when it failed 3+ times AND more often than it
/// succeeded — one flaky call in fifty is noise, a tool that mostly fails is a
/// broken wire. Ties on name.
let sysToolBroken = toolWorstFailing.filter { $0.stat.failed >= 3 && $0.stat.failed > $0.stat.ok }
do {
    let dispatchCell = sysCell("traces/events.jsonl", [
        "**\(toolDispatchInWindow)** of \(toolDispatchRowsTotal) row(s)",
        " across \(toolStats.count) tool(s)",
        ", ok **\(toolDispatchOK)** / failed **\(toolDispatchFailed)**",
        (sysToolFailRate.map { " (\(fmt($0, 1))%)" } ?? "")
    ].joined())
    let worstCell = sysCell("traces/events.jsonl", toolWorstFailing.isEmpty
        ? "none"
        : toolWorstFailing.prefix(3).map { "`\(mdCode($0.name))`×\($0.stat.failed)" }.joined(separator: ", "))
    let envelopeCell = sysCell("traces/events.jsonl", sysToolEnvelopePass.map {
        "envelope **\($0 ? "PASS" : "FAIL")** (≤25% overall; ≤25% per tool with ≥10 calls)"
    } ?? "source absent")
    let preloadCell = sysCell("traces/events.jsonl",
        "**\(toolPreloadInWindow)**"
        + (toolPreloadGroups.isEmpty ? "" : " (\(topCounts(toolPreloadGroups, 3)))"))
    let registryCell = sysCell("tools/registry.json",
        toolRegistryEntries.map { count in
            let directoryState = toolArtifactDirectories.map { directory -> String in
                let name = directory.relativePath.replacingOccurrences(of: "tools/", with: "")
                guard directory.present else { return "\(name): absent" }
                guard directory.readable else { return "\(name): **unreadable**" }
                return "\(name): \(directory.ids.count)"
            }.joined(separator: ", ")
            let posture = count == 0 && toolArtifactDirectories.allSatisfy { !$0.present || ($0.readable && $0.ids.isEmpty) }
                ? " — **EMPTY / never materialized**" : ""
            return "**\(count)** entr(ies), \(toolRegistryInstalled) installed/active (\(directoryState))\(posture)"
        }
            ?? "source absent")
    // Sandbox/policy refusals are the audit feed's number, not the trace's — a
    // refused call never reaches dispatch, so it is invisible in `tool.dispatch`.
    let refusalCell = sysCell("security/audit.jsonl",
        "**\(auditRefusalsInWindow)**"
        + (auditWorstRefused.isEmpty ? "" : " (worst " + auditWorstRefused.prefix(3)
            .map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", ") + ")"))
    let approvalLatencyCell: String = {
        guard approvalsFeed.didRead else { return "source absent" }
        guard !approvalLatenciesHours.isEmpty else { return "no resolved request carries both stamps" }
        let s = approvalLatenciesHours.sorted()
        return "p50 \(fmt(percentile(s, 0.5), 1))h, p95 \(fmt(percentile(s, 0.95), 1))h over \(s.count)"
    }()
    let reading = sysBlockedReading(sysToolStatus, sysToolLabels) ?? [
        "dispatches in \(runtimeEvidenceLabel): ", dispatchCell,
        " · worst failing: ", worstCell,
        " · ", envelopeCell,
        " · preloads in window: ", preloadCell,
        " · signed registry: ", registryCell,
        " · gate refusals in window: ", refusalCell,
        " · approval latency: ", approvalLatencyCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    // The artifact boundary outranks an otherwise-partial lane. A missing
    // audit feed must not hide a malformed `active/` directory or a split
    // registry/active commit: both are actionable damage in the one source
    // that DID read.
    if sysToolStatus == .unreadable {
        sev = .unreadable; why = "a tool-lane source could not be read"
    } else if toolArtifactDirectories.contains(where: { $0.present && !$0.readable }) {
        sev = .unreadable
        let malformed = toolArtifactDirectories
            .filter { !$0.nonDirectoryEntries.isEmpty }
            .flatMap { directory in directory.nonDirectoryEntries.map { "\(directory.relativePath)/\($0)" } }
            .sorted()
        why = malformed.isEmpty
            ? "a tool artifact directory could not be listed"
            : "active tool artifact entries must be directories (\(malformed.prefix(3).joined(separator: ", ")))"
    } else if !registryWithoutActiveArtifact.isEmpty || !activeArtifactWithoutRegistry.isEmpty {
        sev = .failureStreak
        why = "tool registry and active artifact IDs diverge"
    } else if sysToolStatus == .absent {
        sev = .absentExpected; why = "no trace, registry or audit feed on this root"
    } else if sysToolStatus == .partial {
        sev = .absentExpected; why = "part of the tool lane is missing on this root"
    } else if let worst = sysToolBroken.first {
        sev = .failureStreak
        why = "tool `\(mdCode(worst.name))` failed \(worst.stat.failed)× against \(worst.stat.ok) success(es)"
        if let top = worst.stat.errorDetails.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first {
            why += "; top reason: `\(mdCode(shortDetail(top.key)))`×\(top.value)"
        }
    } else if toolDispatchInWindow == 0, toolDispatchRowsTotal > 0 {
        sev = .stale
        why = "no tool dispatch in the \(runtimeEvidenceLabel)"
            + (toolDispatchNewest.map { " (newest \(stamp($0)))" } ?? "")
    }
    sysRows.append(SysRow(id: "SYS-10", organ: "Tools (dispatch outcomes, registry, gate refusals)",
                          status: sysToolStatus, sourceLabels: sysToolLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-11 sync ──
let sysSyncLabels = ["icloud/chat_delivery_receipts.jsonl", "icloud/processed_ids.json",
                     "icloud/snapshot_digests.json", "mobile_snapshot_cache/",
                     "mobile/signed_peer_evidence.json", "mobile_push/tokens.json",
                     "public_sync/last_status.json"]
let sysSyncStatus = sysStatus(sysSyncLabels)
/// A cached snapshot older than this has stopped being refreshed for the
/// companion. The writer refreshes on state change, so a week-old snapshot on a
/// live root means that surface stopped publishing, not that nothing happened.
let snapshotStaleDays = 7.0
do {
    let receiptCell = sysCell("icloud/chat_delivery_receipts.jsonl",
        "**\(icloudRowsInWindow)** in window"
        + (icloudNewest.map { ", newest \(stamp($0))" } ?? ", **no dated row**"))
    let processedCell = sysCell("icloud/processed_ids.json",
        icloudProcessedIDs.map { "**\($0)**" } ?? "source absent")
    let snapshotCell = sysCell("mobile_snapshot_cache/", [
        "**\(snapshotFiles.count)** cached",
        (stalestSnapshot.map { ", stalest `\(mdCode($0.name))` " + ($0.modified.map(ageDaysText) ?? "undated")
            + " old" } ?? ""),
        (digestsWithoutSnapshot.isEmpty ? "" : ", **\(digestsWithoutSnapshot.count) digest(s) with no cached file**"),
        (snapshotsWithoutDigest.isEmpty ? "" : ", \(snapshotsWithoutDigest.count) cached with no digest"),
        (snapshotCacheStrays == 0 ? "" : ", \(snapshotCacheStrays) unrecognized entr\(snapshotCacheStrays == 1 ? "y" : "ies") (not parsed)")
    ].joined())
    let queueCell = sysCell("mobile_snapshot_cache/", [
        "**\(syncTransactionsUnanswered)** unanswered of \(syncTransactionsTotal)",
        (syncTransactionsRetried > 0 ? ", \(syncTransactionsRetried) retried" : ""),
        (syncTransactionsUnparseable > 0 ? ", **\(syncTransactionsUnparseable) unparseable**" : ""),
        (syncTransactionNewest.map { ", newest \(stamp($0))" } ?? "")
    ].joined())
    let ackCell = sysCell("mobile_snapshot_cache/",
        "**\(snapshotCacheResponses)**"
        + (snapshotResponseStatuses.isEmpty ? "" : " (\(topCounts(snapshotResponseStatuses, 3)))"))
    let peerCell = sysCell("mobile/signed_peer_evidence.json", [
        peerEvidenceChannel.map { "`\(mdCode($0))`" } ?? "**no `channel` field**",
        (peerEvidenceObservedAt.map { " observed \(stamp($0)) (\(ageHoursText($0)) ago)" }
            ?? ", **no `observedAt` field**"),
        (peerEvidenceSkewSeconds.map { ", peer skew \(fmt($0, 0))s" } ?? "")
    ].joined())
    let tokenCell = sysCell("mobile_push/tokens.json",
        mobilePushTokenCount.map { "**\($0)**" } ?? "source absent")
    let publicCell = sysCell("public_sync/last_status.json", [
        publicSyncResult.map { "`\(mdCode($0))`" } ?? "**no `result` field**",
        (publicSyncStage.map { " at stage `\(mdCode($0))`" } ?? ""),
        (publicSyncRecordedAt.map { ", \(stamp($0)) (\(ageDaysText($0)) ago)" } ?? "")
    ].joined())
    let reading = sysBlockedReading(sysSyncStatus, sysSyncLabels) ?? [
        "iCloud chat receipts: ", receiptCell,
        " · processed ids: ", processedCell,
        " · companion snapshots: ", snapshotCell,
        " · write-back queue: ", queueCell,
        " · companion acks: ", ackCell,
        " · signed peer evidence: ", peerCell,
        " · paired tokens: ", tokenCell,
        " · public sync: ", publicCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysSyncStatus {
    case .unreadable: sev = .unreadable; why = "a sync source could not be read"
    case .absent: sev = .absentExpected; why = "no iCloud, snapshot-cache or public-sync state on this root"
    case .partial: sev = .absentExpected; why = "part of the sync lane is missing on this root"
    default:
        if !digestsWithoutSnapshot.isEmpty {
            sev = .failureStreak
            why = "\(digestsWithoutSnapshot.count) snapshot digest(s) name a file that is not cached"
        } else if syncTransactionsUnparseable > 0 {
            sev = .failureStreak; why = "\(syncTransactionsUnparseable) sync transaction(s) will not parse"
        } else if let r = publicSyncResult, r != "succeeded" {
            sev = .failureStreak; why = "last public sync `\(mdCode(r))`, not `succeeded`"
        } else if let s = stalestSnapshot, let m = s.modified, daysSince(m) > snapshotStaleDays {
            sev = .stale
            why = "companion snapshot `\(mdCode(s.name))` last refreshed \(fmt(daysSince(m), 1))d ago"
        }
    }
    sysRows.append(SysRow(id: "SYS-11", organ: "Sync (iCloud bridge, companion snapshots, paired devices)",
                          status: sysSyncStatus, sourceLabels: sysSyncLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-12 chat sessions ──
let sysChatLabels = ["chat/sessions.json", "chat/messages/", "chat/archive/sessions.jsonl",
                     "chat/pinned_session_ids.json", "chat/mac_turn_lifecycle.json"]
let sysChatStatus = sysStatus(sysChatLabels)
do {
    let sessionCell = sysCell("chat/sessions.json", [
        "**\(chatSessions.count)**",
        (chatSessionsBySource.isEmpty ? "" : " (\(topCounts(chatSessionsBySource, 3)))"),
        ", **\(chatSessionsInWindow)** touched in window",
        (chatSessionsWithoutCount > 0 ? ", **\(chatSessionsWithoutCount) with no `messageCount`**" : "")
    ].joined())
    let retentionCell = sysCell("chat/sessions.json",
        (chatOldestCreated.map { "oldest \(stamp($0)) (\(ageDaysText($0)) ago)" } ?? "**no dated session**")
        + (chatNewestUpdated.map { ", newest update \(stamp($0))" } ?? ""))
    let archiveCell = sysCell("chat/archive/sessions.jsonl", [
        "**\(chatArchivedTotal)**",
        (chatArchiveOldest.map { ", oldest \(stamp($0))" } ?? ""),
        (chatArchiveNewest.map { ", newest \(stamp($0))" } ?? "")
    ].joined())
    // The turn-volume cell is gated on `chat/sessions.json`, because the
    // message files are only found through it — but it reports how many files
    // it OPENED, so a capped or short read can never masquerade as the whole.
    let turnCell = sysCell("chat/sessions.json", [
        "**\(chatTurnsBySurfaceInWindow.values.reduce(0, +))**",
        (chatTurnsBySurfaceInWindow.isEmpty ? "" : " (\(topCounts(chatTurnsBySurfaceInWindow, 3)))"),
        ", user **\(chatUserTurnsInWindow)** / assistant **\(chatAssistantTurnsInWindow)**",
        " — from \(chatMessageFilesOpened) message file(s) opened",
        (chatMessageFilesMissing > 0 ? ", **\(chatMessageFilesMissing) session(s) have no message file**" : ""),
        (chatMessageRowsMalformed > 0 ? ", \(chatMessageRowsMalformed) malformed row(s)" : "")
    ].joined())
    // Deliberately a bare count with no `?? "source absent"` fallback: the
    // PER-FEED GUARD is what must catch the absent feed here. A second,
    // belt-and-braces Optional would make the guard untestable on this organ,
    // and a guard nothing exercises is one refactor from silently not working.
    let pinnedCell = sysCell("chat/pinned_session_ids.json", "**\(chatPinnedSessions ?? 0)**")
    let outcomeDistribution = chatOutcomeDimensions.map { dimension in
        let counts = chatOutcomeStateCounts[dimension] ?? [:]
        return "`\(mdCode(dimension))` [\(counts.isEmpty ? "no observations" : topCounts(counts, 6))]"
    }.joined(separator: "; ")
    let measuredOutcomeCell = [
        "assistant rows **\(chatOutcomeAssistantRows)**",
        "valid observations **\(chatOutcomeAssistantRows - chatOutcomeObservationsAbsent)**",
        "absent **\(chatOutcomeObservationsAbsent)** (reported separately, not zero)",
        (chatOutcomeObservationsInvalid > 0
            ? "invalid **\(chatOutcomeObservationsInvalid)**"
            : "invalid **0**"),
        "states: \(outcomeDistribution)",
        (chatOutcomeDarkDimensions.isEmpty
            ? "no >95% dark lane"
            : "**dark >95%:** " + chatOutcomeDarkDimensions.map {
                "`\(mdCode($0.dimension))`=`\(mdCode($0.state))`"
              }.joined(separator: ", ")),
    ].joined(separator: " · ")
    let outcomeCell = chatMessagesPopulationReadable
        ? measuredOutcomeCell
        : "**source absent** — canonical `chat/messages/` population is unavailable. This is not a zero."
    let reading = sysBlockedReading(sysChatStatus, sysChatLabels) ?? [
        "sessions: ", sessionCell,
        " · retention: ", retentionCell,
        " · archived: ", archiveCell,
        " · turns in window: ", turnCell,
        " · outcome dimensions: ", outcomeCell,
        " · pinned: ", pinnedCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysChatStatus {
    case .unreadable: sev = .unreadable; why = "a chat store source could not be read"
    case .absent: sev = .absentExpected; why = "no chat session index on this root"
    case .partial: sev = .absentExpected; why = "part of the chat store is missing on this root"
    default:
        if chatSessionsFeed.didRead, !chatMessagesPopulationReadable {
            sev = .failureStreak
            why = "canonical chat message population is absent; outcome dimensions are unavailable, not zero"
        } else if chatMessageFilesMissing > 0 {
            sev = .failureStreak
            why = "\(chatMessageFilesMissing) in-window session(s) have an index row but no message file"
        } else if chatOutcomeObservationsAbsent > 0 {
            sev = .failureStreak
            why = "\(chatOutcomeObservationsAbsent) assistant outcome observation(s) absent or invalid"
        } else if let dark = chatOutcomeDarkDimensions.first {
            sev = .failureStreak
            why = "outcome dimension `\(mdCode(dark.dimension))` is >95% `\(mdCode(dark.state))`"
        } else if chatSessionsFeed.didRead, chatSessionsInWindow == 0, !chatSessions.isEmpty {
            sev = .stale
            why = "no chat session updated in the \(days)d window"
                + (chatNewestUpdated.map { " (newest \(stamp($0)))" } ?? "")
        }
    }
    sysRows.append(SysRow(id: "SYS-12", organ: "Chat sessions (index, retention, turn volume, outcome evidence)",
                          status: sysChatStatus, sourceLabels: sysChatLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-13 security / trust ──
let sysSecurityLabels = ["security/audit.jsonl", "security/canary_trips.jsonl",
                         "security/mac_integration_permissions.json",
                         "security/autonomy_promotion/last_scan", "trust/policy.json",
                         "workflows/approvals/requests.json", "workflows/approvals/effect_spends.json"]
    + macControlLabels
let sysSecurityStatus = sysStatus(sysSecurityLabels)
do {
    let gateCell = sysCell("security/audit.jsonl", [
        "**\(auditRowsInWindow)** of \(auditRowsTotal) row(s)",
        (auditDecisions.isEmpty ? "" : " (\(topCounts(auditDecisions, 3)))"),
        ", refused **\(auditRefusalsInWindow)**",
        (auditRisk.isEmpty ? "" : " · risk \(topCounts(auditRisk, 3))")
    ].joined())
    let escalationCell = sysCell("security/audit.jsonl",
        "**\(auditApprovalRequiredInWindow)** requiring approval, "
        + "\(auditUntrustedOriginInWindow) from an untrusted origin")
    let approvalCell = sysCell("workflows/approvals/requests.json", [
        "**\(approvalsTotal)** total, \(approvalsInWindow) raised in window",
        (approvalDecisions.isEmpty ? "" : " (\(topCounts(approvalDecisions, 3)))"),
        (approvalPending > 0
            ? ", **\(approvalPending) unanswered**"
              + (approvalOldestPending.map { " (oldest \(stamp($0)), \(ageDaysText($0)) ago)" } ?? "")
            : "")
    ].joined())
    let canaryCell = sysCell("security/canary_trips.jsonl", [
        "**\(canaryTripsInWindow)** in window of \(canaryTripsTotal)",
        (canaryKinds.isEmpty ? "" : " (\(topCounts(canaryKinds, 3)))"),
        (canaryNewest.map { ", newest \(stamp($0))" } ?? "")
    ].joined())
    let macCell = sysCell(macControlLabels, [
        "**\(macControlInWindow)** in window of \(macControlRowsTotal)",
        (macControlBlocked > 0 ? ", **\(macControlBlocked) blocked**" : ""),
        (macControlNonZeroExit > 0 ? ", \(macControlNonZeroExit) non-zero exit" : ""),
        (macControlCategories.isEmpty ? "" : " (\(topCounts(macControlCategories, 3)))")
    ].joined())
    let permissionCell = sysCell("security/mac_integration_permissions.json",
        macPermissionGrants.map { "**\(macPermissionGranted)**/\($0) grant(s) across "
            + "\(macPermissionKeys ?? 0) integration(s)" } ?? "source absent")
    let scanCell = sysCell("security/autonomy_promotion/last_scan",
        autonomyLastScan.map { "\(stamp($0)) (\(ageDaysText($0)) ago)" } ?? "source absent")
    // Same reasoning as SYS-12's pinned cell: the per-feed guard is the only
    // thing standing between an absent `trust/policy.json` and a rendered 0.
    let policyCell = sysCell("trust/policy.json", "**\(trustPolicyKeys ?? 0)** top-level key(s); security posture "
        + "\(securityPolicyExplicitCount) explicit / \(securityPolicyDefaultedCount) defaulted")
    let policyProtectionCell = sysCell("trust/policy.json", securityPolicyPostureKnown
        ? "**\(securityPolicyProtectedEnabledCount)/\(securityPolicyProtectedKeys.count) enabled**"
          + (securityPolicyWeakened.isEmpty ? "" : "; **weakened:** \(securityPolicyWeakened.joined(separator: ", "))")
        : "security posture indeterminate")
    let spendCell = sysCell("workflows/approvals/effect_spends.json",
        effectSpends.map { "**\($0)**" + (effectSpendNewest.map { d in ", newest \(stamp(d))" } ?? "") }
            ?? "source absent")
    let reading = sysBlockedReading(sysSecurityStatus, sysSecurityLabels) ?? [
        "gate decisions in window: ", gateCell,
        " · escalations: ", escalationCell,
        " · approval inbox: ", approvalCell,
        " · canary trips: ", canaryCell,
        " · mac-control audit: ", macCell,
        " · mac permissions: ", permissionCell,
        " · autonomy promotion scan: ", scanCell,
        " · trust policy: ", policyCell,
        " · effective protective controls: ", policyProtectionCell,
        " · effect spends: ", spendCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysSecurityStatus {
    case .unreadable: sev = .unreadable; why = "a security or trust source could not be read"
    case .absent: sev = .absentExpected; why = "no audit, policy or approval source on this root"
    case .partial: sev = .absentExpected; why = "part of the security lane is missing on this root"
    default:
        if securityPolicyPostureKnown, !securityPolicyWeakened.isEmpty {
            sev = .failureStreak
            why = "protective controls disabled: \(securityPolicyWeakened.joined(separator: ", "))"
        } else if canaryTripsInWindow > 0 {
            sev = .failureStreak; why = "\(canaryTripsInWindow) canary trip(s) in window"
        } else if approvalPending > 0 {
            sev = .failureStreak
            why = "\(approvalPending) approval request(s) never answered"
                + (approvalOldestPending.map { ", oldest \(fmt(daysSince($0), 0))d old" } ?? "")
        } else if auditFeed.didRead, auditRowsInWindow == 0, auditRowsTotal > 0 {
            sev = .stale
            why = "the gate graded nothing in the \(days)d window"
                + (auditNewest.map { " (newest \(stamp($0)))" } ?? "")
        }
    }
    sysRows.append(SysRow(id: "SYS-13", organ: "Security / trust (gate decisions, approvals, mac control)",
                          status: sysSecurityStatus, sourceLabels: sysSecurityLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-14 update lane ──
//
// The ONLY organ with no source inside the data root. Its status is derived
// from the two machine-global sources exactly like every other organ derives
// its status from its own labels — an empty label list reads `absent`, which is
// precisely what a fixture root or `--no-machine-state` should produce.
let sysUpdateLabels = updateLabels
let sysUpdateStatus = sysStatus(sysUpdateLabels)
do {
    let infoLabel = "update/Info.plist"
    let versionCell = sysCell(infoLabel,
        (updateBundleVersion.map { "`\(mdCode($0))`" } ?? "**no `CFBundleShortVersionString`**")
        + (updateBundleBuild.map { " (build \(mdText($0)))" } ?? ""))
    // The honesty flag is the whole point of this organ: an app that ships a
    // "Check for Updates…" with no published feed is the failure the flag
    // exists to prevent. A MISSING flag is reported as missing, never false.
    let honestyCell = sysCell(infoLabel, updateFeedPublished.map { $0 ? "**true**" : "**false**" }
        ?? "**no `NativeAgentUpdateFeedPublished` key** — updater stays off")
    let feedCell = sysCell(infoLabel, updateFeedURL.map { "`\(mdCode(String($0.prefix(72))))`" }
        ?? "**no `SUFeedURL` key**")
    let keyCell = sysCell(infoLabel, updateSigningKeyPresent ? "present" : "**no `SUPublicEDKey`**")
    let sparkleCell: String = {
        guard let bid = updateBundleID else { return "source absent" }
        let prefsLabel = "update/\(bid).plist"
        return sysCell(prefsLabel, updateSparkleKeys.isEmpty
            ? "**no Sparkle key ever written** — the updater has never run"
            : updateSparkleKeys.sorted { $0.key < $1.key }
                .map { "`\(mdCode($0.key))`=\(mdText($0.value))" }.joined(separator: ", "))
    }()
    let noticeCell: String = {
        guard let bid = updateBundleID else { return "source absent" }
        return sysCell("update/\(bid).plist",
                       updateNoticePersisted == true ? "a persisted update notice is pending" : "none")
    }()
    let scheduledCheckCell: String = {
        guard let bid = updateBundleID else { return "source absent" }
        let prefsLabel = "update/\(bid).plist"
        guard updateFeedPublished == true else {
            return sysCell(prefsLabel, "not expected — this build has no published feed")
        }
        if updateAutomaticChecksEnabled == false {
            return sysCell(prefsLabel, "automatic checks disabled by preference")
        }
        guard updateScheduleContextMatches, let activatedAt = updateScheduleActivatedAt else {
            return sysCell(prefsLabel, "**no activation receipt for this installed build/feed**")
        }
        let intervalHours = fmt(updateScheduledCheckInterval / 3600, 1)
        if let failedAt = updateLastScheduledFailureAt,
           failedAt >= activatedAt,
           failedAt >= (updateLastScheduledCheckAt ?? .distantPast) {
            return sysCell(prefsLabel, "**failed** at `\(stamp(failedAt))` (\(ageHoursText(failedAt)) ago)")
        }
        guard let completedAt = updateLastScheduledCheckAt, completedAt >= activatedAt else {
            let deadline = activatedAt.addingTimeInterval(updateScheduledCheckInterval)
            return sysCell(prefsLabel, now > deadline
                ? "**no scheduled check landed** by `\(stamp(deadline))` (\(intervalHours)h interval)"
                : "awaiting first scheduled check by `\(stamp(deadline))` (\(intervalHours)h interval)")
        }
        let deadline = completedAt.addingTimeInterval(updateScheduledCheckInterval)
        return sysCell(prefsLabel, now > deadline
            ? "**stale** — last scheduled check `\(stamp(completedAt))` (\(ageHoursText(completedAt)) ago; \(intervalHours)h interval)"
            : "last scheduled check `\(stamp(completedAt))` (\(ageHoursText(completedAt)) ago; \(intervalHours)h interval)")
    }()
    let reading = sysBlockedReading(sysUpdateStatus, sysUpdateLabels) ?? [
        "installed bundle: ", versionCell,
        (updateBundlePath.map { " at `\(mdCode(($0 as NSString).abbreviatingWithTildeInPath))`" } ?? ""),
        " · feed published (honesty flag): ", honestyCell,
        " · `SUFeedURL`: ", feedCell,
        " · signing key: ", keyCell,
        " · Sparkle state: ", sparkleCell,
        " · scheduled check: ", scheduledCheckCell,
        " · pending notice: ", noticeCell,
        " · **the data root persists nothing for this organ** — update state lives in "
            + "`UserDefaults` and the bundle `Info.plist`, both machine-global"
    ].joined()
    var sev = SysSeverity.healthy
    var why = "measured, inside bounds"
    switch sysUpdateStatus {
    case .unreadable: sev = .unreadable; why = "an update-lane source could not be read"
    case .absent, .partial:
        sev = .absentExpected
        why = machineStateDisabled ? "machine state disabled by `--no-machine-state`"
            : (dataRootIsInstallRoot
               ? "no installed app bundle found at either candidate path"
               : "machine-global update state stays out on a non-install data root")
    case .measured:
        // Published-vs-unpublished is the honesty contract, not an error: an
        // unpublished build is CORRECT to have no feed. What is wrong is the
        // mismatched pair — a flag that claims published with no feed URL, or a
        // feed URL the honesty flag does not vouch for.
        if updateFeedPublished == true, updateFeedURL == nil {
            sev = .failureStreak
            why = "`NativeAgentUpdateFeedPublished` is true but the bundle carries no `SUFeedURL`"
        } else if updateFeedURL != nil, updateFeedPublished != true {
            sev = .failureStreak
            why = "the bundle carries an `SUFeedURL` the honesty flag does not vouch for"
        } else if updateFeedPublished != true {
            sev = .stale
            why = "this build publishes no update feed — `Check for Updates…` stays off by design"
        } else if updateAutomaticChecksEnabled == false {
            sev = .stale
            why = "automatic Sparkle checks are disabled by preference"
        } else if !updateScheduleContextMatches || updateScheduleActivatedAt == nil {
            sev = .stale
            why = "published updater has no scheduler activation receipt for this installed build/feed"
        } else if let activatedAt = updateScheduleActivatedAt,
                  let failedAt = updateLastScheduledFailureAt,
                  failedAt >= activatedAt,
                  failedAt >= (updateLastScheduledCheckAt ?? .distantPast) {
            sev = .failureStreak
            why = "scheduled Sparkle check failed \(ageHoursText(failedAt)) ago"
        } else if let activatedAt = updateScheduleActivatedAt,
                  (updateLastScheduledCheckAt == nil || updateLastScheduledCheckAt! < activatedAt),
                  now > activatedAt.addingTimeInterval(updateScheduledCheckInterval) {
            sev = .stale
            why = "no scheduled Sparkle check landed inside its \(fmt(updateScheduledCheckInterval / 3600, 1))h interval"
        } else if let completedAt = updateLastScheduledCheckAt,
                  let activatedAt = updateScheduleActivatedAt,
                  completedAt >= activatedAt,
                  now > completedAt.addingTimeInterval(updateScheduledCheckInterval) {
            sev = .stale
            why = "last scheduled Sparkle check was \(ageHoursText(completedAt)) ago, over its \(fmt(updateScheduledCheckInterval / 3600, 1))h interval"
        }
    }
    sysRows.append(SysRow(id: "SYS-14", organ: "Update lane (Sparkle feed, honesty flag, installed build)",
                          status: sysUpdateStatus, sourceLabels: sysUpdateLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-15 research connector evidence ──
let sysResearchLabels = [researchConfigLabel, researchLabRunsLabel, researchReceiptsLabel]
let sysResearchStatus = sysStatus(sysResearchLabels)
do {
    let configCell = sysCell(researchConfigLabel,
        researchConfigured == true
            ? "**true** (non-empty `searxng_base_url`; endpoint reachability is not claimed)"
            : "**false** (no non-empty `searxng_base_url`)")
    let runCell = sysCell(researchLabRunsLabel, {
        guard let count = researchLabRunsCount else { return "source unreadable" }
        let newest = researchLabNewest.map { "last run \(stamp($0)) (\(ageDaysText($0)) ago)" }
            ?? "**no dated lab run**"
        let statuses = researchLabStatusCounts.isEmpty ? "" : " (\(topCounts(researchLabStatusCounts, 3)))"
        return "**\(count)** saved lab run(s); \(newest)\(statuses)"
    }())
    let receiptCell = sysCell(researchReceiptsLabel, {
        guard let count = researchReceiptCount else { return "source unreadable" }
        return "**\(count)** receipt file(s)"
            + (researchReceiptNewest.map { "; newest \(stamp($0)) (\(ageDaysText($0)) ago)" } ?? "")
    }())
    let reading = sysBlockedReading(sysResearchStatus, sysResearchLabels) ?? [
        "configured=", configCell,
        " · lab evidence: ", runCell,
        " · direct connector receipts: ", receiptCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "configuration, lab evidence, and receipt family read cleanly"
    switch sysResearchStatus {
    case .unreadable:
        sev = .unreadable
        why = "a research source could not be read or did not have its persisted shape"
    case .absent:
        sev = .absentExpected
        why = "no research configuration, lab history, or receipt directory exists on this root"
        addLead(rank: 26, "Research connector evidence is absent",
                evidence: "`\(researchConfigLabel)`, `\(researchLabRunsLabel)`, and `\(researchReceiptsLabel)` "
                    + "are absent. The instrument therefore reports no run or receipt count — absence is not zero.",
                action: "If research is intended on this install, configure the connector and retain its first lab/run "
                    + "and direct-call receipts; otherwise this row truthfully records that the lane has no evidence.")
    case .partial:
        sev = .absentExpected
        why = "only part of the research evidence boundary exists on this root"
        addLead(rank: 24, "Research connector evidence is partial",
                evidence: "The SYS-15 row names each persisted authority: `\(researchConfigLabel)`, "
                    + "`\(researchLabRunsLabel)`, and `\(researchReceiptsLabel)`. A missing member is not rendered as a zero.",
                action: "Restore or intentionally create the missing authority before treating the available run or "
                    + "receipt count as a complete research history.")
    case .measured:
        if researchConfigured != true {
            sev = .stale
            why = "the connector is explicitly unconfigured; no endpoint reachability is claimed"
            addLead(rank: 24, "Research connector is not configured",
                    evidence: "`\(researchConfigLabel)` was read and has no non-empty `searxng_base_url`; "
                        + "`\(researchLabRunsLabel)` and `\(researchReceiptsLabel)` were also read.",
                    action: "Configure a reachable SearXNG base URL, then run one research pass and inspect its "
                        + "persisted status/receipt evidence rather than treating configuration as a successful call.")
        } else if let needsConnector = researchLabStatusCounts["needs_connector"], needsConnector > 0 {
            sev = .failureStreak
            why = "\(needsConnector) persisted lab run(s) recorded `needs_connector`"
            addLead(rank: 14, "Research lab recorded `needs_connector` outcome(s)",
                    evidence: "`\(researchLabRunsLabel)` contains \(needsConnector) `needs_connector` run(s); "
                        + "SYS-15 also reports configuration and direct-receipt provenance separately.",
                    action: "Verify the configured SearXNG service from the runtime host, then run a fresh lab pass. "
                        + "Do not treat a saved config file as proof that the connector completed work.")
        } else if researchLabRunsCount == 0 {
            sev = .stale
            why = "configured but no research-lab pass has ever been persisted"
            addLead(rank: 25, "Research is configured but has no persisted lab run",
                    evidence: "`\(researchConfigLabel)` has a non-empty connector setting, while "
                        + "`\(researchLabRunsLabel)` is a readable empty array and `\(researchReceiptsLabel)` "
                        + "was separately inspected.",
                    action: "Run a deliberate research-lab pass. Until then, this is an unexercised connector, not "
                        + "a measured zero-result search.")
        } else if let newest = researchLabNewest, daysSince(newest) > Double(days) {
            sev = .stale
            why = "newest research lab evidence is \(fmt(daysSince(newest), 1))d old"
            addLead(rank: 25, "Research lab evidence is stale",
                    evidence: "Newest `\(researchLabRunsLabel)` record is \(stamp(newest)) "
                        + "(\(ageDaysText(newest)) ago); direct receipts remain a separate source.",
                    action: "Run a fresh research pass if this connector is expected to stay operational, then inspect "
                        + "the persisted outcome rather than inferring health from an old configuration.")
        }
    }
    sysRows.append(SysRow(id: "SYS-15", organ: "Research connector (configuration, lab runs, direct receipts)",
                          status: sysResearchStatus, sourceLabels: sysResearchLabels,
                          reading: reading, severity: sev, severityReason: why))
}

// ── SYS-16 Browser operation lifecycle / instrument blind spot ──────────────
let sysBrowserLabels = [browserRunsLabel, browserReceiptsLabel]
let sysBrowserStatus = sysStatus(sysBrowserLabels)
do {
    let runsCell = sysCell(browserRunsLabel, {
        guard let count = browserRunCount else { return "source unreadable" }
        let headroom = max(0, browserRunRetentionCeiling - count)
        let statuses = browserRunStatusCounts.isEmpty ? "" : " (\(topCounts(browserRunStatusCounts, 4)))"
        return "**\(count) / \(browserRunRetentionCeiling)** retained; headroom **\(headroom)**\(statuses)"
    }())
    let runningCell = sysCell(browserRunsLabel, {
        guard browserRunCount != nil else { return "source unreadable" }
        return "**\(browserStaleRunning.count)**"
            + (browserStaleRunning.isEmpty ? "" : " (`\(mdCode(browserStaleRunning[0].id))` oldest \(ageHoursText(browserStaleRunning[0].createdAt)))")
    }())
    let projectionCell = sysCell(browserRunsLabel, {
        guard browserRunCount != nil else { return "source unreadable" }
        let stale = browserStaleProjectionRuns.count
        return "**\(stale)** stale run(s); **\(browserPendingProjectionEntries)** queued transition(s)"
            + (browserStaleProjectionRuns.isEmpty ? "" : " (`\(mdCode(browserStaleProjectionRuns[0].id))` oldest \(ageHoursText(browserStaleProjectionRuns[0].pendingAt)))")
    }())
    let receiptCell = sysCell(browserReceiptsLabel,
        browserLatestReceipt.map { "newest \(stamp($0)) (\(ageHoursText($0)) ago)" }
            ?? "**no dated browser receipt**")
    let reading = sysBlockedReading(sysBrowserStatus, sysBrowserLabels) ?? [
        "runs: ", runsCell,
        " · running >\(Int(browserStaleRunningHours))h: ", runningCell,
        " · pending projection >\(Int(browserStaleProjectionHours))h: ", projectionCell,
        " · receipts: ", receiptCell
    ].joined()
    var sev = SysSeverity.healthy
    var why = "canonical runs and derived receipts read cleanly, inside bounds"
    switch sysBrowserStatus {
    case .unreadable:
        sev = .unreadable
        why = "a Browser canonical run or receipt source could not be read"
    case .absent:
        sev = .absentExpected
        why = "no Browser operation stores exist on this root"
        addLead(rank: 26, "Browser operation evidence is absent",
                evidence: "`\(browserRunsLabel)` and `\(browserReceiptsLabel)` are absent, so the instrument does not infer a quiet Browser lane from zero rows.",
                action: "If Browser is enabled on this install, retain its canonical run store and derived receipts before treating the connector as observable.")
    case .partial:
        sev = .absentExpected
        why = "only part of the Browser operation evidence boundary exists"
        addLead(rank: 24, "Browser operation evidence is partial",
                evidence: "SYS-16 reads `\(browserRunsLabel)` for lifecycle state and `\(browserReceiptsLabel)` for derived evidence; one authority is missing.",
                action: "Restore the missing Browser authority before interpreting the available capacity or receipt reading as complete.")
    case .measured:
        if let count = browserRunCount, count >= browserRunRetentionCeiling {
            sev = .failureStreak
            why = "canonical Browser run store is at its \(browserRunRetentionCeiling)-run retention ceiling"
            addLead(rank: 10, "Browser run store has no eviction headroom",
                    evidence: "`\(browserRunsLabel)` contains \(count) retained runs (ceiling \(browserRunRetentionCeiling)); a new non-terminal run can block writes rather than being safely evicted.",
                    action: "Resolve or recover stranded Browser runs, then confirm a new operation can persist before relying on this connector.")
        } else if !browserStaleRunning.isEmpty {
            sev = .failureStreak
            why = "\(browserStaleRunning.count) Browser run(s) remain `running` for over \(Int(browserStaleRunningHours))h"
            addLead(rank: 11, "Browser run(s) are stranded in `running`",
                    evidence: "`\(browserRunsLabel)` has \(browserStaleRunning.count) `running` row(s) older than \(Int(browserStaleRunningHours))h; oldest is `\(mdCode(browserStaleRunning[0].id))` at \(stamp(browserStaleRunning[0].createdAt)).",
                    action: "Use the Browser recovery command to settle the persisted running row as outcome-unknown/failed; do not reopen an external effect merely because its process disappeared.")
        } else if !browserStaleProjectionRuns.isEmpty {
            sev = .failureStreak
            why = "\(browserStaleProjectionRuns.count) Browser run(s) have projections pending for over \(Int(browserStaleProjectionHours))h"
            addLead(rank: 11, "Browser receipt projection is not draining",
                    evidence: "`\(browserRunsLabel)` retains \(browserPendingProjectionEntries) queued transition(s); `\(browserStaleProjectionRuns.count) run(s) have been pending over \(Int(browserStaleProjectionHours))h.",
                    action: "Run the Browser receipt projection recovery, then verify the canonical outbox clears and the derived receipt stream advances.")
        }
    }
    sysRows.append(SysRow(id: "SYS-16", organ: "Browser connector (runs, recovery, derived receipts)",
                          status: sysBrowserStatus, sourceLabels: sysBrowserLabels,
                          reading: reading, severity: sev, severityReason: why))
}

let sysMeasuredCount = sysRows.filter { $0.status == .measured }.count
let sysPartialCount = sysRows.filter { $0.status == .partial }.count
let sysBlockedCount = sysRows.filter { $0.status == .absent || $0.status == .unreadable }.count
/// Worst = lowest severity, ties broken on the SYS id. Deterministic by
/// construction; see `SysSeverity` for the rule this implements.
let sysWorst = sysRows.min {
    $0.severity.rawValue == $1.severity.rawValue ? $0.id < $1.id
                                                 : $0.severity.rawValue < $1.severity.rawValue
}

line("<a id=\"sec-h\"></a>")
line()
line("## (h) System matrix (SYS) — the functional organs, one row each")
line()
line("Sections (a)–(g) grade the COGNITIVE system against `docs/SUBCONSCIOUS.md`. This one grades the")
line("FUNCTIONAL system against `docs/ARCHITECTURE_BLUEPRINT.md`: the bridges, the background loops,")
line("delegation, notification/push delivery, memory housekeeping, Workshop, the GitHub command lane,")
line("the heartbeat, providers/routing, tools, sync, chat sessions, security/trust, the update lane and")
line("research connector evidence, and Browser operation recovery. Status is derived from the SOURCES, never from a count — an organ whose feeds")
line("are missing reads `source absent` and one whose feeds exist but will not parse reads")
line("`source unreadable`. Neither is ever rendered as a zero.")
line()
line("**\(sysMeasuredCount)/\(sysRows.count) measured · \(sysPartialCount) partial · \(sysBlockedCount) absent-or-unreadable.** "
     + "Worst organ (severity rule: unreadable > absent-expected > failure-streak > stale > healthy): "
     + (sysWorst.map { "**\($0.id) \(mdComposed($0.organ))** — \(mdComposed($0.severityReason))" } ?? "none"))
line()
line("| # | organ | status / severity | source(s) | live reading |")
line("|---|---|---|---|---|")
for r in sysRows {
    let src = r.sourceLabels.isEmpty
        ? "*(none registered)*"
        : r.sourceLabels.map { "`\(mdCode($0))`" }.joined(separator: "<br>")
    line("| \(r.id) | \(mdComposed(r.organ)) | \(r.status.badge) · \(r.severity.badge) | \(mdComposed(src)) | \(mdComposed(r.reading)) |")
}
line()

// ── per-lane bridge detail ──
line("### SYS-01 detail — per bridge lane")
line()
if bridgeConfigRoot == nil {
    line("**source absent** — the bridge config root was not read"
         + (bridgeConfigDisabled ? " (`--no-bridge-config`)."
            : " (this data root is not an install root, so machine-global `~/.config` lanes stay out)."))
    line("No lane number is reported. This is not a zero.")
    line()
} else {
    line("| lane | dir | inbox (window/total, unread) | delivered (window) | terminal failed | unconsumed >24h | jobs (window/total) | held-unreleased | stale-heartbeat | preserved (undelivered/) |")
    line("|---|---|---|---|---|---|---|---|---|---|")
    for l in bridgeLanes {
        // No `undelivered/` directory means nothing was ever preserved on this
        // lane (the bridge creates it on first preserve) — a dash, not a zero
        // and not an absent source. Present-and-read prints the count and the
        // oldest reply's own completion stamp; present-and-blocked prints why.
        let preservedCell: String = {
            guard l.preservedDirPresent else { return "— (no undelivered/ dir)" }
            if let blocked = l.preserved.blockedLabel { return blocked }
            var cell = "\(l.preservedCount)\(l.preservedCapped ? " (capped at \(wakeJobFileCap))" : "")"
            if l.preservedUnparseable > 0 { cell += " (\(l.preservedUnparseable) unparseable)" }
            if let o = l.preservedOldest { cell += ", oldest \(stamp(o)) (\(ageDaysText(o)))" }
            return cell
        }()
        let inboxCell = l.inbox.blockedLabel
            ?? "\(l.inboxInWindow)/\(l.inboxRows), \(l.inboxUnread) unread"
        let delCell = l.deliveries.blockedLabel
            ?? "\(l.deliveriesInWindow)" + (l.deliveryStatuses.isEmpty ? "" : " (\(topCounts(l.deliveryStatuses, 2)))")
        let undCell = l.inbox.didRead ? "\(l.undeliveredOver24h)"
            + (l.undeliveredOldest.map { ", oldest \(stamp($0))" } ?? "") : "not computable"
        let terminalCell = l.inbox.didRead ? "\(l.terminalFailedUnread)"
            + (l.terminalFailedOldest.map { ", oldest \(stamp($0))" } ?? "") : "not computable"
        // `jobsPresent` only says the directory exists. A directory that exists
        // and could not be listed — or whose files will not parse — is
        // UNREADABLE here, and prints its reason instead of a job count.
        let jobsCell = l.jobs.blockedLabel
            ?? ("\(l.jobsInWindow)/\(l.jobsTotal)\(l.jobsCapped ? " (capped at \(wakeJobFileCap))" : "")"
              + (l.jobStates.isEmpty ? "" : " (\(topCounts(l.jobStates, 2)))"))
        line("| `\(mdCode(l.name))` | `\(mdCode((l.dirPath as NSString).abbreviatingWithTildeInPath))` | "
             + "\(mdComposed(inboxCell)) | \(mdComposed(delCell)) | \(mdComposed(terminalCell)) | \(mdComposed(undCell)) | "
             + "\(mdComposed(jobsCell)) | \(l.jobs.didRead ? String(l.jobsHeldUnreleased) : "—") | "
             + "\(l.jobs.didRead ? String(l.jobsStaleHeartbeat) : "—") | \(mdComposed(preservedCell)) |")
    }
    line()
}

// ── per-loop detail ──
line("### SYS-02 detail — per background loop")
line()
if sysLoopStatus == .unreadable {
    line("**source unreadable** — see the matrix row above; no per-loop number is derived.")
    line()
} else if loopLastRun.isEmpty && loopFailuresByLoop.isEmpty {
    line("**source absent** — `logs/background_loop_state.json` records no loop tick and")
    line("`logs/background_loop_failures.jsonl` no failure row on this data root. This is not a zero.")
    line()
} else {
    line("Every loop the scheduler has ever stamped, newest tick first. `failures (window)` is a LOWER")
    line("BOUND: the failure feed is line-capped and offline-classified errors are deliberately never")
    line("written, so an empty failure column is not proof of a healthy tick.")
    line()
    line("| loop | last tick | age | failures (window) | newest failure |")
    line("|---|---|---|---|---|")
    let allLoops = Set(loopLastRun.keys).union(loopFailuresByLoop.keys).union(loopFailureNewest.keys)
    // Newest tick first, TIES BROKEN ON NAME. Several loops are driven by the
    // same scheduler pass and land on the identical second; Swift's sort is not
    // stable, so without the name tiebreak two runs over a FROZEN root emit the
    // rows in different orders and the report stops being reproducible.
    for name in allLoops.sorted(by: {
        let a = loopLastRun[$0], b = loopLastRun[$1]
        if let a, let b { return a == b ? $0 < $1 : a > b }
        if a != nil { return true }
        if b != nil { return false }
        return $0 < $1
    }) {
        let tick = loopLastRun[name]
        let fails = loopFailuresByLoop[name] ?? 0
        line("| `\(mdCode(name))` | \(tick.map { stamp($0) } ?? "**never stamped**") | "
             + "\(tick.map { ageDaysText($0) } ?? "—") | "
             + "\(fails > 0 ? "**\(fails)**" : "0") | "
             + "\(loopFailureNewest[name].map { stamp($0) } ?? "—") |")
    }
    line()
    if !loopFailureSignatures.isEmpty {
        // Same tie rule as the loop table: equal counts sort by signature, or
        // two runs over the same bytes print a different top-6.
        line("- failure signatures in window: " + loopFailureSignatures
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(6).map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
        line()
    }
    if loopPushStampsInWindow > 0 {
        line("- `failure_push` stamps in window: \(loopPushStampsInWindow)")
        line()
    }
}

// ── per-surface provider detail ──
line("### SYS-09 detail — per surface: pin vs provider vs what actually ran")
line()
if sysProviderStatus == .unreadable {
    line("**source unreadable** — see the matrix row above; no per-surface number is derived.")
    line()
} else if surfacePins.isEmpty {
    line("**source absent** — neither `providers/surfaces.json` nor `providers/active.json` is on this")
    line("data root, so no surface pin exists to compare against. This is not a zero.")
    line()
} else {
    line("`pinned model` and `provider` come from the two pin files; `observed` comes from the")
    line("`llm.call` rows in the \(days)-day window. A surface with **no observed call** is not a")
    line("failure — it means nothing ran on that surface in the window, which is a different fact from a")
    line("pin nobody honoured. Sorted by call volume, ties on surface name.")
    line()
    line("| surface | pinned model | effort | provider | config on disk | calls (window) | observed model(s) | subs |")
    line("|---|---|---|---|---|---|---|---|")
    for pin in surfacePins.values.sorted(by: {
        $0.calls == $1.calls ? $0.surface < $1.surface : $0.calls > $1.calls
    }) {
        let observed = pin.calls == 0
            ? "—"
            : (sources.isPresent("traces/events.jsonl") && !sources.isUnreadable("traces/events.jsonl")
               ? topCounts(pin.observedModels, 2) : "source absent")
        // `config on disk` is only answerable when active.json read; without it
        // there IS no provider pin to resolve, so the cell says so.
        let configCell: String = pin.provider == nil ? "—" : (pin.providerConfigured ? "yes" : "**NO**")
        line("| `\(mdCode(pin.surface))` | \(pin.model.map { "`\(mdCode($0))`" } ?? "**unpinned**") | "
             + "\(pin.reasoningEffort.map(mdText) ?? "—") | "
             + "\(pin.provider.map { "`\(mdCode($0))`" } ?? "**unpinned**") | \(configCell) | "
             + "\(pin.calls) | \(mdComposed(observed)) | \(pin.substituted) |")
    }
    line()
    if !llmNonOKSignatures.isEmpty {
        line("- non-`ok` llm.call signatures in window: " + llmNonOKSignatures
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(6).map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
        line()
    }
    if !providerCredentialFiles.isEmpty {
        line("- provider configs on disk (shape only — no credential value is ever read out of these files): "
             + providerCredentialFiles.sorted { $0.key < $1.key }.map { id, v in
                 "`\(mdCode(id))`" + (v.parsed
                    ? " (\(v.authMode.map { "auth `\(mdCode($0))`" } ?? "no `auth_mode`")"
                      + (v.defaultModel.map { ", default `\(mdCode($0))`" } ?? "") + ")"
                    : " **(unparseable)**")
             }.joined(separator: ", "))
        line()
    }
    if !unservedProviderPins.isEmpty {
        line("- **Unknown routing-surface pins:** " + unservedProviderPins
            .map { "`\(mdCode($0))`" }.joined(separator: ", ")
            + ". These persisted keys are not in the canonical picker vocabulary and cannot route a turn.")
        line()
    }
    if !retiredProviderPins.isEmpty {
        line("- **Retired compatibility pins (not failures):** " + retiredProviderPins
            .map { "`\(mdCode($0))`" }.joined(separator: ", ")
            + ". These keys are recognized historical residue and no longer route a turn.")
        line()
    }
}

// ── per-tool detail ──
line("### SYS-10 detail — per tool, dispatch outcomes in \(runtimeEvidenceLabel)")
line()
if sysToolStatus == .unreadable {
    line("**source unreadable** — see the matrix row above; no per-tool number is derived.")
    line()
} else if !sources.isPresent("traces/events.jsonl") {
    line("**source absent** — `traces/events.jsonl` is not on this data root, so no dispatch outcome")
    line("exists to count. This is not a zero.")
    line()
} else if toolStats.isEmpty {
    line("`traces/events.jsonl` READ and carries **no `tool.dispatch` row inside the \(runtimeEvidenceLabel)**")
    line((toolDispatchNewest.map { "(newest dispatch anywhere in the feed: \(stamp($0)))." }
          ?? "(and none anywhere in the feed)."))
    line("That is a measured zero, not an absent source — the distinction the rest of this report keeps.")
    line()
} else {
    line("Ordered by failures, then by dispatch count, ties on tool name. `p95 ms` is over the")
    line("durations the rows carry; `refused` is the SEPARATE count of calls the security gate blocked")
    line("before dispatch — a refused call never becomes a `tool.dispatch` row at all.")
    line()
    line("`failure reason(s)` is the tracer's bounded `receipt.errorDetail` (top 2 by count); rows written")
    line("before 2026-08-21 carry none and say so — that is a missing field, not a reasonless failure.")
    line()
    line("| tool | dispatches | ok | failed | p95 ms | error class(es) | failure reason(s) | refused by gate |")
    line("|---|---|---|---|---|---|---|---|")
    let toolRows = toolStats.map { (name: $0.key, stat: $0.value) }.sorted {
        if $0.stat.failed != $1.stat.failed { return $0.stat.failed > $1.stat.failed }
        if $0.stat.total != $1.stat.total { return $0.stat.total > $1.stat.total }
        return $0.name < $1.name
    }
    for r in toolRows.prefix(25) {
        let p95 = r.stat.durations.isEmpty ? "—" : fmt(percentile(r.stat.durations.sorted(), 0.95), 0)
        // The refusal column is gated on the AUDIT feed, not the trace: with no
        // audit feed the answer is unknown, and a dash would read as zero.
        let refused = sources.isPresent("security/audit.jsonl") && !sources.isUnreadable("security/audit.jsonl")
            ? String(auditRefusalsByTool[r.name] ?? 0) : "unknown"
        line("| `\(mdCode(r.name))` | \(r.stat.total) | \(r.stat.ok) | "
             + "\(r.stat.failed > 0 ? "**\(r.stat.failed)**" : "0") | \(p95) | "
             + "\(r.stat.errorClasses.isEmpty ? "—" : mdComposed(topCounts(r.stat.errorClasses, 2))) | "
             + "\(r.stat.errorDetails.isEmpty ? "—" : topDetails(r.stat.errorDetails, 2)) | "
             + "\(refused) |")
    }
    line()
    if toolRows.count > 25 {
        line("**25 of \(toolRows.count) tools shown** — ordered worst-first, so nothing failing is hidden.")
        line()
    }
    if !toolDecisions.isEmpty {
        line("- receipt decisions: \(mdComposed(topCounts(toolDecisions, 4)))"
             + " · outcomes: \(mdComposed(topCounts(toolOutcomes, 4)))"
             + " · permanence: \(mdComposed(topCounts(toolPermanence, 4)))")
        line()
    }
}

line("### Tool execution artifact inventory")
line()
if case .absent = toolRegistryFeed {
    line("**source absent** — `tools/registry.json` is not on this data root. This is not an empty registry.")
} else if sources.isUnreadable("tools/registry.json") {
    line("**source unreadable** — `tools/registry.json`: \(mdText(sources.reason("tools/registry.json"))). "
         + "No registry count is derived from damaged bytes.")
} else {
    let registryState = (toolRegistryEntries ?? 0) == 0 ? "**EMPTY**" : "populated"
    let registryModified = (try? fm.attributesOfItem(atPath: rootPath("tools/registry.json"))[.modificationDate]) as? Date
    line("- registry: \(registryState), **\(toolRegistryEntries ?? 0)** row(s); newest file stamp "
         + (registryModified.map { stamp($0) + " (\(ageDaysText($0)))" } ?? "unknown"))
}
for directory in toolArtifactDirectories {
    let name = directory.relativePath + "/"
    if !directory.present {
        line("- `\(mdCode(name))`: **absent**")
    } else if !directory.readable {
        line("- `\(mdCode(name))`: **unreadable**")
    } else {
        line("- `\(mdCode(name))`: **\(directory.ids.count)** opaque artifact entr\(directory.ids.count == 1 ? "y" : "ies")"
             + (directory.newest.map { ", newest \(stamp($0)) (\(ageDaysText($0)))" } ?? ", no entry timestamp"))
    }
    if !directory.nonDirectoryEntries.isEmpty {
        line("  - **invalid non-directory entries:** " + directory.nonDirectoryEntries.sorted().prefix(5)
            .map { "`\(mdCode($0))`" }.joined(separator: ", "))
    }
}

if !registryWithoutActiveArtifact.isEmpty {
    line("- **registry rows without `active/` artifact:** " + registryWithoutActiveArtifact.prefix(5)
        .map { "`\(mdCode($0))`" }.joined(separator: ", "))
}
if !activeArtifactWithoutRegistry.isEmpty {
    line("- **`active/` artifacts without registry row:** " + activeArtifactWithoutRegistry.prefix(5)
        .map { "`\(mdCode($0))`" }.joined(separator: ", "))
}
line()

line("### Skill registry inventory")
line()
if case .absent = skillRegistryFeed {
    line("**source absent** — `skills/registry.json` is not on this data root. This is not an empty skill registry.")
} else if sources.isUnreadable("skills/registry.json") {
    line("**source unreadable** — `skills/registry.json`: \(mdText(sources.reason("skills/registry.json"))). "
         + "No skill count is derived from damaged bytes.")
} else if let count = skillRegistryEntries {
    let state = count == 0 ? "**EMPTY**" : "populated"
    line("- registry: \(state), **\(count)** row(s)"
         + (skillRegistryStatuses.isEmpty ? "" : " · status: \(mdComposed(topCounts(skillRegistryStatuses, 6)))")
         + (skillRegistryNewest.map { " · newest record stamp \(stamp($0)) (\(ageDaysText($0)))" } ?? ""))
    if skillRegistryNonObjectRows > 0 {
        line("- **\(skillRegistryNonObjectRows)** non-object row(s) — retained in the row count but cannot participate in lazy discovery.")
    }
}
line()

// ── companion snapshot detail ──
line("### SYS-11 detail — companion snapshot freshness")
line()
if sysSyncStatus == .unreadable {
    line("**source unreadable** — see the matrix row above; no per-snapshot number is derived.")
    line()
} else if !snapshotCachePresent {
    line("**source absent** — `mobile_snapshot_cache/` is not on this data root. This is not a zero.")
    line()
} else if snapshotFiles.isEmpty {
    line("`mobile_snapshot_cache/snapshots/` "
         + (snapshotCacheState.didRead ? "READ and holds no snapshot file."
            : "could not be listed — see the matrix row."))
    line()
} else {
    line("One row per snapshot the iOS companion reads. `digest` says whether")
    line("`icloud/snapshot_digests.json` also names it — a digest with no file is a snapshot the")
    line("companion is told exists and cannot fetch. Oldest first, ties on name.")
    line()
    line("| snapshot | size | last written | age | digest |")
    line("|---|---|---|---|---|")
    for s in snapshotFiles.sorted(by: { a, b in
        let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
        return x == y ? a.name < b.name : x < y
    }) {
        line("| `\(mdCode(s.name))` | \(humanBytes(s.bytes)) | "
             + "\(s.modified.map { stamp($0) } ?? "**undated**") | "
             + "\(s.modified.map { ageDaysText($0) } ?? "—") | "
             + "\(snapshotDigestKeys.contains(s.name) ? "yes" : "no") |")
    }
    line()
    if !digestsWithoutSnapshot.isEmpty {
        line("- **digest entries with no cached file**: "
             + digestsWithoutSnapshot.map { "`\(mdCode($0))`" }.joined(separator: ", "))
        line()
    }
}

// ── security detail ──
line("### SYS-13 detail — what the gate refused, and who answered")
line()
if sysSecurityStatus == .unreadable {
    line("**source unreadable** — see the matrix row above; no security number is derived.")
    line()
} else if !sources.isPresent("security/audit.jsonl") && !approvalsFeed.didRead {
    line("**source absent** — neither `security/audit.jsonl` nor `workflows/approvals/requests.json` is")
    line("on this data root. This is not a zero.")
    line()
} else {
    if sources.isPresent("security/audit.jsonl"), !sources.isUnreadable("security/audit.jsonl") {
        line("Gate refusals in the \(days)-day window, by tool. Ties on tool name.")
        line()
        if auditWorstRefused.isEmpty {
            line("- **0 refusals in window** — measured, from \(auditRowsInWindow) graded row(s).")
        } else {
            line("| tool | refused | dispatched (window) |")
            line("|---|---|---|")
            for (tool, n) in auditWorstRefused.prefix(12) {
                let dispatched = sources.isPresent("traces/events.jsonl")
                    && !sources.isUnreadable("traces/events.jsonl")
                    ? String(toolStats[tool]?.total ?? 0) : "unknown"
                line("| `\(mdCode(tool))` | **\(n)** | \(dispatched) |")
            }
        }
        line()
        if !auditRefusalReasons.isEmpty {
            line("- refusal reasons: " + auditRefusalReasons
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(6).map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", "))
            line()
        }
        line("- audit retention: "
             + (auditOldest.map { "oldest \(stamp($0))" } ?? "**no dated row**")
             + (auditNewest.map { ", newest \(stamp($0))" } ?? "")
             + ", \(auditRowsTotal) row(s) total")
        line()
    }
    if approvalsFeed.didRead {
        line("- approval inbox: \(approvalsTotal) request(s), decisions "
             + mdComposed(topCounts(approvalDecisions, 5))
             + (approvalLatenciesHours.isEmpty ? ""
                : " · resolution latency p50 "
                  + "\(fmt(percentile(approvalLatenciesHours.sorted(), 0.5), 1))h, p95 "
                  + "\(fmt(percentile(approvalLatenciesHours.sorted(), 0.95), 1))h"))
        line()
    }
}
line("#### Effective security-policy posture")
line()
if sources.isUnreadable("trust/policy.json") {
    line("**source unreadable** — the saved `securityPolicy` has an invalid authority shape, so no effective")
    line("value is inferred. TrustCenter must fail closed rather than borrow defaults from damaged bytes.")
    line()
} else if securityPolicyPostureRows.isEmpty {
    line("**source absent** — no trust policy source was available to classify.")
    line()
} else {
    line("Each row names the value the checked TrustCenter read will enforce and whether it came from saved")
    line("authority or the canonical default. `default` is not a user choice.")
    line()
    line("| securityPolicy key | effective value | provenance |")
    line("|---|---|---|")
    for row in securityPolicyPostureRows {
        line("| `\(mdCode(row.key))` | \(row.effectiveValue) | \(row.provenance.reportText) |")
    }
    line()
}

// ── SYS leads ───────────────────────────────────────────────────────────────
// Every lead below is raised ONLY from an organ that actually READ. A blocked
// organ raises no lead — its own `source absent` / `source unreadable` line is
// the finding, and inventing a threshold breach from an unread feed is the
// silent zero this instrument exists to catch.
if sysBridgeStatus == .measured || sysBridgeStatus == .partial {
    if brTerminalFailed > 0 {
        let lanes = bridgeLanes.filter { $0.terminalFailedUnread > 0 }
        addLead(rank: 5, "\(brTerminalFailed) bridge message(s) terminally failed delivery",
                evidence: "Unread bridge inbox rows carrying the durable `deliveryStatus=dead_letter` projection: "
                    + lanes.map { "`\(mdCode($0.name))`×\($0.terminalFailedUnread)" }.joined(separator: ", ")
                    + (brTerminalFailedOldest.map { "; oldest failure \(stamp($0))" } ?? "") + ".",
                action: "These messages are no longer queued and will not replay automatically. Review the retained brief, then resend as new work or mark it read.")
    }
    if brUndelivered > 0 {
        let worstLane = bridgeLanes.filter { $0.undeliveredOver24h > 0 }
            .sorted { $0.undeliveredOver24h == $1.undeliveredOver24h ? $0.name < $1.name : $0.undeliveredOver24h > $1.undeliveredOver24h }.first
        addLead(rank: 6, "\(brUndelivered) bridge message(s) have sat unconsumed for over 24h",
                evidence: "Bridge inbox rows with neither an explicit read/consumed stamp nor a legacy matching reply receipt, and a "
                    + "`createdAt` older than 24h: \(brUndelivered) across \(bridgeLanes.filter { $0.undeliveredOver24h > 0 }.count) lane(s)"
                    + (worstLane.map { ", worst `\(mdCode($0.name))` (\($0.undeliveredOver24h)"
                        + ($0.undeliveredOldest.map { o in ", oldest \(stamp(o))" } ?? "") + ")" } ?? "")
                    + ". Counted only from inbox lanes that READ — see [(h) SYS-01 detail](#sec-h).",
                action: "A message with no consumption stamp was never handed to its agent. Check the lane's inbox "
                    + "consumer and its read/consumed writeback; a backlog this old means the sender believes it "
                    + "was delivered and nobody read it.")
    }
    if brHeld > 0 {
        let heldLanes = bridgeLanes.filter { $0.jobsHeldUnreleased > 0 }
        addLead(rank: 7, "\(brHeld) wake job(s) are still under an unreleased COMMIT HOLD",
                evidence: "Wake-job files with `commitPolicy=\"hold\"` and a null `holdReleasedAt`: "
                    + heldLanes.map { "`\(mdCode($0.name))`×\($0.jobsHeldUnreleased)" }.joined(separator: ", ")
                    + " (of \(brJobs) job file(s) read).",
                action: "A held job's work is finished but its commit was never authorized, so the tree keeps "
                    + "the change and the ledger keeps the hold. Release each with the hold-release tool or "
                    + "settle it explicitly — an unreleased hold is indistinguishable from a stalled worker.")
    }
    if brPreserved > 0 {
        let lanes = brPreservedLanes.filter { $0.preserved.didRead && $0.preservedCount > 0 }
        addLead(rank: 7, "\(brPreserved) completed bridge repl\(brPreserved == 1 ? "y" : "ies") sit preserved as undeliverable"
                    + (brPreservedOldest.map { " (oldest \(ageDaysText($0)))" } ?? ""),
                evidence: "Reply-job files under `reply-jobs/undelivered/`: "
                    + lanes.map { "`\(mdCode($0.name))`×\($0.preservedCount)"
                        + ($0.preservedOldest.map { o in " (oldest \(stamp(o)))" } ?? "") }.joined(separator: ", ")
                    + ". The bridge moves a completed reply there when its delivery settles 409 / outcome_unknown "
                    + "— the app could not confirm receipt either way — and keeps the FULL reply text. Nothing "
                    + "rescans or replays that directory by design: a days-old completion claim injected into "
                    + "her session would read as current.",
                action: "This is finished work she never acknowledged. Read each file (the text is under "
                    + "`completedExecution.turnResult.message`), decide whether it was already acted on, hand it "
                    + "over as a NEW message if it still matters, then remove the file. The app's inbox carries a "
                    + "rolling \"Codex: N undelivered replies preserved\" card over the same directory.")
    }
    if brStaleHB > 0 {
        addLead(rank: 9, "\(brStaleHB) unsettled wake job(s) stopped heartbeating over an hour ago",
                evidence: "Job files whose `state` is not `settled` and whose `heartbeatAt` is more than 1h old: "
                    + bridgeLanes.filter { $0.jobsStaleHeartbeat > 0 }
                        .map { "`\(mdCode($0.name))`×\($0.jobsStaleHeartbeat)" }.joined(separator: ", ") + ".",
                action: "That is a worker that died without settling. Reap it or mark it failed, so the lane's "
                    + "capacity is not held by a process that no longer exists.")
    }
}
if sysLoopStatus == .measured || sysLoopStatus == .partial {
    for (name, count) in sysLoopStreaks.prefix(3) {
        addLead(rank: 8, "Background loop `\(mdCode(name))` failed \(count)× in the \(days)-day window",
                evidence: "`logs/background_loop_failures.jsonl`: \(count) failure row(s) for `loopId=\"\(mdCode(name))\"` "
                    + "since \(stamp(windowStart))"
                    + (loopFailureNewest[name].map { ", newest \(stamp($0))" } ?? "")
                    + (loopLastRun[name].map { ", last recorded tick \(stamp($0))" } ?? ", no recorded tick")
                    + ". The feed is line-capped, so this is a lower bound.",
                action: "Read the failure signatures in [(h) SYS-02 detail](#sec-h) and fix the loop's error "
                    + "path. A loop that keeps failing is doing none of the work the rest of the system "
                    + "assumes it did.")
    }
}
if (sysGithubStatus == .measured || sysGithubStatus == .partial), githubTrackingObj != nil {
    if let h = sysWatcherAgeHours, h > githubWatcherStaleHours {
        addLead(rank: 12, "GitHub watcher snapshot has not refreshed in \(fmt(h, 1))h",
                evidence: "`connectors/github/tracking_snapshot.json`: newest timestamp field "
                    + (githubTrackingNewest.map { stamp($0) } ?? "unknown")
                    + ", \(fmt(h, 1))h old against a \(fmt(githubWatcherStaleHours, 0))h staleness bound; "
                    + "\(githubItems) tracked item(s), \(githubItemsOpen) open.",
                action: "The watcher loop is the only thing that turns GitHub state into Desk work. While it "
                    + "is cold, every open item's status in this report is the last thing the watcher saw, "
                    + "not the truth on GitHub.")
    } else if sysWatcherAgeHours == nil {
        addLead(rank: 12, "GitHub watcher snapshot carries no timestamp — its cycle age is unknowable",
                evidence: "`connectors/github/tracking_snapshot.json` has \(githubTrackingKeys) top-level key(s) "
                    + "and none of `updatedAt`/`generatedAt`/`capturedAt`/`refreshedAt`/`at`.",
                action: "Stamp the snapshot when the watcher writes it. Without a timestamp nobody — including "
                    + "this instrument — can tell a live watcher from one that stopped weeks ago.")
    }
}
// ── wave-2 leads (SYS-09..14) ──
// Same rule: raised ONLY from an organ that actually READ.
if sysProviderStatus == .measured || sysProviderStatus == .partial {
    if !unservedProviderPins.isEmpty {
        addLead(rank: 5, "\(unservedProviderPins.count) provider picker pin(s) target an unknown routing surface",
                evidence: "Persisted picker keys not in the instrument's canonical routing vocabulary: "
                    + unservedProviderPins.prefix(5).map { "`\(mdCode($0))`" }.joined(separator: ", ") + ".",
                action: "Remove or migrate those orphan keys through Provider Routing. They are not defaults and no turn can consume them.")
    }
    if !unresolvedProviderPins.isEmpty {
        addLead(rank: 5, "\(unresolvedProviderPins.count) surface pin(s) name a provider with no config on disk",
                evidence: "`providers/active.json` pins "
                    + unresolvedProviderPins.prefix(5)
                        .map { "`\(mdCode($0.surface))`→`\(mdCode($0.provider))`" }.joined(separator: ", ")
                    + "; no matching `providers/<id>.json` parsed in the \(providerFilesTotal) config "
                    + "file(s) read. See [(h) SYS-09 detail](#sec-h).",
                action: "That surface cannot make a call until the credential file exists — every turn on it "
                    + "either falls back silently or fails. Add the config, or repoint the pin at a "
                    + "provider that is actually configured.")
    }
    if !pinDrifts.isEmpty {
        let d = pinDrifts[0]
        addLead(rank: 11, "\(pinDrifts.count) surface(s) never used their pinned model in the \(days)d window",
                evidence: "Worst: `\(mdCode(d.surface))` is pinned to `\(mdCode(d.pinned))` in "
                    + "`providers/surfaces.json` but all \(d.calls) `llm.call` row(s) after the current pin epoch ran "
                    + "`\(mdCode(d.observed))`. Full table in [(h) SYS-09 detail](#sec-h).",
                action: "Either the pin is stale and should be updated to what the router really picks, or "
                    + "something upstream is overriding it. A pin nobody honours is a config file that "
                    + "lies to the next person who reads it.")
    }
    if llmNonOKInWindow > 0 {
        addLead(rank: 10, "\(llmNonOKInWindow) `llm.call` row(s) came back non-`ok` in the \(days)d window",
                evidence: "`traces/events.jsonl`: statuses \(mdComposed(topCounts(llmNonOKByStatus, 4)))"
                    + (llmNonOKSignatures.isEmpty ? "" : "; signatures " + llmNonOKSignatures
                        .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                        .prefix(3).map { "`\(mdCode($0.key))`×\($0.value)" }.joined(separator: ", ")) + ".",
                action: "Cluster them by provider before changing anything: an auth rejection is a "
                    + "credential problem, a transport error is a network one, and they are fixed in "
                    + "opposite places.")
    }
}
if sysToolStatus == .measured || sysToolStatus == .partial {
    if !registryWithoutActiveArtifact.isEmpty || !activeArtifactWithoutRegistry.isEmpty {
        addLead(rank: 6, "Tool registry and active artifact directory diverge",
                evidence: "Registry-only IDs: "
                    + (registryWithoutActiveArtifact.isEmpty ? "none" : registryWithoutActiveArtifact.prefix(3).map { "`\(mdCode($0))`" }.joined(separator: ", "))
                    + "; active-only IDs: "
                    + (activeArtifactWithoutRegistry.isEmpty ? "none" : activeArtifactWithoutRegistry.prefix(3).map { "`\(mdCode($0))`" }.joined(separator: ", ")) + ".",
                action: "Do not promote or remove anything by hand. Reconcile through the ToolExecution owner so signed registry state and artifact directories commit together.")
    }
    for r in sysToolBroken.prefix(3) {
        addLead(rank: 8, "Tool `\(mdCode(r.name))` failed \(r.stat.failed)× against \(r.stat.ok) success(es) in \(runtimeEvidenceLabel)",
                evidence: "`traces/events.jsonl` `tool.dispatch` rows for `\(mdCode(r.name))`: "
                    + "\(r.stat.total) dispatch(es), \(r.stat.failed) failed"
                    + (r.stat.errorClasses.isEmpty ? "" : " (\(mdComposed(topCounts(r.stat.errorClasses, 2))))")
                    + (r.stat.errorDetails.isEmpty ? "" : ", top reason(s) \(topDetails(r.stat.errorDetails, 2, inTable: false))")
                    + (r.stat.surfaces.isEmpty ? "" : ", surfaces \(mdComposed(topCounts(r.stat.surfaces, 2)))")
                    + ". See [(h) SYS-10 detail](#sec-h).",
                action: "A tool that mostly fails is worse than a missing one: the model keeps choosing it and "
                    + "keeps getting nothing. Fix the tool or take it out of the manifest until it works.")
    }
}
if sysSyncStatus == .measured || sysSyncStatus == .partial {
    if !digestsWithoutSnapshot.isEmpty {
        addLead(rank: 12, "\(digestsWithoutSnapshot.count) companion snapshot digest(s) name a file that is not cached",
                evidence: "`icloud/snapshot_digests.json` lists "
                    + digestsWithoutSnapshot.prefix(5).map { "`\(mdCode($0))`" }.joined(separator: ", ")
                    + ", none of which exist in `mobile_snapshot_cache/snapshots/` "
                    + "(\(snapshotFiles.count) file(s) cached). See [(h) SYS-11 detail](#sec-h).",
                action: "The digest map is what the phone diffs against to decide it is up to date. A digest "
                    + "with no file means the companion either re-fetches forever or believes it already "
                    + "has data it has never seen.")
    }
    if syncTransactionsUnanswered > 0 {
        addLead(rank: 16, "\(syncTransactionsUnanswered) companion sync transaction(s) have no response recorded",
                evidence: "`mobile_snapshot_cache/transactions/`: \(syncTransactionsUnanswered) of "
                    + "\(syncTransactionsTotal) transaction file(s) carry no `response` object"
                    + (syncTransactionsRetried > 0 ? ", \(syncTransactionsRetried) with `attempts` > 1" : "")
                    + (syncTransactionNewest.map { "; newest transaction \(stamp($0))" } ?? "") + ".",
                action: "Each is an action the phone asked for and never heard back about. Check the Mac-side "
                    + "handler still drains this directory — an unanswered transaction is indistinguishable "
                    + "on the phone from one that is still in flight.")
    }
    if let r = publicSyncResult, r != "succeeded" {
        addLead(rank: 13, "The last public sync did not succeed — result `\(mdCode(r))`",
                evidence: "`public_sync/last_status.json`: result `\(mdCode(r))`"
                    + (publicSyncStage.map { ", stage `\(mdCode($0))`" } ?? "")
                    + (publicSyncExitCode.map { ", exit \($0)" } ?? "")
                    + (publicSyncRecordedAt.map { ", recorded \(stamp($0))" } ?? "") + ".",
                action: "The public export is the open-source mirror. A failed run means the mirror is behind "
                    + "whatever the status file last recorded — re-run it and read the stage it stopped at.")
    }
}
if sysChatStatus == .measured || sysChatStatus == .partial {
    if chatMessageFilesMissing > 0 {
        addLead(rank: 9, "\(chatMessageFilesMissing) in-window chat session(s) have an index row but no message file",
                evidence: "`chat/sessions.json` lists \(chatSessionsInWindow) session(s) updated inside the "
                    + "\(days)d window; \(chatMessageFilesOpened) of the \(chatMessageFilesOpened + chatMessageFilesMissing) "
                    + "opened had a `chat/messages/<id>.jsonl`.",
                action: "An index row with no transcript is a session the UI will open empty. Find out whether "
                    + "the transcript was compacted into `chat/sessions/<id>/messages.compact.*.jsonl`, "
                    + "archived, or lost — the three have very different fixes.")
    }
}
if sysSecurityStatus == .measured || sysSecurityStatus == .partial {
    if securityPolicyPostureKnown, !securityPolicyWeakened.isEmpty {
        addLead(rank: 4, "Security policy disabled protective controls: \(securityPolicyWeakened.joined(separator: ", "))",
                evidence: "`trust/policy.json`: \(securityPolicyProtectedEnabledCount) of \(securityPolicyProtectedKeys.count) "
                    + "SecurityCenter protection(s) remain enabled; disabled: "
                    + securityPolicyWeakened.map { "`\(mdCode($0))`" }.joined(separator: ", ") + ".",
                action: "Restore each protection in `trust/policy.json`, or record a narrowly scoped, "
                    + "time-bounded exception before accepting the weaker authorization boundary.")
    }
    if approvalPending > 0 {
        addLead(rank: 6, "\(approvalPending) approval request(s) were never answered",
                evidence: "`workflows/approvals/requests.json`: \(approvalPending) of \(approvalsTotal) "
                    + "request(s) carry a null `decision`"
                    + (approvalOldestPending.map { ", oldest raised \(stamp($0)) (\(fmt(daysSince($0), 0))d ago)" } ?? "")
                    + ". Decisions overall: \(mdComposed(topCounts(approvalDecisions, 4))).",
                action: "Every one of these is work the agent stopped and waited on. Answer or cancel them — "
                    + "an approval nobody ever decides is a silent way to lose a task, and the agent has no "
                    + "way to tell it apart from one still under consideration.")
    }
    if canaryTripsInWindow > 0 {
        addLead(rank: 4, "\(canaryTripsInWindow) security canary trip(s) fired in the \(days)d window",
                evidence: "`security/canary_trips.jsonl`: \(mdComposed(topCounts(canaryKinds, 4)))"
                    + (canaryNewest.map { ", newest \(stamp($0))" } ?? "")
                    + " (\(canaryTripsTotal) trip(s) recorded in total).",
                action: "A canary trip is the guard catching something the policy layer let through far "
                    + "enough to matter. Read each one before deciding it was a false positive — that is "
                    + "the whole reason it is a separate feed from the audit ledger.")
    }
    if macControlBlocked > 0 {
        addLead(rank: 17, "\(macControlBlocked) mac-control call(s) were blocked in the \(days)d window",
                evidence: "`mac_control_audit.jsonl` + `mac_control_bridge_audit.jsonl`: "
                    + "\(macControlBlocked) blocked of \(macControlInWindow) call(s) in window"
                    + (macControlNonZeroExit > 0 ? ", plus \(macControlNonZeroExit) non-zero exit(s)" : "")
                    + (macControlCategories.isEmpty ? "" : "; categories \(mdComposed(topCounts(macControlCategories, 3)))") + ".",
                action: "A blocked mac-control call is the OS or the policy layer refusing an action the agent "
                    + "believed it could take. Check which — a TCC grant that was never given looks exactly "
                    + "like a policy denial from inside the app.")
    }
}
if sysWorkshopStatus == .measured || sysWorkshopStatus == .partial {
    if let h = workshopPumpTickAgeHours, h > workshopPumpReviewHours {
        addLead(rank: 14, "Workshop pump last recorded tick \(fmt(h, 1))h ago; current activity unknown",
                evidence: "`logs/background_loop_state.json`: `workshop_pump` "
                    + (workshopPumpTick.map { stamp($0) } ?? "unknown")
                    + ", beyond the \(fmt(workshopPumpReviewHours, 0))h review threshold (two daily integrity intervals).",
                action: "Inspect canonical loop status and failure evidence. The pump is event/deadline-driven; its consumed-window lease is historical spend evidence, not a heartbeat. This timestamp alone proves neither stopped execution nor continuous uptime.")
    }
}

// ── (i) Reach walk ───────────────────────────────────────────────────────────
line("<a id=\"sec-i\"></a>")
line()
line("## (i) REACH WALK — every feed in the data root, covered and NOT COVERED")
line()
line("- files walked: **\(walkFilesSeen)** (\(humanBytes(walkBytesSeen)))"
     + (walkSkippedSymlinks > 0 ? ", \(walkSkippedSymlinks) symlink(s) skipped (never followed)" : ""))
line("- entries visited: \(walkEntriesVisited) · **per-entry errors: \(walkEntryErrors)**"
     + (walkUnattributedEntries > 0 ? " · \(walkUnattributedEntries) entry(ies) outside every spelling of the root" : "")
     + " · enumerator: \(walkEnumeratorFailed ? "**FAILED TO START**" : "started")")
if walkEntryErrors > 0 {
    line("- ⚠︎ **\(walkEntryErrors) entry(ies) could not be read during the walk** — the coverage counts below")
    line("  are therefore a LOWER BOUND, not an inventory. First error: `\(mdCode(walkFirstEntryError ?? "unknown"))`")
    addLead(rank: 4, "Reach walk hit \(walkEntryErrors) per-entry error(s) — coverage is a lower bound",
            evidence: "Directory walk over `\(mdCode(resolvedDataRoot))`: \(walkEntriesVisited) entries visited, "
                + "\(walkEntryErrors) unreadable. First: \(mdCode(walkFirstEntryError ?? "unknown")).",
            action: "Every skipped entry could be an uncovered feed the report is not naming. Fix the permissions "
                + "or the broken paths and re-run before treating the NOT COVERED list as complete.")
}
line("- feeds after family aggregation: **\(feeds.count)** — instance-named siblings "
     + "(`2026-08-20.jsonl`, UUIDs, timestamped backups) collapse into one `*` feed")
line("- **covered by a reader: \(coveredFeeds.count)** · **NOT COVERED: \(uncoveredFeeds.count)** "
     + "(\(humanBytes(uncoveredBytes)))")
line("- burndown: \(uncoveredBurndown). The baseline is an in-code constant "
     + "(`uncoveredBaseline`) moved deliberately by each coverage wave, never to flatter a delta. "
     + "A RISE is normal — a new subsystem announces itself here the day it starts writing.")
line()
line("### NOT COVERED (\(uncoveredFeeds.count)) — named blind spots")
line()
if !disabledShadowFeeds.isEmpty {
    line("`disabled/` contributes \(disabledShadowFeeds.count) shadow feed family(ies), intentionally excluded here; "
         + "see [(i.2) WAVE-3 FEEDS](#sec-i2). A disabled snapshot must never sort beside live lanes.")
    line()
}
if reachWalkFailed {
    // A walk that returns nothing must never render as "everything is covered".
    // This also drives a NONZERO EXIT at the bottom of the file: a report whose
    // reach answer is vacuous is an invalid report, and an invalid report that
    // exits 0 is indistinguishable to a caller from a clean bill of health.
    line("**REPORT INVALID — REACH WALK FAILED.** "
         + (walkEnumeratorFailed
            ? "The directory enumerator could not be created for"
            : "0 files were enumerated under")
         + " `\(mdCode(resolvedDataRoot))`.")
    line("This is a WALK FAILURE, not a clean bill of health: coverage below is meaningless and the")
    line("`\(coveredFeeds.count)` / `\(uncoveredFeeds.count)` counts are both vacuous. This run exits NONZERO.")
    line()
    addLead(rank: 1, "REPORT INVALID — reach walk failed, the coverage answer is vacuous",
            evidence: "`\(mdCode(resolvedDataRoot))`: enumerator "
                + (walkEnumeratorFailed ? "could not be created" : "started but yielded no regular file")
                + "; \(walkEntriesVisited) entries visited, \(walkEntryErrors) per-entry error(s) "
                + "(prefixes tried: \(mdCode(walkPrefixes.joined(separator: ", ")))).",
            action: "Do not read any covered/not-covered number from this run. Check the data root path, "
                + "its permissions, and whether it resolves through a symlink the walker did not expect.")
} else if uncoveredFeeds.isEmpty {
    line("Every feed in the data root has a reader — over \(walkFilesSeen) file(s) actually walked.")
    line()
} else {
    line("#### Rollup by top-level directory (exhaustive — all \(uncoveredFeeds.count) feeds counted)")
    line()
    line("| directory | uncovered feeds | active | files | size | newest mtime |")
    line("|---|---|---|---|---|---|")
    for r in uncoveredRollups {
        line("| `\(mdCode(r.dir))` | \(r.feeds) | \(r.activeFeeds > 0 ? "**\(r.activeFeeds)**" : "0") | \(r.files) | "
             + "\(humanBytes(r.bytes)) | \(r.newest.map { stamp($0) } ?? "—") |")
    }
    line()
    line("#### Feed detail — active first, then newest")
    line()
    line("A subsystem that starts writing today appears at the top of this table on the very next run")
    line("without anyone editing the instrument. `ACTIVE` = written inside the \(days)-day window.")
    line()
    // Active first, then largest (active) / newest (inactive), TIES ON KEY.
    let detail = uncoveredFeeds.sorted { l, r in
        let a = (l.newest ?? .distantPast) >= windowStart ? 1 : 0
        let b = (r.newest ?? .distantPast) >= windowStart ? 1 : 0
        if a != b { return a > b }
        if a == 1 { return l.bytes == r.bytes ? l.key < r.key : l.bytes > r.bytes }
        let x = l.newest ?? .distantPast, y = r.newest ?? .distantPast
        return x == y ? l.key < r.key : x > y
    }
    line("| feed | files | size | rows (est) | newest mtime | |")
    line("|---|---|---|---|---|---|")
    for f in detail.prefix(uncoveredDetailLimit) {
        let active = (f.newest ?? .distantPast) >= windowStart
        line("| `\(mdCode(f.key))` | \(f.files) | \(humanBytes(f.bytes)) | \(mdComposed(f.rowEstimate)) | "
             + "\(f.newest.map { stamp($0) } ?? "—") | \(active ? "**ACTIVE**" : "") |")
    }
    line()
    if detail.count > uncoveredDetailLimit {
        line("**\(uncoveredDetailLimit) of \(detail.count) uncovered feeds shown** — the remaining "
             + "\(detail.count - uncoveredDetailLimit) are all accounted for in the rollup table above, which is")
        line("exhaustive. Nothing is dropped silently: raise `uncoveredDetailLimit` in the source to see them all.")
        line()
    }
    if !uncoveredActive.isEmpty {
        let top = uncoveredRollups.filter { $0.activeFeeds > 0 }.prefix(5)
            .map { "`\(mdCode($0.dir))` \($0.activeFeeds) active feed(s), \(humanBytes($0.bytes))" }.joined(separator: "; ")
        addLead(rank: 15, "\(uncoveredActive.count) actively-written feed(s) have no reader in this instrument",
                evidence: "Reach walk over \(resolvedDataRoot): \(uncoveredActive.count) of \(uncoveredFeeds.count) "
                    + "uncovered feeds were written inside the \(days)d window. Largest/newest: \(top).",
                action: "Each is a lane that can regress invisibly. Add a reader, or state in the plan why the feed "
                    + "does not need one — an uncovered ACTIVE feed is the only kind of blind spot that grows.")
    }
}
if !uncoveredSQLiteCopies.isEmpty {
    line("Uncovered sqlite files were counted on a COPY, same rule as the readers:")
    line()
    for c in uncoveredSQLiteCopies.sorted() { line("- `\(c)`") }
    line()
}
line("### Covered (\(coveredFeeds.count))")
line()
line("| feed | reader | files | size | newest mtime |")
line("|---|---|---|---|---|")
for f in coveredFeeds {
    line("| `\(mdCode(f.key))` | \(mdCode(f.coveredBy.first ?? "?")) | \(f.files) | \(humanBytes(f.bytes)) | "
         + "\(f.newest.map { stamp($0) } ?? "—") |")
}
line()
let registeredButUnwalked = sources.entries.filter { !$0.present && relativeInDataRoot($0.path) != nil }
if !registeredButUnwalked.isEmpty {
    line("Readers registered against a path that does not exist in this data root "
         + "(they render `source absent`, never a zero):")
    line()
    for e in registeredButUnwalked { line("- `\(e.label)` → `\((e.path as NSString).abbreviatingWithTildeInPath)`") }
    line()
}

// ── (i.1) Turn-trace kind vocabulary + lifecycle pairing ────────────────────
line("<a id=\"sec-i1\"></a>")
line()
line("## (i.1) TURN-TRACE VOCABULARY — every kind the code can emit, and whether it fires")
line()
if skipFeedSection(turnTracesPresent, "the turn-trace kind vocabulary", "turn_traces/", turnTraceDir) {
    // absent/unreadable already rendered; nothing below is derived.
} else {
    line("`turn_traces/<day>.jsonl` was graded above by its context lanes and its turn speed. This section")
    line("grades the feed's own VOCABULARY. **A kind with no rows is printed as a row, not omitted** — that is")
    line("the whole point: a producer that goes silent must be NAMED, and \"absent from the table\" and")
    line("\"never fired\" are the same picture to a reader.")
    line()

    // ── per-DAY readability, kept apart from per-day emptiness ──
    line("### Per-day readability — `opened` is a separate column from `rows`")
    line()
    line("The live reader (`TurnTraceReplayReader.read`, TurnInspectorModel.swift:429-432) returns `([], 0)`")
    line("when a day file cannot be read, so an unreadable day is byte-identical to a day with no turns.")
    line("This table refuses that collapse.")
    line()
    line("| day file | opened | rows | malformed | size |")
    line("|---|---|---|---|---|")
    for d in traceDays.sorted(by: { $0.name < $1.name }) {
        line("| `\(mdCode(d.name))` | \(d.opened ? "yes" : "**NO**") | "
             + "\(d.opened ? "\(d.rows)" : "unknown — not read") | \(d.opened ? "\(d.malformed)" : "—") | "
             + "\(humanBytes(d.bytes)) |")
    }
    line()
    if !traceDayOpenFailures.isEmpty {
        line("**\(traceDayOpenFailures.count) day file(s) present and unreadable** — every number in this")
        line("section is a LOWER BOUND, not an inventory.")
        line()
        addLead(rank: 3, "\(traceDayOpenFailures.count) turn-trace day file(s) are present and could not be opened",
                evidence: "`turn_traces/`: \(mdCode(traceDayOpenFailures.sorted().prefix(4).joined(separator: ", "))) "
                    + "present on disk, `LineStream` could not open them. The live reader returns `([], 0)` in the "
                    + "same situation (TurnInspectorModel.swift:429-432), so the Inspector and the phone would both "
                    + "render those days as \"no turns\".",
                action: "Fix the permissions or the truncation, then re-run. Until then treat every turn-trace "
                    + "count as a floor — including the vocabulary table below.")
    }

    // ── the vocabulary table ──
    let seenKinds = Set(traceKindLookback.keys)
    let declared = Set(declaredTraceKinds.keys)
    let undeclared = seenKinds.subtracting(declared).sorted()
    let inert = declared.subtracting(seenKinds).sorted()
    let allRows = declared.union(seenKinds).sorted()
    line("### Kind reachability (\(allRows.count) kinds: \(declared.count) declared, "
         + "\(undeclared.count) undeclared, \(inert.count) declared-but-INERT)")
    line()
    line("| kind | rows (\(days)d window) | rows (\(lookbackDays)d lookback) | newest | state | emitter |")
    line("|---|---|---|---|---|---|")
    for k in allRows {
        let inLookback = traceKindLookback[k] ?? 0
        let inWindowRows = traceKindWindow[k] ?? 0
        let isDeclared = declared.contains(k)
        let state: String
        if !isDeclared { state = "**UNDECLARED — vocabulary drift**" }
        else if inLookback == 0 { state = "**INERT — no row in \(lookbackDays)d**" }
        else if inWindowRows == 0 { state = "**ZERO IN WINDOW** (last seen in lookback)" }
        else { state = "live" }
        line("| `\(mdCode(k))` | \(inWindowRows) | \(inLookback) | "
             + "\(traceKindNewest[k].map { stamp($0) } ?? "—") | \(state) | "
             + "\(declaredTraceKinds[k] ?? "(no declared emitter)") |")
    }
    line()
    line("- cheap-scan cross-check: **\(traceScanDisagreements) disagreement(s)** over \(traceScanCrossChecked) "
         + "row(s) parsed both ways · \(traceKindUnscannable) row(s) whose `kind` the byte scan could not read "
         + "· \(traceWave3Unparsed) row(s) matched a kind and would not parse")
    line()
    if traceScanDisagreements > 0 {
        addLead(rank: 2, "The turn-trace kind census disagrees with the JSON parser on \(traceScanDisagreements) row(s)",
                evidence: "\(traceScanDisagreements) of \(traceScanCrossChecked) cross-checked rows: the byte scanner "
                    + "and `JSONSerialization` read a DIFFERENT `kind`. The whole vocabulary table above is derived "
                    + "from the scanner.",
                action: "Do not read the vocabulary table from this run. The scanner takes the FIRST `\"kind\"` in "
                    + "the line — a producer that now writes a nested `kind` ahead of the top-level one would "
                    + "produce exactly this.")
    }
    if !undeclared.isEmpty {
        addLead(rank: 6, "\(undeclared.count) turn-trace kind(s) are emitted and DECLARED NOWHERE",
                evidence: "Kinds present in `turn_traces/` with no entry in `declaredTraceKinds`: "
                    + undeclared.prefix(6).map { "`\(mdCode($0))` (\(traceKindLookback[$0] ?? 0) rows)" }
                        .joined(separator: ", ") + ".",
                action: "An emitter landed and nobody decided what reads it. Either add it to the declared "
                    + "vocabulary with its emitter, or stop emitting it. Note the iOS projection allowlist "
                    + "(`TurnSummaryRecord.allowedKinds`) buckets anything it does not name into `other`, so an "
                    + "undeclared kind is invisible from the phone.")
    }
    if !inert.isEmpty {
        addLead(rank: 8, "\(inert.count) declared turn-trace kind(s) are INERT — zero rows in \(lookbackDays) days",
                evidence: "Declared with an emitter and never fired in the lookback: "
                    + inert.prefix(8).map { "`\(mdCode($0))`" }.joined(separator: ", ")
                    + ". A source read cannot tell an unreachable emit from a quiet lane.",
                action: "For each: force the event (a driven probe) and see whether a row appears. A latch that "
                    + "never fires and a latch that fires but cannot write look identical from here.")
    }

    // ── lifecycle pairing ──
    let windowTurns = lifecycles.filter { $0.value.terminal != nil || $0.value.accepted != nil }
    let terminalTurns = lifecycles.filter { $0.value.terminal != nil }
    // Only an accepted turn belongs to a user-visible lifecycle envelope.
    // Background/ephemeral terminal rows do not own a surface handoff, so
    // comparing all terminals to outputEnqueued manufactured hundreds of
    // false delivery gaps on the live feed.
    let okTurns = terminalTurns.filter {
        $0.value.accepted != nil
            && (($0.value.terminalStatus ?? "") == "completed"
                || ($0.value.terminalStatus ?? "") == "ok")
    }
    let missingReady = terminalTurns.filter { $0.value.readyRows == 0 }
    let negativeReady = lifecycles.filter {
        guard let a = $0.value.accepted, let r = $0.value.readyFirst else { return false }
        return r < a
    }
    let readyAfterRequest = lifecycles.filter {
        guard let r = $0.value.readyFirst, let s = $0.value.requestStarted else { return false }
        return s < r
    }
    let bothReadyAndRequest = lifecycles.filter { $0.value.readyFirst != nil && $0.value.requestStarted != nil }
    let missingEnqueued = okTurns.filter { $0.value.outputEnqueued == 0 }
    let firstDeltaTurns = lifecycles.filter { $0.value.firstDelta != nil }.count
    let ttftTurns = lifecycles.filter { $0.value.llmWithTtft > 0 }.count
    let lateCompletionRows = lifecycles.values.reduce(0) { $0 + $1.lateCompletion }

    line("### Lifecycle milestone pairing (\(windowTurns.count) turn(s) in the \(days)d window)")
    line()
    line("Each row is an ENVELOPE the milestones must satisfy, not a value. Any \"turns checked: 0\" is printed")
    line("as such — a check with nothing to check is not a pass.")
    line()
    line("| property | turns checked | violations | verdict |")
    line("|---|---|---|---|")
    func pairRow(_ name: String, checked: Int, violations: Int) {
        let verdict = checked == 0 ? "**nothing to check in window**"
            : (violations == 0 ? "ok" : "**\(violations) violation(s)**")
        // `name` is a literal written in this file, not store-derived text —
        // escaping it would print the backticks it is meant to render.
        line("| \(name) | \(checked) | \(violations) | \(verdict) |")
    }
    pairRow("every terminal turn carries ≥1 `context.ready`",
            checked: terminalTurns.count, violations: missingReady.count)
    pairRow("`turn.accepted` → `context.ready` elapsed is non-negative",
            checked: lifecycles.filter { $0.value.accepted != nil && $0.value.readyFirst != nil }.count,
            violations: negativeReady.count)
    pairRow("`context.ready` precedes `provider.requestStarted`",
            checked: bothReadyAndRequest.count, violations: readyAfterRequest.count)
    pairRow("every accepted ok-terminal turn carries ≥1 `surface.outputEnqueued`",
            checked: okTurns.count, violations: missingEnqueued.count)
    line()
    let readySpreads = lifecycles.values.compactMap { r -> Double? in
        guard let a = r.accepted, let ready = r.readyFirst else { return nil }
        return ready.timeIntervalSince(a) * 1000
    }.sorted()
    if readySpreads.isEmpty {
        line("- `turn.accepted` → `context.ready`: **no turn in window carries both milestones** — not a zero.")
    } else {
        line("- `turn.accepted` → `context.ready`: p50 \(fmt(percentile(readySpreads, 0.5), 0)) ms · "
             + "p95 \(fmt(percentile(readySpreads, 0.95), 0)) ms over \(readySpreads.count) turn(s)")
    }
    line("- `provider.firstDelta` turns: **\(firstDeltaTurns)** vs `llm.call` rows carrying `ttftMs`: "
         + "**\(ttftTurns)** turn(s) — two independent first-token clocks, compared here for the first time")
    line("- `context.attention.late-completion`: **\(lateCompletionRows)** row(s) in window "
         + "(the 250 ms attention-abandon latch's only receipt)")
    line()
    if !missingReady.isEmpty {
        addLead(rank: 5, "\(missingReady.count) terminal turn(s) carry no `context.ready`",
                evidence: "\(missingReady.count) of \(terminalTurns.count) terminal turns have no `context.ready` "
                    + "in the \(days)d window. Multiple rows are valid when a provider/tool loop rebuilds context; "
                    + "the earliest row remains the assembly boundary used for ordering.",
                action: "`context.ready` is the assembly→provider boundary stamp. Without it the assembly gap is "
                    + "unmeasurable and lands in the unattributed bucket of the turn-speed section.")
    }
    if readyAfterRequest.count > 0 {
        addLead(rank: 4, "`provider.requestStarted` precedes `context.ready` on \(readyAfterRequest.count) turn(s)",
                evidence: "\(readyAfterRequest.count) of \(bothReadyAndRequest.count) turns carrying both "
                    + "milestones have the provider stamp BEFORE the assembly stamp.",
                action: "Either work moved across the assembly→provider boundary or one of the two observers is "
                    + "stamping from the wrong clock. Both make every assembly number above wrong.")
    }
    if missingEnqueued.count > 0 {
        addLead(rank: 5, "\(missingEnqueued.count) accepted ok-terminal turn(s) have no `surface.outputEnqueued`",
                evidence: "\(missingEnqueued.count) of \(okTurns.count) turns that reached a successful terminal "
                    + "carry no enqueue milestone — the last stamp before the UI.",
                action: "Either the surface stopped stamping the handoff, or those turns produced no output while "
                    + "reporting success. The second is worse than the first.")
    }
    if firstDeltaTurns > 0 || ttftTurns > 0 {
        let hi = max(firstDeltaTurns, ttftTurns), lo = min(firstDeltaTurns, ttftTurns)
        if lo == 0 || Double(hi) / Double(max(lo, 1)) > 2.0 {
            addLead(rank: 7, "The two first-token clocks disagree: \(firstDeltaTurns) `provider.firstDelta` turns vs \(ttftTurns) `ttftMs` turns",
                    evidence: "Same window, same feed: \(firstDeltaTurns) turn(s) carry a `provider.firstDelta` "
                        + "milestone and \(ttftTurns) carry an `llm.call` row with `ttftMs`.",
                    action: "This names a broken OBSERVER, not a slow model. The instrument's first-token numbers "
                        + "are derived from `ttftMs`; if `firstDelta` stopped firing nothing else would notice.")
        }
    }

    // ── stream.tick budget ──
    let tickTurns = lifecycles.filter { $0.value.ticks > 0 }
    let tickCounts = tickTurns.values.map { Double($0.ticks) }.sorted()
    let allGaps = tickTurns.values.flatMap { $0.tickGaps }.sorted()
    let interRoundGaps = tickTurns.values.flatMap { $0.interRoundGaps }.sorted()
    let tickRows = traceKindWindow["stream.tick"] ?? 0
    let windowRowsAllKinds = traceKindWindow.values.reduce(0, +)
    line("### `stream.tick` — the feed's own budget share")
    line()
    if tickTurns.isEmpty {
        line("**No `stream.tick` row in the \(days)d window.** Not a zero cadence — no cadence to measure.")
    } else {
        let sharePct = windowRowsAllKinds > 0 ? Double(tickRows) / Double(windowRowsAllKinds) * 100 : 0
        line("- rows in window: **\(tickRows)** = \(fmt(sharePct, 1))% of all \(windowRowsAllKinds) trace rows")
        line("- ticks per turn: p50 \(fmt(percentile(tickCounts, 0.5), 0)) · p95 "
             + "\(fmt(percentile(tickCounts, 0.95), 0)) · max \(Int(tickCounts.last ?? 0)) "
             + "over \(tickTurns.count) turn(s)")
        if allGaps.isEmpty {
            line("- intra-round inter-tick gap: **no round has two ticks** — cadence not measurable, not zero")
        } else {
            line("- intra-round inter-tick gap: p50 \(fmt(percentile(allGaps, 0.5), 0)) ms · p95 "
                 + "\(fmt(percentile(allGaps, 0.95), 0)) ms · max \(fmt(allGaps.last ?? 0, 0)) ms")
        }
        if !interRoundGaps.isEmpty {
            line("- inter-round gap (tool dispatch + next-round TTFT, NOT streaming cadence): "
                 + "\(interRoundGaps.count) boundary interval(s) · p50 \(fmt(percentile(interRoundGaps, 0.5), 0)) ms · p95 "
                 + "\(fmt(percentile(interRoundGaps, 0.95), 0)) ms · max \(fmt(interRoundGaps.last ?? 0, 0)) ms")
        }
        line("- named bounds: **\(streamTickPerTurnCeiling) ticks/turn** and **"
             + "\(Int(streamTickGapCeilingMs)) ms** p95 intra-round inter-tick gap "
             + "(the ticker is chunk-gated — a zero-chunk freeze emits no tick and is invisible here)")
        if (tickCounts.last ?? 0) > Double(streamTickPerTurnCeiling) {
            addLead(rank: 9, "A turn emitted \(Int(tickCounts.last ?? 0)) `stream.tick` rows — over the \(streamTickPerTurnCeiling) ceiling",
                    evidence: "`stream.tick` is \(fmt(sharePct, 1))% of the trace feed in this window "
                        + "(\(tickRows) of \(windowRowsAllKinds) rows). Max per turn: \(Int(tickCounts.last ?? 0)).",
                    action: "This feed shares a retention budget with the small load-bearing kinds. A tick storm "
                        + "evicts them first, which is a silent loss of the rows that matter most.")
        }
        if !allGaps.isEmpty, percentile(allGaps, 0.95) > streamTickGapCeilingMs {
            addLead(rank: 9, "Streaming cadence p95 intra-round inter-tick gap is \(fmt(percentile(allGaps, 0.95), 0)) ms — over the \(Int(streamTickGapCeilingMs)) ms bound",
                    evidence: "\(allGaps.count) intra-round inter-tick interval(s) across \(tickTurns.count) turn(s) "
                        + "in the \(days)d window (provider-round boundaries excluded — "
                        + "\(interRoundGaps.count) dispatch/TTFT interval(s) reported separately).",
                    action: "Chunk delivery WITHIN a provider stream is uneven. Scope honestly: the ticker is "
                        + "chunk-gated, so a zero-chunk freeze (\"she froze\") emits no tick and is NOT visible "
                        + "here — that shape lands in TTFT and the turn-speed section, not this metric.")
        }
    }
    line()

    // ── the remaining dark lanes ──
    line("### The other dark lanes")
    line()
    line("| lane | reading |")
    line("|---|---|")
    line("| `context.stage` names | \(traceStageRowsWindow == 0 ? "**no row in window**" : "\(traceStageRowsWindow) row(s): " + topCounts(traceStageNames, 6)) |")
    line("| `turn.failed` reasons | \(turnFailedRowsWindow == 0 ? "**no row in window**" : "\(turnFailedRowsWindow) row(s): " + topCounts(turnFailedReasons, 4)) |")
    line("| `motor.state` phases | \(motorRowsWindow == 0 ? "**no row in window**" : "\(motorRowsWindow) row(s) over \(motorActionLastPhase.count) action(s): " + topCounts(motorPhaseCounts, 5)) |")
    let intentionalGithubWaits = motorActionLastPhase.filter {
        $0.value.domain == "github_command"
            && ($0.value.phase == "waiting_external" || $0.value.phase == "ready")
    }
    let halfOpenMotor = motorActionLastPhase.filter {
        !motorTerminalPhases.contains($0.value.phase)
            && !intentionalGithubWaits.keys.contains($0.key)
    }
    var halfOpenPhases: [String: Int] = [:]
    for (_, v) in halfOpenMotor { halfOpenPhases[v.phase, default: 0] += 1 }
    line("| `motor.state` half-open actions | \(motorActionLastPhase.isEmpty ? "**no action in window**" : "\(halfOpenMotor.count) of \(motorActionLastPhase.count) never reached a terminal phase") |")
    line("| `motor.state` intentional GitHub waits | **\(intentionalGithubWaits.count)** `github_command` action(s) in `ready`/`waiting_external` (watcher-owned, not abandoned) |")
    line("| `memory.commit` two feeds | turn_traces **\(memoryCommitTraceRows)** vs traces/events.jsonl **\(memoryCommitEventRows)** row(s) in window |")
    line("| `turn.plan` two feeds | turn_traces **\(turnPlanTraceRows)** (payload fields: \(turnPlanTraceFieldCounts.isEmpty ? "—" : turnPlanTraceFieldCounts.sorted().map(String.init).joined(separator: "/"))) vs events **\(turnPlanEventRows)** (payload fields: \(turnPlanEventFieldCounts.isEmpty ? "—" : turnPlanEventFieldCounts.sorted().map(String.init).joined(separator: "/"))) |")
    line("| `turn.plan` policy outcomes | \(turnPlanEventRows == 0 ? "**no row in window**" : topCounts(turnPlanPolicyOutcomes, 4) + (turnPlanNullPolicy > 0 ? ", \(turnPlanNullPolicy) row(s) with a null decision" : "")) |")
    line("| `turn.plan` permission levels | \(turnPlanEventRows == 0 ? "**no row in window**" : topCounts(turnPlanPermissionLevels, 4)) |")
    line("| `tool.preload` breadth | \(toolPreloadInWindow == 0 ? "**no row in window**" : "\(toolPreloadInWindow) row(s), groups: " + topCounts(toolPreloadGroups, 4)) |")
    line()
    if !halfOpenMotor.isEmpty {
        let oldest = halfOpenMotor.values.map { $0.ts }.min()
        addLead(rank: 8, "\(halfOpenMotor.count) motor action(s) never reached a terminal phase",
                evidence: "`motor.state` (schema `motor.action.read-model.v1`): \(halfOpenMotor.count) of "
                    + "\(motorActionLastPhase.count) `actionIdentity` values are last seen in a non-terminal phase "
                    + "(\(topCounts(halfOpenPhases, 3)))"
                    + (oldest.map { "; oldest \(stamp($0))" } ?? "") + ".",
                action: "Terminal phases are `succeeded/failed/cancelled/expired` (MotorActionReadModel.swift:24 — "
                    + "`blocked` is deliberately NOT terminal). GitHub Command `ready`/`waiting_external` rows are "
                    + "watcher-owned long-lived state and are excluded. A different lane stuck in one phase forever looks identical "
                    + "to a quiet system from every other section.")
    }
    if !motorUndeclaredPhases.isEmpty {
        addLead(rank: 7, "`motor.state` carries \(motorUndeclaredPhases.count) phase value(s) outside `MotorActionPhase`",
                evidence: "Phases seen that the enum cannot produce: \(topCounts(motorUndeclaredPhases, 4)).",
                action: "Either the enum gained a case and this reader is stale, or something is writing free text "
                    + "into a closed vocabulary. Both break every consumer that switches on it.")
    }
    let memoryCommitFeedsDisagree = (memoryCommitTraceRows == 0) != (memoryCommitEventRows == 0)
    if memoryCommitFeedsDisagree {
        addLead(rank: 6, "The two `memory.commit` feeds disagree: turn_traces \(memoryCommitTraceRows) vs events \(memoryCommitEventRows)",
                evidence: "`SwiftToolDispatcher+MemoryTools.swift:280` fires the bus and `:283` appends to "
                    + "`traces/events.jsonl`; in this window one of the two is empty and the other is not.",
                action: "One of the two write paths is broken. The instrument grades memory from `memory.sqlite`, "
                    + "so a broken TOOL path with a healthy STORE reads clean everywhere else.")
    }
    let undeclaredOutcomes = turnPlanPolicyOutcomes.keys.filter { !declaredPolicyOutcomes.contains($0) }
    if !undeclaredOutcomes.isEmpty {
        addLead(rank: 4, "`turn.plan` carries \(undeclaredOutcomes.count) policy outcome(s) `UnifiedPolicyOutcome` cannot produce",
                evidence: "Outcomes seen: \(topCounts(turnPlanPolicyOutcomes, 5)); the enum allows only "
                    + "`allow`, `confirm`, `deny` (TrustCenter/UnifiedPolicyDecision.swift:4).",
                action: "This is the richest policy record in the system and only production code reads it. A gate "
                    + "that starts defaulting permissive shows up here first and nowhere else.")
    }
    if turnPlanTraceRows > 0, turnPlanEventRows > 0,
       let traceFields = turnPlanTraceFieldCounts.max(), let eventFields = turnPlanEventFieldCounts.max(),
       traceFields != eventFields {
        line("> **The two `turn.plan` payloads are NOT the same shape** — \(traceFields) field(s) on the bus row and")
        line("> \(eventFields) on the events row. A consumer written against one reads nothing from the other.")
        line()
    }
}

// ── (i.2) Wave-3 uncovered feeds ────────────────────────────────────────────
line("<a id=\"sec-i2\"></a>")
line()
line("## (i.2) WAVE-3 FEEDS — the uncovered ACTIVE lanes, one reading each")
line()
line("Each feed below had NO reader in this instrument and is written by the live app. They were chosen by")
line("silent-failure class, not by size. Every one renders `source absent` or `source unreadable` rather than")
line("a zero when it did not read.")
line()

// chat/session_state + per-session residue
line("### `chat/session_state/` + per-session residue — state-lifecycle leak")
line()
if !sessionStatePresent {
    line("- `chat/session_state/`: **source absent** — `\(mdCode(sessionStateRoot))` is not in this data root. "
         + "Not a zero.")
} else if let blocked = sessionStateState.blockedLabel {
    line("- `chat/session_state/`: **\(mdText(blocked))**")
} else {
    line("- session_state directories: **\(sessionStateDirs)** (\(humanBytes(sessionStateBytes))) · "
         + "digest.txt \(sessionStateDigestFiles) · provider_usage.json \(sessionStateProviderUsageFiles)")
    if chatSessionsFeed.didRead {
        line("- orphans (id in neither `chat/sessions.json` nor the archive tail): **\(sessionStateOrphans.count)**"
             + (sessionStateOrphans.isEmpty ? "" : " — e.g. "
                + sessionStateOrphans.sorted().prefix(4).map { "`\(mdCode($0))`" }.joined(separator: ", ")))
    } else {
        line("- orphans: **not computed — `chat/sessions.json` did not read**, so \"orphan\" cannot be decided. "
             + "This is not \"0 orphans\".")
    }
}
if let blocked = chatSessionsDirState.blockedLabel {
    line("- `chat/sessions/`: **\(mdText(blocked))**")
} else if !chatSessionsDirPresent {
    line("- `chat/sessions/`: **source absent**")
} else {
    let maxGenerations = compactGenerationsBySession.values.max() ?? 0
    line("- compaction artifacts: **\(compactGenerationsBySession.values.reduce(0, +))** file(s) "
         + "(\(humanBytes(compactBytes))) across \(compactGenerationsBySession.count) session(s); "
         + "max generations on one session: **\(maxGenerations)** (bound: \(compactGenerationCeiling))")
    line("- sessions whose compact artifacts are NOT smaller than the live transcript: "
         + "**\(compactNotSmaller.count)**")
    let staleFlags = cancelledFlags.filter { $0.age > cancelledFlagMaxAgeDays }
    line("- `cancelled.flag` files: **\(cancelledFlags.count)**, "
         + (cancelledFlags.isEmpty ? "none" : "oldest \(fmt(cancelledFlags.map { $0.age }.max() ?? 0, 1))d")
         + " — **\(staleFlags.count)** cleanup residue older than \(Int(cancelledFlagMaxAgeDays))d; "
         + "turn acceptance clears the session flag before execution")
    if maxGenerations > compactGenerationCeiling {
        addLead(rank: 10, "One chat session holds \(maxGenerations) compaction generations — over the \(compactGenerationCeiling) bound",
                evidence: "`chat/sessions/*/messages.compact.*.jsonl`: \(compactGenerationsBySession.values.reduce(0, +)) "
                    + "file(s), \(humanBytes(compactBytes)), no visible retention.",
                action: "The pre-compaction transcript survives beside the compacted one, so a compaction bug "
                    + "DOUBLES storage instead of reducing it — silently, because nothing reads these files.")
    }
    if !compactNotSmaller.isEmpty {
        addLead(rank: 9, "\(compactNotSmaller.count) session(s) have compaction artifacts no smaller than the live transcript",
                evidence: "Sessions: " + compactNotSmaller.sorted().prefix(4).map { "`\(mdCode($0))`" }
                    .joined(separator: ", ") + ". Compaction that does not shrink is compaction that cost storage.",
                action: "Check the autocompactor's output for those sessions. A compact file larger than its "
                    + "source is the wrong-value failure of the whole compaction lane.")
    }
}
if sessionStateOrphans.count > sessionStateOrphanCeiling {
    addLead(rank: 7, "\(sessionStateOrphans.count) orphan `chat/session_state/` directories — over the \(sessionStateOrphanCeiling) bound",
            evidence: "\(sessionStateDirs) session_state directories, \(humanBytes(sessionStateBytes)); "
                + "\(sessionStateOrphans.count) belong to no session in `chat/sessions.json` or the archive tail.",
            action: "Nothing prunes this directory — every session ever created leaves one permanently, including "
                + "test ids. Add a sweep keyed to session deletion, or state the retention policy.")
}
line()

// activity/events.jsonl
line("### `activity/events.jsonl` — the SECOND events feed, and its eviction cliff")
line()
if skipFeedSection(sources.isPresent("activity/events.jsonl"), "the activity event feed",
                   "activity/events.jsonl", activityEventsPath) {
    // labelled above
} else {
    let linePct = Double(activityRows) / Double(activityEventsLineCap) * 100
    let bytePct = Double(activityBytes) / Double(activityTrimTriggerBytes) * 100
    line("- rows: **\(activityRows) / \(activityEventsLineCap)** line cap (\(fmt(linePct, 1))%) · "
         + "size **\(humanBytes(activityBytes)) / \(humanBytes(activityTrimTriggerBytes))** trim trigger "
         + "(\(fmt(bytePct, 1))%)")
    line("- newest row: \(activityNewest.map { stamp($0) } ?? "**no parseable timestamp on any row**") · "
         + "kinds: \(activityKinds.isEmpty ? "**none**" : "\(activityKinds.count) — " + topCounts(activityKinds, 6))")
    line("- kinds that the FIRST eviction would remove entirely (≤2 rows): "
         + (activityRareKinds.isEmpty ? "none"
            : "**\(activityRareKinds.count)** — " + activityRareKinds.prefix(8).map { "`\(mdCode($0))`" }.joined(separator: ", ")))
    line()
    line("The 5000-line cap is only enforced once the file crosses the 4 MiB trigger")
    line("(PersistenceCore.swift:970 / :1188-1192), so the first trim drops the OLDEST rows — which is exactly")
    line("where the single-row kinds live. This is named BEFORE the trim; after it, there is nothing left to name.")
    line()
    if linePct >= 90 || bytePct >= 90 {
        addLead(rank: 6, "`activity/events.jsonl` is at \(fmt(max(linePct, bytePct), 0))% of its eviction threshold",
                evidence: "\(activityRows)/\(activityEventsLineCap) rows and \(humanBytes(activityBytes))/"
                    + "\(humanBytes(activityTrimTriggerBytes)); \(activityRareKinds.count) kind(s) have ≤2 rows and "
                    + "would be erased by the first trim: "
                    + activityRareKinds.prefix(6).map { "`\(mdCode($0))`" }.joined(separator: ", ") + ".",
                action: "Five-plus subsystems co-write this feed and nothing reads it. Decide the retention before "
                    + "the trim, not after — the rare kinds are the ones a regression would show up in.")
    }
}

// builder_audit
line("### `builder_audit/` — bounded builder receipts and their sidecars")
line()
if let blocked = builderAuditState.blockedLabel {
    line("- **\(mdText(blocked))**")
} else if !builderAuditPresent {
    line("- **source absent** — `\(mdCode(builderAuditRoot))` is not in this data root. Not a zero.")
} else {
    line("- receipts: **\(builderAuditReceiptFiles) / \(builderAuditReceiptCeiling)** writer-retention bound · "
         + "sidecars: **\(builderAuditSidecarFiles)** · total **\(builderAuditFiles)** file(s), "
         + "**\(humanBytes(builderAuditBytes))**")
    line("- oldest retained artifact: \(builderAuditOldest.map { "\(stamp($0)) (\(ageDaysText($0)))" } ?? "—") "
         + "· newest: \(builderAuditNewest.map { stamp($0) } ?? "—")")
    if builderAuditReceiptFiles > builderAuditReceiptCeiling {
        addLead(rank: 7, "`builder_audit/` holds \(builderAuditReceiptFiles) receipts — over its \(builderAuditReceiptCeiling)-receipt writer bound",
                evidence: "The writer prunes UUID-named JSON receipts to \(builderAuditReceiptCeiling) and removes "
                    + "their matching sidecars. The directory currently has \(builderAuditSidecarFiles) sidecar(s) "
                    + "and \(humanBytes(builderAuditBytes)) total.",
                action: "Inspect the shared builder audit writer: a count over 500 means pruning stopped or a "
                    + "writer bypassed the retained path.")
    }
}
line()

// surface error feeds
line("### Surface error feeds — FAILING is not IDLE")
line()
line("| surface | error rows | in window | newest error | top codes | receipts newest | reading |")
line("|---|---|---|---|---|---|---|")
for f in surfaceErrorFeeds.sorted(by: { $0.name < $1.name }) {
    if let blocked = f.errorState.blockedLabel {
        line("| \(mdText(f.name)) | \(mdText(blocked)) | — | — | — | "
             + "\(f.receiptNewest.map { stamp($0) } ?? "—") | not measured |")
        continue
    }
    let atLineCap = f.lineCap.map { f.errorRows >= $0 } ?? false
    let atByteCap = f.byteCap.map { f.errorBytes >= $0 } ?? false
    let atCap = atLineCap || atByteCap
    let capSuffix: String = {
        if let cap = f.lineCap, atLineCap { return " (**line cap \(cap)**)" }
        if let cap = f.byteCap { return " (**\(humanBytes(f.errorBytes)) / \(humanBytes(cap)) byte cap**)" }
        return ""
    }()
    let receiptsStale = f.receiptState.didRead
        ? ((f.receiptNewest.map { $0 < windowStart } ?? true) ? "receipts stale" : "receipts live")
        : "receipts \(f.receiptState.blockedLabel ?? "unknown")"
    let currentStateOverridesHistory = f.name == "slack" && slackRuntimeIsCurrentConnected
    let reading = currentStateOverridesHistory
        ? "**CURRENTLY CONNECTED** (historical errors retained)"
        : (f.errorRowsInWindow > 0 && receiptsStale == "receipts stale"
            ? "**FAILING, NOT IDLE**" : (atCap ? "**AT RETENTION CAP**" : "ok"))
    line("| \(mdText(f.name)) | \(f.errorRows)\(capSuffix) | \(f.errorRowsInWindow) | "
         + "\(f.errorNewest.map { stamp($0) } ?? "—") | \(topCounts(f.codes, 3)) | "
         + "\(f.receiptNewest.map { stamp($0) } ?? "—") | \(reading) |")
    if f.errorRowsInWindow > 0, f.receiptState.didRead,
       (f.receiptNewest.map { $0 < windowStart } ?? true), !currentStateOverridesHistory {
        addLead(rank: 4, "`\(mdCode(f.name))` is FAILING, not idle — \(f.errorRowsInWindow) error(s) in window, receipts stale",
                evidence: "`\(mdCode(f.name))/errors.jsonl`: \(f.errorRows) row(s)"
                    + (atLineCap ? " — **at its \(f.lineCap!)-row cap**" : "")
                    + (atByteCap ? " — **at its \(humanBytes(f.byteCap!)) byte cap**" : "")
                    + ", \(f.errorRowsInWindow) inside the "
                    + "\(days)d window, newest \(f.errorNewest.map { stamp($0) } ?? "—"); top codes "
                    + "\(topCounts(f.codes, 3)). Its receipt feed's newest row is "
                    + "\(f.receiptNewest.map { stamp($0) } ?? "none at all") — outside the window.",
                action: "Every other tier reads this surface as quiet. A loop erroring continuously with nothing "
                    + "succeeding is the shape a self-bricked poll loop makes.")
    }
    if atCap {
        let capDescription = atLineCap
            ? "\(f.lineCap!)-row cap"
            : "\(humanBytes(f.byteCap!)) byte cap"
        addLead(rank: 6, "`\(mdCode(f.name))/errors.jsonl` is AT its \(capDescription)",
                evidence: "\(f.errorRows) row(s), \(humanBytes(f.errorBytes)) retained. At the cap the feed is a rolling "
                    + "window: the oldest errors — including the first one, which is usually the cause — are gone.",
                action: "Read the error codes before the tail rolls off: \(topCounts(f.codes, 4)).")
    }
}
line()

// logs/*.txt + errors.jsonl
line("### `logs/*.txt` + `logs/errors.jsonl` — bounded files, paired error lanes")
line()
if let blocked = logsTextState.blockedLabel {
    line("- `logs/*.txt`: **\(mdText(blocked))**")
} else if !logsTextPresent {
    line("- `logs/*.txt`: **source absent** — `\(mdCode(logsDirectoryRoot))` is not in this data root. Not a zero.")
} else {
    let totalBytes = logTextFiles.reduce(Int64(0)) { $0 + $1.bytes }
    let largest = logTextFiles.max { l, r in
        l.bytes == r.bytes ? l.name < r.name : l.bytes < r.bytes
    }
    line("- text files: **\(logTextFiles.count)** · total **\(humanBytes(totalBytes))** · largest "
         + (largest.map { "`\(mdCode($0.name))` **\(humanBytes($0.bytes))** / \(humanBytes(logTextByteCeiling)) bound" }
            ?? "—")
         + " · newest mtime \(logTextFiles.compactMap(\.modified).max().map { stamp($0) } ?? "—")")
    if let largest, largest.bytes > logTextByteCeiling {
        addLead(rank: 7, "`logs/\(largest.name)` is \(humanBytes(largest.bytes)) — over the \(humanBytes(logTextByteCeiling)) text-log bound",
                evidence: "\(logTextFiles.count) `logs/*.txt` file(s), \(humanBytes(totalBytes)) total. The report reads only "
                    + "name/size/mtime, never the potentially sensitive text.",
                action: "Rotate or cap this writer. A human-readable daemon/report log is still a feed, and a stale "
                    + "fossil must not be allowed to consume disk indefinitely.")
    }
}
if let blocked = generalErrorFeed.blockedLabel {
    line("- `logs/errors.jsonl`: **\(mdText(blocked))**")
} else {
    line("- `logs/errors.jsonl`: **\(generalErrorRows)** row(s), **\(generalErrorsInWindow)** in the \(days)d window · "
         + "newest \(generalErrorNewest.map { stamp($0) } ?? "**no parseable timestamp on any row**") · codes "
         + (generalErrorCodes.isEmpty ? "**none**" : topCounts(generalErrorCodes, 4)))
}
if let blocked = loopFailuresFeed.blockedLabel {
    line("- `logs/background_loop_failures.jsonl`: **\(mdText(blocked))** — not comparable to general errors.")
} else {
    line("- `logs/background_loop_failures.jsonl`: **\(loopFailuresInWindow)** failure row(s) in the same window "
         + "(\(loopFailureRowsTotal) retained total). Both error lanes are printed together so one cannot hide behind the other.")
}
line()

// from_codex
line("### `from_codex/` — retained audit envelopes and last-message sidecars")
line()
if let blocked = fromCodexState.blockedLabel {
    line("- **\(mdText(blocked))**")
} else if !fromCodexPresent {
    line("- **source absent** — `\(mdCode(fromCodexRoot))` is not in this data root. Not a zero.")
} else {
    let auditBytes = fromCodexAudits.values.reduce(Int64(0)) { $0 + $1.bytes }
    let sidecarBytes = fromCodexSidecars.values.reduce(Int64(0)) { $0 + $1.bytes }
    let newestAudit = fromCodexAudits.values.compactMap(\.modified).max()
    let newestSidecar = fromCodexSidecars.values.compactMap(\.modified).max()
    line("- audit envelopes: **\(fromCodexAudits.count) / \(fromCodexAuditRetention)** writer-retention bound · "
         + "\(humanBytes(auditBytes)) · newest \(newestAudit.map { stamp($0) } ?? "—")")
    line("- last-message sidecars: **\(fromCodexSidecars.count)** · \(humanBytes(sidecarBytes)) · newest "
         + "\(newestSidecar.map { stamp($0) } ?? "—") · unpaired **\(fromCodexUnpairedSidecars.count)** "
         + "(\(fromCodexStaleUnpairedSidecars.count) older than \(Int(fromCodexUnpairedGraceDays))d)")
    if fromCodexAudits.count > fromCodexAuditRetention {
        addLead(rank: 7, "`from_codex/` holds \(fromCodexAudits.count) audit envelopes — over the \(fromCodexAuditRetention)-file writer-retention bound",
                evidence: "\(humanBytes(auditBytes)) in JSON envelopes. `invoke_codex` trims after each completed "
                    + "write, so this count means trimming stopped or a writer bypassed the shared path.",
                action: "Inspect the `invoke_codex` audit writer before the oldest prompt/reply evidence grows out "
                    + "of the intended bounded window.")
    }
    if !fromCodexStaleUnpairedSidecars.isEmpty {
        let examples = fromCodexStaleUnpairedSidecars.sorted { $0.name < $1.name }.prefix(4)
            .map { "`\(mdCode($0.name))`" }.joined(separator: ", ")
        addLead(rank: 6, "\(fromCodexStaleUnpairedSidecars.count) `from_codex` last-message sidecar(s) are unpaired for over \(Int(fromCodexUnpairedGraceDays)) day",
                evidence: "No matching JSON audit envelope exists; examples: \(examples). A fresh unpaired sidecar "
                    + "can belong to an active Codex run, so only files past the grace period are named.",
                action: "Review the interrupted Codex run manually. Do not replay its text automatically: the whole "
                    + "point of the audit pair is to preserve ambiguous output for deliberate handling.")
    }
}
line()

// disabled shadow tree
line("### `disabled/` — SHADOW TREE, never a live feed")
line()
if let blocked = disabledShadowState.blockedLabel {
    line("- **\(mdText(blocked))**")
} else if !disabledShadowPresent {
    line("- **source absent** — `\(mdCode(disabledShadowRoot))` is not in this data root. Not a zero.")
} else {
    let totalBytes = disabledShadowArtifacts.reduce(Int64(0)) { $0 + $1.bytes }
    let newest = disabledShadowArtifacts.compactMap(\.modified).max()
    let liveShadows = disabledShadowArtifacts.filter(\.shadowsLivePath)
    line("- snapshots: **\(Set(disabledShadowArtifacts.map(\.snapshot)).count)** · files: **\(disabledShadowArtifacts.count)** · "
         + "bytes: **\(humanBytes(totalBytes))** · newest mtime \(newest.map { stamp($0) } ?? "—")")
    line("- live-path shadows: **\(liveShadows.count)** — these rows are excluded from the normal NOT COVERED sort.")
    if !liveShadows.isEmpty {
        line("- examples: " + liveShadows.sorted { $0.relativePath < $1.relativePath }.prefix(6)
            .map { "`\(mdCode($0.snapshot))/\(mdCode($0.relativePath))` → **shadows LIVE** `\(mdCode($0.relativePath))`" }
            .joined(separator: "; "))
    }
    if !disabledShadowReaderLabels.isEmpty {
        line("- **VIOLATION:** \(disabledShadowReaderLabels.count) non-shadow reader(s) resolve under `disabled/`: "
             + disabledShadowReaderLabels.map { "`\(mdCode($0))`" }.joined(separator: ", "))
        addLead(rank: 2, "A live reader resolves under `disabled/` — subject-pinning risk",
                evidence: "Readers: " + disabledShadowReaderLabels.map { "`\(mdCode($0))`" }.joined(separator: ", ") + ".",
                action: "Point each reader at the canonical live path. A disabled snapshot may resemble a healthy "
                    + "store but is never evidence about the running subsystem.")
    } else {
        line("- live-reader guard: **0** non-shadow readers resolve under `disabled/`.")
    }
    // Resembling a live path is why this inventory exists, but it is not itself
    // a defect: the tree is explicitly disabled and excluded from every live
    // reader. Only the reader-guard violation above is actionable. Raising a
    // lead merely because inert fossils exist made safely quarantined data the
    // report's top problem.
}
line()

// telegram offset + inbox
line("### `telegram/last_offset.json` + `telegram/update_inbox/` — lose or duplicate User's messages")
line()
if telegramOffsetFeed.didRead {
    if let o = telegramOffset {
        line("- offset: **\(o)** \(o < 0 ? "— **NEGATIVE, which the API cannot produce**" : "") · file mtime "
             + "\(telegramOffsetModified.map { "\(stamp($0)) (\(ageDaysText($0)))" } ?? "—")")
        if o < 0 {
            addLead(rank: 3, "`telegram/last_offset.json` holds a negative offset (\(o))",
                    evidence: "The Telegram update offset is a monotonically increasing non-negative integer; "
                        + "this file holds \(o).",
                    action: "An offset that rolls backwards re-delivers every update; one that jumps forward drops "
                        + "messages permanently. Neither is observable from turn counts.")
        }
    } else {
        line("- offset: **\(mdText(telegramOffsetRaw ?? "present but no numeric offset key"))**")
    }
} else {
    line("- offset: **\(mdText(telegramOffsetFeed.blockedLabel ?? "not read"))**")
}
if let blocked = telegramInboxState.blockedLabel {
    line("- `update_inbox/`: **\(mdText(blocked))**")
} else if !telegramInboxPresent {
    line("- `update_inbox/`: **source absent**")
} else if !telegramInboxIndexFeed.didRead {
    line("- `update_inbox/`: **\(telegramInboxClaimFiles)** claim file(s) + **\(telegramInboxLockFiles)** lock sidecar(s); "
         + "claim index \(mdText(telegramInboxIndexFeed.blockedLabel ?? "not readable")) — pending work cannot be distinguished from retained terminal claims")
} else {
    let workCount = telegramInboxPending + telegramInboxProcessing
    let oldestWorkAge = telegramInboxWorkOldest.map { daysSince($0) }
    line("- `update_inbox/`: **\(telegramInboxClaimFiles)** claim file(s) + **\(telegramInboxLockFiles)** lock sidecar(s); "
         + "pending **\(telegramInboxPending)** · processing **\(telegramInboxProcessing)** · completed retained "
         + "**\(telegramInboxCompleted) / \(telegramInboxTerminalRetention)** · outcome-unknown retained "
         + "**\(telegramInboxOutcomeUnknown)**"
         + (telegramInboxOtherPhases > 0 ? " · **\(telegramInboxOtherPhases) malformed/unknown index row(s)**" : ""))
    line("- drain reading: " + (workCount == 0
        ? "**idle** — terminal claim retention is intentional and is not queued work"
        : "**\(workCount) active claim(s)**, oldest "
            + (telegramInboxWorkOldest.map { "\(stamp($0)) (\(fmt(oldestWorkAge ?? 0, 1))d)" } ?? "has no claim-file mtime")))
    if workCount > 0, let oldestWorkAge, oldestWorkAge > telegramInboxDrainAgeDays {
        addLead(rank: 5, "`telegram/update_inbox/` is not draining — \(workCount) pending/processing claim(s), oldest \(fmt(oldestWorkAge, 1))d",
                evidence: "The claim index contains \(telegramInboxPending) pending and \(telegramInboxProcessing) "
                    + "processing update(s); the oldest active claim file is \(fmt(oldestWorkAge, 1)) day(s) old. "
                    + "The \(telegramInboxCompleted + telegramInboxOutcomeUnknown) terminal rows are bounded retention, not queued work.",
                action: "A message that arrives and is never drained is a message User sent and she never saw. "
                    + "Nothing else in any tier counts these files.")
    }
}
line()

// doctor
line("### `doctor/latest.json` — what self-healing believes")
line()
if skipFeedSection(sources.isPresent("doctor/latest.json"), "the doctor verdict", "doctor/latest.json", doctorPath) {
    // labelled
} else {
    let stampDate = doctorGeneratedAt ?? doctorModified
    let age = stampDate.map { daysSince($0) }
    line("- checks: **\(doctorChecks.count)** · failing: **\(doctorFailing.count)**"
         + (doctorFailing.isEmpty ? "" : " — " + doctorFailing.sorted().prefix(4).map { "`\(mdCode($0))`" }.joined(separator: ", ")))
    line("- verdict written: \(stampDate.map { "\(stamp($0)) (\(fmt(age ?? 0, 1))d ago)" } ?? "**no parseable stamp**") "
         + "· staleness bound \(Int(doctorStaleAgeDays))d")
    if doctorChecks.isEmpty {
        line("- **the file read and named no checks** — that is not a healthy doctor, it is an empty verdict.")
    }
    if let age, age > doctorStaleAgeDays {
        addLead(rank: 4, "`doctor/latest.json` is \(fmt(age, 1)) days stale — self-healing is acting on a frozen verdict",
                evidence: "`SelfHealingHook.swift:213` reads \"healthy = no check has status fail\" from this file. "
                    + "Newest stamp \(stampDate.map { stamp($0) } ?? "—"), \(doctorChecks.count) check(s), "
                    + "\(doctorFailing.count) failing.",
                action: "A doctor run that crashes before writing leaves the PREVIOUS healthy verdict in place and "
                    + "self-healing keeps believing it. Check the doctor loop actually ran.")
    }
    if !doctorFailing.isEmpty {
        addLead(rank: 5, "The doctor's own verdict lists \(doctorFailing.count) failing check(s)",
                evidence: "`doctor/latest.json`: " + doctorFailing.sorted().prefix(6).map { "`\(mdCode($0))`" }
                    .joined(separator: ", ") + ".",
                action: "This file is read by self-healing and by nothing else. A `fail` here has never appeared "
                    + "in any report until now.")
    }
}
line()

// oauth tokens
line("### `oauth_tokens/` — SHAPE ONLY, never material")
line()
line("This reader is allowed to look at exactly two keys (`expires_at`, `scope`) and copies nothing else out of")
line("those objects — same boundary as `providerSafeKeys` above, and for the same reason: this report is a file.")
line()
if let blocked = oauthState.blockedLabel {
    line("- **\(mdText(blocked))**")
} else if !oauthPresent {
    line("- **source absent** — `\(mdCode(oauthRoot))` is not in this data root. Not a zero.")
} else if oauthTokenFiles.isEmpty {
    line("- directory present, **no `*.json` token file in it**.")
} else {
    line("| token file | parsed | keys | mtime | age | expires_at | scope |")
    line("|---|---|---|---|---|---|---|")
    for t in oauthTokenFiles.sorted(by: { $0.id < $1.id }) {
        line("| `\(mdCode(t.id))` | \(t.parsed ? "yes" : "**NO**") | \(t.parsed ? "\(t.keyCount)" : "—") | "
             + "\(t.modified.map { stamp($0) } ?? "—") | \(t.modified.map { ageDaysText($0) } ?? "—") | "
             + "\(mdText(t.expiresAt ?? "—")) | \(mdText(t.scope ?? "—")) |")
    }
    line()
    // File age is not credential expiry: Slack bot/app tokens and several
    // provider credentials are intentionally long-lived and may be healthy for
    // months without rewriting their file. Raise only from an explicit,
    // parseable expires_at authority.
    let expired = oauthTokenFiles.compactMap { token -> (OAuthTokenFile, Date)? in
        guard let expiry = oauthExpiryDate(token.expiresAt), expiry <= now else { return nil }
        return (token, expiry)
    }
    if !expired.isEmpty {
        addLead(rank: 6, "\(expired.count) OAuth token file(s) carry an expired `expires_at`",
                evidence: "Shape only: " + expired.sorted(by: { $0.0.id < $1.0.id }).prefix(4)
                    .map { "`\(mdCode($0.0.id))` expired \(stamp($0.1))" }.joined(separator: ", ")
                    + ". Files without explicit expiry are not classified from mtime. No token material was read.",
                action: "Refresh or reconnect the affected provider before relying on it. Long-lived credentials "
                    + "without `expires_at` are not presumed stale merely because their file is old.")
    }
}
line()

// mac_control operations
line("### `mac_control/operations.json` vs the dispatch trace")
line()
if skipFeedSection(sources.isPresent("mac_control/operations.json"), "the mac-control operation store",
                   "mac_control/operations.json", macOperationsPath) {
    // labelled
} else {
    line("- operations in the store: **\(macOperationCount)** · statuses: "
         + (macOperationStatuses.isEmpty ? "**none carried a status field**" : topCounts(macOperationStatuses, 4)))
    line("- newest operation stamp: \(macOperationNewest.map { stamp($0) } ?? "**none parseable**") · file "
         + "**\(humanBytes(macOperationBytes))** / \(humanBytes(macOperationsByteCeiling)) bound "
         + "(single JSON object, no rotation)")
    if sources.isUnreadable("traces/events.jsonl") || !eventsPresent {
        line("- `mac.*` dispatches in window: **not comparable — `traces/events.jsonl` did not read**. "
             + "This is not \"0 dispatches\".")
    } else {
        line("- `mac.*` rows in `traces/events.jsonl` (\(runtimeEvidenceLabel)): **\(macToolDispatchInWindow)** — the leads about "
             + "`mac.act`/`mac_view` come from THERE, never from this store")
        line("- Mac-control operations in \(runtimeEvidenceLabel): **\(macOperationsInRuntimeEvidence)** "
             + "(\(macOperationsInWindow) in the full \(days)d window)")
        let hi = max(macOperationsInRuntimeEvidence, macToolDispatchInWindow)
        let lo = min(macOperationsInRuntimeEvidence, macToolDispatchInWindow)
        if hi > 0, lo == 0 || Double(hi) / Double(max(lo, 1)) > 4.0 {
            addLead(rank: 7, "The mac-control operation store and the dispatch trace disagree (\(macOperationsInRuntimeEvidence) vs \(macToolDispatchInWindow))",
                    evidence: "`mac_control/operations.json` carries \(macOperationsInRuntimeEvidence) operation(s) in the "
                        + "\(runtimeEvidenceLabel); "
                        + "`traces/events.jsonl` carries \(macToolDispatchInWindow) `mac.*` dispatch row(s) in the "
                        + "same cohort. (The store retains \(macOperationCount) total; older rows are excluded.)",
                    action: "Two records of the same action that disagree means one of them stopped being written. "
                        + "Nothing reads the operation store, so only the trace side would have been noticed.")
        }
    }
    if macOperationBytes > macOperationsByteCeiling {
        addLead(rank: 9, "`mac_control/operations.json` is \(humanBytes(macOperationBytes)) in ONE JSON object",
                evidence: "Bound \(humanBytes(macOperationsByteCeiling)); \(macOperationCount) operation(s). A "
                    + "single-object store with no rotation is rewritten whole on every append.",
                action: "Add rotation or a cap. Growth inside one object is the shape that gets slower with every "
                    + "write and never says so.")
    }
}
line()

line("### Local Mac-control and browser IPC discovery")
line()
line("Shape and metadata only: descriptor bearer values and `browser_ipc_token` contents are never read or rendered; no listener is probed.")
line()
if case .absent = macctlBridgeFeed {
    line("- Mac-control bridge descriptor: **source absent**")
} else if sources.isUnreadable(macctlBridgeDescriptorLabel) {
    line("- Mac-control bridge descriptor: **source unreadable** — \(mdText(sources.reason(macctlBridgeDescriptorLabel)))")
} else {
    line("- Mac-control bridge descriptor: loopback port **\(macctlBridgePort.map(String.init) ?? "unknown")** · written \(macctlBridgeWrittenAt.map(stamp) ?? "unknown") · bearer **present (not read)**")
}
if case .absent = browserIPCFeed {
    line("- Browser IPC descriptor: **source absent**")
} else if sources.isUnreadable(browserIPCDescriptorLabel) {
    line("- Browser IPC descriptor: **source unreadable** — \(mdText(sources.reason(browserIPCDescriptorLabel)))")
} else {
    line("- Browser IPC descriptor: loopback `127.0.0.1` port **\(browserIPCPort.map(String.init) ?? "unknown")** · written \(browserIPCWrittenAt.map(stamp) ?? "unknown") · bearer **present (not read)**")
}
if !browserIPCTokenPresent {
    line("- Browser IPC bearer file: **source absent**")
} else if sources.isUnreadable(browserIPCTokenLabel) {
    line("- Browser IPC bearer file: **source unreadable** — \(mdText(sources.reason(browserIPCTokenLabel)))")
} else {
    line("- Browser IPC bearer file: **\(browserIPCTokenBytes.map(String.init) ?? "unknown") byte(s)** · private mode **yes** · contents **not read**")
}
line()

// ── (j) Leads ────────────────────────────────────────────────────────────────
line("<a id=\"sec-j\"></a>")
line()
line("## (j) LEADS — ranked, each with its evidence")
line()
if leads.isEmpty {
    line("No leads. Every detector that had a live source came back clean for this window.")
    line("Check the **Sources** table above: a lead cannot be raised from a source marked absent.")
    line()
} else {
    let ranked = leads.sorted { $0.rank == $1.rank ? $0.title < $1.title : $0.rank < $1.rank }
    for (i, lead) in ranked.enumerated() {
        line("<a id=\"lead-\(i + 1)\"></a>")
        line()
        line("### \(i + 1). \(mdHeading(lead.title))")
        line()
        line("- **evidence:** \(mdComposed(lead.evidence))")
        line("- **do:** \(mdComposed(lead.action))")
        line()
    }
}

line("---")
line()
line("*Read-only run. SQLite stores were transactionally backed up to `\(workDirDisplay)` and queried there;")
line("source connections were read-only. No application data was changed. Findings are leads for a human or")
line("their agent to act on — this instrument never writes into memory, persona, or views.*")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - BOOM summary
//
// One screen, composed LAST because every number in it is derived from a
// section below — and every number in it links to that section. Nothing is
// computed here that is not also shown, with its evidence, further down.
// ─────────────────────────────────────────────────────────────────────────────

let bodyBlock = md
md = ""

let rankedLeads = leads.sorted { $0.rank == $1.rank ? $0.title < $1.title : $0.rank < $1.rank }

line("<a id=\"sec-boom\"></a>")
line()
line("## BOOM — the whole thing on one screen")
line()

// ── health line ──────────────────────────────────────────────────────────────
var health: [String] = []
if reachWalkFailed {
    health.append("**REPORT INVALID** — [reach walk failed](#sec-i); every coverage number below is vacuous")
}
if !unreadableSources.isEmpty {
    health.append("[**\(unreadableSources.count) source(s) UNREADABLE**](#sec-sources) — "
                  + unreadableSources.prefix(3).map { "`\(mdCode($0.label))`" }.joined(separator: ", ")
                  + "; their sections are skipped, not zeroed")
}
if turnTracesUnreadable {
    health.append("[lanes](#sec-a) **source unreadable**")
} else if turnTracesPresent && !lanes.isEmpty {
    let observed = lanes.filter { $0.value.observationsInWindow > 0 }
    let dormant = observed.filter { $0.value.nonZeroInWindow == 0 }.count
    health.append("[lanes](#sec-a) **\(observed.count - dormant)/\(observed.count) live**, \(dormant) dormant")
} else {
    health.append("[lanes](#sec-a) **source absent**")
}
if turnTracesUnreadable {
    health.append("[turn p95](#sec-f) **source unreadable**")
} else if turnEvidenceTurns.isEmpty {
    health.append("[turn p95](#sec-f) **source absent**")
} else {
    let e = turnEvidenceTurns.compactMap { $0.elapsedMs }.sorted()
    health.append("[turn p95](#sec-f) **\(fmt(percentile(e, 0.95) / 1000, 1)) s** over \(e.count) turns")
}
if sources.isUnreadable("traces/events.jsonl") {
    health.append("[llm calls](#sec-e) **source unreadable**")
} else if llmCallsInWindow > 0 {
    let d = surfaceStats.values.flatMap { $0.durations }.sorted()
    health.append("[llm calls](#sec-e) **\(llmCallsInWindow)** (p95 \(fmt(percentile(d, 0.95) / 1000, 1)) s)")
} else {
    health.append("[llm calls](#sec-e) **none in window**")
}
if sources.isUnreadable("desk/desk_ops.jsonl") {
    health.append("[desk backlog](#sec-d) **desk ops unreadable**")
} else if deskStatePresent {
    let open = deskOpenAging.count
    health.append("[desk backlog](#sec-d) **\(open) open**"
                  + (deskOpsPresent ? " · \(deskOpsInWindow) ops in window" : ""))
} else {
    health.append("[desk backlog](#sec-d) **source absent**")
}
if let r = cognitionState.unreadableReason {
    health.append("[subconscious](#sec-b) **source unreadable** — \(mdCode(String(r.prefix(70))))")
} else if cognition != nil {
    health.append("[subconscious](#sec-b) \(nodesTotal) nodes · \(standingActive) standing views"
                  + (consolidationRunsInWindow > 0 ? " · \(consolidationRunsInWindow) consolidation(s)" : " · **0 consolidations**"))
} else {
    health.append("[subconscious](#sec-b) **source absent**")
}
// The functional-system line. `worst` comes from the documented severity order
// on `SysSeverity` (unreadable > absent-expected > failure-streak > stale >
// healthy), ties broken on the SYS id, so this names the same organ every run
// for the same data.
health.append("[system](#sec-h): **\(sysMeasuredCount)/\(sysRows.count) organs measured**"
              + (sysPartialCount > 0 ? " (\(sysPartialCount) partial)" : "")
              + ", worst: "
              + (sysWorst.map { "**\($0.id) \(mdComposed($0.organ))** (\(mdComposed($0.severityReason)))" }
                 ?? "**none — no organ registered**"))
health.append("[coverage](#sec-g) **\(coverageMeasured)/\(coverage.count) measured** "
              + "(\(coveragePartial) partial, \(coverageNotYet) not-yet)")
health.append("[reach](#sec-i) **\(uncoveredFeeds.count) uncovered feed(s)**, \(uncoveredActive.count) active "
              + "— \(uncoveredBurndown)")

line("**Health** — window \(days)d, \(stamp(windowStart)) → \(stamp(now)):")
line()
for h in health { line("- \(h)") }
line()

// ── top 3 leads ──────────────────────────────────────────────────────────────
line("**Top 3 leads** → full list with evidence in [(j) LEADS](#sec-j)")
line()
if rankedLeads.isEmpty {
    line("1. *No leads.* Every detector with a live source came back clean — see [(j) LEADS](#sec-j)")
    line("   and check the [Sources](#sec-sources) table, since a lead can never be raised from an absent source.")
} else {
    for (i, lead) in rankedLeads.prefix(3).enumerated() {
        let evidence = mdComposed(clip(lead.evidence, 160))
        line("\(i + 1). [\(mdLinkText(lead.title))](#lead-\(i + 1)) — \(evidence)")
    }
    if rankedLeads.count > 3 {
        line()
        line("*(\(rankedLeads.count - 3) more in [(j) LEADS](#sec-j).)*")
    }
}
line()

// ── top 3 blind spots ────────────────────────────────────────────────────────
// A blind spot is not a bad reading — it is an place the instrument CANNOT see.
// Ranked: actively-written uncovered feeds first (they grow), then subsystems
// with no measurement, then stages whose clock is dark.
struct BlindSpot { let text: String; let anchor: String }
/// Clip at a word boundary and mark the clip, so a one-screen summary never
/// ends mid-word pretending to be a complete sentence.
func clip(_ s: String, _ n: Int) -> String {
    guard s.count > n else { return s }
    let head = String(s.prefix(n))
    let cut = head.lastIndex(of: " ").map { String(head[head.startIndex..<$0]) } ?? head
    return cut + "…"
}
var blindSpots: [BlindSpot] = []
// Order is a judgment: a stage that reports a number nobody writes is worse than
// an unread file, because it looks measured. Then subsystems with no measurement
// at all. Then uncovered feeds — rolled up by directory, since a 25-byte lease
// file is not a blind spot and `chat/` with 2,600 unread feeds is.
for r in darkStages {
    blindSpots.append(BlindSpot(
        text: "`stageMs.\(mdCode(r.name))` — **dark** across \(r.samples) sample(s); "
            + (r.lastNonZero.map { "last non-zero \(stamp($0))" } ?? "never in \(lookbackDays)d")
            + " (not the same as 0 ms)",
        anchor: "sec-f"))
}
for r in coverage where r.status == .notYet {
    blindSpots.append(BlindSpot(text: "\(r.id) **\(r.subsystem)** — \(r.measurement); \(clip(r.reason, 140))",
                                anchor: "sec-g"))
}
for r in uncoveredRollups.filter({ $0.activeFeeds > 0 }).prefix(3) {
    blindSpots.append(BlindSpot(
        text: "`\(r.dir)` — **\(r.feeds) uncovered feed(s)** (\(r.activeFeeds) active), \(r.files) files, "
            + "\(humanBytes(r.bytes)), **no reader**",
        anchor: "sec-i"))
}
for r in coverage where r.status == .partial {
    blindSpots.append(BlindSpot(text: "\(r.id) **\(r.subsystem)** (partial) — \(clip(r.reason, 140))",
                                anchor: "sec-g"))
}
if sources.entries.contains(where: { !$0.present }) {
    let absentLabels = sources.entries.filter { !$0.present }.map { $0.label }
    blindSpots.append(BlindSpot(
        text: "\(absentLabels.count) registered source(s) absent from this data root — "
            + absentLabels.prefix(4).joined(separator: ", "),
        anchor: "sec-sources"))
}

line("**Top 3 blind spots** — places this instrument cannot see, not bad readings")
line()
if blindSpots.isEmpty {
    line("1. *None.* Every feed has a reader, every subsystem a measurement, every stage a live clock.")
} else {
    for (i, b) in blindSpots.prefix(3).enumerated() {
        line("\(i + 1). [\(mdLinkText(mdComposed(b.text)))](#\(b.anchor))")
    }
    if blindSpots.count > 3 {
        line()
        line("*(\(blindSpots.count - 3) more: [(g) coverage matrix](#sec-g), [(i) reach walk](#sec-i), "
             + "[(f) dark stages](#sec-f).)*")
    }
}
line()
line("Sections: [Sources](#sec-sources) · [(a) lanes](#sec-a) · [(b) subconscious](#sec-b) · "
     + "[(c) memory](#sec-c) · [(d) desk](#sec-d) · [(e) cost+latency](#sec-e) · [(f) turn speed](#sec-f) · "
     + "[(g) coverage](#sec-g) · [(h) system](#sec-h) · [(i) reach](#sec-i) · [(j) leads](#sec-j)")
line()
line("---")
line()

let boomBlock = md
let report = headerBlock + boomBlock + bodyBlock

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Emit
// ─────────────────────────────────────────────────────────────────────────────

md = report
print(md)

/// Writes the report with the data-root check RE-RESOLVED at the moment of the
/// write, not at argument-parse time.
///
/// The old code checked `--out` during startup and wrote minutes later with
/// `String.write(toFile:atomically:)`. That is a TOCTOU window wide enough to
/// drive a truck through: swap any directory on the path for a symlink into the
/// data root after the check, and the "read-only" instrument writes into
/// Agent's stores through a door it already decided was safe. Two locks now:
///
///   1. The full parent chain is re-resolved with realpath(3) immediately
///      before the write and re-tested against every spelling of the data root.
///   2. The file is opened with O_NOFOLLOW, so the FINAL component can never be
///      a symlink — the kernel refuses, no matter what changed since step 1.
///      The write goes through that one descriptor, so no later swap can
///      redirect it. `atomically:` was worse than useless here: it writes a
///      temp file next to the target and renames, following symlinks twice.
func writeReport(_ text: String, to rawPath: String) {
    let dest = absolutize(rawPath)
    let parent = (dest as NSString).deletingLastPathComponent
    guard let resolvedParent = realPathOf(parent) else {
        fail("could not write report to \(dest): parent directory \(parent) does not resolve")
    }
    let finalResolved = (resolvedParent as NSString)
        .appendingPathComponent((dest as NSString).lastPathComponent)
    if matchesDataRoot(resolvedParent) || matchesDataRoot(finalResolved) {
        fail("""
        REFUSED: --out "\(rawPath)" resolves to \(finalResolved), inside the data root
                 (\(canonicalDataRoot)). Re-checked at write time: the path chain changed
                 after the startup check, or resolves through a symlink into her stores.
        """)
    }
    guard let data = text.data(using: .utf8) else {
        fail("could not encode report as UTF-8")
    }
    let fd = open(finalResolved, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
    if fd < 0 {
        let e = errno
        if e == ELOOP {
            fail("""
            REFUSED: --out "\(rawPath)" is a symlink. The instrument will not write through a
                     symlink — the target it points at cannot be re-verified after the open.
            """)
        }
        fail("could not write report to \(finalResolved): \(String(cString: strerror(e)))")
    }
    defer { close(fd) }
    var written = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        while written < data.count {
            let n = write(fd, base.advanced(by: written), data.count - written)
            if n < 0 {
                if errno == EINTR { continue }      // a signal, not a failure
                break
            }
            if n == 0 { break }
            written += n
        }
    }
    guard written == data.count else {
        fail("could not write report to \(finalResolved): wrote \(written) of \(data.count) bytes")
    }
    FileHandle.standardError.write("agent_instrument: report written to \(finalResolved)\n".data(using: .utf8)!)
}

if let out = outPath { writeReport(md, to: out) }

// The report is emitted either way — a caller reading stdout can see WHY it is
// invalid — but the exit code tells the truth about whether it can be trusted.
if reachWalkFailed {
    FileHandle.standardError.write("""
    agent_instrument: report invalid — reach walk failed \
    (enumerator \(walkEnumeratorFailed ? "could not be created" : "yielded 0 files"), \
    \(walkEntriesVisited) entries visited, \(walkEntryErrors) per-entry error(s)). \
    No covered/not-covered number in this report is meaningful.

    """.data(using: .utf8)!)
    exit(4)
}
