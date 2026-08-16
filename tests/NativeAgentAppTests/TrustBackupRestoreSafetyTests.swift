import Foundation
import Testing
import PersistenceCore
import ApprovalInbox
import MemoryV2
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

    @Test func backupUsesCoherentMemoryDatabaseAndOmitsChatLockSidecars() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try MemoryStorage(dataRoot: root)
        try write(
            #"[{"id":"chat-1","title":"Chat","createdAt":"2026-08-16T00:00:00Z"}]"#,
            to: "chat/sessions.json",
            under: root
        )
        try write("stale lock bytes", to: "chat/sessions.json.lock", under: root)
        try write("{\"role\":\"user\",\"content\":\"hello\"}\n", to: "chat/messages/chat-1.jsonl", under: root)
        try write("stale lock bytes", to: "chat/messages/chat-1.jsonl.lock", under: root)

        let backup = try await NativeClient.createBackup(reason: "coherent stores", dataRoot: root)
        let data = URL(fileURLWithPath: backup.path).appendingPathComponent("data", isDirectory: true)

        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("memory/memory.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("memory/memory.sqlite-wal").path))
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("memory/memory.sqlite-shm").path))
        _ = try MemoryStorage(dataRoot: data)
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("chat/sessions.json.lock").path))
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("chat/messages/chat-1.jsonl.lock").path))
        #expect(try read("chat/messages/chat-1.jsonl", under: data).contains("hello"))
    }

    @Test func restoreCreatesSafetyBackupBeforeReplacingLiveData() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "before policy migration", dataRoot: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)

        let staged = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)

        #expect(staged.requiresRestart)
        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        let resumed = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)
        let result = try #require(resumed)

        #expect(try read("trust/policy.json", under: root) == trustPolicy("target"))
        #expect(!result.requiresRestart)
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
        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)
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

    @Test func restoreIgnoresRegistryPathAndDerivesSourceUnderBackupRoot() async throws {
        let root = try makeTempRoot()
        let outside = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "contained source", dataRoot: root)
        try write(trustPolicy("outside"), to: "data/trust/policy.json", under: outside)
        try rewriteBackupRegistryPath(root: root, id: target.id, path: outside.path)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)

        let staged = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
        #expect(staged.requiresRestart)
        _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)

        #expect(try read("trust/policy.json", under: root) == trustPolicy("target"))
        #expect(try read("data/trust/policy.json", under: outside) == trustPolicy("outside"))
    }

    @Test func validatedLegacySwiftBackupIsSealedBeforeItCanBeStaged() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(trustPolicy("legacy target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "legacy compatibility", dataRoot: root)
        let backupDir = URL(fileURLWithPath: target.path)
        let manifest = backupDir.appendingPathComponent("manifest.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        object.removeValue(forKey: "integrityVersion")
        object.removeValue(forKey: "files")
        object.removeValue(forKey: "reason")
        let legacyBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacyBytes.write(to: manifest, options: .atomic)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)

        let staged = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
        #expect(staged.requiresRestart)
        _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)

        #expect(try read("trust/policy.json", under: root) == trustPolicy("legacy target"))
        let sealed = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        #expect(sealed["integrityVersion"] as? Int == 2)
        #expect(sealed["files"] != nil)
        #expect(try Data(contentsOf: backupDir.appendingPathComponent("manifest.v1.json")) == legacyBytes)
    }

    @Test func tamperedBackupDigestIsRejectedAndBytesRemainUntouched() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "digest target", dataRoot: root)
        try write(
            trustPolicy("tampered"),
            to: "data/trust/policy.json",
            under: URL(fileURLWithPath: target.path)
        )
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore accepted backup bytes that no longer match the manifest")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 422)
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(
            try read("data/trust/policy.json", under: URL(fileURLWithPath: target.path))
                == trustPolicy("tampered")
        )
    }

    @Test func backupSymlinkIsRejectedBeforeCurrentDataChanges() async throws {
        let root = try makeTempRoot()
        let outside = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "symlink target", dataRoot: root)
        let backupTrust = URL(fileURLWithPath: target.path).appendingPathComponent("data/trust")
        try FileManager.default.removeItem(at: backupTrust)
        try write(trustPolicy("outside"), to: "policy.json", under: outside)
        try FileManager.default.createSymbolicLink(at: backupTrust, withDestinationURL: outside)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)

        do {
            _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
            Issue.record("Restore accepted a symbolic-link backup member")
        } catch {
            #expect((error as NSError).code == 422)
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(try read("policy.json", under: outside) == trustPolicy("outside"))
    }

    @Test func stagedRestoreRevalidatesPinnedManifestAndDigestAtLaunch() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "effect-time target", dataRoot: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
        try write(
            trustPolicy("changed after staging"),
            to: "data/trust/policy.json",
            under: URL(fileURLWithPath: target.path)
        )

        do {
            _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)
            Issue.record("Launch restore accepted bytes changed after staging")
        } catch {
            #expect((error as NSError).code == 422)
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/restore-intent.json").path))
    }

    @Test func interruptedTargetApplicationRollsBackSafetySnapshotBeforeLaunch() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        let target = try await NativeClient.createBackup(reason: "interrupted target", dataRoot: root)
        try write(trustPolicy("current"), to: "trust/policy.json", under: root)
        _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)

        let intent = root.appendingPathComponent("backups/restore-intent.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: intent)) as? [String: Any]
        )
        object["state"] = "applying"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: intent, options: .atomic)
        try write(trustPolicy("partially applied"), to: "trust/policy.json", under: root)

        do {
            _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)
            Issue.record("Interrupted target application did not surface its rollback")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "NativeAgentBackup")
            #expect(nsError.code == 500)
        }

        #expect(try read("trust/policy.json", under: root) == trustPolicy("current"))
        #expect(!FileManager.default.fileExists(atPath: intent.path))
    }

    @Test func restorePreservesNewerApprovalOccurrenceAndExternalSendFences() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(trustPolicy("target"), to: "trust/policy.json", under: root)
        try write(
            #"[{"id":"job-1","lastOccurrenceKey":"old-occurrence"}]"#,
            to: "scheduler/jobs.json",
            under: root
        )
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Fence test"),
            "action": .string("test.effect"),
            "risk": .string("high"),
            "reason": .string("prove restore monotonicity"),
            "payload": .object(["kind": .string("test")]),
        ]))
        let target = try await NativeClient.createBackup(reason: "old generation", dataRoot: root)

        try write(
            #"[{"id":"job-1","lastOccurrenceKey":"new-occurrence"}]"#,
            to: "scheduler/jobs.json",
            under: root
        )
        _ = try await inbox.resolve(
            approval.id,
            decision: .approved,
            provenance: .local(decidedBy: "test")
        )
        _ = try await inbox.annotateExecution(
            approval.id,
            executedAction: .object(["status": .string("succeeded")]),
            detail: "effect completed"
        )
        let initialSpend = await inbox.consumeApprovedEffect(
            id: approval.id,
            digest: "new-digest",
            action: "test.effect",
            surface: "test"
        )
        #expect(initialSpend == .spent)

        let sendApprovalID = UUID().uuidString.lowercased()
        let receipt: JSONValue = .object([
            "kind": .string("external_send_execution"),
            "approvalId": .string(sendApprovalID),
            "idempotencyKey": .string("new-send-occurrence"),
            "connectorId": .string("slack"),
            "actionId": .string("slack.post_message"),
            "status": .string("provider_accepted"),
            "didDispatch": .bool(true),
        ])
        try write(
            try receipt.serialize(pretty: false),
            to: "connectors/actions/external_send_receipts/\(sendApprovalID).json",
            under: root
        )
        try write(
            "lock sidecar",
            to: "connectors/actions/external_send_receipts/\(sendApprovalID).json.lock",
            under: root
        )

        _ = try await NativeClient.restoreBackup(id: target.id, dataRoot: root)
        _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(dataRoot: root)

        #expect(try read("scheduler/jobs.json", under: root).contains("new-occurrence"))
        let recoveredApproval = try await SwiftNativeApprovalInbox(root: root).get(approval.id)
        #expect(recoveredApproval.status == "resolved")
        #expect(recoveredApproval.executedAction != nil)
        let restoredSpend = await SwiftNativeApprovalInbox(root: root).consumeApprovedEffect(
            id: approval.id,
            digest: "new-digest",
            action: "test.effect",
            surface: "test"
        )
        #expect(restoredSpend == .alreadySpent)
        #expect(
            try read(
                "connectors/actions/external_send_receipts/\(sendApprovalID).json",
                under: root
            ).contains("new-send-occurrence")
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

    private func rewriteBackupRegistryPath(root: URL, id: String, path: String) throws {
        for name in ["registry.json", "index.json"] {
            let registry = root.appendingPathComponent("backups/\(name)")
            var rows = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]]
            )
            for index in rows.indices where rows[index]["id"] as? String == id {
                rows[index]["path"] = path
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
                .write(to: registry, options: .atomic)
        }
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
