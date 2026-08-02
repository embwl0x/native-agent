import Foundation
import Testing
@testable import DoctorChecks
import PersistenceCore

/// Doctor must SAY when an op-log feed is wedged (gpt-5.5 review 2026-08-02,
/// finding 3).
///
/// THE BUG THESE PIN: the three snapshot+tail stores refuse to compact while
/// any row is undecodable — correct, but the refusal was reported only on
/// stderr, which in a GUI app goes nowhere, plus a couple of APIs nothing
/// called. One row from a newer build could therefore wedge compaction for
/// weeks while every append replayed a longer feed, and the first symptom would
/// be "the desk feels slow". PRE-FIX there was no `op_log_health` check at all,
/// so every assertion below fails.
@Suite("Doctor op-log health check", .serialized)
struct OpLogHealthCheckTests {

    private func root(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-oplog-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendRawLine(_ line: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: Data())
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// A fresh install has no feed files at all. That is healthy — ok, not a
    /// missing-file failure.
    @Test func freshInstallIsOK() async throws {
        let dir = try root("fresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await OpLogHealthCheck(root: dir).run()
        #expect(result.id == "op_log_health")
        #expect(result.status == "ok")
    }

    /// A desk feed with one row this build cannot decode: compaction is
    /// blocked, and Doctor says so with a repair hint that names the cause
    /// (a version-skewed binary), not a generic "try again".
    @Test func anUndecodableDeskRowIsReportedAsAFailure() async throws {
        let dir = try root("blocked")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus())
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "real item")
        try appendRawLine(
            #"{"opId":"future-1","ts":"2026-08-02T00:00:00.000000Z","op":"set_moon_phase","handle":"h1"}"#,
            to: store.opsPath
        )

        let result = await OpLogHealthCheck(root: dir).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("COMPACTION BLOCKED"))
        #expect(result.detail.contains("DeskStore"))
        #expect(result.repair?.isEmpty == false)
        // The feed SIZE is in the report too — "blocked" matters because the
        // feed can only grow while it lasts.
        #expect(result.detail.contains("row(s)"))
    }

    /// A malformed line in the task-ledger feed is the same class of finding
    /// through a different store, and must not be masked by the desk being fine.
    @Test func aMalformedTaskLedgerLineIsReportedAsAFailure() async throws {
        let dir = try root("ledger")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = SwiftNativeTaskLedger(dataRoot: dir)
        _ = try await ledger.append(
            TaskLedgerEvent(taskId: "t1", actor: .claude, kind: .created, title: "real")
        )
        try appendRawLine("}{ half a line a crash left behind", to: ledger.eventsPath)

        let result = await OpLogHealthCheck(root: dir).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("TaskLedger"))
    }

    /// Every feed decodable → ok, and all three feeds are named so the check
    /// reads as a real inventory rather than a single-store probe.
    @Test func healthyFeedsReportOKAndNameEveryFeed() async throws {
        let dir = try root("healthy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus())
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "real item")
        let ledger = SwiftNativeTaskLedger(dataRoot: dir)
        _ = try await ledger.append(
            TaskLedgerEvent(taskId: "t1", actor: .claude, kind: .created, title: "real")
        )

        let result = await OpLogHealthCheck(root: dir).run()
        #expect(result.status == "ok")
        #expect(result.detail.contains("DeskStore"))
        #expect(result.detail.contains("TaskLedger"))
        #expect(result.detail.contains("GitHubCommandStore"))
    }

    /// The check is wired into the default Doctor run — an unregistered check
    /// reports nothing at all, which is the state finding 3 described.
    @Test func theCheckIsRegisteredInTheDefaultDoctorRun() async throws {
        // The DEFAULT check list — not one we hand it. An unregistered check
        // returns nil here, which is exactly the "nothing reports this" state
        // finding 3 described. Read-only: the check only reads feed files.
        let byId = try await SwiftNativeDoctorChecks().runCheck(id: "op_log_health", repair: false)
        #expect(byId != nil)
        #expect(byId?.title == "Op-Log Health")
    }
}
