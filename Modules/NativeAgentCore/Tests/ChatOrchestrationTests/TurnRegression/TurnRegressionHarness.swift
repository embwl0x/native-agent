import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import ProviderRouting

// MARK: - The end-to-end turn-regression harness
//
// User, 2026-09-02: "build the evals and tests and regression checks so that it
// tests that stuff too, so we don't go a while with stuff half working or
// failing like you found."
//
// The unit suites written this week each pin ONE organ in isolation
// (ConversationPrefixV2ProjectionTests, ConversationPrefixShapeV2Tests,
// ToolContractStabilityTests, FluidContextLeadAndStablePersonaTests …). Every
// defect they were written for was found the same way: someone read a live
// trace. None of them could have caught it, because each one is true about its
// own organ while the assembled TURN is wrong.
//
// This harness closes that gap. It drives SIX CONSECUTIVE TURNS of one 150-row
// session through the REAL seam every production chat turn crosses —
//
//     TurnContext                       (the real turn context type)
//       → SessionHistoryMessageProjection.project(…)      (the real projection)
//       → ConversationPrefixSeeding.seed(…)               (the real seeding)
//       → AnthropicOAuthDirectAdapter.makeMessagesRequestBody(…)
//                                                          (the real wire body)
//
// — and asserts on the BYTES the provider would receive. No URL stub, no
// shared static state, no network, no clock: the whole chain above is pure, so
// the suites built on it are hermetic by construction and finish in
// milliseconds.
//
// The stub streaming LLM (`TurnRegressionStubLLM`) is the same harness's other
// half: it satisfies the orchestrator's `MessagesStreamingLLMClient` seam and
// RECORDS every `(messages, system, tools)` triple handed to it, so a suite
// that wants the request the ENGINE produced (rather than one this file seeded)
// reads it off the double instead of guessing.
//
// Silent-failure class for everything below: a wrong value with no error. A
// prefix that re-churns, a capsule that stopped being attached, a tool array
// that reshuffled — all of them answer the user perfectly and cost full-price
// uncached input on every turn, forever, until someone reads a trace.

// MARK: - Fixtures shared by every suite in this directory

enum TurnRegression {
    static let surface = "chat"
    static let telegramSurface = "telegram"
    static let sessionId = "turn-regression"
    static let model = "claude-fable-5-1"
    static let providerId = "anthropic_oauth_direct"
    static let historyLimit = 80
    static let maxTokens = 4_096

    /// A hermetic data root. Never `PersistenceCore.defaultDataRoot()`, which
    /// under `swift test` resolves to the LIVE app data root.
    static func dataRoot(_ label: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "turn-regression-\(label)-\(UUID().uuidString)", isDirectory: true
            )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Stable head

    /// The compiled persona packet: identity, voice, the user document, growth.
    /// Byte-stable across turns AND surfaces by construction — that stability
    /// is the entire reason it lives in the cached prefix.
    static let personaStable = """
    # SOUL
    You are the agent this installation configured. You keep your word.

    # VOICE
    Plain sentences. No hedging, no filler openers.

    # USER
    User builds NativeAgent. He reads diffs.

    # GROWTH
    Tie completion claims to observed results, not intention.

    Natural expression: write the way a person writes, not the way a form
    letter does.

    # Pinned facts (REM-approved overrides)
    - The canonical data root is the one the caller passed.
    """

    /// The session tool contract that rides the stable suffix on the text lane.
    static let stableSuffix = """
    # Session tool contract
    - tool_load is available; loading appends, it never reshuffles.
    """

    // MARK: The 150-row session

    /// 150 alternating rows carrying stable ids and run ids — the exact shape
    /// the live d83b71d3 session had when the head-drift defect was measured.
    static func session(rows: Int = 150) -> [ChatMessage] {
        let filler = String(repeating: "word ", count: 30)
        return (0..<rows).map { index in
            ChatMessage(
                role: index % 2 == 0 ? "user" : "assistant",
                content: "row\(index) \(filler)",
                timestamp: "2026-09-02T11:00:00Z",
                extras: .object([
                    "id": .string("m\(index)"),
                    "runId": .string("run-\(index / 2)"),
                ])
            )
        }
    }

    /// The persisted window boundary. The head must be a pure function of THIS
    /// value — nothing about the current turn may move it.
    static func cursor(boundary: String = "id\u{1F}m80") -> HistoryWindowCursor {
        HistoryWindowCursor(sessionId: sessionId, dropBoundaryIdentity: boundary)
    }

    /// The six questions of the six turns. They differ in every byte, which is
    /// the point: what the user just said must not move the replayed prefix.
    static let questions = [
        "what did we decide about the rollout",
        "never mind, show me the diff",
        "does that break the telegram surface",
        "ok ship it",
        "one more thing — where does the receipt land",
        "thanks, that is what I needed",
    ]

    // MARK: Per-turn volatile mass

    /// The dynamic segment: everything that legitimately churns per turn —
    /// digest, fluid packet, recall, derived history blocks, clock, plan hint,
    /// and the capsule as the LAST bytes before the user's message.
    static func dynamicSegment(turn: Int, capsule: String? = nil) -> String {
        var parts = [
            "# Since last session\n- \(turn) exchanges ago you were on the rollout.",
            "Relevant context:\n- [memory] the rollout gate is script/test.sh",
            "Recent memory:\n- hit \(turn)",
            "Local time: Monday, September 2, 2026 at 11:0\(turn) AM PDT.",
            "Turn plan: ordinary chat.",
        ]
        if let capsule, !capsule.isEmpty { parts.append(capsule) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Tools

    static func schema(_ name: String, description: String? = nil) -> LLMToolSchema {
        LLMToolSchema(
            name: name,
            description: description ?? "turn-regression tool \(name)",
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )
    }

    /// A realistic advertised set: the always-on floor plus two session loads.
    /// `context_expand` is deliberately in the floor — it is always advertised
    /// (2026-09-01), whether or not this turn's packet carries a pointer.
    /// Every name here is a REAL member of `SwiftToolDispatcher.alwaysOnCoreNames`
    /// — pinned below by `toolFloorFixtureIsTheRealAlwaysOnFloor`, so a fixture
    /// that drifts out of the production set fails instead of quietly testing
    /// a floor that does not exist.
    static let floorNames = [
        "commit_memory", "context_expand", "inner_state", "recall_memory",
        "tool_catalog", "tool_load",
    ]
    static let loadedNames = ["workshop_submit", "task_ledger_post"]

    static func tools(loaded: [String] = loadedNames) -> [LLMToolSchema] {
        (floorNames.sorted() + loaded).map { schema($0) }
    }

    // MARK: One turn, end to end

    struct Turn {
        let index: Int
        let seed: ConversationPrefixSeeding.Seed
        let telemetry: ConversationPrefixTelemetrySnapshot
        let body: [String: Any]

        var messages: [LLMMessage] { seed.messages }
        var digests: [String] { telemetry.messageDigests }
    }

    /// Build ONE turn's context exactly as the production seam does.
    static func context(
        turn: Int,
        session rows: [ChatMessage],
        cursor pinned: HistoryWindowCursor?,
        surface currentSurface: String = TurnRegression.surface,
        capsule: String? = nil,
        tools schemas: [LLMToolSchema] = TurnRegression.tools(),
        stable: String = TurnRegression.personaStable,
        stableSuffix suffix: String = "",
        archivedTurnMessages: [String: [LLMMessage]] = [:],
        windowReceipt: HistoryWindowReceipt? = HistoryWindowReceipt(advanceCount: 1, slid: false)
    ) -> TurnContext {
        let history = SessionHistoryMessageProjection.project(
            messages: rows,
            historyLimit: historyLimit,
            surface: currentSurface,
            windowTokens: nil,
            cursor: pinned,
            archivedTurnMessages: archivedTurnMessages
        ).messages
        let segments = SystemPromptSegments(
            stable: stable,
            stableSuffix: suffix,
            dynamic: dynamicSegment(turn: turn, capsule: capsule)
        )
        return TurnContext(
            surface: currentSurface,
            personaDocs: [:],
            recalled: [],
            modelId: model,
            reasoningEffort: "medium",
            providerId: providerId,
            toolsAvailable: schemas.map(\.name),
            systemPrompt: segments.combined,
            userMessage: questions[turn % questions.count],
            toolSchemas: schemas,
            systemSegments: segments,
            historyMessages: history,
            historyWindowReceipt: windowReceipt
        )
    }

    /// Seed + encode one context into the exact Anthropic request body.
    static func wire(
        _ context: TurnContext,
        index: Int,
        shape: ConversationPrefixShape = .v2Prefix,
        stream: Bool = true
    ) -> Turn {
        let seed = ConversationPrefixSeeding.seed(context, shape: shape)
        let fingerprint = SwiftNativeTurnEngine.toolSchemaFingerprint(context.toolSchemas)
        let telemetry = ConversationPrefixSeeding.telemetry(
            seed, shape: seed.shape, toolSchemaFingerprint: fingerprint
        )
        let sent = seed.context
        let schemas = sent.toolSchemas
        let body = ConversationPrefixShape.$override.withValue(seed.shape) {
            LLMCallContext.$systemSegments.withValue(sent.systemSegments) {
                ConversationPrefixBoundary.$currentUserIndex.withValue(seed.currentUserIndex) {
                    AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                        messages: seed.messages,
                        system: sent.systemPrompt,
                        coercedModel: model,
                        maxTokens: maxTokens,
                        tools: schemas.isEmpty ? nil : schemas,
                        stream: stream
                    )
                }
            }
        }
        return Turn(index: index, seed: seed, telemetry: telemetry, body: body)
    }

    /// SIX CONSECUTIVE TURNS of one session. Each turn appends the previous
    /// exchange to the transcript (as a real session does), asks a different
    /// question, and rebuilds its whole volatile mass — while the persisted
    /// cursor stays put, because nothing here slid the window.
    static func sixTurns(
        cursorPinned: HistoryWindowCursor? = TurnRegression.cursor(),
        surface currentSurface: String = TurnRegression.surface,
        tools schemas: [LLMToolSchema] = TurnRegression.tools(),
        capsule: @Sendable (Int) -> String? = { _ in nil },
        stableSuffix suffix: String = "",
        shape: ConversationPrefixShape = .v2Prefix
    ) -> [Turn] {
        var rows = session()
        var out: [Turn] = []
        for index in 0..<6 {
            let built = TurnRegression.context(
                turn: index,
                session: rows,
                cursor: cursorPinned,
                surface: currentSurface,
                capsule: capsule(index),
                tools: schemas,
                stableSuffix: suffix
            )
            out.append(wire(built, index: index, shape: shape))
            let next = rows.count
            rows.append(contentsOf: [
                ChatMessage(
                    role: "user", content: questions[index % questions.count],
                    timestamp: "2026-09-02T11:3\(index):00Z",
                    extras: .object([
                        "id": .string("m\(next)"), "runId": .string("live-\(index)"),
                    ])
                ),
                ChatMessage(
                    role: "assistant", content: "answer \(index)",
                    timestamp: "2026-09-02T11:3\(index):01Z",
                    extras: .object([
                        "id": .string("m\(next + 1)"), "runId": .string("live-\(index)"),
                    ])
                ),
            ])
        }
        return out
    }

    // MARK: Wire-body readers

    static func systemBlocks(_ body: [String: Any]) -> [[String: Any]] {
        body["system"] as? [[String: Any]] ?? []
    }

    static func wireMessages(_ body: [String: Any]) -> [[String: Any]] {
        body["messages"] as? [[String: Any]] ?? []
    }

    static func wireTools(_ body: [String: Any]) -> [[String: Any]] {
        body["tools"] as? [[String: Any]] ?? []
    }

    static func cacheControl(_ block: [String: Any]) -> [String: Any]? {
        block["cache_control"] as? [String: Any]
    }

    /// `"5m"` is spelled on the wire as the ABSENT `ttl` key, so a reader that
    /// only looked for `"5m"` would report every default marker as untyped.
    static func ttl(_ block: [String: Any]) -> String? {
        guard let control = cacheControl(block) else { return nil }
        return (control["ttl"] as? String) ?? "5m"
    }

    struct Marker: Equatable {
        let region: String
        let index: Int
        let role: String?
        let ttl: String
    }

    /// Every `cache_control` in the request, wherever it rides.
    static func markers(_ body: [String: Any]) -> [Marker] {
        var out: [Marker] = []
        for (index, block) in systemBlocks(body).enumerated() where cacheControl(block) != nil {
            out.append(Marker(region: "system", index: index, role: nil, ttl: ttl(block) ?? "5m"))
        }
        for (index, tool) in wireTools(body).enumerated() where cacheControl(tool) != nil {
            out.append(Marker(region: "tools", index: index, role: nil, ttl: ttl(tool) ?? "5m"))
        }
        for (index, message) in wireMessages(body).enumerated() {
            let role = message["role"] as? String
            for block in (message["content"] as? [[String: Any]] ?? [])
            where cacheControl(block) != nil {
                out.append(
                    Marker(region: "messages", index: index, role: role, ttl: ttl(block) ?? "5m")
                )
            }
        }
        return out
    }

    /// The concatenated text of every system block — the bytes the model reads
    /// as its system prompt, in order.
    static func systemText(_ body: [String: Any]) -> String {
        systemBlocks(body).compactMap { $0["text"] as? String }.joined()
    }

    /// The text of one wire message.
    static func text(_ message: [String: Any]) -> String {
        (message["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    static func text(_ message: LLMMessage) -> String {
        message.content.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }.joined(separator: "\n")
    }

    static func allText(_ messages: [LLMMessage]) -> String {
        messages.map(text).joined(separator: "\n")
    }
}

// MARK: - The stub streaming LLM

/// A `MessagesStreamingLLMClient` that never touches a network, answers from a
/// script, and RECORDS every request handed to it — the double a suite uses
/// when it wants the request the ENGINE built rather than one the harness
/// seeded. Locked, so it is safe to share across the orchestrator's tasks.
final class TurnRegressionStubLLM: LLMClient, StreamingLLMClient,
                                   MessagesStreamingLLMClient, @unchecked Sendable {
    struct Request: Sendable {
        let messages: [LLMMessage]
        let system: String?
        let model: String?
        let surface: String
        let tools: [LLMToolSchema]
        /// The stable/dynamic split in force for this call, read off the same
        /// task-local the adapters read. Captured here so a test can prove the
        /// SPLIT reached the wire, not merely that the combined prompt did.
        let segments: SystemPromptSegments?
        let shape: ConversationPrefixShape?
    }

    private let lock = NSLock()
    private let scripted: [String]
    private var _requests: [Request] = []
    private var _callCount = 0

    init(scripted: [String] = ["ok"]) {
        self.scripted = scripted.isEmpty ? ["ok"] : scripted
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    private func record(_ request: Request) -> String {
        lock.lock(); defer { lock.unlock() }
        let index = _callCount
        _callCount += 1
        _requests.append(request)
        return scripted[index % scripted.count]
    }

    // LLMClient

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        record(
            Request(
                messages: [.user(prompt)], system: system, model: model,
                surface: LLMCallContext.surface ?? TurnRegression.surface, tools: [],
                segments: LLMCallContext.systemSegments,
                shape: ConversationPrefixShape.override
            )
        )
    }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        record(
            Request(
                messages: messages, system: system, model: model, surface: surface,
                tools: tools ?? [], segments: LLMCallContext.systemSegments,
                shape: ConversationPrefixShape.override
            )
        )
    }

    // StreamingLLMClient

    func stream(
        prompt: String, system: String?, model: String?
    ) -> AsyncThrowingStream<String, Error> {
        let reply = record(
            Request(
                messages: [.user(prompt)], system: system, model: model,
                surface: LLMCallContext.surface ?? TurnRegression.surface, tools: [],
                segments: LLMCallContext.systemSegments,
                shape: ConversationPrefixShape.override
            )
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }

    // MessagesStreamingLLMClient

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let reply = record(
            Request(
                messages: messages, system: system, model: model, surface: surface,
                tools: tools ?? [], segments: LLMCallContext.systemSegments,
                shape: ConversationPrefixShape.override
            )
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.finish()
        }
    }
}
