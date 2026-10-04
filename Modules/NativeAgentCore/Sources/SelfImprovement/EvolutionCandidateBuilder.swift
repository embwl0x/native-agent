import Foundation
import NativeAgentCore
import PersistenceCore

// Persisted candidate evidence remains readable for approval and promotion.
// There is no automatic candidate build pipeline.

public enum EvolutionCandidatePhase: String, Sendable, Codable {
    case validate
    case worktreeAdd = "worktree_add"
    case headVerify = "head_verify"
    case apply
    case build
    case complete
}

public struct EvolutionCandidateResult: Sendable, Codable, Equatable {
    public var runId: String
    public var proposalId: String
    public var ok: Bool
    /// Furthest phase reached (== .complete on success).
    public var phase: EvolutionCandidatePhase
    public var expectedHead: String
    public var diffSHA256: String
    public var touchedPaths: [String]
    public var buildExit: Int32?
    public var timedOutPhase: String?
    public var error: String?
    public var startedAt: String
    public var finishedAt: String
    public var worktreeCleaned: Bool
}

public actor EvolutionCandidateBuilder {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol

    public init(
        repoRoot: URL,
        dataRoot: URL = defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    public nonisolated func candidatesDir() -> URL {
        dataRoot
            .appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("candidates", isDirectory: true)
    }

    public nonisolated func candidateDir(runId: String) -> URL {
        candidatesDir().appendingPathComponent(runId, isDirectory: true)
    }

    public nonisolated func resultPath(runId: String) -> URL {
        candidateDir(runId: runId).appendingPathComponent("result.json")
    }

    /// Fail-closed read of a persisted verdict. Missing → nil; corrupt →
    /// typed throw (never a default).
    public func loadResult(runId: String) async throws -> EvolutionCandidateResult? {
        guard EvolutionSupport.isSafePathComponent(runId) else {
            throw EvolutionEngineError.invalidRunId(runId)
        }
        let path = resultPath(runId: runId)
        return try await persistence.withFileLock(path) {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            do {
                let data = try Data(contentsOf: path)
                return try JSONDecoder().decode(EvolutionCandidateResult.self, from: data)
            } catch {
                throw EvolutionEngineError.storeCorrupt(path: path.path, detail: "\(error)")
            }
        }
    }
}
