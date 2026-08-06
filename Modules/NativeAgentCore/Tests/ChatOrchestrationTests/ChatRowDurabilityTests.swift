import Testing
import Foundation
import PersistenceCore
import PersonaEngine
import ProviderRouting
import TrustCenter
import DreamREMCycle
import NativeAgentCore
@testable import ChatOrchestration

// Sweep R4 items 4 + 5. Chat rows were appended under the transcript flock but
// NOT durably: `write(2)` returns once the kernel has the page, so a power cut
// between the append and the next flush loses a turn the user watched commit.
// Full durability on every row would put an F_FULLFSYNC on the streaming hot
// path, so the split is deliberate:
//
//   user rows, terminal assistant rows, tool receipts → DURABLE
//   streaming partials                                → fast path
//
// and the session index (item 5) moves off bare `Data.write(.atomic)` onto the
// durable atomic writer, so the sidebar can't lose a session whose transcript
// rows survived.

/// Records WHICH write primitive each row took, delegating the actual bytes to
/// the real implementation so the assertions run against a real transcript.
private final class DurabilitySpyPersistence: PersistenceCoreProtocol, @unchecked Sendable {
    private let inner = SwiftNativePersistenceCore()
    private let lock = NSLock()
    private var _fastAppends: [String] = []
    private var _durableAppends: [String] = []
    private var _durableDataWrites: [String] = []

    var fastAppends: [String] { lock.withLock { _fastAppends } }
    var durableAppends: [String] { lock.withLock { _durableAppends } }
    var durableDataWrites: [String] { lock.withLock { _durableDataWrites } }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await inner.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await inner.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        lock.withLock { _fastAppends.append(Self.label(record)) }
        try await inner.appendJSONL(record, to: path)
    }
    func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
        lock.withLock { _durableAppends.append(Self.label(record)) }
        try await inner.appendJSONLDurable(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
    func readJSONLReporting(_ path: URL) async throws -> (rows: [JSONValue], report: JSONLReadReport) {
        try await inner.readJSONLReporting(path)
    }
    func replaceJSONL(_ records: [JSONValue], to path: URL) async throws {
        try await inner.replaceJSONL(records, to: path)
    }
    func writeDataAtomicDurable(_ data: Data, to path: URL) async throws {
        lock.withLock { _durableDataWrites.append(path.lastPathComponent) }
        try await inner.writeDataAtomicDurable(data, to: path)
    }

    /// "user", "assistant", "tool", or "<role>/partial".
    static func label(_ record: JSONValue) -> String {
        guard case .object(let object) = record else { return "unknown" }
        var role = "?"
        if case .string(let value)? = object["role"] { role = value }
        if case .object(let metadata)? = object["metadata"],
           case .bool(true)? = metadata["partial"] {
            return "\(role)/partial"
        }
        return role
    }
}

private func durabilityRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-row-durability-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Minimal routing stub: this suite never runs a turn, it only exercises the
/// persistence seams, so the engine just needs a well-formed collaborator.
private final class DurabilityStubRouting: ProviderRoutingProtocol, @unchecked Sendable {
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

private func makeDurabilityClient(
    root: URL,
    spy: DurabilitySpyPersistence
) -> SwiftNativeChatOrchestrationClient {
    let llm = MockLLMClient(scriptedResponses: ["unused"])
    let tools = MockToolDispatchClient()
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: DurabilityStubRouting(),
        trust: hermeticTrust(),
        llm: llm,
        tools: tools
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: root),
        persistence: spy,
        dataRoot: root,
        trust: SwiftNativeTrustCenter(dataRoot: root)
    )
}

@Suite("Chat row durability")
struct ChatRowDurabilityTests {

    @Test("user rows and terminal assistant rows take the durable append")
    func committedTurnBoundariesAreDurable() async throws {
        let root = durabilityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = DurabilitySpyPersistence()
        let client = makeDurabilityClient(root: root, spy: spy)

        try await client.appendMessage(
            sessionId: "s-durable", role: "user", content: "hi",
            runId: "r1", attachments: []
        )
        try await client.appendMessage(
            sessionId: "s-durable", role: "assistant", content: "hello",
            runId: "r1", attachments: [], canonicalAssistantCompletion: true
        )

        #expect(spy.durableAppends == ["user", "assistant"])
        #expect(spy.fastAppends.isEmpty, "no committed turn boundary may take the fast path")
    }

    @Test("tool receipts — the record of an external effect — take the durable append")
    func toolReceiptsAreDurable() async throws {
        let root = durabilityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = DurabilitySpyPersistence()
        let client = makeDurabilityClient(root: root, spy: spy)

        try await client.appendToolMessage(
            sessionId: "s-tool", runId: "r1", toolName: "write_file",
            inputJSON: "{}", resultSummary: "wrote 1 file", ok: true
        )

        #expect(spy.durableAppends == ["tool"])
        #expect(spy.fastAppends.isEmpty)
    }

    @Test("streaming partials stay on the fast path")
    func partialsStayFast() async throws {
        let root = durabilityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = DurabilitySpyPersistence()
        let client = makeDurabilityClient(root: root, spy: spy)

        await client.persistPartialIfNeeded(
            sessionId: "s-partial", runId: "r1", text: "half a rep",
            cancelled: false, source: "app"
        )

        #expect(spy.fastAppends == ["assistant/partial"])
        #expect(spy.durableAppends.isEmpty, "a partial must not pay for an F_FULLFSYNC")
    }

    @Test("the session index is written through the durable atomic writer")
    func sessionIndexIsDurable() async throws {
        let root = durabilityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = DurabilitySpyPersistence()
        let client = makeDurabilityClient(root: root, spy: spy)

        try await client.appendMessage(
            sessionId: "s-index", role: "user", content: "hi",
            runId: "r1", attachments: []
        )

        #expect(spy.durableDataWrites == ["sessions.json"])
        // And the index really landed — durability must not have cost content.
        let indexData = try Data(
            contentsOf: root.appendingPathComponent("chat/sessions.json")
        )
        #expect(String(decoding: indexData, as: UTF8.self).contains("s-index"))
    }
}
