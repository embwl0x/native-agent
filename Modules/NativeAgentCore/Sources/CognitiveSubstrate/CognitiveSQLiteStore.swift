import Foundation
import GRDB
import PersistenceCore

public struct CognitiveSQLitePruneResult: Sendable, Equatable {
    public var deletedNodes: Int
    public var deletedArtifacts: Int
    /// Receipts trimmed beyond the retention cap (additive, 2026-07-02 — the
    /// append-only receipt log was the one unbounded table; User: "we have to
    /// make sure [it] doesnt wind up becoming a huge pile").
    public var deletedReceipts: Int

    public init(deletedNodes: Int, deletedArtifacts: Int, deletedReceipts: Int = 0) {
        self.deletedNodes = max(0, deletedNodes)
        self.deletedArtifacts = max(0, deletedArtifacts)
        self.deletedReceipts = max(0, deletedReceipts)
    }
}

struct CognitiveArtifactReplacement: Sendable, Equatable {
    var id: UUID
    var status: String
    var score: Double
    var payload: JSONValue
}

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
}

/// Minimum newest rows retained from each live artifact family before generic
/// age-based pruning may spend that family. The totals fit beneath the default
/// artifact cap; if a caller supplies a smaller cap, the hard cap still wins
/// deterministically after every unprotected row has been spent.
private let cognitiveProtectedArtifactMinimums: [String: Int] = [
    "affect": 1,
    "disposition": 1,
    "emotional_consolidation": 1,
    "thought_seed": 128,
    "episode": 64,
    "schema_proposal": 64,
    "standing_view": 60,
    "identity_proposal": 32,
    "developmental_timeline": 128,
    "reflection_receipt": 32,
    "experiment": 20,
]

struct CognitiveArtifactFamilyLoad: Sendable, Equatable {
    var key: String
    var kindPrefix: String
    var limit: Int
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

public actor CognitiveSQLiteStore {
    private static let maximumMotorConsequenceAdmissions = 4_096
    public let databaseURL: URL
    private let dbQueue: DatabaseQueue

    public init(dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.databaseURL = dir.appendingPathComponent("cognition.sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
        try Self.drainRetiredCognitionArtifacts(dbQueue)
    }

    /// One-way drain of retired cognition machinery. Runs unconditionally at
    /// store open; because no live path writes these kinds or cue metadata any
    /// longer, subsequent opens are idempotent no-ops.
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
            // Legacy neglected-commitment THOUGHT SEEDS live under kind
            // 'thought_seed' with the seed's own kind inside payload_json.
            // Their enum case is removed, so restore already skips them — but
            // restoreThoughtSeeds loads a bounded newest-N slice, and dead rows
            // left in place would crowd surviving reflection-takeaway seeds out
            // of that window on legacy DBs (review finding 2026-07-01).
            try db.execute(sql: """
                DELETE FROM cognitive_artifacts
                WHERE kind = 'thought_seed'
                  AND json_extract(payload_json, '$.kind') = 'neglectedCommitment'
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

    public func saveNodes(_ nodes: [CognitiveNode], at now: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cognitive_nodes")
            for node in nodes {
                try Self.insertNode(db, node: node, at: now)
            }
        }
    }

    public func loadNodes() async throws -> [CognitiveNode] {
        try await dbQueue.read { db in
            try Self.fetchNodesWithDecayAnchors(db).nodes
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
                let existingFingerprint: String = existing["semantic_fingerprint"]
                if existingFingerprint == fingerprint { return false }
                let existingOwnerUpdatedAt: Double? = existing["owner_updated_at"]
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

    func loadRestoreBundle(
        artifactFamilies: [CognitiveArtifactFamilyLoad]
    ) async throws -> CognitiveSQLiteRestoreBundle {
        try await dbQueue.read { db in
            var artifacts: [String: [JSONValue]] = [:]
            for family in artifactFamilies {
                artifacts[family.key] = try Self.fetchArtifacts(
                    db,
                    kindPrefix: family.kindPrefix,
                    limit: family.limit,
                    requireObjectPayload: true
                )
            }
            let restoredNodes = try Self.fetchNodesWithDecayAnchors(db)
            return CognitiveSQLiteRestoreBundle(
                nodes: restoredNodes.nodes,
                nodeDecayAnchors: restoredNodes.decayAnchors,
                artifacts: artifacts
            )
        }
    }

    public func upsertArtifact(
        kind: String,
        id: UUID,
        status: String,
        score: Double,
        payload: JSONValue,
        at now: Date
    ) async throws {
        try await dbQueue.write { db in
            try Self.upsertArtifact(
                db,
                artifact: CognitiveArtifactWrite(
                    kind: kind,
                    id: id,
                    status: status,
                    score: score,
                    payload: payload
                ),
                at: now
            )
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
                        Self.jsonString(artifact.payload),
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                    ]
                )
            }
            if let receiptPayload {
                try db.execute(
                    sql: """
                    INSERT INTO cognitive_receipts (id, kind, payload_json, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        "replay.integration",
                        Self.jsonString(receiptPayload),
                        now.timeIntervalSince1970,
                    ]
                )
            }
            _ = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            )
            let receiptCap = max(0, maxReceipts)
            let receiptCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM cognitive_receipts"
            ) ?? 0
            if receiptCount > receiptCap {
                let slack = min(256, max(1, receiptCap / 4))
                try db.execute(
                    sql: """
                    DELETE FROM cognitive_receipts
                    WHERE id IN (
                        SELECT id FROM cognitive_receipts
                        ORDER BY created_at ASC, id ASC
                        LIMIT MAX((SELECT COUNT(*) FROM cognitive_receipts) - ?, 0)
                    )
                    """,
                    arguments: [max(0, receiptCap - slack)]
                )
            }
        }
    }

    /// Commit one complete cognition-maintenance transition. Thought-seed
    /// decay, affect/ambient settlement, emotional consolidation, stale-view
    /// retirement, the exact node snapshot, and their receipts either all
    /// become durable or none do. This deliberately remains inside the one
    /// canonical cognition store; maintenance does not gain a second ledger.
    func commitMaintenance(
        nodes: [CognitiveNode],
        thoughtSeeds: [CognitiveArtifactReplacement]?,
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

            if let thoughtSeeds {
                try db.execute(
                    sql: "DELETE FROM cognitive_artifacts WHERE kind = ?",
                    arguments: ["thought_seed"]
                )
                for record in thoughtSeeds {
                    try Self.insertArtifact(
                        db,
                        kind: "thought_seed",
                        id: record.id,
                        status: record.status,
                        score: record.score,
                        payload: record.payload,
                        at: now
                    )
                }
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
            _ = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            )
            for receipt in receipts {
                try Self.insertReceipt(db, kind: receipt.kind, payload: receipt.payload, at: now)
            }
            try Self.pruneReceipts(db, maxReceipts: maxReceipts)
        }
    }

    /// Atomically replace one complete in-memory artifact family and enforce the
    /// global retention policy before commit. This is the persistence boundary
    /// for lifecycle-managed families such as thought seeds: decay, cap eviction,
    /// score updates, stale-row deletion, and protected-family pruning become one
    /// durable transition, so a restart cannot resurrect rows removed in memory.
    func replaceArtifactFamily(
        kind: String,
        records: [CognitiveArtifactReplacement],
        at now: Date,
        maxArtifacts: Int
    ) async throws {
        try await dbQueue.write { db in
            let oldIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT id FROM cognitive_artifacts WHERE kind = ?",
                arguments: [kind]
            ))
            try db.execute(
                sql: "DELETE FROM cognitive_artifacts WHERE kind = ?",
                arguments: [kind]
            )
            for record in records {
                try Self.insertArtifact(
                    db,
                    kind: kind,
                    id: record.id,
                    status: record.status,
                    score: record.score,
                    payload: record.payload,
                    at: now
                )
            }
            let globallyEvicted = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            )
            let newIDs = Set(records.map { $0.id.uuidString })
            let lifecycleRemoved = oldIDs.subtracting(newIDs)
            if !lifecycleRemoved.isEmpty || !globallyEvicted.isEmpty {
                let payload: JSONValue = .object([
                    "family": .string(kind),
                    "familyRowCount": .int(Int64(records.count)),
                    "lifecycleRemoved": .int(Int64(lifecycleRemoved.count)),
                    "globallyEvicted": .int(Int64(globallyEvicted.count)),
                    "maxArtifacts": .int(Int64(maxArtifacts)),
                ])
                try Self.insertReceipt(
                    db,
                    kind: "artifact.family_transition",
                    payload: payload,
                    at: now
                )
            }
        }
    }

    /// Delete a single artifact row by id. Additive API (Wave E): retired standing views
    /// remove their artifact instead of upserting status=retired — their audit trail lives
    /// in the developmental timeline — so bounded restores (`loadArtifacts(limit:)`, ordered
    /// by updated_at DESC) can never be crowded out by retired history, and the global
    /// prune can never evict a long-lived ACTIVE view in favor of newer retired rows
    /// (gpt-5.5 review, 2026-07-02).
    public func deleteArtifact(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM cognitive_artifacts WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    public func appendReceipt(kind: String, payload: JSONValue, at now: Date) async throws {
        let id = UUID()
        let payloadJSON = Self.jsonString(payload)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO cognitive_receipts (id, kind, payload_json, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [id.uuidString, kind, payloadJSON, now.timeIntervalSince1970]
            )
            // R2-C (2026-07-09): receipts are NO LONGER mirrored into
            // cognitive_artifacts. Nothing ever read the "receipt.<kind>" mirror,
            // and high-frequency kinds (cognition.resource_skip fired hundreds of
            // times/week) flooded the ~516-row artifact cap; the kind-blind prune
            // then evicted the RARE artifacts — standing views, schema proposals,
            // thought seeds, episodes, identity/timeline — which is what
            // restorePersistentState restores from. Net effect in the wild: her
            // durable inner life was amputated to skip-noise on every prune cycle
            // (live store 2026-07-09: 510/516 artifacts were receipt mirrors; zero
            // views/seeds/episodes survived). Receipts live in cognitive_receipts
            // (10k cap) — the one copy is the right copy.
        }
    }

    public func loadArtifacts(kindPrefix: String? = nil, limit: Int = 100) async throws -> [JSONValue] {
        try await dbQueue.read { db in
            try Self.fetchArtifacts(
                db,
                kindPrefix: kindPrefix,
                limit: limit,
                requireObjectPayload: false
            )
        }
    }

    public func loadReceipts(kindPrefix: String? = nil, limit: Int = 100) async throws -> [JSONValue] {
        try await dbQueue.read { db in
            let bounded = max(0, min(limit, 500))
            let rows: [Row]
            if let kindPrefix {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT payload_json FROM cognitive_receipts
                    WHERE kind LIKE ?
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: ["\(kindPrefix)%", bounded]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT payload_json FROM cognitive_receipts
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: [bounded]
                )
            }
            return rows.compactMap { row in
                guard let raw: String = row["payload_json"] else { return nil }
                return Self.parseJSON(raw)
            }
        }
    }

    public func loadReceiptRecords(kindPrefix: String? = nil, limit: Int = 100) async throws -> [CognitiveReceiptRecord] {
        try await dbQueue.read { db in
            let bounded = max(0, min(limit, 500))
            let rows: [Row]
            if let kindPrefix {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, kind, payload_json, created_at FROM cognitive_receipts
                    WHERE kind LIKE ?
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: ["\(kindPrefix)%", bounded]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, kind, payload_json, created_at FROM cognitive_receipts
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: [bounded]
                )
            }
            return rows.compactMap { row in
                guard let rawId: String = row["id"],
                      let id = UUID(uuidString: rawId),
                      let kind: String = row["kind"],
                      let rawPayload: String = row["payload_json"],
                      let createdAt: Double = row["created_at"] else {
                    return nil
                }
                return CognitiveReceiptRecord(
                    id: id,
                    kind: kind,
                    payload: Self.parseJSON(rawPayload),
                    createdAt: Date(timeIntervalSince1970: createdAt)
                )
            }
        }
    }

    public func schemaMarkers() async throws -> [String: String] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name, value FROM cognitive_schema_markers")
            var out: [String: String] = [:]
            for row in rows {
                if let name: String = row["name"], let value: String = row["value"] {
                    out[name] = value
                }
            }
            return out
        }
    }

    @discardableResult
    /// `maxReceipts` (additive, default 10_000): the receipts table is an append-only
    /// audit log written on every loop tick (~900/day live) and was the ONE unbounded
    /// table in the store — nodes cap at 256 and artifacts at artifactCap, but receipts
    /// grew forever (8.6k rows in 3 weeks when caught). Consumers only ever read the
    /// newest ≤100, so trimming to the newest 10k (~10 days of history) is invisible
    /// to every surface while making the whole store bounded (User, 2026-07-02: "make
    /// sure [it] doesnt wind up becoming a huge pile of saved memories and files").
    public func prune(maxNodes: Int, maxArtifacts: Int, maxReceipts: Int = 10_000) async throws -> CognitiveSQLitePruneResult {
        try await dbQueue.write { db in
            let nodesBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_nodes") ?? 0
            let artifactsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_artifacts") ?? 0
            let receiptsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_receipts") ?? 0
            try db.execute(
                sql: """
                DELETE FROM cognitive_nodes
                WHERE id IN (
                    SELECT id FROM cognitive_nodes
                    ORDER BY salience ASC, activation ASC, last_activated_at ASC, id ASC
                    LIMIT MAX((SELECT COUNT(*) FROM cognitive_nodes) - ?, 0)
                )
                """,
                arguments: [max(1, maxNodes)]
            )
            // Keep the explicit operator prune defensive against a legacy or
            // externally restored database that acquired mirror rows after
            // this store instance opened. The hot microcycle and artifact-
            // family transitions rely on the one-time open drain instead.
            try db.execute(sql: "DELETE FROM cognitive_artifacts WHERE kind LIKE 'receipt.%'")
            _ = try Self.pruneArtifacts(
                db,
                maxArtifacts: maxArtifacts,
                protectedMinimums: cognitiveProtectedArtifactMinimums
            )
            // Hysteresis: only trim once the table EXCEEDS the cap, and then cut to
            // cap − slack — otherwise the prune receipt inserted below (plus the
            // caller's own functional receipt) would leave the table at cap+1 and
            // every subsequent prune would churn a delete + a "prune" receipt into
            // the recent-receipts view (gpt-5.5 review, 2026-07-02). With slack,
            // trimming fires a few times a day instead of every persist.
            let receiptCap = max(0, maxReceipts)
            let receiptSlack = min(256, max(1, receiptCap / 4))
            if receiptsBefore > receiptCap {
                try db.execute(
                    sql: """
                    DELETE FROM cognitive_receipts
                    WHERE id IN (
                        SELECT id FROM cognitive_receipts
                        ORDER BY created_at ASC, id ASC
                        LIMIT MAX((SELECT COUNT(*) FROM cognitive_receipts) - ?, 0)
                    )
                    """,
                    arguments: [max(0, receiptCap - receiptSlack)]
                )
            }
            let nodesAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_nodes") ?? 0
            let artifactsAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_artifacts") ?? 0
            let receiptsAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_receipts") ?? 0
            let result = CognitiveSQLitePruneResult(
                deletedNodes: nodesBefore - nodesAfter,
                deletedArtifacts: artifactsBefore - artifactsAfter,
                deletedReceipts: receiptsBefore - receiptsAfter
            )
            if result.deletedNodes > 0 || result.deletedArtifacts > 0 || result.deletedReceipts > 0 {
                let payload: JSONValue = .object([
                    "deletedNodes": .int(Int64(result.deletedNodes)),
                    "deletedArtifacts": .int(Int64(result.deletedArtifacts)),
                    "deletedReceipts": .int(Int64(result.deletedReceipts)),
                    "maxNodes": .int(Int64(maxNodes)),
                    "maxArtifacts": .int(Int64(maxArtifacts)),
                    "maxReceipts": .int(Int64(maxReceipts)),
                ])
                let id = UUID()
                let payloadJSON = Self.jsonString(payload)
                let now = Date().timeIntervalSince1970
                try db.execute(
                    sql: """
                    INSERT INTO cognitive_receipts (id, kind, payload_json, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [id.uuidString, "prune", payloadJSON, now]
                )
            }
            return result
        }
    }

    public func clear() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cognitive_nodes")
            try db.execute(sql: "DELETE FROM cognitive_artifacts")
            try db.execute(sql: "DELETE FROM cognitive_receipts")
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
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM cognitive_artifacts"
        ) ?? 0
        let overflow = count - boundedCap
        guard overflow > 0 else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, kind, status, updated_at FROM cognitive_artifacts"
        ).compactMap { row -> ArtifactPruneRow? in
            guard let id: String = row["id"],
                  let kind: String = row["kind"],
                  let status: String = row["status"],
                  let updatedAt: Double = row["updated_at"] else { return nil }
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

    private static func insertArtifact(
        _ db: Database,
        kind: String,
        id: UUID,
        status: String,
        score: Double,
        payload: JSONValue,
        at now: Date
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cognitive_artifacts (
                id, kind, status, score, payload_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id.uuidString,
                kind,
                status,
                (score).clamped01(),
                jsonString(payload),
                now.timeIntervalSince1970,
                now.timeIntervalSince1970,
            ]
        )
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
                jsonString(artifact.payload),
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
                emotional_valence, emotional_arousal, emotional_warmth
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                jsonString(.object(node.metadata)),
                now.timeIntervalSince1970,
                node.emotionalValence,
                node.emotionalArousal,
                node.emotionalWarmth,
            ]
        )
    }

    private static func pruneReceipts(_ db: Database, maxReceipts: Int) throws {
        let cap = max(0, maxReceipts)
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cognitive_receipts") ?? 0
        guard count > cap else { return }
        let slack = min(256, max(1, cap / 4))
        try db.execute(
            sql: """
            DELETE FROM cognitive_receipts
            WHERE id IN (
                SELECT id FROM cognitive_receipts
                ORDER BY created_at ASC, id ASC
                LIMIT MAX((SELECT COUNT(*) FROM cognitive_receipts) - ?, 0)
            )
            """,
            arguments: [max(0, cap - slack)]
        )
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
            arguments: [UUID().uuidString, kind, jsonString(payload), now.timeIntervalSince1970]
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

                CREATE TABLE cognitive_schema_markers (
                    name TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                INSERT INTO cognitive_schema_markers (name, value)
                VALUES ('schema_version', '2');
                """)
        }
        // Wave A: per-node emotional tag. Purely ADDITIVE — three REAL columns with a
        // NOT NULL DEFAULT 0 (the neutral tag), so an existing DB from v1/v2 opens clean
        // and every pre-tag node loads as neutral. This ALTER-ADD-COLUMN path is the
        // migration-safety crux; nothing here touches existing rows or wire strings.
        // GRDB's own grdb_migrations table gates which migrations have run; the
        // cognitive_schema_markers 'schema_version' row is separate app bookkeeping and is
        // left untouched here (no reader keys off it), so this migration stays purely additive.
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
        return migrator
    }

    private static func motorOwnerTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func fetchNodesWithDecayAnchors(
        _ db: Database
    ) throws -> (nodes: [CognitiveNode], decayAnchors: [UUID: Date]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, kind, subject_type, subject_id, subject_label,
                   activation, salience, confidence, source_class,
                   created_at, last_activated_at, decay_half_life,
                   summary, metadata_json, updated_at,
                   emotional_valence, emotional_arousal, emotional_warmth
            FROM cognitive_nodes
            ORDER BY salience DESC, activation DESC, last_activated_at DESC, id ASC
            """
        )
        var nodes: [CognitiveNode] = []
        var decayAnchors: [UUID: Date] = [:]
        nodes.reserveCapacity(rows.count)
        decayAnchors.reserveCapacity(rows.count)
        for row in rows {
            let node = try node(from: row)
            guard let updatedAt: Double = row["updated_at"], updatedAt.isFinite else {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_nodes",
                    id: node.id.uuidString,
                    detail: "updated_at is missing or nonfinite"
                )
            }
            nodes.append(node)
            decayAnchors[node.id] = Date(timeIntervalSince1970: updatedAt)
        }
        return (nodes, decayAnchors)
    }

    private static func fetchArtifacts(
        _ db: Database,
        kindPrefix: String?,
        limit: Int,
        requireObjectPayload: Bool
    ) throws -> [JSONValue] {
        let bounded = max(0, min(limit, 500))
        let rows: [Row]
        if let kindPrefix {
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, payload_json FROM cognitive_artifacts
                WHERE kind LIKE ?
                ORDER BY updated_at DESC, id ASC
                LIMIT ?
                """,
                arguments: ["\(kindPrefix)%", bounded]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, payload_json FROM cognitive_artifacts
                ORDER BY updated_at DESC, id ASC
                LIMIT ?
                """,
                arguments: [bounded]
            )
        }
        return try rows.map { row in
            let id: String = row["id"] ?? "<unknown>"
            guard let raw: String = row["payload_json"] else {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_artifacts",
                    id: id,
                    detail: "payload_json is missing"
                )
            }
            let payload: JSONValue
            do {
                payload = try parseJSONStrict(raw)
            } catch {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_artifacts",
                    id: id,
                    detail: "payload_json is not valid JSON"
                )
            }
            if requireObjectPayload, case .object = payload {
                return payload
            }
            if requireObjectPayload {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_artifacts",
                    id: id,
                    detail: "payload_json is not an object"
                )
            }
            return payload
        }
    }

    private static func node(from row: Row) throws -> CognitiveNode {
        let rowID: String = row["id"] ?? "<unknown>"
        guard let idRaw: String = row["id"],
              let id = UUID(uuidString: idRaw),
              let kindRaw: String = row["kind"],
              let kind = CognitiveNodeKind(rawValue: kindRaw),
              let type: String = row["subject_type"],
              let subjectId: String = row["subject_id"],
              let sourceRaw: String = row["source_class"],
              let source = CognitiveSourceClass(rawValue: sourceRaw),
              let activation: Double = row["activation"],
              let salience: Double = row["salience"],
              let confidence: Double = row["confidence"],
              let createdAt: Double = row["created_at"],
              let lastActivatedAt: Double = row["last_activated_at"],
              let decayHalfLife: Double = row["decay_half_life"],
              let summary: String = row["summary"],
              let metadataRaw: String = row["metadata_json"],
              let emotionalValence: Double = row["emotional_valence"],
              let emotionalArousal: Double = row["emotional_arousal"],
              let emotionalWarmth: Double = row["emotional_warmth"] else {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes",
                id: rowID,
                detail: "one or more required fields are invalid"
            )
        }
        let metadataPayload: JSONValue
        do {
            metadataPayload = try parseJSONStrict(metadataRaw)
        } catch {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes",
                id: rowID,
                detail: "metadata_json is not valid JSON"
            )
        }
        guard case .object(let metadata) = metadataPayload else {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes",
                id: rowID,
                detail: "metadata_json is not an object"
            )
        }
        return CognitiveNode(
            id: id,
            kind: kind,
            subjectReference: CognitiveSubjectReference(
                type: type,
                id: subjectId,
                label: row["subject_label"]
            ),
            activation: activation,
            salience: salience,
            confidence: confidence,
            sourceClass: source,
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastActivatedAt: Date(timeIntervalSince1970: lastActivatedAt),
            decayHalfLife: decayHalfLife,
            summary: summary,
            metadata: metadata,
            emotionalValence: emotionalValence,
            emotionalArousal: emotionalArousal,
            emotionalWarmth: emotionalWarmth
        )
    }

    static func jsonString(_ value: JSONValue) -> String {
        (try? value.serialize(pretty: false)) ?? "null"
    }

    static func parseJSON(_ raw: String) -> JSONValue {
        (try? JSONValue.parse(Data(raw.utf8))) ?? .null
    }

    private static func parseJSONStrict(_ raw: String) throws -> JSONValue {
        try JSONValue.parse(Data(raw.utf8))
    }
}
