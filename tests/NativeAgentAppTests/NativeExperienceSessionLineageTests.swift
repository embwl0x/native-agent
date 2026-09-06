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

@MainActor
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
        .object([
            "id": .string("m1"), "sessionId": .string("source-session"), "role": .string("user"),
            "content": .string("one"), "createdAt": .string("2026-08-08T12:00:01Z"),
            "metadata": .object(["origin": .object(["surface": .string("codex-bridge"), "agent": .string("codex")])]),
        ]),
        .object([
            "id": .string("m2"), "sessionId": .string("source-session"), "role": .string("assistant"),
            "content": .string("two"), "createdAt": .string("2026-08-08T12:00:02Z"),
            "metadata": .object([
                "turnTraceId": .string("original-turn"),
                "outcomeObservation": .object([
                    "sessionID": .string("source-session"), "messageID": .string("m2"), "turnID": .string("original-turn"),
                ]),
            ]),
        ]),
        .object(["id": .string("m3"), "sessionId": .string("source-session"), "role": .string("user"), "content": .string("three"), "createdAt": .string("2026-08-08T12:00:03Z")]),
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
    // 2026-09-06: the fork used to be a byte-exact copy of the source prefix.
    // 310e38ba ("Fork: stamp copied transcript rows with the new session id")
    // restamps `sessionId` on every copied row — the old copy claimed to belong
    // to the SOURCE session, so orphan recovery read the transcript as
    // corruption and every reader that selects rows by sessionId matched none
    // of them. Lineage stays on the index row (asserted above). So the pin is
    // still exact, just against the restamped prefix: sessionId becomes the
    // fork's id and NOTHING else about the copied rows may change.
    let expectedPrefix = try messages.prefix(2).reduce(into: Data()) { data, value in
        guard case .object(var object) = value else { return }
        object["sessionId"] = .string(fork.id)
        data.append(try JSONValue.object(object).serializedData(pretty: false))
        data.append(0x0A)
    }
    #expect(forkBytes == expectedPrefix)

    let forkMessages = try await NativeClient.getChatMessages(sessionId: fork.id, dataRoot: root)
    let sourceMessages = try await NativeClient.getChatMessages(sessionId: "source-session", dataRoot: root)
    #expect(forkMessages.map(\.id) == ["m1", "m2"])
    #expect(forkMessages.allSatisfy { $0.sessionId == fork.id })
    #expect(sourceMessages.allSatisfy { $0.sessionId == "source-session" })
    #expect(forkMessages.first?.metadata?.origin?.surface == "codex-bridge")
    let target = try #require(forkMessages.last)
    let targetSessionID = try #require(target.sessionId)
    let retry = try #require(MacChatRetrySnapshot.capture(
        target: target, messages: forkMessages, sessionId: targetSessionID, isSyntheticNotice: false
    ))
    #expect(retry.sessionId == fork.id)
    #expect(retry.assistantMessageId == "m2")
    #expect(retry.priorUserMessageId == "m1")
    #expect(try Data(contentsOf: sourcePath) == sourceBytes)
    #expect(try Data(contentsOf: root.appendingPathComponent("chat/messages/\(fork.id).jsonl")) == expectedPrefix)
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
