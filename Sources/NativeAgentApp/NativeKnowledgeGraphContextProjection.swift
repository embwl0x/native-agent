import Context
import Foundation
import KnowledgeGraph
import MemoryV2
import PersistenceCore

/// The knowledge graph, made REACHABLE instead of dark.
///
/// Before this projection the graph had exactly one prompt path: the legacy
/// recall lane's `related:` garnish, which needs a non-empty `ctx.recalled` —
/// and an active ContextFlow turn leaves that empty by design. 663 entities and
/// their typed edges therefore never reached a live turn.
///
/// The fix is clause 6, not clause 6's opposite: relations become first-class
/// SELECTABLE atoms in the resident index, ranked by the same lexical/semantic
/// selector as everything else, and pulled only when the message actually
/// touches them. Nothing here is injected unconditionally — the atoms are
/// `.adaptive`, they carry no `always` policy, and the `.relationship` kind cap
/// in `ContextSelectionConfiguration` bounds how much of a packet they can ever
/// take.
///
/// ── BOUNDS ───────────────────────────────────────────────────────────────────
/// Three caps, all applied before anything is published:
///   - per subject entity (`maximumRelationsPerEntity`), so the hub entity User
///     touches most of the graph and cannot flood the index;
///   - total (`maximumRelations`);
///   - body shape: one short "A —works_on→ B" line, never a relation body.
///
/// ── FAILURE ──────────────────────────────────────────────────────────────────
/// A missing graph is an empty graph. An unreadable one keeps the last good
/// relations (no changes, no removals) and says so in the log — a garnish must
/// never be able to fail the whole context generation that also carries
/// persona, memory and resident work.
struct NativeKnowledgeGraphContextProjection: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.knowledge-graph"
    static let schemaVersion = "knowledge-graph-context-projection-v1"
    static let maximumRelations = 192
    static let maximumRelationsPerEntity = 4

    /// Same tier the memory lane defaults to for a `local_private` record:
    /// User's authenticated personal surfaces, never Slack.
    static let surfaces: Set<ContextSurface> = Set(
        MemoryRecordDisclosurePolicy.localPrivateSurfaces.map(ContextSurface.init(rawValue:))
    )

    var projectionIdentifier: String { Self.owner }
    /// The graph lives inside memory.sqlite and is written on memory writes, so
    /// it invalidates on exactly the signal the memory projection uses.
    var invalidationNamespaces: Set<String> { ["memory-v2"] }
    let invalidationSourceURL: URL?

    private let loadRelations: @Sendable () async throws -> [KnowledgeGraphContextRelation]
    private let diagnostics: @Sendable (String) -> Void

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        maximumRelations: Int = NativeKnowledgeGraphContextProjection.maximumRelations,
        maximumRelationsPerEntity: Int =
            NativeKnowledgeGraphContextProjection.maximumRelationsPerEntity,
        loadRelations: (@Sendable () async throws -> [KnowledgeGraphContextRelation])? = nil,
        diagnostics: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }
    ) {
        let sqlite = dataRoot.appendingPathComponent("memory/memory.sqlite").standardizedFileURL
        self.invalidationSourceURL = sqlite
        self.diagnostics = diagnostics
        let total = max(0, maximumRelations)
        let perEntity = max(1, maximumRelationsPerEntity)
        self.loadRelations = loadRelations ?? {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
            return try await indexer.contextRelations(
                perSubjectLimit: perEntity,
                maximumRelations: total
            )
        }
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        let relations: [KnowledgeGraphContextRelation]
        do {
            relations = try await loadRelations()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Last known good: publish nothing, retire nothing.
            diagnostics("[context-kg] relation read failed: \(String(describing: error))")
            return ContextCompiledProjectionResult(changedSources: [], removedSourceIDs: [])
        }

        let prepared = Self.prepare(relations)
        let selectedIDs = Set(prepared.map(\.sourceID))
        let previousOwnedIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == Self.owner }
            .map(\.descriptor.id))
        let changed = prepared.compactMap { item -> ContextCompiledSource? in
            guard previousSources[item.sourceID]?.sourceHash != item.sourceHash else {
                return nil
            }
            return item.compiledSource
        }
        return ContextCompiledProjectionResult(
            changedSources: changed,
            removedSourceIDs: previousOwnedIDs.subtracting(selectedIDs)
        )
    }
}

extension NativeKnowledgeGraphContextProjection {
    struct Prepared: Sendable {
        let sourceID: ContextSourceID
        let sourceHash: String
        let compiledSource: ContextCompiledSource
    }

    /// One source per subject entity, one atom per edge. Grouping this way lets
    /// the selector's existing `maximumAtomsPerSource` bound keep a single
    /// entity from owning the whole relationship budget of one packet.
    static func prepare(_ relations: [KnowledgeGraphContextRelation]) -> [Prepared] {
        let usable = relations.filter { relation in
            let body = self.body(relation)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !containsDisallowedControl(body)
                && !ContextSecretContentPolicy.containsSecretLikeContent(body)
        }
        let grouped = Dictionary(grouping: usable, by: \.subjectID)
        return grouped.keys.sorted().compactMap { subjectID -> Prepared? in
            guard let edges = grouped[subjectID], !edges.isEmpty else { return nil }
            let locatorDigest = ContextStableID.digest(parts: [subjectID])
            let locator = "knowledge-graph/entities/\(locatorDigest)"
            let sourceID = ContextStableID.source(owner: owner, locator: locator)
            let ordered = edges.sorted {
                if $0.predicate != $1.predicate { return $0.predicate < $1.predicate }
                if $0.object != $1.object { return $0.object < $1.object }
                return $0.objectID < $1.objectID
            }
            let sourceHash = ContextStableID.digest(parts: [schemaVersion] + ordered.map {
                [self.body($0), $0.objectID, String($0.weight.bitPattern),
                 String($0.mentionCount), $0.lastSeen ?? ""].joined(separator: "\u{1f}")
            })
            let descriptor = ContextSourceDescriptor(
                id: sourceID,
                owner: owner,
                kind: .other,
                canonicalLocator: locator,
                authority: .inferred,
                privacy: .localPrivate,
                permittedSurfaces: surfaces,
                injectionPolicy: .adaptive
            )
            let atoms = ordered.map { relation in
                atom(relation, sourceID: sourceID, sourceHash: sourceHash)
            }
            return Prepared(
                sourceID: sourceID,
                sourceHash: sourceHash,
                compiledSource: ContextCompiledSource(
                    descriptor: descriptor,
                    sourceHash: sourceHash,
                    atoms: atoms
                )
            )
        }
    }

    /// The whole atom body. A relation is a pointer to structure, not a
    /// document: anything longer would be a second memory block wearing the
    /// graph's name.
    static func body(_ relation: KnowledgeGraphContextRelation) -> String {
        let subject = clean(relation.subject)
        let predicate = clean(relation.predicate)
        let object = clean(relation.object)
        guard !subject.isEmpty, !predicate.isEmpty, !object.isEmpty else { return "" }
        return "\(bounded(subject, to: 120)) —\(bounded(predicate, to: 60))→ "
            + bounded(object, to: 120)
    }

    static func atom(
        _ relation: KnowledgeGraphContextRelation,
        sourceID: ContextSourceID,
        sourceHash: String
    ) -> ContextAtomDraft {
        let body = self.body(relation)
        let edgeDigest = ContextStableID.digest(parts: [relation.predicate, relation.objectID])
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .relationship,
            headingPath: [],
            blockAnchor: "kg-relation-" + edgeDigest
        )
        // ONLY the two endpoints are selection keys, and they carry the kind
        // `ContextCorrectionScope.relationshipEntityKind` — which is also what
        // gates ELIGIBILITY, so an edge whose endpoints this message never
        // named is excluded outright rather than left to rank low. The
        // predicate is what the atom SAYS, never how it is found: admitting it
        // here (or as a trigger) would let a generic "who owns what?" pull
        // unrelated edges, which is prompt mass wearing reach's name.
        let entities = [
            ContextEntity(
                kind: ContextCorrectionScope.relationshipEntityKind,
                id: relation.subjectID,
                label: clean(relation.subject)
            ),
            ContextEntity(
                kind: ContextCorrectionScope.relationshipEntityKind,
                id: relation.objectID,
                label: clean(relation.object)
            ),
        ]
        return ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .relationship,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            authority: .inferred,
            confidence: min(1, max(0, relation.weight)),
            freshness: ContextFreshness(updatedAt: parseDate(relation.lastSeen) ?? .distantPast),
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: entities,
            triggers: triggers(relation),
            activation: 0,
            recentUsefulness: 0,
            decayState: 1,
            embedding: nil
        )
    }

    /// Endpoint names only — see the note on `entities`. The predicate is
    /// deliberately absent.
    static func triggers(_ relation: KnowledgeGraphContextRelation) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        let text = [relation.subject, relation.object].joined(separator: " ")
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(token)
            guard value.count >= 2, seen.insert(value).inserted else { continue }
            values.append(bounded(value, to: 64))
            if values.count == 12 { break }
        }
        return values
    }

    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func bounded(_ value: String, to maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum))
    }

    static func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
