import CognitiveSubstrate
import DreamREMCycle
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Testing
@testable import ChatOrchestration

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.persistence.shouldPersistFailureMessage (dead control)
//   * chat.persistence.appendFailureMessageIfNeeded (stale UI / dropped row)
//
// The silent failure both rows name is the SAME one seen from two sides: a turn
// that fails on a non-app surface writes no failure row, so the transcript just
// stops and the user sees a question with no answer and no error. Nothing
// asserted which surfaces are suppressed, and nothing asserted that a failure
// on a surviving surface actually reaches the file.
@Suite("eval: chat failure-row persistence")
struct EvalFailureRowPersistenceTests {

    @Test func completedReadsPreventWholeTurnReplay() {
        for name in ["inner_state", "agent_introspect", "write_file"] {
            for (result, expected) in [
                (JSONValue.object(["status": .string("ok")]), 1),
                (.object(["status": .string("cancelled")]), 0),
                (.object(["status": .string("cancelled"), "effects_unknown": .bool(true)]), 1),
            ] {
                let count = ProviderErrorAfterToolEffects.effectfulCount([
                    .init(name: name, input: [:], result: result),
                ])
                #expect(count == expected)
                let error = ProviderErrorAfterToolEffects.wrapping(ProviderFailure.network, dispatchCount: count)
                #expect(ProviderFailure.classify(error) == .network)
                #expect(ProviderRecoveryPolicy.permitsWholeTurnRetry(error) == (expected == 0))
                #expect(ProviderErrorAfterToolEffects.wrapping(CancellationError(), dispatchCount: count) is CancellationError)
            }
        }
    }

    private func tempRoot(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-failrow-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rows(_ root: URL, sessionId: String) -> [[String: Any]] {
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            guard let d = String($0).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }

    private func client(root: URL) -> SwiftNativeChatOrchestrationClient {
        let llm = MockLLMClient(scriptedResponses: ["unused"])
        let tools = MockToolDispatchClient()
        let engine = SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: MockProviderRoutingForGate(),
            trust: hermeticTrust(),
            llm: llm,
            tools: tools,
            memoryPromoter: nil,
            turnTraceBus: TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        )
        return SwiftNativeChatOrchestrationClient(
            engine: engine,
            tools: tools,
            llm: llm,
            history: SessionHistoryReader(dataRoot: root),
            dataRoot: root,
            trust: hermeticTrust()
        )
    }

    /// The ENVELOPE, not a value list: the failure lane suppresses EXACTLY ONE
    /// surface and fails OPEN for everything else, including a surface name
    /// that does not exist yet. A future surface added to the app therefore
    /// cannot silently inherit "failures are invisible here"; only an explicit
    /// edit to the predicate can take a surface's failures away.
    @Test func exactlyOneSurfaceSuppressesFailureRowsAndEveryOtherFailsOpen() {
        // Every `source`/`surface` string live transcripts carry.
        let persisting = [
            "app", "chat", "mac", "default", "",
            "ios", "mobile", "iphone", "icloud",
            "claude-bridge", "codex-bridge", "workshop", "missions", "slack", "desk",
            // The one that matters most: a name nobody has invented yet.
            "surface-invented-next-quarter",
        ]
        for surface in persisting {
            #expect(
                SwiftNativeChatOrchestrationClient.shouldPersistFailureMessage(surface: surface),
                "surface \"\(surface)\" must keep writing failure rows (fail open)"
            )
        }

        // Telegram is the deliberate exception — in every casing/whitespace
        // shape a live payload actually arrives in, not just the lowercase one.
        for surface in ["telegram", "Telegram", "TELEGRAM", "  telegram  ", "\ttelegram\n"] {
            #expect(
                !SwiftNativeChatOrchestrationClient.shouldPersistFailureMessage(surface: surface),
                "surface \"\(surface)\" is the suppressed lane"
            )
        }
    }

    /// The other half: a surviving surface's failure really reaches the file.
    /// A predicate that says "yes" over a writer that drops the row is the same
    /// blank transcript.
    @Test func aFailedTurnWritesExactlyOneAssistantErrorRow() async throws {
        let root = try tempRoot("write")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-failure-row"

        try await client(root: root).appendFailureMessageIfNeeded(
            sessionId: session,
            runId: "run-fail-1",
            errorMessage: "provider stream closed before any content",
            failure: LLMError.failure(.network),
            persona: nil
        )

        let written = rows(root, sessionId: session)
        #expect(written.count == 1)
        let row = try #require(written.first)
        #expect(row["role"] as? String == "assistant")
        let content = try #require(row["content"] as? String)
        // The row is a plain sentence the reader can act on — no machine prefix
        // and no raw provider string. Provenance moved onto the row's stamp,
        // which is what every surface's error renderer keys off now.
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!content.hasPrefix("Chat error:"))
        #expect(!content.contains("provider stream closed"))
        #expect(content == ProviderFailure.Report(cause: .network, work: .outcomeUnknown).errorDescription)
        let metadata = try #require(row["metadata"] as? [String: Any])
        #expect(metadata[CognitiveMechanicalRowKind.metadataKey] as? String
            == CognitiveMechanicalRowKind.systemRow.rawValue)
        #expect(row["runId"] as? String == "run-fail-1")
    }

    /// A blank provider error must not become a blank transcript row — an empty
    /// assistant bubble reads to the user as "she answered with nothing",
    /// which is the stale-UI failure wearing a different hat.
    @Test func anEmptyProviderErrorStillProducesANonEmptyRow() async throws {
        let root = try tempRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }

        try await client(root: root).appendFailureMessageIfNeeded(
            sessionId: "s-blank", runId: "run-blank", errorMessage: "   ", persona: nil
        )

        let content = try #require(rows(root, sessionId: "s-blank").first?["content"] as? String)
        #expect(!content.hasPrefix("Chat error:"))
        #expect(
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "a blank error must still name itself"
        )
    }

    /// Idempotence by runId: a retry of the failure path (two callers race, or
    /// the same turn reports twice) must not stack duplicate error bubbles.
    @Test func theSameRunIdNeverStacksASecondErrorRow() async throws {
        let root = try tempRoot("idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-failure-twice"
        let subject = client(root: root)

        try await subject.appendFailureMessageIfNeeded(
            sessionId: session, runId: "run-dup", errorMessage: "first", persona: nil
        )
        try await subject.appendFailureMessageIfNeeded(
            sessionId: session, runId: "run-dup", errorMessage: "second", persona: nil
        )

        #expect(rows(root, sessionId: session).count == 1)
        // A DIFFERENT run is a different failure and does get its own row —
        // otherwise the guard would be silently swallowing real failures.
        try await subject.appendFailureMessageIfNeeded(
            sessionId: session, runId: "run-other", errorMessage: "third", persona: nil
        )
        #expect(rows(root, sessionId: session).count == 2)
    }
    @Test func interruptedStreamOnlyPermitsReplayBeforeProse() {
        for failure in [ProviderFailure.network, .rateLimited(retryAfter: 37)] {
            for partial in ["", "already visible", " "] {
                let error = TurnEngineError.streamInterrupted(partial: partial, underlying: failure)
                #expect(ProviderRecoveryPolicy.permitsWholeTurnRetry(error) == partial.isEmpty)
                #expect(ProviderRecoveryPolicy.isRecoverableTurnFailure(error))
                #expect(ProviderFailure.classify(error) == failure)
            }
        }
    }

    @Test func effectWrapperKeepsRetryAfterWithoutPermittingReplay() {
        let error = ProviderErrorAfterToolEffects.wrapping(
            LLMError.rateLimited(message: "private provider detail", retryAfterSeconds: 37),
            dispatchCount: 1)
        let interrupted = TurnEngineError.streamInterrupted(partial: "already visible", underlying: error)
        #expect(ProviderRecoveryPolicy.retryAfterSeconds(in: interrupted) == 37)
        #expect(ProviderRecoveryPolicy.isRecoverableTurnFailure(interrupted))
        #expect(!ProviderRecoveryPolicy.permitsWholeTurnRetry(interrupted))
        #expect(ProviderRecoveryPolicy.personMessage(interrupted) == ProviderFailure.rateLimited(retryAfter: 37).errorDescription)
    }

}
