import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

private func contractTempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-contract-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("lazy dispatch derives the canonical task-local session when input omits it")
func lazyDispatchUsesTaskLocalSession() async throws {
    let root = try contractTempRoot("task-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)

    let result = try await ChatToolSessionContext.$verifiedSessionId.withValue("chat-task-session") {
        try await LLMCallContext.$turnActiveTools.withValue(["workshop_status"]) {
            try await dispatcher.dispatch(tool: "workshop_status", input: [:], surface: "chat")
        }
    }

    guard case .object(let object) = result else {
        Issue.record("workshop_status should return an object")
        return
    }
    #expect(object["reason"] != .string("missing_session_id"))
    #expect(object["reason"] != .string("not_loaded"))
}

@Test("builder conversation mode rejects ambiguous new and resume requests")
func builderConversationModeFailsClosed() async throws {
    let root = try contractTempRoot("builder-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { _ in
            .object(["status": .string("sent"), "threadId": .string("fresh-thread")])
        }
    )

    let staleHandle = try await dispatcher.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("This is unrelated work."),
            "conversation_mode": .string("new"),
            "conversation_id": .string("codex:stale-thread"),
        ],
        surface: "chat"
    )
    guard case .object(let staleObject) = staleHandle else {
        Issue.record("expected a conflict envelope")
        return
    }
    #expect(staleObject["reason"] == .string("conversation_mode_conflict"))

    let missingHandle = try await dispatcher.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Continue the earlier work."),
            "conversation_mode": .string("resume"),
        ],
        surface: "chat"
    )
    guard case .object(let missingObject) = missingHandle else {
        Issue.record("expected a missing-handle conflict envelope")
        return
    }
    #expect(missingObject["reason"] == .string("conversation_mode_conflict"))

    let newWork = try await dispatcher.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Start genuinely new work."),
            "conversation_mode": .string("new"),
            "message_id": .string("explicit-new-work"),
        ],
        surface: "chat"
    )
    guard case .object(let newObject) = newWork else {
        Issue.record("expected a queued new-work envelope")
        return
    }
    #expect(newObject["reason"] == nil)
}

@Test("builder and Desk schemas make optional contract boundaries explicit")
func toolSchemasExposeConversationModeAndNonEmptyMetadata() async throws {
    let root = try contractTempRoot("schemas")
    defer { try? FileManager.default.removeItem(at: root) }
    let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()

    for name in ["codex_message", "claude_message", "omp_message"] {
        let schema = try #require(schemas.first { $0.name == name })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let object) = parsed,
              case .object(let properties)? = object["properties"],
              case .object(let mode)? = properties["conversation_mode"],
              case .array(let values)? = mode["enum"],
              case .object(let conversation)? = properties["conversation_id"] else {
            Issue.record("\(name) conversation schema is malformed")
            continue
        }
        #expect(values.count == 2)
        #expect(values.contains(.string("new")))
        #expect(values.contains(.string("resume")))
        #expect(conversation["minLength"] == nil)
        guard case .string(let description)? = conversation["description"] else {
            Issue.record("\(name) conversation schema needs omission guidance")
            continue
        }
        #expect(description.contains("empty string"))
    }

    let status = try #require(schemas.first { $0.name == "desk_set_status" })
    let parsedStatus = try JSONValue.parse(status.parametersJSON)
    guard case .object(let statusObject) = parsedStatus,
          case .object(let statusProperties)? = statusObject["properties"],
          case .object(let assignee)? = statusProperties["assignee"],
          case .object(let laneOf)? = statusProperties["lane_of"] else {
        Issue.record("desk_set_status metadata schema is malformed")
        return
    }
    // Optional blank metadata is an omission, not a clear/unassign request.
    // The schema must agree with deskMetadataString's preserved-value contract.
    for metadata in [assignee, laneOf] {
        #expect(metadata["type"] == .string("string"))
        #expect(metadata["minLength"] == nil)
        guard case .string(let description)? = metadata["description"] else {
            Issue.record("desk_set_status metadata needs preservation guidance")
            continue
        }
        #expect(description.contains("Omitted or blank values preserve the current value"))
        #expect(description.contains("cannot clear"))
    }
}
