import Testing
import Foundation
@testable import MemoryV2

@Suite("MemoryV2 CloudKit sync (Phase D)")
struct CloudKitTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryV2CloudKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleRecord(id: String = "r1", text: String = "hello", updatedAt: String = "2026-01-01T00:00:00Z") -> CloudKitMemoryRecord {
        CloudKitMemoryRecord(
            id: id,
            text: text,
            kind: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: updatedAt
        )
    }

    // MARK: MockCloudKitSync

    @Test func mockCloudKit_push_stamps_modificationDate() async throws {
        let m = MockCloudKitSync()
        let stamped = try await m.push([sampleRecord()])
        #expect(stamped.count == 1)
        #expect(stamped[0].modificationDate != nil)
    }

    @Test func mockCloudKit_pull_since_nil_returns_all() async throws {
        let m = MockCloudKitSync()
        _ = try await m.push([sampleRecord(id: "a"), sampleRecord(id: "b")])
        let all = try await m.pullSince(nil)
        #expect(all.count == 2)
    }

    @Test func mockCloudKit_pull_since_filters_by_modificationDate() async throws {
        let m = MockCloudKitSync()
        let first = try await m.push([sampleRecord(id: "a")])
        guard let cutoff = first.first?.modificationDate else {
            Issue.record("expected modificationDate")
            return
        }
        _ = try await m.push([sampleRecord(id: "b")])
        let recent = try await m.pullSince(cutoff)
        #expect(recent.count == 1)
        #expect(recent.first?.id == "b")
    }

    @Test func mockCloudKit_delete_removes_records() async throws {
        let m = MockCloudKitSync()
        _ = try await m.push([sampleRecord(id: "a"), sampleRecord(id: "b")])
        try await m.delete(ids: ["a"])
        let snap = await m.snapshot()
        #expect(snap["a"] == nil)
        #expect(snap["b"] != nil)
    }

    @Test func mockCloudKit_accountStatus_default_available() async throws {
        let m = MockCloudKitSync()
        let s = await m.accountStatus()
        #expect(s == "available")
    }

    @Test func mockCloudKit_accountStatus_simulate_noAccount() async throws {
        let m = MockCloudKitSync()
        await m.setSimulateAccountStatus("noAccount")
        let s = await m.accountStatus()
        #expect(s == "noAccount")
    }

    @Test func mockCloudKit_push_with_simulateConflict_throws_conflict() async throws {
        let m = MockCloudKitSync()
        await m.setSimulateConflictOnPush(true)
        do {
            _ = try await m.push([sampleRecord()])
            Issue.record("expected conflict error")
        } catch let CloudKitSyncError.conflict(server) {
            #expect(server.id == "r1")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: SwiftNativeMemoryCloudSync

    @Test func swiftNativeMemoryCloudSync_loadSyncState_initial_returns_nils() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = SwiftNativeMemoryCloudSync(sync: MockCloudKitSync(), storePath: dir)
        let s = try await coord.loadSyncState()
        #expect(s.lastPushAt == nil)
        #expect(s.lastPullAt == nil)
    }

    @Test func swiftNativeMemoryCloudSync_recordSyncState_persists() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = SwiftNativeMemoryCloudSync(sync: MockCloudKitSync(), storePath: dir)
        let push = Date(timeIntervalSinceReferenceDate: 1000)
        let pull = Date(timeIntervalSinceReferenceDate: 2000)
        try await coord.recordSyncState(lastPushAt: push, lastPullAt: pull)
        let loaded = try await coord.loadSyncState()
        // ISO 8601 round-trip should preserve seconds (we use fractional seconds).
        #expect(loaded.lastPushAt != nil)
        #expect(loaded.lastPullAt != nil)
        if let lp = loaded.lastPushAt, let lpl = loaded.lastPullAt {
            #expect(abs(lp.timeIntervalSinceReferenceDate - 1000) < 0.01)
            #expect(abs(lpl.timeIntervalSinceReferenceDate - 2000) < 0.01)
        }
    }

    @Test func swiftNativeMemoryCloudSync_syncPush_delegates_to_sync() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockCloudKitSync()
        let coord = SwiftNativeMemoryCloudSync(sync: mock, storePath: dir)
        let stamped = try await coord.syncPush(records: [sampleRecord(id: "a")])
        #expect(stamped.count == 1)
        let snap = await mock.snapshot()
        #expect(snap["a"] != nil)
        // lastPushAt should now be set.
        let state = try await coord.loadSyncState()
        #expect(state.lastPushAt != nil)
    }

    @Test func swiftNativeMemoryCloudSync_syncPull_advances_lastPullAt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockCloudKitSync()
        _ = try await mock.push([sampleRecord(id: "a")])
        let coord = SwiftNativeMemoryCloudSync(sync: mock, storePath: dir)
        let before = try await coord.loadSyncState()
        #expect(before.lastPullAt == nil)
        let results = try await coord.syncPull()
        #expect(results.count == 1)
        let after = try await coord.loadSyncState()
        #expect(after.lastPullAt != nil)
    }

    @Test func swiftNativeMemoryCloudSync_resolveConflict_localNewer_wins() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = SwiftNativeMemoryCloudSync(sync: MockCloudKitSync(), storePath: dir)
        let local = sampleRecord(id: "r1", text: "local", updatedAt: "2026-05-01T00:00:00Z")
        let server = sampleRecord(id: "r1", text: "server", updatedAt: "2026-01-01T00:00:00Z")
        let winner = coord.resolveConflict(local: local, server: server)
        #expect(winner.text == "local")
    }

    @Test func swiftNativeMemoryCloudSync_resolveConflict_serverNewer_wins() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = SwiftNativeMemoryCloudSync(sync: MockCloudKitSync(), storePath: dir)
        let local = sampleRecord(id: "r1", text: "local", updatedAt: "2026-01-01T00:00:00Z")
        let server = sampleRecord(id: "r1", text: "server", updatedAt: "2026-05-01T00:00:00Z")
        let winner = coord.resolveConflict(local: local, server: server)
        #expect(winner.text == "server")
    }

    @Test func swiftNativeMemoryCloudSync_concurrent_recordSyncState_atomic() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = SwiftNativeMemoryCloudSync(sync: MockCloudKitSync(), storePath: dir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let d = Date(timeIntervalSinceReferenceDate: TimeInterval(i))
                    try? await coord.recordSyncState(lastPushAt: d, lastPullAt: d)
                }
            }
        }
        // Final state should be readable (no corruption / partial-write file).
        let final = try await coord.loadSyncState()
        #expect(final.lastPushAt != nil)
        #expect(final.lastPullAt != nil)
    }
}
