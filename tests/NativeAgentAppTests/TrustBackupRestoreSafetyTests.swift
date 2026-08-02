import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

@Suite("Trust backup restore safety")
struct TrustBackupRestoreSafetyTests {
    @Test func backupCopiesWorkshopStateAndExcludesRetiredWorkshopExecutionsRoot() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("workshop", to: "workshop/executions/task-1/mission.json", under: root)
        try write("legacy", to: "missions/should-not-return.json", under: root)

        let backup = try await NativeClient.createBackup(reason: "Workshop cutover", dataRoot: root)
        let backupData = URL(fileURLWithPath: backup.path).appendingPathComponent("data", isDirectory: true)

        #expect(try read("workshop/executions/task-1/mission.json", under: backupData) == "workshop")
        #expect(!FileManager.default.fileExists(atPath: backupData.appendingPathComponent("missions").path))
        #expect(NativeClient.productionExportRelativePaths.contains("workshop"))
        #expect(!NativeClient.productionExportRelativePaths.contains("missions"))
    }

    @Test func restoreCreatesSafetyBackupBeforeReplacingLiveData() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "before policy migration", dataRoot: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)

        let result = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)

        #expect(try read("trust/policy.json", under: root) == trustPolicy("target"))
        #expect(result.restored.contains("trust"))
        let records = try NativeClient.readBackupRecords(root: root)
        let safety = try #require(records.first(where: { $0.id != target.id }))
        #expect(safety.reason.contains("pre-restore safety backup"))
        #expect(safety.reason.contains(target.reason))
        #expect(safety.reason.contains(target.createdAt))
        #expect(try read("trust/policy.json", under: URL(fileURLWithPath: safety.path).appendingPathComponent("data")) == trustPolicy("current"))
    }

    @Test func safetyBackupFailureLeavesDestinationUnchanged() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "known good", dataRoot: root)
        try write(trustPolicy("current must survive"), to: "trust/policy.json", under: root)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backupRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupRoot.path)
        }

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore unexpectedly continued after the safety backup failed")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 412)
            #expect(nsError.localizedDescription.contains("before current data changed"))
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current must survive"))
        #expect(try NativeClient.readBackupRecords(root: root).map(\.id) == [target.id])
    }

    @Test func overlappingRestoreIsRejectedForTheSameDataRoot() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "overlap target", dataRoot: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        let gate = RestoreSafetyGate()
        let registryPath = root.appendingPathComponent("backups/registry.json")
        let persistence = SwiftNativePersistenceCore()

        let registryLock = Task {
            try await persistence.withFileLock(registryPath) {
                await gate.pause()
            }
        }
        await gate.waitUntilPaused()
        let initialDirectoryCount = try backupDirectoryCount(under: root)

        let firstRestore = Task {
            try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
        }
        do {
            try await waitForAdditionalBackupDirectory(
                under: root,
                initialCount: initialDirectoryCount
            )
        } catch {
            await gate.resume()
            _ = try? await registryLock.value
            _ = try? await firstRestore.value
            throw error
        }

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("An overlapping restore unexpectedly acquired the same data-root gate")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 409)
        }

        await gate.resume()
        _ = try await registryLock.value
        _ = try await firstRestore.value
        #expect(try read("trust/policy.json", under: root) == trustPolicy("target"))
    }

    @Test func malformedBackupSessionIndexIsRejectedBeforeLiveDataChanges() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed = #"[{"id":"target"},null]"#
        try write(malformed, to: "chat/sessions.json", under: root)
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "malformed session index", dataRoot: root)

        let liveSessions = #"[{"id":"live","title":"Live","createdAt":"2026-07-10T00:00:00Z"}]"#
        try write(liveSessions, to: "chat/sessions.json", under: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        let recordsBefore = try NativeClient.readBackupRecords(root: root).map(\.id)

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore unexpectedly accepted a malformed backup session index")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 422)
            #expect(nsError.localizedDescription.contains("before current data changed"))
        }

        #expect(try read("chat/sessions.json", under: root) == liveSessions)
        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(try NativeClient.readBackupRecords(root: root).map(\.id) == recordsBefore)
    }

    @Test func malformedBackupTrustPolicyIsRejectedBeforeLiveDataChanges() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("not-json", to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "malformed trust policy", dataRoot: root)

        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        let recordsBefore = try NativeClient.readBackupRecords(root: root).map(\.id)

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore unexpectedly accepted a malformed backup trust policy")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 422)
            #expect(nsError.localizedDescription.contains("before current data changed"))
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(try NativeClient.readBackupRecords(root: root).map(\.id) == recordsBefore)
    }

    @Test func wrongTypedBackupTrustPolicyIsRejectedBeforeLiveDataChanges() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let damaged = #"{"securityPolicy":{"killSwitchEnabled":"false"}}"#
        try write(damaged, to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(
            reason: "wrong-typed trust policy",
            dataRoot: root
        )

        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        let recordsBefore = try NativeClient.readBackupRecords(root: root).map(\.id)

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore unexpectedly accepted a wrong-typed backup trust policy")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 422)
            #expect(nsError.localizedDescription.contains("before current data changed"))
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(try NativeClient.readBackupRecords(root: root).map(\.id) == recordsBefore)
    }

    @Test func malformedBackupCapabilityAuthorityIsRejectedBeforeLiveDataChanges() async throws {
        try await assertMalformedCapabilityAuthorityIsRejected(
            relativePath: "catalog/sources/sources.json"
        )
        try await assertMalformedCapabilityAuthorityIsRejected(
            relativePath: "catalog/trust/roots.json"
        )
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-backup-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ value: String, to relativePath: String, under root: URL) throws {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: destination, options: .atomic)
    }

    private func read(_ relativePath: String, under root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func trustPolicy(_ marker: String) -> String {
        #"{"testMarker":"\#(marker)"}"#
    }

    private func assertMalformedCapabilityAuthorityIsRejected(relativePath: String) async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("not-json", to: relativePath, under: root)
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(
            reason: "malformed capability authority",
            dataRoot: root
        )

        try write("[]", to: relativePath, under: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        let recordsBefore = try NativeClient.readBackupRecords(root: root).map(\.id)

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore unexpectedly accepted malformed capability authority at \(relativePath)")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 422)
        }

        #expect(try read(relativePath, under: root) == "[]")
        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(try NativeClient.readBackupRecords(root: root).map(\.id) == recordsBefore)
    }

    private func backupDirectoryCount(under root: URL) throws -> Int {
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }.count
    }

    // 10s deadline, not 2s: positive steps only need the deadline to exceed
    // worst-case scheduler noise under full-suite parallelism — a green run
    // still returns at the first 10ms poll that observes the directory.
    private func waitForAdditionalBackupDirectory(under root: URL, initialCount: Int) async throws {
        for _ in 0..<1000 {
            if try backupDirectoryCount(under: root) > initialCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RestoreTestTimeout()
    }
}

private struct RestoreTestTimeout: LocalizedError {
    var errorDescription: String? { "timed out waiting for the safety backup to start" }
}

private actor RestoreSafetyGate {
    private var paused = false
    private var resumed = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !resumed else { return }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        resumed = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
