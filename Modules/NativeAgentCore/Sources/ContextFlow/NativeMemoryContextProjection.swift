import Context
import Foundation
import NativeAgentShared
import MemoryV2
import PersistenceCore
// Blueprint: | `NativeMemoryContextProjection.swift` | `MemoryContext`: canonical memory projection, including immutable untrusted-source entities and source hashes |

private enum NativeMemoryContextProjectionLimits {
    static let maximumRecords = memoryStoredRowCap
    static let maximumTextUTF8Bytes = 16 * 1_024
    static let maximumTagsPerRecord = 32
    static let maximumTagUTF8Bytes = 128
}

/// Attention's record-to-atom lookup for the current accepted generation.
public final class MemoryAtomRecordIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var recordToAtom: [String: ContextAtomID] = [:]

    func publish(_ generation: ContextStoredGeneration) {
        let records = Dictionary(generation.sources.compactMap { source -> (ContextSourceID, String)? in
            guard source.descriptor.owner == MemoryContext.owner,
                  let recordID = MemoryContext.recordID(inLocator: source.descriptor.canonicalLocator) else { return nil }
            return (source.descriptor.id, recordID)
        }, uniquingKeysWith: { first, _ in first })
        let mapping = Dictionary(generation.atoms.compactMap { atom -> (String, ContextAtomID)? in
            guard atom.validToGeneration == nil, let recordID = records[atom.draft.sourceID] else { return nil }
            return (recordID, atom.draft.id)
        }, uniquingKeysWith: { first, _ in first })
        lock.withLock {
            recordToAtom = mapping
        }
    }

    func atomID(forRecordID recordID: String) -> ContextAtomID? {
        let normalized = MemoryContext.normalizedRecordID(recordID)
        return lock.withLock { recordToAtom[normalized] }
    }

    var count: Int {
        lock.withLock { recordToAtom.count }
    }
}

struct MemoryContext: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.memory-v2"

    var projectionIdentifier: String { Self.owner }
    var invalidationNamespaces: Set<String> { ["memory-v2"] }
    let invalidationSourceURL: URL?
    private let dataRoot: URL

    // Creation time is separate from update freshness for memory age tags.
    private static let schemaVersion = "memory-context-projection-v6"
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
        guard let storage = await memory.underlyingStorage() else { throw MemoryV2Error.storageUnavailable }
        let listed = try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { MemoryLifecycle.isRecallEligible($0.lifecycle) }
        let prepared = try Self.prepareUnique(listed, dataRoot: dataRoot)
        let selected = Array(prepared.sources.prefix(NativeMemoryContextProjectionLimits.maximumRecords))
        let selectedIDs = Set(selected.map(\.descriptor.id))
        let previousOwnedIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == Self.owner }
            .map(\.descriptor.id))
        let removed = previousOwnedIDs.subtracting(selectedIDs).subtracting(prepared.failures.keys)

        let changedSources = selected.compactMap { item -> ContextCompiledSource? in
            if let previous = previousSources[item.descriptor.id],
               previous.sourceHash == item.sourceHash,
               previous.descriptor == item.descriptor,
               previous.atoms.count == 1, previous.atoms[0].embedding == item.atoms[0].embedding { return nil }
            return item
        }
        return ContextCompiledProjectionResult(
            changedSources: changedSources,
            removedSourceIDs: removed,
            sourceFailures: prepared.failures, verifiedSources: selected
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
            let invalidDates = dropped.filter { _, id in
                guard let id, let record = byID[id] else { return false }
                return Self.parseDate(record.updatedAt) == nil || Self.parseDate(record.createdAt) == nil
            }
            let pending = dropped.filter { $0.1.flatMap { byID[$0] }.map(Self.pendingAdmission) == true }
            return ContextTurnExclusion(atomIDs: Set(dropped.map(\.0.draft.id)), unverified: pending.map {
                ContextDegradedSourceNotice(sourceID: $0.0.draft.sourceID, reason: "saved; its check is pending")
            } + invalidDates.map {
                ContextDegradedSourceNotice(sourceID: $0.0.draft.sourceID, reason: "memory source dates unavailable; repair the canonical record")
            })
        } catch {
            return ContextTurnExclusion(atomIDs: Set(atoms.map(\.0.draft.id)), unverified: [ContextDegradedSourceNotice(
                sourceID: ContextStableID.source(owner: Self.owner, locator: "memory-v2"),
                reason: "memories withheld this turn: the memory store could not confirm them (\(error.localizedDescription))")])
        }
    }

    /// Active, recall-eligible, no newer than what was compiled, and disclosed here.
    static func speakable(_ record: MemoryV2.MemoryRecord?, compiledAt: Date, on surface: ContextSurface) -> Bool {
        guard let record, parseDate(record.createdAt) != nil, isActive(record), !pendingAdmission(record), MemoryLifecycle.isRecallEligible(record.lifecycle),
              let version = parseDate(record.updatedAt),
              version.timeIntervalSince(compiledAt) <= 0.001,
              MemoryRecordDisclosurePolicy.classify(record)?.permits(surface: surface.rawValue, personaID: nil) == true
        else { return false }
        return true
    }

    static func pendingAdmission(_ record: MemoryV2.MemoryRecord) -> Bool {
        guard case .object(let extras)? = record.extras else { return false }
        return extras[MemoryStorage.pendingAdmissionKey] == .bool(true)
    }

    /// The record id the locator carries; nil for one compiled before it did.
    static func recordID(inLocator locator: String) -> String? {
        guard let range = locator.range(of: "/records/id:") else { return nil }
        return String(locator[range.upperBound...])
    }

    func didPublish(generation: ContextStoredGeneration) {
        provenanceIndex.publish(generation)
    }
}

private extension MemoryContext {
    static func prepareUnique(
        _ records: [StoredMemory],
        dataRoot: URL
    ) throws -> (sources: [ContextCompiledSource], failures: [ContextSourceID: String]) {
        let grouped = Dictionary(grouping: records, by: { normalizedID($0.id) })
        var sources: [ContextCompiledSource] = []
        var failures: [ContextSourceID: String] = [:]
        for key in grouped.keys.sorted() {
            guard !key.isEmpty, let group = grouped[key], group.count == 1 else { continue }
            do {
                if let source = try prepare(group[0], dataRoot: dataRoot) { sources.append(source) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                let id = ContextStableID.source(owner: owner,
                    locator: "memory-v2/records/\(ContextStableID.digest(parts: [key]))")
                failures[id] = "Memory projection unavailable: \(error.localizedDescription)"
            }
        }
        return (sources, failures)
    }

    static func prepare(
        _ stored: StoredMemory,
        dataRoot: URL
    ) throws -> ContextCompiledSource? {
        let record = MemoryV2.MemoryRecord(stored: stored)
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

        let updatedAt = try NativeContextProjectionText.requiredDate(record.updatedAt, owner: "memory \(recordID) updatedAt")
        let createdAt = try NativeContextProjectionText.requiredDate(record.createdAt, owner: "memory \(recordID) createdAt")
        let tags = normalizedTags(record.tags)
        let provenance = try Self.provenance(record)
        let provenanceJSON = try String(decoding: canonicalEncoder.encode(provenance), as: UTF8.self)
        let body = presentationBody(
            embeddingText, record: record, maximumUTF8Bytes: NativeMemoryContextProjectionLimits.maximumTextUTF8Bytes
        )

        let correction = MemoryRecallScoring.isCorrection(record, tags: tags)
        let pinned = record.pinned == true
        let authority: ContextAuthority = correction
            ? .explicitCorrection
            : (pinned ? .canonical : .inferred)
        let atomKind: ContextAtomKind = correction ? .correction : .memory
        // What happened between them is marked as personal.
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
        if case .array(let values)? = record.extras?.objectValue?["context_topics"] {
            // Identity is read from this projection's injected root, through
            // the profile cache that observes renames, never a default install.
            let names = try MemoryRecallQueryExpansion.names(storeDirectory: dataRoot.appendingPathComponent("memory"))
            func topicKey(_ text: String) -> String {
                text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
            }
            let identities = Set([names.agent, names.user].compactMap { $0 }.map(topicKey))
            for case .string(let topic) in values.prefix(8) {
                let clean = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 120, !identities.contains(topicKey(clean)) else { continue }
                entities.append(ContextEntity(
                    kind: ContextCorrectionScope.entityKind,
                    id: ContextStableID.digest(parts: [clean.lowercased()]),
                    label: clean
                ))
            }
        }
        let confidence = finite(record.confidence) ?? 1
        let importance = finite(record.importance) ?? 0
        // Canonical SQLite supplies no learned decay seed; feedback owns adaptation.
        let decayState: Double = 1
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
            String(decayState.bitPattern),
            String(updatedAt.timeIntervalSince1970.bitPattern),
            String(createdAt.timeIntervalSince1970.bitPattern),
            tags.joined(separator: "\u{1f}"),
            provenanceJSON,
            record.validFrom ?? "",
            record.validTo ?? "",
            record.observedAt ?? "",
            canonicalJSONString(record.evidence) ?? "",
            canonicalJSONString(record.extras?.objectValue?["context_topics"]) ?? "",
            entities.filter { $0.kind == ContextCorrectionScope.entityKind }.map(\.label).joined(separator: "\u{1f}"),
            canonicalJSONString(.object(MemoryDataProvenance.fields(in: record.extras, dataRoot: dataRoot))) ?? "",
        ] + (body == embeddingText ? [] : [embeddingText]))

        // Canonical saves and epoch convergence own the vector; metadata
        // changes can republish an atom without predicting its words again.
        let embedding: ContextEmbedding?
        if let epoch = stored.embeddingEpoch, !epoch.isEmpty,
           let vector = stored.embedding, !vector.isEmpty, vector.allSatisfy(\.isFinite) {
            embedding = ContextEmbedding(modelFingerprint: epoch, values: vector)
        } else {
            embedding = nil
        }
        let atom = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: atomKind,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            authority: authority,
            confidence: confidence,
            // A closed truth interval expires the atom from automatic context.
            freshness: ContextFreshness(updatedAt: updatedAt, expiresAt: parseDate(record.validTo), createdAt: createdAt),
            privacy: descriptor.privacy,
            permittedSurfaces: descriptor.permittedSurfaces,
            injectionPolicy: .adaptive,
            contentRole: contentRole,
            entities: entities,
            memoryProvenance: provenance,
            triggers: tags,
            activation: importance,
            recentUsefulness: 0,
            decayState: decayState,
            embedding: embedding
        )
        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: [atom]
        )
    }

    /// Memory kinds that are what happened between them: marked
    /// `.personal`; they compete in the one memory lane like any memory. A
    /// kept moment from the retired lane is an ordinary memory: what moved her
    /// lives in her cares.
    static let personalKinds: Set<String> = ["relationship", "lesson_origin"]

    static func isActive(_ record: MemoryV2.MemoryRecord) -> Bool {
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

    static func provenance(_ record: MemoryV2.MemoryRecord) throws -> ContextMemoryProvenance? {
        guard let value = record.extras?.objectValue?["provenance"] else { return nil }
        guard case .string(let raw) = value,
              let kind = ContextMemoryProvenance.Kind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw ContextFlowStoreError.malformedStoredValue("memory \(record.id) provenance")
        }
        let by = record.extras?.objectValue?["provenance_by"]?.stringValue.flatMap(ContextMemoryLead.validDisplayName)
        return ContextMemoryProvenance(kind: kind, by: by)
    }

    /// Dates are presentation evidence, not vector input; `valid_to` also
    /// expires the atom (`prepare`).
    /// Prefix them so the existing bounded context_expand prefix also retains
    /// them. Reserve their bytes inside the existing body cap, never above it.
    static func presentationBody(
        _ text: String, record: MemoryV2.MemoryRecord, maximumUTF8Bytes: Int
    ) -> String {
        let warning = MemorySenseProvenance.warning(in: record.extras)
        // Days, said once: the block's own note already says these are records,
        // not live readings, so each memory carries only its dates (10-29: the
        // long per-memory label was a third of the memory block).
        func day(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), value.utf8.count <= 64,
                  !NativeContextProjectionText.containsDisallowedControl(value), parseDate(value) != nil else { return nil }
            return String(value.prefix(10))
        }
        let from = day(record.validFrom), until = day(record.validTo), observed = day(record.observedAt)
        let fields = [
            from.map { "from " + $0 },
            until.map { "until " + $0 },
            observed.flatMap { $0 == from ? nil : "observed " + $0 },
        ].compactMap { $0 }
        guard !fields.isEmpty || warning != nil else { return text }
        let prefix = MemorySenseProvenance.presentation("", metadata: record.extras)
            + (fields.isEmpty ? "" : "[" + fields.joined(separator: ", ") + "]\n")
        let prefixBytes = prefix.utf8.count
        guard maximumUTF8Bytes >= prefixBytes else { return text }
        if text.utf8.count <= maximumUTF8Bytes - prefixBytes {
            return prefix + text
        }
        let suffix = "\n[Excerpt; full_content_chars=\(text.count)]"
        let afterPrefix = maximumUTF8Bytes - prefixBytes
        guard afterPrefix > suffix.utf8.count else { return text }
        let available = afterPrefix - suffix.utf8.count
        // A custom tiny budget must not discard the canonical fact merely
        // because a complete date label cannot fit. Standard budget is 16 KiB.
        guard available > 0 else { return text }
        var excerpt = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard size <= available - bytes else { break }
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


}

// Record lookup uses the projection's canonical identity normalization.
extension MemoryContext {
    static func normalizedRecordID(_ value: String) -> String {
        normalizedID(value)
    }

    /// Shared by the knowledge-graph projection too; trims projection input.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }
}
