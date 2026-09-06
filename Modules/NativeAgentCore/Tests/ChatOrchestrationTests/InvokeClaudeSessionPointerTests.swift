import Foundation
import PersistenceCore
import Testing
@testable import ChatOrchestration

// The unresolved HIGH review note this closes: `invoke_claude`'s session
// pointer had NO lock, so two invokes in one process (a Mac-chat turn and a
// Telegram turn) could interleave its read-check-write. The live evidence was a
// `.stale-<ts>` rename-aside produced by one invoke's reset landing on a
// pointer another invoke had already replaced.
//
// These tests drive the REAL `runInvokeClaude` with a fake `claude` that
// mutates the pointer mid-run — the deterministic stand-in for a concurrent
// invoke — because a lock that is merely present proves nothing. What has to
// hold is that neither half of the lifecycle overwrites work the other half
// did not see.
@Suite("invoke_claude session pointer", .serialized)
struct InvokeClaudeSessionPointerTests {

    // MARK: - the lock itself

    @Test("the pointer lock serializes concurrent read-modify-write")
    func lockSerializes() async throws {
        let root = try temporaryDirectory("lock")
        let target = root.appendingPathComponent("pointer.txt")
        try "0".write(to: target, atomically: true, encoding: .utf8)
        // 24 racers, each read-sleep-write. Without mutual exclusion the sleep
        // guarantees lost updates; with it the count is exact.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    SwiftToolDispatcher.withSessionPointerLock(target) {
                        let current = Int((try? String(contentsOf: target, encoding: .utf8)) ?? "0") ?? 0
                        usleep(2_000)
                        try? "\(current + 1)".write(to: target, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        let final = Int(try String(contentsOf: target, encoding: .utf8))
        #expect(final == 24)
    }

    @Test("pointer id reads the first line, and nothing at all from an absent or empty file")
    func pointerIDReads() throws {
        let root = try temporaryDirectory("read")
        let missing = root.appendingPathComponent("missing.txt")
        #expect(SwiftToolDispatcher.sessionPointerSessionID(missing) == nil)
        let empty = root.appendingPathComponent("empty.txt")
        try "\n\n".write(to: empty, atomically: true, encoding: .utf8)
        #expect(SwiftToolDispatcher.sessionPointerSessionID(empty) == nil)
        let real = root.appendingPathComponent("real.txt")
        try "  SESSION-X  \n/some/cwd\n/data/root".write(to: real, atomically: true, encoding: .utf8)
        #expect(SwiftToolDispatcher.sessionPointerSessionID(real) == "SESSION-X")
    }

    // MARK: - the two halves, driven end to end

    @Test("a session-gone reset NEVER renames aside a pointer another invoke replaced")
    func resetSparesAReplacedPointer() async throws {
        let root = try temporaryDirectory("reset-race")
        let pointer = try writePointer(root, sessionID: "SESSION-A")
        // The fake claude stands in for the concurrent invoke: while "our" run
        // is in flight it heals the topic onto a fresh session, then our run
        // fails with the session-not-found marker. Our reset must not touch it.
        let claude = try fakeClaude(root, body: """
        printf 'SESSION-B\\n%s\\n%s\\n' "$PWD" "\(root.path)" > "\(pointer.path)"
        echo "Error: No conversation found with session ID SESSION-A" >&2
        exit 1
        """)
        let result = try await invoke(dataRoot: root, claude: claude, cwd: root.path)

        #expect(status(result) == "failed")
        #expect(SwiftToolDispatcher.sessionPointerSessionID(pointer) == "SESSION-B")
        #expect(staleSiblings(root).isEmpty, "the concurrent invoke's live thread was renamed aside")
    }

    @Test("CONTROL: a genuine session-gone reset still renames the pointer aside")
    func resetStillHealsAGoneSession() async throws {
        let root = try temporaryDirectory("reset-real")
        let pointer = try writePointer(root, sessionID: "SESSION-A")
        let claude = try fakeClaude(root, body: """
        echo "Error: No conversation found with session ID SESSION-A" >&2
        exit 1
        """)
        _ = try await invoke(dataRoot: root, claude: claude, cwd: root.path)

        #expect(!FileManager.default.fileExists(atPath: pointer.path))
        #expect(staleSiblings(root).count == 1, "a genuinely dead session must still self-heal aside")
    }

    @Test("a new session never clobbers a pointer another invoke established meanwhile")
    func newSessionDoesNotClobber() async throws {
        let root = try temporaryDirectory("new-race")
        let pointer = sessionPointer(root)
        // No pointer at read time, so this run mints a fresh id. The concurrent
        // invoke lands ITS pointer first; ours must leave that thread owning
        // the topic rather than orphaning it on last-writer-wins.
        let claude = try fakeClaude(root, body: """
        mkdir -p "\(pointer.deletingLastPathComponent().path)"
        printf 'SESSION-OTHER\\n%s\\n%s\\n' "$PWD" "\(root.path)" > "\(pointer.path)"
        echo "answered"
        """)
        let result = try await invoke(dataRoot: root, claude: claude, cwd: root.path)

        #expect(status(result) == "completed")
        #expect(SwiftToolDispatcher.sessionPointerSessionID(pointer) == "SESSION-OTHER")
    }

    @Test("CONTROL: a first successful run still pins its own fresh session")
    func newSessionStillPins() async throws {
        let root = try temporaryDirectory("new-pin")
        let claude = try fakeClaude(root, body: "echo answered")
        let result = try await invoke(dataRoot: root, claude: claude, cwd: root.path)

        #expect(status(result) == "completed")
        let pinned = SwiftToolDispatcher.sessionPointerSessionID(sessionPointer(root))
        #expect(pinned != nil && UUID(uuidString: pinned ?? "") != nil)
    }

    // MARK: - helpers

    private func invoke(dataRoot: URL, claude: URL, cwd: String) async throws -> JSONValue {
        setenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN", claude.path, 1)
        defer { unsetenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN") }
        return try await SwiftToolDispatcher.runInvokeClaude(
            input: ["text": .string("ping"), "cwd": .string(cwd), "timeout_seconds": .int(30)],
            dataRoot: dataRoot
        )
    }

    private func status(_ value: JSONValue) -> String? {
        guard case .object(let object) = value, case .string(let status)? = object["status"] else { return nil }
        return status
    }

    private func sessionPointer(_ root: URL) -> URL {
        root.appendingPathComponent("from_claude", isDirectory: true)
            .appendingPathComponent("agent_session.txt")
    }

    @discardableResult
    private func writePointer(_ root: URL, sessionID: String) throws -> URL {
        let pointer = sessionPointer(root)
        try FileManager.default.createDirectory(
            at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "\(sessionID)\n\(root.path)\n\(root.standardizedFileURL.path)"
            .write(to: pointer, atomically: true, encoding: .utf8)
        return pointer
    }

    private func staleSiblings(_ root: URL) -> [String] {
        let dir = root.appendingPathComponent("from_claude", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".stale-") }
    }

    private func fakeClaude(_ root: URL, body: String) throws -> URL {
        let script = root.appendingPathComponent("fake-claude.sh")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func temporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoke-claude-pointer-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
