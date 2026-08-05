import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - U2b wave 1: evolution proposal store
//
// Durable store for self-evolution proposals at
// `<dataRoot>/evolution/proposals.json`, every mutation CAS'd under the
// repo's cross-process flock convention (PersistenceCore withFileLock —
// executions casMutateMission precedent).
//
// SAFETY INVARIANT (plan design #7): evolution proposals are NEVER
// auto-approvable. Live policy has `autoApproveLowRiskImprovements: true`;
// the wave-2 executor enforces the exclusion at the approval layer, but the
// RECORD SHAPE itself is hardened here: `risk` is structurally pinned to
// "critical" and `autoApprove` to `false` — both are force-overwritten on
// decode, so even a tampered/mis-written proposals.json can never present a
// low-risk record to a mis-wired approval path.

// MARK: - Status machine

public enum EvolutionProposalStatus: String, Sendable, Codable, CaseIterable {
    case needsDiff = "needs_diff"
    case proposed
    case building
    case candidateGreen = "candidate_green"
    case candidateFailed = "candidate_failed"
    case staged
    case approved
    case installed
    case verified
    case reverted
    case denied

    /// Legal exit edges. Terminal statuses (verified/reverted/denied) have no
    /// transition exits — their remove path is `sweep(olderThanDays:)`, which
    /// closes the state-lifecycle loop.
    public static let legalTransitions: [EvolutionProposalStatus: Set<EvolutionProposalStatus>] = [
        .needsDiff: [.proposed, .denied],
        .proposed: [.building, .denied],
        .building: [.candidateGreen, .candidateFailed],
        .candidateGreen: [.staged, .denied],
        .candidateFailed: [.proposed, .denied],
        .staged: [.approved, .denied],
        .approved: [.installed, .reverted],
        .installed: [.verified, .reverted],
        .verified: [],
        .reverted: [],
        .denied: [],
    ]

    public var isTerminal: Bool {
        Self.legalTransitions[self]?.isEmpty ?? true
    }
}

public enum EvolutionProposalSource: String, Sendable, Codable {
    case weekly
    case chat
    case selfHeal = "self_heal"
    case external
}

// MARK: - Receipt

public struct EvolutionReceipt: Sendable, Codable, Equatable {
    public var at: String
    public var kind: String
    public var detail: String

    public init(at: String, kind: String, detail: String) {
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - Proposal record

public struct EvolutionProposal: Sendable, Codable, Equatable {
    public var id: String
    public var source: EvolutionProposalSource
    public var title: String
    public var evidence: String
    public var diffText: String?
    public var diffSHA256: String?
    public var expectedHead: String?
    public var status: EvolutionProposalStatus
    public var candidateRunId: String?
    public var promotedCommitSha: String?
    public var denyReason: String?
    public var createdAt: String
    public var updatedAt: String
    public var receipts: [EvolutionReceipt]

    /// Structurally pinned high tier — see file header. Not settable.
    public private(set) var risk: String = Self.pinnedRisk
    /// Structurally pinned — evolution cards are explicit-human-only.
    public private(set) var autoApprove: Bool = false

    public static let pinnedRisk = "critical"

    public init(
        id: String,
        source: EvolutionProposalSource,
        title: String,
        evidence: String,
        diffText: String?,
        diffSHA256: String?,
        expectedHead: String?,
        status: EvolutionProposalStatus,
        candidateRunId: String? = nil,
        promotedCommitSha: String? = nil,
        denyReason: String? = nil,
        createdAt: String,
        updatedAt: String,
        receipts: [EvolutionReceipt] = []
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.evidence = evidence
        self.diffText = diffText
        self.diffSHA256 = diffSHA256
        self.expectedHead = expectedHead
        self.status = status
        self.candidateRunId = candidateRunId
        self.promotedCommitSha = promotedCommitSha
        self.denyReason = denyReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.receipts = receipts
        self.risk = Self.pinnedRisk
        self.autoApprove = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.source = (try? c.decode(EvolutionProposalSource.self, forKey: .source)) ?? .external
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        self.diffText = try c.decodeIfPresent(String.self, forKey: .diffText)
        self.diffSHA256 = try c.decodeIfPresent(String.self, forKey: .diffSHA256)
        self.expectedHead = try c.decodeIfPresent(String.self, forKey: .expectedHead)
        self.status = try c.decode(EvolutionProposalStatus.self, forKey: .status)
        self.candidateRunId = try c.decodeIfPresent(String.self, forKey: .candidateRunId)
        self.promotedCommitSha = try c.decodeIfPresent(String.self, forKey: .promotedCommitSha)
        self.denyReason = try c.decodeIfPresent(String.self, forKey: .denyReason)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        self.receipts = try c.decodeIfPresent([EvolutionReceipt].self, forKey: .receipts) ?? []
        // HARD PIN: ignore whatever is on disk. A tampered "risk": "low" or
        // "autoApprove": true must never survive a round-trip.
        self.risk = Self.pinnedRisk
        self.autoApprove = false
    }
}

// MARK: - Store

public actor EvolutionProposalStore {
    private let persistence: any PersistenceCoreProtocol
    private let dataRoot: URL
    private let now: @Sendable () -> Date

    public init(
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = defaultDataRoot(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.dataRoot = dataRoot
        self.now = now
    }

    public nonisolated var storePath: URL {
        dataRoot
            .appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("proposals.json")
    }

    // MARK: - Public API

    /// File a new proposal. With a diff → `proposed`; without → `needs_diff`.
    @discardableResult
    public func propose(
        source: EvolutionProposalSource,
        title: String,
        evidence: String,
        diffText: String? = nil,
        expectedHead: String? = nil
    ) async throws -> EvolutionProposal {
        let stamp = EvolutionSupport.isoTimestamp(now())
        let trimmedDiff = diffText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDiff = (trimmedDiff?.isEmpty == false)
        let proposal = EvolutionProposal(
            id: newProposalId(),
            source: source,
            title: title,
            evidence: evidence,
            diffText: hasDiff ? diffText : nil,
            diffSHA256: hasDiff ? EvolutionSupport.sha256Hex(diffText ?? "") : nil,
            expectedHead: expectedHead,
            status: hasDiff ? .proposed : .needsDiff,
            createdAt: stamp,
            updatedAt: stamp,
            receipts: [EvolutionReceipt(at: stamp, kind: "proposed", detail: "filed via \(source.rawValue)")]
        )
        try await mutateAll { proposals -> Bool in
            proposals.append(proposal)
            return true
        }
        return proposal
    }

    /// Attach a diff to a `needs_diff` proposal → `proposed`. CAS'd.
    @discardableResult
    public func attachDiff(
        id: String,
        diffText: String,
        expectedHead: String? = nil
    ) async throws -> EvolutionProposal {
        let trimmed = diffText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EvolutionEngineError.underlying("attachDiff: empty diff refused")
        }
        let stamp = EvolutionSupport.isoTimestamp(now())
        let (proposal, _) = try await mutateOne(id: id) { p -> Bool in
            guard p.status == .needsDiff else {
                throw EvolutionEngineError.illegalTransition(
                    id: id, from: p.status.rawValue, to: EvolutionProposalStatus.proposed.rawValue)
            }
            p.diffText = diffText
            p.diffSHA256 = EvolutionSupport.sha256Hex(diffText)
            if let expectedHead { p.expectedHead = expectedHead }
            p.status = .proposed
            p.updatedAt = stamp
            p.receipts.append(EvolutionReceipt(at: stamp, kind: "diff_attached", detail: "sha256=\(p.diffSHA256 ?? "")"))
            return true
        }
        return proposal
    }

    /// CAS transition under flock. `require` adds an explicit precondition on
    /// the current status beyond the legal-edge table; pass nil to rely on the
    /// table alone. Illegal edge or failed precondition → `applied: false`
    /// with the unmodified record (concurrent transition wins, Workshop executions
    /// casMutateMission convention).
    public func transition(
        id: String,
        to newStatus: EvolutionProposalStatus,
        require: Set<EvolutionProposalStatus>? = nil,
        receipt: String? = nil,
        candidateRunId: String? = nil,
        promotedCommitSha: String? = nil,
        denyReason: String? = nil
    ) async throws -> (proposal: EvolutionProposal, applied: Bool) {
        let stamp = EvolutionSupport.isoTimestamp(now())
        let (proposal, applied) = try await mutateOne(id: id) { p -> Bool in
            if let require, !require.contains(p.status) { return false }
            guard let exits = EvolutionProposalStatus.legalTransitions[p.status],
                  exits.contains(newStatus) else { return false }
            p.status = newStatus
            p.updatedAt = stamp
            if let candidateRunId { p.candidateRunId = candidateRunId }
            if let promotedCommitSha { p.promotedCommitSha = promotedCommitSha }
            if let denyReason { p.denyReason = denyReason }
            p.receipts.append(EvolutionReceipt(
                at: stamp, kind: "transition",
                detail: receipt ?? "-> \(newStatus.rawValue)"))
            return true
        }
        return (proposal, applied)
    }

    public func appendReceipt(id: String, kind: String, detail: String) async throws {
        let stamp = EvolutionSupport.isoTimestamp(now())
        _ = try await mutateOne(id: id) { p -> Bool in
            p.receipts.append(EvolutionReceipt(at: stamp, kind: kind, detail: detail))
            p.updatedAt = stamp
            return true
        }
    }

    public func get(id: String) async throws -> EvolutionProposal? {
        try await withLock { try self.loadLocked().first { $0.id == id } }
    }

    public func list(statuses: Set<EvolutionProposalStatus>? = nil) async throws -> [EvolutionProposal] {
        try await withLock {
            let all = try self.loadLocked()
            let filtered = statuses.map { set in all.filter { set.contains($0.status) } } ?? all
            return filtered.sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Remove path for terminal records (state-lifecycle cleanup audit):
    /// terminal proposals older than `olderThanDays` are dropped. Non-terminal
    /// records are never swept. Returns count removed.
    @discardableResult
    public func sweep(olderThanDays days: Int = 30) async throws -> Int {
        let cutoff = now().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return try await mutateAll { proposals -> Int in
            let before = proposals.count
            proposals.removeAll { p in
                guard p.status.isTerminal else { return false }
                guard let updated = EvolutionSupport.parseISO(p.updatedAt) else { return false }
                return updated < cutoff
            }
            return before - proposals.count
        }
    }

    // MARK: - Internals

    private func newProposalId() -> String {
        let ts = Int(now().timeIntervalSince1970 * 1000)
        let rand = UInt32.random(in: 0..<UInt32.max)
        return "evo_\(ts)_\(String(rand, radix: 16))"
    }

    /// Fail-closed load, MUST be called while holding the flock. Missing file
    /// → empty store (legitimate fresh-install state). Present-but-unparseable
    /// → typed `storeCorrupt`, never silently overwritten with `[]` (which is
    /// what `persistence.readJSON(defaultValue:)` would do).
    private nonisolated func loadLocked() throws -> [EvolutionProposal] {
        let path = storePath
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw EvolutionEngineError.storeCorrupt(path: path.path, detail: "unreadable: \(error)")
        }
        do {
            return try JSONDecoder().decode([EvolutionProposal].self, from: data)
        } catch {
            throw EvolutionEngineError.storeCorrupt(path: path.path, detail: "decode failed: \(error)")
        }
    }

    private nonisolated func saveLocked(_ proposals: [EvolutionProposal]) async throws {
        let data = try JSONEncoder().encode(proposals)
        let jv = try JSONDecoder().decode(JSONValue.self, from: data)
        try await persistence.writeJSON(jv, to: storePath)
    }

    private func withLock<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await persistence.withFileLock(storePath, body)
    }

    @discardableResult
    private func mutateAll<T: Sendable>(
        _ mutate: @escaping @Sendable (inout [EvolutionProposal]) throws -> T
    ) async throws -> T {
        try await withLock {
            var proposals = try self.loadLocked()
            let out = try mutate(&proposals)
            try await self.saveLocked(proposals)
            return out
        }
    }

    private func mutateOne<T: Sendable>(
        id: String,
        _ mutate: @escaping @Sendable (inout EvolutionProposal) throws -> T
    ) async throws -> (proposal: EvolutionProposal, value: T) {
        try await withLock {
            var proposals = try self.loadLocked()
            guard let idx = proposals.firstIndex(where: { $0.id == id }) else {
                throw EvolutionEngineError.proposalNotFound(id: id)
            }
            var p = proposals[idx]
            let out = try mutate(&p)
            proposals[idx] = p
            try await self.saveLocked(proposals)
            return (p, out)
        }
    }
}
