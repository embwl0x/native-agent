import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Test func workContextKeepsCurrentWorkSeparateFromDatedConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let messages = root.appendingPathComponent("chat/messages")
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    let transcript = """
    {"id":"old","role":"assistant","createdAt":"2026-09-01T10:00:00Z","content":"Browser replies appear done, but this is an earlier claim."}
    {"id":"direction","role":"user","createdAt":"2026-09-02T10:00:00Z","content":"Browser replies still need checking in the background."}
    {"id":"unrelated","role":"assistant","createdAt":"2026-09-03T10:00:00Z","content":"The lunch reservation is confirmed."}
    """
    try Data(transcript.utf8).write(to: messages.appendingPathComponent("work.jsonl"))
    try Data(#"[{"id":"work","title":"Browser replies"}]"#.utf8).write(to: root.appendingPathComponent("chat/sessions.json"))
    let store = SwiftNativeDeskStore(dataRoot: root)
    let item = try await store.createItem(kind: .project, project: "Browser", title: "Browser replies")
    _ = try await store.appendNote(item.handle, text: "Still need installed evidence.")
    let dispatcher = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
    // The compact workspace is advertised; its underlying reader stays lazy.
    let coldContract = SwiftToolDispatcher.normalModelToolNames(activeTools: [])
    #expect(coldContract.contains("workspace"))
    #expect(!coldContract.contains("work_context"))
    #expect(!coldContract.contains("search_chat_history"))
    let result = try await dispatcher.impl_work_context(input: [
        "query": .string("pick up our browser replies work"),
        "session_id": .null, "limit": .null, "__session_id": .string("fresh-work-chat")
    ])
    guard case .object(let result) = result,
          case .object(let current)? = result["current_work"],
          case .array(let items)? = current["items"],
          case .object(let first)? = items.first,
          case .object(let history)? = result["supporting_history"],
          case .array(let hits)? = history["excerpts"] else { Issue.record("Missing composed evidence"); return }
    #expect(first["handle"] == .string(item.handle))
    #expect(first["is_open"] == .bool(true))
    #expect(first["read_locator"] == .object(["tool": .string("desk_read"), "arguments": .object(["handle": .string(item.handle)])]))
    let ids = hits.compactMap { value -> JSONValue? in
        guard case .object(let row) = value else { return nil }; return row["message_id"]
    }
    #expect(ids == [.string("direction"), .string("old")])
    #expect(try await store.liveState().items.first?.status == item.status)
}

@Test func workContextReportsPartialHistoryWithoutLosingCurrentDesk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let messages = root.appendingPathComponent("chat/messages")
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    try Data("not-json\n".utf8).write(to: messages.appendingPathComponent("broken.jsonl"))
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await store.createItem(kind: .project, project: "Browser", title: "Browser replies")
    let result = try await SwiftToolDispatcher(dataRoot: root).impl_work_context(input: ["query": .string("browser replies")])
    guard case .object(let result) = result,
          case .object(let current)? = result["current_work"],
          case .object(let history)? = result["supporting_history"] else { Issue.record("Missing independent source status"); return }
    #expect(result["status"] == .string("partial"))
    #expect(current["status"] == .string("ok"))
    #expect(history["status"] == .string("partial"))
}

@Test func workContextUsesSpecificTopicAndWholeWords() {
    #expect(WorkContextQuery("pick up our browser work").text == "browser")
    #expect(WorkContextQuery("please continue our work").terms.isEmpty)
    #expect(WorkContextQuery("X replies").score("Text explanation about replies") == 0)
    #expect(WorkContextQuery("X replies").score("Read replies on X") > 0)
    #expect(WorkContextQuery("browser replies").score("A browser opened the weather") == 0)
    #expect(WorkContextQuery("standing bots improvements").score("Updated the standing job for Bot Check") == 2)
    #expect(WorkContextQuery("standing bot").score("Standing bots are available") == 2)
}

@Test func workContextSurfacesOriginalTurnsWithoutLosingNewestCorrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let messages = root.appendingPathComponent("chat/messages")
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    let original = """
    {"id":"request","role":"user","runId":"change","createdAt":"2026-09-01T10:00:00Z","content":"Update the standing bot."}
    {"id":"receipt","role":"tool","runId":"change","metadata":{"toolName":"bot_update","ok":true}}
    {"id":"changed","role":"assistant","runId":"change","createdAt":"2026-09-01T10:01:00Z","content":"The standing bot brief is version two, with its schedule retained."}
    """
    let recall = """
    {"id":"lookup","role":"tool","runId":"lookup","metadata":{"toolName":"work_context"}}
    {"id":"other","role":"tool","runId":"lookup","metadata":{"toolName":"read_file"}}
    {"id":"echo","role":"assistant","runId":"lookup","createdAt":"2026-09-02T10:00:00Z","content":"Standing bots improvements: the previous conversation said version two."}
    {"id":"correction","role":"user","runId":"correct","createdAt":"2026-09-03T10:00:00Z","content":"Standing bots improvements are not finished: the schedule needs fixing."}
    """
    try Data(original.utf8).write(to: messages.appendingPathComponent("check.jsonl"))
    try Data(recall.utf8).write(to: messages.appendingPathComponent("followup.jsonl"))
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let result = try await dispatcher.impl_work_context(input: ["query": .string("standing bots improvements")])
    guard case .object(let result) = result,
          case .object(let history)? = result["supporting_history"],
          case .array(let hits)? = history["excerpts"] else { Issue.record("Missing history"); return }
    let ids = hits.compactMap { hit -> JSONValue? in
        guard case .object(let row) = hit else { return nil }; return row["message_id"]
    }
    #expect(ids == [.string("changed"), .string("correction"), .string("echo")])
    guard case .object(let first)? = hits.first else { Issue.record("Missing source"); return }
    #expect(first["read_locator"] == .object(["tool": .string("read_chat_message"), "arguments": .object(["session_id": .string("check"), "message_id": .string("changed")])]))

    // Ordinary search and explicit session pinning retain their contracts.
    let ordinary = try await dispatcher.impl_search_chat_history(input: [
        "query": .string("standing"), "scope": .string("all_sessions"), "sort": .string("newest")
    ], invokedAs: "search_chat_history")
    guard case .object(let ordinary) = ordinary, case .array(let ordinaryHits)? = ordinary["hits"],
          case .object(let latest)? = ordinaryHits.first else { Issue.record("Missing ordinary history"); return }
    #expect(latest["message_id"] == .string("correction"))
    let pinned = try await dispatcher.impl_work_context(input: [
        "query": .string("standing bots improvements"), "session_id": .string("followup")
    ])
    guard case .object(let pinned) = pinned, case .object(let lane)? = pinned["supporting_history"],
          case .array(let pinnedHits)? = lane["excerpts"] else { Issue.record("Missing pinned history"); return }
    #expect(pinnedHits.allSatisfy { if case .object(let row) = $0 { return row["session_id"] == .string("followup") }; return false })
}
