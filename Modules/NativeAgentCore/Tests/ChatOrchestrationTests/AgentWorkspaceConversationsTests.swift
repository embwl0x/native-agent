import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Workspace conversation windows")
struct AgentWorkspaceConversationsTests {
    @Test func sameContactKeepsTwoExactDiscussionsAndExcludesForeignScope() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentConversationStore(dataRoot: root)
        try save(store, scope: "my-chat", label: "Design", phase: "ready")
        try save(store, scope: "my-chat", label: "Research", phase: "waiting")
        try save(store, scope: "other-chat", label: "Private", phase: "ready")
        let view = try await AgentWorkspaceConversations.project(scope: "my-chat", dataRoot: root) { tool, _ in
            #expect(tool == "agent_contacts")
            return contacts()
        }
        #expect(view.items.count == 2)
        #expect(Set(view.items.map(\.title)) == ["Codex — Design", "Codex — Research"])
        var labels: Set<String> = []
        for item in view.items {
            let button = try #require(item.actions.first)
            guard case .open(.record(let tool, let input, let title)) = button.action else {
                Issue.record("A conversation needs an exact owner read"); continue
            }
            #expect(tool == "agent_read")
            #expect(input["agent"] == .string("codex"))
            guard case .string(let label)? = input["conversation"] else {
                Issue.record("Never reopen whichever discussion happens to be selected"); continue
            }
            labels.insert(label)
            #expect(title == "Codex — " + label)
        }
        #expect(labels == ["Design", "Research"])
        let encoded = String(decoding: try JSONEncoder().encode(view.items.map(\.content)), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE_REPLY_TEXT"))
        #expect(!encoded.contains("Private"))
    }

    @Test func stateIsHonestAboutRecordedOutcomeAndUnavailableContact() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentConversationStore(dataRoot: root)
        try save(store, scope: "chat", label: "Sending", phase: "sending")
        try save(store, scope: "chat", label: "Waiting", phase: "waiting")
        try save(store, scope: "chat", label: "Ready", phase: "ready")
        try save(store, scope: "chat", label: "Input", phase: "ready", needsInput: true)
        try save(store, scope: "chat", label: "Unknown", phase: "mystery")
        let view = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root) { _, _ in contacts() }
        let states = Dictionary(uniqueKeysWithValues: view.items.map { ($0.title, object($0.content)["state"]) })
        #expect(states["Codex — Sending"] == .string("waiting"))
        #expect(states["Codex — Waiting"] == .string("waiting"))
        #expect(states["Codex — Ready"] == .string("ready"))
        #expect(states["Codex — Input"] == .string("attention"))
        #expect(states["Codex — Unknown"] == .string("attention"))
        #expect(view.items.allSatisfy { object($0.content)["state_basis"] == .string("last recorded owner outcome") })
        let disconnected = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root) { _, _ in
            .object(["status": .string("ok"), "contacts": .array([])])
        }
        #expect(disconnected.items.count == 5)
        #expect(disconnected.items.allSatisfy { $0.actions.first?.label == "Read saved result" && object($0.content)["available"] == .bool(false) })
    }

    @Test func failedContactGateCannotExposeSavedMetadata() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try save(AgentConversationStore(dataRoot: root), scope: "chat", label: "Design", phase: "ready")
        let denied: JSONValue = .object(["status": .string("denied"), "detail": .string("Current gate denied")])
        let view = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root) { _, _ in denied }
        #expect(view.content == denied)
        #expect(view.items.isEmpty)
    }

    @Test func selectionTimestampDoesNotCreateAChangeAndListingDoesNotReadReplies() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentConversationStore(dataRoot: root)
        try save(store, scope: "chat", label: "Design", phase: "ready")
        let before = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root) { tool, _ in
            #expect(tool == "agent_contacts")
            return contacts()
        }
        let row = try #require(try store.find(scopeSessionID: "chat", agent: "codex", label: "Design"))
        try store.update(id: row.id, operationID: row.operationID) { $0.selected = true }
        let after = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root) { tool, _ in
            #expect(tool == "agent_contacts")
            return contacts()
        }
        #expect(object(before.items[0].content)["change_token"] == object(after.items[0].content)["change_token"])
    }

    @Test func listMatchesActualReadBaselineButNeverConsumesChangedEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentConversationStore(dataRoot: root)
        try save(store, scope: "chat", label: "Design", phase: "ready")
        let row = try #require(try store.find(scopeSessionID: "chat", agent: "codex", label: "Design"))
        let location = AgentWorkspaceLocation.record(tool: "agent_read", input: ["agent": .string("codex"), "conversation": .string("Design")], title: "Codex — Design")
        let actualRead = AgentConversationSession.view(row, details: false, dataRoot: root)
        let stamp = try #require(AgentWorkspaceChanges.evaluate(location: location, result: actualRead, previous: nil)?.nextStamp)
        let observations = [stamp]
        let unchanged = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root, observations: observations) { _, _ in contacts() }
        #expect(object(object(unchanged.items[0].content)["change"] ?? .null)["state"] == .string("unchanged"))
        try store.update(id: row.id, operationID: row.operationID) { $0.phase = "waiting" }
        let progress = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root, observations: observations) { _, _ in contacts() }
        #expect(progress.items[0].actions.first?.label == "See updated progress")
        try store.update(id: row.id, operationID: row.operationID) { $0.receipt = .object(["reply": .string("A newer private answer")]) }
        for _ in 0..<2 {
            let changed = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root, observations: observations) { tool, _ in
                #expect(tool == "agent_contacts")
                return contacts()
            }
            #expect(object(object(changed.items[0].content)["change"] ?? .null)["state"] == .string("changed"))
            #expect(changed.items[0].actions.first?.label == "Read what’s new")
            let rendered = String(decoding: try JSONEncoder().encode(changed.items[0].content), as: UTF8.self)
            #expect(!rendered.contains("A newer private answer"))
        }
    }

    @Test func botWindowUsesCurrentContinuousOwnerAndExactOpenedBaseline() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentConversationStore(dataRoot: root)
        let agent = "bot:" + UUID().uuidString.lowercased()
        let row = try store.begin(scopeSessionID: "chat", agent: agent, name: "Helper", label: "Main", fresh: false, sourceSurface: "chat", fingerprint: nil, replyRoute: nil)
        try store.update(id: row.id, operationID: row.operationID) {
            $0.phase = "waiting"
            $0.receipt = .object(["reply": .string("STALE_BOOKMARK_REPLY")])
        }
        let input: [String: JSONValue] = ["agent": .string(agent)]
        let raw: JSONValue = .object(["status": .string("ok"), "run_status": .string("completed"), "reply": .string("CURRENT_PRIVATE_REPLY")])
        let current = AgentConversationView.read(raw, agent: agent, input: input)
        let location = AgentWorkspaceLocation.record(tool: "agent_read", input: input, title: "Helper")
        let stamp = try #require(AgentWorkspaceChanges.evaluate(location: location, result: current, previous: nil)?.nextStamp)
        let view = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root, observations: [stamp]) { tool, arguments in
            if tool == "agent_contacts" {
                return .object(["status": .string("ok"), "contacts": .array([.object(["agent": .string(agent), "capabilities": .array([.string("read")])])])])
            }
            #expect(tool == "agent_read")
            #expect(arguments == input)
            return current
        }
        let item = try #require(view.items.first)
        #expect(object(item.content)["state"] == .string("ready"))
        #expect(object(object(item.content)["change"] ?? .null)["state"] == .string("unchanged"))
        guard case .open(.record(let tool, let bound, _)) = item.actions[0].action else {
            Issue.record("Bot needs its continuous owner read"); return
        }
        #expect(tool == "agent_read")
        #expect(bound == input)
        let rendered = String(decoding: try JSONEncoder().encode(item.content), as: UTF8.self)
        #expect(!rendered.contains("STALE_BOOKMARK_REPLY"))
        #expect(!rendered.contains("CURRENT_PRIVATE_REPLY"))
    }

    @Test func unavailableSavedBotStillOffersExactGatedReadWithoutEagerlyReading() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentConversationStore(dataRoot: root)
        let agent = "bot:" + UUID().uuidString.lowercased()
        for target in [agent, "bot-run:unsupported"] {
            let row = try store.begin(scopeSessionID: "chat", agent: target, name: target == agent ? "Saved helper" : "Unknown record", label: "Main", fresh: false, sourceSurface: "chat", fingerprint: nil, replyRoute: nil)
            try store.update(id: row.id, operationID: row.operationID) { $0.phase = "ready" }
        }
        let view = try await AgentWorkspaceConversations.project(scope: "chat", dataRoot: root) { tool, _ in
            #expect(tool == "agent_contacts")
            return .object(["status": .string("ok"), "contacts": .array([])])
        }
        let item = try #require(view.items.first { object($0.content)["agent"] == .string(agent) })
        #expect(object(item.content)["available"] == .bool(false))
        #expect(object(item.content)["state"] == .string("attention"))
        #expect(object(item.content)["recorded_state"] == .string("ready"))
        let button = try #require(item.actions.first)
        #expect(button.label == "Read saved result")
        guard case .open(.record(let tool, let bound, _)) = button.action else {
            Issue.record("Saved bot needs its exact gated owner read"); return
        }
        #expect(tool == "agent_read")
        #expect(bound == ["agent": .string(agent)])
        #expect(view.items.first { object($0.content)["agent"] == .string("bot-run:unsupported") }?.actions.isEmpty == true)
    }

    private func save(_ store: AgentConversationStore, scope: String, label: String,
                      phase: String, needsInput: Bool = false) throws {
        let row = try store.begin(scopeSessionID: scope, agent: "codex", name: "Codex", label: label,
                                  fresh: true, sourceSurface: "chat", fingerprint: nil, replyRoute: nil)
        try store.update(id: row.id, operationID: row.operationID) {
            $0.phase = phase
            $0.receipt = .object(["reply": .string("PRIVATE_REPLY_TEXT"), "needs_input": .bool(needsInput)])
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-conversations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func contacts() -> JSONValue {
        .object(["status": .string("ok"), "contacts": .array([.object([
            "agent": .string("codex"), "name": .string("Codex"),
            "capabilities": .array([.string("read"), .string("message")])
        ])])])
    }

    private func object(_ value: JSONValue) -> [String: JSONValue] {
        guard case .object(let object) = value else { return [:] }
        return object
    }
}
