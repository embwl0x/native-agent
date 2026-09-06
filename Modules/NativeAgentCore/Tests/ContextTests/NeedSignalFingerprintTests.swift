import Context
import Foundation
import Testing

/// `NeedSignal.deterministicFingerprint` is the identity of a turn's need. It
/// digests 30+ fields and it is what the selection receipt id (and, through
/// ContextExpansion, the expansion receipt id) is derived from.
///
/// The failure it can have is the classic one: *the digest forgot a field.* Add
/// a lane to NeedSignal, forget to append it to `parts`, and two materially
/// different needs collapse onto the SAME fingerprint — receipts collide and
/// feedback attributes to the wrong selection. Every determinism test in the
/// suite still passes, because they compare two selections that genuinely are
/// identical.
///
/// So this file asserts two things the rest of the suite cannot:
///   1. a per-field discrimination table — changing exactly one covered field
///      moves the fingerprint;
///   2. a COMPLETENESS guard — every encoded NeedSignal key is either in that
///      table or in a written-down exclusion list. A new field with no digest
///      coverage fails here instead of silently colliding in production.
@Suite("NeedSignal deterministic fingerprint")
struct NeedSignalFingerprintTests {
    // MARK: - Baseline

    /// Every field populated with a distinctive value, so a mutation of any one
    /// of them is a real difference rather than nil-vs-nil.
    private static func signal(
        message: String = "what is the atlas rollout status?",
        extractedEntities: Set<ContextEntity> = [
            ContextEntity(kind: "project", id: "atlas", label: "Atlas"),
        ],
        surface: ContextSurface = .chat,
        origin: ContextOriginClass = .localAuthenticated,
        allowedOrigins: Set<ContextOriginClass> = [.localAuthenticated],
        allowedPrivacy: Set<ContextPrivacy> = [.localPrivate],
        allowedSourceIDs: Set<ContextSourceID> = [ContextSourceID(rawValue: "src-a")],
        allowedAtomIDs: Set<ContextAtomID>? = [ContextAtomID(rawValue: "atom-a")],
        permissionLabels: Set<String> = ["persona.read"],
        sessionID: String? = "session-a",
        currentProjectID: String? = "project-a",
        executionID: String? = "execution-a",
        recentTurns: [String] = ["previous turn"],
        activeTask: String? = "task-a",
        unresolvedQuestion: String? = "question-a",
        goal: String? = "goal-a",
        predictedToolGroups: Set<String> = ["files"],
        contextualTerms: Set<String> = ["atlas"],
        cognitiveActivation: [ContextAtomID: Double] = [ContextAtomID(rawValue: "atom-a"): 0.5],
        feedbackUtilityOverrides: [ContextAtomID: Double] = [ContextAtomID(rawValue: "atom-a"): 0.25],
        feedbackDecayOverrides: [ContextAtomID: Double] = [ContextAtomID(rawValue: "atom-a"): 0.75],
        workingAtomIDs: Set<ContextAtomID> = [ContextAtomID(rawValue: "atom-w")],
        precoveredSourceIDs: Set<ContextSourceID> = [ContextSourceID(rawValue: "src-p")],
        mandatoryAtomIDs: Set<ContextAtomID> = [ContextAtomID(rawValue: "atom-m")],
        deletedAtomIDs: Set<ContextAtomID> = [ContextAtomID(rawValue: "atom-d")],
        tombstonedAtomIDs: Set<ContextAtomID> = [ContextAtomID(rawValue: "atom-t")],
        staleRuntimeAtomIDs: Set<ContextAtomID> = [ContextAtomID(rawValue: "atom-s")],
        secretBearingAtomIDs: Set<ContextAtomID> = [ContextAtomID(rawValue: "atom-x")],
        queryEmbedding: [Float]? = [0.1, 0.2],
        queryEmbeddingModelFingerprint: String? = "embedder-v1",
        availableGenerationID: Int64? = 7,
        characterBudget: Int = 6_000,
        mandatoryCharacterBudget: Int? = 4_000,
        packetAtomExpandThresholdChars: Int = 400,
        memoryAtomRowLimit: Int? = 12,
        now: Date = Date(timeIntervalSince1970: 10_000),
        timeBucketSeconds: Int = 60,
        explicitConflicts: [ContextConflictDefinition] = [
            ContextConflictDefinition(
                id: "conflict-a",
                memberAtomIDs: [ContextAtomID(rawValue: "atom-a"), ContextAtomID(rawValue: "atom-m")],
                resolvedAtomID: ContextAtomID(rawValue: "atom-a"),
                provenance: "explicit"
            ),
        ],
        cacheState: ContextSelectionCacheState = .miss,
        measuredSelectionMicroseconds: Int? = 1_234
    ) -> NeedSignal {
        NeedSignal(
            message: message,
            extractedEntities: extractedEntities,
            surface: surface,
            origin: origin,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: allowedOrigins,
                allowedPrivacy: allowedPrivacy,
                allowedSourceIDs: allowedSourceIDs,
                allowedAtomIDs: allowedAtomIDs,
                permissionLabels: permissionLabels
            ),
            sessionID: sessionID,
            currentProjectID: currentProjectID,
            executionID: executionID,
            recentTurns: recentTurns,
            activeTask: activeTask,
            unresolvedQuestion: unresolvedQuestion,
            goal: goal,
            predictedToolGroups: predictedToolGroups,
            contextualTerms: contextualTerms,
            cognitiveActivation: cognitiveActivation,
            feedbackUtilityOverrides: feedbackUtilityOverrides,
            feedbackDecayOverrides: feedbackDecayOverrides,
            workingAtomIDs: workingAtomIDs,
            precoveredSourceIDs: precoveredSourceIDs,
            mandatoryAtomIDs: mandatoryAtomIDs,
            deletedAtomIDs: deletedAtomIDs,
            tombstonedAtomIDs: tombstonedAtomIDs,
            staleRuntimeAtomIDs: staleRuntimeAtomIDs,
            secretBearingAtomIDs: secretBearingAtomIDs,
            queryEmbedding: queryEmbedding,
            queryEmbeddingModelFingerprint: queryEmbeddingModelFingerprint,
            availableGenerationID: availableGenerationID,
            characterBudget: characterBudget,
            mandatoryCharacterBudget: mandatoryCharacterBudget,
            packetAtomExpandThresholdChars: packetAtomExpandThresholdChars,
            memoryAtomRowLimit: memoryAtomRowLimit,
            now: now,
            timeBucketSeconds: timeBucketSeconds,
            explicitConflicts: explicitConflicts,
            cacheState: cacheState,
            measuredSelectionMicroseconds: measuredSelectionMicroseconds
        )
    }

    /// One row per encoded key the digest claims to cover. `key` is the wire
    /// name (`CodingKeys`), so the completeness guard below can subtract this
    /// table from a real encoding and see what is left over.
    private static var discriminationTable: [(key: String, mutated: NeedSignal)] {
        [
            ("message", signal(message: "a different question entirely")),
            (
                "extractedEntities",
                signal(extractedEntities: [ContextEntity(kind: "project", id: "borealis", label: "Borealis")])
            ),
            ("surface", signal(surface: .telegram)),
            ("origin", signal(origin: .remoteAuthenticated)),
            // `authorization` is one encoded key with five digested members;
            // each gets its own row, because "the digest forgot a field" is
            // exactly as easy to do one level down.
            ("authorization", signal(allowedOrigins: [.localAuthenticated, .remoteAuthenticated])),
            ("authorization", signal(allowedPrivacy: [.localPrivate, .trustedRemote])),
            ("authorization", signal(allowedSourceIDs: [ContextSourceID(rawValue: "src-b")])),
            ("authorization", signal(allowedAtomIDs: nil)),
            ("authorization", signal(permissionLabels: ["persona.read", "memory.read"])),
            ("sessionID", signal(sessionID: "session-b")),
            ("currentProjectID", signal(currentProjectID: "project-b")),
            ("missionID", signal(executionID: "execution-b")),
            ("recentTurns", signal(recentTurns: ["previous turn", "and another"])),
            ("activeTask", signal(activeTask: "task-b")),
            ("unresolvedQuestion", signal(unresolvedQuestion: "question-b")),
            ("goal", signal(goal: "goal-b")),
            ("predictedToolGroups", signal(predictedToolGroups: ["files", "search"])),
            ("contextualTerms", signal(contextualTerms: ["atlas", "rollout"])),
            (
                "cognitiveActivation",
                signal(cognitiveActivation: [ContextAtomID(rawValue: "atom-a"): 0.6])
            ),
            (
                "feedbackUtilityOverrides",
                signal(feedbackUtilityOverrides: [ContextAtomID(rawValue: "atom-a"): 0.26])
            ),
            (
                "feedbackDecayOverrides",
                signal(feedbackDecayOverrides: [ContextAtomID(rawValue: "atom-a"): 0.76])
            ),
            ("workingAtomIDs", signal(workingAtomIDs: [ContextAtomID(rawValue: "atom-w2")])),
            ("precoveredSourceIDs", signal(precoveredSourceIDs: [ContextSourceID(rawValue: "src-p2")])),
            ("mandatoryAtomIDs", signal(mandatoryAtomIDs: [ContextAtomID(rawValue: "atom-m2")])),
            ("deletedAtomIDs", signal(deletedAtomIDs: [ContextAtomID(rawValue: "atom-d2")])),
            ("tombstonedAtomIDs", signal(tombstonedAtomIDs: [ContextAtomID(rawValue: "atom-t2")])),
            ("staleRuntimeAtomIDs", signal(staleRuntimeAtomIDs: [ContextAtomID(rawValue: "atom-s2")])),
            ("secretBearingAtomIDs", signal(secretBearingAtomIDs: [ContextAtomID(rawValue: "atom-x2")])),
            ("queryEmbedding", signal(queryEmbedding: [0.1, 0.3])),
            ("queryEmbeddingModelFingerprint", signal(queryEmbeddingModelFingerprint: "embedder-v2")),
            ("availableGenerationID", signal(availableGenerationID: 8)),
            ("characterBudget", signal(characterBudget: 6_001)),
            ("mandatoryCharacterBudget", signal(mandatoryCharacterBudget: 4_001)),
            // Both knobs change what the packet CONTAINS — the truncation
            // pointer set and the memory row count — so two turns that differ
            // only here are two different selections and must not share a
            // receipt id.
            (
                "packetAtomExpandThresholdChars",
                signal(packetAtomExpandThresholdChars: 401)
            ),
            ("memoryAtomRowLimit", signal(memoryAtomRowLimit: nil)),
            // The bucket is derived from `now`, which is how a real turn moves
            // it; the field itself is what lands in the digest.
            ("selectionTimeBucket", signal(now: Date(timeIntervalSince1970: 20_000))),
            ("timeBucketSeconds", signal(timeBucketSeconds: 120)),
            (
                "explicitConflicts",
                signal(explicitConflicts: [
                    ContextConflictDefinition(
                        id: "conflict-a",
                        memberAtomIDs: [
                            ContextAtomID(rawValue: "atom-a"),
                            ContextAtomID(rawValue: "atom-m"),
                        ],
                        resolvedAtomID: nil,
                        provenance: "explicit"
                    ),
                ])
            ),
            ("cacheState", signal(cacheState: .hit)),
        ]
    }

    /// Encoded keys the digest deliberately does NOT cover, each with the
    /// reason. Anything not in the discrimination table and not here is an
    /// unreviewed omission — that is the whole point of the guard below.
    private static let documentedExclusions: Set<String> = [
        // An OUTPUT measurement of how long selection took, stamped onto the
        // need after the fact. Digesting it would make the receipt id depend on
        // machine speed and destroy restart determinism.
        "measuredSelectionMicroseconds",
    ]

    // MARK: - (1) Per-field discrimination

    @Test
    func changingAnySingleDigestedFieldChangesTheFingerprint() {
        let baseline = Self.signal().deterministicFingerprint
        var seen: [String: String] = [:]
        for (key, mutated) in Self.discriminationTable {
            let fingerprint = mutated.deterministicFingerprint
            #expect(
                fingerprint != baseline,
                "changing \(key) did not move the fingerprint — the digest is blind to it"
            )
            // Two different mutations landing on one fingerprint is the
            // collision this whole file exists to catch.
            if let collidingKey = seen[fingerprint] {
                Issue.record("\(key) and \(collidingKey) produced the same fingerprint")
            }
            seen[fingerprint] = key
        }
        #expect(seen.count == Self.discriminationTable.count)
    }

    // MARK: - (2) Completeness — the digest cannot quietly forget a new field

    @Test
    func everyEncodedNeedSignalFieldIsDigestedOrExplicitlyExcluded() throws {
        let data = try JSONEncoder().encode(Self.signal())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedKeys = Set(object.keys)
        // The baseline populates every field, so nothing may be missing from
        // the encoding — otherwise "not encoded" would silently look like
        // "covered".
        #expect(encodedKeys.count >= 33, "baseline stopped populating some fields: \(encodedKeys.count)")

        let digested = Set(Self.discriminationTable.map(\.key))
        let unaccounted = encodedKeys.subtracting(digested).subtracting(Self.documentedExclusions)
        #expect(
            unaccounted.isEmpty,
            """
            NeedSignal field(s) \(unaccounted.sorted()) are neither proven to move \
            deterministicFingerprint nor listed in documentedExclusions. Two different \
            needs can now share a receipt id. Add the field to the digest and to the \
            discrimination table, or write down why it is excluded.
            """
        )

        let stale = digested.subtracting(encodedKeys)
        #expect(stale.isEmpty, "discrimination table names key(s) NeedSignal no longer encodes: \(stale.sorted())")
    }

    // MARK: - (3) Reproducibility, and the one documented exclusion

    @Test
    func identicalNeedSignalsReproduceTheSameFingerprint() {
        #expect(Self.signal().deterministicFingerprint == Self.signal().deterministicFingerprint)
        // Set/dictionary iteration order must not leak in: same members,
        // different literal order.
        let a = Self.signal(
            contextualTerms: ["atlas", "rollout", "status"],
            workingAtomIDs: [ContextAtomID(rawValue: "w1"), ContextAtomID(rawValue: "w2")]
        )
        let b = Self.signal(
            contextualTerms: ["status", "atlas", "rollout"],
            workingAtomIDs: [ContextAtomID(rawValue: "w2"), ContextAtomID(rawValue: "w1")]
        )
        #expect(a.deterministicFingerprint == b.deterministicFingerprint)
    }

    @Test
    func measuredSelectionLatencyIsExcludedSoTheReceiptIDStaysMachineIndependent() {
        #expect(
            Self.signal(measuredSelectionMicroseconds: 1_234).deterministicFingerprint
                == Self.signal(measuredSelectionMicroseconds: 987_654).deterministicFingerprint
        )
    }
}
