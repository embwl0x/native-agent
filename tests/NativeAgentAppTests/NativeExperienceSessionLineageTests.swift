import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private func lineageRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-experience-lineage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("chat/messages"), withIntermediateDirectories: true)
    return root
}

private func lineageWrite(_ value: JSONValue, to path: URL) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.serializedData(pretty: false).write(to: path, options: .atomic)
}

@Test func conversationForkCopiesExactPrefixAndPreservesSource() async throws {
    let root = try lineageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("chat/sessions.json")
    try lineageWrite(.array([.object([
        "id": .string("source-session"), "title": .string("Source"), "source": .string("app"),
        "createdAt": .string("2026-08-08T12:00:00Z"), "updatedAt": .string("2026-08-08T12:00:00Z"),
        "archived": .bool(false), "messageCount": .int(3), "projectSpaceId": .string("workspace-1"),
        "providerId": .string("openai"), "modelId": .string("gpt-test"),
    ])]), to: sessions)
    let sourcePath = root.appendingPathComponent("chat/messages/source-session.jsonl")
    let messages: [JSONValue] = [
        .object(["id": .string("m1"), "role": .string("user"), "content": .string("one"), "createdAt": .string("2026-08-08T12:00:01Z")]),
        .object(["id": .string("m2"), "role": .string("assistant"), "content": .string("two"), "createdAt": .string("2026-08-08T12:00:02Z")]),
        .object(["id": .string("m3"), "role": .string("user"), "content": .string("three"), "createdAt": .string("2026-08-08T12:00:03Z")]),
    ]
    let sourceBytes = try messages.reduce(into: Data()) { data, value in
        data.append(try value.serializedData(pretty: false)); data.append(0x0A)
    }
    try sourceBytes.write(to: sourcePath)

    let fork = try await NativeClient.forkChatSession(
        sourceSessionId: "source-session", throughMessageId: "m2", title: "Alternate",
        dataRoot: root
    )
    #expect(fork.parentSessionId == "source-session")
    #expect(fork.rootSessionId == "source-session")
    #expect(fork.forkedAtMessageId == "m2")
    #expect(fork.projectSpaceId == "workspace-1")
    #expect(fork.providerId == "openai")
    #expect(try Data(contentsOf: sourcePath) == sourceBytes)
    let forkBytes = try Data(contentsOf: root.appendingPathComponent("chat/messages/\(fork.id).jsonl"))
    #expect(forkBytes.split(separator: 0x0A).count == 2)
}

@Test func conversationForkMissingPointLeavesNoNewTranscriptOrIndexRow() async throws {
    let root = try lineageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("chat/sessions.json")
    let original: JSONValue = .array([.object([
        "id": .string("source"), "title": .string("Source"), "source": .string("app"),
        "createdAt": .string("2026-08-08T12:00:00Z"), "updatedAt": .string("2026-08-08T12:00:00Z"), "archived": .bool(false),
    ])])
    try lineageWrite(original, to: sessions)
    try (try JSONValue.object(["id": .string("m1"), "role": .string("user"), "content": .string("one"), "createdAt": .string("now")]).serializedData(pretty: false) + Data([0x0A]))
        .write(to: root.appendingPathComponent("chat/messages/source.jsonl"))

    await #expect(throws: SessionLineageError.forkPointNotFound) {
        try await NativeClient.forkChatSession(sourceSessionId: "source", throughMessageId: "absent", dataRoot: root)
    }
    #expect(try JSONValue.parse(Data(contentsOf: sessions)) == original)
    let messageFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("chat/messages").path)
        .filter { $0.hasSuffix(".jsonl") }
    #expect(messageFiles == ["source.jsonl"])
}
