import Testing
import Foundation
@testable import PersistenceCore

// C6 (upgrade-sweep-2026-08): self-write suppression for physiology watchers,
// keyed on a WRITER GENERATION — explicitly not a time window. Every test here
// runs with no waiting at all, which is itself the point: a correct
// implementation cannot depend on how long ago the tick happened.
@Suite(.serialized)
struct PhysiologySelfWriteRegistryTests {

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selfwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func anUnregisteredLoopIsNeverSuppressed() {
        let registry = PhysiologySelfWriteRegistry()
        #expect(registry.isSelfWriteEcho(loopId: "nobody") == false)
    }

    @Test
    func aRegisteredLoopThatHasNotTickedIsNeverSuppressed() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    @Test
    func anUnchangedFileAfterATickIsSuppressedAsTheLoopsOwnEcho() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("{\"v\":1}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        // The tick ran and wrote; the stamp is taken at its end.
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))
        // ...and it stays suppressed no matter how many events arrive. No time
        // window means no expiry.
        #expect(registry.isSelfWriteEcho(loopId: "l"))
        #expect(registry.isSelfWriteEcho(loopId: "l"))
    }

    @Test
    func aForeignWriteAfterTheStampIsDelivered() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("{\"v\":1}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))

        try Data("{\"v\":2,\"more\":true}".utf8).write(to: file)
        #expect(
            registry.isSelfWriteEcho(loopId: "l") == false,
            "a foreign write must be delivered — this is the failure a time window would cause"
        )
    }

    /// The whole reason a generation beats a window: an FSEvent can arrive
    /// arbitrarily late. Suppression must still hold, and a foreign write must
    /// still get through, with no notion of elapsed time anywhere.
    @Test
    func suppressionIsNotTimeBounded() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("a".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")

        // Backdate the file far into the past. A window keyed on "was the tick
        // recent" would now let the echo through; a generation does not care.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path
        )
        // The generation CHANGED (mtime is part of it), so this reads as a
        // foreign write — which is correct: something other than the loop
        // touched the file.
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)

        // Re-stamp against the new state and it is quiet again, still with no
        // clock involved.
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))
    }

    @Test
    func everyWatchedPathMustBeUnchangedForSuppression() throws {
        let dir = try makeDir()
        let a = dir.appendingPathComponent("a.json")
        let b = dir.appendingPathComponent("b.json")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [a, b])
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))

        try Data("bbbb".utf8).write(to: b)
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    @Test
    func creatingAWatchedPathThatDidNotExistIsDelivered() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("appears-later.json")
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))

        try Data("{}".utf8).write(to: file)
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    @Test
    func deletingAWatchedPathIsDelivered() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("goes-away.json")
        try Data("{}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        try FileManager.default.removeItem(at: file)
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    /// A rebuilt listener must not inherit the retired one's suppression: the
    /// window in which nothing was listening is a window in which anything
    /// could have changed.
    @Test
    func reRegisteringDropsThePreviousStamp() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))

        registry.register(loopId: "l", paths: [file])
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    @Test
    func clearForgetsTheLoopEntirely() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        registry.clear(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
        // And a stamp on a cleared loop does not resurrect suppression.
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    @Test
    func loopsDoNotShareSuppressionState() throws {
        let dir = try makeDir()
        let a = dir.appendingPathComponent("a.json")
        let b = dir.appendingPathComponent("b.json")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "one", paths: [a])
        registry.register(loopId: "two", paths: [b])
        registry.stampAfterTick(loopId: "one")
        #expect(registry.isSelfWriteEcho(loopId: "one"))
        #expect(registry.isSelfWriteEcho(loopId: "two") == false)
    }

    /// A watched DIRECTORY can never suppress. A directory's own generation
    /// moves only when an ENTRY is added or removed — rewriting a file INSIDE it
    /// leaves the directory itself byte-identical, so suppressing on it would
    /// silently swallow a real foreign write (workshop/executions is watched
    /// exactly this way).
    @Test
    func aWatchedDirectoryIsNeverSuppressed() throws {
        let dir = try makeDir()
        let watched = dir.appendingPathComponent("executions", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let inner = watched.appendingPathComponent("run.json")
        try Data("{\"v\":1}".utf8).write(to: inner)

        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [watched])
        registry.stampAfterTick(loopId: "l")
        #expect(
            registry.isSelfWriteEcho(loopId: "l") == false,
            "a directory watch must never suppress — its generation cannot prove the files under it are unchanged"
        )

        // The concrete miss this guards: an in-place rewrite inside the
        // directory leaves the DIRECTORY unchanged.
        let before = PhysiologySelfWriteRegistry.generation(of: watched)
        try Data("{\"v\":2}".utf8).write(to: inner)
        let after = PhysiologySelfWriteRegistry.generation(of: watched)
        #expect(
            before == after,
            "premise check: this test is only meaningful while a directory's generation is blind to in-place child writes"
        )
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    /// A mixed path set is only as trustworthy as its weakest member.
    @Test
    func oneWatchedDirectoryDisablesSuppressionForTheWholeSet() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file, sub])
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }

    /// The app's own atomic writes go through rename(2), so the inode changes.
    /// A foreign atomic write must read as a change.
    @Test
    func anAtomicRenameWriteIsDelivered() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("{\"v\":1}".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        #expect(registry.isSelfWriteEcho(loopId: "l"))

        let tmp = dir.appendingPathComponent("state.json.tmp")
        try Data("{\"v\":1}".utf8).write(to: tmp)   // SAME bytes, same size
        _ = rename(tmp.path, file.path)
        #expect(
            registry.isSelfWriteEcho(loopId: "l") == false,
            "a byte-identical atomic replace still swapped the inode — it is a new file"
        )
    }

    /// Content change alone, with size and path identical, must still read as a
    /// change — otherwise a same-size in-place rewrite is invisible.
    @Test
    func sameSizeContentChangeIsDetected() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("state.json")
        try Data("aaaa".utf8).write(to: file)
        let registry = PhysiologySelfWriteRegistry()
        registry.register(loopId: "l", paths: [file])
        registry.stampAfterTick(loopId: "l")
        let before = PhysiologySelfWriteRegistry.generation(of: file)

        try Data("bbbb".utf8).write(to: file)
        let after = PhysiologySelfWriteRegistry.generation(of: file)
        #expect(
            before != after,
            "a same-size rewrite produced an identical generation — st_gen and the nanosecond mtime both stood still (this is what a cached URL.resourceValues read looks like)"
        )
        #expect(registry.isSelfWriteEcho(loopId: "l") == false)
    }
}
