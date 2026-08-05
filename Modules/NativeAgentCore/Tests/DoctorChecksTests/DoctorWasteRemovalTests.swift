// A1/FIX-1 pinning tests — pure waste removal in the Doctor read path.
//
// The chat health pill polls every 15s and, because its 60s cache handshake was
// broken (its only producer ticks every SEVEN days), every poll ran a full
// 9-check doctor sweep including a whole-directory JSONL reparse. These pin the
// two Core-side halves of the fix:
//
//   b) ChatMessagesIntegrityCheck skips reparsing a file whose (mtime,size) is
//      unchanged — and still DETECTS a newly-malformed row once either moves.
//   c) SwiftNativeDoctorChecks.runAll runs its read-only checks concurrently
//      while emitting results in declaration order, and keeps repair strictly
//      sequential.
//
// The contract under test is "same verdict, less work", so every assertion here
// is a verdict assertion.

import Testing
import Foundation
@testable import DoctorChecks
import NativeAgentCore
import PersistenceCore

private func wasteTempRoot(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctor-waste-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func messagesDir(_ root: URL) -> URL {
    let dir = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func setModified(_ file: URL, to date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
}

private func modifiedDate(_ file: URL) throws -> Date {
    try #require(
        try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )
}

// MARK: - (b) the (mtime,size) scan memo

@Test("unchanged chat JSONL files yield the identical verdict on a second run")
func chatMessagesSkipCacheKeepsVerdictOnUnchangedFiles() async throws {
    let root = wasteTempRoot("skip-identical")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = messagesDir(root)
    try #"{"role":"user","content":"a"}"# .write(
        to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8
    )
    try "{\"role\":\"user\",\"content\":\"b\"}\n{\"role\":\"assistant\",\"content\":\"c\"}\n".write(
        to: dir.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8
    )

    let check = ChatMessagesIntegrityCheck(root: root)
    let first = await check.run(repair: false)
    let second = await check.run(repair: false)

    #expect(first.status == "ok")
    #expect(first.detail == "Chat message logs are valid (2 file(s), 3 row(s)).")
    // Byte-identical verdict, not merely "also ok" — the memo rebuilds the same
    // row counts the parse produced.
    #expect(second == first)
}

@Test("a file whose (mtime,size) is unchanged is not reparsed")
func chatMessagesSkipCacheActuallySkipsTheParse() async throws {
    let root = wasteTempRoot("skip-proof")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = messagesDir(root)
    let file = dir.appendingPathComponent("s1.jsonl")
    try #"{"role":"user","content":"aa"}"#.write(to: file, atomically: true, encoding: .utf8)
    // Pin the mtime to a whole second so it can be restored EXACTLY below —
    // a live mtime carries sub-second precision that setAttributes truncates.
    let stamp = Date(timeIntervalSince1970: 1_784_200_000)
    try setModified(file, to: stamp)

    let check = ChatMessagesIntegrityCheck(root: root)
    let first = await check.run(repair: false)
    #expect(first.status == "ok")

    // Swap the bytes for a same-LENGTH malformed row and restore the exact
    // mtime. Nothing the memo keys on moved, so a run that still reported "ok"
    // can only have skipped the parse. This is the direct proof of the work
    // skip; the invalidation half is the next test.
    let poison = #"{"role":"user","content":"aa"X"#   // same byte count, unparseable
    #expect(poison.utf8.count == #"{"role":"user","content":"aa"}"#.utf8.count)
    // IN-PLACE rewrite, not `atomically:` — an atomic write replaces the file
    // and mints a new inode, which the stat-strength stamp (device+inode+
    // size+mtime_ns, gpt-5.5 wave-1 hardening) correctly treats as a new
    // file. The metadata-preserving swap this test models must keep the
    // inode to hit the memo.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(poison.utf8))
    try handle.close()
    try setModified(file, to: stamp)
    #expect(try modifiedDate(file) == stamp)

    let second = await check.run(repair: false)
    #expect(second == first)
}

@Test("a newly-malformed row is DETECTED once mtime/size move (mutation)")
func chatMessagesSkipCacheDetectsNewlyMalformedRow() async throws {
    let root = wasteTempRoot("skip-mutation")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = messagesDir(root)
    let file = dir.appendingPathComponent("s1.jsonl")
    try "{\"role\":\"user\",\"content\":\"a\"}\n".write(to: file, atomically: true, encoding: .utf8)

    let check = ChatMessagesIntegrityCheck(root: root)
    #expect(await check.run(repair: false).status == "ok")

    // Real-world mutation: a writer appends a truncated row.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"role\":\"assistant\",\"conte\n".utf8))
    try handle.close()

    let after = await check.run(repair: false)
    #expect(after.status == "fail")
    #expect(after.detail == "1 malformed chat JSONL row(s) across 1 file(s).")

    // And a size-SHRINKING rewrite (truncation/compaction) is caught too — the
    // memo must not be fooled by "smaller than last time".
    try "{\"role\":\"user\",\"conte\n".write(to: file, atomically: true, encoding: .utf8)
    let shrunk = await check.run(repair: false)
    #expect(shrunk.status == "fail")
    #expect(shrunk.detail == "1 malformed chat JSONL row(s) across 1 file(s).")
}

@Test("repair bypasses the memo and still repairs a malformed file")
func chatMessagesRepairIgnoresTheScanCache() async throws {
    let root = wasteTempRoot("skip-repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = messagesDir(root)
    let file = dir.appendingPathComponent("s1.jsonl")
    try "{\"role\":\"user\",\"content\":\"a\"}\nnot json\n".write(
        to: file, atomically: true, encoding: .utf8
    )

    let check = ChatMessagesIntegrityCheck(root: root)
    // Prime the memo on the read-only path first.
    #expect(await check.run(repair: false).status == "fail")

    let repaired = await check.run(repair: true)
    #expect(repaired.status == "ok")
    #expect(repaired.repair?.contains("s1.jsonl") == true)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == "{\"role\":\"user\",\"content\":\"a\"}\n")

    // The post-repair read-only run must see the repaired file, not a memo
    // that predates the rewrite.
    let after = await check.run(repair: false)
    #expect(after.status == "ok")
    #expect(after.detail == "Chat message logs are valid (1 file(s), 1 row(s)).")
}

@Test("memos for deleted files are dropped")
func chatMessagesScanCacheDropsVanishedFiles() async throws {
    let root = wasteTempRoot("skip-retain")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = messagesDir(root)
    let keep = dir.appendingPathComponent("keep.jsonl")
    let drop = dir.appendingPathComponent("drop.jsonl")
    try "{\"a\":1}\n".write(to: keep, atomically: true, encoding: .utf8)
    try "{\"a\":2}\n".write(to: drop, atomically: true, encoding: .utf8)

    // The memo is process-wide, so this test owns its own cache instance
    // rather than asserting on a count other suites also write to.
    let cache = ChatMessagesScanCache()
    let check = ChatMessagesIntegrityCheck(root: root, scanCache: cache)
    _ = await check.run(repair: false)
    #expect(await cache.count() == 2)

    try FileManager.default.removeItem(at: drop)
    let after = await check.run(repair: false)
    #expect(after.detail == "Chat message logs are valid (1 file(s), 1 row(s)).")
    // Every insert has a matching remove: the vanished file's memo is gone.
    #expect(await cache.count() == 1)
}

// MARK: - (c) concurrent read-only runAll

private struct OrderProbeCheck: DoctorCheck {
    let id: String
    let title: String
    let delay: UInt64
    let observer: ConcurrencyObserver

    init(id: String, delay: UInt64, observer: ConcurrencyObserver) {
        self.id = id
        self.title = "probe-\(id)"
        self.delay = delay
        self.observer = observer
    }

    func run() async -> CheckResult {
        await observer.enter()
        try? await Task.sleep(nanoseconds: delay)
        await observer.leave()
        return CheckResult(id: id, title: title, status: "ok", detail: "ran")
    }
}

private actor ConcurrencyObserver {
    private var live = 0
    private(set) var peak = 0
    func enter() { live += 1; peak = max(peak, live) }
    func leave() { live -= 1 }
}

@Test("read-only runAll runs checks concurrently but emits declaration order")
func runAllReadOnlyIsConcurrentAndOrderStable() async throws {
    let observer = ConcurrencyObserver()
    let checks: [any DoctorCheck] = (0..<6).map {
        OrderProbeCheck(id: "c\($0)", delay: 60_000_000, observer: observer)
    }
    let runner = SwiftNativeDoctorChecks(checks: checks)

    let results = try await runner.runAll(repair: false, checkLLM: false)

    #expect(results.map(\.id) == ["c0", "c1", "c2", "c3", "c4", "c5"])
    // Overlap, not wall-clock: every check records how many peers were inside
    // run() with it. Sequential execution can never observe a peak above 1,
    // and unlike an elapsed-time bound this does not flake under a loaded
    // machine running the whole suite in parallel.
    #expect(await observer.peak == 6)
}

private struct SequentialRepairProbe: RepairingDoctorCheck {
    let id: String
    let title: String
    let order: OrderRecorder
    let delay: UInt64

    init(id: String, delay: UInt64, order: OrderRecorder) {
        self.id = id
        self.title = "repair-\(id)"
        self.delay = delay
        self.order = order
    }

    func run(repair: Bool) async -> CheckResult {
        try? await Task.sleep(nanoseconds: delay)
        await order.append(id)
        return CheckResult(id: id, title: title, status: "ok", detail: repair ? "repaired" : "read-only")
    }
}

private actor OrderRecorder {
    private(set) var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
}

@Test("repair mode stays strictly sequential")
func runAllRepairStaysSequential() async throws {
    let order = OrderRecorder()
    // Descending delays: under any concurrency the completion order would
    // invert. Sequential execution is the only way to observe a0, a1, a2.
    let checks: [any DoctorCheck] = [
        SequentialRepairProbe(id: "a0", delay: 90_000_000, order: order),
        SequentialRepairProbe(id: "a1", delay: 40_000_000, order: order),
        SequentialRepairProbe(id: "a2", delay: 5_000_000, order: order),
    ]
    let results = try await SwiftNativeDoctorChecks(checks: checks).runAll(repair: true, checkLLM: false)
    #expect(results.map(\.id) == ["a0", "a1", "a2"])
    #expect(await order.ids == ["a0", "a1", "a2"])
    #expect(results.allSatisfy { $0.detail == "repaired" })
}

@Test("the real doctor checks still emit in declaration order under concurrency")
func runAllRealCheckSubsetOrderIsUnchanged() async throws {
    let root = wasteTempRoot("real-order")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = SwiftNativeDoctorChecks(checks: [
        StorageCheck(root: root),
        RuntimeJSONStoresCheck(root: root),
        ChatSessionsCheck(root: root),
        ChatMessagesIntegrityCheck(root: root),
        MemoryStoreCheck(root: root),
    ])
    let results = try await runner.runAll(repair: false, checkLLM: false)
    #expect(results.map(\.id) == [
        "storage", "runtime_json_stores", "chat_sessions", "chat_messages", "memory_store",
    ])
}
