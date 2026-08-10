import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

private actor OMPWakeRecorder {
    private(set) var payloads: [[String: JSONValue]] = []
    func record(_ payload: [String: JSONValue]) -> JSONValue {
        payloads.append(payload)
        return .object(["status": .string("sent"), "delivery": .string("fake_omp_thread_wakeup")])
    }
}

@Test("omp_message persists its inbox row and dispatches the asynchronous wake payload")
func ompMessagePersistsAndWakes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-message-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("repo/data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    let recorder = OMPWakeRecorder()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        ompMessageWakeupOverride: { payload in await recorder.record(payload) }
    )
    let result = try await dispatcher.dispatch(
        tool: "omp_message",
        input: [
            "text": .string("Say only: tool path ok"),
            "topic": .string("omp-test"),
            "priority": .string("important"),
            "timeout_seconds": .int(120),
            "session_id": .string("agent-session"),
        ],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("omp_message must return an object receipt")
        return
    }
    #expect(object["status"] == .string("queued"))
    #expect(object["timeoutSeconds"] == .int(120))
    #expect(object["conversationId"] == .string("omp:omp-test"))
    #expect(object["replyWith"] == .string("omp_message"))
    #expect(object["wakeup"] == .object(["status": .string("sent"), "delivery": .string("fake_omp_thread_wakeup")]))
    let payloads = await recorder.payloads
    #expect(payloads.count == 1)
    #expect(payloads[0]["source"] == .string("omp_message"))
    #expect(payloads[0]["sessionId"] == .string("agent-session"))
    let inbox = root.appendingPathComponent("config/omp-bridge/omp-inbox.jsonl")
    let rows = try String(contentsOf: inbox, encoding: .utf8).split(separator: "\n")
    #expect(rows.count == 1)
}

@Test("omp_message conversation reference resumes the same topic pointer")
func ompMessageConversationReferenceResumesPointer() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("omp-conversation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("repo/data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    let recorder = OMPWakeRecorder()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        ompMessageWakeupOverride: { payload in await recorder.record(payload) }
    )

    let first = try await dispatcher.dispatch(
        tool: "omp_message",
        input: ["text": .string("Begin this task."), "message_id": .string("omp-first")],
        surface: "chat"
    )
    guard case .object(let firstObject) = first,
          case .string(let conversationId)? = firstObject["conversationId"] else {
        Issue.record("first omp_message should return a conversation reference")
        return
    }
    #expect(conversationId.hasPrefix("omp:conversation-"))

    let reply = try await dispatcher.dispatch(
        tool: "omp_message",
        input: [
            "text": .string("Keep the context and revise it."),
            "conversation_id": .string(conversationId),
            "message_id": .string("omp-reply"),
        ],
        surface: "chat"
    )
    guard case .object(let replyObject) = reply else {
        Issue.record("OMP reply should return an object")
        return
    }
    #expect(replyObject["conversationId"] == .string(conversationId))
    let payloads = await recorder.payloads
    #expect(payloads.count == 2)
    let referenceTopic = String(conversationId.dropFirst("omp:".count))
    #expect(payloads[0]["topic"] == .string(referenceTopic))
    #expect(payloads[1]["topic"] == .string(referenceTopic))
}
