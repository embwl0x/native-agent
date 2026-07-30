import Foundation
import Testing
import PersistenceCore
import GRDB
@testable import CognitiveSubstrate

// Wave A — per-node emotional tagging. Proves a node carries a persistent feeling
// stamped from Agent's live affect at encode, blended ASYMMETRICALLY on re-activation,
// and that the tag round-trips through the store while old (pre-tag) DBs still open clean.
@Suite("EmotionalTagging")
struct EmotionalTaggingTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private func substrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, affectEnabled: true, maximumActiveNodes: 256, defaultDecayHalfLife: 100
            ),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: nil
        )
    }

    private func affectEvent(_ kind: CognitiveEventKind, _ summary: String, at: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: "affect-\(kind)-\(summary.hashValue)-\(at.timeIntervalSince1970)",
            kind: kind,
            subject: CognitiveSubjectReference(type: "chat", id: "user", label: "User"),
            sourceClass: .observed,
            occurredAt: at,
            summary: summary,
            importance: 0.6
        )
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-emotag-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - (a) affect state at encode drives the tag

    @Test func warmEncodeAndUncertainEncodeYieldDifferentTags() async throws {
        // WARM: pre-warm affect with genuine affection (no nodes created — updateAffect is
        // the affect-only seam), then encode ONE fresh node so isNewNode → tag = current.
        let warmClock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let warm = substrate(warmClock)
        for _ in 0..<6 {
            _ = await warm.updateAffect(from: affectEvent(.userMessageReceived, "proud of you 💜 how are you feeling", at: warmClock.now()))
        }
        await warm.ingest(CognitiveEvent(
            id: "warm-encode", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "topic", id: "probe", label: "probe"),
            sourceClass: .userStated, occurredAt: warmClock.now(), summary: "a neutral note", importance: 0.4))
        let warmNode = try #require(await warm.snapshot().nodes.first { $0.subjectReference.id == "probe" })

        // UNCERTAIN: pre-load affect with repeated failures (raises uncertainty, no warmth),
        // then encode a fresh node.
        let coldClock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let cold = substrate(coldClock)
        for _ in 0..<6 {
            _ = await cold.updateAffect(from: affectEvent(.toolFailed, "the build failed again", at: coldClock.now()))
        }
        await cold.ingest(CognitiveEvent(
            id: "uncertain-encode", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "topic", id: "probe", label: "probe"),
            sourceClass: .userStated, occurredAt: coldClock.now(), summary: "a neutral note", importance: 0.4))
        let uncertainNode = try #require(await cold.snapshot().nodes.first { $0.subjectReference.id == "probe" })

        // The warm encode feels measurably warmer AND more positive than the uncertain one.
        #expect(warmNode.emotionalWarmth > uncertainNode.emotionalWarmth + 0.2,
                "warm encode warmth \(warmNode.emotionalWarmth) vs uncertain \(uncertainNode.emotionalWarmth)")
        #expect(warmNode.emotionalValence > uncertainNode.emotionalValence + 0.2,
                "warm encode valence \(warmNode.emotionalValence) vs uncertain \(uncertainNode.emotionalValence)")
        #expect(warmNode.emotionalValence > 0, "warm encode should feel positive, got \(warmNode.emotionalValence)")
        #expect(uncertainNode.emotionalValence < 0, "uncertain encode should feel negative, got \(uncertainNode.emotionalValence)")
    }

    // MARK: - (b) re-activation blend is ASYMMETRIC (warm-fast / cold-slow)

    @Test func reactivationBlendIsAsymmetric() throws {
        let cfg = CognitiveConfiguration(enabled: true, affectEnabled: true, maximumActiveNodes: 256, defaultDecayHalfLife: 100)
        let now = Date(timeIntervalSince1970: 5_000_000)

        func makeNode(seed: (Double, Double, Double), then refire: (Double, Double, Double)) -> CognitiveNode {
            var field = ContinuityField()
            let ev = CognitiveEvent(
                id: "seed-\(seed.0)-\(refire.0)", kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "topic", id: "n", label: "n"),
                sourceClass: .userStated, occurredAt: now, summary: "hello", importance: 0.5)
            let out = field.ingest(ev, now: now, makeUUID: { UUID() }, configuration: cfg)!
            // Stamp the seed feeling as a NEW node (set directly), then re-fire it (blend).
            field.stampEmotionTag(key: out.key, tag: (valence: seed.0, arousal: seed.1, warmth: seed.2),
                                  isNewNode: true, configuration: cfg)
            field.stampEmotionTag(key: out.key, tag: (valence: refire.0, arousal: refire.1, warmth: refire.2),
                                  isNewNode: false, configuration: cfg)
            return field.snapshot(at: now, configuration: cfg).first!
        }

        // Equal-magnitude (0.6) moves in opposite directions on both asymmetric axes.
        // Warmth: cold node (0.2) re-fired warm (0.8) should climb FAST.
        let warmed = makeNode(seed: (-0.3, 0.5, 0.2), then: (0.3, 0.5, 0.8))
        // Warmth: warm node (0.8) re-fired cold (0.2) should fall SLOW.
        let cooled = makeNode(seed: (0.3, 0.5, 0.8), then: (-0.3, 0.5, 0.2))

        let warmthUp = warmed.emotionalWarmth - 0.2      // moved up from 0.2
        let warmthDown = 0.8 - cooled.emotionalWarmth    // moved down from 0.8
        #expect(warmthUp > warmthDown,
                "warmth must warm FASTER than it cools: up \(warmthUp) vs down \(warmthDown)")

        let valenceUp = warmed.emotionalValence - (-0.3) // moved up from -0.3
        let valenceDown = 0.3 - cooled.emotionalValence  // moved down from 0.3
        #expect(valenceUp > valenceDown,
                "valence must brighten FASTER than it darkens: up \(valenceUp) vs down \(valenceDown)")

        // Arousal blends symmetrically (single rate) — sanity: it moved toward the refire value.
        #expect(warmed.emotionalArousal == 0.5, "arousal seed==refire should be unchanged, got \(warmed.emotionalArousal)")
    }

    // MARK: - (c) tag round-trips through saveNodes -> loadNodes

    @Test func tagRoundTripsThroughStore() async throws {
        let root = try tempDataRoot("roundtrip")
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let node = CognitiveNode(
            id: UUID(), kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "rt", label: "rt"),
            activation: 0.5, salience: 0.5, confidence: 0.8, sourceClass: .observed,
            createdAt: Date(timeIntervalSince1970: 10), lastActivatedAt: Date(timeIntervalSince1970: 20),
            decayHalfLife: 100, summary: "round trip", metadata: [:],
            emotionalValence: -0.42, emotionalArousal: 0.66, emotionalWarmth: 0.71)
        try await store.saveNodes([node], at: Date(timeIntervalSince1970: 30))

        let loaded = try #require(try await store.loadNodes().first)
        #expect(abs(loaded.emotionalValence - (-0.42)) < 1e-9)
        #expect(abs(loaded.emotionalArousal - 0.66) < 1e-9)
        #expect(abs(loaded.emotionalWarmth - 0.71) < 1e-9)
    }

    // MARK: - (d) MIGRATION SAFETY — a pre-tag (v1/v2) DB opens clean with default-0 tags

    @Test func legacyDatabaseOpensCleanWithDefaultTags() async throws {
        let root = try tempDataRoot("legacy")
        let dir = root.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("cognition.sqlite")

        // Hand-build a DB at the v2 schema — NO emotional_* columns — and record the v1/v2
        // migration identifiers so the store's migrator runs ONLY the new v3 ALTER on open.
        let legacy = try DatabaseQueue(path: dbURL.path)
        try await legacy.write { db in
            try db.execute(sql: """
                CREATE TABLE cognitive_nodes (
                    id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL,
                    subject_type TEXT NOT NULL, subject_id TEXT NOT NULL, subject_label TEXT,
                    activation REAL NOT NULL, salience REAL NOT NULL, confidence REAL NOT NULL,
                    source_class TEXT NOT NULL, created_at REAL NOT NULL, last_activated_at REAL NOT NULL,
                    decay_half_life REAL NOT NULL, summary TEXT NOT NULL, metadata_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE cognitive_artifacts (
                    id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
                    score REAL NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
                );
                CREATE TABLE cognitive_receipts (
                    id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL
                );
                CREATE TABLE cognitive_schema_markers (name TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                INSERT INTO cognitive_schema_markers (name, value) VALUES ('schema_version', '2');
                CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations (identifier) VALUES ('v1_cognitive_substrate');
                INSERT INTO grdb_migrations (identifier) VALUES ('v2_cognitive_receipts_and_schema_markers');
                """)
            try db.execute(sql: """
                INSERT INTO cognitive_nodes
                    (id, kind, subject_type, subject_id, subject_label, activation, salience, confidence,
                     source_class, created_at, last_activated_at, decay_half_life, summary, metadata_json, updated_at)
                VALUES (?, 'conversationFocus', 'topic', 'legacy', 'legacy', 0.5, 0.5, 0.8,
                        'observed', 10, 20, 100, 'old node', '{}', 30)
                """, arguments: [UUID().uuidString])
        }
        // Release the handle before the store re-opens the same file.
        try legacy.close()

        // Opening the store runs the additive v3 migration; the legacy row must load with
        // neutral (0) tags and NO crash.
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let loaded = try #require(try await store.loadNodes().first { $0.subjectReference.id == "legacy" })
        #expect(loaded.emotionalValence == 0)
        #expect(loaded.emotionalArousal == 0)
        #expect(loaded.emotionalWarmth == 0)
    }
}
