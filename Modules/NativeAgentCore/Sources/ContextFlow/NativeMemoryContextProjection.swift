import Context
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore

struct NativeMemoryProjectionRecord: Sendable, Equatable {
    let id: String
    let text: String
    let layer: String?
    let memoryKind: String?
    let createdAt: String
    let updatedAt: String?
    let sourceRunId: String?
    var status: String?
    let pinned: Bool?
    let confidence: Double?
    let importance: Double?
    let tags: [String]?
    let sourceQuality: Double?
    let decay: JSONValue?
    let correction: JSONValue?
    let provenance: JSONValue?
    let extras: JSONValue?
    let personaId: String?
    let lifecycle: String?
    let validFrom: String?
    let validTo: String?
    let observedAt: String?
    let evidence: JSONValue?

    init(
        id: String,
        text: String,
        layer: String?,
        memoryKind: String?,
        createdAt: String,
        updatedAt: String?,
        sourceRunId: String?,
        status: String?,
        pinned: Bool?,
        confidence: Double?,
        importance: Double?,
        tags: [String]?,
        sourceQuality: Double?,
        decay: JSONValue?,
        correction: JSONValue?,
        provenance: JSONValue?,
        extras: JSONValue?,
        personaId: String? = nil,
        lifecycle: String? = nil,
        validFrom: String? = nil,
        validTo: String? = nil,
        observedAt: String? = nil,
        evidence: JSONValue? = nil
    ) {
        self.id = id
        self.text = text
        self.layer = layer
        self.memoryKind = memoryKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceRunId = sourceRunId
        self.status = status
        self.pinned = pinned
        self.confidence = confidence
        self.importance = importance
        self.tags = tags
        self.sourceQuality = sourceQuality
        self.decay = decay
        self.correction = correction
        self.provenance = provenance
        self.extras = extras
        self.personaId = personaId
        self.lifecycle = lifecycle
        self.validFrom = validFrom
        self.validTo = validTo
        self.observedAt = observedAt
        self.evidence = evidence
    }
}

protocol NativeMemoryContextProjectionMemory: Sendable {
    func listContextProjectionRecords() async throws -> [NativeMemoryProjectionRecord]
    func contextProjectionEmbeddingModelFingerprint() async throws -> String
    func embedForDerivedContext(_ texts: [String]) async throws -> [[Float]]
    func contextProjectionEmbeddingEpoch() async throws -> MemoryEmbeddingEpoch
    func embedForDerivedContextWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch
}

extension NativeMemoryContextProjectionMemory {
    func contextProjectionEmbeddingEpoch() async throws -> MemoryEmbeddingEpoch {
        MemoryEmbeddingEpoch(rawValue: try await contextProjectionEmbeddingModelFingerprint())
    }

    func embedForDerivedContextWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        MemoryEmbeddingBatch(
            epoch: try await contextProjectionEmbeddingEpoch(),
            vectors: try await embedForDerivedContext(texts)
        )
    }
}

extension SwiftNativeMemoryV2: NativeMemoryContextProjectionMemory {
    func listContextProjectionRecords() async throws -> [NativeMemoryProjectionRecord] {
        try await listMemory(kind: nil).map { record in
            NativeMemoryProjectionRecord(
                id: record.id,
                text: record.text,
                layer: record.layer,
                memoryKind: record.memoryKind,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                sourceRunId: record.sourceRunId,
                status: record.status,
                pinned: record.pinned,
                confidence: record.confidence,
                importance: record.importance,
                tags: record.tags,
                sourceQuality: record.sourceQuality,
                decay: record.decay,
                correction: record.correction,
                provenance: record.provenance,
                extras: record.extras,
                personaId: record.personaId,
                lifecycle: record.lifecycle,
                validFrom: record.validFrom,
                validTo: record.validTo,
                observedAt: record.observedAt,
                evidence: record.evidence
            )
        }
    }

    func contextProjectionEmbeddingEpoch() async throws -> MemoryEmbeddingEpoch {
        guard let epoch = embeddingEpoch() else {
            throw MemoryV2Error.storageUnavailable
        }
        return epoch
    }

    func contextProjectionEmbeddingModelFingerprint() async throws -> String {
        try await contextProjectionEmbeddingEpoch().rawValue
    }
}

struct NativeMemoryContextProjectionLimits: Sendable, Equatable {
    static let standard = NativeMemoryContextProjectionLimits()

    let maximumRecords: Int
    let maximumTextUTF8Bytes: Int
    let maximumEmbeddingBatchSize: Int
    let maximumTagsPerRecord: Int
    let maximumTagUTF8Bytes: Int
    let maximumProvenanceUTF8Bytes: Int

    init(
        maximumRecords: Int = 2_000,
        maximumTextUTF8Bytes: Int = 16 * 1_024,
        maximumEmbeddingBatchSize: Int = 32,
        maximumTagsPerRecord: Int = 32,
        maximumTagUTF8Bytes: Int = 128,
        maximumProvenanceUTF8Bytes: Int = 2 * 1_024
    ) {
        self.maximumRecords = maximumRecords
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.maximumEmbeddingBatchSize = maximumEmbeddingBatchSize
        self.maximumTagsPerRecord = maximumTagsPerRecord
        self.maximumTagUTF8Bytes = maximumTagUTF8Bytes
        self.maximumProvenanceUTF8Bytes = maximumProvenanceUTF8Bytes
    }
}

enum NativeMemoryContextProjectionError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidModelFingerprint
    case embeddingCountMismatch(expected: Int, actual: Int)
    case invalidEmbedding(batchIndex: Int)
}

/// Packet provenance (2026-07-11): atomID → memory RECORD ID, accepted with
/// each published generation. Atom/source IDs are one-way digests, so this index is
/// the ONLY way back from a packet's memory atoms to record identity — and it
/// lives with the projection owner, never in core. Pure derived state:
/// rebuildable, never persisted. Pinned turns retain their generation's mapping;
/// attention lookup uses only the current accepted generation.
public final class MemoryAtomRecordIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var atomToRecord: [ContextAtomID: String] = [:]
    private var generationMappings: [Int64: [ContextAtomID: String]] = [:]
    private var recordToAtom: [String: ContextAtomID] = [:]

    func publish(
        _ mapping: [ContextAtomID: String]?,
        generationID: Int64,
        liveAtomIDs: Set<ContextAtomID>,
        retaining generationIDs: Set<Int64>
    ) {
        lock.withLock {
            atomToRecord = (mapping ?? atomToRecord).filter { liveAtomIDs.contains($0.key) }
            generationMappings = generationMappings.filter { generationIDs.contains($0.key) }
            generationMappings[generationID] = atomToRecord
            recordToAtom = Dictionary(atomToRecord.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func atomID(forRecordID recordID: String) -> ContextAtomID? {
        let normalized = NativeMemoryContextProjection.normalizedRecordID(recordID)
        return lock.withLock { recordToAtom[normalized] }
    }

    func recordIDs(for atomIDs: [ContextAtomID]) -> [String] {
        lock.withLock { atomIDs.compactMap { atomToRecord[$0] } }
    }

    func recordMap(for atomIDs: [ContextAtomID], generationID: Int64) -> [ContextAtomID: String] {
        let requested = Set(atomIDs)
        return lock.withLock {
            (generationMappings[generationID] ?? [:]).filter { requested.contains($0.key) }
        }
    }

    var count: Int {
        lock.withLock { atomToRecord.count }
    }
}

struct NativeMemoryContextProjection: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.memory-v2"

    var projectionIdentifier: String { Self.owner }
    var invalidationNamespaces: Set<String> { ["memory-v2"] }
    let invalidationSourceURL: URL?
    private let dataRoot: URL

    // v3: creation time is separate from update freshness for memory age tags.
    private static let schemaVersion = "memory-context-projection-v4"
    private let memory: any NativeMemoryContextProjectionMemory
    let limits: NativeMemoryContextProjectionLimits
    private let provenanceIndex: MemoryAtomRecordIndex?

    init(
        memory: any NativeMemoryContextProjectionMemory = SwiftNativeMemoryV2.shared,
        limits: NativeMemoryContextProjectionLimits = .standard,
        provenanceIndex: MemoryAtomRecordIndex? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.memory = memory
        self.limits = limits
        self.provenanceIndex = provenanceIndex
        self.dataRoot = dataRoot
        self.invalidationSourceURL = dataRoot.appendingPathComponent("memory/memory.sqlite")
            .standardizedFileURL
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        try validateLimits()

        let listed = try await memory.listContextProjectionRecords()
        let active = listed.filter(Self.isActive)
        let prepared = Self.prepareUnique(active, limits: limits, dataRoot: dataRoot)
            .sorted { $0.recordID < $1.recordID }
        let selected = Array(prepared.prefix(limits.maximumRecords))
        let selectedIDs = Set(selected.map(\.sourceID))
        let previousOwnedIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == Self.owner }
            .map(\.descriptor.id))
        let removed = previousOwnedIDs.subtracting(selectedIDs)

        let atomRecordIDs = Dictionary(
            selected.map { ($0.atomID, $0.recordID) },
            uniquingKeysWith: { first, _ in first }
        )

        guard !selected.isEmpty else {
            return ContextCompiledProjectionResult(
                changedSources: [],
                removedSourceIDs: removed,
                atomRecordIDs: atomRecordIDs
            )
        }

        let modelFingerprint = try await memory.contextProjectionEmbeddingEpoch().rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelFingerprint.isEmpty else {
            throw NativeMemoryContextProjectionError.invalidModelFingerprint
        }

        let changed = selected.filter { item in
            guard let previous = previousSources[item.sourceID],
                  previous.sourceHash == item.sourceHash,
                  previous.atoms.count == 1,
                  let embedding = previous.atoms[0].embedding,
                  embedding.modelFingerprint == modelFingerprint,
                  !embedding.values.isEmpty,
                  embedding.values.allSatisfy(\.isFinite) else {
                return true
            }
            return false
        }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(changed.count)
        var offset = 0
        while offset < changed.count {
            let end = min(offset + limits.maximumEmbeddingBatchSize, changed.count)
            let texts = changed[offset..<end].map(\.embeddingText)
            let batch = try await memory.embedForDerivedContextWithEpoch(texts)
            guard batch.epoch.rawValue == modelFingerprint else {
                throw NativeMemoryContextProjectionError.invalidModelFingerprint
            }
            guard batch.vectors.count == texts.count else {
                throw NativeMemoryContextProjectionError.embeddingCountMismatch(
                    expected: texts.count,
                    actual: batch.vectors.count
                )
            }
            for (index, vector) in batch.vectors.enumerated() {
                guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
                    throw NativeMemoryContextProjectionError.invalidEmbedding(
                        batchIndex: offset + index
                    )
                }
            }
            vectors.append(contentsOf: batch.vectors)
            offset = end
        }

        let changedSources = zip(changed, vectors).map { item, vector in
            item.compiledSource(
                embedding: ContextEmbedding(
                    modelFingerprint: modelFingerprint,
                    values: vector
                )
            )
        }
        return ContextCompiledProjectionResult(
            changedSources: changedSources,
            removedSourceIDs: removed,
            atomRecordIDs: atomRecordIDs
        )
    }

    func didPublish(
        _ result: ContextCompiledProjectionResult?,
        generation: ContextStoredGeneration,
        retaining generationIDs: Set<Int64>
    ) {
        provenanceIndex?.publish(
            result?.atomRecordIDs,
            generationID: generation.generation.id,
            liveAtomIDs: Set(generation.atoms.lazy
                .filter { $0.validToGeneration == nil }
                .map(\.draft.id)),
            retaining: generationIDs
        )
    }

    private func validateLimits() throws {
        guard limits.maximumRecords > 0,
              limits.maximumTextUTF8Bytes > 0,
              limits.maximumEmbeddingBatchSize > 0,
              limits.maximumTagsPerRecord > 0,
              limits.maximumTagUTF8Bytes > 0,
              limits.maximumProvenanceUTF8Bytes > 0 else {
            throw NativeMemoryContextProjectionError.invalidLimits
        }
    }
}

private extension NativeMemoryContextProjection {
    struct PreparedRecord: Sendable {
        let recordID: String
        let sourceID: ContextSourceID
        let descriptor: ContextSourceDescriptor
        let atomID: ContextAtomID
        let atomKind: ContextAtomKind
        let contentRole: ContextContentRole
        let body: String
        let embeddingText: String
        let sourceHash: String
        let authority: ContextAuthority
        let confidence: Double
        let freshness: ContextFreshness
        let tags: [String]
        let entities: [ContextEntity]
        let importance: Double
        let sourceQuality: Double
        let decayState: Double

        func compiledSource(embedding: ContextEmbedding) -> ContextCompiledSource {
            let atom = ContextAtomDraft(
                id: atomID,
                sourceID: sourceID,
                kind: atomKind,
                headingPath: [],
                sourceRange: ContextSourceRange(
                    utf8Start: 0,
                    utf8End: body.utf8.count
                ),
                sourceHash: sourceHash,
                body: body,
                authority: authority,
                confidence: confidence,
                freshness: freshness,
                privacy: descriptor.privacy,
                permittedSurfaces: descriptor.permittedSurfaces,
                injectionPolicy: .adaptive,
                contentRole: contentRole,
                entities: entities,
                triggers: tags,
                activation: importance,
                recentUsefulness: sourceQuality,
                decayState: decayState,
                embedding: embedding
            )
            return ContextCompiledSource(
                descriptor: descriptor,
                sourceHash: sourceHash,
                atoms: [atom]
            )
        }
    }

    static func prepareUnique(
        _ records: [NativeMemoryProjectionRecord],
        limits: NativeMemoryContextProjectionLimits,
        dataRoot: URL
    ) -> [PreparedRecord] {
        let grouped = Dictionary(grouping: records, by: { normalizedID($0.id) })
        return grouped.keys.sorted().compactMap { key in
            guard !key.isEmpty,
                  let group = grouped[key],
                  group.count == 1 else {
                return nil
            }
            return prepare(group[0], limits: limits, dataRoot: dataRoot)
        }
    }

    static func prepare(
        _ record: NativeMemoryProjectionRecord,
        limits: NativeMemoryContextProjectionLimits,
        dataRoot: URL
    ) -> PreparedRecord? {
        let recordID = normalizedID(record.id)
        guard !recordID.isEmpty,
              recordID.utf8.count <= 512,
              !NativeContextProjectionText.containsDisallowedControl(recordID) else {
            return nil
        }

        let embeddingText = normalizedText(record.text)
        guard !embeddingText.isEmpty,
              embeddingText.utf8.count <= limits.maximumTextUTF8Bytes,
              !NativeContextProjectionText.containsDisallowedControl(embeddingText),
              !ContextSecretContentPolicy.containsSecretLikeContent(embeddingText) else {
            return nil
        }
        guard MemoryCandidateQuality.isDurableCandidate(
            text: embeddingText,
            source: record.sourceRunId,
            kind: record.memoryKind
        ) else {
            return nil
        }

        guard let updatedAt = parseDate(record.updatedAt) ?? parseDate(record.createdAt) else {
            return nil
        }
        let createdAt = parseDate(record.createdAt)
        let tags = normalizedTags(record.tags, limits: limits)
        guard let provenance = provenanceText(record, limit: limits.maximumProvenanceUTF8Bytes) else {
            return nil
        }
        let body = presentationBody(
            embeddingText, record: record, maximumUTF8Bytes: limits.maximumTextUTF8Bytes
        )

        let correction = isCorrection(record, tags: tags)
        let pinned = record.pinned == true
        let authority: ContextAuthority = correction
            ? .explicitCorrection
            : (pinned ? .canonical : .inferred)
        let atomKind: ContextAtomKind = correction ? .correction : .memory
        // Skills-as-recall (2026-07-03) dissolved the skill library into memory
        // pointer rows. The legacy recall lane still shares its budget with
        // them (`selectRecallResults`); the ContextFlow lane cannot, because
        // every pointer arrives as an ordinary `.memory` atom competing on
        // cosine against 200+ real memories inside one 8-slot kind quota.
        // Stamping the PROCEDURAL content role is what makes them findable to
        // the selector's reservation without minting a second atom kind — the
        // row is still a memory record, its content is still a skill.
        let skillPointer = !correction && MemoryRecallScoring.isSkillRecallHint(
            id: recordID,
            kind: record.memoryKind ?? MemoryRecallScoring.kind(of: record.extras)
        )
        // Phase 5 C3: what happened between them rides its own lane.
        let personal = !correction && Self.personalKinds.contains(
            (record.memoryKind ?? MemoryRecallScoring.kind(of: record.extras) ?? "").lowercased())
        let contentRole: ContextContentRole = skillPointer ? .procedure : (personal ? .personal : .memory)
        guard let disclosure = MemoryRecordDisclosurePolicy.classify(
            personaID: record.personaId,
            status: record.status,
            lifecycle: record.lifecycle,
            tags: tags,
            metadata: record.extras
        ) else { return nil }
        let privacy: ContextPrivacy
        switch disclosure.privacy {
        case .localPrivate: privacy = .localPrivate
        case .trustedRemote: privacy = .trustedRemote
        case .publicSafe: privacy = .publicSafe
        }
        let surfaces = Set(disclosure.permittedSurfaces.map(ContextSurface.init(rawValue:)))
        guard !surfaces.isEmpty else { return nil }

        let locatorDigest = ContextStableID.digest(parts: [recordID])
        let personaScope: String = {
            guard let rawPersona = disclosure.personaID else { return "shared" }
            let normalized = rawPersona.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return "shared" }
            return "personas/\(ContextStableID.digest(parts: [normalized]))"
        }()
        let locator = "memory-v2/\(personaScope)/records/\(locatorDigest)"
        // Keep record/atom identity stable when disclosure scope changes.
        // The canonical locator carries persona scope for eligibility, while
        // the source identity remains the long-standing record-id digest used
        // by resident attention activation and persisted generations.
        let sourceID = ContextStableID.source(
            owner: owner,
            locator: "memory-v2/records/\(locatorDigest)"
        )
        let descriptor = ContextSourceDescriptor(
            id: sourceID,
            owner: owner,
            kind: .memory,
            canonicalLocator: locator,
            authority: authority,
            privacy: privacy,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive
        )
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: atomKind,
            headingPath: [],
            blockAnchor: "memory-record"
        )

        var entities = [ContextEntity(
            kind: "memory_record",
            id: locatorDigest,
            label: record.memoryKind ?? record.layer ?? "memory"
        )]
        for source in MemoryDataProvenance.sources(in: record.extras, dataRoot: dataRoot) {
            entities.append(ContextEntity(kind: "untrusted_source", id: ContextStableID.digest(parts: [source]), label: source))
        }
        entities.append(ContextEntity(
            kind: "memory_authority",
            id: correction ? "correction" : (pinned ? "pinned" : "adaptive"),
            label: correction ? "explicit correction" : (pinned ? "pinned memory" : "adaptive memory")
        ))
        if case .array(let values)? = objectValue(record.extras, key: "context_topics") {
            for case .string(let topic) in values.prefix(8) {
                let clean = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 120 else { continue }
                entities.append(ContextEntity(
                    kind: ContextCorrectionScope.entityKind,
                    id: ContextStableID.digest(parts: [clean.lowercased()]),
                    label: clean
                ))
            }
        }
        if !provenance.isEmpty {
            entities.append(ContextEntity(
                kind: "provenance",
                id: ContextStableID.digest(parts: [provenance]),
                label: provenance
            ))
        }

        let confidence = finite(record.confidence) ?? 1
        let importance = finite(record.importance) ?? 0
        let sourceQuality = finite(record.sourceQuality) ?? 0
        let decayState = decayValue(record.decay) ?? 1
        let sourceHash = ContextStableID.digest(parts: [
            schemaVersion,
            body,
            atomKind.rawValue,
            contentRole.rawValue,
            authority.rawValue,
            privacy.rawValue,
            surfaces.sorted().map(\.rawValue).joined(separator: ","),
            disclosure.personaID?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "",
            String(confidence.bitPattern),
            String(importance.bitPattern),
            String(sourceQuality.bitPattern),
            String(decayState.bitPattern),
            String(updatedAt.timeIntervalSince1970.bitPattern),
            createdAt.map { String($0.timeIntervalSince1970.bitPattern) } ?? "",
            tags.joined(separator: "\u{1f}"),
            provenance,
            record.validFrom ?? "",
            record.validTo ?? "",
            record.observedAt ?? "",
            canonicalJSONString(record.evidence) ?? "",
            canonicalJSONString(objectValue(record.extras, key: "context_topics")) ?? "",
            canonicalJSONString(.object(MemoryDataProvenance.fields(in: record.extras, dataRoot: dataRoot))) ?? "",
        ] + (body == embeddingText ? [] : [embeddingText]))

        return PreparedRecord(
            recordID: recordID,
            sourceID: sourceID,
            descriptor: descriptor,
            atomID: atomID,
            atomKind: atomKind,
            contentRole: contentRole,
            body: body,
            embeddingText: embeddingText,
            sourceHash: sourceHash,
            authority: authority,
            confidence: confidence,
            freshness: ContextFreshness(updatedAt: updatedAt, createdAt: createdAt),
            tags: tags,
            entities: entities,
            importance: importance,
            sourceQuality: sourceQuality,
            decayState: decayState
        )
    }

    /// Memory kinds the personal lane carries (Phase 5 C3).
    static let personalKinds: Set<String> = ["moment", "relationship", "lesson_origin"]

    static func isActive(_ record: NativeMemoryProjectionRecord) -> Bool {
        let status = record.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return status == nil || status == "active"
    }

    static func normalizedID(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTags(
        _ values: [String]?,
        limits: NativeMemoryContextProjectionLimits
    ) -> [String] {
        let valid = (values ?? []).compactMap { raw -> String? in
            let value = raw.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !value.isEmpty,
                  value.utf8.count <= limits.maximumTagUTF8Bytes,
                  !NativeContextProjectionText.containsDisallowedControl(value) else {
                return nil
            }
            return value
        }
        return Array(Set(valid).sorted().prefix(limits.maximumTagsPerRecord))
    }

    static func isCorrection(_ record: NativeMemoryProjectionRecord, tags: [String]) -> Bool {
        if record.memoryKind?.lowercased() == "correction" || tags.contains("correction") {
            return true
        }
        guard let correction = record.correction ?? objectValue(record.extras, key: "correction") else {
            return false
        }
        switch correction {
        case .null, .bool(false): return false
        case .object(let object):
            if case .bool(let current)? = object["current"] { return current }
            if case .bool(let active)? = object["active"] { return active }
            return !object.isEmpty
        case .array(let values): return !values.isEmpty
        case .string(let value): return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bool(true), .int, .double: return true
        }
    }

    static func provenanceText(_ record: NativeMemoryProjectionRecord, limit: Int) -> String? {
        var components: [String] = []
        if let source = record.sourceRunId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            guard !NativeContextProjectionText.containsDisallowedControl(source),
                  !source.contains(";"), !source.contains("=") else { return nil }
            components.append("source_run_id=\(source)")
        }
        if let provenance = record.provenance ?? objectValue(record.extras, key: "provenance") {
            guard let data = try? canonicalEncoder.encode(provenance),
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            components.append("provenance=\(value)")
        }
        // Who told her, when provenance is `told` (commit_memory's
        // `provenance_by`). Without it the packet can only render "[told]",
        // which loses the half that matters: told BY WHOM.
        //
        // Emitted only as a bounded display name (the same rule the memory tool
        // validates on commit). This blob is `key=value;…`, so a name carrying a
        // delimiter would be read back as another field: it is dropped here, and
        // the reader takes the FIRST value per key, so neither side alone has to
        // be the one that holds.
        if let raw = stringValue(record.extras, key: "provenance_by"),
           let by = ContextMemoryLead.validDisplayName(raw) {
            components.append("provenance_by=\(by)")
        }
        if let validFrom = record.validFrom { components.append("valid_from=\(validFrom)") }
        if let validTo = record.validTo { components.append("valid_to=\(validTo)") }
        if let observedAt = record.observedAt { components.append("observed_at=\(observedAt)") }
        if let evidence = record.evidence,
           let data = try? canonicalEncoder.encode(evidence),
           let value = String(data: data, encoding: .utf8) {
            components.append("evidence=\(value)")
        }
        let combined = components.joined(separator: ";")
        guard combined.utf8.count <= limit,
              !ContextSecretContentPolicy.containsSecretLikeContent(combined) else {
            return nil
        }
        return combined
    }

    /// Dates are presentation evidence, not vector input or a valid-now test.
    /// Prefix them so the existing bounded context_expand prefix also retains
    /// them. Reserve their bytes inside the existing body cap, never above it.
    static func presentationBody(
        _ text: String, record: NativeMemoryProjectionRecord, maximumUTF8Bytes: Int
    ) -> String {
        let warning = MemorySenseProvenance.warning(in: record.extras)
        let fields = [
            ("valid_from", record.validFrom),
            ("valid_to", record.validTo),
            ("observed_at", record.observedAt),
        ].compactMap { key, raw -> String? in
            guard let raw else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 64,
                  !NativeContextProjectionText.containsDisallowedControl(value), parseDate(value) != nil else { return nil }
            return "\(key)=\(value)"
        }
        guard !fields.isEmpty || warning != nil else { return text }
        let prefix = (warning.map { "[\($0)]\n" } ?? "")
            + (fields.isEmpty ? "" : "[Recorded dates; not a live-status check; observed_at is evidence time: "
                + fields.joined(separator: "; ") + "]\n")
        if prefix.utf8.count + text.utf8.count <= maximumUTF8Bytes {
            return prefix + text
        }
        let suffix = "\n[Excerpt; full_content_chars=\(text.count)]"
        let available = maximumUTF8Bytes - prefix.utf8.count - suffix.utf8.count
        // A custom tiny budget must not discard the canonical fact merely
        // because a complete date label cannot fit. Standard budget is 16 KiB.
        guard available > 0 else { return text }
        var excerpt = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= available else { break }
            excerpt.append(character)
            bytes += size
        }
        return prefix + excerpt + suffix
    }

    static func canonicalJSONString(_ value: JSONValue?) -> String? {
        guard let value,
              let data = try? canonicalEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func decayValue(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let number): return finite(number)
        case .int(let number): return Double(number)
        case .object(let object):
            for key in ["state", "factor", "score", "retention", "value"] {
                if let result = decayValue(object[key]) { return result }
            }
            return nil
        default: return nil
        }
    }

    static func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
        guard case .object(let object)? = value else { return nil }
        return object[key]
    }

    static func stringValue(_ value: JSONValue?, key: String) -> String? {
        guard case .string(let result)? = objectValue(value, key: key) else { return nil }
        return result
    }

}

// Record lookup uses the projection's canonical identity normalization.
extension NativeMemoryContextProjection {
    static func normalizedRecordID(_ value: String) -> String {
        normalizedID(value)
    }

    /// Shared by the knowledge-graph projection too. Two formatters for the
    /// process: a pass over every memory used to build two per memory.
    /// Reconciliations can overlap, so the formatters are used under a lock.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        isoLock.lock(); defer { isoLock.unlock() }
        return fractionalISO.date(from: value) ?? plainISO.date(from: value)
    }

    private static let isoLock = NSLock()
    // Only touched under `isoLock`.
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainISO = ISO8601DateFormatter()
}
