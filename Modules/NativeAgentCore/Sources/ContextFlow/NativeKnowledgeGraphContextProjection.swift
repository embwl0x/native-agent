import Context
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `NativeKnowledgeGraphContextProjection.swift` | `KnowledgeGraphContext`: rebuildable graph atoms, support and triggers with canonical-source verification |

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
struct KnowledgeGraphContext: ContextCompiledProjectionProvider, Sendable {
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
    var invalidationSourceURL: URL? { sqlite }
    private let sqlite: URL

    private let dataRoot: URL

    var excludedSourceOwners: Set<String> {
        MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) ? [] : [Self.owner]
    }

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.sqlite = dataRoot.appendingPathComponent("memory/memory.sqlite").standardizedFileURL
        self.dataRoot = dataRoot
    }

    /// A chosen edge is spoken only while the memory that last asserted it
    /// is active, unchanged since compile, and disclosed on this surface; the
    /// supporting records are read by id with the memory atoms' own rule.
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion {
        let owned = Set(generation.sources.lazy.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
        let relations = chosen.filter { owned.contains($0.draft.sourceID) }
        // Compiled before relations recorded their support: unknowable here,
        // so they wait for the rebuild to republish them.
        let legacy = relations.filter { atom in !atom.draft.entities.contains { $0.kind == Self.supportKind } }
        var exclusion = ContextTurnExclusion(atomIDs: Set(legacy.map(\.draft.id)), unverified: legacy.isEmpty ? [] : [
            ContextDegradedSourceNotice(sourceID: ContextStableID.source(owner: Self.owner, locator: "knowledge-graph"),
                                        reason: "graph relations compiled by an earlier build wait for the graph rebuild")])
        let supported = relations.compactMap { atom -> (ContextStoredAtom, String, Date)? in
            guard let support = atom.draft.entities.first(where: { $0.kind == Self.supportKind }),
                  support.id != "none", let at = support.id.lastIndex(of: "@") else { return nil }
            return (atom, String(support.id[..<at]),
                    MemoryContext.parseDate(String(support.id[support.id.index(after: at)...])) ?? .distantPast)
        }
        guard !supported.isEmpty else { return exclusion }
        do {
            let records = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).memoryRecords(ids: supported.map(\.1))
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            exclusion.atomIDs.formUnion(supported.lazy.filter { _, id, compiled in
                !MemoryContext.speakable(byID[id], compiledAt: compiled, on: surface)
            }.map(\.0.draft.id))
        } catch {
            exclusion.atomIDs.formUnion(supported.map(\.0.draft.id))
            exclusion.unverified.append(ContextDegradedSourceNotice(
                sourceID: ContextStableID.source(owner: Self.owner, locator: "knowledge-graph"),
                reason: "graph relations withheld this turn: their memories could not be confirmed (\(error.localizedDescription))"))
        }
        return exclusion
    }

    /// The edge's supporting memory, `id@version`, carried in every atom;
    /// `none` marks a relation no memory asserted.
    static let supportKind = "supporting_memory"

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        guard MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) else {
            return ContextCompiledProjectionResult(
                owner: Self.owner, currentSources: [], previousSources: previousSources
            )
        }
        let relations: [KnowledgeGraphContextRelation]
        do {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
            relations = try await indexer.contextRelations(
                perSubjectLimit: Self.maximumRelationsPerEntity,
                maximumRelations: Self.maximumRelations
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Last known good: publish nothing, retire nothing.
            nativeLog("%@", "[context-kg] relation read failed: \(String(describing: error))")
            return ContextCompiledProjectionResult(changedSources: [], removedSourceIDs: [])
        }

        return ContextCompiledProjectionResult(
            owner: Self.owner, currentSources: Self.prepare(relations), previousSources: previousSources
        )
    }
}

extension KnowledgeGraphContext {
    /// One source per subject entity, one atom per edge. Grouping this way lets
    /// the selector's existing `maximumAtomsPerSource` bound keep a single
    /// entity from owning the whole relationship budget of one packet.
    static func prepare(_ relations: [KnowledgeGraphContextRelation]) -> [ContextCompiledSource] {
        let usable = relations.filter { relation in
            let body = self.body(relation)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !NativeContextProjectionText.containsDisallowedControl(body)
                && !ContextSecretContentPolicy.containsSecretLikeContent(body)
        }
        let grouped = Dictionary(grouping: usable, by: \.subjectID)
        return grouped.keys.sorted().compactMap { subjectID -> ContextCompiledSource? in
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
                 String($0.mentionCount), $0.lastSeen ?? "", Self.support($0)].joined(separator: "\u{1f}")
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
            return ContextCompiledSource(
                descriptor: descriptor,
                sourceHash: sourceHash,
                atoms: atoms
            )
        }
    }

    /// The whole atom body. A relation is a pointer to structure, not a
    /// document: anything longer would be a second memory block wearing the
    /// graph's name.
    static func body(_ relation: KnowledgeGraphContextRelation) -> String {
        let subject = NativeContextProjectionText.clean(relation.subject)
        let predicate = NativeContextProjectionText.clean(relation.predicate)
        let object = NativeContextProjectionText.clean(relation.object)
        guard !subject.isEmpty, !predicate.isEmpty, !object.isEmpty else { return "" }
        return "\(NativeContextProjectionText.bounded(subject, to: 120)) —\(NativeContextProjectionText.bounded(predicate, to: 60))→ "
            + NativeContextProjectionText.bounded(object, to: 120)
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
        let entities = [ContextEntity(kind: supportKind, id: Self.support(relation), label: "")] + [
            ContextEntity(
                kind: ContextCorrectionScope.relationshipEntityKind,
                id: relation.subjectID,
                label: NativeContextProjectionText.clean(relation.subject)
            ),
            ContextEntity(
                kind: ContextCorrectionScope.relationshipEntityKind,
                id: relation.objectID,
                label: NativeContextProjectionText.clean(relation.object)
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
            freshness: ContextFreshness(updatedAt: MemoryContext.parseDate(relation.lastSeen) ?? .distantPast),
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

    static func support(_ relation: KnowledgeGraphContextRelation) -> String {
        relation.memoryID.map { $0 + "@" + (relation.memoryVersion ?? "") } ?? "none"
    }

    /// Endpoint names only — see the note on `entities`. The predicate is
    /// deliberately absent.
    static func triggers(_ relation: KnowledgeGraphContextRelation) -> [String] {
        let text = [relation.subject, relation.object].joined(separator: " ")
        return NativeContextProjectionText.triggers(text)
    }
}
