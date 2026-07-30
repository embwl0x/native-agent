// Swift-native cutover mem-m6: weekly slow-path memory consolidation.
//
// Ports the retired daemon (deleted in earlier waves). Walks
// pending proposals in the MemoryV2 SQLite store, dedups against active
// memories by embedding cosine similarity, auto-accepts high-durability
// proposals, archives stale/low-quality active memories, and leaves marginal
// proposals pending for inbox review.
//
// Runs weekly (Sun 3am local) under NSBackgroundActivityScheduler from
// NativeAgentApp; can also be invoked inline from the debug menu.
//
// U3 WAVE-2 ITEM 7 (2026-06-10): consolidate() is now NON-DESTRUCTIVE.
// The public entry point routes through MemoryConsolidationGate — the
// mutation pipeline (consolidateDestructively, module-internal) only ever
// runs against a CANDIDATE copy of the store; the live store changes only
// when the staged `memory.consolidation.swap` approval card is approved
// and the gate's swap executor applies it. Every legacy caller
// (NativeClient.runMemoryHygiene, MemoryConsolidationHygiene.runOnce, the
// debug menu) inherits the probe-set gate through this seam with no
// signature change — the ConsolidationReport they receive now describes
// the PLANNED ops carried on the staged card, not applied mutations.

import Foundation
import GRDB
import NativeAgentCore
import OSLog
import PersistenceCore

// MARK: - ConsolidationReport

public struct ConsolidationReport: Sendable, Equatable {
    public let processed: Int
    public let autoAccepted: Int
    public let duplicatesMerged: Int
    public let pendingForReview: Int
    public let staleArchived: Int
    public let errors: [String]

    public init(
        processed: Int,
        autoAccepted: Int,
        duplicatesMerged: Int,
        pendingForReview: Int,
        staleArchived: Int,
        errors: [String]
    ) {
        self.processed = processed
        self.autoAccepted = autoAccepted
        self.duplicatesMerged = duplicatesMerged
        self.pendingForReview = pendingForReview
        self.staleArchived = staleArchived
        self.errors = errors
    }
}

// MARK: - Tunables

/// Cosine similarity at/above this counts a proposal as a duplicate of an
/// existing active memory. Match the original Python (0.92) so behavior is
/// preserved across the port.
public let memoryConsolidationDuplicateThreshold: Double = 0.92

/// Above this durability score (read from proposal.metadata.durability_score
/// when present, otherwise inferred from proposal.metadata or omitted), the
/// proposal auto-promotes to an active memory.
public let memoryConsolidationAutoAcceptThreshold: Double = 0.85

/// Active memories older than this with zero recall hits get archived.
public let memoryConsolidationStaleAgeSeconds: TimeInterval = 365 * 24 * 60 * 60

/// Active-memory semantic duplicate cleanup is intentionally stricter than
/// proposal-vs-active duplicate merge: only near-identical same-kind rows with
/// high lexical overlap are archived automatically.
public let memoryConsolidationActiveDuplicateThreshold: Double = 0.995
public let memoryConsolidationActiveDuplicateJaccardFloor: Double = 0.80

// MARK: - MemoryConsolidator actor

public actor MemoryConsolidator {
    private let storage: MemoryStorage
    private let logger: Logger
    private let now: @Sendable () -> Date
    /// Probe-gate injection points (tests / future app wiring). nil →
    /// ManagedEmbeddingProvider(dataRoot:) and the committed probe set
    /// (with the <dataRoot>/memory/probes/probe_set.json override).
    private let embedder: (any EmbeddingProvider)?
    private let probeSet: MemoryProbeSet?

    public init(
        storage: MemoryStorage,
        now: @escaping @Sendable () -> Date = { Date() },
        embedder: (any EmbeddingProvider)? = nil,
        probeSet: MemoryProbeSet? = nil
    ) {
        self.storage = storage
        self.logger = Logger(subsystem: "com.nativeagent.app", category: "memory-consolidation")
        self.now = now
        self.embedder = embedder
        self.probeSet = probeSet
    }

    // MARK: - Gated entry points (U3 wave-2 item 7)

    /// NON-DESTRUCTIVE consolidation: candidate store + probe gate +
    /// approval card; the live store is never mutated here. See
    /// MemoryV2+ConsolidationGate.swift for the full pipeline.
    public func consolidateGated() async throws -> GatedConsolidationOutcome {
        let dataRoot = MemoryConsolidationGate.deriveDataRoot(storagePath: storage.path)
        return try await MemoryConsolidationGate.run(
            liveStorage: storage,
            dataRoot: dataRoot,
            embedder: embedder,
            probeSet: probeSet,
            now: now
        )
    }

    /// Legacy-shaped adapter over consolidateGated(): every existing
    /// caller keeps compiling, but the report now describes the PLANNED
    /// ops staged on the approval card (or why nothing staged) — never
    /// applied mutations.
    public func consolidate() async throws -> ConsolidationReport {
        switch try await consolidateGated() {
        case .alreadyStaged(let approvalId):
            return ConsolidationReport(
                processed: 0, autoAccepted: 0, duplicatesMerged: 0,
                pendingForReview: 0, staleArchived: 0,
                errors: ["consolidation already staged for approval (card \(approvalId)) — no new run"]
            )
        case .noChanges(let plan):
            return plan
        case .refusedRegression(let scores, let plan):
            return ConsolidationReport(
                processed: plan.processed,
                autoAccepted: plan.autoAccepted,
                duplicatesMerged: plan.duplicatesMerged,
                pendingForReview: plan.pendingForReview,
                staleArchived: plan.staleArchived,
                errors: plan.errors + [
                    "probe gate REFUSED to stage: candidate lost probes "
                    + "[\(scores.lostProbeIds.joined(separator: ", "))] vs live "
                    + "(live \(scores.live.summary), candidate \(scores.candidate.summary)); "
                    + "candidate discarded"
                ]
            )
        case .staged(_, _, _, let plan):
            return plan
        }
    }

    // MARK: - Destructive pipeline (module-internal: candidate stores only)

    /// The original mem-m6 mutation pipeline. INTERNAL on purpose: the only
    /// production caller is MemoryConsolidationGate, which points it at a
    /// candidate copy — never the live store.
    func consolidateDestructively() async throws -> ConsolidationReport {
        var processed = 0
        var autoAccepted = 0
        var duplicatesMerged = 0
        var pendingForReview = 0
        var errors: [String] = []

        let pending = try await storage.listProposals(status: "pending")
        // Cache active memories with embeddings once per run so we don't
        // re-fetch on every proposal. Updated as we accept new proposals so
        // back-to-back near-duplicates also dedup against each other.
        var actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)

        for proposal in pending {
            processed += 1
            do {
                // 1) Tombstone check — skip if previously rejected.
                if try await storage.isTombstoned(content: proposal.content) {
                    _ = try await storage.rejectProposal(
                        id: proposal.id,
                        reason: "tombstoned: matches prior rejection"
                    )
                    continue
                }

                // 2) Durable-memory quality gate. This catches low-value
                // pending rows that predate stricter proposal-time filtering.
                if let reason = MemoryCandidateQuality.rejectionReason(
                    text: proposal.content,
                    source: proposal.source,
                    kind: MemoryRecallScoring.kind(of: proposal.metadata)
                ) {
                    _ = try await storage.rejectProposal(
                        id: proposal.id,
                        reason: "memory hygiene rejected non-durable proposal: \(reason)"
                    )
                    continue
                }

                // 3) Embedding cosine sim vs active memories → duplicate?
                if let dupe = bestDuplicate(for: proposal, against: actives) {
                    try await markProposalMerged(
                        proposalId: proposal.id,
                        intoMemoryId: dupe.id
                    )
                    duplicatesMerged += 1
                    continue
                }

                // 4) durability_score >= 0.85 → auto-accept.
                let durability = durabilityScore(proposal)
                if let d = durability, d >= memoryConsolidationAutoAcceptThreshold {
                    let accepted = try await storage.acceptProposal(id: proposal.id)
                    actives.append(accepted)
                    autoAccepted += 1
                    continue
                }

                // 5) Below threshold (or no score): leave pending for inbox.
                pendingForReview += 1
            } catch {
                errors.append("proposal \(proposal.id): \(error.localizedDescription)")
            }
        }

        // 5) Narrow supersession (wave1 S-lane, Agent's canon): for SINGLE-VALUED
        //    kinds only, a newer active fact archives the older same-kind fact —
        //    demotion with provenance, never deletion. Multi-valued kinds coexist.
        do {
            try await supersedeSingleValuedKinds()
        } catch {
            errors.append("supersession: \(error.localizedDescription)")
        }

        // 6) Active-memory quality/dedup hygiene.
        var activeQualityArchived = 0
        var activeDuplicatesArchived = 0
        do {
            activeQualityArchived = try await archiveNonDurableActiveMemories()
        } catch {
            errors.append("active quality archive: \(error.localizedDescription)")
        }
        do {
            activeDuplicatesArchived = try await archiveDuplicateActiveMemories()
            duplicatesMerged += activeDuplicatesArchived
        } catch {
            errors.append("active duplicate archive: \(error.localizedDescription)")
        }

        // 7) Stale eviction.
        let staleArchived: Int
        do {
            staleArchived = try await archiveStale() + activeQualityArchived
        } catch {
            errors.append("stale archive: \(error.localizedDescription)")
            staleArchived = activeQualityArchived
        }

        let report = ConsolidationReport(
            processed: processed,
            autoAccepted: autoAccepted,
            duplicatesMerged: duplicatesMerged,
            pendingForReview: pendingForReview,
            staleArchived: staleArchived,
            errors: errors
        )
        logger.info(
            "MemoryConsolidator: processed=\(processed, privacy: .public) autoAccepted=\(autoAccepted, privacy: .public) duplicatesMerged=\(duplicatesMerged, privacy: .public) pendingForReview=\(pendingForReview, privacy: .public) staleArchived=\(staleArchived, privacy: .public) errors=\(errors.count, privacy: .public)"
        )
        return report
    }

    // MARK: - Dedup

    private func bestDuplicate(
        for proposal: StoredProposal,
        against actives: [StoredMemory]
    ) -> StoredMemory? {
        guard let pe = proposal.embedding, !pe.isEmpty else { return nil }
        let qn = Self.l2norm(pe)
        guard qn > 0 else { return nil }
        var best: (StoredMemory, Double)? = nil
        for m in actives {
            guard let e = m.embedding, e.count == pe.count else { continue }
            let mn = Self.l2norm(e)
            guard mn > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * pe[i] }
            let sim = Double(dot) / (Double(qn) * Double(mn))
            if sim >= memoryConsolidationDuplicateThreshold {
                if best == nil || sim > best!.1 {
                    best = (m, sim)
                }
            }
        }
        return best?.0
    }

    /// Mark the proposal as 'merged' and bump the older memory's recall_count
    /// (stored under metadata.recall_count). Done in one storage call so the
    /// older memory's updated_at moves with the merge.
    private func markProposalMerged(proposalId: String, intoMemoryId: String) async throws {
        // Mark proposal merged.
        try await storage.markProposalStatus(
            id: proposalId,
            status: "merged",
            resolvedAt: Self.iso8601(now())
        )
        // Bump recall_count on the older memory.
        let mem = try await storage.memory(id: intoMemoryId)
        guard var m = mem else { return }
        var meta: [String: JSONValue] = [:]
        if case .object(let existing)? = m.metadata { meta = existing }
        let currentCount: Int64 = {
            if case .int(let n)? = meta["recall_count"] { return n }
            if case .double(let d)? = meta["recall_count"] { return Int64(d) }
            return 0
        }()
        meta["recall_count"] = .int(currentCount + 1)
        m.metadata = .object(meta)
        _ = try await storage.updateMemory(
            id: m.id,
            patch: MemoryPatch(metadata: .object(meta))
        )
    }

    // MARK: - durability score

    private func durabilityScore(_ proposal: StoredProposal) -> Double? {
        guard case .object(let obj)? = proposal.metadata else { return nil }
        if case .double(let d)? = obj["durability_score"] { return d }
        if case .int(let i)? = obj["durability_score"] { return Double(i) }
        return nil
    }

    // MARK: - supersession (wave1 S-lane)

    /// For each single-valued kind (location/employment/identity — two values
    /// can't both be true), the NEWEST active fact archives older same-kind
    /// actives that clear the cosine floor (mechanism guard: employment carries
    /// both work-at and work-as; the floor keeps unrelated same-kind facts from
    /// colliding). Archive only — supersession is demotion, not erasure.
    private func supersedeSingleValuedKinds() async throws {
        let actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        var byKind: [String: [StoredMemory]] = [:]
        for m in actives {
            guard let kind = MemoryRecallScoring.kind(of: m.metadata),
                  memorySupersessionSingleValuedKinds.contains(kind) else { continue }
            byKind[kind, default: []].append(m)
        }
        for (_, group) in byKind where group.count > 1 {
            // Newest first by PARSED Date — the codebase writes both fractional
            // and plain ISO8601, and string-sorting mixes them wrongly within
            // the same second (gpt-5.5 wave1 finding 4). Unparseable → distant
            // past (never wins newest). Tie-break by id for determinism.
            let sorted = group.sorted { a, b in
                let da = MemoryRecallScoring.parseTimestamp(a.createdAt) ?? .distantPast
                let db = MemoryRecallScoring.parseTimestamp(b.createdAt) ?? .distantPast
                if da != db { return da > db }
                return a.id > b.id
            }
            guard let newest = sorted.first else { continue }
            for older in sorted.dropFirst() {
                guard Self.cosine(newest.embedding, older.embedding) >= memorySupersessionCosineFloor else { continue }
                _ = try await storage.archiveSuperseded(id: older.id, by: newest.id)
            }
        }
    }

    // Single source of truth: VectorMath.cosine (raw, finiteness-guarded,
    // equal-length required). Consolidation compares the raw value against a
    // supersession/duplicate threshold, so no post-clamp here.
    private static func cosine(_ a: [Float]?, _ b: [Float]?) -> Double {
        VectorMath.cosine(a, b)
    }

    // MARK: - active-memory semantic hygiene

    private func archiveNonDurableActiveMemories() async throws -> Int {
        let actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        var archived = 0
        for memory in actives {
            if let reason = MemoryCandidateQuality.rejectionReason(
                text: memory.content,
                source: memory.source,
                kind: MemoryRecallScoring.kind(of: memory.metadata)
            ), try await archiveActiveMemory(
                memory,
                reason: "memory hygiene archived non-durable active memory: \(reason)",
                duplicateOf: nil
            ) {
                archived += 1
            }
        }
        return archived
    }

    private func archiveDuplicateActiveMemories() async throws -> Int {
        let actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        var archivedIDs = Set<String>()
        var archived = 0

        for group in Dictionary(grouping: actives, by: { Self.normalizedContentKey($0.content) }).values
            where group.count > 1 {
            let keeper = Self.preferredKeeper(in: group)
            for memory in group where memory.id != keeper.id {
                if try await archiveActiveMemory(
                    memory,
                    reason: "memory hygiene archived duplicate active memory",
                    duplicateOf: keeper.id
                ) {
                    archivedIDs.insert(memory.id)
                    archived += 1
                }
            }
        }

        let remaining = actives.filter { !archivedIDs.contains($0.id) }
        for i in remaining.indices {
            let left = remaining[i]
            guard !archivedIDs.contains(left.id) else { continue }
            for j in remaining.index(after: i)..<remaining.endIndex {
                let right = remaining[j]
                guard !archivedIDs.contains(right.id) else { continue }
                guard Self.sameKind(left, right) else { continue }
                guard Self.cosine(left.embedding, right.embedding) >= memoryConsolidationActiveDuplicateThreshold else { continue }
                guard Self.lexicalJaccard(left.content, right.content) >= memoryConsolidationActiveDuplicateJaccardFloor else { continue }
                let keeper = Self.preferredKeeper(in: [left, right])
                let duplicate = keeper.id == left.id ? right : left
                if try await archiveActiveMemory(
                    duplicate,
                    reason: "memory hygiene archived semantic duplicate active memory",
                    duplicateOf: keeper.id
                ) {
                    archivedIDs.insert(duplicate.id)
                    archived += 1
                }
            }
        }
        return archived
    }

    private func archiveActiveMemory(
        _ memory: StoredMemory,
        reason: String,
        duplicateOf: String?
    ) async throws -> Bool {
        var meta: [String: JSONValue] = [:]
        if case .object(let existing)? = memory.metadata { meta = existing }
        meta["hygiene_archive_reason"] = .string(reason)
        meta["hygiene_archived_at"] = .string(Self.iso8601(now()))
        if let duplicateOf {
            meta["duplicate_of"] = .string(duplicateOf)
        }
        let updated = try await storage.updateMemory(
            id: memory.id,
            patch: MemoryPatch(status: "archived", metadata: .object(meta))
        )
        return updated?.status == "archived"
    }

    private static func sameKind(_ left: StoredMemory, _ right: StoredMemory) -> Bool {
        let leftKind = MemoryRecallScoring.kind(of: left.metadata) ?? ""
        let rightKind = MemoryRecallScoring.kind(of: right.metadata) ?? ""
        return leftKind == rightKind
    }

    private static func preferredKeeper(in memories: [StoredMemory]) -> StoredMemory {
        memories.sorted { left, right in
            if left.confidence != right.confidence { return left.confidence > right.confidence }
            if left.useCount != right.useCount { return left.useCount > right.useCount }
            let leftDate = parseISO8601(left.updatedAt) ?? .distantPast
            let rightDate = parseISO8601(right.updatedAt) ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if left.content.count != right.content.count { return left.content.count > right.content.count }
            return left.id < right.id
        }.first!
    }

    // Internal (not private): MemoryV2.store's write-time exact-duplicate
    // guard shares this exact normalization so "duplicate" means the same
    // thing at write time and at weekly hygiene time.
    static func normalizedContentKey(_ content: String) -> String {
        content
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"'` "))
            .lowercased()
    }

    private static func lexicalJaccard(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(lexicalTokens(left))
        let rightTokens = Set(lexicalTokens(right))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func lexicalTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - stale eviction

    private func archiveStale() async throws -> Int {
        let cutoff = now().addingTimeInterval(-memoryConsolidationStaleAgeSeconds)
        let actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)
        var archived = 0
        for m in actives {
            guard let updated = Self.parseISO8601(m.updatedAt) else { continue }
            guard updated < cutoff else { continue }
            let recall: Int64 = {
                guard case .object(let obj)? = m.metadata else { return 0 }
                if case .int(let n)? = obj["recall_count"] { return n }
                if case .double(let d)? = obj["recall_count"] { return Int64(d) }
                return 0
            }()
            // Agent's ruling (2026-06-09): recall_count (merge corroboration) and
            // use_count (recall access) are separate signals of life — evict only
            // when NEITHER shows any. A memory recalled often but never merged
            // into must not read as "unused."
            guard recall == 0, m.useCount == 0 else { continue }
            // Conditional write: re-checks use_count == 0 INSIDE the UPDATE so a
            // recall bump landing after our snapshot vetoes the eviction
            // (TOCTOU fix, gpt-5.5 review finding 1).
            if try await storage.archiveIfStillUnused(id: m.id) {
                archived += 1
            }
        }
        return archived
    }

    // MARK: - helpers

    private static func l2norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return s.squareRoot()
    }

    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
