import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Sweep item 35 — what she DID in a turn reaches memory.
//
// The turn's tool evidence used to stop at the transcript and OutcomeTissueV2.
// These tests pin the ChatOrchestration half: which dispatches are eligible,
// what the bounded projection looks like, and that the promoter seam carries it
// without changing prose-only behavior.

private func record(
    _ name: String,
    input: [String: JSONValue] = [:],
    result: JSONValue
) -> TurnEngineResult.ToolDispatchRecord {
    TurnEngineResult.ToolDispatchRecord(name: name, input: input, result: result)
}

private let authPath = "/Users/user/Projects/App/Sources/Auth.swift"

// MARK: - Eligibility

@Suite("TurnToolEvidenceProjection — eligibility")
struct TurnToolEvidenceEligibilityTests {

    @Test func successfulFileReadCarriesThePath() {
        let lines = TurnToolEvidenceProjection.project([
            record("read_file", input: ["path": .string(authPath)],
                   result: .string("import Foundation // 812 lines"))
        ])
        #expect(lines.count == 1)
        #expect(lines[0].contains(authPath))
        #expect(lines[0].hasPrefix("read_file("))
    }

    @Test func failedDispatchYieldsNothing() {
        let failures: [JSONValue] = [
            .object(["error": .string("ENOENT: \(authPath)")]),
            .object(["ok": .bool(false), "path": .string(authPath)]),
            .object(["success": .bool(false), "path": .string(authPath)]),
            .object(["status": .string("failed"), "path": .string(authPath)]),
            .object(["status": .string("denied"), "path": .string(authPath)]),
            .object(["exit_code": .int(1), "path": .string(authPath)]),
        ]
        for failure in failures {
            let lines = TurnToolEvidenceProjection.project([
                record("read_file", input: ["path": .string(authPath)], result: failure)
            ])
            #expect(lines.isEmpty, "expected no evidence for \(failure)")
        }
    }

    @Test func timeoutsCancellationsAndPendingEnvelopesYieldNothing() {
        let unsettled: [JSONValue] = [
            .object(["status": .string("timeout"), "path": .string(authPath)]),
            .object(["status": .string("timed_out"), "path": .string(authPath)]),
            .object(["status": .string("cancelled"), "path": .string(authPath)]),
            .object(["status": .string("pending_approval"), "path": .string(authPath)]),
            .object(["status": .string("queued"), "path": .string(authPath)]),
            .object(["dryRun": .bool(true), "path": .string(authPath)]),
            .null,
        ]
        for envelope in unsettled {
            let lines = TurnToolEvidenceProjection.project([
                record("mac_open", input: ["path": .string(authPath)], result: envelope)
            ])
            #expect(lines.isEmpty, "expected no evidence for \(envelope)")
        }
    }

    @Test func transientReadsAreNotEligible() {
        for name in ["screenshot", "get_time", "recall_memory", "weather", "context_expand"] {
            let lines = TurnToolEvidenceProjection.project([
                record(name, input: ["path": .string(authPath)], result: .string(authPath))
            ])
            #expect(lines.isEmpty, "expected \(name) to be transient")
        }
    }

    @Test func proseShapedSuccessIsNotEligible() {
        let lines = TurnToolEvidenceProjection.project([
            record("send_message",
                   input: ["text": .string("sounds good, talk later")],
                   result: .string("delivered"))
        ])
        #expect(lines.isEmpty)
    }

    @Test func verifiedMotorOutcomeWithABundleIdentifierIsEligible() {
        let lines = TurnToolEvidenceProjection.project([
            record("mac_launch",
                   input: ["bundle_id": .string("com.apple.Notes")],
                   result: .object(["status": .string("completed"), "error": .null]))
        ])
        #expect(lines.count == 1)
        #expect(lines[0].contains("com.apple.Notes"))
    }

    @Test func noDispatchesYieldNoEvidence() {
        #expect(TurnToolEvidenceProjection.project([]).isEmpty)
    }
}

// MARK: - Bounds and redaction

@Suite("TurnToolEvidenceProjection — bounds and redaction")
struct TurnToolEvidenceBoundsTests {

    @Test func dispatchCountCapHolds() {
        let dispatches = (0..<40).map { i in
            record("read_file",
                   input: ["path": .string("/Users/user/Projects/App/File\(i).swift")],
                   result: .string("ok"))
        }
        let lines = TurnToolEvidenceProjection.project(dispatches)
        let evidence = lines.filter { $0 != TurnToolEvidenceProjection.sequenceBreakMarker }
        #expect(evidence.count == TurnToolEvidenceProjection.maxDispatches)
        // 40 in, 6 out: what was dropped sat in the MIDDLE, so the window is
        // no longer a contiguous run and says so.
        #expect(lines.last == TurnToolEvidenceProjection.sequenceBreakMarker)
    }

    @Test func selectionKeepsBothEndsOfALongToolTurn() {
        let dispatches = (0..<10).map { i in
            record("read_file",
                   input: ["path": .string("/Users/user/Projects/App/File\(i).swift")],
                   result: .string("ok"))
        }
        let lines = TurnToolEvidenceProjection.project(dispatches)
        let evidence = lines.filter { $0 != TurnToolEvidenceProjection.sequenceBreakMarker }
        #expect(evidence.count == 6)
        #expect(evidence[0].contains("File0.swift"))
        #expect(evidence[2].contains("File2.swift"))
        // The tail — where a long turn's verified outcome actually lands —
        // survives instead of being truncated away with everything after #6.
        #expect(evidence[5].contains("File9.swift"))
        #expect(!evidence.contains { $0.contains("File5.swift") })
    }

    @Test func perLineCharacterCapHolds() {
        let huge = String(repeating: "y", count: 20_000)
        let lines = TurnToolEvidenceProjection.project([
            record("read_file",
                   input: ["path": .string("/Users/user/Projects/App/\(huge).swift")],
                   result: .string(huge))
        ])
        #expect(lines.count == 1)
        #expect(lines[0].count <= TurnToolEvidenceProjection.maxLineChars)
    }

    @Test func longResultsKeepHeadAndTail() {
        let middle = String(repeating: "m", count: 400)
        let lines = TurnToolEvidenceProjection.project([
            record("run_tests",
                   input: ["path": .string("/Users/user/Projects/App/Tests")],
                   result: .string("HEADMARK \(middle) TAILMARK"))
        ])
        #expect(lines.count == 1)
        #expect(lines[0].contains("HEADMARK"))
        #expect(lines[0].contains("TAILMARK"))
        #expect(lines[0].contains("elided"))
    }

    @Test func secretsAreRedactedInInputsAndResults() {
        let token = "ghp_abcdefghijklmnopqrstuvwxyz012345"
        let lines = TurnToolEvidenceProjection.project([
            record("read_file",
                   input: ["path": .string(authPath), "token": .string(token)],
                   result: .string("\(authPath) authorizes with \(token)"))
        ])
        #expect(lines.count == 1)
        #expect(!lines[0].contains(token))
        #expect(lines[0].contains("REDACTED"))
        #expect(lines[0].contains(authPath))
    }

    // MARK: Sequence integrity

    @Test func aCleanContiguousTurnCarriesNoMarker() {
        let lines = TurnToolEvidenceProjection.project([
            record("read_file", input: ["path": .string(authPath)], result: .string("ok")),
            record("write_file", input: ["path": .string(authPath)], result: .string("wrote")),
        ])
        #expect(lines.count == 2)
        #expect(!lines.contains(TurnToolEvidenceProjection.sequenceBreakMarker))
    }

    @Test func aFailedStepInTheMiddleMarksTheWindowBroken() {
        // The exact HIGH finding: `read ok, write ok, run_tests failed` used to
        // project as a clean `read → write`, and the procedural lane recorded a
        // verified run that never happened.
        let lines = TurnToolEvidenceProjection.project([
            record("read_file", input: ["path": .string(authPath)], result: .string("ok")),
            record("write_file", input: ["path": .string(authPath)], result: .string("wrote")),
            record("run_tests", input: ["path": .string("/Users/user/Projects/App/Tests")],
                   result: .object(["status": .string("failed")])),
        ])
        #expect(lines.filter { $0 != TurnToolEvidenceProjection.sequenceBreakMarker }.count == 2)
        #expect(lines.last == TurnToolEvidenceProjection.sequenceBreakMarker)
    }

    @Test func unsettledEnvelopesAlsoMarkTheWindowBroken() {
        for envelope: JSONValue in [
            .object(["status": .string("cancelled")]),
            .object(["status": .string("pending_approval")]),
            .object(["status": .string("timeout")]),
            .null,
        ] {
            let lines = TurnToolEvidenceProjection.project([
                record("read_file", input: ["path": .string(authPath)], result: .string("ok")),
                record("mac_open", input: ["path": .string(authPath)], result: envelope),
            ])
            #expect(lines.last == TurnToolEvidenceProjection.sequenceBreakMarker,
                    "expected a break marker for \(envelope)")
        }
    }

    @Test func theMarkerStaysBelowThePromoterCandidateFloor() {
        // Load-bearing coupling: the promoter drops any line shorter than
        // AdaptiveToolEvidence.minLineChars (12) before it can become a
        // candidate, which is what keeps this marker out of memory.
        #expect(TurnToolEvidenceProjection.sequenceBreakMarker.count < 12)
        #expect(TurnToolEvidenceProjection.sequenceBreakMarker.hasPrefix("!"))
    }

    @Test func identicalDispatchesDedupe() {
        let dispatches = (0..<4).map { _ in
            record("read_file", input: ["path": .string(authPath)], result: .string("ok"))
        }
        #expect(TurnToolEvidenceProjection.project(dispatches).count == 1)
    }
}

// MARK: - The promoter seam

private final class EvidenceSpyPromoter: MemoryPromoting, @unchecked Sendable {
    private let q = DispatchQueue(label: "EvidenceSpyPromoter")
    private var _calls: [(user: String, assistant: String, evidence: [String])] = []

    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        await observeTurn(userMessage: userMessage, assistantMessage: assistantMessage,
                          toolEvidence: [], sessionId: sessionId)
    }

    func observeTurn(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async {
        q.sync { _calls.append((userMessage, assistantMessage, toolEvidence)) }
    }

    var calls: [(user: String, assistant: String, evidence: [String])] { q.sync { _calls } }
}

/// Conforms with the PROSE-ONLY requirement, exactly as every promoter did
/// before item 35. The protocol's default must keep it working untouched.
private final class LegacyProseOnlyPromoter: MemoryPromoting, @unchecked Sendable {
    private let q = DispatchQueue(label: "LegacyProseOnlyPromoter")
    private var _count = 0
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        q.sync { _count += 1 }
    }
    var count: Int { q.sync { _count } }
}

private struct EvidenceSeamRouting: ProviderRoutingProtocol {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": .init(surface: "chat", model: "eval", reasoningEffort: "low")]
    }
}

private struct EvidenceSeamLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String { "unused" }
}

@Suite("Post-turn promoter seam — tool evidence")
struct TurnToolEvidenceSeamTests {

    private func engine(
        root: URL,
        promoter: (any MemoryPromoting)?
    ) -> SwiftNativeTurnEngine {
        SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: EvidenceSeamRouting(),
            trust: hermeticTrust(),
            llm: EvidenceSeamLLM(),
            tools: MockToolDispatchClient(),
            memoryPromoter: promoter
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-tool-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func projectedEvidenceReachesThePromoter() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let promoter = EvidenceSpyPromoter()

        _ = try await withHermeticTraceBus(kinds: ["context.stage"], expecting: 1) { _ in
            await engine(root: root, promoter: promoter).observeMemoryPromotion(
                userMessage: "where does auth live?",
                assistantMessage: "In the Auth module.",
                toolDispatches: [
                    record("read_file", input: ["path": .string(authPath)], result: .string("ok")),
                    record("read_file", input: ["path": .string("/Users/user/missing.swift")],
                           result: .object(["error": .string("ENOENT")])),
                ],
                sessionId: "s-evidence",
                surface: "chat"
            )
        }

        let calls = promoter.calls
        #expect(calls.count == 1)
        let evidence = calls[0].evidence
            .filter { $0 != TurnToolEvidenceProjection.sequenceBreakMarker }
        #expect(evidence.count == 1)
        #expect(evidence[0].contains(authPath))
        // The second dispatch failed, so the window reaches the promoter with
        // the break marker beside the one fact it did establish.
        #expect(calls[0].evidence.last == TurnToolEvidenceProjection.sequenceBreakMarker)
    }

    @Test func proseOnlyTurnSendsNoEvidence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let promoter = EvidenceSpyPromoter()

        _ = try await withHermeticTraceBus(kinds: ["context.stage"], expecting: 1) { _ in
            await engine(root: root, promoter: promoter).observeMemoryPromotion(
                userMessage: "my name is Example User",
                assistantMessage: "got it",
                sessionId: "s-prose",
                surface: "chat"
            )
        }

        let calls = promoter.calls
        #expect(calls.count == 1)
        #expect(calls[0].evidence.isEmpty)
        #expect(calls[0].user == "my name is Example User")
    }

    @Test func legacyProseOnlyPromoterStillObservesTheTurn() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let promoter = LegacyProseOnlyPromoter()

        _ = try await withHermeticTraceBus(kinds: ["context.stage"], expecting: 1) { _ in
            await engine(root: root, promoter: promoter).observeMemoryPromotion(
                userMessage: "where does auth live?",
                assistantMessage: "In the Auth module.",
                toolDispatches: [
                    record("read_file", input: ["path": .string(authPath)], result: .string("ok"))
                ],
                sessionId: "s-legacy",
                surface: "chat"
            )
        }

        #expect(promoter.count == 1)
    }
}
