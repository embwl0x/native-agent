import Foundation
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Feeds reports-only wave 4 Claude", .serialized)
struct FeedsReportsOnlyWave4ClaudeTests {
    @Test("feeds.from_claude resumes its canonical session in its original cwd and trims only completed audit envelopes")
    func claudePersistentSessionAndAuditRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feeds-wave4-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("invocations.log")
        let fake = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '%s|%s\\n' \"$PWD\" \"$*\" >> '\(log.path)'\necho reply\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN", fake.path, 1)
        defer { unsetenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN") }

        _ = try await SwiftToolDispatcher.runInvokeClaude(input: ["text": .string("first"), "cwd": .string(root.path)], dataRoot: root)
        let pointer = root.appendingPathComponent("from_claude/agent_session.txt")
        let pointerLines = try String(contentsOf: pointer, encoding: .utf8).split(separator: "\n").map(String.init)
        let sessionID = try #require(pointerLines.first)
        #expect(pointerLines.dropFirst().first == root.path)
        #expect(pointerLines.dropFirst(2).first == root.standardizedFileURL.path)

        let differentCWD = root.appendingPathComponent("must-not-replace-session-cwd")
        try FileManager.default.createDirectory(at: differentCWD, withIntermediateDirectories: true)
        _ = try await SwiftToolDispatcher.runInvokeClaude(input: ["text": .string("second"), "cwd": .string(differentCWD.path)], dataRoot: root)
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("|") }
        #expect(calls.count == 2)
        #expect(calls[0].contains("--session-id \(sessionID)"))
        #expect(calls[1].contains("\(root.lastPathComponent)|"))
        #expect(!calls[1].contains(differentCWD.lastPathComponent + "|"))
        #expect(calls[1].contains("--resume \(sessionID)"))

        try "foreign-session\n\(root.path)\n/another/data/root".write(to: pointer, atomically: true, encoding: .utf8)
        _ = try await SwiftToolDispatcher.runInvokeClaude(input: ["text": .string("replace foreign"), "cwd": .string(root.path)], dataRoot: root)
        let replacedPointer = try String(contentsOf: pointer, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(replacedPointer.first != "foreign-session")
        #expect(replacedPointer.dropFirst(2).first == root.standardizedFileURL.path)
        let replacementCall = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { $0.contains("|") }.last
        #expect(replacementCall?.contains("--session-id") == true)
        #expect(replacementCall?.contains("--resume foreign-session") == false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0...Self.extraAudits {
                group.addTask {
                    _ = try await SwiftToolDispatcher.runInvokeClaude(
                        input: ["text": .string("retain \(index)"), "cwd": .string(root.path)],
                        dataRoot: root
                    )
                }
            }
            try await group.waitForAll()
        }
        let auditDir = root.appendingPathComponent("from_claude")
        let audits = try FileManager.default.contentsOfDirectory(at: auditDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(audits.count == SwiftToolDispatcher.agentBridgeAuditRetention)
        #expect(FileManager.default.fileExists(atPath: pointer.path), "audit trim must not remove the persistent-session pointer")
    }

    private static let extraAudits = SwiftToolDispatcher.agentBridgeAuditRetention
}
