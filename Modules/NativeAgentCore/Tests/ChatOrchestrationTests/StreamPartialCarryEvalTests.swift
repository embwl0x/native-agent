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
// Ledger row closed here:
//   * chat.engine.error.streamCancelledPartialCarry (REPORTS-ONLY → COVERED)
//
// `.streamInterrupted` / `.streamCancelled` carry the prose the user already
// WATCHED render so the orchestration layer can persist it. Silent-failure
// class: dropped row. If a lane stops wrapping and throws the raw error, the
// visible partial is discarded and the transcript loses text the user saw —
// with NO error, because the cancel path is expected to look lossy.
//
// The app's bridge deadline path (Sources/NativeAgentApp/ClaudeBridge.swift)
// depends on this behavior in prose ("the cancelled partial already persisted
// via streamCancelled") while nothing asserted it. Also pinned: the marker
// STRIP, so a half-emitted `<tool_use` never persists as visible prose.

// MARK: - scripted streaming client

/// Yields the scripted deltas, then either throws `Boom` or cancels.
private final class PartialCarryStreamingLLM: LLMClient, @unchecked Sendable {
    struct Boom: Error, LocalizedError {
        var errorDescription: String? { "scripted provider failure" }
    }
    enum Ending: Sendable { case fail, cancel }

    private let deltas: [String]
    private let ending: Ending
    nonisolated(unsafe) private(set) var callCount = 0

    init(deltas: [String], ending: Ending) {
        self.deltas = deltas
        self.ending = ending
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "" }

    func completeMessages(
        messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?
    ) async throws -> String { "" }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        callCount += 1
        let deltas = self.deltas
        let ending = self.ending
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(.textDelta(delta)) }
            switch ending {
            case .fail: continuation.finish(throwing: Boom())
            case .cancel: continuation.finish(throwing: CancellationError())
            }
        }
    }
}

private struct PartialCarryPersona: PersonaEngineProtocol {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

private final class PartialCarryRouting: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { ProviderTestResult(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "partial-model", reasoningEffort: "high")]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
}

private func makePartialCarryEngine(llm: any LLMClient) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: PartialCarryPersona(),
        memory: nil,
        router: PartialCarryRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: MockToolDispatchClient()
    )
}

private actor StructuredPartialNoticeCapture {
    private var events: [TurnStreamEvent] = []

    func record(_ event: TurnStreamEvent) { events.append(event) }
    func snapshot() -> [TurnStreamEvent] { events }
}

private func partialNoticeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("structured-partial-notice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func wedgePartialTranscript(root: URL, sessionID: String) throws {
    let messages = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: messages.appendingPathComponent("\(sessionID).jsonl", isDirectory: false),
        withIntermediateDirectories: true
    )
}

// MARK: - tests

/// Ledger row `chat.persistence.transcriptWriteFailureNotice`. This is the
/// structured streaming route itself: it emits visible prose, the provider
/// interrupts, and only the partial-reply transcript target is wedged. The
/// adverse persistence result must return on the same live progress channel.
@Test
func structuredStream_partialWriteFailureSurfacesNoticeToTheLiveProgressChannel() async throws {
    let root = try partialNoticeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = "structured-partial-notice"
    try wedgePartialTranscript(root: root, sessionID: sessionID)

    let llm = PartialCarryStreamingLLM(deltas: ["visible partial"], ending: .fail)
    let tools = MockToolDispatchClient()
    let client = SwiftNativeChatOrchestrationClient(
        engine: makePartialCarryEngine(llm: llm),
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
    let capture = StructuredPartialNoticeCapture()

    var thrown: Error?
    do {
        _ = try await client.executeStructuredChatStreaming(
            message: "continue",
            sessionId: sessionID,
            model: "partial-model",
            reasoningEffort: "high",
            fileAccess: "workspace",
            attachments: [],
            persona: nil,
            surface: "chat",
            suppressUserAppend: true,
            persistToolMessages: true,
            progress: nil,
            noticeSink: { kind, text in await capture.record(.notice(kind: kind, text: text)) }
        )
    } catch {
        thrown = error
    }

    #expect(thrown != nil, "the scripted provider interruption must still escape")
    let events = await capture.snapshot()
    #expect(events.contains {
        if case .notice(let kind, let text) = $0 {
            return kind == "transcript_write_failed" && text.contains("partial reply")
        }
        return false
    })
}

@Test
func streamInterrupted_carriesExactlyTheProseTheConsumerAlreadySaw() async throws {
    let deltas = ["The build ", "pipeline is ", "documented across "]
    let llm = PartialCarryStreamingLLM(deltas: deltas, ending: .fail)
    let engine = makePartialCarryEngine(llm: llm)
    let seen = LockedBox<[String]>([])

    var thrown: Error?
    do {
        _ = try await engine.executeTurnWithStreamingToolLoop(
            userMessage: "explain the build",
            llm: llm,
            tools: MockToolDispatchClient(),
            progress: { event in
                if case .delta(let text) = event {
                    var current = seen.get()
                    current.append(text)
                    seen.set(current)
                }
            }
        )
    } catch {
        thrown = error
    }

    let error = try #require(thrown as? TurnEngineError)
    guard case .streamInterrupted(let partial, let underlying) = error else {
        Issue.record("expected .streamInterrupted, got \(error)")
        return
    }
    // The carried partial IS the visible prose of this turn — not empty, and
    // exactly the accumulated deltas (no marker fragments, nothing extra).
    #expect(!partial.isEmpty)
    #expect(partial == deltas.joined())
    // The consumer's own view is a PREFIX of it: the loop holds back a ≤16-char
    // tail so a marker split across SSE boundaries is caught before it renders.
    // The carry must include that held-back tail — dropping it is the silent
    // truncation this row exists to catch.
    let rendered = seen.get().joined()
    #expect(!rendered.isEmpty)
    #expect(partial.hasPrefix(rendered))
    #expect(partial.count >= rendered.count)
    #expect(partial.count - rendered.count <= 16)
    // The provider failure is preserved underneath (surface retry ladders read
    // errorDescription off it).
    #expect((underlying as? LocalizedError)?.errorDescription == "scripted provider failure")
    #expect(error.errorDescription == "scripted provider failure")
}

@Test
func streamCancelled_carriesThePartialAndIsDistinctFromInterrupted() async throws {
    let deltas = ["Half of ", "an answer"]
    let llm = PartialCarryStreamingLLM(deltas: deltas, ending: .cancel)
    let engine = makePartialCarryEngine(llm: llm)

    var thrown: Error?
    do {
        _ = try await engine.executeTurnWithStreamingToolLoop(
            userMessage: "explain the build", llm: llm, tools: MockToolDispatchClient()
        )
    } catch {
        thrown = error
    }

    let error = try #require(thrown as? TurnEngineError)
    guard case .streamCancelled(let partial, let underlying) = error else {
        Issue.record("expected .streamCancelled (a user Stop is not a failure), got \(error)")
        return
    }
    #expect(partial == "Half of an answer")
    #expect(underlying is CancellationError)
    // A cancel must NOT be reported as an interruption: the orchestration catch
    // persists cancelled:true and rethrows CancellationError off this case.
    if case .streamInterrupted = error {
        Issue.record("a user Stop was misclassified as a provider interruption")
    }
}

@Test
func partialCarry_stripsAHalfEmittedToolMarkerFromTheVisiblePartial() async throws {
    // Some structured-path providers emit `<tool_use ...>` as TEXT. A stream
    // that dies mid-marker must not persist the marker fragment as prose the
    // user "saw" — it was buffered, never rendered.
    let llm = PartialCarryStreamingLLM(
        deltas: ["Checking the file. ", "<tool_use id=\"c1\" name=\"read_"],
        ending: .fail
    )
    let engine = makePartialCarryEngine(llm: llm)

    var thrown: Error?
    do {
        _ = try await engine.executeTurnWithStreamingToolLoop(
            userMessage: "read it", llm: llm, tools: MockToolDispatchClient()
        )
    } catch {
        thrown = error
    }

    let error = try #require(thrown as? TurnEngineError)
    guard case .streamInterrupted(let partial, _) = error else {
        Issue.record("expected .streamInterrupted, got \(error)")
        return
    }
    #expect(partial == "Checking the file. ")
    #expect(!partial.contains("<tool_use"))
}

@Test
func partialCarry_emptyStreamStillProducesTheWrappedCaseWithAnEmptyPartial() async throws {
    // Zero deltas then a failure: the case must still be the WRAPPED one (so
    // upstream `if case .streamInterrupted(let partial, _)` persistence
    // branches keep matching) with an honest empty partial.
    let llm = PartialCarryStreamingLLM(deltas: [], ending: .fail)
    let engine = makePartialCarryEngine(llm: llm)

    var thrown: Error?
    do {
        _ = try await engine.executeTurnWithStreamingToolLoop(
            userMessage: "anything", llm: llm, tools: MockToolDispatchClient()
        )
    } catch {
        thrown = error
    }

    let error = try #require(thrown as? TurnEngineError)
    guard case .streamInterrupted(let partial, _) = error else {
        Issue.record("expected .streamInterrupted, got \(error)")
        return
    }
    #expect(partial.isEmpty)
}

@Test
func turnEngineErrorDescriptions_flowTheUnderlyingThroughBothCarryCases() {
    // errorDescription must NOT report the partial (it is transcript content,
    // not an error message) and must forward the underlying so surface retry
    // ladders can classify.
    struct Underlying: Error, LocalizedError {
        var errorDescription: String? { "upstream-529-overloaded" }
    }
    let interrupted = TurnEngineError.streamInterrupted(
        partial: "SECRET-PARTIAL-PROSE", underlying: Underlying()
    )
    let cancelled = TurnEngineError.streamCancelled(
        partial: "SECRET-PARTIAL-PROSE", underlying: Underlying()
    )
    #expect(interrupted.errorDescription == "upstream-529-overloaded")
    #expect(cancelled.errorDescription == "upstream-529-overloaded")
    #expect(interrupted.errorDescription?.contains("SECRET-PARTIAL-PROSE") != true)
    #expect(cancelled.errorDescription?.contains("SECRET-PARTIAL-PROSE") != true)
}
