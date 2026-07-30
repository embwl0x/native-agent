import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// M4 (honesty sweep, 2026-07-09): a corrupt trigger config used to collapse into
// `readJSON`'s default array — which the mutation path then WROTE BACK, silently
// replacing every trigger the user had configured with factory defaults, "for
// daemon parity" with a daemon that no longer exists. Corrupt now quarantines the
// bytes and throws; only a genuinely MISSING file may seed defaults.

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TriggerCorruptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeClient(root: URL) -> SwiftNativeTriggerScheduler {
    SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        workshopRunner: nil,
        now: { Date() },
        uuid: { UUID().uuidString.lowercased() },
        notifier: nil,
        worklogPath: root.appendingPathComponent("no-such-worklog.jsonl")
    )
}

private func inboxConfigPath(_ root: URL) -> URL {
    root.appendingPathComponent("inbox", isDirectory: true)
        .appendingPathComponent("trigger_config.json")
}

private func writeInboxConfig(_ contents: String, root: URL) throws -> URL {
    let path = inboxConfigPath(root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: path)
    return path
}

// MARK: - Classifier

@Test func readConfigsRaw_distinguishes_missing_corrupt_and_parsed() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let path = inboxConfigPath(root)
    if case .missing = SwiftNativeTriggerScheduler.readConfigsRaw(path) {} else {
        Issue.record("absent file must classify as .missing")
    }

    _ = try writeInboxConfig("", root: root)
    // gpt-5.5 review MED (2026-07-09): an EXISTING zero-byte file is a truncated
    // write — corrupt (quarantine), never .missing (which would reseed defaults
    // over what used to be the user's config).
    if case .corrupt = SwiftNativeTriggerScheduler.readConfigsRaw(path) {} else {
        Issue.record("zero-length EXISTING file must classify as .corrupt")
    }

    _ = try writeInboxConfig("{not json at all", root: root)
    if case .corrupt = SwiftNativeTriggerScheduler.readConfigsRaw(path) {} else {
        Issue.record("garbage must classify as .corrupt")
    }

    // Valid JSON that is not an ARRAY is still unusable as a config list.
    _ = try writeInboxConfig(#"{"name":"x"}"#, root: root)
    if case .corrupt = SwiftNativeTriggerScheduler.readConfigsRaw(path) {} else {
        Issue.record("non-array JSON must classify as .corrupt")
    }

    _ = try writeInboxConfig(#"[{"name":"morning_brief","enabled":false}]"#, root: root)
    guard case .parsed(let items) = SwiftNativeTriggerScheduler.readConfigsRaw(path) else {
        Issue.record("well-formed array must classify as .parsed")
        return
    }
    #expect(items.count == 1)
}

// MARK: - The destruction this closes

@Test func enableInboxTrigger_on_corrupt_config_quarantines_and_throws() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let corruptBytes = #"[{"name":"morning_brief","enabled":true},,,BROKEN"#
    let path = try writeInboxConfig(corruptBytes, root: root)

    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await makeClient(root: root).enableInboxTrigger(name: "morning_brief")
    }

    // The user's bytes were NOT overwritten with defaults...
    #expect(!FileManager.default.fileExists(atPath: path.path))
    // ...they were moved aside intact, where they can be recovered.
    let siblings = try FileManager.default.contentsOfDirectory(
        atPath: path.deletingLastPathComponent().path
    ).filter { $0.contains("trigger_config.json.corrupt-") }
    #expect(siblings.count == 1)
    let asideURL = path.deletingLastPathComponent().appendingPathComponent(siblings[0])
    #expect(try String(contentsOf: asideURL, encoding: .utf8) == corruptBytes)
}

@Test func configureInboxTrigger_on_corrupt_config_throws_and_writes_no_defaults() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = try writeInboxConfig("this is not JSON", root: root)

    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await makeClient(root: root).configureInboxTrigger(
            name: "morning_brief", config: .object(["hour": .int(7)])
        )
    }
    // No resurrected default config took the corrupt file's place.
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func enableInboxTrigger_on_missing_config_still_seeds_defaults() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A genuinely fresh install: defaults ARE the right answer here, and this is
    // the case the corrupt path must never be confused with.
    let status = try await makeClient(root: root).enableInboxTrigger(name: "morning_brief")
    #expect(status.status == "updated")
    #expect(FileManager.default.fileExists(atPath: inboxConfigPath(root).path))
}

@Test func enableInboxTrigger_on_healthy_config_preserves_user_rows() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeInboxConfig(
        #"[{"name":"morning_brief","enabled":false},{"name":"users_custom","enabled":false}]"#,
        root: root
    )
    let status = try await makeClient(root: root).enableInboxTrigger(name: "users_custom")
    #expect(status.status == "updated")

    let data = try Data(contentsOf: inboxConfigPath(root))
    guard case .array(let rows) = try JSONValue.parse(data) else {
        Issue.record("config should still be an array")
        return
    }
    // The custom row survived — defaults did not replace it.
    #expect(rows.count == 2)
    let names: [String] = rows.compactMap {
        guard case .object(let o) = $0, case .string(let n)? = o["name"] else { return nil }
        return n
    }
    #expect(names.contains("users_custom"))
}
