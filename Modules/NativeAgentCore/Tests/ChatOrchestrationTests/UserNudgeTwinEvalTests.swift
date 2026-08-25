import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter

// MARK: - evals-total-coverage · fence core.chat.engine
//
// Ledger rows closed here:
//   * chat.toolLoop.appendStructuredUserNudge     (UNCOVERED → COVERED)
//   * chat.nativeToolLane.appendNativeUserText    (UNCOVERED → COVERED)
//   * chat.toolLoop.remedy.announceContract       (UNCOVERED → COVERED)
//
// The two append helpers are DUPLICATED LOGIC with no shared test: one can be
// fixed without the other. Their whole job is preventing two consecutive user
// turns, which the Anthropic wire REJECTS — a hard 400 there, but SILENT for
// providers that tolerate it (those turns just get a malformed conversation and
// degraded answers). Every assertion below runs against BOTH twins from one
// table so they cannot diverge.
//
// The remedy row pins the three properties that make the bounce a working
// control rather than dead text: a user-role nudge MERGES into the trailing
// user turn, first- and second-bounce wordings DIFFER, and each bounce costs
// exactly one extra provider call.

// MARK: - twin table

/// The two production twins, addressed uniformly so every case runs on both.
private func userTextAppenders() -> [(name: String, apply: (String, inout [LLMMessage]) -> Void)] {
    [
    (
        "SwiftNativeTurnEngine.appendStructuredUserNudge",
        { text, conversation in
            SwiftNativeTurnEngine.appendStructuredUserNudge(text, to: &conversation)
        }
    ),
    (
        "SwiftNativeChatOrchestrationClient.appendNativeUserText",
        { text, conversation in
            SwiftNativeChatOrchestrationClient.appendNativeUserText(text, to: &conversation)
        }
    ),
    ]
}

private func textBlocks(_ message: LLMMessage) -> [String] {
    message.content.compactMap {
        if case .text(let t) = $0 { return t }
        return nil
    }
}

// MARK: - chat.toolLoop.appendStructuredUserNudge / chat.nativeToolLane.appendNativeUserText

@Test
func userNudgeTwins_mergeIntoTrailingUserMessage_neverTwoConsecutiveUserTurns() {
    for twin in userTextAppenders() {
        var conversation: [LLMMessage] = [.user("original question")]
        twin.apply("NUDGE", &conversation)

        #expect(conversation.count == 1, "\(twin.name) created a second user message")
        #expect(conversation[0].role == .user, "\(twin.name)")
        #expect(textBlocks(conversation[0]) == ["original question", "NUDGE"], "\(twin.name)")
        // The wire invariant, stated directly: no two adjacent user roles.
        #expect(!hasConsecutiveUserTurns(conversation), "\(twin.name)")
    }
}

@Test
func userNudgeTwins_appendStandaloneAfterAssistantMessage() {
    for twin in userTextAppenders() {
        var conversation: [LLMMessage] = [.user("q"), .assistantText("a")]
        twin.apply("NUDGE", &conversation)

        #expect(conversation.count == 3, "\(twin.name)")
        #expect(conversation[2].role == .user, "\(twin.name)")
        #expect(textBlocks(conversation[2]) == ["NUDGE"], "\(twin.name)")
        #expect(!hasConsecutiveUserTurns(conversation), "\(twin.name)")
    }
}

@Test
func userNudgeTwins_emptyConversationStandsAlone() {
    for twin in userTextAppenders() {
        var conversation: [LLMMessage] = []
        twin.apply("NUDGE", &conversation)
        #expect(conversation.count == 1, "\(twin.name)")
        #expect(conversation[0] == .user("NUDGE"), "\(twin.name)")
    }
}

@Test
func userNudgeTwins_mergeOntoAToolResultUserTurn_preservingBlockOrder() {
    // The real shape at the bounce site: the previous iteration appended ONE
    // user message carrying tool_result blocks. A fresh `.user(...)` here is
    // exactly the two-consecutive-user-turns bug; the nudge must ride as a
    // trailing text block, AFTER the tool results.
    for twin in userTextAppenders() {
        var conversation: [LLMMessage] = [
            .user("q"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "c1", name: "read_file", inputJSON: Data("{}".utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "c1", content: "file body", isError: false),
            ]),
        ]
        twin.apply("NUDGE", &conversation)

        #expect(conversation.count == 3, "\(twin.name) appended instead of merging")
        let last = conversation[2]
        #expect(last.role == .user, "\(twin.name)")
        #expect(last.content.count == 2, "\(twin.name)")
        if case .toolResult(let id, _, _) = last.content[0] {
            #expect(id == "c1", "\(twin.name)")
        } else {
            Issue.record("\(twin.name): tool_result block was displaced")
        }
        #expect(textBlocks(last) == ["NUDGE"], "\(twin.name)")
        #expect(!hasConsecutiveUserTurns(conversation), "\(twin.name)")
    }
}

@Test
func userNudgeTwins_repeatedNudgesStillProduceExactlyOneTrailingUserTurn() {
    for twin in userTextAppenders() {
        var conversation: [LLMMessage] = [.user("q")]
        twin.apply("first", &conversation)
        twin.apply("second", &conversation)
        #expect(conversation.count == 1, "\(twin.name)")
        #expect(textBlocks(conversation[0]) == ["q", "first", "second"], "\(twin.name)")
    }
}

@Test
func userNudgeTwins_produceByteIdenticalConversationsForTheSameInputs() {
    // The anti-divergence assertion: same inputs, same output, for every shape
    // above. Fixing one twin and not the other fails HERE.
    let seeds: [[LLMMessage]] = [
        [],
        [.user("q")],
        [.user("q"), .assistantText("a")],
        [
            .user("q"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "c1", name: "t", inputJSON: Data("{}".utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "c1", content: "r", isError: false),
            ]),
        ],
    ]
    for seed in seeds {
        var structured = seed
        var native = seed
        SwiftNativeTurnEngine.appendStructuredUserNudge("N", to: &structured)
        SwiftNativeChatOrchestrationClient.appendNativeUserText("N", to: &native)
        #expect(structured == native, "twins diverged for seed of \(seed.count) messages")
    }
}

private func hasConsecutiveUserTurns(_ conversation: [LLMMessage]) -> Bool {
    guard conversation.count > 1 else { return false }
    for index in 1..<conversation.count
    where conversation[index].role == .user && conversation[index - 1].role == .user {
        return true
    }
    return false
}

// MARK: - chat.toolLoop.remedy.announceContract — the remedy TEXTS

@Test
func structuredRemedies_firstAndSecondBounceWordingsDiffer_andStayOffTheMarkerProtocol() {
    // Silent-failure class: dead control. If the escalation collapses to one
    // wording the loop just bounces twice and gives up, and the user sees a
    // shorter, vaguer answer with no signal that two provider calls were spent.
    let announceFirst = ToolCallParser.structuredAnnounceContractRemedy(secondBounce: false)
    let announceSecond = ToolCallParser.structuredAnnounceContractRemedy(secondBounce: true)
    let emptyFirst = ToolCallParser.structuredEmptyReplyRemedy(secondBounce: false)
    let emptySecond = ToolCallParser.structuredEmptyReplyRemedy(secondBounce: true)

    #expect(announceFirst != announceSecond)
    #expect(emptyFirst != emptySecond)
    // The two REMEDIES must also be distinguishable from each other — an empty
    // reply must never be scolded for "narrating".
    #expect(announceFirst != emptyFirst)
    #expect(announceSecond != emptySecond)

    // Escalation is legible to the model, not just different bytes.
    #expect(announceSecond.contains("SECOND"))
    #expect(emptySecond.contains("SECOND"))
    #expect(announceSecond.lowercased().contains("last continuation"))
    #expect(emptySecond.lowercased().contains("last continuation"))

    for remedy in [announceFirst, announceSecond, emptyFirst, emptySecond] {
        #expect(!remedy.isEmpty)
        // The STRUCTURED lane speaks the provider's native tool-call
        // convention; leaking the text-marker protocol here teaches the model
        // to emit markers the structured parser treats as a violation.
        #expect(!remedy.contains("<tool_use"))
        #expect(!remedy.contains("</tool_use>"))
    }
}

// MARK: - chat.toolLoop.remedy.announceContract — the remedy WIRING

/// Captures both the messages array AND the tools array of every provider call.
private final class WireCapturingLLM: LLMClient, @unchecked Sendable {
    private let scripted: [String]
    nonisolated(unsafe) private var _messages: [[LLMMessage]] = []
    nonisolated(unsafe) private var _tools: [[LLMToolSchema]] = []

    init(scripted: [String]) { self.scripted = scripted }

    var capturedMessages: [[LLMMessage]] { _messages }
    var capturedTools: [[LLMToolSchema]] { _tools }
    var callCount: Int { _messages.count }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        next([], nil)
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        next(messages, tools)
    }

    private func next(_ messages: [LLMMessage], _ tools: [LLMToolSchema]?) -> String {
        _messages.append(messages)
        _tools.append(tools ?? [])
        let idx = _messages.count - 1
        guard !scripted.isEmpty else { return "" }
        return scripted[min(idx, scripted.count - 1)]
    }
}

private final class SchemaToolDispatchForRemedy: ToolDispatchClient, @unchecked Sendable {
    private let scripted: [String: JSONValue]
    init(scripted: [String: JSONValue]) { self.scripted = scripted }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        scripted[tool] ?? .null
    }
    func listAvailableTools() async throws -> [String] { scripted.keys.sorted() }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        scripted.keys.sorted().map {
            LLMToolSchema(
                name: $0,
                description: "test tool \($0)",
                parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
            )
        }
    }
}

private final class RemedyRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "test-model", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

private struct RemedyPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private func makeRemedyEngine(
    llm: any LLMClient,
    tools: any ToolDispatchClient
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: RemedyPersona(),
        memory: nil,
        router: RemedyRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

@Test
func announceBounce_appendsNarrationThenRemedy_andCostsExactlyOneExtraCall() async throws {
    let tools = SchemaToolDispatchForRemedy(scripted: ["recall_memory": .string("clean")])
    // Announce, announce, then a real answer: two bounces, then accepted.
    let llm = WireCapturingLLM(scripted: [
        "Reading the README now.",
        "Now onto the build files.",
        "The build pipeline is documented across three files.",
    ])
    let engine = makeRemedyEngine(llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "what does the readme say?", llm: llm, tools: tools
    )

    #expect(result.reply == "The build pipeline is documented across three files.")
    // Exactly one extra provider call per bounce: 1 (announce) + 1 (bounce) + 1.
    #expect(result.providerCallCount == 3)
    #expect(llm.callCount == 3)

    // Call 2 and call 3 each carry a nudge, and neither ever produced two
    // consecutive user turns — the wire invariant both bounce shapes must hold.
    for (index, conversation) in llm.capturedMessages.enumerated() {
        #expect(!hasConsecutiveUserTurns(conversation), "call \(index + 1)")
    }

    // LEDGER CORRECTION (verified at ChatOrchestration+ToolLoop.swift:1874):
    // the ANNOUNCE bounce does not go through appendStructuredUserNudge — it
    // appends the model's narration as an assistant message FIRST and then a
    // standalone user remedy, which preserves alternation by construction. The
    // merge helper is the EMPTY-reply bounce's shape (no assistant text exists),
    // asserted in the sibling test below. Both are pinned so a refactor that
    // swaps one for the other trips here.
    let secondCall = llm.capturedMessages[1]
    #expect(secondCall.count == 3)
    #expect(secondCall[0].role == .user)
    #expect(textBlocks(secondCall[0]) == ["what does the readme say?"])
    #expect(secondCall[1].role == .assistant)
    #expect(textBlocks(secondCall[1]) == ["Reading the README now."])
    #expect(secondCall[2].role == .user)
    #expect(textBlocks(secondCall[2])
        == [ToolCallParser.structuredAnnounceContractRemedy(secondBounce: false)])

    // Call 3 carries the ESCALATED wording, and it differs from the first.
    let thirdCall = llm.capturedMessages[2]
    #expect(thirdCall.count == 5)
    #expect(thirdCall[3].role == .assistant)
    #expect(textBlocks(thirdCall[3]) == ["Now onto the build files."])
    #expect(thirdCall[4].role == .user)
    #expect(textBlocks(thirdCall[4])
        == [ToolCallParser.structuredAnnounceContractRemedy(secondBounce: true)])
    #expect(textBlocks(thirdCall[2]) != textBlocks(thirdCall[4]))
}

@Test
func emptyReplyBounce_nudgeMergesIntoTrailingUserTurn_withEscalatedSecondWording() async throws {
    let tools = SchemaToolDispatchForRemedy(scripted: ["recall_memory": .string("clean")])
    let llm = WireCapturingLLM(scripted: ["", "", "finally an answer"])
    let engine = makeRemedyEngine(llm: llm, tools: tools)

    let result = try await engine.executeTurnWithToolLoop(
        userMessage: "status?", llm: llm, tools: tools
    )

    #expect(result.reply == "finally an answer")
    #expect(result.providerCallCount == 3)

    let secondBlocks = textBlocks(llm.capturedMessages[1][0])
    #expect(secondBlocks.last == ToolCallParser.structuredEmptyReplyRemedy(secondBounce: false))
    let thirdBlocks = textBlocks(llm.capturedMessages[2][0])
    #expect(thirdBlocks.last == ToolCallParser.structuredEmptyReplyRemedy(secondBounce: true))
    for conversation in llm.capturedMessages {
        #expect(!hasConsecutiveUserTurns(conversation))
    }
}
