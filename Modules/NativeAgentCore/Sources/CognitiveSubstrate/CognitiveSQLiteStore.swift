import NativeAgentCore
import Foundation
import NativeAgentShared
import GRDB
import PersistenceCore
// Blueprint: | `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore` actor; `backupForDoctor`, `commitMaintenance` |

struct CognitiveArtifactWrite: Sendable, Equatable {
    var kind: String
    var id: UUID
    var status: String
    var score: Double
    var payload: JSONValue
}

struct CognitiveReceiptWrite: Sendable, Equatable {
    var kind: String
    var payload: JSONValue
    /// When execution began, for a receipt measured at its insertion point.
    var startedAt: ContinuousClock.Instant? = nil
}

/// Minimum newest rows retained from each active or migration-compatible
/// artifact family before generic age-based pruning may spend that family.
///
/// BOUNDED WORST CASE — protection is an eviction ORDERING, never a veto.
/// pruneArtifacts always deletes exactly `count - cap` rows (protected rows sort
/// last, but they are still spent once the unprotected supply runs out), so the
/// table is bounded at `cap` no matter how many families are listed here or how
/// lopsidedly they fill. A full protected family may spend its floor when
/// the rest of the table has no unprotected rows left.
/// Kinds the generic cap never counts or evicts. Cares have no count cap:
/// lane 3's night fades the unused ones, and the four seeds never go.
private let cognitiveUnprunedArtifactKinds: Set<String> = [
    "care", "care_migration", "care_retired_migration", "standing_view", "thought_seed",
]

private let cognitiveProtectedArtifactMinimums: [String: Int] = [
    "affect": 32,
    // One row, rewritten in place: the capsule cadence ledger. Tiny, but losing
    // it re-opens a suppressed nag on the next relaunch.
    "capsule_presentation": 1,
    // One row: 48 rejections and one disposition undo; her corrections survive pruning.
    "mind_ledger": 1,
    "disposition": 32,
    "emotional_consolidation": 32,
    "episode": 64,
    "schema_proposal": 64,
    // Retired from resident cognition, but old rows remain byte-preserved for
    // backup/migration readers rather than being silently deleted at store open.
    "identity_proposal": 32,
    "developmental_timeline": 128,
    "reflection_receipt": 32,
]

/// Receipt floors prioritize critical history for retention without overriding the hard cap.
private let cognitiveProtectedReceiptMinimums: [String: Int] = [
    "reflection.persona_context": 32,
    "reflection.persona_load_failed": 32,
    "reflection.skipped": 32,
    "emotional_consolidation": 32,
    "replay.integration": 32,
    // A pending reconciliation is UNFINISHED work, not history: trimming it
    // silently drops replay evidence that was never integrated (8 live rows).
    "replay.reconciliation_pending": 32,
    "workshop.pursuit_proposed": 32,
    "workshop.pursuit_proposal_refused": 32,
]

struct CognitiveArtifactFamilyLoad: Sendable, Equatable {
    var key: String
    var kindPrefix: String
    var limit: Int
    /// Every row of exactly this kind, not a prefix and not capped: `care`
    /// must not also load `care_migration`, and cares have no count cap.
    var whole = false
}

struct CognitiveSQLiteRestoreBundle: Sendable, Equatable {
    var nodes: [CognitiveNode]
    /// Exact persistence checkpoints for the already-decayed node values.
    /// Keyed by stable node ID so ContinuityField can rebuild its private index.
    var nodeDecayAnchors: [UUID: Date]
    var artifacts: [String: [JSONValue]]
}

enum CognitiveSQLiteReadError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedRow(table: String, id: String, detail: String)

    var description: String {
        switch self {
        case .malformedRow(let table, let id, let detail):
            return "malformed \(table) row \(id): \(detail)"
        }
    }
}

enum CognitiveSQLiteCounterError: Error, CustomStringConvertible {
    case outsideStorageRange(String)
    case exhausted(String)

    var description: String {
        switch self {
        case .outsideStorageRange(let name): "\(name) is outside SQLite's nonnegative signed-integer range"
        case .exhausted(let name): "\(name) has exhausted SQLite's signed-integer range"
        }
    }
}

public actor CognitiveSQLiteStore {
    private static let maximumMotorConsequenceAdmissions = 4_096
    public let databaseURL: URL
    let dbQueue: DatabaseQueue

    public init(dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.databaseURL = dir.appendingPathComponent("cognition.sqlite")
        var config = Configuration()
        // Without a busy timeout GRDB fails a write instantly with SQLITE_BUSY
        // when any second connection (probe CLI, second process) holds the
        // lock — the affect/node checkpoint would be lost, and
        // recordReceipt swallows the throw. Matches every sibling store.
        config.busyMode = .timeout(2)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
        try Self.drainRetiredCognitionArtifacts(dbQueue)
    }

    /// Consistent online snapshot through the mounted writer before Doctor restores.
    public func backupForDoctor() throws -> URL {
        let name = "cognition.sqlite.doctor-bak-\(NativeTimestampFormat.fractionalZulu(Date()).replacingOccurrences(of: ":", with: ""))-\(UUID().uuidString)"
        let destination = databaseURL.deletingLastPathComponent().appendingPathComponent(name)
        let backup = try DatabaseQueue(path: destination.path)
        try dbQueue.backup(to: backup)
        let result = try backup.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard result == "ok" else { throw CognitivePersistenceError.storeUnavailable }
        try backup.close()
        return destination
    }

    /// Drain retired cognition rows at open, including rows a downgraded
    /// pre-retirement binary may have written after newer migrations ran.
    private static func drainRetiredCognitionArtifacts(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            // Artifact rows: the persisted `prediction`/`commitment` records plus the
            // mirror `receipt.prediction_resolution` rows appendReceipt writes.
            try db.execute(sql: """
                DELETE FROM cognitive_artifacts
                WHERE kind LIKE 'prediction%'
                   OR kind LIKE 'commitment%'
                   OR kind LIKE 'receipt.%'
                   OR kind LIKE 'cue_authoring%'
                """)
            // Receipt rows carry the bare kind (e.g. 'prediction_resolution').
            try db.execute(sql: """
                DELETE FROM cognitive_receipts
                WHERE kind LIKE 'prediction%'
                   OR kind LIKE 'commitment%'
                   OR kind LIKE 'cue_authoring%'
                """)
            // R8a cue authoring had already lost its capsule consumer before
            // the lane was retired. Remove its inert node decorations so they
            // cannot spend bounded metadata slots forever.
            try db.execute(sql: """
                UPDATE cognitive_nodes
                SET metadata_json = json_remove(
                    metadata_json,
                    '$.authored_cue',
                    '$.authored_cue_hash',
                    '$.authored_cue_at'
                )
                WHERE json_type(metadata_json, '$.authored_cue') IS NOT NULL
                   OR json_type(metadata_json, '$.authored_cue_hash') IS NOT NULL
                   OR json_type(metadata_json, '$.authored_cue_at') IS NOT NULL
                """)
        }
    }

    /// Durable, payload-free replay guard for canonical motor projections.
    /// Domain owners remain authoritative; this table only prevents an older,
    /// duplicate, or equal-time contradictory projection from re-entering
    /// resident physiology after a relaunch.
    public func admitMotorConsequence(_ model: MotorActionReadModel, at now: Date) async throws -> Bool {
        let actionKey = CausalTransitionEvidence.opaqueIdentity(
            "\(model.domain)|\(model.actionIdentity)"
        )
        let fingerprint = CausalTransitionEvidence.opaqueIdentity([
            model.domain,
            model.actionIdentity,
            model.phase.rawValue,
            model.domainState,
            model.verification.rawValue,
        ].joined(separator: "|"))
        let ownerUpdatedAt = Self.motorOwnerTimestamp(model.updatedAt)?.timeIntervalSince1970
        return try await dbQueue.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT semantic_fingerprint, owner_updated_at
                    FROM cognitive_motor_consequence_admission
                    WHERE action_key = ?
                    """,
                arguments: [actionKey]
            ) {
                let existingFingerprint: String = try existing.decode(forColumn: "semantic_fingerprint")
                if existingFingerprint == fingerprint { return false }
                let existingOwnerUpdatedAt: Double? = try existing.decode(forColumn: "owner_updated_at")
                // Without a strictly newer canonical owner timestamp, a
                // contradiction is ambiguous and therefore cannot affect the
                // resident body. Exact later corrections remain admissible.
                guard let ownerUpdatedAt,
                      existingOwnerUpdatedAt.map({ ownerUpdatedAt > $0 }) ?? true else {
                    return false
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO cognitive_motor_consequence_admission (
                        action_key, semantic_fingerprint, owner_updated_at, admitted_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(action_key) DO UPDATE SET
                        semantic_fingerprint = excluded.semantic_fingerprint,
                        owner_updated_at = excluded.owner_updated_at,
                        admitted_at = excluded.admitted_at
                    """,
                arguments: [actionKey, fingerprint, ownerUpdatedAt, now.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    DELETE FROM cognitive_motor_consequence_admission
                    WHERE action_key IN (
                        SELECT action_key FROM cognitive_motor_consequence_admission
                        ORDER BY admitted_at DESC, action_key DESC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                arguments: [Self.maximumMotorConsequenceAdmissions]
            )
            return true
        }
    }

    /// Artifact writes and their capacity releases are one transaction.
    func commitArtifactTransition(
        artifacts: [CognitiveArtifactWrite],
        deletedArtifactIDs: [UUID],
        at now: Date
    ) async throws {
        try await dbQueue.write { db in
            for artifact in artifacts {
                try Self.upsertArtifact(db, artifact: artifact, at: now)
            }
            for id in Set(deletedArtifactIDs) {
                try db.execute(sql: "DELETE FROM cognitive_artifacts WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    /// Commit one replay integration as a single SQLite transition. Episodes,
    /// schema changes, timeline lineage, and the correlated receipt either all
    /// become durable or none do; evidence is never permanently consumed by a
    /// partial sequence of best-effort artifact writes.
    func commitReplayIntegration(
        artifacts: [CognitiveArtifactWrite],
        receiptPayload: JSONValue?,
        maxArtifacts: Int,
        maxReceipts: Int = 10_000,
        at now: Date
    ) async throws {
        try await dbQueue.write { db in
            for artifact in artifacts {
                try Self.upsertArtifact(db, artifact: artifact, at: now)
            }
            if let receiptPayload {
                try Self.insertReceipt(db, kind: "replay.integration", payload: receiptPayload, at: now)
            }
            _ = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            )
            _ = try Self.pruneReceipts(
                db,
                maxReceipts: maxReceipts,
                protectedMinimums: cognitiveProtectedReceiptMinimums
            )
        }
    }

    /// Commit one complete cognition-maintenance transition. Affect, consumed
    /// residue, emotional consolidation, the exact node snapshot, and their receipts all
    /// become durable or none do. This deliberately remains inside the one
    /// canonical cognition store; maintenance does not gain a second ledger.
    func commitMaintenance(
        nodes: [CognitiveNode],
        artifacts: [CognitiveArtifactWrite],
        deletedArtifactIDs: [UUID],
        receipts: [CognitiveReceiptWrite],
        maxNodes: Int,
        maxArtifacts: Int,
        maxReceipts: Int = 10_000,
        at now: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cognitive_nodes")
            for node in nodes {
                try Self.insertNode(db, node: node, at: now)
            }

            for artifact in artifacts {
                try Self.upsertArtifact(db, artifact: artifact, at: now)
            }
            for id in Set(deletedArtifactIDs) {
                try db.execute(
                    sql: "DELETE FROM cognitive_artifacts WHERE id = ?",
                    arguments: [id.uuidString]
                )
            }

            // Exact snapshots are already bounded, but keep the store boundary
            // defensive if a malformed caller ever exceeds the configured cap.
            let nodeCap = max(1, maxNodes)
            try db.execute(
                sql: """
                DELETE FROM cognitive_nodes
                WHERE id IN (
                    SELECT id FROM cognitive_nodes
                    ORDER BY salience ASC, activation ASC, last_activated_at ASC, id ASC
                    LIMIT MAX((SELECT COUNT(*) FROM cognitive_nodes) - ?, 0)
                )
                """,
                arguments: [nodeCap]
            )
            let deletedNodes = db.changesCount
            // Remove legacy receipt mirrors even if restored after store open.
            try db.execute(sql: "DELETE FROM cognitive_artifacts WHERE kind LIKE 'receipt.%'")
            let deletedMirrors = db.changesCount
            let deletedArtifacts = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            ).count + deletedMirrors
            for receipt in receipts {
                var payload = receipt.payload
                if let startedAt = receipt.startedAt, case .object(var fields) = payload {
                    let elapsed = startedAt.duration(to: ContinuousClock.now).components
                    fields["durationSeconds"] = .double(max(0,
                        Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
                    payload = .object(fields)
                }
                try Self.insertReceipt(db, kind: receipt.kind, payload: payload, at: now)
            }
            let deletedReceipts = try Self.pruneReceipts(
                db,
                maxReceipts: maxReceipts,
                protectedMinimums: cognitiveProtectedReceiptMinimums
            )
            if deletedNodes > 0 || deletedArtifacts > 0 || deletedReceipts > 0 {
                try Self.insertReceipt(db, kind: "prune", payload: .object([
                    "deletedNodes": .int(Int64(deletedNodes)),
                    "deletedArtifacts": .int(Int64(deletedArtifacts)),
                    "deletedReceipts": .int(Int64(deletedReceipts)),
                    "maxNodes": .int(Int64(maxNodes)),
                    "maxArtifacts": .int(Int64(maxArtifacts)),
                    "maxReceipts": .int(Int64(maxReceipts)),
                ]), at: now)
            }
        }
    }

    /// The durable forgetting epoch of `domain` (0 before its first forgetting).
    public func loadEpoch(_ domain: String) async throws -> UInt64 {
        try await dbQueue.read { db -> UInt64 in
            let value = try Int64.fetchOne(
                db, sql: "SELECT epoch FROM cognitive_epochs WHERE domain = ?", arguments: [domain])
            let epoch = value ?? 0
            guard epoch >= 0 else { throw CognitiveSQLiteCounterError.outsideStorageRange(domain) }
            return UInt64(epoch)
        }
    }

    static func sqliteCounter(_ value: UInt64, named name: String) throws -> Int64 {
        guard let stored = Int64(exactly: value) else {
            throw CognitiveSQLiteCounterError.outsideStorageRange(name)
        }
        return stored
    }

    static func bumpEpoch(_ db: Database, domain: String) throws -> UInt64 {
        let prior = try Int64.fetchOne(
            db, sql: "SELECT epoch FROM cognitive_epochs WHERE domain = ?", arguments: [domain]) ?? 0
        guard prior >= 0 else { throw CognitiveSQLiteCounterError.outsideStorageRange(domain) }
        guard prior < Int64.max else { throw CognitiveSQLiteCounterError.exhausted(domain) }
        let next = prior + 1
        try db.execute(sql: """
            INSERT INTO cognitive_epochs (domain, epoch) VALUES (?, ?)
            ON CONFLICT(domain) DO UPDATE SET epoch = excluded.epoch
            """, arguments: [domain, next])
        return UInt64(next)
    }

    public func appendReceipt(
        kind: String,
        payload: JSONValue,
        at now: Date,
        id: UUID = UUID()
    ) async throws {
        let payloadJSON = try Self.jsonString(payload)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO cognitive_receipts (id, kind, payload_json, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [id.uuidString, kind, payloadJSON, now.timeIntervalSince1970]
            )
            // Receipts live only in cognitive_receipts (10k cap). Mirroring
            // them into artifacts crowded durable state out of restoration.
        }
    }

    /// Forget her transient mind: nodes, artifacts and receipts go, and the
    /// mind's forgetting epoch moves in the SAME transaction (it lives outside
    /// what this deletes). Returns the new epoch.
    @discardableResult
    public func clear() async throws -> UInt64 {
        try await dbQueue.write { db -> UInt64 in
            try db.execute(sql: "DELETE FROM cognitive_nodes")
            try db.execute(sql: "DELETE FROM cognitive_artifacts")
            try db.execute(sql: "DELETE FROM cognitive_receipts")
            return try Self.bumpEpoch(db, domain: "mind")
        }
    }

    private struct ArtifactPruneRow {
        var id: String
        var kind: String
        var status: String
        var updatedAt: Double
    }

    /// Return exact deleted ids so family transitions can receipt lifecycle and
    /// global-cap removals separately. Rows inside each protected quota are chosen
    /// by durable status first, then newest update; unprotected rows remain the
    /// first eviction class regardless of age.
    private static func pruneArtifacts(
        _ db: Database,
        maxArtifacts: Int,
        protectedMinimums: [String: Int]
    ) throws -> [String] {
        let boundedCap = max(0, maxArtifacts)
        let exempt = cognitiveUnprunedArtifactKinds
        let exemptMarks = Array(repeating: "?", count: exempt.count).joined(separator: ",")
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM cognitive_artifacts WHERE kind NOT IN (\(exemptMarks))",
            arguments: StatementArguments(Array(exempt))
        ) ?? 0
        let overflow = count - boundedCap
        guard overflow > 0 else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, kind, status, updated_at FROM cognitive_artifacts WHERE kind NOT IN (\(exemptMarks))",
            arguments: StatementArguments(Array(exempt))
        ).compactMap { row -> ArtifactPruneRow? in
            guard let id: String = try row.decode(forColumn: "id"),
                  let kind: String = try row.decode(forColumn: "kind"),
                  let status: String = try row.decode(forColumn: "status"),
                  let updatedAt: Double = try row.decode(forColumn: "updated_at") else { return nil }
            return ArtifactPruneRow(id: id, kind: kind, status: status, updatedAt: updatedAt)
        }

        var protectedIDs: Set<String> = []
        for (kind, minimum) in protectedMinimums where minimum > 0 {
            let family = rows.filter { $0.kind == kind }.sorted(by: protectionOrder)
            protectedIDs.formUnion(family.prefix(minimum).map(\.id))
        }
        let victims = rows.sorted { lhs, rhs in
            let lhsProtected = protectedIDs.contains(lhs.id)
            let rhsProtected = protectedIDs.contains(rhs.id)
            if lhsProtected != rhsProtected { return !lhsProtected }
            let lhsDurability = artifactDurability(lhs.status)
            let rhsDurability = artifactDurability(rhs.status)
            if lhsDurability != rhsDurability { return lhsDurability < rhsDurability }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.id < rhs.id
        }.prefix(overflow).map(\.id)
        guard !victims.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: victims.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM cognitive_artifacts WHERE id IN (\(placeholders))",
            arguments: StatementArguments(victims)
        )
        return victims
    }

    private static func protectionOrder(_ lhs: ArtifactPruneRow, _ rhs: ArtifactPruneRow) -> Bool {
        let lhsDurability = artifactDurability(lhs.status)
        let rhsDurability = artifactDurability(rhs.status)
        if lhsDurability != rhsDurability { return lhsDurability > rhsDurability }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private static func artifactDurability(_ status: String) -> Int {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "current", "accepted", "approved": return 3
        case "proposed", "open", "recorded": return 2
        case "cancelled", "rejected", "retired", "resolved": return 0
        default: return 1
        }
    }

    private static func upsertArtifact(
        _ db: Database,
        artifact: CognitiveArtifactWrite,
        at now: Date
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cognitive_artifacts (
                id, kind, status, score, payload_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                status = excluded.status,
                score = excluded.score,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """,
            arguments: [
                artifact.id.uuidString,
                artifact.kind,
                artifact.status,
                (artifact.score).clamped01(),
                try jsonString(artifact.payload),
                now.timeIntervalSince1970,
                now.timeIntervalSince1970,
            ]
        )
    }

    private static func insertNode(_ db: Database, node: CognitiveNode, at now: Date) throws {
        try db.execute(
            sql: """
            INSERT INTO cognitive_nodes (
                id, kind, subject_type, subject_id, subject_label,
                activation, salience, confidence, source_class,
                created_at, last_activated_at, decay_half_life,
                summary, metadata_json, updated_at,
                emotional_valence, emotional_arousal, emotional_warmth, lived_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                node.id.uuidString,
                node.kind.rawValue,
                node.subjectReference.type,
                node.subjectReference.id,
                node.subjectReference.label,
                node.activation,
                node.salience,
                node.confidence,
                node.sourceClass.rawValue,
                node.createdAt.timeIntervalSince1970,
                node.lastActivatedAt.timeIntervalSince1970,
                node.decayHalfLife,
                node.summary,
                try jsonString(.object(node.metadata)),
                now.timeIntervalSince1970,
                node.emotionalValence,
                node.emotionalArousal,
                node.emotionalWarmth,
                node.livedSeq.map { try sqliteCounter($0, named: "node lived_seq") },
            ]
        )
    }

    private struct ReceiptPruneRow {
        var id: String
        var kind: String
        var createdAt: Double
    }

    @discardableResult
    private static func pruneReceipts(
        _ db: Database,
        maxReceipts: Int,
        protectedMinimums: [String: Int]
    ) throws -> Int {
        let cap = max(0, maxReceipts)
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_receipts") ?? 0
        guard count > cap else { return 0 }
        let slack = min(256, max(1, cap / 4))
        let targetCount = max(0, cap - slack)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, kind, created_at FROM cognitive_receipts"
        ).compactMap { row -> ReceiptPruneRow? in
            guard let id: String = try row.decode(forColumn: "id"),
                  let kind: String = try row.decode(forColumn: "kind"),
                  let createdAt: Double = try row.decode(forColumn: "created_at") else { return nil }
            return ReceiptPruneRow(id: id, kind: kind, createdAt: createdAt)
        }

        var protectedIDs: Set<String> = []
        for (kind, minimum) in protectedMinimums where minimum > 0 {
            let family = rows
                .filter { $0.kind == kind }
                .sorted(by: receiptProtectionOrder)
            protectedIDs.formUnion(family.prefix(minimum).map(\.id))
        }

        let victims = rows.sorted { lhs, rhs in
            let lhsProtected = protectedIDs.contains(lhs.id)
            let rhsProtected = protectedIDs.contains(rhs.id)
            if lhsProtected != rhsProtected { return !lhsProtected }
            let lhsPriority = receiptEvictionPriority(lhs.kind)
            let rhsPriority = receiptEvictionPriority(rhs.kind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }.prefix(max(0, count - targetCount)).map(\.id)
        guard !victims.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: victims.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM cognitive_receipts WHERE id IN (\(placeholders))",
            arguments: StatementArguments(victims)
        )
        return victims.count
    }

    private static func receiptProtectionOrder(_ lhs: ReceiptPruneRow, _ rhs: ReceiptPruneRow) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    private static func receiptEvictionPriority(_ kind: String) -> Int {
        kind == "microcycle" ? 0 : 1
    }

    private static func insertReceipt(
        _ db: Database,
        kind: String,
        payload: JSONValue,
        at now: Date
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cognitive_receipts (id, kind, payload_json, created_at)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [UUID().uuidString, kind, try jsonString(payload), now.timeIntervalSince1970]
        )
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_cognitive_substrate") { db in
            try db.execute(sql: """
                CREATE TABLE cognitive_nodes (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    subject_type TEXT NOT NULL,
                    subject_id TEXT NOT NULL,
                    subject_label TEXT,
                    activation REAL NOT NULL,
                    salience REAL NOT NULL,
                    confidence REAL NOT NULL,
                    source_class TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_activated_at REAL NOT NULL,
                    decay_half_life REAL NOT NULL,
                    summary TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX idx_cognitive_nodes_kind ON cognitive_nodes(kind);
                CREATE INDEX idx_cognitive_nodes_subject ON cognitive_nodes(subject_type, subject_id);
                CREATE INDEX idx_cognitive_nodes_salience ON cognitive_nodes(salience, activation);

                CREATE TABLE cognitive_artifacts (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    score REAL NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX idx_cognitive_artifacts_kind ON cognitive_artifacts(kind, status);
                CREATE INDEX idx_cognitive_artifacts_updated ON cognitive_artifacts(updated_at);
                """)
        }
        migrator.registerMigration("v2_cognitive_receipts_and_schema_markers") { db in
            try db.execute(sql: """
                CREATE TABLE cognitive_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX idx_cognitive_receipts_kind ON cognitive_receipts(kind, created_at);
                """)
        }
        // New emotional-tag columns default to neutral without changing existing values.
        migrator.registerMigration("v3_cognitive_node_emotional_tags") { db in
            try db.execute(sql: """
                ALTER TABLE cognitive_nodes ADD COLUMN emotional_valence REAL NOT NULL DEFAULT 0;
                ALTER TABLE cognitive_nodes ADD COLUMN emotional_arousal REAL NOT NULL DEFAULT 0;
                ALTER TABLE cognitive_nodes ADD COLUMN emotional_warmth REAL NOT NULL DEFAULT 0;
                """)
        }
        migrator.registerMigration("v4_motor_consequence_replay_guard") { db in
            try db.execute(sql: """
                CREATE TABLE cognitive_motor_consequence_admission (
                    action_key TEXT PRIMARY KEY NOT NULL,
                    semantic_fingerprint TEXT NOT NULL,
                    owner_updated_at REAL,
                    admitted_at REAL NOT NULL
                );
                CREATE INDEX idx_cognitive_motor_consequence_admitted
                    ON cognitive_motor_consequence_admission(admitted_at);
                """)
        }
        migrator.registerMigration("v5_care_folded_movement_days") { db in
            // Old folds kept no distinct-day evidence. Preserve their summary
            // and start an explicit empty witness list; the retained story still
            // counts, and future folds keep its days. Never invent lost evidence.
            for row in try Row.fetchAll(db, sql: "SELECT id, payload_json FROM cognitive_artifacts WHERE kind = 'care'") {
                let id: String = try row.decode(forColumn: "id")
                let payload: String = try row.decode(forColumn: "payload_json")
                guard case .object(var object) = try JSONValue.parse(Data(payload.utf8)),
                      case .object(var folded)? = object["folded"], folded["movedDays"] == nil else { continue }
                folded["movedDays"] = .array([])
                object["folded"] = .object(folded)
                try db.execute(sql: "UPDATE cognitive_artifacts SET payload_json = ? WHERE id = ?",
                               arguments: [try JSONValue.object(object).serialize(pretty: false), id])
            }
        }
        migrator.registerMigration("v6_retire_cognitive_experiments") { db in
            // These count-based ratings never measured a cognitive outcome.
            // Retire only their artifacts; living state and receipts keep their format.
            try db.execute(sql: "DELETE FROM cognitive_artifacts WHERE kind = 'experiment'")
        }
        migrator.registerMigration("v7_forgetting_epochs") { db in
            // One durable forgetting boundary per domain, kept OUTSIDE what
            // `clear()` deletes: a moment admitted under an older epoch of a
            // domain is refused by that domain's parts. An older binary ignores
            // this table (GRDB skips unknown applied migrations).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cognitive_epochs (
                    domain TEXT PRIMARY KEY NOT NULL,
                    epoch INTEGER NOT NULL
                )
                """)
        }
        registerLivedMomentsMigration(&migrator)
        return migrator
    }

    private static func motorOwnerTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    static func jsonString(_ value: JSONValue) throws -> String {
        try value.serialize(pretty: false)
    }


}
