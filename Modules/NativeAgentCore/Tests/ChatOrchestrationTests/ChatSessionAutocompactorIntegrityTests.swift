import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

@testable import ChatOrchestration

@Suite("Chat transcript autocompaction integrity")
struct ChatSessionAutocompactorIntegrityTests {
    @Test("mixed valid and malformed JSONL fails closed without rewriting")
    func mixedMalformedTranscriptIsPreserved() async throws {
        let fixture = try Fixture(name: "mixed-malformed")
        let validRow = try row(role: "user", content: String(repeating: "context ", count: 40))
        let original = validRow + Data("{malformed\n".utf8) + validRow
        try original.write(to: fixture.messagesURL)

        await #expect(throws: Error.self) {
            _ = try await fixture.compactor().compactIfNeeded(
                sessionId: fixture.sessionID,
                model: "gpt-5.6",
                surface: "chat",
                runId: nil
            )
        }

        #expect(try Data(contentsOf: fixture.messagesURL) == original)
        #expect(try fixture.backupFiles().isEmpty)
    }

    @Test("backup failure aborts compaction without rewriting")
    func backupFailurePreservesTranscript() async throws {
        let fixture = try Fixture(name: "backup-failure")
        let original = try (0..<4).reduce(into: Data()) { payload, index in
            payload.append(try row(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: String(repeating: "message-\(index) ", count: 40)
            ))
        }
        try original.write(to: fixture.messagesURL)

        let compactor = fixture.compactor { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        await #expect(throws: Error.self) {
            _ = try await compactor.compactIfNeeded(
                sessionId: fixture.sessionID,
                model: "gpt-5.6",
                surface: "chat",
                runId: nil
            )
        }

        #expect(try Data(contentsOf: fixture.messagesURL) == original)
        #expect(try fixture.backupFiles().isEmpty)
    }

    private func row(role: String, content: String) throws -> Data {
        var data = Data(try JSONValue.object([
            "role": .string(role),
            "content": .string(content),
        ]).serialize(pretty: false).utf8)
        data.append(0x0A)
        return data
    }

    private struct Fixture {
        let root: URL
        let sessionID: String
        let messagesURL: URL

        init(name: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nativeagent-autocompactor-\(name)-\(UUID().uuidString)", isDirectory: true)
            sessionID = "session-\(name)"
            messagesURL = root
                .appendingPathComponent("chat/messages", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            try FileManager.default.createDirectory(
                at: messagesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        func compactor(
            backupFileCopy: @escaping ChatSessionAutocompactor.BackupFileCopy = { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            }
        ) -> ChatSessionAutocompactor {
            ChatSessionAutocompactor(
                dataRoot: root,
                config: ChatSessionAutocompactionConfig(
                    thresholdTokens: 1,
                    keepCount: 1,
                    distillEnabled: true
                ),
                backupFileCopy: backupFileCopy
            )
        }

        func backupFiles() throws -> [URL] {
            let directory = root
                .appendingPathComponent("chat/sessions", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("messages.compact.") }
        }
    }
}
