// A1 waste-hunt pinning tests (app side).
//
// FIX-1a — getHealthCard is now the PRODUCER of the doctor snapshot it reads,
//   so its own 60s cache contract finally holds. Before this, the only producer
//   ticked every seven days, so the 15s chat health pill ran a full doctor
//   sweep on every single poll.
// FIX-2  — the 300s github_tracking tick no longer replays the whole
//   GitHubCommandStore op log just to discover nothing changed.
//
// Both are pure waste removal, so the assertions are about work COUNTS while
// holding the produced verdict fixed.

import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private func perfTempRoot(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("perf-waste-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - FIX-1a: the health-card doctor cache handshake

private actor CoreCheckSpy {
    private(set) var runs = 0
    private let results: [NativeClient.CoreCheckResult]
    init(results: [NativeClient.CoreCheckResult]) { self.results = results }
    func run() -> [NativeClient.CoreCheckResult] {
        runs += 1
        return results
    }
}

private let liveCoverageProbe: [DoctorCheck] = [
    DoctorCheck(id: "live.providers", title: "Providers and OAuth", status: "ok", detail: "live", repair: nil),
]

private let coreProbe: [NativeClient.CoreCheckResult] = [
    NativeClient.CoreCheckResult(id: "storage", title: "Storage", status: "ok", detail: "core-ok"),
    NativeClient.CoreCheckResult(id: "chat_messages", title: "Chat Message Logs", status: "warn", detail: "core-warn", repair: "fix me"),
]

@Suite("A1 health-card doctor cache")
struct HealthCardDoctorCacheTests {
    @Test("a live run persists the snapshot, and the next call inside 60s does not re-run the checks")
    func liveRunWritesCacheAndSecondCallHits() async throws {
        let root = perfTempRoot("healthcard-hit")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("doctor/latest.json")
        let spy = CoreCheckSpy(results: coreProbe)
        let now = ISO8601DateFormatter().string(from: Date())

        let first = await NativeClient.makeHealthCard(
            now: now, cachePath: cache, liveChecks: liveCoverageProbe,
            runCoreChecks: { await spy.run() }
        )
        #expect(await spy.runs == 1)
        #expect(FileManager.default.fileExists(atPath: cache.path))

        // The 15s pill polls again a moment later. Pre-fix this ran the whole
        // 9-check sweep again; now it must not run the checks at all.
        let second = await NativeClient.makeHealthCard(
            now: now, cachePath: cache, liveChecks: liveCoverageProbe,
            runCoreChecks: { await spy.run() }
        )
        #expect(await spy.runs == 1)

        // Same verdict either way — that is the whole contract.
        #expect(second.overall == first.overall)
        #expect(second.overall == "warn")
        #expect(second.subsystems.map(\.id) == first.subsystems.map(\.id))
        #expect(second.subsystems.map(\.status) == first.subsystems.map(\.status))
        #expect(second.subsystems.map(\.detail) == first.subsystems.map(\.detail))
    }

    @Test("the persisted file matches DoctorAutoRunLoop's wire shape and holds core checks only")
    func persistedSnapshotMatchesLoopWireShape() async throws {
        let root = perfTempRoot("healthcard-shape")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("doctor/latest.json")
        let now = ISO8601DateFormatter().string(from: Date())

        _ = await NativeClient.makeHealthCard(
            now: now, cachePath: cache, liveChecks: liveCoverageProbe,
            runCoreChecks: { coreProbe }
        )

        let data = try Data(contentsOf: cache)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["runAt"] as? String == now)
        let checks = try #require(obj["checks"] as? [[String: Any]])
        #expect(checks.map { $0["id"] as? String } == ["storage", "chat_messages"])
        // Live-owner rows are per-call truth. Leaking them into this file would
        // change what SelfHealingHook and the heartbeat read out of it.
        #expect(checks.allSatisfy { ($0["id"] as? String)?.hasPrefix("live.") == false })
    }

    @Test("a stale snapshot still falls through to a live run")
    func staleSnapshotFallsThrough() async throws {
        let root = perfTempRoot("healthcard-stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("doctor/latest.json")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Exactly the situation the live app was stuck in: a snapshot written
        // by the 7-day loop, long past the 60s window.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86_400))
        try #"{"checks":[{"id":"storage","title":"Storage","status":"fail","detail":"stale"}],"runAt":"\#(old)"}"#
            .write(to: cache, atomically: true, encoding: .utf8)

        let spy = CoreCheckSpy(results: coreProbe)
        let card = await NativeClient.makeHealthCard(
            now: ISO8601DateFormatter().string(from: Date()),
            cachePath: cache, liveChecks: liveCoverageProbe,
            runCoreChecks: { await spy.run() }
        )
        #expect(await spy.runs == 1)
        // The stale "fail" row must NOT be what the pill shows.
        #expect(card.overall == "warn")
        #expect(card.subsystems.first { $0.id == "storage" }?.detail == "core-ok")
    }

    @Test("live coverage rows are recomputed on a cache hit, never served from disk")
    func cacheHitStillUsesFreshLiveCoverage() async throws {
        let root = perfTempRoot("healthcard-live")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("doctor/latest.json")
        let now = ISO8601DateFormatter().string(from: Date())
        _ = await NativeClient.makeHealthCard(
            now: now, cachePath: cache, liveChecks: liveCoverageProbe,
            runCoreChecks: { coreProbe }
        )

        // Telegram just broke. The cached core checks are still fresh, but the
        // live row must reflect the new truth immediately.
        let degraded: [DoctorCheck] = [
            DoctorCheck(id: "live.providers", title: "Providers and OAuth", status: "fail", detail: "key revoked", repair: nil),
        ]
        let card = await NativeClient.makeHealthCard(
            now: now, cachePath: cache, liveChecks: degraded,
            runCoreChecks: { Issue.record("core checks must not re-run on a cache hit"); return coreProbe }
        )
        #expect(card.overall == "fail")
        #expect(card.subsystems.first { $0.id == "live.providers" }?.detail == "key revoked")
    }

    @Test("a doctor failure still renders the single error row and writes no cache")
    func doctorFailureFallsBackAndDoesNotPoisonTheCache() async throws {
        let root = perfTempRoot("healthcard-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("doctor/latest.json")
        struct Boom: Error {}
        let card = await NativeClient.makeHealthCard(
            now: ISO8601DateFormatter().string(from: Date()),
            cachePath: cache, liveChecks: liveCoverageProbe,
            runCoreChecks: { throw Boom() }
        )
        #expect(card.overall == "error")
        #expect(card.subsystems.map(\.id) == ["doctor"])
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
    }
}

// MARK: - FIX-2: change-gated github_tracking replay

@Suite("A1 github_tracking replay gate")
struct GitHubTrackingReplayGateTests {
    private func makeRuntime(root: URL) -> GitHubCommandRuntime {
        GitHubCommandRuntime(
            dataRoot: root,
            observationLoader: { _ in throw CancellationError() },
            notificationSender: { _ in ("skipped", "") }
        )
    }

    private func opsDir(_ root: URL) -> URL {
        let dir = root.appendingPathComponent("workshop/github_command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("unchanged op-log files produce no replay")
    func unchangedOpLogSkipsReplay() async throws {
        let root = perfTempRoot("gh-unchanged")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = opsDir(root)
        try "{\"seq\":1}\n".write(
            to: dir.appendingPathComponent("ops.jsonl"), atomically: true, encoding: .utf8
        )
        let runtime = makeRuntime(root: root)

        // First tick after launch always replays — nothing is known yet.
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 1)

        // Nine further event/repair offers with nothing moving on disk.
        // Pre-fix each offer decoded and reduced the entire op log.
        for _ in 0..<9 {
            await runtime.processConnectorChangesIfChanged(refreshed: false)
        }
        #expect(await runtime._testConnectorReplayCount() == 1)
    }

    @Test("a refresh that wrote something always replays")
    func refreshedAlwaysReplays() async throws {
        let root = perfTempRoot("gh-refreshed")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = opsDir(root)
        let runtime = makeRuntime(root: root)
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        await runtime.processConnectorChangesIfChanged(refreshed: true)
        await runtime.processConnectorChangesIfChanged(refreshed: true)
        #expect(await runtime._testConnectorReplayCount() == 3)
    }

    @Test("an out-of-process append to ops.jsonl replays on the next tick")
    func externalAppendReplays() async throws {
        let root = perfTempRoot("gh-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = opsDir(root)
        let ops = dir.appendingPathComponent("ops.jsonl")
        try "{\"seq\":1}\n".write(to: ops, atomically: true, encoding: .utf8)
        let runtime = makeRuntime(root: root)
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 1)

        // A CLI / sibling process appends a row. This is the recovery property
        // the unconditional replay was there for; it must survive the gate.
        let handle = try FileHandle(forWritingTo: ops)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":2}\n".utf8))
        try handle.close()

        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 2)
    }

    @Test("compaction (base rewritten, ops truncated) replays even though ops SHRANK")
    func compactionReplays() async throws {
        let root = perfTempRoot("gh-compaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = opsDir(root)
        let ops = dir.appendingPathComponent("ops.jsonl")
        let base = dir.appendingPathComponent("ops_base.json")
        try "{\"seq\":1}\n{\"seq\":2}\n{\"seq\":3}\n".write(to: ops, atomically: true, encoding: .utf8)
        let runtime = makeRuntime(root: root)
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 1)

        // Compaction: the base snapshot appears and the tail is truncated. A
        // size-only or grow-only heuristic would miss this entirely.
        try #"{"items":[]}"#.write(to: base, atomically: true, encoding: .utf8)
        try "".write(to: ops, atomically: true, encoding: .utf8)

        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 2)
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 2)
    }

    @Test("a same-size rewrite with a new mtime still replays")
    func sameSizeRewriteReplays() async throws {
        let root = perfTempRoot("gh-samesize")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = opsDir(root)
        let ops = dir.appendingPathComponent("ops.jsonl")
        try "{\"seq\":1}\n".write(to: ops, atomically: true, encoding: .utf8)
        let runtime = makeRuntime(root: root)
        await runtime.processConnectorChangesIfChanged(refreshed: false)

        try "{\"seq\":2}\n".write(to: ops, atomically: true, encoding: .utf8)   // same byte count
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: ops.path
        )
        await runtime.processConnectorChangesIfChanged(refreshed: false)
        #expect(await runtime._testConnectorReplayCount() == 2)
    }
}

// MARK: - Shared event-driven subprocess ownership

@Suite("App subprocess consolidation")
struct NativeClientProcessConsolidationTests {
    @Test("app commands preserve cwd and output through the shared process owner")
    func workingDirectoryAndOutputArePreserved() async throws {
        let root = perfTempRoot("shared-process")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NativeClient.runProcess(
            executable: "/bin/pwd",
            arguments: [],
            currentDirectory: root,
            timeout: 2
        )

        #expect(result.status == 0)
        #expect(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("/\(root.lastPathComponent)")
        )
        #expect(result.stderr.isEmpty)
    }

    @Test("app timeout contract remains exit 124 with an honest detail")
    func timeoutContractIsPreserved() async throws {
        let root = perfTempRoot("shared-process-timeout")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NativeClient.runProcess(
            executable: "/bin/sleep",
            arguments: ["2"],
            currentDirectory: root,
            timeout: 0.05
        )

        #expect(result.status == 124)
        #expect(result.stderr.contains("timed out"))
    }
}

// MARK: - Lazy privacy inventory

@Suite("Privacy inventory refresh cost")
struct PrivacyInventoryRefreshCostTests {
    @Test("metadata-only refresh skips recursive counts while explicit inventory keeps them")
    func inventoryIsLazyWithoutChangingTheExplicitMap() throws {
        let root = perfTempRoot("privacy-inventory")
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: chat.appendingPathComponent("one.jsonl"))

        let metadataOnly = NativeClient.privacyCategories(
            dataRoot: root,
            includeInventory: false
        )
        let inventoried = NativeClient.privacyCategories(
            dataRoot: root,
            includeInventory: true
        )
        let metadataChat = try #require(metadataOnly.first { $0.id == "chat" })
        let inventoriedChat = try #require(inventoried.first { $0.id == "chat" })

        #expect(metadataChat.path == inventoriedChat.path)
        #expect(metadataChat.exportable == inventoriedChat.exportable)
        #expect(!metadataChat.contains.contains("1 file"))
        #expect(inventoriedChat.contains.contains("1 file, 3 bytes"))
    }
}
