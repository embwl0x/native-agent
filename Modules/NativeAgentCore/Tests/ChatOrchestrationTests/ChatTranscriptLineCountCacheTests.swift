import Foundation
import Testing
@testable import ChatOrchestration

/// Regression cover for the transcript line-count cache that took a full-file
/// byte scan off every persisted chat message.
///
/// The count these guard is the `messageCount` field of a `chat/sessions.json`
/// row, and it is NOT advisory. Three consumers, in ascending order of how
/// much a wrong number costs:
///
/// 1. Display surfaces — Mac session list, Telegram `/sessions`.
/// 2. `ChatSessionRetention`'s stale-empty rule, which archives a session only
///    when `messageCount <= 0` and it is older than 24h. An under-report can
///    get a live session archived.
/// 3. `SessionDigestProvider.swift:243`, which renders it straight into the
///    next session's PROMPT: `Previous session "X" (N messages) ended ...`.
///
/// So the cache is only admissible if it returns exactly what a full byte scan
/// would have returned, every time. That — not speed — is what these tests are
/// about: each one takes a way the file can change behind the cache's back and
/// asserts the stamp catches it and falls back to the scan.

// MARK: - Helpers

private func makeCacheTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("linecount-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Byte-for-byte the production counter's contract: count non-blank lines.
/// Redeclared here (the real one is private) so the tests measure the same
/// thing the cache is standing in for.
private func referenceLineCount(at path: URL) -> Int {
    guard let data = FileManager.default.contents(atPath: path.path),
          let text = String(data: data, encoding: .utf8) else { return 0 }
    return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .count
}

/// Appends one JSONL row exactly the way `PersistenceCore.appendJSONL` does:
/// one serialized line plus a trailing newline.
private func appendRow(_ index: Int, to path: URL) throws {
    let line = Data("{\"id\":\"row-\(index)\"}\n".utf8)
    if FileManager.default.fileExists(atPath: path.path) {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    } else {
        try line.write(to: path)
    }
}

/// The exact sequence `appendMessage` runs under the transcript lock.
@discardableResult
private func productionAppendSequence(
    _ cache: ChatTranscriptLineCountCache,
    index: Int,
    at path: URL
) throws -> Int {
    let prior = cache.count(at: path, recount: referenceLineCount(at:))
    try appendRow(index, to: path)
    return cache.record(count: prior + 1, at: path)
}

// MARK: - The fast path

@Test
func transcriptLineCountCache_appendsDoNotRescanTheFile() throws {
    let dir = try makeCacheTempDir("append-no-rescan")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()

    // Seed a transcript that already has history, so a rescan would be
    // visible and expensive — this is the shape the old code paid for on
    // every single message.
    for index in 0..<50 { try appendRow(index, to: path) }

    var counts: [Int] = []
    for index in 50..<70 {
        counts.append(try productionAppendSequence(cache, index: index, at: path))
    }

    // One full scan total: the cold read before the first append. Every
    // subsequent append carried the count forward.
    #expect(cache.fullRecountCount(at: path) == 1)
    #expect(counts == Array(51...70))
    // And the carried count is the truth, not a drifting accumulator.
    #expect(counts.last == referenceLineCount(at: path))
    #expect(counts.last == 70)
}

@Test
func transcriptLineCountCache_coldReadCountsAndThenServesFromCache() throws {
    let dir = try makeCacheTempDir("cold-then-warm")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<7 { try appendRow(index, to: path) }

    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 7)
    #expect(cache.fullRecountCount(at: path) == 1)
    // Repeated reads of an unchanged file never touch it again.
    for _ in 0..<5 {
        #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 7)
    }
    #expect(cache.fullRecountCount(at: path) == 1)
}

@Test
func transcriptLineCountCache_missingFileCountsZeroWithoutCaching() throws {
    let dir = try makeCacheTempDir("missing")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("never-written.jsonl")
    let cache = ChatTranscriptLineCountCache()

    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 0)
    // A file that does not exist has no stamp, so nothing is cached and the
    // first real append is still counted correctly.
    try appendRow(0, to: path)
    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 1)
}

// MARK: - Invalidation (the part that makes the fast path safe)

@Test
func transcriptLineCountCache_externalTruncationForcesRecount() throws {
    let dir = try makeCacheTempDir("truncation")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<12 { try appendRow(index, to: path) }
    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 12)
    let scansAfterWarm = cache.fullRecountCount(at: path)

    // Another process truncates the transcript (compaction, a repair tool, a
    // user clearing history). The cached 12 is now a lie.
    try Data("{\"id\":\"row-0\"}\n".utf8).write(to: path)

    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 1)
    #expect(cache.fullRecountCount(at: path) == scansAfterWarm + 1)
}

@Test
func transcriptLineCountCache_externalGrowthForcesRecount() throws {
    let dir = try makeCacheTempDir("growth")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<4 { try appendRow(index, to: path) }
    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 4)

    // A writer that does NOT go through this cache adds rows.
    for index in 4..<9 { try appendRow(index, to: path) }

    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 9)
}

@Test
func transcriptLineCountCache_replacedInodeForcesRecount() throws {
    let dir = try makeCacheTempDir("inode")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<6 { try appendRow(index, to: path) }
    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 6)

    // An atomic rewrite (`Data.write(options: .atomic)`, which is how
    // compaction lands) swaps in a brand new inode at the same path.
    var replacement = ""
    for index in 0..<3 { replacement += "{\"id\":\"row-\(index)\"}\n" }
    try Data(replacement.utf8).write(to: path, options: .atomic)

    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 3)
}

/// Mutation test for the detector itself. If the stamp were dropped from the
/// cache key — the single change that would make this optimization unsafe —
/// this scenario is what would go wrong, and this asserts the stamp catches it.
@Test
func transcriptLineCountCache_staleEntryIsDetectedNotServed() throws {
    let dir = try makeCacheTempDir("mutation")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<10 { try appendRow(index, to: path) }
    cache.record(count: 10, at: path)
    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 10)

    // Rewrite the file to a DIFFERENT row count behind the cache's back.
    // A cache that keyed only on path would still answer 10 here.
    var rewritten = ""
    for index in 0..<2 { rewritten += "{\"id\":\"kept-\(index)\"}\n" }
    try Data(rewritten.utf8).write(to: path)

    let truth = referenceLineCount(at: path)
    #expect(truth == 2)
    let served = cache.count(at: path, recount: referenceLineCount(at:))
    #expect(served == truth)
    #expect(served != 10, "a path-only cache would have served the stale 10 here")
}

@Test
func transcriptLineCountCache_invalidateDropsTheEntry() throws {
    let dir = try makeCacheTempDir("invalidate")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("session.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<5 { try appendRow(index, to: path) }
    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 5)
    let scans = cache.fullRecountCount(at: path)

    cache.invalidate(at: path)

    #expect(cache.count(at: path, recount: referenceLineCount(at:)) == 5)
    #expect(cache.fullRecountCount(at: path) == scans + 1)
}

@Test
func transcriptLineCountCache_entriesAreScopedPerTranscript() throws {
    let dir = try makeCacheTempDir("per-path")
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.jsonl")
    let b = dir.appendingPathComponent("b.jsonl")
    let cache = ChatTranscriptLineCountCache()
    for index in 0..<3 { try appendRow(index, to: a) }
    for index in 0..<8 { try appendRow(index, to: b) }

    #expect(cache.count(at: a, recount: referenceLineCount(at:)) == 3)
    #expect(cache.count(at: b, recount: referenceLineCount(at:)) == 8)
    try productionAppendSequence(cache, index: 99, at: a)
    #expect(cache.count(at: a, recount: referenceLineCount(at:)) == 4)
    #expect(cache.count(at: b, recount: referenceLineCount(at:)) == 8)
    #expect(cache.fullRecountCount(at: b) == 1)
}
