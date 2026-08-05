import Foundation
import Testing
@testable import PersistenceCore

// Perf wave 2, F5. One desk event fans out into ~5 `liveState()` calls —
// desk_notify's `nextMeaningfulDeadline` + `tickOutcome`, workshop_pump's
// `nextMeaningfulDeadline`, and the pump's own read — each re-decoding the
// whole op-log (352KB live) plus the compaction base (179KB) and re-running the
// reducer to produce identical bytes.
//
// These tests pin the three things that make the memo a WORK skip and never a
// TRUTH skip: repeats hit, any change to either file misses (the mutation
// tests), and the state served is byte-equal to an unmemoized replay.
@Suite("DeskStore liveState memo")
struct DeskLiveStateMemoTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskLiveStateMemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // Each test owns a UNIQUE temp root AND its own memo instance. The
    // production memo is process-wide with a bounded entry count, so a test
    // that asserted on it would be racing every other desk suite in the same
    // process for those entries — the residency it depends on could be evicted
    // mid-test by a sibling. Injection makes these assertions deterministic
    // without weakening what they assert.
    private func freshStore(
        _ root: URL,
        memo: DeskLiveStateMemo,
        compactionThreshold: Int = 2_048
    ) -> SwiftNativeDeskStore {
        SwiftNativeDeskStore(
            dataRoot: root,
            opsCompactionThreshold: compactionThreshold,
            liveStateMemo: memo
        )
    }

    private func stats(_ memo: DeskLiveStateMemo, _ store: SwiftNativeDeskStore) async -> (hits: Int, misses: Int, entries: Int) {
        await memo._testStats(key: SwiftNativeDeskStore.memoKey(store.opsPath))
    }

    @Test func repeatedReadsOnAnUnchangedFeedReplayExactlyOnce() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = DeskLiveStateMemo()
        let store = freshStore(root, memo: memo)
        _ = try await store.createItem(kind: .plan, project: "p", title: "one")

        let before = await stats(memo, store)
        let first = try await store.liveState()
        for _ in 0..<4 { _ = try await store.liveState() }

        let after = await stats(memo, store)
        // This is the F5 shape exactly: one desk event, five liveState() calls,
        // ONE replay. (createItem commits through readFeedUnlocked, not
        // liveState, so the first read here is the cold one.)
        #expect(after.misses - before.misses == 1, "only the first of five reads may replay the feed")
        #expect(after.hits - before.hits == 4)
        #expect(first.items.count == 1)
    }

    @Test func servedStateIsIdenticalToAnUnmemoizedReplay() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = DeskLiveStateMemo()
        let store = freshStore(root, memo: memo)
        let a = try await store.createItem(kind: .plan, project: "p", title: "alpha")
        _ = try await store.createItem(kind: .plan, project: "p", title: "beta", parent: a.handle)
        _ = try await store.appendNote(a.handle, text: "a note")

        let cold = try await store.liveState()
        let warm = try await store.liveState()
        await memo.forget(key: SwiftNativeDeskStore.memoKey(store.opsPath))
        let recold = try await store.liveState()

        #expect(warm.toJSON() == cold.toJSON(), "a memo hit must serve the replay's exact bytes")
        #expect(recold.toJSON() == cold.toJSON())
    }

    // MUTATION TEST 1 — an in-process write must invalidate.
    @Test func aWriteThroughTheStoreInvalidatesTheMemo() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = DeskLiveStateMemo()
        let store = freshStore(root, memo: memo)
        _ = try await store.createItem(kind: .plan, project: "p", title: "one")
        _ = try await store.liveState()

        _ = try await store.createItem(kind: .plan, project: "p", title: "two")
        let after = try await store.liveState()

        #expect(after.items.count == 2, "a committed append must be visible to the next read")
    }

    // MUTATION TEST 2 — an OUT-OF-PROCESS append (the shape DeskSweepCLI and a
    // second app instance produce) must invalidate. This is the test that fails
    // if the memo ever keys on anything weaker than the file's own identity.
    @Test func anExternalAppendInvalidatesTheMemo() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = DeskLiveStateMemo()
        let store = freshStore(root, memo: memo)
        let seed = try await store.createItem(kind: .plan, project: "p", title: "one")
        let before = try await store.liveState()
        #expect(before.items.count == 1)

        // Append a create op by hand — no store API, no change bus, no flock
        // release the memo could have keyed on.
        let foreign = DeskOp(
            ts: DeskClock.commitStamp(notBefore: seed.updatedAt),
            handle: DeskClock.newHandle(),
            body: .createItem(
                alias: "99", kind: .plan, project: "p", title: "smuggled",
                parent: nil, summary: nil, origin: .owner, pursuit: nil
            )
        )
        let line = try foreign.toJSON().serialize(pretty: false) + "\n"
        let handle = try FileHandle(forWritingTo: store.opsPath)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()

        let after = try await store.liveState()
        #expect(
            after.items.contains { $0.title == "smuggled" },
            "an external append must invalidate the memo — a stale desk is a wrong desk"
        )
    }

    // MUTATION TEST 3 — COMPACTION. The base is rewritten and the ops file is
    // truncated to empty in one transaction. A memo keyed only on the ops file's
    // SIZE could see a post-truncate feed re-grow back to a byte count it has
    // seen before; a memo keyed only on the base would miss the truncate.
    @Test func compactionInvalidatesTheMemo() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Threshold 4: a handful of ops trips a real snapshot + truncate.
        let memo = DeskLiveStateMemo()
        let store = freshStore(root, memo: memo, compactionThreshold: 4)

        let first = try await store.createItem(kind: .plan, project: "p", title: "one")
        let beforeCompaction = try await store.liveState()
        #expect(beforeCompaction.items.count == 1)

        _ = try await store.createItem(kind: .plan, project: "p", title: "two")
        _ = try await store.createItem(kind: .plan, project: "p", title: "three")
        _ = try await store.appendNote(first.handle, text: "trip the threshold")
        _ = try await store.appendNote(first.handle, text: "and again")

        #expect(
            FileManager.default.fileExists(atPath: store.basePath.path),
            "test premise: the threshold must actually have produced a compaction base"
        )
        let after = try await store.liveState()
        #expect(after.items.count == 3, "post-compaction reads must see base + tail, not a stale memo")
        #expect(after.items.contains { $0.title == "three" })
    }

    // The memo is process-wide, so a second data root must never be served
    // another root's state.
    @Test func distinctDataRootsDoNotShareEntries() async throws {
        let rootA = try tempRoot()
        let rootB = try tempRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let memo = DeskLiveStateMemo()
        let storeA = freshStore(rootA, memo: memo)
        let storeB = freshStore(rootB, memo: memo)
        _ = try await storeA.createItem(kind: .plan, project: "a", title: "in A")

        let a = try await storeA.liveState()
        let b = try await storeB.liveState()
        #expect(a.items.count == 1)
        #expect(b.items.isEmpty, "root B has its own (empty) desk")
    }

    // Every insert has a matching eviction: walking many roots must not grow
    // the map without bound.
    @Test func entryCountStaysBounded() async throws {
        let memo = DeskLiveStateMemo()
        var roots: [URL] = []
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        for index in 0..<(DeskLiveStateMemo.maxEntries + 5) {
            let root = try tempRoot()
            roots.append(root)
            let store = freshStore(root, memo: memo)
            _ = try await store.createItem(kind: .plan, project: "p", title: "item \(index)")
            _ = try await store.liveState()
        }
        let bounded = await memo._testStats(key: "")
        #expect(bounded.entries <= DeskLiveStateMemo.maxEntries)
    }
}
