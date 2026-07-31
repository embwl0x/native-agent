import Testing
import Foundation
import Darwin
@testable import DoctorChecks
import NativeAgentCore
import PersonaEngine
import PersistenceCore

// MARK: - Helpers

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctor-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func waitUntilExit(_ process: Process, timeout: TimeInterval) -> Bool {
    guard process.isRunning else { return true }
    let done = DispatchSemaphore(value: 0)
    let priorHandler = process.terminationHandler
    process.terminationHandler = { proc in
        priorHandler?(proc)
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .success {
        return true
    }
    return !process.isRunning
}

private struct StubCheck: DoctorCheck {
    let id: String
    let title: String
    let status: String
    let detail: String
    init(id: String, status: String = "ok", detail: String = "stub") {
        self.id = id
        self.title = "stub-\(id)"
        self.status = status
        self.detail = detail
    }
    func run() async -> CheckResult {
        CheckResult(id: id, title: title, status: status, detail: detail, repair: nil)
    }
}

private struct RepairableStubCheck: RepairingDoctorCheck {
    let id: String
    let title: String
    func run(repair: Bool) async -> CheckResult {
        CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: repair ? "repaired" : "checked",
            repair: repair ? "repair action ran" : nil
        )
    }
}

/// Check whose body could throw but catches internally and returns "fail".
/// Pins that DoctorCheck.run() is non-throwing and that SwiftNativeDoctorChecks
/// surfaces a "fail" status without propagating.
private struct InternallyFailingCheck: DoctorCheck {
    let id = "boom"
    let title = "Boom"
    func run() async -> CheckResult {
        // Simulate a body that "tried" something and caught — never throws.
        let pretendError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "synthetic"])
        return CheckResult(id: id, title: title, status: "fail", detail: "Could not prepare app storage: \(pretendError.localizedDescription)", repair: nil)
    }
}

// MARK: - Factory

@Test func placeholderFactoryReturnsSwiftNative() async throws {
    let impl = makeDoctorChecks()
    #expect(impl is SwiftNativeDoctorChecks)
}

// MARK: - StorageCheck

@Test func storageCheck_returns_ok_for_existing_writable_root() async {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let check = StorageCheck(root: root)
    let result = await check.run()
    #expect(result.status == "ok")
    #expect(result.id == "storage")
    #expect(result.title == "App Storage")
}

@Test func storageCheck_returns_fail_for_unwritable_root() async {
    // A regular file used as a "root" — createDirectory will fail because
    // the path already exists as a non-directory. Reliable cross-FS way to
    // force the failure branch without relying on chmod semantics.
    let parent = tempDir()
    defer { try? FileManager.default.removeItem(at: parent) }
    let bogus = parent.appendingPathComponent("not-a-dir")
    try? Data("blocker".utf8).write(to: bogus)
    let check = StorageCheck(root: bogus)
    let result = await check.run()
    #expect(result.status == "fail")
    #expect(result.detail.hasPrefix("Could not prepare app storage: "))
}

@Test func storageCheck_detail_format_matches_python() async {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let check = StorageCheck(root: root)
    let result = await check.run()
    #expect(result.detail == "App data is available at \(root.path)")
    #expect(result.repair == nil)
}

@Test func storageCheck_returns_fail_when_subdir_blocked_by_file() async {
    // Plant a regular file at one of the subdir paths ensureDirs needs to
    // create (e.g. "logs"). createDirectory at that path will fail because
    // it already exists as a non-directory, forcing the check to status="fail".
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = root.appendingPathComponent("logs")
    try? Data("blocker".utf8).write(to: blocker)
    let result = await StorageCheck(root: root).run()
    #expect(result.status == "fail")
    #expect(result.detail.hasPrefix("Could not prepare app storage: "))
}

@Test func storageCheck_creates_root_if_missing() async {
    let parent = tempDir()
    defer { try? FileManager.default.removeItem(at: parent) }
    let missing = parent.appendingPathComponent("does-not-exist-yet")
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    let result = await StorageCheck(root: missing).run()
    #expect(result.status == "ok")
    #expect(FileManager.default.fileExists(atPath: missing.path))
}

@Test func storageCheck_creates_workshop_tree_without_retired_executions_root() async {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let result = await StorageCheck(root: root).run()

    #expect(result.status == "ok")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("workshop/executions").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("workshop/migrations").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missions").path))
}

// MARK: - ChatSessionsCheck

@Test func chatSessionsCheck_returns_ok_with_count() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    let sessions: [[String: Any]] = [
        ["id": "s1", "title": "A"],
        ["id": "s2", "title": "B"],
        ["id": "s3", "title": "C"],
    ]
    let data = try JSONSerialization.data(withJSONObject: sessions, options: [])
    try data.write(to: chatDir.appendingPathComponent("sessions.json"))
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "ok")
    #expect(result.id == "chat_sessions")
    #expect(result.title == "Persistent Chat Sessions")
    #expect(result.detail == "Chat session storage is available with 3 session(s).")
    #expect(result.repair == nil)
}

@Test func chatSessionsCheck_invalid_json_returns_fail() async throws {
    // Audit fix 2026-06-10: a garbage payload is store corruption, not a
    // fresh install — it must trip status=fail (the old behavior swallowed
    // every failure into ok/0, hiding real data loss).
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    try Data("not json at all".utf8).write(to: chatDir.appendingPathComponent("sessions.json"))
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "fail")
    #expect(result.detail.hasPrefix("Chat session store failed: "))
    #expect(result.repair != nil)
}

@Test func chatSessionsCheck_non_list_json_returns_fail() async throws {
    // Valid JSON that is not a list (e.g. an object) is the wrong shape for
    // the sessions store — fail, not silent ok/0.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    try Data("{\"id\": \"s1\"}".utf8).write(to: chatDir.appendingPathComponent("sessions.json"))
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "fail")
    #expect(result.detail.contains("not a JSON list"))
}

@Test func chatSessionsCheck_empty_file_returns_fail() async throws {
    // An empty file is not valid JSON (torn write / truncation), so it is
    // corruption — distinct from a MISSING file, which stays ok/0.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    try Data().write(to: chatDir.appendingPathComponent("sessions.json"))
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "fail")
    #expect(result.detail.contains("empty"))
}

@Test func chatSessionsCheck_mixed_validity_counts_only_dicts_with_id() async throws {
    // Regression for daemon parity: list_chat_sessions skips non-dicts and
    // dicts missing a non-empty `id` before len(). Payload [{}, {"id":"s1"}, "bad"]
    // must count as 1, not 3.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    let mixed: [Any] = [[:] as [String: Any], ["id": "s1"], "bad"]
    let data = try JSONSerialization.data(withJSONObject: mixed, options: [])
    try data.write(to: chatDir.appendingPathComponent("sessions.json"))
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "ok")
    #expect(result.detail == "Chat session storage is available with 1 session(s).")
}

@Test func chatSessionsCheck_directory_at_path_returns_fail() async throws {
    // Audit fix 2026-06-10: a directory at the sessions.json path means the
    // store is unreadable — fail, not silent ok/0.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: chatDir.appendingPathComponent("sessions.json"),
        withIntermediateDirectories: true
    )
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "fail")
    #expect(result.detail.contains("directory"))
    #expect(result.repair != nil)
}

@Test func chatSessionsCheck_missing_file_stays_ok_zero() async throws {
    // Fresh install: chat/ exists but sessions.json was never written —
    // this is the ONE absence case that stays ok/0.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    let result = await ChatSessionsCheck(root: root).run()
    #expect(result.status == "ok")
    #expect(result.detail == "Chat session storage is available with 0 session(s).")
    #expect(result.repair == nil)
}

@Test func chatSessionsCheck_detail_format_matches_python() async throws {
    // Empty root -> 0 sessions (preserves retired read_json(path, []) behavior).
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zero = await ChatSessionsCheck(root: root).run()
    #expect(zero.status == "ok")
    #expect(zero.detail == "Chat session storage is available with 0 session(s).")
    // One session.
    let chatDir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
    let oneData = try JSONSerialization.data(withJSONObject: [["id": "x"]], options: [])
    try oneData.write(to: chatDir.appendingPathComponent("sessions.json"))
    let one = await ChatSessionsCheck(root: root).run()
    #expect(one.detail == "Chat session storage is available with 1 session(s).")
}

// MARK: - PersonaEngineCheck

@Test func personaEngineCheck_returns_ok_when_SOUL_present() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("you are SOUL".utf8).write(to: root.appendingPathComponent("SOUL.md"))
    try Data("user".utf8).write(to: root.appendingPathComponent("USER.md"))
    let engine = SwiftNativePersonaEngine(root: root)
    let check = PersonaEngineCheck(engineProvider: { engine })
    let result = await check.run()
    #expect(result.status == "ok")
    #expect(result.id == "persona_engine")
    #expect(result.title == "Persona Engine 2.0")
    #expect(result.repair == nil)
    #expect(result.detail.hasPrefix("Persona docs loaded ("))
}

@Test func personaEngineCheck_returns_fail_when_SOUL_absent() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // Persona dir exists with non-SOUL docs only.
    try Data("user".utf8).write(to: root.appendingPathComponent("USER.md"))
    let engine = SwiftNativePersonaEngine(root: root)
    let check = PersonaEngineCheck(engineProvider: { engine })
    let result = await check.run()
    #expect(result.status == "fail")
    #expect(result.detail.hasPrefix("Persona compiler failed: "))
    #expect(result.repair == "Run Repair Safe Issues to normalize the personality profile.")
}

@Test func personaEngineCheck_repair_seeds_missing_docs() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = SwiftNativePersonaEngine(root: root)
    let check = PersonaEngineCheck(engineProvider: { engine })
    let result = await check.run(repair: true)
    #expect(result.status == "ok")
    #expect(result.repair?.contains("SOUL.md") == true)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("USER.md").path))
}

@Test func personaEngineCheck_documents_divergence_from_daemon_check() async throws {
    // The Swift check verifies docs LOAD; the daemon check COMPILES the
    // personality packet. The detail wording must say "docs loaded" — never
    // "compiled" — so operators can't mistake one for the other.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("you are SOUL".utf8).write(to: root.appendingPathComponent("SOUL.md"))
    let engine = SwiftNativePersonaEngine(root: root)
    let check = PersonaEngineCheck(engineProvider: { engine })
    let result = await check.run()
    #expect(result.status == "ok")
    #expect(result.detail.contains("docs loaded"))
    #expect(!result.detail.contains("compiled"))
    #expect(!result.detail.contains("fingerprint"))
}

// MARK: - RuntimeJSONStoresCheck

@Test func runtimeJSONStoresCheck_warns_when_missing_and_repairs_defaults() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = await RuntimeJSONStoresCheck(root: root).run(repair: false)
    #expect(before.status == "warn")
    #expect(before.detail.contains("missing"))

    let after = await RuntimeJSONStoresCheck(root: root).run(repair: true)
    #expect(after.status == "ok")
    #expect(after.repair != nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("providers/active.json").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("scheduler/jobs.json").path))
}

@Test func runtimeJSONStoresCheck_repairs_malformed_store_with_backup() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("providers/active.json")
    try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: active)

    let before = await RuntimeJSONStoresCheck(root: root).run(repair: false)
    #expect(before.status == "fail")

    let after = await RuntimeJSONStoresCheck(root: root).run(repair: true)
    #expect(after.status == "ok")
    #expect(after.repair?.contains("reset providers/active.json") == true)
    let repaired = try JSONValue.parse(Data(contentsOf: active))
    if case .object(let obj) = repaired {
        #expect(obj.isEmpty)
    } else {
        Issue.record("providers/active.json should repair to object")
    }
    let backups = try FileManager.default.contentsOfDirectory(atPath: active.deletingLastPathComponent().path)
        .filter { $0.hasPrefix("active.json.doctor-bak-") }
    #expect(!backups.isEmpty)
}

@Test func runtimeJSONStoresCheck_repair_fails_when_directory_blocks_store() async throws {
    // Audit fix 2026-06-10: a directory at a store path gets NO repair (Doctor
    // will not delete directories), so the repair summary must NOT claim
    // "valid after repair" while it remains — it must fail naming the leftover.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("providers/active.json"),
        withIntermediateDirectories: true
    )
    let after = await RuntimeJSONStoresCheck(root: root).run(repair: true)
    #expect(after.status == "fail")
    #expect(after.detail.contains("providers/active.json"))
    #expect(after.detail.contains("directory"))
    // The other (missing) stores were still created and reported.
    #expect(after.repair?.contains("created") == true)
}

// MARK: - ChatMessagesIntegrityCheck

@Test func chatMessagesIntegrityCheck_repairs_malformed_jsonl_rows() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("chat/messages", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("s1.jsonl")
    try Data("{\"role\":\"user\"}\nnot-json\n{\"role\":\"assistant\"}\n".utf8).write(to: file)

    let before = await ChatMessagesIntegrityCheck(root: root).run(repair: false)
    #expect(before.status == "fail")

    let after = await ChatMessagesIntegrityCheck(root: root).run(repair: true)
    #expect(after.status == "ok")
    #expect(after.repair?.contains("s1.jsonl") == true)
    let repaired = try String(contentsOf: file, encoding: .utf8)
    #expect(repaired.contains("\"user\""))
    #expect(repaired.contains("\"assistant\""))
    #expect(!repaired.contains("not-json"))
    let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("s1.jsonl.doctor-bak-") }
    #expect(!backups.isEmpty)
}

// MARK: - Memory / bridge / bundle checks

// M5 (2026-07-09): MemoryStoreCheck no longer validates or "repairs" the dead
// knowledge_graph.json fallback — the graph lives in memory.sqlite. These tests
// pin the two honesty properties the old shape violated: it must never write a
// KG JSON file nobody reads, and it must actually open the database.

@Test func memoryStoreCheck_missing_sqlite_warns_and_writes_nothing() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await MemoryStoreCheck(root: root).run()
    #expect(result.status == "warn")
    #expect(result.detail.contains("memory.sqlite missing"))
    // The old check "repaired" a healthy machine by creating this file.
    let kg = root.appendingPathComponent("memory/knowledge_graph.json")
    #expect(!FileManager.default.fileExists(atPath: kg.path))
}

@Test func memoryStoreCheck_unreadable_sqlite_fails_loud() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    // Non-empty, present, and not a SQLite database: the check must OPEN it and
    // report the failure, not shrug because some JSON file happens to be fine.
    try Data("this is not a sqlite database".utf8)
        .write(to: memoryDir.appendingPathComponent("memory.sqlite"))
    try Data(#"{"entities":{},"relationships":[]}"#.utf8)
        .write(to: memoryDir.appendingPathComponent("knowledge_graph.json"))

    let result = await MemoryStoreCheck(root: root).run()
    #expect(result.status == "fail")
    #expect(result.detail.contains("Knowledge graph tables in memory.sqlite could not be read"))
    #expect(result.repair == nil)
}

@Test func iCloudBridgeStateCheck_repair_creates_bridge_dirs() async throws {
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let docs = root.appendingPathComponent("Documents", isDirectory: true)
    let result = await ICloudBridgeStateCheck(docsURLProvider: { docs }).run(repair: true)
    #expect(result.status == "ok")
    #expect(result.repair?.contains("outbox/mac") == true)
    #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("outbox/mac").path))
    #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("snapshots").path))
    #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("inbox/_rejected").path))
}

@Test func iCloudBridgeStateCheck_ok_when_iCloud_not_configured() async {
    // Public no-iCloud build (2026-07-04, 502b82b0 "silence false Doctor
    // warnings"): the DMG ships without an iCloud container on purpose, so an
    // unavailable container is EXPECTED and must NOT nag — report ok, not warn.
    // iCloudConfigured is passed explicitly so the assertion is hermetic and
    // doesn't depend on the ambient NATIVEAGENT_ICLOUD_CONTAINER_ID.
    let result = await ICloudBridgeStateCheck(
        docsURLProvider: { nil },
        iCloudConfigured: false
    ).run(repair: true)
    #expect(result.status == "ok")
    #expect(result.detail.contains("isn't part of this build"))
    #expect(result.repair == nil)
}

@Test func iCloudBridgeStateCheck_warns_when_configured_container_unavailable() async {
    // A build that DOES configure a real iCloud container but can't reach it
    // (not signed in / CLI lacks the iCloud entitlement) is a genuine problem —
    // warn and point the user at signing in from the signed Mac app.
    let result = await ICloudBridgeStateCheck(
        docsURLProvider: { nil },
        iCloudConfigured: true
    ).run(repair: true)
    #expect(result.status == "warn")
    #expect(result.detail.contains("unavailable"))
    #expect(result.repair != nil)
}

// MARK: - SwiftNativeDoctorChecks

@Test func swiftNative_runAll_default_includes_core_runtime_checks() async throws {
    let doctor = SwiftNativeDoctorChecks()
    let results = try await doctor.runAll(repair: false, checkLLM: false)
    let ids = results.map(\.id)
    #expect(ids.contains("storage"))
    #expect(ids.contains("runtime_json_stores"))
    #expect(ids.contains("chat_sessions"))
    #expect(ids.contains("chat_messages"))
    #expect(ids.contains("persona_engine"))
    #expect(ids.contains("memory_store"))
    #expect(ids.contains("coreml_embedder"))
    #expect(ids.contains("icloud_bridge_state"))
    #expect(results.count == 8)
}

@Test func swiftNative_runAll_repair_dispatches_to_repairable_checks() async throws {
    let doctor = SwiftNativeDoctorChecks(checks: [RepairableStubCheck(id: "storage", title: "Storage")])
    let results = try await doctor.runAll(repair: true, checkLLM: false)
    #expect(results.map(\.id) == ["storage"])
    #expect(results.last?.status == "ok")
    #expect(results.last?.detail == "repaired")
    #expect(results.last?.repair == "repair action ran")
}

@Test func swiftNative_runAll_returns_storage_check_only_by_default() async throws {
    // Pin that custom-checks injection bypasses the default 3-check set.
    let root = tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let doctor = SwiftNativeDoctorChecks(checks: [StorageCheck(root: root)])
    let results = try await doctor.runAll(repair: false, checkLLM: false)
    #expect(results.count == 1)
    #expect(results.first?.id == "storage")
}

@Test func swiftNative_runAll_with_custom_checks_runs_each_in_order() async throws {
    let doctor = SwiftNativeDoctorChecks(checks: [
        StubCheck(id: "a"),
        StubCheck(id: "b"),
        StubCheck(id: "c"),
    ])
    let results = try await doctor.runAll(repair: false, checkLLM: false)
    #expect(results.map(\.id) == ["a", "b", "c"])
}

@Test func swiftNative_runCheck_by_id_found() async throws {
    let doctor = SwiftNativeDoctorChecks(checks: [StubCheck(id: "x"), StubCheck(id: "y")])
    let result = try await doctor.runCheck(id: "y", repair: false)
    #expect(result?.id == "y")
}

@Test func swiftNative_runCheck_by_id_notFound() async throws {
    let doctor = SwiftNativeDoctorChecks(checks: [StubCheck(id: "x")])
    let result = try await doctor.runCheck(id: "nope", repair: false)
    #expect(result == nil)
}

@Test func swiftNative_runAll_concurrent_calls_are_actor_isolated() async throws {
    let doctor = SwiftNativeDoctorChecks(checks: [StubCheck(id: "a"), StubCheck(id: "b")])
    async let r1 = doctor.runAll(repair: false, checkLLM: false)
    async let r2 = doctor.runAll(repair: false, checkLLM: false)
    let (a, b) = try await (r1, r2)
    #expect(a.map(\.id) == ["a", "b"])
    #expect(b.map(\.id) == ["a", "b"])
}

@Test func swiftNative_internally_failing_check_returns_fail_does_not_throw() async throws {
    let doctor = SwiftNativeDoctorChecks(checks: [InternallyFailingCheck()])
    let results = try await doctor.runAll(repair: false, checkLLM: false)
    #expect(results.count == 1)
    #expect(results[0].status == "fail")
    #expect(results[0].id == "boom")
}

// MARK: - CheckResult Codable

@Test func checkResult_round_trips_via_Codable() throws {
    let original = CheckResult(id: "storage", title: "App Storage", status: "ok", detail: "ok detail", repair: "fix it")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CheckResult.self, from: data)
    #expect(decoded == original)
}

@Test func checkResult_round_trips_with_nil_repair() throws {
    let original = CheckResult(id: "x", title: "T", status: "warn", detail: "d", repair: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CheckResult.self, from: data)
    #expect(decoded == original)
    #expect(decoded.repair == nil)
}

