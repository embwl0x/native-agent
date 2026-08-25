import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, rows `cognition.observeTurnMessage`
// (NativeCognitionRuntime+Events.swift:385), `cognition.observeAssistantTurnCompleted`
// (:444) and `cognition.observeRemoteAction` (:459).
//
// These three are the ONLY doors between a lived turn and Agent's substrate.
// Their silent failures are "dropped row" and "state-lifecycle leak": a
// mis-shaped subject, a debug misclassification, or a missing close half looks
// exactly like nothing happening. Existing coverage drives `observe(event:)`
// directly — it never goes through these entry points, so the role→kind
// mapping, the empty-text drop, and the debug-session lifecycle were unpinned.
//
// Every assertion below reads the SUBSTRATE (the envelope), not an internal
// counter.
@Suite("Native cognition runtime turn ingest", .serialized)
struct NativeCognitionRuntimeTurnIngestTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func configuration() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            backgroundMicrocyclesEnabled: true,
            observatoryEnabled: true,
            maximumCapsuleCharacters: 4_000,
            maximumThoughtSeeds: 64
        )
    }

    private func nodes(
        _ substrate: CognitiveSubstrate,
        subject id: String
    ) async -> [CognitiveNode] {
        await substrate.snapshot().nodes.filter { $0.subjectReference.id == id }
    }

    @Test("a user message and its assistant close both land, subject-keyed and live")
    func turnMessagePairLandsInTheSubstrate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration()
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()
        let session = "ingest-session-\(UUID().uuidString)"

        await runtime.observeTurnMessage(
            surface: "chat",
            role: "user",
            text: "How is the eval fence going?",
            sessionId: session,
            messageId: "m-user"
        )
        await runtime.observeAssistantTurnCompleted(
            surface: "chat",
            text: "Five rows closed, three seams reported.",
            sessionId: session,
            messageId: "m-assistant"
        )

        let userNodes = await nodes(substrate, subject: "\(session):m-user")
        let assistantNodes = await nodes(substrate, subject: "\(session):m-assistant")
        #expect(userNodes.count == 1, "the user half of the turn must not be dropped")
        #expect(assistantNodes.count == 1, "the CLOSE half must land — an open turn never settles")
        // Live, not debug/verification: an ordinary chat turn misclassified as
        // debug is excluded from her felt state and nothing errors.
        #expect(userNodes.first?.turnKind == .live)
        #expect(assistantNodes.first?.turnKind == .live)
        // Provenance the projection depends on: role and surface survive ingest.
        #expect(userNodes.first?.sourceClass == .userStated)
        #expect(assistantNodes.first?.sourceClass == .observed)
    }

    @Test("an unknown role or empty text is dropped rather than stored mis-shaped")
    func malformedTurnMessagesAreDropped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration()
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()
        let session = "drop-session-\(UUID().uuidString)"
        let before = await substrate.snapshot().nodes.count

        // Neither is a lived turn: `system` has no role mapping, and a
        // whitespace-only message carries no content to remember.
        await runtime.observeTurnMessage(
            surface: "chat",
            role: "system",
            text: "housekeeping",
            sessionId: session,
            messageId: "m-system"
        )
        await runtime.observeTurnMessage(
            surface: "chat",
            role: "user",
            text: "   \n  ",
            sessionId: session,
            messageId: "m-blank"
        )

        #expect(await nodes(substrate, subject: "\(session):m-system").isEmpty)
        #expect(await nodes(substrate, subject: "\(session):m-blank").isEmpty)
        #expect(await substrate.snapshot().nodes.count == before)
    }

    @Test("a bridge turn latches its whole session as debug without leaking to other sessions")
    func debugSessionLatchIsSessionScoped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration(),
            organismConfigurationOverride: .enabled
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()
        let session = "bridge-session-\(UUID().uuidString)"

        await runtime.observeTurnMessage(
            surface: "chat",
            role: "user",
            text: "[from: codex, via bridge] check the live runtime",
            sessionId: session,
            messageId: "m-1"
        )
        await runtime.observeAssistantTurnCompleted(
            surface: "chat",
            text: "The runtime is healthy.",
            sessionId: session,
            messageId: "m-2"
        )

        let debugUser = await nodes(substrate, subject: "\(session):m-1")
        let debugReply = await nodes(substrate, subject: "\(session):m-2")
        #expect(debugUser.first?.turnKind == .debug)
        #expect(
            debugReply.first?.turnKind == .debug,
            "the REPLY to a bridge turn must inherit debug — otherwise a diagnostic answer is felt as lived chat"
        )

        // The classification is SESSION-WIDE and sticky (markSessionDebug +
        // canTreatWholeSessionAsDebug for chat/codex surfaces): every later
        // message on this session inherits debug, not just the one claimed
        // reply. Pinned because the cost is real — everything said in a
        // bridge-touched session is excluded from her felt state.
        await runtime.observeTurnMessage(
            surface: "chat",
            role: "user",
            text: "And how are you feeling about it?",
            sessionId: session,
            messageId: "m-3"
        )
        let latched = await nodes(substrate, subject: "\(session):m-3")
        #expect(latched.first?.turnKind == .debug)

        // The latch must NOT leak: an unrelated session on the same runtime is
        // still lived chat. A leak here would silently drain her whole felt
        // history after one bridge turn.
        let liveSession = "live-session-\(UUID().uuidString)"
        await runtime.observeTurnMessage(
            surface: "chat",
            role: "user",
            text: "How are you feeling right now?",
            sessionId: liveSession,
            messageId: "m-live"
        )
        let liveNodes = await nodes(substrate, subject: "\(liveSession):m-live")
        #expect(
            liveNodes.first?.turnKind == .live,
            "the debug latch is per-session — another session must stay lived chat"
        )
    }

    @Test("remote actions admit corrections and provider failures, and drop the rest")
    func remoteActionAdmissionIsExact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration()
        )
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()

        let proposalId = "proposal-\(UUID().uuidString)"
        await runtime.observeRemoteAction(
            surface: "ios",
            action: "rejectMemoryProposal",
            payload: ["proposalId": proposalId],
            response: ["status": "ok"]
        )
        let corrections = await nodes(substrate, subject: proposalId)
        #expect(corrections.count == 1, "a remote REJECT is a correction — it must reach her felt state")
        #expect(corrections.first?.sourceClass == .userStated)

        let providerId = "provider-\(UUID().uuidString)"
        await runtime.observeRemoteAction(
            surface: "ios",
            action: "providerCall",
            payload: ["provider_id": providerId],
            response: ["status": "error", "message": "429 from upstream"]
        )
        let failures = await nodes(substrate, subject: providerId)
        #expect(failures.count == 1, "a remote provider failure must be felt, not silently dropped")

        // Deliberate drop: an ordinary remote read is not an event about her.
        // Pinned so a widening (every remote tap becoming a felt event) or a
        // narrowing (the two admitted classes going silent) is visible.
        let sessionId = "remote-session-\(UUID().uuidString)"
        await runtime.observeRemoteAction(
            surface: "ios",
            action: "openSession",
            payload: ["sessionId": sessionId],
            response: ["status": "ok"]
        )
        #expect(await nodes(substrate, subject: sessionId).isEmpty)
    }
}
