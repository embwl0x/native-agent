import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / macsync.snapshotIntegrityLoop

@Suite("MacSync snapshot integrity fallback")
struct MacSyncSnapshotIntegrityLoopEvalTests {
    @Test("the slow integrity seam keeps proven files, prunes retired keys, and marks only active snapshot damage for repair")
    func reconcilesDigestAuthorityAgainstTheActualMobileFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let healthy = Data("{\"ok\":true}".utf8)
        try healthy.write(to: directory.appendingPathComponent("health.json"), options: .atomic)
        try Data("{\"tampered\":true}".utf8)
            .write(to: directory.appendingPathComponent("sessions.json"), options: .atomic)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("trust_policy.json"),
            withIntermediateDirectories: true
        )

        let report = MacSyncSnapshotIntegrity.reconcile(
            digests: [
                "health.json": MacSyncSnapshotIntegrity.digest(healthy),
                "sessions.json": MacSyncSnapshotIntegrity.digest(Data("{\"expected\":true}".utf8)),
                "trust_policy.json": "expected-regular-file",
                "providers.json": "missing-active-snapshot",
                "retired_snapshot.json": "retired-key",
            ],
            in: directory
        )

        #expect(report.retainedDigests == [
            "health.json": MacSyncSnapshotIntegrity.digest(healthy),
        ])
        #expect(report.mismatchedManagedFiles == ["sessions.json"])
        #expect(report.unreadableManagedFiles == ["trust_policy.json"])
        #expect(report.missingManagedFiles == ["providers.json"])
        #expect(report.retiredDigestKeys == ["retired_snapshot.json"])
        #expect(report.requiresRepair)
        #expect(report.integrityFailures == [
            "providers.json is missing",
            "sessions.json digest mismatch",
            "trust_policy.json unreadable",
        ])
    }

    @Test("a matching bounded active file remains eligible for the writer's no-write fast path")
    func unchangedSnapshotRemainsProven() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("{\"ready\":true}".utf8)
        try data.write(to: directory.appendingPathComponent("health.json"), options: .atomic)

        let digest = MacSyncSnapshotIntegrity.digest(data)
        let report = MacSyncSnapshotIntegrity.reconcile(
            digests: ["health.json": digest],
            in: directory
        )

        #expect(report.retainedDigests == ["health.json": digest])
        #expect(!report.requiresRepair)
        #expect(report.integrityFailures.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-snapshot-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
