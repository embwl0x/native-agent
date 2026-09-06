import Testing
import Foundation
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import DreamREMCycle
import NativeAgentCore
@testable import ChatOrchestration

// MARK: - One Thread, Many Surfaces — Phase 1 tests
//
// docs/build_plans/one-thread-many-surfaces-plan.md §7 Phase 1:
//
//   3. Mixed-surface transcript ⇒ session row `source` is STABLE across
//      appends. (§1.3, the last-writer-wins overwrite.)
//   4. The envelope round-trips through JSONL and back with no field loss.
//
// Plus the surface-agnostic contract: a brand-new adapter binds an envelope
// and gets correct behavior with ZERO changes outside its own adapter.

private func envelopeRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("turn-envelope-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class EnvelopeStubRouting: ProviderRoutingProtocol, @unchecked Sendable {
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
    func activeProvidersForSurfaces() async -> [String: String] { [:] }
}

private func makeEnvelopeClient(root: URL) -> SwiftNativeChatOrchestrationClient {
    let llm = MockLLMClient(scriptedResponses: ["unused"])
    let tools = MockToolDispatchClient()
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: EnvelopeStubRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        persistence: SwiftNativePersistenceCore(),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
}

private func transcriptRows(root: URL, sessionId: String) throws -> [[String: JSONValue]] {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
    let raw = try String(contentsOf: path, encoding: .utf8)
    return try raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard case .object(let object) = try JSONValue.parse(Data(String(line).utf8)) else { return nil }
        return object
    }
}

private func sessionRow(root: URL, sessionId: String) throws -> [String: JSONValue]? {
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions.json")
    guard case .array(let rows) = try JSONValue.parse(try Data(contentsOf: path)) else { return nil }
    for row in rows {
        guard case .object(let object) = row,
              case .string(let id)? = object["id"], id == sessionId else { continue }
        return object
    }
    return nil
}

@Suite("TurnEnvelope Phase 1", .serialized)
struct TurnEnvelopeTests {

    // MARK: Test 4 — round trip with no field loss

    @Test("the envelope round-trips through the persisted metadata shape")
    func envelopeRoundTrip() throws {
        let route = ChatToolSessionContext.ReplyRoute(
            surface: "signal",
            destinationId: "+15550100",
            threadId: "thread-7",
            sourceKey: "signal_app",
            replyTo: "msg-42",
            correlationId: "corr-9"
        )
        let envelope = TurnEnvelope(
            surface: "signal",
            agent: "claude",
            verifiedChatId: "chat-abc",
            verifiedUserId: "user-xyz",
            commandSignatureVerified: true,
            deliveryRoute: route
        )

        let persisted = envelope.persistedMetadata()
        // Survives a real JSONL hop, not just an in-memory copy.
        let reparsed = try JSONValue.parse(try persisted.serializedData(pretty: false))
        let restored = try #require(TurnEnvelope.fromPersistedMetadata(reparsed))

        #expect(restored.surface == "signal")
        #expect(restored.agent == "claude")
        #expect(restored.verifiedChatId == "chat-abc")
        #expect(restored.verifiedUserId == "user-xyz")
        #expect(restored.deliveryRoute?.destinationId == "+15550100")
        #expect(restored.deliveryRoute?.threadId == "thread-7")
        #expect(restored.deliveryRoute?.sourceKey == "signal_app")
        #expect(restored.deliveryRoute?.replyTo == "msg-42")
        #expect(restored.deliveryRoute?.correlationId == "corr-9")
    }

    @Test("no trust verdict is ever persisted on the row")
    func envelopeCarriesNoAuthority() throws {
        let envelope = TurnEnvelope(
            surface: "telegram",
            verifiedChatId: "123",
            commandSignatureVerified: true
        )
        guard case .object(let object) = envelope.persistedMetadata() else {
            Issue.record("not an object")
            return
        }
        // A persisted verdict would be exactly the "authority from history" the
        // design forbids: a Mac-authored trusted turn sits rows above a remote
        // one in the same transcript, and history must grant nothing.
        #expect(object["trusted"] == nil)
        #expect(object["originTrusted"] == nil)
        #expect(object["commandSignatureVerified"] == nil)
        // What it DOES carry is who and where.
        #expect(object["surface"] == .string("telegram"))
        #expect(object["chatId"] == .string("123"))
    }

    @Test("ReplyRoute stays the envelope's delivery projection")
    func replyRouteProjection() {
        let route = ChatToolSessionContext.ReplyRoute(surface: "telegram", destinationId: "42")
        let envelope = TurnEnvelope(surface: "telegram", deliveryRoute: route)
        #expect(envelope.replyRoute == route)
        // An envelope with no explicit route still projects an honest surface,
        // so a consumer never sees a route claiming the wrong place.
        #expect(TurnEnvelope(surface: "signal").replyRoute.surface == "signal")
        #expect(TurnEnvelope(surface: "signal").replyRoute.destinationId == nil)
    }

    @Test("current() composes from the pre-envelope task-locals when none is bound")
    func currentFallsBackToLegacyBindings() {
        let composed = ChatToolSessionContext.$verifiedChatId.withValue("999") {
            ChatToolSessionContext.$verifiedUserId.withValue("u1") {
                TurnEnvelope.current(surface: "telegram")
            }
        }
        // This fallback is what makes Phase 1 additive: an adapter that has not
        // migrated to binding an envelope keeps working unchanged.
        #expect(composed.verifiedChatId == "999")
        #expect(composed.verifiedUserId == "u1")
        #expect(composed.surface == "telegram")
    }

    @Test("an explicitly bound envelope outranks the legacy task-locals")
    func boundEnvelopeWins() {
        let bound = TurnEnvelope(surface: "signal", verifiedChatId: "sig-1")
        let observed = ChatToolSessionContext.$envelope.withValue(bound) {
            ChatToolSessionContext.$verifiedChatId.withValue("stale") {
                TurnEnvelope.current(surface: "signal")
            }
        }
        #expect(observed.verifiedChatId == "sig-1")
    }

    // MARK: Test 3 — the session row's `source` stops flapping

    @Test("a mixed-surface transcript leaves the session row's source stable")
    func mixedSurfaceSourceIsStable() async throws {
        let root = envelopeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeEnvelopeClient(root: root)
        let session = "mixed-surface-session"

        // Created by the Mac.
        try await client.appendMessage(
            sessionId: session, role: "user", content: "from the mac",
            runId: "r1", attachments: [], source: "app"
        )
        let afterFirst = try #require(try sessionRow(root: root, sessionId: session))
        #expect(afterFirst["source"] == .string("app"))
        #expect(afterFirst["threadKind"] == .string("direct"))

        // Then Telegram, then iOS, then the Mac again. Under the old
        // last-writer-wins block the row's `source` would read "ios" here.
        try await client.appendMessage(
            sessionId: session, role: "user", content: "from telegram",
            runId: "r2", attachments: [], source: "telegram"
        )
        try await client.appendMessage(
            sessionId: session, role: "user", content: "from the phone",
            runId: "r3", attachments: [], source: "ios"
        )

        let final = try #require(try sessionRow(root: root, sessionId: session))
        #expect(
            final["source"] == .string("app"),
            "the index row's source must not be restamped by the most recent surface"
        )
        #expect(final["threadKind"] == .string("direct"))

        // Per-MESSAGE provenance is where the surface genuinely varies, and it
        // must still be complete — the fix removes a lie, not information.
        let rows = try transcriptRows(root: root, sessionId: session)
        let sources = rows.compactMap { row -> String? in
            guard case .string(let value)? = row["source"] else { return nil }
            return value
        }
        #expect(sources == ["app", "telegram", "ios"])
    }

    @Test("a Slack-created session row is classified channel, not direct")
    func slackRowIsAChannel() async throws {
        let root = envelopeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeEnvelopeClient(root: root)
        try await client.appendMessage(
            sessionId: "slack-session", role: "user", content: "hi",
            runId: "r1", attachments: [], source: "slack"
        )
        let row = try #require(try sessionRow(root: root, sessionId: "slack-session"))
        #expect(row["threadKind"] == .string("channel"))
        #expect(row["source"] == .string("slack"))
    }

    // MARK: metadata.envelope lands on the row, beside metadata.origin

    @Test("every message row carries metadata.envelope; origin stays user-only")
    func envelopeIsWrittenOnEveryRow() async throws {
        let root = envelopeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeEnvelopeClient(root: root)
        let session = "envelope-session"

        let route = ChatToolSessionContext.ReplyRoute(
            surface: "telegram",
            destinationId: "1394548068",
            correlationId: "corr-1"
        )
        try await ChatToolSessionContext.$envelope.withValue(
            TurnEnvelope(
                surface: "telegram",
                verifiedChatId: "1394548068",
                verifiedUserId: "u-user",
                deliveryRoute: route
            )
        ) {
            try await ChatPersistenceContext.$originProvenance.withValue(
                ChatMessageOrigin(surface: "telegram")
            ) {
                try await client.appendMessage(
                    sessionId: session, role: "user", content: "hello",
                    runId: "r1", attachments: [], source: "telegram"
                )
            }
            try await client.appendMessage(
                sessionId: session, role: "assistant", content: "hi back",
                runId: "r1", attachments: [], source: "telegram",
                canonicalAssistantCompletion: true
            )
        }

        let rows = try transcriptRows(root: root, sessionId: session)
        #expect(rows.count == 2)

        for row in rows {
            guard case .object(let metadata)? = row["metadata"] else {
                Issue.record("row has no metadata")
                continue
            }
            let envelope = try #require(TurnEnvelope.fromPersistedMetadata(metadata["envelope"]))
            #expect(envelope.surface == "telegram")
            #expect(envelope.verifiedChatId == "1394548068")
            // The delivery route is DURABLE on the row: with several surfaces
            // writing one transcript, a completion arriving after the
            // originating loop has moved on cannot rediscover its destination
            // from "the session's surface".
            #expect(envelope.deliveryRoute?.destinationId == "1394548068")
            #expect(envelope.deliveryRoute?.correlationId == "corr-1")
        }

        // metadata.origin keeps its narrower, unchanged contract: user rows
        // only. An assistant row is hers by construction.
        guard case .object(let userMetadata)? = rows[0]["metadata"],
              case .object(let assistantMetadata)? = rows[1]["metadata"] else {
            Issue.record("missing metadata")
            return
        }
        #expect(userMetadata["origin"] != nil)
        #expect(assistantMetadata["origin"] == nil)
        #expect(assistantMetadata["envelope"] != nil)
    }

    @Test("a bridged turn's envelope records the bridge, not the tool surface")
    func bridgedTurnKeepsItsOwnSurface() async throws {
        let root = envelopeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeEnvelopeClient(root: root)

        // The bridges deliberately run with `surface: "chat"` so they get the
        // same TOOL surface as the Mac (User's 2026-06-13 call). Provenance must
        // not inherit that, or a bridge message reads as a Mac message.
        try await ChatPersistenceContext.$originProvenance.withValue(
            ChatMessageOrigin(surface: "claude-bridge", agent: "claude")
        ) {
            try await client.appendMessage(
                sessionId: "bridge-session", role: "user", content: "from claude",
                runId: "r1", attachments: [], source: "app"
            )
        }

        let rows = try transcriptRows(root: root, sessionId: "bridge-session")
        guard case .object(let metadata)? = rows[0]["metadata"] else {
            Issue.record("no metadata")
            return
        }
        let envelope = try #require(TurnEnvelope.fromPersistedMetadata(metadata["envelope"]))
        #expect(envelope.surface == "claude-bridge")
        #expect(envelope.agent == "claude")
        // The tool-authorization surface is unchanged on the row itself.
        #expect(rows[0]["source"] == .string("app"))
    }

    @Test("a tool receipt carries the envelope too; a streaming partial does not")
    func toolReceiptsCarryTheEnvelope() async throws {
        let root = envelopeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeEnvelopeClient(root: root)
        let session = "tool-receipt-session"

        try await ChatToolSessionContext.$envelope.withValue(
            TurnEnvelope(
                surface: "telegram",
                verifiedChatId: "1394548068",
                deliveryRoute: ChatToolSessionContext.ReplyRoute(
                    surface: "telegram",
                    destinationId: "1394548068"
                )
            )
        ) {
            try await client.appendToolMessage(
                sessionId: session,
                runId: "r1",
                toolName: "mac.shell",
                inputJSON: "{\"command\":\"whoami\"}",
                resultSummary: "{\"ok\":true}",
                ok: true,
                source: "telegram"
            )
            // A partial takes the fast append and is superseded within the turn.
            await client.persistPartialIfNeeded(
                sessionId: session,
                runId: "r1",
                text: "thinking",
                cancelled: false,
                source: "telegram",
                onNotice: { _, _ in }
            )
        }

        let rows = try transcriptRows(root: root, sessionId: session)
        #expect(rows.count == 2)
        guard case .object(let toolMetadata)? = rows[0]["metadata"] else {
            Issue.record("tool row has no metadata")
            return
        }
        let envelope = try #require(TurnEnvelope.fromPersistedMetadata(toolMetadata["envelope"]))
        // A tool receipt records an EXTERNAL EFFECT — which surface caused it,
        // and where that turn's reply went, must survive on the row.
        #expect(envelope.surface == "telegram")
        #expect(envelope.deliveryRoute?.destinationId == "1394548068")

        guard case .object(let partialMetadata)? = rows[1]["metadata"] else {
            Issue.record("partial row has no metadata")
            return
        }
        #expect(partialMetadata["partial"] == .bool(true))
        #expect(partialMetadata["envelope"] == nil, "partials stay off the hot path")
    }

    // MARK: The "how to add a surface" contract

    /// A synthetic adapter for a surface that does not exist in this codebase.
    /// It does exactly the three things the `TurnEnvelope` doc comment names,
    /// and nothing outside this struct changes anywhere.
    private struct SyntheticSignalAdapter {
        let conversationId: String
        let senderId: String

        func envelope() -> TurnEnvelope {
            TurnEnvelope(
                surface: "signal",
                verifiedChatId: conversationId,
                verifiedUserId: senderId,
                deliveryRoute: ChatToolSessionContext.ReplyRoute(
                    surface: "signal",
                    destinationId: conversationId
                )
            )
        }
    }

    @Test("a new surface adapter binds an envelope with zero changes outside itself")
    func newSurfaceAdapterNeedsNoCoreEdits() async throws {
        let adapter = SyntheticSignalAdapter(conversationId: "sig-conv-1", senderId: "sig-user-1")

        let observed = ChatToolSessionContext.$envelope.withValue(adapter.envelope()) {
            (
                chatId: AutonomyGatedDispatcher.resolvedChatId(sessionId: "any-session"),
                envelope: TurnEnvelope.current(surface: "signal")
            )
        }

        // The identity the transport bound is what every gate reads — no
        // registration, no switch statement, no per-surface parse.
        #expect(observed.chatId == "sig-conv-1")
        #expect(observed.envelope.verifiedUserId == "sig-user-1")
        #expect(observed.envelope.replyRoute.destinationId == "sig-conv-1")

        // And it persists on the row through the same generic path.
        let root = envelopeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeEnvelopeClient(root: root)
        try await ChatToolSessionContext.$envelope.withValue(adapter.envelope()) {
            try await client.appendMessage(
                sessionId: "signal-session", role: "user", content: "hey",
                runId: "r1", attachments: [], source: "signal"
            )
        }
        let rows = try transcriptRows(root: root, sessionId: "signal-session")
        guard case .object(let metadata)? = rows[0]["metadata"] else {
            Issue.record("no metadata")
            return
        }
        let restored = try #require(TurnEnvelope.fromPersistedMetadata(metadata["envelope"]))
        #expect(restored.surface == "signal")
        #expect(restored.verifiedChatId == "sig-conv-1")
    }

    // MARK: The origin projection is the ENVELOPE's, not the caller's surface

    @Test("an envelope-bound remote surface fails closed even when it dispatches as \"chat\"")
    func envelopeBoundRemoteSurfaceIsNotLocal() {
        // The exact adapter shape the contract tells a new surface to build:
        // identity and remoteness on the envelope, while the `chat()` call
        // still runs under the shared "chat" tool surface. Reading `surface`
        // here handed this turn "local app surface" — trusted, before any
        // allowlist was consulted.
        let envelope = TurnEnvelope(
            surface: "signal",
            verifiedUserId: "sig-user-1",
            declaredRemote: true
        )
        let origin = ChatToolSessionContext.$envelope.withValue(envelope) {
            AutonomyGatedDispatcher.securityOrigin(
                verifiedSessionId: "some-uuid-session",
                surface: "chat"
            )
        }
        #expect(origin.surface == "signal", "the origin must name the real surface")
        #expect(origin.isRemote == true, "declaredRemote must widen an unknown surface")
        #expect(origin.userId == "sig-user-1")
        #expect(origin.chatId == nil, "nothing was verified, so nothing is claimed")
    }

    @Test("a known-remote envelope stays remote without declaring it")
    func knownRemoteEnvelopeNeedsNoDeclaration() {
        let origin = ChatToolSessionContext.$envelope.withValue(
            TurnEnvelope(surface: "telegram", verifiedChatId: "1394548068")
        ) {
            AutonomyGatedDispatcher.securityOrigin(verifiedSessionId: nil, surface: "chat")
        }
        #expect(origin.surface == "telegram")
        #expect(origin.isRemote == true)
        #expect(origin.chatId == "1394548068")
    }

    @Test("with no envelope bound the origin is exactly the pre-envelope projection")
    func originFallsBackToLegacyBindings() {
        let origin = ChatToolSessionContext.$verifiedChatId.withValue("999") {
            ChatToolSessionContext.$verifiedUserId.withValue("u1") {
                ChatToolSessionContext.$commandSignatureVerified.withValue(true) {
                    AutonomyGatedDispatcher.securityOrigin(
                        verifiedSessionId: "  ",
                        surface: "telegram"
                    )
                }
            }
        }
        #expect(origin.surface == "telegram")
        #expect(origin.isRemote == true)
        #expect(origin.chatId == "999")
        #expect(origin.userId == "u1")
        #expect(origin.commandSignatureVerified == true)
        #expect(origin.sessionId == nil, "a blank session id is not a session id")
    }

    @Test("an envelope can never SUBTRACT remoteness from a known-remote surface")
    func remotenessOnlyWidens() {
        let origin = ChatToolSessionContext.$envelope.withValue(
            TurnEnvelope(surface: "telegram", declaredRemote: false)
        ) {
            AutonomyGatedDispatcher.securityOrigin(verifiedSessionId: nil, surface: "chat")
        }
        #expect(origin.isRemote == true)
    }

    @Test("an adapter that binds nothing gets nil, not an inferred identity")
    func adapterThatBindsNothingGetsNothing() {
        // Even when the session id is shaped exactly like the deleted parse's
        // input. This is parse site 2, proven dead.
        let chatId = AutonomyGatedDispatcher.resolvedChatId(
            sessionId: "telegram:1394548068"
        )
        #expect(chatId == nil)
    }
}
