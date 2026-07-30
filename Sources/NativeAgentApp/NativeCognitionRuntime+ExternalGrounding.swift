import Foundation
import CognitiveSubstrate
import KnowledgeGraph
import MemoryV2
import PersistenceCore

extension NativeCognitionRuntime {
    func groundWithMemoryAndKnowledgeGraph(
        query: String,
        limit: Int = 5
    ) async -> CognitiveExternalGroundingResult {
        let substrate = await substrateForIntegration()
        let memory = externalGroundingMemoryOwner()
        return await substrate.groundExternalContext(
            query: query,
            memory: NativeCognitionMemoryReader(memory: memory),
            knowledgeGraph: NativeCognitionKnowledgeGraphReader(
                graphPath: externalGroundingGraphPath
            ),
            limit: limit
        )
    }

    func makeMemoryProposalCandidate(
        text: String,
        source: String = "cognitive_substrate",
        confidence: Double = 0.5,
        kind: String = "cognitive_proposal",
        evidenceNodeIds: [UUID] = []
    ) async -> CognitiveMemoryProposalCandidate? {
        let substrate = await substrateForIntegration()
        return await substrate.makeMemoryProposalCandidate(
            text: text,
            source: source,
            confidence: confidence,
            kind: kind,
            evidenceNodeIds: evidenceNodeIds
        )
    }

    func stageMemoryProposalCandidate(
        _ candidate: CognitiveMemoryProposalCandidate
    ) async -> CognitiveMemoryProposalStageReceipt {
        let substrate = await substrateForIntegration()
        let receipt: CognitiveMemoryProposalStageReceipt
        do {
            let proposal = try await externalGroundingMemoryOwner().propose(
                content: candidate.text,
                source: candidate.source,
                confidence: candidate.confidence,
                kind: candidate.kind
            )
            receipt = CognitiveMemoryProposalStageReceipt(
                candidateId: candidate.id,
                externalProposalId: proposal.id,
                status: "staged"
            )
        } catch {
            receipt = CognitiveMemoryProposalStageReceipt(
                candidateId: candidate.id,
                externalProposalId: nil,
                status: "failed",
                error: String(describing: error)
            )
        }
        await substrate.recordMemoryProposalStage(receipt)
        return receipt
    }

    private var externalGroundingGraphPath: URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
    }

    private func externalGroundingMemoryOwner() -> SwiftNativeMemoryV2 {
        if dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL {
            return .shared
        }
        guard let storage = try? MemoryStorage(dataRoot: dataRoot) else {
            return SwiftNativeMemoryV2()
        }
        return SwiftNativeMemoryV2(
            embedder: ManagedEmbeddingProvider(dataRoot: dataRoot),
            storage: MemoryStorageBridge(storage: storage)
        )
    }

    /// Narrow path-only proof for alternate-root tests. It exposes no memory,
    /// graph, prompt, or credential content.
    func _testExternalGroundingOwnerPaths() async -> (memory: URL?, graph: URL) {
        let memory = externalGroundingMemoryOwner()
        let bridge = await memory.underlyingBridge()
        let storagePath = await bridge?.underlyingStorage().path
        return (storagePath, externalGroundingGraphPath)
    }
}

private struct NativeCognitionMemoryReader: CognitiveMemoryReading {
    let memory: SwiftNativeMemoryV2

    func recallMemory(query: String, limit: Int) async throws -> [CognitiveExternalReference] {
        let response = try await memory.recall(
            MemoryV2RecallRequest(text: query, topK: limit, persona: nil)
        )
        return response.hits.prefix(limit).enumerated().map { index, hit in
            let rawID = hit.memoryID ?? "memory-\(index)"
            let content = hit.content ?? hit.preview
            return CognitiveExternalReference(
                id: rawID,
                source: "MemoryV2",
                title: "Memory \(rawID)",
                summary: NativeAppSecretRedactor.redactText(content),
                score: hit.score,
                metadata: [
                    "preview": .string(NativeAppSecretRedactor.redactText(hit.preview)),
                    "source": .string(hit.source ?? "swift-native"),
                ]
            )
        }
    }
}

private struct NativeCognitionKnowledgeGraphReader: CognitiveKnowledgeGraphReading {
    let graphPath: URL

    func searchKnowledgeGraph(query: String, limit: Int) async throws -> [CognitiveExternalReference] {
        let env = try await makeKnowledgeGraphReader(graphPath: graphPath).searchChecked(q: query)
        guard case .object(let root) = env,
              case .array(let results)? = root["results"] else {
            return []
        }
        return results.prefix(limit).enumerated().compactMap { index, value in
            guard case .object(let entity) = value else { return nil }
            let id = entity.stringValue("id") ?? "kg-\(index)"
            let name = entity.stringValue("name") ?? id
            let summary = entity.stringValue("summary") ?? name
            let mentions = entity.intValue("mention_count") ?? 0
            return CognitiveExternalReference(
                id: id,
                source: "KnowledgeGraph",
                title: NativeAppSecretRedactor.redactText(name),
                summary: NativeAppSecretRedactor.redactText(summary),
                score: min(1, 0.5 + Double(min(mentions, 10)) * 0.05),
                metadata: [
                    "mention_count": .int(Int64(mentions)),
                ]
            )
        }
    }
}

private extension MemoryRecallHit {
    var memoryID: String? {
        guard case .object(let extras)? = extras,
              case .string(let id)? = extras["id"],
              !id.isEmpty else {
            return nil
        }
        return id
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(_ key: String) -> String? {
        guard case .string(let value)? = self[key], !value.isEmpty else { return nil }
        return value
    }

    func intValue(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value)?: return Int(value)
        case .double(let value)?: return Int(value)
        case .string(let value)?: return Int(value)
        default: return nil
        }
    }
}
