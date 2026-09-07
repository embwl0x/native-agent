import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// EVAL FENCE: turn.contract
// Ledger row: telemetry.context.stage.memoryPromotion
//
// The production turn engine owns this receipt. A reporting promoter supplies
// only its staged count; the eval proves the bus sees the typed stage name,
// bounded count, and explicit evidence that the outcome was observable.
private struct MemoryPromotionTelemetryEvalPromoter: MemoryPromotionTelemetryReporting {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {}

    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        sessionId: String
    ) async -> MemoryPromotionTelemetry {
        MemoryPromotionTelemetry(stagedProposalCount: 2, semanticStatus: .timedOut,
                                 semanticCandidateCount: 0, candidateCount: 3)
    }
}

private struct LegacyMemoryPromotionTelemetryEvalPromoter: MemoryPromoting {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {}
}

private struct MemoryPromotionTelemetryEvalRouting: ProviderRoutingProtocol {
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

private struct MemoryPromotionTelemetryEvalLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String { "unused" }
}

@Test func memoryPromotionContextStage_reportsTheProductionOutcomeWithoutContent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-promotion-context-stage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    @Sendable func engine(promoter: (any MemoryPromoting)?) -> SwiftNativeTurnEngine {
        SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: MemoryPromotionTelemetryEvalRouting(),
            trust: hermeticTrust(),
            llm: MemoryPromotionTelemetryEvalLLM(),
            tools: MockToolDispatchClient(),
            memoryPromoter: promoter
        )
    }
    let events = try await withHermeticTraceBus(kinds: ["context.stage"], expecting: 3) { _ in
        await engine(promoter: nil).observeMemoryPromotion(
            userMessage: "unconfigured source content",
            assistantMessage: "unconfigured response content",
            sessionId: "promotion-unconfigured",
            surface: "chat"
        )
        await engine(promoter: LegacyMemoryPromotionTelemetryEvalPromoter()).observeMemoryPromotion(
            userMessage: "legacy source content",
            assistantMessage: "legacy response content",
            sessionId: "promotion-legacy",
            surface: "slack"
        )
        await engine(promoter: MemoryPromotionTelemetryEvalPromoter()).observeMemoryPromotion(
            userMessage: "reporting source content",
            assistantMessage: "reporting response content",
            sessionId: "promotion-reporting",
            surface: "telegram"
        )
    }

    #expect(events.count == 3)
    let payloadsBySurface = try Dictionary(uniqueKeysWithValues: events.map { event -> (String, [String: JSONValue]) in
        guard case .object(let payload) = event.payload else {
            throw NSError(domain: "MemoryPromotionContextStage", code: 1)
        }
        return (event.surface ?? "(missing surface)", payload)
    })
    #expect(Set(payloadsBySurface.keys) == ["chat", "slack", "telegram"])

    for payload in payloadsBySurface.values {
        #expect(payload["schema"] == .string("context.stage.v1"))
        #expect(payload["stage"] == .string(ContextStageEmissionName.memoryPromotion.rawValue))
        #expect(payload["elapsedMs"] != nil)
    }
    func state(_ surface: String) throws -> ([String: JSONValue], [String: JSONValue]) {
        let payload = try #require(payloadsBySurface[surface])
        guard case .object(let counts)? = payload["counts"],
              case .object(let flags)? = payload["flags"]
        else { throw NSError(domain: "MemoryPromotionContextStage", code: 2) }
        return (counts, flags)
    }
    let (unconfiguredCounts, unconfiguredFlags) = try state("chat")
    #expect(unconfiguredCounts["stagedProposalCount"] == .int(0))
    #expect(unconfiguredFlags == ["configured": .bool(false), "outcomeReported": .bool(false)])

    let (legacyCounts, legacyFlags) = try state("slack")
    #expect(legacyCounts["stagedProposalCount"] == .int(0))
    #expect(legacyFlags == ["configured": .bool(true), "outcomeReported": .bool(false)])

    let (reportingCounts, reportingFlags) = try state("telegram")
    #expect(reportingCounts["stagedProposalCount"] == .int(2))
    #expect(reportingCounts["extractedCandidateCount"] == .int(3))
    #expect(reportingCounts["semanticCandidateCount"] == .int(0))
    // 2026-09-06: every memory.promotion trace now also names the MOMENT
    // outcome (commit e2ddc19a) so a turn that staged nothing can be told apart
    // from one whose moment lane never reported. This stub reports no moment,
    // so the label is the "unreported" default — and it is still a LABEL, not
    // content, which is what this row is guarding.
    #expect(payloadsBySurface["telegram"]?["labels"] == .object([
        "semanticExtraction": .string("timedOut"),
        "momentOutcome": .string("unreported"),
    ]))
    #expect(reportingFlags == ["configured": .bool(true), "outcomeReported": .bool(true)])
    let serialized = String(describing: payloadsBySurface)
    #expect(!serialized.contains("source content"))
    #expect(!serialized.contains("response content"))
}
