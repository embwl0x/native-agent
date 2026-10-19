import Context
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore

private enum NativeMemoryContextProjectionLimits {
    static let maximumRecords = 2_000
    static let maximumTextUTF8Bytes = 16 * 1_024
    static let maximumEmbeddingBatchSize = 32
    static let maximumTagsPerRecord = 32
    static let maximumTagUTF8Bytes = 128
    static let maximumProvenanceUTF8Bytes = 2 * 1_024
}

enum NativeMemoryContextProjectionError: Error, Equatable, Sendable {
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
    private let memory: SwiftNativeMemoryV2
    private let provenanceIndex: MemoryAtomRecordIndex

    init(
        memory: SwiftNativeMemoryV2 = SwiftNativeMemoryV2.shared,
        provenanceIndex: MemoryAtomRecordIndex? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.memory = memory
        self.provenanceIndex = provenanceIndex ?? MemoryAtomRecordIndex()
        self.dataRoot = dataRoot
        self.invalidationSourceURL = dataRoot.appendingPathComponent("memory/memory.sqlite")
            .standardizedFileURL
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        let listed = try await memory.listMemory(kind: nil)
        let active = listed.filter(Self.isActive)
        let prepared = Self.prepareUnique(active, dataRoot: dataRoot)
            .sorted { $0.recordID < $1.recordID }
        let selected = Array(prepared.prefix(NativeMemoryContextProjectionLimits.maximumRecords))
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

        guard let epoch = await memory.embeddingEpoch() else {
            throw MemoryV2Error.storageUnavailable
        }
        let modelFingerprint = epoch.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelFingerprint.isEmpty else {
            throw NativeMemoryContextProjectionError.invalidModelFingerprint
        }

        // Unchanged words keep their vector; a source whose descriptor moved
        // (its locator now carries the record id) republishes with that vector.
        var redescribed: [ContextCompiledSource] = []
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
            if previous.descriptor != item.descriptor { redescribed.append(item.compiledSource(embedding: embedding)) }
            return false
        }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(changed.count)
        var offset = 0
        while offset < changed.count {
            let end = min(offset + NativeMemoryContextProjectionLimits.maximumEmbeddingBatchSize, changed.count)
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
            changedSources: changedSources + redescribed,
            removedSourceIDs: removed,
            atomRecordIDs: atomRecordIDs
        )
    }

    /// The body never speaks a memory the database says is gone or tightened:
    /// the chosen atoms' records are read by id, and any retired, newer than
    /// the version compiled, or not disclosed on this surface is dropped.
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion {
        let locators = Dictionary(generation.sources.lazy.filter { $0.descriptor.owner == Self.owner }
            .map { ($0.descriptor.id, $0.descriptor.canonicalLocator) }, uniquingKeysWith: { first, _ in first })
        let atoms = chosen.compactMap { atom in
            locators[atom.draft.sourceID].map { (atom, Self.recordID(inLocator: $0)) }
        }
        guard !atoms.isEmpty else { return ContextTurnExclusion() }
        do {
            let records = try await memory.memoryRecords(ids: atoms.compactMap(\.1))
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let dropped = atoms.filter { atom, recordID in
                !Self.speakable(recordID.flatMap { byID[$0] }, compiledAt: atom.draft.freshness.updatedAt, on: surface)
            }
            let pending = dropped.filter { $0.1.flatMap { byID[$0] }.map(Self.pendingAdmission) == true }
            return ContextTurnExclusion(atomIDs: Set(dropped.map(\.0.draft.id)), unverified: pending.map {
                ContextDegradedSourceNotice(sourceID: $0.0.draft.sourceID, reason: "saved; its check is pending")
            })
        } catch {
            return ContextTurnExclusion(atomIDs: Set(atoms.map(\.0.draft.id)), unverified: [ContextDegradedSourceNotice(
                sourceID: ContextStableID.source(owner: Self.owner, locator: "memory-v2"),
                reason: "memories withheld this turn: the memory store could not confirm them (\(error.localizedDescription))")])
        }
    }

    /// Active, recall-eligible, no newer than what was compiled, and disclosed here.
    static func speakable(_ record: MemoryRecord?, compiledAt: Date, on surface: ContextSurface) -> Bool {
        guard let record, isActive(record), !pendingAdmission(record), MemoryLifecycle.isRecallEligible(record.lifecycle),
              let version = parseDate(record.updatedAt) ?? parseDate(record.createdAt),
              version.timeIntervalSince(compiledAt) <= 0.001,
              MemoryRecordDisclosurePolicy.classify(record)?.permits(surface: surface.rawValue, personaID: nil) == true
        else { return false }
        return true
    }

    static func pendingAdmission(_ record: MemoryRecord) -> Bool {
        guard case .object(let extras)? = record.extras else { return false }
        return extras[MemoryStorage.pendingAdmissionKey] == .bool(true)
    }

    /// The record id the locator carries; nil for one compiled before it did.
    static func recordID(inLocator locator: String) -> String? {
        guard let range = locator.range(of: "/records/id:") else { return nil }
        return String(locator[range.upperBound...])
    }

    func didPublish(
        _ result: ContextCompiledProjectionResult?,
        generation: ContextStoredGeneration,
        retaining generationIDs: Set<Int64>
    ) {
        provenanceIndex.publish(
            result?.atomRecordIDs,
            generationID: generation.generation.id,
            liveAtomIDs: Set(generation.atoms.lazy
                .filter { $0.validToGeneration == nil }
                .map(\.draft.id)),
            retaining: generationIDs
        )
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
        _ records: [MemoryRecord],
        dataRoot: URL
    ) -> [PreparedRecord] {
        let grouped = Dictionary(grouping: records, by: { normalizedID($0.id) })
        return grouped.keys.sorted().compactMap { key in
            guard !key.isEmpty,
                  let group = grouped[key],
                  group.count == 1 else {
                return nil
            }
            return prepare(group[0], dataRoot: dataRoot)
        }
    }

    static func prepare(
        _ record: MemoryRecord,
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
              embeddingText.utf8.count <= NativeMemoryContextProjectionLimits.maximumTextUTF8Bytes,
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
        let tags = normalizedTags(record.tags)
        guard let provenance = provenanceText(record, limit: NativeMemoryContextProjectionLimits.maximumProvenanceUTF8Bytes) else {
            return nil
        }
        let body = presentationBody(
            embeddingText, record: record, maximumUTF8Bytes: NativeMemoryContextProjectionLimits.maximumTextUTF8Bytes
        )

        let correction = isCorrection(record, tags: tags)
        let pinned = record.pinned == true
        let authority: ContextAuthority = correction
            ? .explicitCorrection
            : (pinned ? .canonical : .inferred)
        let atomKind: ContextAtomKind = correction ? .correction : .memory
        // Phase 5 C3: what happened between them rides its own lane.
        let personal = !correction && Self.personalKinds.contains(
            (record.memoryKind ?? MemoryRecallScoring.kind(of: record.extras) ?? "").lowercased())
        let contentRole: ContextContentRole = personal ? .personal : .memory
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
        // The record id rides the locator, so a turn can read the record back.
        let locator = "memory-v2/\(personaScope)/records/id:\(recordID)"
        // Keep record/atom identity stable when disclosure scope changes:
        // the locator carries persona scope, the source identity does not.
        let sourceID = ContextStableID.source(owner: owner, locator: "memory-v2/records/\(locatorDigest)")
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

    static func isActive(_ record: MemoryRecord) -> Bool {
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

    static func normalizedTags(_ values: [String]?) -> [String] {
        let valid = (values ?? []).compactMap { raw -> String? in
            let value = raw.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !value.isEmpty,
                  value.utf8.count <= NativeMemoryContextProjectionLimits.maximumTagUTF8Bytes,
                  !NativeContextProjectionText.containsDisallowedControl(value) else {
                return nil
            }
            return value
        }
        return Array(Set(valid).sorted().prefix(NativeMemoryContextProjectionLimits.maximumTagsPerRecord))
    }

    static func isCorrection(_ record: MemoryRecord, tags: [String]) -> Bool {
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

    static func provenanceText(_ record: MemoryRecord, limit: Int) -> String? {
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
        _ text: String, record: MemoryRecord, maximumUTF8Bytes: Int
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
