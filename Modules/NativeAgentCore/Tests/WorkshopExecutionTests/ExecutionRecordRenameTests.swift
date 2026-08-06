import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// P2-1 (de-mission wave 1): `mission.json` → `execution.json`.
//
// Two halves have to hold together: the one-time rename pass moves the file,
// and dual-read keeps every directory the pass hasn't reached fully usable.
// Only the second half protects real user data — a crash mid-pass, an iCloud
// straggler syncing a pre-rename directory, a restored backup.

private func renameTestRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExecutionRecordRenameTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func executionDir(_ root: URL, _ id: String) throws -> URL {
    let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A complete, parseable record body — enough for `recordFromJSON` and every
/// scanner's `id`-non-empty guard.
private func recordBody(id: String, status: String = "queued", title: String = "t") -> String {
    """
    {"id":"\(id)","title":"\(title)","objective":"o","created_at":"2026-01-01T00:00:00Z",\
    "status":"\(status)","plan":[],"steps_completed":[],"receipts_dir":"",\
    "trigger_source":"manual","trust_required":"none","expected_outputs":[],\
    "current_step_id":"","updated_at":"2026-01-01T00:00:00Z","result":null,"rerun_count":0}
    """
}

private func writeString(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func readString(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

private func migrationMarker(_ root: URL) -> URL {
    WorkshopStorageMigrator.recordRenameMarkerURL(
        workshopRoot: root.appendingPathComponent("workshop", isDirectory: true))
}

@Suite("P2-1: execution record rename + dual read")
struct ExecutionRecordRenameTests {

    // (a) The pass renames, stamps its marker, and a second launch is a no-op.
    @Test("rename pass renames every legacy record, stamps the marker, and skips on re-run")
    func renamePassRenamesAndStampsThenSkips() throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try executionDir(root, "exec-a")
        let b = try executionDir(root, "exec-b")
        try writeString(recordBody(id: "exec-a"), to: ExecutionRecordFile.legacyPath(in: a))
        try writeString(recordBody(id: "exec-b"), to: ExecutionRecordFile.legacyPath(in: b))
        // A sibling file that is NOT the record must not move.
        try writeString("line\n", to: a.appendingPathComponent("timeline.jsonl"))

        #expect(!exists(migrationMarker(root)))
        let report = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)

        for dir in [a, b] {
            #expect(exists(ExecutionRecordFile.canonicalPath(in: dir)))
            #expect(!exists(ExecutionRecordFile.legacyPath(in: dir)))
        }
        #expect(try readString(ExecutionRecordFile.canonicalPath(in: a)).contains("\"exec-a\""))
        #expect(exists(a.appendingPathComponent("timeline.jsonl")))
        #expect(exists(migrationMarker(root)))
        #expect(report.didMigrate)
        // Full execution-relative paths on both sides, not bare filenames.
        #expect(report.moved.contains(
            "workshop/executions/exec-a/mission.json -> workshop/executions/exec-a/execution.json"))
        #expect(report.moved.contains(
            "workshop/executions/exec-b/mission.json -> workshop/executions/exec-b/execution.json"))

        // Re-run: marker present → the pass does not walk at all. Proven by
        // dropping a FRESH legacy record and seeing it survive untouched (a
        // non-skipping pass would rename it).
        let c = try executionDir(root, "exec-c")
        try writeString(recordBody(id: "exec-c"), to: ExecutionRecordFile.legacyPath(in: c))
        let second = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)
        #expect(!second.didMigrate)
        #expect(second.moved.isEmpty)
        #expect(exists(ExecutionRecordFile.legacyPath(in: c)))
        #expect(!exists(ExecutionRecordFile.canonicalPath(in: c)))
    }

    // (c) Both names present: canonical is authoritative, legacy is preserved
    // beside it (never deleted) and reported as a conflict.
    @Test("conflict: canonical wins, legacy is preserved aside and counted")
    func conflictPreservesLegacyBesideCanonical() throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try executionDir(root, "exec-conflict")
        try writeString(recordBody(id: "exec-conflict", status: "completed", title: "canonical"),
                        to: ExecutionRecordFile.canonicalPath(in: dir))
        try writeString(recordBody(id: "exec-conflict", status: "queued", title: "legacy"),
                        to: ExecutionRecordFile.legacyPath(in: dir))

        let report = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)

        // Canonical untouched.
        #expect(try readString(ExecutionRecordFile.canonicalPath(in: dir)).contains("\"canonical\""))
        // Legacy moved aside, not destroyed.
        #expect(!exists(ExecutionRecordFile.legacyPath(in: dir)))
        let aside = dir.appendingPathComponent("mission.json.premigration-conflict")
        #expect(exists(aside))
        #expect(try readString(aside).contains("\"legacy\""))
        // The receipt must name the EXECUTION, not just the bare filename.
        #expect(report.conflictsPreservedInArchive
            .contains("workshop/executions/exec-conflict/mission.json"),
            "conflicts: \(report.conflictsPreservedInArchive)")
        // resolve() picks canonical, and the aside file is not a record name.
        #expect(ExecutionRecordFile.resolve(in: dir).lastPathComponent == "execution.json")
    }

    // (d) The orphan lock sidecar is removed ONLY where the record itself moved.
    @Test("orphan mission.json.lock removed only where the record was renamed")
    func orphanLockRemovedOnlyForRenamedRecords() throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let renamed = try executionDir(root, "exec-renamed")
        try writeString(recordBody(id: "exec-renamed"), to: ExecutionRecordFile.legacyPath(in: renamed))
        let renamedLock = renamed.appendingPathComponent("mission.json.lock")
        try writeString("", to: renamedLock)

        // Conflict dir: the record did NOT move into place, so its legacy lock
        // is NOT provably orphaned and must survive.
        let conflicted = try executionDir(root, "exec-conflicted")
        try writeString(recordBody(id: "exec-conflicted"),
                        to: ExecutionRecordFile.canonicalPath(in: conflicted))
        try writeString(recordBody(id: "exec-conflicted"),
                        to: ExecutionRecordFile.legacyPath(in: conflicted))
        let conflictedLock = conflicted.appendingPathComponent("mission.json.lock")
        try writeString("", to: conflictedLock)

        // Untouched dir: already canonical, nothing to rename, lock left alone.
        let canonical = try executionDir(root, "exec-canonical")
        try writeString(recordBody(id: "exec-canonical"),
                        to: ExecutionRecordFile.canonicalPath(in: canonical))
        let canonicalLock = canonical.appendingPathComponent("execution.json.lock")
        try writeString("", to: canonicalLock)

        _ = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)

        #expect(!exists(renamedLock), "the renamed record's legacy lock is orphaned and must go")
        #expect(exists(conflictedLock), "a conflict did not move the record — leave its lock alone")
        #expect(exists(canonicalLock), "the live canonical lock must never be reaped")
    }

    // The pass must run on the FAST path — an install that already stamped
    // pointer normalization (so `missions/` is long gone) still gets renamed.
    @Test("rename runs on the fast path, after pointer normalization already completed")
    func renameRunsOnFastPathAfterPointerNormalizationStamped() throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try executionDir(root, "exec-fast")
        try writeString(recordBody(id: "exec-fast"), to: ExecutionRecordFile.legacyPath(in: dir))
        // Pre-stamp the pointer marker only — the old fast path would have
        // returned immediately here and never looked at the record name.
        let workshopRoot = root.appendingPathComponent("workshop", isDirectory: true)
        try writeString("done", to: workshopRoot
            .appendingPathComponent("migrations/pointer_normalization_v1.done"))
        #expect(WorkshopStorageMigrator.pointerNormalizationCompleted(
            workshopRoot: workshopRoot, fileManager: .default))

        let report = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)

        #expect(exists(ExecutionRecordFile.canonicalPath(in: dir)))
        #expect(!exists(ExecutionRecordFile.legacyPath(in: dir)))
        #expect(report.didMigrate)
    }

    // (e) Existence probes must classify a legacy-only directory as a record
    // directory. This is the misreading that silently drops work.
    @Test("existence probes accept EITHER record name")
    func existenceProbesAcceptBothNames() throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyOnly = try executionDir(root, "legacy-only")
        try writeString(recordBody(id: "legacy-only"), to: ExecutionRecordFile.legacyPath(in: legacyOnly))
        let canonicalOnly = try executionDir(root, "canonical-only")
        try writeString(recordBody(id: "canonical-only"),
                        to: ExecutionRecordFile.canonicalPath(in: canonicalOnly))
        let empty = try executionDir(root, "reservation")

        #expect(ExecutionRecordFile.exists(in: legacyOnly))
        #expect(ExecutionRecordFile.exists(in: canonicalOnly))
        #expect(!ExecutionRecordFile.exists(in: empty))

        // resolve() falls back for the unmigrated dir, prefers canonical
        // otherwise, and hands a fresh write the canonical name.
        #expect(ExecutionRecordFile.resolve(in: legacyOnly).lastPathComponent == "mission.json")
        #expect(ExecutionRecordFile.resolve(in: canonicalOnly).lastPathComponent == "execution.json")
        #expect(ExecutionRecordFile.resolve(in: empty).lastPathComponent == "execution.json")
    }

    // (b) Dual read end-to-end: an unmigrated directory reads, patches and
    // cancels through the runner exactly like a migrated one — and the RMW
    // rewrites the file IN PLACE rather than silently forking a second record.
    @Test("runner get/update/cancel work against a legacy-named record")
    func runnerDualReadsAndRewritesLegacyRecordInPlace() async throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try executionDir(root, "legacy-live")
        let legacy = ExecutionRecordFile.legacyPath(in: dir)
        try writeString(recordBody(id: "legacy-live"), to: legacy)

        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            persistence: SwiftNativePersistenceCore(),
            planner: RenameTestPlannerLLM()
        )

        // get
        let got = await runner.getWorkshopExecution("legacy-live")
        #expect(got?.id == "legacy-live")
        #expect(got?.status == "queued")
        #expect(await runner.getWorkshopExecutionWireJSON("legacy-live") != nil)

        // listAll / scanAll see it too.
        let listed = await runner.listAll()
        #expect(listed.map(\.id).contains("legacy-live"))

        // update (RMW under the flock)
        let patched = try await runner.updateWorkshopExecution(
            WorkshopExecutionUpdate(id: "legacy-live", title: "patched"))
        #expect(patched?.title == "patched")
        #expect(exists(legacy), "the RMW must rewrite the legacy file in place")
        #expect(!exists(ExecutionRecordFile.canonicalPath(in: dir)),
                "dual-read must not fork a second record under the canonical name")
        #expect(try readString(legacy).contains("patched"))

        // cancel
        let cancelled = try await runner.cancel(executionId: "legacy-live")
        #expect(cancelled.status == "cancelled")
        #expect(await runner.getWorkshopExecution("legacy-live")?.status == "cancelled")
        #expect(exists(legacy))
        #expect(!exists(ExecutionRecordFile.canonicalPath(in: dir)))
    }

    // New writes land on the canonical name even in a root that also holds an
    // unmigrated sibling — resolve() on the fresh empty dir yields canonical.
    @Test("submit writes the canonical name alongside an unmigrated sibling")
    func submitWritesCanonicalName() async throws {
        let root = try renameTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try executionDir(root, "stale-legacy")
        try writeString(recordBody(id: "stale-legacy"), to: ExecutionRecordFile.legacyPath(in: stale))

        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            persistence: SwiftNativePersistenceCore(),
            planner: RenameTestPlannerLLM()
        )
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        let fresh = root.appendingPathComponent(
            "workshop/executions/\(result.executionId)", isDirectory: true)
        #expect(exists(ExecutionRecordFile.canonicalPath(in: fresh)))
        #expect(!exists(ExecutionRecordFile.legacyPath(in: fresh)))
        // The unmigrated sibling is untouched and still readable.
        #expect(exists(ExecutionRecordFile.legacyPath(in: stale)))
        #expect(await runner.getWorkshopExecution("stale-legacy") != nil)
    }
}

/// Empty-plan planner: submit() succeeds and lands `queued` without any
/// network or provider dependency.
private final class RenameTestPlannerLLM: WorkshopPlannerLLM, @unchecked Sendable {
    let directProviderCallCountPerInvocation: Int? = 1
    func availableConnectorActions() async -> [JSONValue] { [] }
    func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws
        -> (model: String, output: String) {
        ("test-model", "{\"steps\":[]}")
    }
}
