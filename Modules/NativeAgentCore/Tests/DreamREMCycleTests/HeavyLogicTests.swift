import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rem-heavy-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func entry(_ date: String, _ content: String) -> DreamEntry {
    DreamEntry(date: date, filename: "\(date).md", content: content, size: content.utf8.count, modifiedAt: nil)
}

// MARK: - Clustering

@Test func clusterDreamEntries_groups_similar_topics() {
    let entries = [
        entry("2026-05-01", "Working on the dream cycle and REM consolidation logic for Agent persona docs"),
        entry("2026-05-02", "Continued REM consolidation logic for the Agent persona dream cycle work"),
        entry("2026-05-03", "Completely different subject — Robinhood equity quotes pricing API."),
    ]
    let clusters = clusterDreamEntries(entries)
    #expect(clusters.count == 2)
    let big = clusters.max(by: { $0.entries.count < $1.entries.count })!
    #expect(big.entries.count == 2)
}

@Test func clusterDreamEntries_singleton_when_no_similar() {
    let entries = [
        entry("2026-05-01", "Apple oranges bananas peaches grapes"),
        entry("2026-05-02", "Quantum mechanics relativity general physics"),
        entry("2026-05-03", "Birds flying south autumn migration patterns"),
    ]
    let clusters = clusterDreamEntries(entries)
    #expect(clusters.count == 3)
    #expect(clusters.allSatisfy { $0.entries.count == 1 })
}

@Test func clusterDreamEntries_jaccard_threshold_observed() {
    // Two entries sharing >=50% word jaccard cluster; below threshold split.
    let a = entry("2026-05-01", "alpha beta gamma delta")
    let b = entry("2026-05-02", "alpha beta gamma epsilon") // 3/5 = 0.6
    let c = entry("2026-05-03", "omega psi chi phi")        // 0
    let clusters = clusterDreamEntries([a, b, c])
    #expect(clusters.count == 2)
}

// MARK: - REMTombstoneStore

private func mkProposal(_ doc: String, _ text: String) -> REMProposal {
    REMProposal(id: UUID().uuidString, targetDoc: doc, proposalText: text, evidenceDates: [], confidence: 0.5, createdAt: "2026-05-31T00:00:00Z")
}

@Test func REMTombstoneStore_record_then_isTombstoned_returns_true() async throws {
    let root = tempDir()
    let store = REMTombstoneStore(dataRoot: root)
    let p = mkProposal("SOUL.md", "I value clarity over cleverness.")
    try await store.record(p, reason: "denied by user")
    #expect(try await store.isTombstoned(p) == true)
}

@Test func REMTombstoneStore_record_normalized_text_matches_variants() async throws {
    let root = tempDir()
    let store = REMTombstoneStore(dataRoot: root)
    let original = mkProposal("VOICE.md", "Speak  PLAINLY,   no fluff.")
    try await store.record(original, reason: "denied")
    let variant = mkProposal("VOICE.md", "speak plainly, no fluff.")
    #expect(try await store.isTombstoned(variant) == true)
    // BUG-A FIX (daemon-parity): daemon's _tombstone_fp keys ONLY on the
    // normalized text, not (text, target_doc). A tombstoned pattern is
    // denylisted globally — the user explicitly rejected this wording, so it
    // shouldn't come back under a different persona doc either. Mirrors
    // the retired daemon (`fp = _tombstone_fp(p.proposed_text)`).
    let differentDoc = mkProposal("SOUL.md", "speak plainly, no fluff.")
    #expect(try await store.isTombstoned(differentDoc) == true)
}

@Test func REMTombstoneStore_persists_across_actor_instances() async throws {
    let root = tempDir()
    let p = mkProposal("GROWTH.md", "Lesson learned about caching")
    do {
        let s1 = REMTombstoneStore(dataRoot: root)
        try await s1.record(p, reason: "x")
    }
    let s2 = REMTombstoneStore(dataRoot: root)
    #expect(try await s2.isTombstoned(p) == true)
}

// MARK: - BUG-C regression: tombstone path daemon-parity
//
// BUG-C: Swift wrote tombstones to <dataRoot>/dream_diary/.rem_tombstones
// (no .json suffix); daemon writes to <dataRoot>/harness/.rem_tombstones.json
//. Two REM cycles never saw each other's
// tombstones — every proposal the user rejected in one would keep coming back
// from the other.
//
// This test pins the fixed path so any future "minor" refactor that
// changes the directory or strips the .json suffix breaks loudly here
// instead of silently in production.
@Test func remTombstoneStore_uses_harness_path_not_dream_diary() async throws {
    let root = tempDir()
    let store = REMTombstoneStore(dataRoot: root)
    let path = await store.tombstonesPath()
    let expected = root
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent(".rem_tombstones.json")
    #expect(path.standardizedFileURL.path == expected.standardizedFileURL.path,
            "tombstone path diverged from daemon: got \(path.path), expected \(expected.path)")
    // Belt-and-suspenders: also assert the legacy buggy path is NOT used.
    let buggy = root
        .appendingPathComponent("dream_diary", isDirectory: true)
        .appendingPathComponent(".rem_tombstones")
    #expect(path.standardizedFileURL.path != buggy.standardizedFileURL.path,
            "tombstone path regressed to pre-fix dream_diary/.rem_tombstones")
}

@Test func remTombstoneStore_record_writes_to_harness_path_on_disk() async throws {
    // End-to-end: record a proposal, then assert the on-disk file lives at
    // harness/.rem_tombstones.json (daemon-readable location).
    let root = tempDir()
    let store = REMTombstoneStore(dataRoot: root)
    let p = mkProposal("SOUL.md", "regression guard for bug C tombstone path")
    try await store.record(p, reason: "test")
    let expected = root
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent(".rem_tombstones.json")
    #expect(FileManager.default.fileExists(atPath: expected.path),
            "tombstone file not written to expected daemon-parity path \(expected.path)")
}

// MARK: - BUG-A regression: tombstone FORMAT daemon-parity
//
// BUG-A: even after the path was fixed, Swift wrote JSONL (one record per
// line) while daemon writes a SINGLE JSON dict keyed by `_tombstone_fp(...)`.
// Neither side could read the other's data. These tests pin the format so
// any future refactor that re-introduces JSONL breaks loudly here instead
// of silently in production.

@Test func tombstone_format_matches_daemon_dict_keyed_by_fingerprint() async throws {
    let root = tempDir()
    let store = REMTombstoneStore(dataRoot: root)
    let text = "Pattern the user rejected — clarity over cleverness"
    let p = mkProposal("SOUL.md", text)
    try await store.record(p, reason: "user_rejected")
    let expected = root
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent(".rem_tombstones.json")
    let data = try Data(contentsOf: expected)
    // Must parse as JSON dict (daemon shape), NOT JSONL.
    let any = try JSONSerialization.jsonObject(with: data)
    let dict = try #require(any as? [String: Any])
    // Top-level key must be the fingerprint, not a uuid or proposal id.
    let fp = _tombstone_fp(text)
    #expect(dict.keys.contains(fp),
            "tombstone dict not keyed by daemon fingerprint; got keys \(Array(dict.keys))")
    // Value shape mirrors daemon: rejected_at / target_doc / reason / preview.
    let value = try #require(dict[fp] as? [String: Any])
    #expect(value["target_doc"] as? String == "SOUL.md")
    #expect(value["reason"] as? String == "user_rejected")
    #expect((value["preview"] as? String) != nil)
    #expect((value["rejected_at"] as? String) != nil)
}

@Test func tombstone_fingerprint_matches_native_contract() async throws {
    let fixtures: [(text: String, expected: String)] = [
        ("I value clarity over cleverness.", "fe6ae456bfb99dd8"),
        ("Speak  PLAINLY,   no fluff.", "a6f5f8038ee05208"),
        ("Lesson learned about caching — keep TTLs honest.", "2e7fcfb08736242b"),
        ("  Whitespace    everywhere\nand newlines\ttoo  ", "87704e4f1acc3745"),
        ("", "e3b0c44298fc1c14"),
    ]
    for fixture in fixtures {
        let swiftFP = _tombstone_fp(fixture.text)
        #expect(swiftFP == fixture.expected,
                "fingerprint mismatch for text=\(fixture.text.debugDescription): swift=\(swiftFP) expected=\(fixture.expected)")
    }
}

@Test func tombstone_legacy_jsonl_migrated_on_next_write() async throws {
    // Pre-seed the file with legacy JSONL records (the pre-fix Swift shape).
    // Then call record() with a new proposal — assert load() now sees both
    // the migrated legacy entries AND the new entry, all in dict shape.
    let root = tempDir()
    let dir = root.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(".rem_tombstones.json")
    let legacyA = #"{"targetDoc":"SOUL.md","normText":"legacy alpha pattern","reason":"old","recordedAt":"2026-05-01T00:00:00Z"}"#
    let legacyB = #"{"targetDoc":"VOICE.md","normText":"legacy beta pattern","reason":"old","recordedAt":"2026-05-02T00:00:00Z"}"#
    let body = legacyA + "\n" + legacyB + "\n"
    try body.data(using: .utf8)!.write(to: path)

    let store = REMTombstoneStore(dataRoot: root)
    let newP = mkProposal("GROWTH.md", "new pattern after migration")
    try await store.record(newP, reason: "fresh")

    let after = try await store.loadAll()
    let fpA = _tombstone_fp("legacy alpha pattern")
    let fpB = _tombstone_fp("legacy beta pattern")
    let fpNew = _tombstone_fp("new pattern after migration")
    #expect(after[fpA] != nil, "legacy entry A lost during migration; have keys \(Array(after.keys))")
    #expect(after[fpB] != nil, "legacy entry B lost during migration; have keys \(Array(after.keys))")
    #expect(after[fpNew] != nil, "new entry missing post-record; have keys \(Array(after.keys))")
    // On-disk: must now be a JSON dict, not JSONL.
    let data = try Data(contentsOf: path)
    let any = try JSONSerialization.jsonObject(with: data)
    #expect(any is [String: Any], "post-migration file still not in daemon dict shape")
}

@Test func REMTombstoneStore_malformed_state_fails_closed_without_overwrite() async throws {
    let root = tempDir()
    let directory = root.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".rem_tombstones.json")
    let original = Data("{\"partial\":".utf8)
    try original.write(to: path)

    let store = REMTombstoneStore(dataRoot: root)
    let proposal = mkProposal("GROWTH.md", "do not overwrite malformed tombstones")
    do {
        _ = try await store.isTombstoned(proposal)
        Issue.record("expected malformed tombstone state to throw")
    } catch let error as REMTombstoneStoreError {
        if case .malformed(let errorPath) = error {
            #expect(errorPath == path.path)
        } else {
            Issue.record("expected malformed tombstone error, got \(error)")
        }
    } catch {
        Issue.record("expected typed malformed tombstone error, got \(error)")
    }

    do {
        try await store.record(proposal, reason: "test")
        Issue.record("expected malformed tombstone state to block record")
    } catch let error as REMTombstoneStoreError {
        if case .malformed = error {
            // Expected: record must preserve the existing bytes.
        } else {
            Issue.record("expected malformed tombstone error, got \(error)")
        }
    } catch {
        Issue.record("expected typed malformed tombstone error, got \(error)")
    }

    #expect(try Data(contentsOf: path) == original)
}

@Test func REMTombstoneStore_unreadable_state_fails_closed_without_overwrite() async throws {
    let root = tempDir()
    let directory = root.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".rem_tombstones.json")
    let original = Data("{\"existing\":{\"rejected_at\":\"2026-05-01T00:00:00Z\",\"target_doc\":\"GROWTH.md\",\"reason\":\"denied\",\"preview\":\"keep\"}}".utf8)
    try original.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    let store = REMTombstoneStore(dataRoot: root)
    let proposal = mkProposal("GROWTH.md", "do not overwrite unreadable tombstones")
    do {
        try await store.record(proposal, reason: "test")
        Issue.record("expected unreadable tombstone state to block record")
    } catch let error as REMTombstoneStoreError {
        if case .unreadable(let errorPath) = error {
            #expect(errorPath == path.path)
        } else {
            Issue.record("expected unreadable tombstone error, got \(error)")
        }
    } catch {
        Issue.record("expected typed unreadable tombstone error, got \(error)")
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    #expect(try Data(contentsOf: path) == original)
}

// MARK: - GrowthDocManager

@Test func GrowthDocManager_growthSize_returns_0_for_missing() async {
    let root = tempDir()
    let m = GrowthDocManager(personaRoot: root)
    #expect(await m.growthSize() == 0)
}

@Test func GrowthDocManager_evictionCandidates_picks_oldest_entries() async throws {
    let root = tempDir()
    let path = root.appendingPathComponent("GROWTH.md")
    let body = """
    2026-01-01 first lesson body that is reasonably long to consume bytes
    2026-02-01 second lesson body also reasonably long to consume bytes
    2026-03-01 third lesson body also reasonably long to consume bytes
    """
    try body.data(using: .utf8)!.write(to: path)
    let m = GrowthDocManager(personaRoot: root)
    let total = body.utf8.count
    let evicted = try await m.evictionCandidates(maxBytes: total - 30)
    #expect(evicted.contains("2026-01-01"))
    #expect(!evicted.contains("2026-03-01"))
}

@Test func GrowthDocManager_appendEntry_appends_with_date_prefix() async throws {
    let root = tempDir()
    let m = GrowthDocManager(personaRoot: root)
    try await m.appendEntry("first thing", date: "2026-05-01")
    try await m.appendEntry("second thing", date: "2026-05-02")
    let body = try String(contentsOf: root.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(body.contains("2026-05-01 first thing"))
    #expect(body.contains("2026-05-02 second thing"))
}

@Test func GrowthDocManager_deleteSlice_removes_exact_match() async throws {
    let root = tempDir()
    let path = root.appendingPathComponent("GROWTH.md")
    let body = "2026-01-01 alpha\n2026-02-01 beta\n2026-03-01 gamma\n"
    try body.data(using: .utf8)!.write(to: path)
    let m = GrowthDocManager(personaRoot: root)
    try await m.deleteSlice("2026-02-01 beta\n")
    let after = try String(contentsOf: path, encoding: .utf8)
    #expect(after == "2026-01-01 alpha\n2026-03-01 gamma\n")
}

@Test func GrowthDocManager_evictionCandidates_returns_empty_when_under_cap() async throws {
    let root = tempDir()
    let path = root.appendingPathComponent("GROWTH.md")
    let body = "2026-01-01 tiny\n"
    try body.data(using: .utf8)!.write(to: path)
    let m = GrowthDocManager(personaRoot: root)
    let evicted = try await m.evictionCandidates(maxBytes: 10_000)
    #expect(evicted.isEmpty)
}

// MARK: - DreamArchiver

private func writeDream(_ root: URL, _ date: String, age: TimeInterval) throws {
    let dir = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(date).md")
    try "dream body".data(using: .utf8)!.write(to: url)
    _ = age // dates resolved from filename by archiver
}

@Test func DreamArchiver_archives_files_older_than_14_days() async throws {
    let root = tempDir()
    // Now = 2026-05-31. Old date 2026-05-01 is 30 days old → archive.
    try writeDream(root, "2026-05-01", age: 0)
    let now = ISO8601DateFormatter().date(from: "2026-05-31T12:00:00Z")!
    let arch = DreamArchiver(dataRoot: root)
    let moved = try await arch.archiveOlderThan(daysOld: 14, now: now)
    #expect(moved == 1)
    let archived = root.appendingPathComponent("dream_diary/archive/2026/2026-05-01.md")
    #expect(FileManager.default.fileExists(atPath: archived.path))
    let original = root.appendingPathComponent("dream_diary/2026-05-01.md")
    #expect(!FileManager.default.fileExists(atPath: original.path))
}

@Test func DreamArchiver_preserves_files_within_window() async throws {
    let root = tempDir()
    try writeDream(root, "2026-05-30", age: 0) // 1 day before now
    let now = ISO8601DateFormatter().date(from: "2026-05-31T12:00:00Z")!
    let arch = DreamArchiver(dataRoot: root)
    let moved = try await arch.archiveOlderThan(daysOld: 14, now: now)
    #expect(moved == 0)
    let original = root.appendingPathComponent("dream_diary/2026-05-30.md")
    #expect(FileManager.default.fileExists(atPath: original.path))
}

@Test func DreamArchiver_archives_swift_format_session_entries() async throws {
    let root = tempDir()
    // Older Swift runners wrote `YYYY-MM-DD_<session>.md`; the archiver must
    // date-parse the prefix instead of requiring the bare daily stem
    // (regression: the old `^YYYY-MM-DD$` regex made archival a no-op for
    // every Swift-written entry).
    try writeDream(root, "2026-05-01_session-abc", age: 0)
    let now = ISO8601DateFormatter().date(from: "2026-05-31T12:00:00Z")!
    let arch = DreamArchiver(dataRoot: root)
    let moved = try await arch.archiveOlderThan(daysOld: 14, now: now)
    #expect(moved == 1)
    let archived = root.appendingPathComponent("dream_diary/archive/2026/2026-05-01_session-abc.md")
    #expect(FileManager.default.fileExists(atPath: archived.path))
    let original = root.appendingPathComponent("dream_diary/2026-05-01_session-abc.md")
    #expect(!FileManager.default.fileExists(atPath: original.path))
}

@Test func DreamArchiver_preserves_swift_format_entries_within_window() async throws {
    let root = tempDir()
    try writeDream(root, "2026-05-30_session-abc", age: 0) // 1 day before now
    let now = ISO8601DateFormatter().date(from: "2026-05-31T12:00:00Z")!
    let arch = DreamArchiver(dataRoot: root)
    let moved = try await arch.archiveOlderThan(daysOld: 14, now: now)
    #expect(moved == 0)
    let original = root.appendingPathComponent("dream_diary/2026-05-30_session-abc.md")
    #expect(FileManager.default.fileExists(atPath: original.path))
}

@Test func DreamArchiver_creates_year_subdirs() async throws {
    let root = tempDir()
    try writeDream(root, "2024-01-15", age: 0)
    try writeDream(root, "2025-06-20", age: 0)
    let now = ISO8601DateFormatter().date(from: "2026-05-31T12:00:00Z")!
    let arch = DreamArchiver(dataRoot: root)
    let moved = try await arch.archiveOlderThan(daysOld: 14, now: now)
    #expect(moved == 2)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("dream_diary/archive/2024/2024-01-15.md").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("dream_diary/archive/2025/2025-06-20.md").path))
}
