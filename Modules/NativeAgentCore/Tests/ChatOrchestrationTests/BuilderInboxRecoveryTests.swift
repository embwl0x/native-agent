import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

private actor InboxRecoveryWakeRecorder {
    private(set) var payloads: [[String: JSONValue]] = []
    func wake(_ payload: [String: JSONValue]) -> JSONValue {
        payloads.append(payload)
        return .object(["status": .string(payloads.count == 1 ? "failed" : "sent")])
    }
}

private struct InboxRecoveryFixture {
    let root: URL
    let inbox: URL
    let dispatcher: SwiftToolDispatcher
    let recorder: InboxRecoveryWakeRecorder
    let tool: String
    var input: [String: JSONValue] {
        ["text": .string("one accepted brief"), "message_id": .string("same-operation"),
         "topic": .string("recovery"), "session_id": .string("original-session"),
         "timeout_seconds": .int(120)]
    }

    init(agent: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("builder-inbox-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        inbox = root.appendingPathComponent("\(agent)-bridge/\(agent)-inbox.jsonl")
        tool = "\(agent)_message"
        let recorder = InboxRecoveryWakeRecorder()
        self.recorder = recorder
        dispatcher = SwiftToolDispatcher(
            dataRoot: root, agentBridgeConfigRoot: root,
            claudeMessageWakeupOverride: { payload in await recorder.wake(payload) },
            ompMessageWakeupOverride: { payload in await recorder.wake(payload) }
        )
    }

    func send(_ body: [String: JSONValue]? = nil) async throws -> [String: JSONValue] {
        let result = try await dispatcher.dispatch(tool: tool, input: body ?? input, surface: "chat")
        guard case .object(let object) = result else { throw PersistenceCoreError.ioFailure("expected receipt") }
        return object
    }

    func rewrite(_ change: ([String: JSONValue]) -> [String: JSONValue]) async throws {
        let rows = try await SwiftNativePersistenceCore().readJSONL(inbox)
        let changed = try rows.map { row -> String in
            guard case .object(let object) = row else { throw PersistenceCoreError.ioFailure("expected inbox row") }
            return try JSONValue.object(change(object)).serialize(pretty: false)
        }.joined(separator: "\n") + "\n"
        try Data(changed.utf8).write(to: inbox, options: .atomic)
    }
}

@Suite("Explicit builder inbox recovery")
struct BuilderInboxRecoveryTests {
    @Test(arguments: ["claude", "omp"])
    func explicitContinuationRequirementSurvivesWakeAndBindsSameMessageID(agent: String) async throws {
        let fixture = try InboxRecoveryFixture(agent: agent)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var resume = fixture.input
        resume["conversation_id"] = .string("\(agent == "claude" ? "claude" : "omp"):recovery")
        resume["conversation_mode"] = .string("resume")
        _ = try await fixture.send(resume)
        let original = try Data(contentsOf: fixture.inbox)
        _ = try await fixture.send(resume)
        let payloads = await fixture.recorder.payloads
        #expect(payloads.count == 2)
        #expect(payloads[0] == payloads[1])
        #expect(payloads[0]["requireExistingConversation"] == .bool(true))
        let changed = try await fixture.send(fixture.input)
        #expect(changed["reason"] == .string("message_id_conflict"))
        #expect(await fixture.recorder.payloads.count == 2)
        #expect(try Data(contentsOf: fixture.inbox) == original)

        // An old/default-topic request must not acquire new resume intent just
        // because its generated conversation handle happens to be the same.
        try await fixture.rewrite { row in
            var legacy = row
            legacy.removeValue(forKey: "requireExistingConversation")
            return legacy
        }
        let legacy = try Data(contentsOf: fixture.inbox)
        let conflict = try await fixture.send(resume)
        #expect(conflict["reason"] == .string("message_id_conflict"))
        #expect(try Data(contentsOf: fixture.inbox) == legacy)
        _ = try await fixture.send(fixture.input)
        let recorded = await fixture.recorder.payloads
        let legacyPayload = try #require(recorded.last)
        #expect(legacyPayload["requireExistingConversation"] == nil)
    }

    @Test(arguments: ["claude", "omp"])
    func unconsumedRetryKeepsOriginalPayloadAndQueueTime(agent: String) async throws {
        let fixture = try InboxRecoveryFixture(agent: agent)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.send()
        let before = try Data(contentsOf: fixture.inbox)
        let second = try await fixture.send()
        #expect(second["deduplicated"] == .bool(true))
        #expect(second["wakeupRetried"] == .bool(true))
        let payloads = await fixture.recorder.payloads
        #expect(payloads.count == 2)
        #expect(payloads[0] == payloads[1])
        #expect(payloads[1]["sessionId"] == .string("original-session"))
        #expect(try Data(contentsOf: fixture.inbox) == before)
    }

    @Test(arguments: ["claude", "omp"])
    func consumedReadAndLegacyMissingOriginDoNotWakeAgain(agent: String) async throws {
        for variant in ["read", "consumed", "legacy"] {
            let fixture = try InboxRecoveryFixture(agent: agent)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try await fixture.send()
            try await fixture.rewrite { original in
                var row = original
                if variant == "read" { row["read"] = .bool(true) }
                if variant == "consumed" { row["consumedAt"] = .string("2026-08-30T17:00:00Z") }
                if variant == "legacy" { row.removeValue(forKey: "sessionId") }
                return row
            }
            let before = try Data(contentsOf: fixture.inbox)
            let second = try await fixture.send()
            #expect(second["wakeupRetried"] == nil)
            #expect(await fixture.recorder.payloads.count == 1)
            #expect(try Data(contentsOf: fixture.inbox) == before)
        }
    }

    @Test(arguments: ["claude", "omp"])
    func changedRouteBriefOrTimeoutRejectsSameIdentity(agent: String) async throws {
        let fixture = try InboxRecoveryFixture(agent: agent)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.send()
        let before = try Data(contentsOf: fixture.inbox)
        for (field, value) in [
            ("session_id", JSONValue.string("different-session")),
            ("text", .string("different work")),
            ("timeout_seconds", .int(300)),
        ] {
            var changed = fixture.input
            changed[field] = value
            let result = try await fixture.send(changed)
            #expect(result["status"] == .string("failed"))
            #expect(result["reason"] == .string("message_id_conflict"))
        }
        #expect(await fixture.recorder.payloads.count == 1)
        #expect(try Data(contentsOf: fixture.inbox) == before)
    }

    @Test(arguments: ["claude", "omp"])
    func malformedInboxCannotHideAnEarlierAdmission(agent: String) async throws {
        let fixture = try InboxRecoveryFixture(agent: agent)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{unreadable admission}\n".utf8)
        try corrupt.write(to: fixture.inbox)
        let result = try await fixture.send()
        #expect(result["status"] == .string("failed"))
        #expect(await fixture.recorder.payloads.isEmpty)
        #expect(try Data(contentsOf: fixture.inbox) == corrupt)
    }

    @Test(arguments: ["claude", "omp"])
    func conflictingStoredIdentityCannotReachHelper(agent: String) async throws {
        let fixture = try InboxRecoveryFixture(agent: agent)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.send()
        try await fixture.rewrite { original in
            var row = original
            row["id"] = .string("another-operation")
            return row
        }
        let before = try Data(contentsOf: fixture.inbox)
        let result = try await fixture.send()
        #expect(result["status"] == .string("failed"))
        #expect(await fixture.recorder.payloads.count == 1)
        #expect(try Data(contentsOf: fixture.inbox) == before)
    }
}
