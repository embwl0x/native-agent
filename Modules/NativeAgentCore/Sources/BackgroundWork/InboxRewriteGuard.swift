import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore

// MARK: - Inbox whole-file rewrite guard
//
// The notification inbox upserts read the whole file and rewrite it in place.
// The old read (`tailJSONL`) was LOSSY: it decoded non-UTF8 bytes with
// replacement and `compactMap`ed away every line it could not parse, so a
// single malformed row among valid rows was silently dropped on rewrite, and a
// fully torn inbox came back as `[]` — rewriting from that wiped every pending
// card the user had not seen yet.
//
// The honest shape: `readLines` returns every PHYSICAL line with its original
// bytes, decoded when possible. Rewrite sites mutate only the rows they own
// and pass every other line — decoded or not — through `writeLines` verbatim,
// so corruption is preserved rather than amplified. A trailing torn line
// (crash residue; the flock serializes live appenders) keeps its bytes and
// gains only a terminating newline.
public enum InboxRewriteGuard {
    /// One physical line of the inbox file. `row` is nil when the line does
    /// not parse as JSON; such lines must be carried through rewrites as
    /// `raw`, byte-identical.
    public struct Line {
        public let raw: Data
        public let row: JSONValue?
    }

    /// Whole-file read that loses nothing: every physical line comes back,
    /// with its decoded row when it parses. Interior blank lines are kept
    /// (as empty `raw`) so the rewrite preserves them too.
    public static func readLines(_ path: URL) throws -> [Line] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        let slices: [Data] = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // Copy each slice: Data slices keep parent byte offsets, and parsers
        // must see zero-based bytes.
        var parts = slices.map { Data($0) }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { Line(raw: $0, row: try? JSONValue.parse($0)) }
    }

    /// Atomic whole-file replacement from physical lines. An empty array
    /// truncates the file (matches the old serializer's behavior).
    public static func writeLines(_ lines: [Data], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = Data()
        payload.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })
        for line in lines {
            payload.append(line)
            payload.append(0x0A)
        }
        try payload.write(to: path, options: [.atomic])
        _ = chmod(path.path, 0o600)
    }

    /// True when it is safe to rewrite `path` from `lines`. With `readLines`
    /// a non-empty file always yields at least one line, so a refusal here
    /// means the read and the file disagree — refuse rather than risk wiping
    /// cards. Zero lines is only legitimate when the file genuinely holds
    /// nothing on disk, which must still allow the very first card.
    public static func rewriteIsSafe(lines: [Line], path: URL) -> Bool {
        if !lines.isEmpty { return true }
        guard FileManager.default.fileExists(atPath: path.path) else { return true }
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: path.path
        )[.size]) as? NSNumber else {
            // Present but unstattable: assume it holds cards and refuse.
            return false
        }
        return size.intValue == 0
    }

    /// Logs the refusal on the way out so a skipped upsert is never silent.
    public static func refuse(_ label: String, path: URL) {
        FileHandle.standardError.write(Data(
            ("\(label): inbox read returned no lines for a non-empty file at "
             + "\(path.path) — skipping whole-file rewrite to avoid wiping "
             + "pending cards\n").utf8))
    }
}
