import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import DreamREMCycle
import ApprovalInbox
import MacIntegration
import CognitiveSubstrate

private let makeTempRoot: @Sendable (String) throws -> URL = makeChatOrchestrationTempRoot

@Test
func swiftToolDispatcher_codexMessageQueuesInboxAndPostsMacNotification() async throws {
    let root = try makeTempRoot("codex-message")
    let deskItem = try await SwiftNativeDeskStore(dataRoot: root).createItem(
        kind: .project, project: "NativeAgent", title: "Bound delegation"
    )
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let bridge = FakeMacIntegrationBridgeForCodexMessage()
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        macIntegrationBridge: bridge,
        agentBridgeConfigRoot: configRoot,
        codexMessageNotificationPermissionOverride: true,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object([
                "status": .string("sent"),
                "delivery": .string("fake_codex_thread_wakeup"),
                "threadId": .string("thread-test"),
            ])
        }
    )

    let route = ChatToolSessionContext.ReplyRoute(
        surface: "telegram",
        destinationId: "123456",
        correlationId: "telegram-update-7"
    )
    let result = try await ChatToolSessionContext.$replyRoute.withValue(route) {
        try await tools.dispatch(
            tool: "codex_message",
            input: [
                "text": JSONValue.string("hello Codex from Agent"),
                "priority": JSONValue.string("important"),
                "topic": JSONValue.string("nativeagent-test"),
                "completion_mode": JSONValue.string("receipt_only"),
                "desk_item": JSONValue.string(deskItem.alias),
                "model": JSONValue.string("gpt-6-astra"),
                "reasoning_effort": JSONValue.string("ultra"),
                "fast": JSONValue.bool(true),
                "__session_id": JSONValue.string("session-test"),
            ],
            surface: "telegram"
        )
    }

    guard case .object(let obj) = result else {
        Issue.record("codex_message should return an object")
        return
    }
    #expect(obj["status"] == JSONValue.string("queued"))
    #expect(obj["priority"] == JSONValue.string("important"))
    #expect(obj["conversationId"] == JSONValue.string("codex:thread-test"))
    #expect(obj["replyWith"] == JSONValue.string("codex_message"))
    #expect(obj["deskHandle"] == JSONValue.string(deskItem.handle))

    guard let filePathValue = obj["filePath"],
          case .string(let filePath) = filePathValue else {
        Issue.record("codex_message should return filePath")
        return
    }
    let inboxURL = configRoot
        .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        .appendingPathComponent("codex-inbox.jsonl")
    #expect(filePath == inboxURL.path)

    let raw = try String(contentsOf: inboxURL, encoding: .utf8)
    let lines = raw.split(separator: "\n")
    #expect(lines.count == 1)
    guard let firstLine = lines.first,
          case .object(let row) = try JSONValue.parse(Data(firstLine.utf8)) else {
        Issue.record("codex_message inbox row should be parseable JSON object")
        return
    }
    #expect(row["from"] == JSONValue.string("assistant"))
    guard case .string(let rowId)? = row["id"],
          case .string(let rowMessageId)? = row["messageId"] else {
        Issue.record("codex_message inbox row should include id and messageId")
        return
    }
    #expect(rowMessageId == rowId)
    #expect(row["priority"] == JSONValue.string("important"))
    #expect(row["topic"] == JSONValue.string("nativeagent-test"))
    #expect(row["deskHandle"] == JSONValue.string(deskItem.handle))
    #expect(row["completionMode"] == JSONValue.string("receipt_only"))
    #expect(row["text"] == JSONValue.string("hello Codex from Agent"))
    #expect(row["sessionId"] == JSONValue.string("session-test"))
    #expect(row["model"] == JSONValue.string("gpt-6-astra"))
    #expect(row["reasoningEffort"] == JSONValue.string("ultra"))
    #expect(row["serviceTier"] == JSONValue.string("priority"))
    #expect(row["fast"] == JSONValue.bool(true))
    guard case .object(let rowOrigin)? = row["origin"] else {
        Issue.record("codex_message inbox row should preserve the reply route")
        return
    }
    #expect(rowOrigin["surface"] == JSONValue.string("telegram"))
    #expect(rowOrigin["destinationId"] == JSONValue.string("123456"))
    #expect(rowOrigin["correlationId"] == JSONValue.string("telegram-update-7"))
    #expect(row["read"] == JSONValue.bool(false))

    guard let notificationValue = obj["notification"],
          case .object(let notification) = notificationValue else {
        Issue.record("codex_message should include notification receipt")
        return
    }
    #expect(notification["status"] == JSONValue.string("completed"))
    #expect(notification["posted"] == JSONValue.bool(true))
    #expect(notification["delivery"] == JSONValue.string("fake_macos_notification"))
    #expect(notification["trigger"] == JSONValue.string("codex_message"))

    let notifyInputs = await bridge.macNotifyInputs()
    #expect(notifyInputs.count == 1)
    #expect(notifyInputs.first?["title"] == JSONValue.string("Important NativeAgent to Codex"))
    #expect(notifyInputs.first?["message"] == JSONValue.string("[nativeagent-test] hello Codex from Agent"))

    guard let wakeupValue = obj["wakeup"],
          case .object(let wakeupReceipt) = wakeupValue else {
        Issue.record("codex_message should include wakeup receipt")
        return
    }
    #expect(wakeupReceipt["status"] == JSONValue.string("sent"))
    #expect(wakeupReceipt["delivery"] == JSONValue.string("fake_codex_thread_wakeup"))
    #expect(wakeupReceipt["threadId"] == JSONValue.string("thread-test"))

    let wakeupInputs = await wakeup.all()
    #expect(wakeupInputs.count == 1)
    #expect(wakeupInputs.first?["text"] == JSONValue.string("hello Codex from Agent"))
    #expect(wakeupInputs.first?["priority"] == JSONValue.string("important"))
    #expect(wakeupInputs.first?["topic"] == JSONValue.string("nativeagent-test"))
    #expect(wakeupInputs.first?["deskHandle"] == JSONValue.string(deskItem.handle))
    #expect(wakeupInputs.first?["completionMode"] == JSONValue.string("receipt_only"))
    #expect(wakeupInputs.first?["source"] == JSONValue.string("codex_message"))
    #expect(wakeupInputs.first?["sessionId"] == JSONValue.string("session-test"))
    #expect(wakeupInputs.first?["model"] == JSONValue.string("gpt-6-astra"))
    #expect(wakeupInputs.first?["reasoningEffort"] == JSONValue.string("ultra"))
    #expect(wakeupInputs.first?["serviceTier"] == JSONValue.string("priority"))
    #expect(wakeupInputs.first?["fast"] == JSONValue.bool(true))
    #expect(wakeupInputs.first?["threadId"] == nil)
    #expect(wakeupInputs.first?["origin"] == row["origin"])
}

@Test
func swiftToolDispatcher_codexConversationReferenceResumesExactThread() async throws {
    let root = try makeTempRoot("codex-conversation-reply")
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent"), "threadId": .string("thread-original")])
        }
    )

    let result = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Please adjust the same implementation."),
            "conversation_id": .string("codex:thread-original"),
            "message_id": .string("codex-reply-1"),
            "__session_id": .string("agent-origin-session"),
        ],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("codex_message reply should return an object")
        return
    }
    #expect(object["conversationId"] == .string("codex:thread-original"))
    let payloads = await wakeup.all()
    #expect(payloads.count == 1)
    #expect(payloads[0]["threadId"] == .string("thread-original"))
    #expect(payloads[0]["sessionId"] == .string("agent-origin-session"))

    let retargetedDuplicate = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Please adjust the same implementation."),
            "conversation_id": .string("codex:different-thread"),
            "message_id": .string("codex-reply-1"),
            "__session_id": .string("agent-origin-session"),
        ],
        surface: "chat"
    )
    guard case .object(let retargetedObject) = retargetedDuplicate else {
        Issue.record("retargeted duplicate should return an object")
        return
    }
    #expect(retargetedObject["reason"] == .string("message_id_conflict"))
    #expect(await wakeup.all().count == 1)

    let mismatch = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Wrong worker must not run."),
            "conversation_id": .string("claude:wake-parity"),
        ],
        surface: "chat"
    )
    guard case .object(let mismatchObject) = mismatch else {
        Issue.record("mismatched conversation should return an object")
        return
    }
    #expect(mismatchObject["status"] == .string("failed"))
    #expect(mismatchObject["reason"] == .string("conversation_agent_mismatch"))
    #expect(await wakeup.all().count == 1)

    let malformed = try await tools.dispatch(
        tool: "codex_message",
        input: ["text": .string("Malformed reference must not start fresh."), "conversation_id": .int(42)],
        surface: "chat"
    )
    guard case .object(let malformedObject) = malformed else {
        Issue.record("malformed conversation should return an object")
        return
    }
    #expect(malformedObject["reason"] == .string("invalid_conversation_id"))
    #expect(await wakeup.all().count == 1)
}

/// C9-1 (upgrade sweep 2026-08-28). 75 of the 101 live `claude_message`
/// failures in the trace feed were `"conversation_id": ""` rejected as
/// `invalid_conversation_id`. An empty reference is the same statement as an
/// omitted one — "this is new work" — and the tool description literally tells
/// the model to omit the key for that. Models that cannot emit an absent
/// optional send "". Pin BOTH halves: empty starts a fresh conversation, and a
/// genuinely malformed reference still fails (negative control, so a future
/// "be lenient" edit cannot quietly turn this into a fuzzy match).
@Test
func swiftToolDispatcher_emptyConversationReferenceStartsFreshInsteadOfFailing() async throws {
    let root = try makeTempRoot("builder-empty-conversation")
    let claudeWakeup = CodexWakeupInputRecorder()
    let codexWakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await codexWakeup.append(input)
            return .object(["status": .string("sent"), "threadId": .string("thread-fresh")])
        },
        claudeMessageWakeupOverride: { input in
            await claudeWakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    for empty in ["", "   "] {
        let result = try await tools.dispatch(
            tool: "claude_message",
            input: [
                "text": .string("New work, no prior conversation."),
                "conversation_id": .string(empty),
                "topic": .string("Upgrade Sweep C9"),
                "message_id": .string("claude-empty-\(empty.count)"),
            ],
            surface: "chat"
        )
        guard case .object(let object) = result else {
            Issue.record("claude_message should return an object")
            return
        }
        #expect(object["status"] == .string("accepted"))
        #expect(object["reason"] == nil)
        // Empty means absent, so the requested topic still mints the handle.
        #expect(object["conversationId"] == .string("claude:upgrade-sweep-c9"))
    }
    #expect(await claudeWakeup.all().count == 2)

    // Same rule on the codex twin, whose branch mints no id without a topic.
    let codexResult = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("New codex work."),
            "conversation_id": .string(""),
            "working_directory": .string(""),
            "message_id": .string("codex-empty-1"),
        ],
        surface: "chat"
    )
    guard case .object(let codexObject) = codexResult else {
        Issue.record("codex_message should return an object")
        return
    }
    #expect(codexObject["reason"] == nil)
    #expect(await codexWakeup.all().count == 1)

    // Negative control: a non-empty but unparseable reference STILL fails.
    let malformed = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Garbage reference must not start fresh."),
            "conversation_id": .string("not-a-reference"),
            "message_id": .string("claude-malformed-1"),
        ],
        surface: "chat"
    )
    guard case .object(let malformedObject) = malformed else {
        Issue.record("malformed reference should return an object")
        return
    }
    #expect(malformedObject["status"] == .string("failed"))
    #expect(malformedObject["reason"] == .string("invalid_conversation_id"))
    #expect(await claudeWakeup.all().count == 2)
}

/// The worktree allocator's `isFollowUp` has to answer "was a conversation
/// referenced?" the SAME way `builderConversationSelection` does, or empty is
/// only half-absent: the allocator would take the follow-up branch and reject
/// a caller-supplied `working_directory` as a follow-up directory conflict on
/// work the selector just called brand new. One rule, all three call sites.
@Test
func swiftToolDispatcher_conversationReferencePresenceUsesOneRule() {
    #expect(SwiftToolDispatcher.builderConversationReferenceSupplied(in: [:]) == false)
    #expect(SwiftToolDispatcher.builderConversationReferenceSupplied(
        in: ["conversation_id": .string("")]) == false)
    #expect(SwiftToolDispatcher.builderConversationReferenceSupplied(
        in: ["conversation_id": .string("   ")]) == false)
    #expect(SwiftToolDispatcher.builderConversationReferenceSupplied(
        in: ["conversation_id": .string("claude:topic")]) == true)
    // A wrong-typed value is malformed, not absent: the selector must get the
    // chance to reject it rather than have this quietly restart the thread.
    #expect(SwiftToolDispatcher.builderConversationReferenceSupplied(
        in: ["conversation_id": .int(42)]) == true)
}

@Test
func swiftToolDispatcher_builderReviewPairPropagatesWithoutChangingOrdinaryMessages() async throws {
    let root = try makeTempRoot("builder-review-pair")
    let codexWakeup = CodexWakeupInputRecorder()
    let claudeWakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await codexWakeup.append(input)
            return .object(["status": .string("sent"), "threadId": .string("paired-codex")])
        },
        claudeMessageWakeupOverride: { input in
            await claudeWakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let codex = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Build the focused change."),
            "message_id": .string("paired-codex-message"),
            "pair_reviewer": .bool(true),
        ],
        surface: "chat"
    )
    guard case .object(let codexObject) = codex else {
        Issue.record("paired codex_message should return an object")
        return
    }
    #expect(codexObject["reviewerPairRequested"] == .bool(true))
    #expect(codexObject["reviewerPaired"] == nil)
    #expect((await codexWakeup.all()).first?["pairReviewer"] == .bool(true))

    let claude = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Build another focused change."),
            "topic": .string("paired-claude"),
            "message_id": .string("paired-claude-message"),
            "pair_reviewer": .bool(true),
        ],
        surface: "chat"
    )
    guard case .object(let claudeObject) = claude else {
        Issue.record("paired claude_message should return an object")
        return
    }
    #expect(claudeObject["reviewerPairRequested"] == .bool(true))
    #expect(claudeObject["reviewerPaired"] == nil)
    #expect((await claudeWakeup.all()).first?["pairReviewer"] == .bool(true))

    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("This ordinary note needs no reviewer."),
            "message_id": .string("ordinary-codex-message"),
        ],
        surface: "chat"
    )
    let codexPayloads = await codexWakeup.all()
    #expect(codexPayloads.count == 2)
    #expect(codexPayloads[1]["pairReviewer"] == nil)

    let invalid = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Invalid pairing must not queue."),
            "pair_reviewer": .string("yes"),
        ],
        surface: "chat"
    )
    guard case .object(let invalidObject) = invalid else {
        Issue.record("invalid pairing should return an object")
        return
    }
    #expect(invalidObject["status"] == .string("failed"))
    #expect(invalidObject["reason"] == .string("invalid_pair_reviewer"))
    #expect(await claudeWakeup.all().count == 1)
}

@Test
func swiftToolDispatcher_builderReviewRequestNeverClaimsPairingWhenWakeSkipsOrFails() async throws {
    let root = try makeTempRoot("builder-review-request-honesty")
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            let status = input["messageId"] == .string("codex-skipped") ? "skipped" : "failed"
            return .object(["status": .string(status)])
        },
        claudeMessageWakeupOverride: { input in
            let status = input["messageId"] == .string("claude-skipped") ? "skipped" : "failed"
            return .object(["status": .string(status)])
        }
    )

    for (tool, messageID, expectedWakeStatus) in [
        ("codex_message", "codex-skipped", "skipped"),
        ("codex_message", "codex-failed", "failed"),
        ("claude_message", "claude-skipped", "skipped"),
        ("claude_message", "claude-failed", "failed"),
    ] {
        let result = try await tools.dispatch(
            tool: tool,
            input: [
                "text": .string("Build with one paired reviewer."),
                "message_id": .string(messageID),
                "pair_reviewer": .bool(true),
            ],
            surface: "chat"
        )
        guard case .object(let object) = result,
              case .object(let wakeup)? = object["wakeup"] else {
            Issue.record("\(tool) \(expectedWakeStatus) wake should return a nested receipt")
            continue
        }
        #expect(object["status"] == .string(tool == "claude_message" && expectedWakeStatus == "failed" ? "failed" : "queued"))
        #expect(object["reviewerPairRequested"] == .bool(true))
        #expect(object["reviewerPaired"] == nil)
        #expect(wakeup["status"] == .string(expectedWakeStatus))
    }
}

@Test
func swiftToolDispatcher_claudeMessageQueuesInboxAndWakesClaudeSession() async throws {
    let root = try makeTempRoot("claude-message-wakeup")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object([
                "status": .string("sent"),
                "delivery": .string("fake_claude_thread_wakeup"),
                "topicSlug": .string("wake-parity"),
            ])
        }
    )

    let input: [String: JSONValue] = [
        "text": .string("write the parity proof artifact"),
        "priority": .string("important"),
        "topic": .string("wake parity"),
        "message_id": .string("claude-wake-1"),
        "__session_id": .string("agent-session-1"),
    ]
    let result = try await tools.dispatch(tool: "claude_message", input: input, surface: "chat")

    guard case .object(let obj) = result else {
        Issue.record("claude_message should return an object")
        return
    }
    #expect(obj["status"] == JSONValue.string("accepted"))
    #expect(obj["deduplicated"] == JSONValue.bool(false))
    #expect(obj["conversationId"] == JSONValue.string("claude:wake-parity"))
    #expect(obj["replyWith"] == JSONValue.string("claude_message"))

    guard let wakeupValue = obj["wakeup"], case .object(let receipt) = wakeupValue else {
        Issue.record("claude_message should carry a wakeup receipt")
        return
    }
    #expect(receipt["status"] == JSONValue.string("sent"))
    #expect(receipt["delivery"] == JSONValue.string("fake_claude_thread_wakeup"))

    let sent = await wakeup.all()
    #expect(sent.count == 1)
    #expect(sent.first?["messageId"] == JSONValue.string("claude-wake-1"))
    #expect(sent.first?["text"] == JSONValue.string("write the parity proof artifact"))
    #expect(sent.first?["priority"] == JSONValue.string("important"))
    #expect(sent.first?["topic"] == JSONValue.string("wake-parity"))
    #expect(sent.first?["source"] == JSONValue.string("claude_message"))
    #expect(sent.first?["sessionId"] == JSONValue.string("agent-session-1"))
    guard case .string(let inboxPath)? = sent.first?["inboxPath"] else {
        Issue.record("wakeup payload should carry the durable inbox path")
        return
    }
    #expect(inboxPath == obj["filePath"].flatMap { value -> String? in
        guard case .string(let path) = value else { return nil }
        return path
    })

    // Model the helper's durable consumption, which the recording override
    // deliberately does not perform. An unread inbox row alone is not proof
    // of admission; explicit retries of that case belong to BuilderInboxRecoveryTests.
    let inboxURL = URL(fileURLWithPath: inboxPath)
    var consumedRow = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: inboxURL))
    consumedRow["read"] = .bool(true)
    consumedRow["consumedAt"] = .string("2026-08-30T20:00:00Z")
    var consumedData = try JSONValue.object(consumedRow).serializedData(pretty: false)
    consumedData.append(0x0a)
    try consumedData.write(to: inboxURL, options: .atomic)

    // Replaying an already-consumed message must not start another wake.
    let replay = try await tools.dispatch(tool: "claude_message", input: input, surface: "chat")
    guard case .object(let replayObj) = replay,
          case .object(let replayReceipt)? = replayObj["wakeup"] else {
        Issue.record("claude_message replay should return a wakeup receipt")
        return
    }
    #expect(replayObj["deduplicated"] == JSONValue.bool(true))
    #expect(replayReceipt["status"] == JSONValue.string("deduplicated"))
    #expect(await wakeup.all().count == 1)
}

@Test
func swiftToolDispatcher_claudeConversationReferenceResumesTopicPointer() async throws {
    let root = try makeTempRoot("claude-conversation-reply")
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        claudeMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let first = try await tools.dispatch(
        tool: "claude_message",
        input: ["text": .string("Start new work."), "message_id": .string("claude-first")],
        surface: "chat"
    )
    guard case .object(let firstObject) = first,
          case .string(let conversationId)? = firstObject["conversationId"] else {
        Issue.record("first claude_message should return a conversation reference")
        return
    }
    #expect(conversationId.hasPrefix("claude:conversation-"))

    _ = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Continue with one adjustment."),
            "conversation_id": .string(conversationId),
            "message_id": .string("claude-reply"),
        ],
        surface: "chat"
    )
    let payloads = await wakeup.all()
    #expect(payloads.count == 2)
    let referenceTopic = String(conversationId.dropFirst("claude:".count))
    #expect(payloads[0]["topic"] == .string(referenceTopic))
    #expect(payloads[1]["topic"] == .string(referenceTopic))

    let mismatch = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Conflicting topic must fail."),
            "conversation_id": .string(conversationId),
            "topic": .string("another-topic"),
        ],
        surface: "chat"
    )
    guard case .object(let mismatchObject) = mismatch else {
        Issue.record("topic mismatch should return an object")
        return
    }
    #expect(mismatchObject["reason"] == .string("conversation_topic_mismatch"))
    #expect(await wakeup.all().count == 2)
}

@Test
func swiftToolDispatcher_asyncBuilderMessagesFailBeforeQueueWithoutReturnBridge() async throws {
    for tool in ["codex_message", "claude_message"] {
        let root = try makeTempRoot("\(tool)-missing-return")
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        let tools = SwiftToolDispatcher(dataRoot: root, agentBridgeConfigRoot: configRoot)
        let result = try await tools.dispatch(
            tool: tool,
            input: ["text": .string("round-trip probe")],
            surface: "chat"
        )
        guard case .object(let object) = result else {
            Issue.record("\(tool) should return an object")
            continue
        }
        #expect(object["status"] == .string("failed"))
        #expect(object["reason"] == .string("return_bridge_unavailable"))
        #expect(object["detail"] == .string("token_missing"))
        #expect(object["fix"] == .string("Keep NativeAgent open and retry. The authenticated local return bridge starts automatically; Developer Mode is not required."))
        let inboxName = tool == "codex_message" ? "codex-nativeagent-bridge" : "claude-bridge"
        #expect(FileManager.default.fileExists(
            atPath: configRoot.appendingPathComponent(inboxName, isDirectory: true).path
        ) == false)
    }
}

/// Serialized on purpose: both tests below mutate PROCESS-WIDE environment
/// (the kill switch and the helper's test seams). Run in parallel, the kill
/// switch leaks into the end-to-end test and turns a real wake into
/// `skipped:disabled_by_environment` — which is exactly how this suite failed
/// the first time it ran.
@Suite("claude_message wakeup (environment-mutating)", .serialized)
struct ClaudeMessageWakeupEnvironmentTests {

@Test
func claudeMessageWakeupKillSwitchAndMissingHelperFailHonestly() async throws {
    let root = try makeTempRoot("claude-message-killswitch")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)

    // Kill switch wins even when a readable helper is configured.
    setenv("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED", "1", 1)
    defer { unsetenv("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED") }
    let helper = claudeWakeupHelperScriptURL()
    let disabledTools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupHelperOverride: helper
    )
    let disabled = try await disabledTools.dispatch(
        tool: "claude_message",
        input: ["text": .string("kill switch check"), "message_id": .string("kill-switch-1")],
        surface: "chat"
    )
    guard case .object(let disabledObj) = disabled,
          case .object(let disabledReceipt)? = disabledObj["wakeup"] else {
        Issue.record("claude_message should carry a wakeup receipt when disabled")
        return
    }
    #expect(disabledObj["status"] == JSONValue.string("queued"))
    #expect(disabledReceipt["status"] == JSONValue.string("skipped"))
    #expect(disabledReceipt["reason"] == JSONValue.string("disabled_by_environment"))
    #expect(disabledReceipt["env"] == JSONValue.string("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED"))

    // The inbox append still happened — the wakeup is additive, never a gate.
    let inboxURL = configRoot
        .appendingPathComponent("claude-bridge", isDirectory: true)
        .appendingPathComponent("claude-inbox.jsonl")
    #expect(FileManager.default.fileExists(atPath: inboxURL.path))

    unsetenv("NATIVE_AGENT_CLAUDE_WAKEUP_DISABLED")
    let missingTools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupHelperOverride: root.appendingPathComponent("nope/claude_thread_wakeup.js")
    )
    let missing = try await missingTools.dispatch(
        tool: "claude_message",
        input: ["text": .string("missing helper check"), "message_id": .string("missing-helper-1")],
        surface: "chat"
    )
    guard case .object(let missingObj) = missing,
          case .object(let missingReceipt)? = missingObj["wakeup"] else {
        Issue.record("claude_message should carry a wakeup receipt when the helper is absent")
        return
    }
    #expect(missingReceipt["status"] == JSONValue.string("skipped"))
    #expect(missingReceipt["reason"] == JSONValue.string("helper_not_found"))
}

/// End-to-end across the language seam: the real Node helper runs with a fake
/// `claude` binary and a dry-run bridge, and its envelope has to arrive inside
/// the tool result. Build-green does not prove this path; running it does.
@Test
func claudeMessageRunsTheRealHelperEndToEnd() async throws {
    let helper = claudeWakeupHelperScriptURL()
    guard FileManager.default.isReadableFile(atPath: helper.path) else {
        Issue.record("script/claude_thread_wakeup.js is missing")
        return
    }
    let root = try makeTempRoot("claude-message-e2e")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let bridgeDir = root.appendingPathComponent("claude-bridge", isDirectory: true)
    try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
    let fakeClaude = root.appendingPathComponent("fake-claude.sh")
    try "#!/bin/sh\necho \"artifact written by the fake claude\"\n"
        .write(to: fakeClaude, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

    setenv("NATIVE_AGENT_CLAUDE_BRIDGE_DIR", bridgeDir.path, 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN", fakeClaude.path, 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_CWD", root.path, 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_INLINE", "1", 1)
    setenv("NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN", "1", 1)
    // 2026-09-06: the helper grew a LIVE-SESSION GUARD (a8d506f7) — it scans
    // the process table and, when an interactive Claude is already open on
    // this Mac, leaves the message in the durable inbox and returns
    // `delivered_live` instead of spawning. That guard is correct and runs
    // under the app's real env, but it makes this end-to-end assertion depend
    // on whether the developer happens to have Claude Code open. The helper's
    // own Node suite already opts out through this seam
    // (script/tests/claude_thread_wakeup.test.js); the Swift twin was left
    // behind. Opting out here is what makes the spawn path the thing under
    // test again — the guard itself is covered on the Node side.
    setenv("NATIVE_AGENT_CLAUDE_WAKE_IGNORE_INTERACTIVE", "1", 1)
    defer {
        unsetenv("NATIVE_AGENT_CLAUDE_BRIDGE_DIR")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_CWD")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_INLINE")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN")
        unsetenv("NATIVE_AGENT_CLAUDE_WAKE_IGNORE_INTERACTIVE")
    }

    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        claudeMessageWakeupHelperOverride: helper
    )
    let result = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("prove the wake path"),
            "topic": .string("Wake Parity"),
            "message_id": .string("e2e-wake-1"),
            "__session_id": .string("e2e-origin-session"),
        ],
        surface: "chat"
    )

    guard case .object(let obj) = result,
          case .object(let receipt)? = obj["wakeup"] else {
        Issue.record("claude_message should carry the real helper's envelope")
        return
    }
    #expect(receipt["status"] == JSONValue.string("completed"))
    #expect(receipt["delivery"] == JSONValue.string("claude_thread_wakeup"))
    #expect(receipt["topicSlug"] == JSONValue.string("wake-parity"))
    #expect(receipt["messageId"] == JSONValue.string("e2e-wake-1"))
    #expect(receipt["helper"] == JSONValue.string(helper.path))
    guard case .object(let bridge)? = receipt["bridge"] else {
        Issue.record("the real helper should return its delivery receipt")
        return
    }
    #expect(bridge["status"] == .string("dry_run"))

    // The would-be bridge text carries the reply and the loop guard.
    guard case .string(let wouldSend)? = receipt["wouldSendText"] else {
        Issue.record("dry-run helper should return the text it would post to Agent")
        return
    }
    #expect(wouldSend.contains("artifact written by the fake claude"))
    #expect(wouldSend.contains("Do NOT auto-fire another claude_message"))

    // And a durable receipt landed on disk.
    let deliveries = bridgeDir.appendingPathComponent("wake-deliveries.jsonl")
    let raw = try String(contentsOf: deliveries, encoding: .utf8)
    #expect(raw.contains("e2e-wake-1"))
}

}

private func claudeWakeupHelperScriptURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ChatOrchestrationTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("script/claude_thread_wakeup.js")
        .standardizedFileURL
}

@Test
func swiftToolDispatcher_retiredGithubCommandSurfaceCannotSelectCodexWorkspace() async throws {
    let root = try makeTempRoot("codex-message-workspace")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let checkout = root.appendingPathComponent("target-checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let retiredSurface = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("trusted github work"),
            "message_id": .string("github-workspace"),
            "working_directory": .string(checkout.path),
        ],
        surface: "github-command"
    )
    let ordinaryChat = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("ordinary chat"),
            "message_id": .string("chat-workspace"),
            "working_directory": .string(checkout.path),
        ],
        surface: "chat"
    )

    #expect(await wakeup.all().isEmpty)
    for result in [retiredSurface, ordinaryChat] {
        guard case .object(let deniedObject) = result else {
            Issue.record("caller-supplied working_directory should return a denial envelope")
            continue
        }
        #expect(deniedObject["reason"] == .string("working_directory_outside_workspace_denied"))
    }
}

@Test
func swiftToolDispatcher_fullMacChatPassesExplicitProjectToCodexAndClaude() async throws {
    let root = try makeTempRoot("full-mac-agent-bridge-cwd")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let project = root.appendingPathComponent("external-project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try writeTrustPolicy(dataRoot, .object([
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "shell_allowed": .bool(true),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ]))

    let codex = CodexWakeupInputRecorder()
    let claude = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await codex.append(input)
            return .object(["status": .string("sent")])
        },
        claudeMessageWakeupOverride: { input in
            await claude.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let common: [String: JSONValue] = [
        "text": .string("inspect and build this project"),
        "working_directory": .string(project.path),
    ]
    _ = try await tools.dispatch(tool: "codex_message", input: common, surface: "chat")
    _ = try await tools.dispatch(tool: "claude_message", input: common, surface: "chat")

    let codexInputs = await codex.all()
    let claudeInputs = await claude.all()
    #expect(codexInputs.first?["workingDirectory"] == .string(project.path))
    #expect(claudeInputs.first?["cwd"] == .string(project.path))
}

@Test
func swiftToolDispatcher_asyncBuilderSchemasAdvertiseExplicitWorkingDirectory() throws {
    let dispatcher = SwiftToolDispatcher(dataRoot: FileManager.default.temporaryDirectory)
    for name in ["codex_message", "claude_message"] {
        let schema = try #require(
            dispatcher.builtInToolSchemas(includeFullMacFileTools: false).first { $0.name == name }
        )
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let root) = parsed,
              case .object(let properties)? = root["properties"] else {
            Issue.record("\(name) schema is malformed")
            return
        }
        #expect(properties["working_directory"] != nil)
    }
}

@Test
func swiftToolDispatcher_nonFullMacChatRejectsExplicitExternalBridgeProject() async throws {
    let root = try makeTempRoot("non-full-mac-agent-bridge-cwd")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let project = root.appendingPathComponent("external-project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let codex = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: root.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await codex.append(input)
            return .object(["status": .string("sent")])
        }
    )
    let result = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("inspect this project"),
            "working_directory": .string(project.path),
        ],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("expected denial envelope")
        return
    }
    #expect(object["reason"] == .string("working_directory_outside_workspace_denied"))
    let dispatched = await codex.all()
    #expect(dispatched.isEmpty)
}

@discardableResult
private func runRepositoryTestGit(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// The absolute shared object store behind a checkout or one of its worktrees.
/// Two paths reporting the same value are provably the same repository.
private func repositoryTestCommonGitDirectory(_ directory: URL) throws -> String {
    let raw = try runRepositoryTestGit(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        at: directory
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }
    return URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
}

/// The `repository` opt-in is the whole point of the change: chat may name a
/// repo (never a path) and get a verified checkout + network profile, while a
/// same-named directory pointing at a DIFFERENT remote must never resolve.
@Test
func swiftToolDispatcher_codexMessageRepositoryResolvesOnlyVerifiedRemote() async throws {
    let root = try makeTempRoot("codex-message-repository")
    let configRoot = root.appendingPathComponent("config", isDirectory: true)
    let searchRoot = root.appendingPathComponent("Projects", isDirectory: true)

    // Decoy: right folder name, wrong remote.
    let decoy = searchRoot.appendingPathComponent("hermes-agent", isDirectory: true)
    // Real: different folder name, correct remote.
    let real = searchRoot.appendingPathComponent("hermes-agent-contrib", isDirectory: true)
    try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try runRepositoryTestGit(["init", "-q"], at: decoy)
    try runRepositoryTestGit(["remote", "add", "origin", "https://github.com/someone/unrelated.git"], at: decoy)
    try runRepositoryTestGit(["init", "-q"], at: real)
    try runRepositoryTestGit(["remote", "add", "origin", "https://github.com/NousResearch/hermes-agent.git"], at: real)

    let resolved = GitHubCommandCheckoutResolver.resolve(
        repository: "NousResearch/hermes-agent",
        headSHA: nil,
        dataRoot: root,
        searchRoots: [searchRoot]
    )
    #expect(resolved?.standardizedFileURL == real.standardizedFileURL)

    // A repository that exists nowhere locally resolves to nil rather than
    // guessing a directory.
    let missing = GitHubCommandCheckoutResolver.resolve(
        repository: "NousResearch/not-cloned-here",
        headSHA: nil,
        dataRoot: root,
        searchRoots: [searchRoot]
    )
    #expect(missing == nil)

    // End to end through the tool: chat names the repo and gets the profile.
    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: configRoot,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )
    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("unknown repository"),
            "message_id": .string("repo-unknown"),
            "repository": .string("NousResearch/not-cloned-here"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    // A count mismatch must fail this test, not force-index a crash that takes
    // the whole test process (and every test after it) down with it.
    let sent = try #require(inputs.first)
    // Unresolvable repository degrades to today's behavior: message still
    // sends, but with no directory and no elevated profile.
    #expect(sent["workingDirectory"] == nil)
    #expect(sent["executionProfile"] == nil)
}

/// The positive half of the wiring: a repository that DOES resolve must reach
/// the wakeup with both a working directory derived from the verified checkout
/// and the elevated execution profile, from an ordinary chat surface. Since
/// `bac13d70` that directory is the builder's isolated worktree of the resolved
/// repository rather than the checkout itself. This drives the resolver's real
/// defaultSearchRoots (dataRoot is <base>/NativeAgent/data, so <base> is a
/// search root) rather than injecting searchRoots the tool path cannot pass.
///
/// The fixture repository name is deliberately one that cannot exist on a real
/// machine: defaultSearchRoots also scans the real home (~/Projects, ~/.hermes,
/// ~/Developer), so a common name like NousResearch/hermes-agent would resolve
/// against the developer's actual clone and make this test machine-dependent.
@Test
func swiftToolDispatcher_codexMessageRepositoryGrantsProfileFromChat() async throws {
    let base = try makeTempRoot("codex-message-repository-hit")
    let dataRoot = base
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let checkout = base.appendingPathComponent("nativeagent-repo-optin-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try runRepositoryTestGit(["init", "-q"], at: checkout)
    try runRepositoryTestGit(
        ["remote", "add", "origin", "https://github.com/nativeagent-tests/nativeagent-repo-optin-fixture.git"],
        at: checkout
    )
    // A real checkout always has a commit. Without one, HEAD is unborn and the
    // builder worktree allocator cannot branch from it -- an artifact of the
    // fixture, not of the repository opt-in this test covers.
    try runRepositoryTestGit(["config", "user.name", "NativeAgent Test"], at: checkout)
    try runRepositoryTestGit(["config", "user.email", "nativeagent-test@example.invalid"], at: checkout)
    try runRepositoryTestGit(["config", "commit.gpgsign", "false"], at: checkout)
    try Data("fixture\n".utf8).write(to: checkout.appendingPathComponent("README.md"))
    try runRepositoryTestGit(["add", "."], at: checkout)
    try runRepositoryTestGit(["commit", "-q", "-m", "fixture"], at: checkout)

    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: base.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("rebase and push"),
            "message_id": .string("repo-hit"),
            "repository": .string("nativeagent-tests/nativeagent-repo-optin-fixture"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    // Guarded, not force-indexed: a count mismatch fails this test instead of
    // trapping and killing every remaining test in the process.
    let sent = try #require(inputs.first)
    #expect(sent["executionProfile"] == .string("github-command-repository-network-v1"))

    // Since the builder worktree allocator landed, a resolved Git checkout is
    // handed to the builder as its own isolated worktree rather than the
    // checkout itself. Pin that the directory really is derived from the
    // repository this test resolved -- same Git object store, distinct
    // working tree -- so the assertion cannot be satisfied by an unrelated path.
    guard case .string(let workingDirectory)? = sent["workingDirectory"] else {
        Issue.record("codex_message sent no workingDirectory for a resolved repository")
        return
    }
    let worktree = URL(fileURLWithPath: workingDirectory)
        .standardizedFileURL.resolvingSymlinksInPath()
    #expect(worktree.path != checkout.standardizedFileURL.resolvingSymlinksInPath().path)
    let worktreeStore = try repositoryTestCommonGitDirectory(worktree)
    let checkoutStore = try repositoryTestCommonGitDirectory(checkout)
    #expect(!worktreeStore.isEmpty)
    #expect(worktreeStore == checkoutStore)
}

/// Slug extraction from request prose. Pure string work -- the resolver still
/// decides whether any candidate is a real checkout.
@Test
func swiftToolDispatcher_repositorySlugCandidatesFromRequestText() {
    // A GitHub URL is the strongest signal and wins outright.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "Please rebase https://github.com/NousResearch/hermes-agent/pull/64288 onto main"
    ) == ["NousResearch/hermes-agent"])

    // The real SSH form uses a colon, not a slash.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "clone git@github.com:acme/widget.git"
    ) == ["acme/widget"])
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "clone https://github.com/acme/widget.git"
    ) == ["acme/widget"])

    // A bare slug is accepted only when no URL named a repository.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "sync NousResearch/hermes-agent for me"
    ) == ["NousResearch/hermes-agent"])

    // URL beats the bare token when both appear.
    #expect(SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "see github.com/acme/widget, not other/thing"
    ) == ["acme/widget"])

    // Path-shaped and malformed tokens never become candidates.
    let noise = SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "check /etc/passwd and ~/Projects/secret and owner/../../etc and a/b/c and just-a-word"
    )
    #expect(noise.isEmpty)

    // Ambiguity is preserved for the resolver to reject, not silently collapsed.
    let two = SwiftToolDispatcher.repositorySlugCandidates(
        inRequestText: "compare github.com/acme/widget with github.com/acme/gadget"
    )
    #expect(two == ["acme/widget", "acme/gadget"])

    // The resolver's work stays bounded no matter how slug-shaped the prose is.
    let many = (1...20).map { "owner\($0)/name\($0)" }.joined(separator: " ")
    #expect(SwiftToolDispatcher.repositorySlugCandidates(inRequestText: many).count == 8)
}

/// The 2026-08-05 regression: Agent omitted `repository`, so the send carried no
/// execution profile, Codex had no GitHub network path, and the turn ground to a
/// silent harness kill. The profile must now attach from the request text alone.
@Test
func swiftToolDispatcher_codexMessageInfersRepositoryFromRequestText() async throws {
    let base = try makeTempRoot("codex-message-repository-inferred")
    let dataRoot = base
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let checkout = base.appendingPathComponent("nativeagent-inferred-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try runRepositoryTestGit(["init", "-q"], at: checkout)
    try runRepositoryTestGit(
        ["remote", "add", "origin", "https://github.com/nativeagent-tests/nativeagent-inferred-fixture.git"],
        at: checkout
    )
    // A real checkout always has a commit. Without one, HEAD is unborn and the
    // builder worktree allocator cannot branch from it -- an artifact of the
    // fixture, not of the inference this test covers.
    try runRepositoryTestGit(["config", "user.name", "NativeAgent Test"], at: checkout)
    try runRepositoryTestGit(["config", "user.email", "nativeagent-test@example.invalid"], at: checkout)
    try runRepositoryTestGit(["config", "commit.gpgsign", "false"], at: checkout)
    try Data("fixture\n".utf8).write(to: checkout.appendingPathComponent("README.md"))
    try runRepositoryTestGit(["add", "."], at: checkout)
    try runRepositoryTestGit(["commit", "-q", "-m", "fixture"], at: checkout)

    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: base.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    // No `repository`, no `working_directory` -- only prose naming the repo.
    let response = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Rebase https://github.com/nativeagent-tests/nativeagent-inferred-fixture/pull/64288 onto main and push."),
            "message_id": .string("repo-inferred"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    // Guarded, not force-indexed: a count mismatch fails this test instead of
    // trapping and killing every remaining test in the process.
    let sent = try #require(inputs.first)
    #expect(sent["executionProfile"] == .string("github-command-repository-network-v1"))
    // The builder worktree allocator hands the builder an isolated worktree of
    // the inferred checkout, not the checkout itself. Pin that it really is
    // derived from this repository: same Git object store, distinct work tree.
    let workingDirectory = try #require(
        sent["workingDirectory"].flatMap { if case .string(let s) = $0 { s } else { nil } },
        "codex_message sent no workingDirectory for an inferred repository"
    )
    let worktree = URL(fileURLWithPath: workingDirectory)
        .standardizedFileURL.resolvingSymlinksInPath()
    #expect(worktree.path != checkout.standardizedFileURL.resolvingSymlinksInPath().path)
    let worktreeStore = try repositoryTestCommonGitDirectory(worktree)
    #expect(!worktreeStore.isEmpty)
    #expect(worktreeStore == (try repositoryTestCommonGitDirectory(checkout)))
    // The auto-attach is observable at the call site, not silent.
    if case .object(let object) = response {
        #expect(object["executionProfile"] == .string("github-command-repository-network-v1"))
        #expect(object["repositorySource"] == .string("inferred_from_request"))
    } else {
        Issue.record("codex_message returned a non-object response")
    }
}

/// Prose naming NO resolvable repository must degrade to today's behavior rather
/// than handing Codex a network-enabled checkout of something adjacent.
@Test
func swiftToolDispatcher_codexMessageInferenceDegradesWhenNothingResolves() async throws {
    let base = try makeTempRoot("codex-message-repository-inferred-miss")
    let dataRoot = base
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let wakeup = CodexWakeupInputRecorder()
    let tools = SwiftToolDispatcher(
        dataRoot: dataRoot,
        agentBridgeConfigRoot: base.appendingPathComponent("config", isDirectory: true),
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakeup.append(input)
            return .object(["status": .string("sent")])
        }
    )

    _ = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Look at github.com/nativeagent-tests/never-cloned-anywhere please."),
            "message_id": .string("repo-inferred-miss"),
        ],
        surface: "chat"
    )

    let inputs = await wakeup.all()
    #expect(inputs.count == 1)
    #expect(inputs[0]["workingDirectory"] == nil)
    #expect(inputs[0]["executionProfile"] == nil)
}

/// A model must not be able to smuggle path syntax through `repository`.
@Test
func swiftToolDispatcher_repositorySlugRejectsPathShapedInput() {
    #expect(SwiftToolDispatcher.isWellFormedRepositorySlug("NousResearch/hermes-agent"))
    #expect(SwiftToolDispatcher.isWellFormedRepositorySlug("owner/name.with.dots"))

    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("/etc"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("~/Projects/secret"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/../../etc"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/name/extra"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug(""))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/na me"))
    #expect(!SwiftToolDispatcher.isWellFormedRepositorySlug("owner/name;rm -rf /"))
}

@Test
func swiftToolDispatcher_codexExecArguments_matchCurrentCli() async throws {
    let args = SwiftToolDispatcher.codexExecArguments(
        sandbox: "read-only",
        cwd: "/tmp/nativeagent",
        lastMessagePath: "/tmp/nativeagent/last-message.txt",
        model: "gpt-6-astra",
        reasoningEffort: "xhigh",
        serviceTier: "priority",
        prompt: "return OK"
    )

    #expect(Array(args.prefix(3)) == ["codex", "exec", "--ephemeral"])
    #expect(!args.contains("--ask-for-approval"))
    #expect(args.contains("--sandbox"))
    #expect(args.contains("read-only"))
    #expect(args.contains("-C"))
    #expect(args.contains("/tmp/nativeagent"))
    #expect(args.contains("-o"))
    #expect(args.contains("/tmp/nativeagent/last-message.txt"))
    #expect(args.contains("-m"))
    #expect(args.contains("gpt-6-astra"))
    #expect(args.contains("model_reasoning_effort=\"xhigh\""))
    #expect(args.contains("service_tier=\"priority\""))
    #expect(args.last == "return OK")
}

@Test
func swiftToolDispatcher_codexBrainControlsValidateModelCapabilities() {
    let args = SwiftToolDispatcher.codexExecArguments(
        sandbox: "read-only", cwd: "/tmp/astra-fixture",
        lastMessagePath: "/tmp/astra-fixture/reply.txt",
        model: "gpt-6-astra", reasoningEffort: "medium", serviceTier: "default", prompt: "Reply OK"
    )
    #expect(args.contains("gpt-6-astra"))
    #expect(args.contains("model_reasoning_effort=\"medium\""))
    let astra = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string(" GPT-6-ASTRA "),
        "reasoning_effort": .string("ultra"),
        "fast": .bool(true),
    ])
    #expect(astra == .success(.init(
        model: "gpt-6-astra",
        reasoningEffort: "ultra",
        serviceTier: "priority",
        fast: true
    )))
    if case .success = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string("gpt-6-astra"),
        "reasoning_effort": .string("none"),
    ]) {
        Issue.record("Astra does not support None reasoning")
    }

    let terra = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string("gpt-5.6-terra"),
        "reasoning_effort": .string("extra high"),
        "fast": .bool(true),
    ])
    #expect(terra == .success(.init(
        model: "gpt-5.6-terra",
        reasoningEffort: "xhigh",
        serviceTier: "priority",
        fast: true
    )))

    let lunaUltra = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string("gpt-5.6-luna"),
        "reasoning_effort": .string("ultra"),
    ])
    guard case .failure(.invalidReasoningEffort(_, let model, let supported)) = lunaUltra else {
        Issue.record("Luna Ultra should fail before spawning Codex")
        return
    }
    #expect(model == "gpt-5.6-luna")
    #expect(supported.contains("max"))
    #expect(!supported.contains("ultra"))

    let legacy = SwiftToolDispatcher.codexBrainControls(from: [
        "model": .string("gpt-5.4"),
        "reasoning_effort": .string("high"),
    ])
    #expect(legacy == .success(.init(
        model: "gpt-5.4",
        reasoningEffort: "high",
        serviceTier: nil,
        fast: nil
    )))

}

@Test
func swiftToolDispatcher_invokeCodexDangerFullAccessRequiresDeveloperModePolicy() {
    #expect(SwiftToolDispatcher.codexDangerFullAccessAllowed(policy: [:]) == false)
    #expect(SwiftToolDispatcher.codexDangerFullAccessAllowed(policy: [
        "developerMode": .bool(false),
    ]) == false)
    #expect(SwiftToolDispatcher.codexDangerFullAccessAllowed(policy: [
        "developerMode": .bool(true),
    ]) == true)
}

private actor CodexWakeupInputRecorder {
    private var recorded: [[String: JSONValue]] = []

    func append(_ input: [String: JSONValue]) {
        recorded.append(input)
    }

    func all() -> [[String: JSONValue]] {
        recorded
    }
}

private final class FakeMacIntegrationBridgeForCodexMessage: MacIntegrationToolBridge, @unchecked Sendable {
    private let recorder = MacNotifyInputRecorder()

    func macNotifyInputs() async -> [[String: JSONValue]] {
        await recorder.all()
    }

    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        await recorder.append(input)
        return .object([
            "status": .string("completed"),
            "posted": .bool(true),
            "delivery": .string("fake_macos_notification"),
            "notificationId": .string("fake-notification-id"),
        ])
    }
    func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailSend(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicControl(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func mailReply(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue { stub() }
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue { stub() }

    private func stub() -> JSONValue {
        .object(["status": .string("stubbed")])
    }
}

private actor MacNotifyInputRecorder {
    private var recorded: [[String: JSONValue]] = []

    func append(_ input: [String: JSONValue]) {
        recorded.append(input)
    }

    func all() -> [[String: JSONValue]] {
        recorded
    }
}
