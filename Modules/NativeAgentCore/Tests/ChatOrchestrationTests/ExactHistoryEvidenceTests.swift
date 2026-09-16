import Foundation
import Testing
@testable import ChatOrchestration
import PersistenceCore

@Suite struct ExactHistoryEvidenceTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-history-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chat/messages"), withIntermediateDirectories: true)
        return root
    }

    private func read(_ root: URL, session: String? = nil, id: String = "target") async throws -> [String: JSONValue] {
        var args: [String: JSONValue] = ["message_id": .string(id)]
        if let session { args["session_id"] = .string(session) }
        let value = try await SwiftToolDispatcher(dataRoot: root).impl_read_chat_message(input: args, invokedAs: "read_chat_message")
        guard case .object(let result) = value else { throw CocoaError(.coderReadCorrupt) }
        return result
    }

    private func coverage(_ result: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let value)? = result["coverage"] else { throw CocoaError(.coderReadCorrupt) }
        return value
    }

    @Test func absentTranscriptIsDistinctFromUnreadableTranscript() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = try await read(root, session: "absent")
        #expect(absent["status"] == .string("not_found"))
        #expect(try coverage(absent)["complete"] == .bool(true))
        #expect(try coverage(absent)["missing_session_count"] == .int(1))
        // A directory is a deterministic read failure without depending on
        // the test user's permission privileges or touching live transcripts.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chat/messages/broken.jsonl"), withIntermediateDirectories: false)
        let unreadable = try await read(root, session: "broken")
        #expect(unreadable["status"] == .string("error"))
        #expect(try coverage(unreadable)["complete"] == .bool(false))
        #expect(try coverage(unreadable)["unreadable_session_count"] == .int(1))
    }

    @Test func damagedRowsDoNotEstablishAbsenceOrInventSourceIndex() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chat/messages/mixed.jsonl")
        let bytes = Data("broken\n[]\n{\"id\":\"target\",\"role\":\"assistant\",\"content\":\"intact evidence 🐚\"}\n".utf8)
        try bytes.write(to: source)
        let found = try await read(root, session: "mixed")
        #expect(found["status"] == .string("ok"))
        #expect(found["text"] == .string("intact evidence 🐚"))
        #expect(found["message_index"] == .null)
        #expect(try coverage(found)["malformed_row_count"] == .int(1))
        #expect(try coverage(found)["invalid_shape_row_count"] == .int(1))
        let missing = try await read(root, session: "mixed", id: "unseen")
        #expect(missing["status"] == .string("error"))
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func invalidUTF8CannotBecomeVerbatimEvidence() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chat/messages/encoding.jsonl")
        var bytes = Data("{\"id\":\"target\",\"role\":\"assistant\",\"content\":\"before ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data(" after\"}\n".utf8))
        try bytes.write(to: source)
        let result = try await read(root, session: "encoding")
        #expect(result["status"] == .string("error"))
        #expect(result["text"] == nil)
        #expect(try coverage(result)["unreadable_session_count"] == .int(1))
        let ordinary = try await SessionHistoryReader(dataRoot: root).messages(forSessionId: "encoding")
        #expect(ordinary.count == 1)
        #expect(ordinary.first?.content.contains("�") == true)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func globalGoodMatchPreservesOtherCopyUncertainty() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"id\":\"target\",\"role\":\"assistant\",\"content\":\"good\"}\n".utf8)
            .write(to: root.appendingPathComponent("chat/messages/good.jsonl"))
        try Data([0xFF]).write(to: root.appendingPathComponent("chat/messages/damaged.jsonl"))
        let result = try await read(root)
        #expect(result["status"] == .string("ok"))
        #expect(result["text"] == .string("good"))
        #expect(try coverage(result)["complete"] == .bool(false))
        #expect(result["coverage_note"] != nil)
        let pinned = try await read(root, session: "good")
        #expect(try coverage(pinned)["complete"] == .bool(true))
        #expect(pinned["message_index"] == .int(0))
    }

    @Test func listingFailureIsNotAnEmptyHistory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("chat/messages")
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        let result = try await read(root)
        #expect(result["status"] == .string("error"))
        #expect(try coverage(result)["directory_listing_failed"] == .bool(true))
    }
}
