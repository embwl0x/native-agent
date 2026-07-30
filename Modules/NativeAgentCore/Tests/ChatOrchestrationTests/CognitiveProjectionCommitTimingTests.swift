import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
@testable import ProviderRouting
import TrustCenter
import CognitiveSubstrate

// MARK: - R-F1 (whole-ship audit round 2, 2026-07-17): projection commit timing
//
// The turn projection used to be committed at context ASSEMBLY — before the
// provider ever saw the turn. A 529 on the first provider call then consumed
// the 20-min felt Body-line suppress window for a line the model never
// received (the quick retry omitted it), and the Observatory labeled a
// never-delivered capsule `.liveInjected`. These tests pin the corrected
// contract at the orchestration layer:
//
//   1. provider failure  → ZERO commits (the retry keeps the felt line)
//   2. provider success  → exactly ONE commit
//   3. multi-round tool loop (several provider calls in one turn) → still ONE
//   4. streaming-path failure → ZERO commits
//
// The success-path commit==1 expectations already live in
// ChatOrchestrationClientTests (chatClient_usesOneCombinedCognitiveProjection…);
// this file owns the failure/timing side.

// MARK: - Helpers (redeclared fileprivate so this file compiles standalone)

private func makeTempRootPCT(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("proj-commit-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeTrustPolicyPCT(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bytes = try policy.serializedData(pretty: false)
    try bytes.write(to: dir.appendingPathComponent("policy.json"))
}

private final class StubRoutingPCT: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "client-model", reasoningEffort: "high")]
    }
}

/// Counts prepare/commit calls and remembers what was committed. The capsule
/// carries a felt Body: marker so the delivered-content claim is inspectable.
private actor CommitCountingCognitionPCT: CognitiveRuntimeProviding {
    private var projectionCalls = 0
    private var commitCalls = 0
    private var committedCapsules: [CognitiveCapsule] = []

    func observe(_ event: CognitiveEvent) async {}

    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? { nil }

    func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitiveTurnProjection {
        projectionCalls += 1
        let fixedAt = Date(timeIntervalSince1970: 9_000)
        return CognitiveTurnProjection(
            fixedAt: fixedAt,
            capsule: CognitiveCapsule(
                generatedAt: fixedAt,
                mode: .inject,
                stableKernel: "How you feel:",
                dynamicContext: "Body: warm and settled — commit-timing marker",
                provenanceNodeIds: [],
                truncated: false
            ),
            posture: OrganismBehaviorPosture?.none
        )
    }

    func commitTurnProjection(
        _ projection: CognitiveTurnProjection,
        request: CognitiveCapsuleRequest
    ) async {
        commitCalls += 1
        if let capsule = projection.capsule {
            committedCapsules.append(capsule)
        }
    }

    func counts() -> (projection: Int, commit: Int) {
        (projectionCalls, commitCalls)
    }

    func committed() -> [CognitiveCapsule] {
        committedCapsules
    }
}

/// Mirrors the 529/overloaded shape: every provider call fails before a reply.
private final class FailingMessagesLLMPCT: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    private func fail() throws -> Never {
        lock.lock(); _calls += 1; lock.unlock()
        throw LLMError.transient(message: "upstream 529: overloaded")
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try fail()
    }
    func complete(prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?) async throws -> String {
        try fail()
    }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        try fail()
    }
}

/// Returns one scripted reply per provider round-trip (tool loop makes several).
private final class ScriptedMessagesLLMPCT: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var _calls = 0
    init(responses: [String]) { self.responses = responses }
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    private func next() -> String {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return responses.isEmpty ? "scripted-exhausted" : responses.removeFirst()
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String { next() }
    func complete(prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?) async throws -> String { next() }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String { next() }
}

/// Streaming client that fails mid-stream (compat path's -1005/overloaded case).
/// Tracks invocation so the failure test can't pass vacuously if routing ever
/// stops reaching the streaming provider (gpt-5.5 review note, 2026-07-17).
private final class FailingStreamingLLMPCT: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _streamCalls = 0
    var streamCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _streamCalls
    }
    private func recordCall() {
        lock.lock(); _streamCalls += 1; lock.unlock()
    }
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        recordCall()
        return AsyncThrowingStream { cont in
            cont.yield("par")
            cont.finish(throwing: LLMError.transient(message: "stream dropped mid-turn"))
        }
    }
    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?,
        surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        recordCall()
        return AsyncThrowingStream { cont in
            cont.yield(.textDelta("par"))
            cont.finish(throwing: LLMError.transient(message: "stream dropped mid-turn"))
        }
    }
}

/// C-H1 (2026-07-18): scripts one STREAMED reply per provider round-trip for
/// the Anthropic text-compatibility path. Emits tool markers for the first N-1
/// calls and a plain reply on call N, so the text-compat tool loop runs exactly
/// N iterations — one `streamTurn` (hence one provider completion) each.
private final class ScriptedTextCompatStreamingLLMPCT: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var _calls = 0
    init(responses: [String]) { self.responses = responses }
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    private func next() -> String {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return responses.isEmpty ? "scripted-exhausted" : responses.removeFirst()
    }
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        let text = next()
        return AsyncThrowingStream { cont in cont.yield(text); cont.finish() }
    }
    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?,
        surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let text = next()
        return AsyncThrowingStream { cont in cont.yield(.textDelta(text)); cont.finish() }
    }
}

private final class ScriptedToolDispatchPCT: ToolDispatchClient, @unchecked Sendable {
    private let schemas: [LLMToolSchema]
    private let scripted: [String: JSONValue]
    init(schemas: [LLMToolSchema], scripted: [String: JSONValue]) {
        self.schemas = schemas
        self.scripted = scripted
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        scripted[tool] ?? .null
    }
    func listAvailableTools() async throws -> [String] { schemas.map(\.name).sorted() }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { schemas }
}

private func makeEnginePCT(root: URL, llm: any LLMClient, tools: any ToolDispatchClient) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: SwiftNativePersonaEngine(root: root),
        memory: nil,
        router: StubRoutingPCT(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
}

private func makeClientPCT(
    root: URL,
    llm: any LLMClient,
    tools: any ToolDispatchClient,
    cognition: CommitCountingCognitionPCT,
    streaming: (any StreamingLLMClient)? = nil
) -> SwiftNativeChatOrchestrationClient {
    SwiftNativeChatOrchestrationClient(
        engine: makeEnginePCT(root: root, llm: llm, tools: tools),
        tools: tools,
        llm: llm,
        streamingLLM: streaming,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root),
        cognitiveObserver: cognition,
        cognitiveContextProvider: cognition
    )
}

// MARK: - Tests

@Test
func projectionCommit_providerFailure_doesNotConsumeTheWindow() async throws {
    let root = try makeTempRootPCT("provider-fail")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = FailingMessagesLLMPCT()
    let tools = MockToolDispatchClient()
    let cognition = CommitCountingCognitionPCT()
    let client = makeClientPCT(root: root, llm: llm, tools: tools, cognition: cognition)

    await #expect(throws: (any Error).self) {
        _ = try await client.chat(
            message: "hello before the 529",
            sessionId: "s-commit-529",
            model: "client-model",
            reasoningEffort: "high",
            fileAccess: "workspace",
            attachments: [],
            suppressUserAppend: false
        )
    }

    let counts = await cognition.counts()
    #expect(llm.calls >= 1, "the provider must actually have been called")
    #expect(counts.projection == 1, "the projection is still prepared once per turn")
    #expect(counts.commit == 0,
            "a turn the provider never accepted must NOT consume the Body-line suppress window or the Observatory live label — the retry re-delivers the felt line")
}

@Test
func projectionCommit_retryAfterFailure_deliversAndCommitsTheFeltLine() async throws {
    // The full 529-then-retry shape at this layer: failed turn commits nothing,
    // the retry prepares a fresh projection and commits exactly once — so the
    // suppress window is consumed by the capsule the model actually received.
    let root = try makeTempRootPCT("retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let failing = FailingMessagesLLMPCT()
    let tools = MockToolDispatchClient()
    let cognition = CommitCountingCognitionPCT()
    let failingClient = makeClientPCT(root: root, llm: failing, tools: tools, cognition: cognition)

    await #expect(throws: (any Error).self) {
        _ = try await failingClient.chat(
            message: "first attempt",
            sessionId: "s-commit-retry",
            model: "client-model",
            reasoningEffort: "high",
            fileAccess: "workspace",
            attachments: [],
            suppressUserAppend: false
        )
    }
    #expect(await cognition.counts().commit == 0)

    let retryLLM = ScriptedMessagesLLMPCT(responses: ["all good now"])
    let retryClient = makeClientPCT(root: root, llm: retryLLM, tools: tools, cognition: cognition)
    let response = try await retryClient.chat(
        message: "second attempt",
        sessionId: "s-commit-retry",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(response.output == "all good now")
    let counts = await cognition.counts()
    #expect(counts.projection == 2)
    #expect(counts.commit == 1, "only the delivered turn commits")
    let committed = await cognition.committed()
    #expect(committed.count == 1)
    #expect(committed.first?.dynamicContext.contains("Body: warm and settled") == true,
            "the committed capsule is the one carrying the felt Body: line the model saw")
}

@Test
func projectionCommit_toolLoopWithMultipleProviderCalls_commitsExactlyOnce() async throws {
    let root = try makeTempRootPCT("tool-loop")
    defer { try? FileManager.default.removeItem(at: root) }
    // Pin the tool to auto so dispatch isn't gated by default-policy semantics.
    try writeTrustPolicyPCT(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git commits.",
        parametersJSON: Data(#"{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(
        schemas: [schema],
        scripted: ["git_log": .object(["status": .string("ok")])]
    )
    let llm = ScriptedMessagesLLMPCT(responses: [
        #"<tool_use name="git_log">{"limit":5}</tool_use>"#,
        "done after the tool round",
    ])
    let cognition = CommitCountingCognitionPCT()
    let client = makeClientPCT(root: root, llm: llm, tools: tools, cognition: cognition)

    let response = try await client.chat(
        message: "look at commits",
        sessionId: "s-commit-toolloop",
        model: "client-model",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    )

    #expect(response.output == "done after the tool round")
    #expect(llm.calls == 2, "the tool loop must have made two provider round-trips")
    let counts = await cognition.counts()
    #expect(counts.projection == 1)
    #expect(counts.commit == 1,
            "several provider calls in one turn still commit the projection exactly once")
}

@Test
func projectionCommit_streamingFailure_doesNotCommit() async throws {
    let root = try makeTempRootPCT("stream-fail")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = FailingMessagesLLMPCT()
    let tools = MockToolDispatchClient()
    let cognition = CommitCountingCognitionPCT()
    let streaming = FailingStreamingLLMPCT()
    let client = makeClientPCT(
        root: root, llm: llm, tools: tools, cognition: cognition,
        streaming: streaming
    )

    var finalReply: String?
    do {
        for try await event in client.chatStream(
            message: "stream me",
            sessionId: "s-commit-streamfail",
            model: "claude-opus-4-8",
            reasoningEffort: "high",
            fileAccess: "workspace",
            attachments: [],
            suppressUserAppend: false
        ) {
            if case .final(let result) = event {
                finalReply = result.reply
            }
        }
    } catch {
        // Thrown or value-error surfaced — either way, no .final and no commit.
    }

    #expect(finalReply == nil, "a failed stream must not produce a final reply")
    #expect(streaming.streamCalls >= 1,
            "the streaming provider must actually have been invoked — a zero-commit result with zero calls would be vacuous")
    let counts = await cognition.counts()
    #expect(counts.commit == 0,
            "a stream the provider dropped must not consume the suppress window")
}

// MARK: - C-H1 (tightness round 2, 2026-07-18): text-compat providerCallCount
//
// The structured streaming loop counts provider calls (B3); the PRIMARY
// Anthropic/Claude path (text compatibility) emitted providerCallCount:nil at
// every result site, so ChatDrive/eval aggregations undercounted the main chat
// surface. This pins the loop-owner's count: N tool-loop iterations → exactly N
// provider round-trips → providerCallCount == N on the final result.

@Test
func textCompat_providerCallCount_equalsToolLoopIterations() async throws {
    let root = try makeTempRootPCT("text-compat-callcount")
    defer { try? FileManager.default.removeItem(at: root) }
    // Pin the tool to auto so dispatch isn't gated by default-policy semantics.
    try writeTrustPolicyPCT(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git commits.",
        parametersJSON: Data(#"{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(
        schemas: [schema],
        scripted: ["git_log": .object(["status": .string("ok")])]
    )
    // Two tool rounds (DISTINCT inputs so the no-progress guard never stops the
    // loop early) then a final reply → exactly 3 provider round-trips.
    let streaming = ScriptedTextCompatStreamingLLMPCT(responses: [
        #"<tool_use name="git_log">{"limit":1}</tool_use>"#,
        #"<tool_use name="git_log">{"limit":2}</tool_use>"#,
        "done after two tool rounds",
    ])
    let cognition = CommitCountingCognitionPCT()
    let client = makeClientPCT(
        root: root,
        llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools,
        cognition: cognition,
        streaming: streaming
    )

    var finalResult: TurnEngineResult?
    // model "claude-*" + surface "chat" (default) routes to runTextStreamingCompatibility.
    for try await event in client.chatStream(
        message: "look at commits",
        sessionId: "s-textcompat-callcount",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalResult = result }
    }

    #expect(streaming.calls == 3,
            "the tool loop must make one streamed provider round-trip per iteration")
    #expect(finalResult?.reply == "done after two tool rounds")
    #expect(finalResult?.providerCallCount == 3,
            "text-compat must report providerCallCount == the number of tool-loop iterations (C-H1)")
}

// MARK: - Announce-without-act guard + tool-routing hint (Kimi K3 Telegram
// incident, 2026-07-19): weak-tool-discipline models on the text-compat path
// ended turns with "on it — checking now" and ZERO dispatches, and fetched
// github.com with generic web tools while github_* sat loaded. These pin the
// one-nudge bounce and the provider-visible routing hint.

@Test
func promiseDetector_matchesImmediateActionPromisesOnly() {
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("On it — checking now."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("Right, let me check your GitHub."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("Loading it now."))
    // Round 2 — the LITERAL replies from the 2026-07-19 Telegram incident
    // that the phrase whitelist missed. These must match forever.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Local copy exists — going through the actual files now."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("Reading the README now."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Right — I don't need to guess URLs when I have the actual connection. Checking your repos directly now."))
    // Round 3 — the verbless forward-reference fragment from the live
    // Continuum turn ("found it… then stopped"). Must match forever.
    // (Same sentence shape as the live incident reply; repo/owner genericized
    // — the public-export privacy guard rightly rejects personal identifiers.)
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Found it: acme/widget-engine — private, Rust, 10 open issues. Now the issues and the code itself."))
    // Forward word + completion verb = a report, never bounced.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Now the tests are green."))
    // Round 4 — the literal post-round-3 stall: adverb between "let me" and
    // the verb defeated the phrase list. Must match forever.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Fair — the README's the pitch, not the work. Let me actually look at what's built."))
    // Same construction in a QUESTION stays a valid stop.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Want me to actually look at what's built?"))
    // Round 5 — live battery catch: bare-gerund-first stopping sentence with
    // no "now" anywhere. THE general announcement shape.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Checking the transcript for that exchange before I answer."))
    // Gerund-first REPORT (completion verb present) stays a valid stop.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Checking finished — all 316 tests are green."))
    // Round 6 — live marathon catch (2026-07-20): filler adverb ahead of the
    // gerund defeated the gerund-FIRST rule. Must match forever.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "First volley landed — 11 dispatches so far, zero errors. "
        + "Now loading the file/git/telegram tools so I can finish the battery for real."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Okay, now checking the desk for what's actionable."))
    // Filler + gerund REPORT (completion verb present) stays a valid stop.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Now checking is done — everything passed."))
    // Questions back to the user are valid stopping points.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("Want me to check your GitHub?"))
    // Completed work described with the same verbs stays a valid stop.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "The suite just finished running now — all 316 green."))
    // Long substantive answers never match, even containing a phrase.
    let long = "Here's the full rundown of your repos. " + String(repeating: "Detail. ", count: 80)
        + "Let me check one more thing tomorrow."
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(long))
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("Your Continuum repo has 3 open PRs."))
}

// MARK: - Round-3 audit fence W4: false-positive shapes that bounced finished
// reports (F2-M1/M2/M3, F2-L1/L2). Each of these is a COMPLETED short reply the
// detector used to wrongly bounce; they must now be accepted (return false),
// while the live-incident corpus above must still match.

@Test
func promiseDetector_pastTenseReports_areNotBounced() {
    // F2-M1: gerund-first sentence whose main verb is PAST TENSE = a report.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Reviewing the PR, I left 3 comments."))
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Running the benchmark took 4 seconds."))
    // F2-L2: verbless forward-reference shape whose clause is a past-tense report.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("Then the app crashed."))
    // -ed regular past tense also reads as a report.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Checking the config, I noticed the flag was already flipped."))
    // The past-tense exemption is SCOPED to the gerund + verbless rules: a
    // present/future promise with a past-tense word elsewhere still bounces via
    // the deferred-intent rule ("built" is not in the final clause's verb slot).
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Fair — the README's the pitch, not the work. Let me actually look at what's built."))
}

@Test
func promiseDetector_alreadyActedReports_areNotBounced() {
    // F2-M2: the raw-substring "on it." FP inside a completed report.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("I already acted on it."))
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Done — I already checked that and pushed the fix."))
    // A bare terminal acknowledgment with nothing delivered still bounces.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("On it."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("On it — checking now."))
}

@Test
func promiseDetector_decisionIdioms_areNotBounced() {
    // F2-M3: go/take/see decision idioms are choices, not deferred action.
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("I'll go with option A."))
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("I'll take that approach."))
    #expect(!ToolCallParser.looksLikeUnfulfilledActionPromise("Let me go with the simpler design."))
    // The genuine deferred-action forms are still caught by their real rules.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("Let me check the logs."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("Let me see what the tests say."))
}

@Test
func promiseDetector_curlyApostrophePositives_stillMatch() {
    // F2-L1: U+2019 / U+02BC smart apostrophes must not defeat the i'll / let me
    // matchers — the curly variants of known positives MUST still bounce.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("I\u{2019}ll check your GitHub."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("Right, let me check your GitHub."))
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise(
        "Fair \u{2014} the README\u{2019}s the pitch. Let me actually look at what\u{2019}s built."))
    // Modifier-letter apostrophe (U+02BC) variant.
    #expect(ToolCallParser.looksLikeUnfulfilledActionPromise("I\u{02BC}ll pull the diff now."))
}

@Test
func textCompat_narrationAfterDispatchesStillBounces() async throws {
    // The round-1 miss: two dispatches, then "going through the files now",
    // then STOP. dispatches-nonempty must not exempt the promise check.
    let root = try makeTempRootPCT("text-compat-midtask-narration")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTrustPolicyPCT(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log", description: "Read recent git commits.",
        parametersJSON: Data(#"{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(
        schemas: [schema],
        scripted: ["git_log": .object(["status": .string("ok")])]
    )
    let streaming = ScriptedTextCompatStreamingLLMPCT(responses: [
        #"<tool_use name="git_log">{"limit":1}</tool_use>"#,
        "Local copy exists — going through the actual files now.",
        "It's a Rust scheduler: three crates, CI green.",
    ])
    let client = makeClientPCT(
        root: root, llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools, cognition: CommitCountingCognitionPCT(), streaming: streaming
    )
    var finalResult: TurnEngineResult?
    for try await event in client.chatStream(
        message: "look at commits", sessionId: "s-midtask-narration",
        model: "claude-opus-4-8", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalResult = result }
    }
    #expect(streaming.calls == 3, "dispatch → narration bounce → real final = 3 calls")
    #expect(finalResult?.reply == "It's a Rust scheduler: three crates, CI green.")
    #expect(finalResult?.toolDispatches.count == 1)
}

@Test
func textCompat_announceWithoutAct_getsOneNudgeThenActs() async throws {
    let root = try makeTempRootPCT("text-compat-announce-nudge")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTrustPolicyPCT(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git commits.",
        parametersJSON: Data(#"{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(
        schemas: [schema],
        scripted: ["git_log": .object(["status": .string("ok")])]
    )
    // Iteration 1: promise with no marker → nudged (not final). Iteration 2:
    // real tool call. Iteration 3: final reply. 3 provider round-trips total.
    let streaming = ScriptedTextCompatStreamingLLMPCT(responses: [
        "On it — checking now.",
        #"<tool_use name="git_log">{"limit":1}</tool_use>"#,
        "two commits, both green",
    ])
    let client = makeClientPCT(
        root: root,
        llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools,
        cognition: CommitCountingCognitionPCT(),
        streaming: streaming
    )
    var finalResult: TurnEngineResult?
    for try await event in client.chatStream(
        message: "look at commits",
        sessionId: "s-announce-nudge",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalResult = result }
    }
    #expect(streaming.calls == 3, "promise → nudge → tool round → final = 3 provider calls")
    #expect(finalResult?.reply == "two commits, both green")
    #expect(finalResult?.toolDispatches.count == 1, "the nudged turn must actually dispatch")
}

@Test
func textCompat_secondPromiseIsAcceptedAsFinal_noLoop() async throws {
    let root = try makeTempRootPCT("text-compat-nudge-once")
    defer { try? FileManager.default.removeItem(at: root) }
    let schema = LLMToolSchema(
        name: "git_log", description: "x",
        parametersJSON: Data(#"{"type":"object","properties":{},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(schemas: [schema], scripted: [:])
    let streaming = ScriptedTextCompatStreamingLLMPCT(responses: [
        "On it — checking now.",
        "Let me check that now.",
        "Reading the README now.",
        "never-reached",
    ])
    let client = makeClientPCT(
        root: root,
        llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools,
        cognition: CommitCountingCognitionPCT(),
        streaming: streaming
    )
    var finalResult: TurnEngineResult?
    for try await event in client.chatStream(
        message: "look at commits",
        sessionId: "s-nudge-once",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        fileAccess: "workspace",
        attachments: [],
        suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalResult = result }
    }
    // TWO bounces max: the third promise is accepted as the final reply —
    // the guard can never loop a model that refuses to act, and never
    // reaches the fourth scripted response.
    #expect(streaming.calls == 3)
    #expect(finalResult?.reply == "Reading the README now.")
}

// MARK: - K3 empty-reply recovery (2026-07-20)

private final class ThrowingThenScriptedStreamingLLMPCT: StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<String, Error>]
    private var _calls = 0
    init(responses: [Result<String, Error>]) { self.responses = responses }
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    private func next() -> Result<String, Error> {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return responses.isEmpty ? .success("scripted-exhausted") : responses.removeFirst()
    }
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        let r = next()
        return AsyncThrowingStream { cont in
            switch r {
            case .success(let text): cont.yield(text); cont.finish()
            case .failure(let err): cont.finish(throwing: err)
            }
        }
    }
    func streamMessages(
        messages: [LLMMessage], system: String?, model: String?,
        surface: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let r = next()
        // LANE-AWARE (2026-07-20, kimi-native-tools): these K3 scenarios script
        // tool calls as text-compat MARKERS, but k3 now rides the provider-
        // native tools lane, where marker text is just prose and the loop
        // consumes structured tool_use blocks instead. A non-nil `tools` array
        // is precisely the signal that this request declared tools natively —
        // so speak the protocol the request asked for and re-emit a scripted
        // marker as a native .toolCall. The scenarios keep pinning what they
        // were written to pin (empty-reply recovery; the retry-unsafe marker
        // after tool effects) on the lane K3 actually runs today.
        let native = tools != nil
        return AsyncThrowingStream { cont in
            switch r {
            case .success(let text):
                if native, let call = Self.nativeCallFromMarker(text) {
                    cont.yield(.toolCall(call))
                } else {
                    cont.yield(.textDelta(text))
                }
                cont.finish()
            case .failure(let err): cont.finish(throwing: err)
            }
        }
    }

    /// `<tool_use name="X">{json}</tool_use>` → a native tool call. Returns nil
    /// for ordinary prose, which then streams as text.
    private static func nativeCallFromMarker(_ text: String) -> LLMStreamToolCall? {
        guard let nameRange = text.range(of: #"<tool_use name=""#),
              let nameEnd = text.range(of: #"">"#, range: nameRange.upperBound..<text.endIndex),
              let close = text.range(of: "</tool_use>", range: nameEnd.upperBound..<text.endIndex)
        else { return nil }
        let name = String(text[nameRange.upperBound..<nameEnd.lowerBound])
        let json = String(text[nameEnd.upperBound..<close.lowerBound])
        return LLMStreamToolCall(
            id: "tool_scripted_\(name)",
            name: name,
            inputJSON: Data(json.utf8)
        )
    }
}

private let emptyReplyErrorPCT = LLMError.transient(
    message: "kimi-code: HTTP 200 with no answer text (stop_reason=end_turn; content: thinking×1)")

@Test
func textCompat_emptyReplyGetsNudgedThenActs() async throws {
    // The 13:08Z live kill: K3 returned thinking-only/zero-text right after
    // tool_load, and identical whole-turn replays failed identically. The
    // loop must recover IN-TURN: swallow the empty-reply error, feed the
    // model a corrective message, and continue — never surface the error.
    let root = try makeTempRootPCT("text-compat-empty-reply-nudge")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTrustPolicyPCT(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log",
        description: "Read recent git commits.",
        parametersJSON: Data(#"{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(
        schemas: [schema],
        scripted: ["git_log": .object(["status": .string("ok")])]
    )
    let streaming = ThrowingThenScriptedStreamingLLMPCT(responses: [
        .failure(emptyReplyErrorPCT),
        .success(#"<tool_use name="git_log">{"limit":1}</tool_use>"#),
        .success("two commits, both green"),
    ])
    let client = makeClientPCT(
        root: root,
        llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools,
        cognition: CommitCountingCognitionPCT(),
        streaming: streaming
    )
    var finalResult: TurnEngineResult?
    var sawErrorEvent = false
    for try await event in client.chatStream(
        message: "look at commits", sessionId: "s-empty-reply-nudge",
        model: "k3", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalResult = result }
        if case .error = event { sawErrorEvent = true }
    }
    #expect(streaming.calls == 3, "empty → nudge → tool round → final = 3 provider calls")
    #expect(!sawErrorEvent, "recovered empty reply must never surface as an error")
    #expect(finalResult?.reply == "two commits, both green")
    #expect(finalResult?.toolDispatches.count == 1)
}

@Test
func textCompat_persistentEmptyRepliesFailHonestlyAfterTwoNudges() async throws {
    // A provider that only ever thinks gets exactly two recoveries, then the
    // third empty reply surfaces as a real error — bounded, no infinite loop.
    let root = try makeTempRootPCT("text-compat-empty-reply-bound")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = ScriptedToolDispatchPCT(schemas: [], scripted: [:])
    let streaming = ThrowingThenScriptedStreamingLLMPCT(responses: [
        .failure(emptyReplyErrorPCT),
        .failure(emptyReplyErrorPCT),
        .failure(emptyReplyErrorPCT),
        .success("never-reached"),
    ])
    let client = makeClientPCT(
        root: root,
        llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools,
        cognition: CommitCountingCognitionPCT(),
        streaming: streaming
    )
    var finalResult: TurnEngineResult?
    var errorMessage: String?
    for try await event in client.chatStream(
        message: "look at commits", sessionId: "s-empty-reply-bound",
        model: "k3", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        if case .final(let result) = event { finalResult = result }
        if case .error(let m) = event { errorMessage = m }
    }
    #expect(streaming.calls == 3, "two recoveries then honest failure — never a fourth call")
    #expect(finalResult == nil)
    #expect(errorMessage?.contains("no answer text") == true)
}

@Test
func textCompat_postToolEmptyExhaustionCarriesRetryUnsafeMarker() async throws {
    // gpt-5.5 BLOCKING (2026-07-20): engine-YIELDED .error events bypassed
    // the thrown-catch's post-tool-effect wrap, so a turn that dispatched
    // tools and then died on persistent empty replies surfaced a bare
    // retryable transient — Telegram would replay the whole handler and
    // re-run the tools. The terminal .error path must stamp the same
    // "whole-turn retry unsafe" marker contract.
    let root = try makeTempRootPCT("text-compat-empty-marker")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTrustPolicyPCT(root, .object([
        "toolAutonomy": .object(["git_log": .string("auto")]),
    ]))
    let schema = LLMToolSchema(
        name: "git_log", description: "Read recent git commits.",
        parametersJSON: Data(#"{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}"#.utf8)
    )
    let tools = ScriptedToolDispatchPCT(
        schemas: [schema],
        scripted: ["git_log": .object(["status": .string("ok")])]
    )
    let streaming = ThrowingThenScriptedStreamingLLMPCT(responses: [
        .success(#"<tool_use name="git_log">{"limit":1}</tool_use>"#),
        .failure(emptyReplyErrorPCT),
        .failure(emptyReplyErrorPCT),
        .failure(emptyReplyErrorPCT),
        .success("never-reached"),
    ])
    let client = makeClientPCT(
        root: root,
        llm: ScriptedMessagesLLMPCT(responses: []),
        tools: tools,
        cognition: CommitCountingCognitionPCT(),
        streaming: streaming
    )
    var errorMessage: String?
    for try await event in client.chatStream(
        message: "look at commits", sessionId: "s-empty-marker",
        model: "k3", reasoningEffort: "high",
        fileAccess: "workspace", attachments: [], suppressUserAppend: false
    ) {
        if case .error(let m) = event { errorMessage = m }
    }
    #expect(streaming.calls == 4, "tool round + 2 recoveries + terminal = 4 calls, never a 5th")
    #expect(errorMessage?.contains(ProviderErrorAfterToolEffects.markerPhrase) == true,
            "post-tool-effect terminal error must carry the retry-unsafe marker")
    #expect(errorMessage?.contains("no answer text") == true)
}
