import ChatOrchestration
import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Item 5 re-review (2026-09-02) — the AVAILABILITY half of the forward
// register.
//
// The horizon lane reads absence as an answer: a source that disappears while
// its horizon is still ahead means "it landed", and opens the relief door. That
// makes every one of these readers a place where "I could not read the store"
// must never be allowed to look like "the thing you were waiting for came
// round". Two of them were getting it wrong in opposite directions, and both
// failures are quiet — one invents a feeling, the other withholds one.
//
// WRITTEN, NOT RUN (User's standing rule).
@Suite("Horizon source availability", .serialized)
struct HorizonSourceAvailabilityTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizon-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - (2) A missing Desk is not "your plans came true"

    @Test("an unwritten Desk is never vouched for")
    func absentDeskFeedIsNotComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(dataRoot: root)

        // `SwiftNativeDeskStore.liveState()` answers this root with a
        // well-formed EMPTY state — indistinguishable in shape from a desk with
        // nothing parked, and the reason row-count cannot decide completeness.
        #expect(runtime.deskFeedIsPresent == false)
    }

    @Test("either half of the canonical feed is enough to vouch for it")
    func presentDeskFeedIsComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let runtime = NativeCognitionRuntime(dataRoot: root)
        try FileManager.default.createDirectory(
            at: store.opsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // The op-log alone.
        FileManager.default.createFile(atPath: store.opsPath.path, contents: Data())
        #expect(runtime.deskFeedIsPresent)

        // And the compaction snapshot alone — a freshly compacted desk can
        // legitimately have no op-log at all, and it is emphatically readable.
        try FileManager.default.removeItem(at: store.opsPath)
        FileManager.default.createFile(atPath: store.basePath.path, contents: Data("{}".utf8))
        #expect(runtime.deskFeedIsPresent)
    }

    // MARK: - (3) A peer that replied must be allowed to have replied

    @Test("an empty but readable set of bridges reports complete")
    func readableEmptyBridgesAreComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = root.appendingPathComponent("claude-bridge/wake-jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)

        let read = DelegationStatusProjector(configRoot: root)
            .recentJobsWithAvailability(now: Date())

        #expect(read.jobs.isEmpty)
        // The row count says nothing; availability says the stores answered.
        // This is the case that used to leave a peer who HAD written back
        // pending until her horizon passed and she was told she was still
        // waiting for them.
        #expect(read.allStoresReadable)
    }

    @Test("a bridge that is not configured is a peer she does not have")
    func absentBridgesAreStillComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Nothing configured at all: every source reads `absent`, which is a
        // fact about her setup, not a failed read.
        let read = DelegationStatusProjector(configRoot: root)
            .recentJobsWithAvailability(now: Date())
        #expect(read.jobs.isEmpty)
        #expect(read.allStoresReadable)
    }

    @Test("a bridge directory that cannot be read withholds the vouch")
    func unreadableBridgeIsNotComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A FILE where the projector expects a directory: present, and
        // unreadable as a job store. `sourceStatus` calls that `unavailable`,
        // which is exactly the state that must not mint relief.
        let jobs = root.appendingPathComponent("claude-bridge/wake-jobs")
        try FileManager.default.createDirectory(
            at: jobs.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: jobs.path, contents: Data())

        let read = DelegationStatusProjector(configRoot: root)
            .recentJobsWithAvailability(now: Date())
        #expect(read.allStoresReadable == false)
    }

    // MARK: - (4) Lane → authorship is a decision, not an assumption

    @Test("every message lane on this bridge is an agent lane, by name")
    func laneAuthorshipTableCoversTheRealRoutes() {
        #expect(ClaudeBridge.laneAuthorship(forSender: "claude") == .agent)
        #expect(ClaudeBridge.laneAuthorship(forSender: "codex") == .agent)
        #expect(ClaudeBridge.laneAuthorship(forSender: "omp") == .agent)
        // A route nobody has answered for cannot claim peer standing. Failing
        // closed means the worst case is a peer felt as User, never User felt as
        // a peer.
        #expect(ClaudeBridge.laneAuthorship(forSender: "relay") == nil)
        #expect(ClaudeBridge.laneAuthorship(forSender: "") == nil)
    }
}
