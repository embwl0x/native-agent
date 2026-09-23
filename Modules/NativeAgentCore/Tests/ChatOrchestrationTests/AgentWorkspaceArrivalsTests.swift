import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import StandingBots
@testable import ChatOrchestration

@Suite("Event-driven workspace arrivals")
struct AgentWorkspaceArrivalsTests {
    @Test(arguments: [true, false])
    func sameHelperReplyFromTwoOwnersIsOneNoticeWithoutHidingDecisions(agentFirst: Bool) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var state = AgentWorkspaceArrivals.State(monitor: .init(dataRoot: root))
        let event = try #require(AgentWorkspaceArrivals.helperEvent(bot: UUID().uuidString, entry: UUID().uuidString))
        let first = agentFirst ? "agents" : "bots", second = agentFirst ? "bots" : "agents"
        func candidate(_ owner: String, revision: String, kind: AgentWorkspaceArrivals.Kind?) -> AgentWorkspaceArrivals.Candidate {
            .init(source: owner + ":one", revision: revision, title: "Helper", kind: kind, location: .home, eventID: event)
        }
        for owner in [first, second] { state.accept([candidate(owner, revision: "pending", kind: nil)], owner: owner) }
        state.accept([candidate(first, revision: "done", kind: .finished)], owner: first)
        state.pending[0].announced = true // Later owner event must not reannounce.
        state.accept([candidate(second, revision: "done", kind: .finished)], owner: second)
        #expect(state.pending.count == 1 && state.pending[0].announced)
        state.accept([candidate(second, revision: "decision", kind: .decision)], owner: second)
        #expect(Set(state.pending.map(\.kind.rawValue)) == ["finished", "decision"])
        state.accept([candidate(first, revision: "updated evidence", kind: .finished)], owner: first)
        #expect(state.pending.contains { $0.kind == .decision })
        for i in 0..<150 {
            state.accept([.init(source: "agents:new-\(i)", revision: "done", title: "Helper", kind: .finished,
                location: .home, eventID: "fixture-\(i)")], owner: "agents")
        }
        #expect(state.eventSources.count == 128 && state.eventOrder.count == 128)
        #expect(AgentWorkspaceArrivals.helperEvent(bot: "not-a-bot", entry: "untrusted prose") == nil)
    }

    @Test func canonicalHelperCompletionAndConversationReceiptShareOneArrival() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = "helper-two-owners", key = root.path + "\u{0}" + scope
        let bot = try BotDefinitionStore(dataRoot: root).create(.init(name: "Helper", brief: "Fixture", cadence: .manual,
            budget: .init(tokens: 500, seconds: 30)))
        func entry() -> ShelfEntry {
            .init(botId: bot.id, briefVersion: bot.briefVersion, runAt: Date(), coverageStart: Date(), coverageEnd: Date(),
                headline: "Controlled completion", findings: "Fixture", changedSinceLastGood: "", runHealth: .ok,
                spend: .init(tokens: 0, seconds: 0))
        }
        try ShelfStore(dataRoot: root).append(entry())
        let store = AgentConversationStore(dataRoot: root)
        let row = try store.begin(scopeSessionID: scope, agent: "bot:" + bot.id.uuidString, name: bot.name,
            label: "Main", fresh: false, sourceSurface: "chat", fingerprint: nil, replyRoute: nil)
        let navigation = AgentWorkspaceNavigation()
        _ = await navigation.arrivalNotice(dataRoot: root, scope: scope)
        try await navigation.navigate(.record(tool: "agent_read", input: ["agent": .string(row.agent)], title: bot.name), key: key)
        _ = await navigation.arrivalNotice(dataRoot: root, scope: scope)
        let reply = entry()
        try ShelfStore(dataRoot: root).append(reply)
        try store.update(id: row.id, operationID: row.operationID) {
            $0.phase = "ready"
            $0.receipt = .object(["status": .string("completed"), "entry_id": .string(reply.id.uuidString)])
        }
        _ = try await waitForNotice(navigation, root: root, scope: scope)
        try await Task.sleep(for: .milliseconds(100)) // Allow the other owner event to reach its dirty bit.
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: scope) == nil)
        #expect(await navigation.arrivalProjection(key: key).items.count == 1)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrivals-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func object(_ value: JSONValue?) -> [String: JSONValue] { AgentWorkspaceArrivals.object(value) }
    private func notice(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .array(let rows)? = object(value)["notices"] else { return [:] }
        return object(rows.first)
    }
    private func begin(_ root: URL, scope: String) throws -> AgentConversationRecord {
        try AgentConversationStore(dataRoot: root).begin(scopeSessionID: scope, agent: "codex", name: "Builder",
            label: "Exact discussion", fresh: false, sourceSurface: "chat", fingerprint: nil, replyRoute: nil)
    }
    private func settle(_ row: AgentConversationRecord, root: URL, status: String = "completed") throws {
        try AgentConversationStore(dataRoot: root).update(id: row.id, operationID: row.operationID) {
            $0.phase = status == "failed" ? "attention" : "ready"
            $0.receipt = .object(["status": .string(status), "reply": .string("PRIVATE_REPLY_DO_NOT_INJECT")])
        }
    }
    private func waitForNotice(_ navigation: AgentWorkspaceNavigation, root: URL, scope: String) async throws -> JSONValue {
        // Wait for an actual vnode event. Production uses no timer; this is a
        // bounded fixture wait, not a direct call to invalidate the cache.
        for _ in 0..<100 {
            if let notice = await navigation.arrivalNotice(dataRoot: root, scope: scope) { return notice }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AgentWorkspaceNavigation.DesktopFailure(message: "No owner event reached the workspace")
    }

    @Test func replyArrivesWithoutWorkspaceCallAndDoesNotMoveSelectionOrRepeat() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = "arrivals-main", key = root.path + "\u{0}" + scope
        let row = try begin(root, scope: scope)
        let navigation = AgentWorkspaceNavigation()
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: scope) == nil)
        let file = AgentWorkspaceLocation.record(tool: "read_file",
            input: ["path": .string("/workspace/note.md"), "offset": .int(73)], title: "My note")
        try await navigation.navigate(file, key: key)
        try settle(row, root: root)
        let result = try await waitForNotice(navigation, root: root, scope: scope)
        #expect(notice(result)["kind"] == .string("finished"))
        #expect(!(try result.serialize(pretty: false)).contains("PRIVATE_REPLY_DO_NOT_INJECT"))
        #expect(await navigation.current(key: key) == file)
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: scope) == nil)
        let action = try #require(AgentWorkspaceArrivals.text(object(notice(result)["open"])["action"]))
        let opened = try await navigation.openArrival(action, key: key)
        #expect(opened == .record(tool: "agent_read", input: ["agent": .string("codex"), "conversation": .string("Exact discussion")], title: "Builder — Exact discussion"))
        try await navigation.navigate(opened, key: key)
        #expect(await navigation.returnFromArrival(key: key) == file)
        #expect(await navigation.arrivalProjection(key: key).items.count == 1) // opening != resolving
        await navigation.dismissArrival(action, key: key)
        #expect(await navigation.arrivalProjection(key: key).items.isEmpty)
    }

    @Test func foreignScopeIsNeverAnnouncedAndOldBacklogStartsQuiet() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try begin(root, scope: "ours")
        try settle(old, root: root)
        let other = try begin(root, scope: "other")
        let navigation = AgentWorkspaceNavigation()
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: "ours") == nil)
        try settle(other, root: root)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: "ours") == nil)
        #expect(await navigation.arrivalProjection(key: root.path + "\u{0}ours").items.isEmpty)
    }

    @Test func progressIsQuietAndCannotBuryAnUnresolvedDecision() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var state = AgentWorkspaceArrivals.State(monitor: .init(dataRoot: root))
        func item(_ revision: String, _ kind: AgentWorkspaceArrivals.Kind?) -> AgentWorkspaceArrivals.Candidate {
            .init(source: "agents:one", revision: revision, title: "A helper", kind: kind, location: .home)
        }
        state.accept([item("queued", nil)], owner: "agents")
        state.accept([item("working", nil)], owner: "agents")
        #expect(state.pending.isEmpty)
        state.accept([item("question", .decision)], owner: "agents")
        state.accept([item("progress", nil)], owner: "agents")
        state.accept([item("finished", .finished)], owner: "agents")
        #expect(Set(state.pending.map(\.kind.rawValue)) == ["decision", "finished"])
        state.accept([item("finished", .finished)], owner: "agents")
        #expect(state.pending.count == 2)
        for i in 0..<40 {
            state.accept([.init(source: "agents:\(i)", revision: "done", title: "Result", kind: .finished, location: .home)], owner: "agents")
        }
        #expect(state.pending.count == 24 && state.overflow)
        #expect(state.pending.contains { $0.kind == .decision })
    }

    @Test func arrivalOpensThroughCurrentGateAndReturnsToExactForm() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = "form-arrival", key = root.path + "\u{0}" + scope
        let row = try begin(root, scope: scope)
        let navigation = AgentWorkspaceNavigation()
        _ = await navigation.arrivalNotice(dataRoot: root, scope: scope)
        let schema = LLMToolSchema(name: "write_file", description: "Write draft",
            parametersJSON: Data(#"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}"#.utf8))
        let form = AgentWorkspaceLocation.form(try .init(schema: schema, title: "Draft",
            bound: ["path": .string("/workspace/exact.md")]))
        try await navigation.navigate(.work("Original work"), key: key)
        try await navigation.navigate(form, key: key)
        try settle(row, root: root)
        let notice = try await waitForNotice(navigation, root: root, scope: scope)
        let pointer = try #require(object(self.notice(notice)["open"])["action"])
        let denied = try await AgentWorkspace.dispatch(input: ["action": pointer], scope: scope, dataRoot: root,
            navigation: navigation, perform: { name, args in
                #expect(name == "agent_read")
                #expect(args["conversation"] == .string("Exact discussion"))
                return .object(["status": .string("blocked")])
            })
        #expect(object(denied)["status"] == .string("blocked"))
        if case .array(let controls)? = object(denied)["actions"] {
            let returning = controls.compactMap { AgentWorkspaceArrivals.text(object($0)["label"]) }
                .filter { $0.hasPrefix("Return") || $0.hasPrefix("Back") }
            #expect(returning == ["Return to Draft"])
        } else { Issue.record("The arrival did not offer a return control") }
        #expect(await navigation.returnFromArrival(key: key) == form)
        #expect(await navigation.arrivalProjection(key: key).items.count == 1)
        var refused = false
        do {
            _ = try await AgentWorkspace.dispatch(input: ["action": pointer], scope: "foreign", dataRoot: root,
                navigation: navigation, perform: { _, _ in Issue.record("A foreign pointer reached execution"); return .null })
        } catch { refused = true }
        #expect(refused)
    }

    @Test func structuredToolResultCarriesArrivalButScalarContentsStayExact() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = "dispatch-arrival"
        let row = try begin(root, scope: scope)
        _ = await AgentWorkspaceNavigation.shared.arrivalNotice(dataRoot: root, scope: scope)
        let original: JSONValue = .object(["status": .string("ok"), "value": .int(42)])
        let client = CanonicalToolNameDispatcher(inner: MockToolDispatchClient(scripted: ["time_now": original, "read_file": .string("exact bytes")]),
            peerDataRoot: root, conversationScope: scope)
        try settle(row, root: root)
        try await Task.sleep(for: .milliseconds(100))
        let scalar = try await client.dispatch(tool: "read_file", input: [:], surface: "chat")
        #expect(scalar == .string("exact bytes"))
        let result = try await client.dispatch(tool: "time_now", input: ["__session_id": .string("spoofed")], surface: "chat")
        #expect(object(result)["status"] == .string("ok") && object(result)["value"] == .int(42))
        #expect(notice(object(result)["workspace_arrivals"])["kind"] == .string("finished"))
        #expect(try await client.dispatch(tool: "time_now", input: [:], surface: "chat") == original)
    }

    @Test func corruptOwnerPreservesPendingNoticeAndBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = "broken-owner", key = root.path + "\u{0}" + scope
        let row = try begin(root, scope: scope)
        let navigation = AgentWorkspaceNavigation()
        _ = await navigation.arrivalNotice(dataRoot: root, scope: scope)
        try settle(row, root: root, status: "failed")
        _ = try await waitForNotice(navigation, root: root, scope: scope)
        let path = AgentConversationStore(dataRoot: root).fileURL
        let broken = Data("{bad json".utf8)
        try broken.write(to: path, options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        _ = await navigation.arrivalNotice(dataRoot: root, scope: scope)
        let projection = await navigation.arrivalProjection(key: key)
        #expect(projection.items.count == 1)
        #expect(object(projection.content)["unavailable_sources"] == .array([.string("agents")]))
        #expect(try Data(contentsOf: path) == broken)
    }

    @Test func exchangeGenerationDoesNotAdvanceOnToolReceipts() {
        var row: [String: JSONValue] = [ChatSessionIndexFile.transcriptGenerationKey: .int(1)]
        ChatSessionIndexFile.recordConversationChange(in: &row, role: "user")
        #expect(row["lastConversationGeneration"] == .int(1))
        ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
        ChatSessionIndexFile.recordConversationChange(in: &row, role: "tool")
        #expect(row["lastConversationGeneration"] == .int(1))
        ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
        ChatSessionIndexFile.recordConversationChange(in: &row, role: "assistant")
        #expect(row["lastConversationGeneration"] == .int(3))
    }

    @Test func firstNewMessageInLegacyHumanConversationArrivesWithoutToolNoise() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = "human-listener", key = root.path + "\u{0}" + scope
        let path = root.appendingPathComponent("chat/sessions.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var row: [String: JSONValue] = ["id": .string("old-human-chat"), "source": .string("app"),
            "title": .string("Human chat"), ChatSessionIndexFile.transcriptGenerationKey: .int(5)]
        try ChatSessionIndexFile.serializedData(for: [row]).write(to: path, options: .atomic)
        let navigation = AgentWorkspaceNavigation()
        _ = await navigation.arrivalNotice(dataRoot: root, scope: scope)
        try await navigation.navigate(.record(tool: "chat_conversations",
            input: ["conversation_session_id": .string("old-human-chat")], title: "Human chat"), key: key)
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: scope) == nil)
        ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
        ChatSessionIndexFile.recordConversationChange(in: &row, role: "tool")
        try ChatSessionIndexFile.serializedData(for: [row]).write(to: path, options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await navigation.arrivalNotice(dataRoot: root, scope: scope) == nil)
        ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
        ChatSessionIndexFile.recordConversationChange(in: &row, role: "assistant")
        try ChatSessionIndexFile.serializedData(for: [row]).write(to: path, options: .atomic)
        let received = try await waitForNotice(navigation, root: root, scope: scope)
        #expect(notice(received)["kind"] == .string("activity"))
    }
}
