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

/// Packet provenance (2026-07-11): atomID → memory RECORD ID, rebuilt on every
/// projection compile. Atom/source IDs are one-way digests, so this index is
/// the ONLY way back from a packet's memory atoms to record identity — and it
/// lives with the projection owner, never in core. Pure derived state:
/// rebuildable, never persisted, replaced wholesale each compile. Because
/// atomID is a deterministic hash of record identity, a refreshed index can
/// never map an older generation's atom to a WRONG record — a just-deleted
/// record is a benign miss.
final class MemoryAtomRecordIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var atomToRecord: [ContextAtomID: String] = [:]

    func replaceAll(_ mapping: [ContextAtomID: String]) {
        lock.withLock { atomToRecord = mapping }
    }

    func recordIDs(for atomIDs: [ContextAtomID]) -> [String] {
        lock.withLock { atomIDs.compactMap { atomToRecord[$0] } }
    }

    var count: Int {
        lock.withLock { atomToRecord.count }
    }
}

struct NativeMemoryContextProjection: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.memory-v2"

    var projectionIdentifier: String { Self.owner }
    var invalidationNamespaces: Set<String> { ["memory-v2"] }

    private static let schemaVersion = "memory-context-projection-v1"
    private let memory: any NativeMemoryContextProjectionMemory
    let limits: NativeMemoryContextProjectionLimits
    private let provenanceIndex: MemoryAtomRecordIndex?

    init(
        memory: any NativeMemoryContextProjectionMemory = SwiftNativeMemoryV2.shared,
        limits: NativeMemoryContextProjectionLimits = .standard,
        provenanceIndex: MemoryAtomRecordIndex? = nil
    ) {
        self.memory = memory
        self.limits = limits
        self.provenanceIndex = provenanceIndex
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        try validateLimits()

        let listed = try await memory.listContextProjectionRecords()
        let active = listed.filter(Self.isActive)
        let prepared = Self.prepareUnique(active, limits: limits)
            .sorted { $0.recordID < $1.recordID }
        let selected = Array(prepared.prefix(limits.maximumRecords))
        let selectedIDs = Set(selected.map(\.sourceID))
        let previousOwnedIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == Self.owner }
            .map(\.descriptor.id))
        let removed = previousOwnedIDs.subtracting(selectedIDs)

        // Refresh BEFORE the empty guard so a projection that publishes zero
        // records also clears the reverse index — stale identity must not
        // outlive the records it named. `selected` is the full published set
        // (not just changed sources), so replace-all semantics are exact.
        provenanceIndex?.replaceAll(Dictionary(
            selected.map { ($0.atomID, $0.recordID) },
            uniquingKeysWith: { first, _ in first }
        ))

        guard !selected.isEmpty else {
            return ContextCompiledProjectionResult(
                changedSources: [],
                removedSourceIDs: removed
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
            let texts = changed[offset..<end].map(\.body)
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
            removedSourceIDs: removed
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
        limits: NativeMemoryContextProjectionLimits
    ) -> [PreparedRecord] {
        let grouped = Dictionary(grouping: records, by: { normalizedID($0.id) })
        return grouped.keys.sorted().compactMap { key in
            guard !key.isEmpty,
                  let group = grouped[key],
                  group.count == 1 else {
                return nil
            }
            return prepare(group[0], limits: limits)
        }
    }

    static func prepare(
        _ record: NativeMemoryProjectionRecord,
        limits: NativeMemoryContextProjectionLimits
    ) -> PreparedRecord? {
        let recordID = normalizedID(record.id)
        guard !recordID.isEmpty,
              recordID.utf8.count <= 512,
              !containsDisallowedControl(recordID) else {
            return nil
        }

        let body = normalizedText(record.text)
        guard !body.isEmpty,
              body.utf8.count <= limits.maximumTextUTF8Bytes,
              !containsDisallowedControl(body),
              !ContextSecretContentPolicy.containsSecretLikeContent(body) else {
            return nil
        }
        guard MemoryCandidateQuality.isDurableCandidate(
            text: body,
            source: record.sourceRunId,
            kind: record.memoryKind
        ) else {
            return nil
        }

        guard let updatedAt = parseDate(record.updatedAt) ?? parseDate(record.createdAt) else {
            return nil
        }
        let tags = normalizedTags(record.tags, limits: limits)
        guard let provenance = provenanceText(record, limit: limits.maximumProvenanceUTF8Bytes) else {
            return nil
        }

        let correction = isCorrection(record, tags: tags)
        let pinned = record.pinned == true
        let authority: ContextAuthority = correction
            ? .explicitCorrection
            : (pinned ? .canonical : .inferred)
        let atomKind: ContextAtomKind = correction ? .correction : .memory
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
        entities.append(ContextEntity(
            kind: "memory_authority",
            id: correction ? "correction" : (pinned ? "pinned" : "adaptive"),
            label: correction ? "explicit correction" : (pinned ? "pinned memory" : "adaptive memory")
        ))
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
            tags.joined(separator: "\u{1f}"),
            provenance,
            record.validFrom ?? "",
            record.validTo ?? "",
            record.observedAt ?? "",
            canonicalJSONString(record.evidence) ?? "",
        ])

        return PreparedRecord(
            recordID: recordID,
            sourceID: sourceID,
            descriptor: descriptor,
            atomID: atomID,
            atomKind: atomKind,
            contentRole: .memory,
            body: body,
            sourceHash: sourceHash,
            authority: authority,
            confidence: confidence,
            freshness: ContextFreshness(updatedAt: updatedAt),
            tags: tags,
            entities: entities,
            importance: importance,
            sourceQuality: sourceQuality,
            decayState: decayState
        )
    }

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
                  !containsDisallowedControl(value) else {
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
            guard !containsDisallowedControl(source) else { return nil }
            components.append("source_run_id=\(source)")
        }
        if let provenance = record.provenance ?? objectValue(record.extras, key: "provenance") {
            guard let data = try? canonicalEncoder.encode(provenance),
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            components.append("provenance=\(value)")
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

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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

    static func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }

}

// Mind-into-circulation (2026-07-10): the attention translator
// (NativeContextFlowRuntime.memoryRecordAtomID) must mirror this projection's
// EXACT id pipeline or activation weights land on phantom atoms. These two
// internal forwards expose the private helpers to it without widening the
// whole private extension.
extension NativeMemoryContextProjection {
    static func normalizedRecordID(_ value: String) -> String {
        normalizedID(value)
    }
    static func recordIDContainsDisallowedControl(_ value: String) -> Bool {
        containsDisallowedControl(value)
    }
}
