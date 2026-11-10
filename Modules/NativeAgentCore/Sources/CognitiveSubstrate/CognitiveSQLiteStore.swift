import NativeAgentCore
import Foundation
import NativeAgentShared
import GRDB
import PersistenceCore
// Blueprint: | `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore`, `backupForDoctor`, `commitMaintenance`: checked storage |

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
    /// Measure execution at receipt insertion, not at later observation.
    var startedAt: ContinuousClock.Instant? = nil
}

/// Cares are uncapped living state; the night fades unused cares and seeds remain. Owed reflections stay outside history pruning until settlement.
private let cognitiveUnprunedArtifactKinds: Set<String> = [
    "care", "care_migration", "care_retired_migration", "standing_view", "thought_seed", "attention_landing",
]

// Retention floors only order eviction; spend protected rows when necessary to enforce the hard cap.
private let cognitiveProtectedArtifactMinimums: [String: Int] = [
    "affect": 32,
    // One row, rewritten in place: the capsule cadence ledger. Tiny, but losing it re-opens a suppressed nag on the next relaunch.
    "capsule_presentation": 1,
    // One row: 48 rejections and one disposition undo; the agent's corrections survive pruning.
    "mind_ledger": 1,
    "disposition": 32,
    "emotional_consolidation": 32,
    "episode": 64,
    "schema_proposal": 64,
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
    // Pending reconciliation is unfinished work; pruning it would discard replay evidence before integration.
    "replay.reconciliation_pending": 32,
    "workshop.pursuit_proposed": 32,
    "workshop.pursuit_proposal_refused": 32,
]

struct CognitiveArtifactFamilyLoad: Sendable, Equatable {
    var key: String
    var kindPrefix: String
    var limit: Int
    /// Every row of exactly this kind, not a prefix and not capped: `care` must not also load `care_migration`, and cares have no count cap.
    var whole = false
}

struct CognitiveSQLiteRestoreBundle: Sendable, Equatable {
    var nodes: [CognitiveNode]
    /// Exact persistence checkpoints for the already-decayed node values. Keyed by stable node ID so ContinuityField can rebuild its private index.
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
        let newStore: Bool
        do {
            _ = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            newStore = false
        } catch CocoaError.fileReadNoSuchFile { newStore = true }
        var config = Configuration()
        // The queue serializes its writer; another owner's lock is an actual contention error.
        config.busyMode = .immediateError
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Self.migrator(newStore: newStore).migrate(dbQueue)
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

    /// Durable, payload-free replay guard for canonical motor projections. Domain owners remain authoritative; this table only prevents an older, duplicate, or
    /// equal-time contradictory projection from re-entering resident physiology after a relaunch.
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
                // Without a strictly newer canonical owner timestamp, a contradiction is ambiguous and therefore cannot affect the resident body. Exact later
                // corrections remain admissible.
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

    /// Commit one replay integration as a single SQLite transition. Episodes, schema changes, timeline lineage, and the correlated receipt either all become
    /// durable or none do; evidence is never permanently consumed by a partial sequence of best-effort artifact writes.
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

    /// Commit one complete cognition-maintenance transition. Affect, consumed residue, emotional consolidation, the exact node snapshot, and their receipts all
    /// become durable or none do. This deliberately remains inside the one canonical cognition store; maintenance does not gain a second ledger.
    func commitMaintenance(
        nodes: [CognitiveNode],
        artifacts: [CognitiveArtifactWrite],
        deletedArtifactIDs: [UUID],
        receipts: [CognitiveReceiptWrite],
        maxArtifacts: Int,
        maxReceipts: Int = 10_000,
        at now: Date
    ) async throws {
        try await dbQueue.write { db in
            let ids = nodes.map { $0.id.uuidString }
            if ids.isEmpty {
                try db.execute(sql: "DELETE FROM cognitive_nodes")
            } else {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM cognitive_nodes WHERE id NOT IN (\(placeholders))", arguments: StatementArguments(ids))
            }
            for node in nodes {
                try Self.upsertNode(db, node: node, at: now)
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

            let deletedArtifacts = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            ).count
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
            if deletedArtifacts > 0 || deletedReceipts > 0 {
                try Self.insertReceipt(db, kind: "prune", payload: .object([
                    "deletedArtifacts": .int(Int64(deletedArtifacts)),
                    "deletedReceipts": .int(Int64(deletedReceipts)),
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
            // Receipts belong only in cognitive_receipts; artifact capacity must remain available to durable state.
        }
    }

    /// Forget the agent's transient mind: nodes, artifacts and receipts go, and the mind's forgetting epoch moves in the SAME transaction (it lives outside
    /// what this deletes). Returns the new epoch.
    @discardableResult
    public func clear(at: Date) async throws -> UInt64 {
        try await dbQueue.write { db -> UInt64 in
            try db.execute(sql: "DELETE FROM cognitive_nodes")
            try db.execute(sql: "DELETE FROM cognitive_artifacts")
            try db.execute(sql: "DELETE FROM cognitive_receipts")
            // When this forgetting happened, beside its epoch: words said before it belong to the mind that is gone.
            try db.execute(sql: """
                INSERT INTO cognitive_epochs (domain, epoch) VALUES (?, ?)
                ON CONFLICT(domain) DO UPDATE SET epoch = excluded.epoch
                """, arguments: [Self.mindClearedDomain, Int64(at.timeIntervalSince1970 * 1000)])
            return try Self.bumpEpoch(db, domain: "mind")
        }
    }

    static let mindClearedDomain = "mind.cleared_ms"

    /// When the mind was last forgotten; the distant past before its first forgetting.
    public func loadMindClearedAt() async throws -> Date {
        let ms = try await loadEpoch(Self.mindClearedDomain)
        return ms == 0 ? .distantPast : Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private struct ArtifactPruneRow {
        var id: String
        var kind: String
        var status: String
        var updatedAt: Double
    }

    /// Return exact deleted ids so family transitions can receipt lifecycle and global-cap removals separately. Rows inside each protected quota are chosen by
    /// durable status first, then newest update; unprotected rows remain the first eviction class regardless of age.
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
            sql: "SELECT COUNT(*) FROM cognitive_artifacts WHERE kind NOT IN (\(exemptMarks)) AND NOT (kind = 'reflection_receipt' AND status = 'owed')",
            arguments: StatementArguments(Array(exempt))
        ) ?? 0
        let overflow = count - boundedCap
        guard overflow > 0 else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, status, updated_at FROM cognitive_artifacts WHERE kind NOT IN (\(exemptMarks)) AND NOT (kind = 'reflection_receipt' AND \
                status = 'owed')
                """,
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
        // An empty attention journal removes only its existing marker; ordinary snapshots never create empty journal rows.
        if artifact.kind == "attention_landing", artifact.payload.objectValue?["pending"] == .null {
            guard try String.fetchOne(db, sql: "SELECT id FROM cognitive_artifacts WHERE id = ? AND kind = ?",
                                     arguments: [artifact.id.uuidString, artifact.kind]) != nil else { return }
            try db.execute(sql: "DELETE FROM cognitive_artifacts WHERE id = ? AND kind = ?",
                           arguments: [artifact.id.uuidString, artifact.kind])
            return
        }
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
            WHERE cognitive_artifacts.kind <> excluded.kind OR cognitive_artifacts.status <> excluded.status
               OR cognitive_artifacts.score <> excluded.score OR cognitive_artifacts.payload_json <> excluded.payload_json
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

    private static func upsertNode(_ db: Database, node: CognitiveNode, at now: Date) throws {
        guard node.drive.isFinite, node.drive >= 0 else {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes", id: node.id.uuidString, detail: "drive must be finite and nonnegative"
            )
        }
        try db.execute(
            sql: """
            INSERT INTO cognitive_nodes (
                id, kind, subject_type, subject_id, subject_label,
                activation, salience, confidence, source_class,
                created_at, last_activated_at, decay_half_life,
                summary, metadata_json, updated_at,
                emotional_valence, emotional_arousal, emotional_warmth, lived_seq, drive
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, subject_type = excluded.subject_type, subject_id = excluded.subject_id,
                subject_label = excluded.subject_label, activation = excluded.activation, salience = excluded.salience,
                confidence = excluded.confidence, source_class = excluded.source_class, created_at = excluded.created_at,
                last_activated_at = excluded.last_activated_at, decay_half_life = excluded.decay_half_life,
                summary = excluded.summary, metadata_json = excluded.metadata_json, updated_at = excluded.updated_at,
                emotional_valence = excluded.emotional_valence, emotional_arousal = excluded.emotional_arousal,
                emotional_warmth = excluded.emotional_warmth, lived_seq = excluded.lived_seq, drive = excluded.drive
            WHERE cognitive_nodes.kind IS NOT excluded.kind OR cognitive_nodes.subject_type IS NOT excluded.subject_type
               OR cognitive_nodes.subject_id IS NOT excluded.subject_id OR cognitive_nodes.subject_label IS NOT excluded.subject_label
               OR cognitive_nodes.activation IS NOT excluded.activation OR cognitive_nodes.salience IS NOT excluded.salience
               OR cognitive_nodes.confidence IS NOT excluded.confidence OR cognitive_nodes.source_class IS NOT excluded.source_class
               OR cognitive_nodes.created_at IS NOT excluded.created_at OR cognitive_nodes.last_activated_at IS NOT excluded.last_activated_at
               OR cognitive_nodes.decay_half_life IS NOT excluded.decay_half_life OR cognitive_nodes.summary IS NOT excluded.summary
               OR cognitive_nodes.metadata_json IS NOT excluded.metadata_json OR cognitive_nodes.emotional_valence IS NOT excluded.emotional_valence
               OR cognitive_nodes.emotional_arousal IS NOT excluded.emotional_arousal OR cognitive_nodes.emotional_warmth IS NOT excluded.emotional_warmth
               OR cognitive_nodes.lived_seq IS NOT excluded.lived_seq OR cognitive_nodes.drive IS NOT excluded.drive
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
                node.drive,
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

    private static func migrator(newStore: Bool) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("current_cognitive_schema") { db in
            let tables = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN \
                ('cognitive_nodes','cognitive_artifacts','cognitive_receipts','cognitive_motor_consequence_admission','cognitive_epochs','lived_moments')
                """) ?? 0
            if tables > 0 {
                guard tables == 6 else { throw CognitivePersistenceError.storeUnavailable }
                _ = try Row.fetchAll(db, sql: """
                    SELECT id, kind, subject_type, subject_id, subject_label, activation, salience, confidence, source_class, created_at, last_activated_at, \
                    decay_half_life, summary, metadata_json, updated_at, emotional_valence, emotional_arousal, emotional_warmth, lived_seq, drive FROM \
                    cognitive_nodes LIMIT 0
                    """)
                _ = try Row.fetchAll(db, sql: "SELECT id, kind, status, score, payload_json, created_at, updated_at FROM cognitive_artifacts LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT id, kind, payload_json, created_at FROM cognitive_receipts LIMIT 0")
                _ = try Row.fetchAll(db, sql: """
                    SELECT action_key, semantic_fingerprint, owner_updated_at, admitted_at FROM cognitive_motor_consequence_admission LIMIT 0
                    """)
                _ = try Row.fetchAll(db, sql: "SELECT domain, epoch FROM cognitive_epochs LIMIT 0")
                _ = try Row.fetchAll(db, sql: """
                    SELECT id, life, kind, lived_at, accepted_at, state, fold_seq, mind_epoch, body_epoch, input_json, meaning_json, parts_json, reason, \
                    updated_at FROM lived_moments LIMIT 0
                    """)
                return
            }
            guard newStore else { throw CognitivePersistenceError.storeUnavailable }
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
                    updated_at REAL NOT NULL,
                    emotional_valence REAL NOT NULL DEFAULT 0,
                    emotional_arousal REAL NOT NULL DEFAULT 0,
                    emotional_warmth REAL NOT NULL DEFAULT 0,
                    lived_seq INTEGER,
                    drive REAL NOT NULL DEFAULT 0
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


                CREATE TABLE cognitive_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX idx_cognitive_receipts_kind ON cognitive_receipts(kind, created_at);


                CREATE TABLE cognitive_motor_consequence_admission (
                    action_key TEXT PRIMARY KEY NOT NULL,
                    semantic_fingerprint TEXT NOT NULL,
                    owner_updated_at REAL,
                    admitted_at REAL NOT NULL
                );
                CREATE INDEX idx_cognitive_motor_consequence_admitted
                    ON cognitive_motor_consequence_admission(admitted_at);


                CREATE TABLE IF NOT EXISTS cognitive_epochs (
                    domain TEXT PRIMARY KEY NOT NULL,
                    epoch INTEGER NOT NULL
                )

                """)
            try createLivedMomentsSchema(db)
        }
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
