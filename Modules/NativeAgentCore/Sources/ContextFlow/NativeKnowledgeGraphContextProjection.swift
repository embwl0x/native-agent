import Context
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `NativeKnowledgeGraphContextProjection.swift` | `KnowledgeGraphContext`: bounded selectable graph atoms; canonical verification |

/// Keep relations selectable rather than always injected; adaptive policy and the relationship cap bound packet mass. Per-entity and total caps prevent hub
/// entities from flooding the index; bodies stay short pointers to structure. An unreadable graph retains rebuild inputs but withholds unverified relations,
/// leaving other context sources available. A missing graph starts empty; an unreadable graph cannot fail unrelated persona, memory or work context.
struct KnowledgeGraphContext: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.knowledge-graph"
    static let schemaVersion = "knowledge-graph-context-projection-v1"
    static let maximumRelations = 192
    static let maximumRelationsPerEntity = 4

    /// Personal-surface disclosure keeps local-private graph relations off Slack.
    static let surfaces: Set<ContextSurface> = Set(
        MemoryRecordDisclosurePolicy.localPrivateSurfaces.map(ContextSurface.init(rawValue:))
    )

    var projectionIdentifier: String { Self.owner }
    /// Facts and profile identity both determine the memory-derived graph.
    var invalidationNamespaces: Set<String> { ["memory-v2", "persona"] }
    var invalidationSourceURL: URL? { sqlite }
    private let sqlite: URL

    private let dataRoot: URL

    func isInvalidated(by change: DerivedSourceChange) -> Bool {
        guard change.semantic, invalidationNamespaces.contains(change.namespace),
              let locator = change.canonicalLocator else { return false }
        let expected = change.namespace == "persona"
            ? dataRoot.appendingPathComponent("memory/profile.json") : sqlite
        return expected.standardizedFileURL == URL(fileURLWithPath: locator).standardizedFileURL
    }

    var excludedSourceOwners: Set<String> {
        MemoryPolicyGate.knowledgeGraphFailure(dataRoot: dataRoot) == nil ? [] : [Self.owner]
    }

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.sqlite = dataRoot.appendingPathComponent("memory/memory.sqlite").standardizedFileURL
        self.dataRoot = dataRoot
    }

    /// Speak an edge only while its supporting memory is active, unchanged since compilation and disclosed on this surface.
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion {
        let owned = Set(generation.sources.lazy.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
        let relations = chosen.filter { owned.contains($0.draft.sourceID) }
        guard !relations.isEmpty else { return ContextTurnExclusion() }
        // Supporting memories cannot prove the graph is readable; selection and expansion must reread its canonical owner.
        let current: (sources: [ContextCompiledSource], failures: [ContextSourceID: String])
        do { current = Self.prepare(try await readRelations()) }
        catch {
            return ContextTurnExclusion(atomIDs: Set(relations.map(\.draft.id)), unverified:
                Set(relations.map(\.draft.sourceID)).sorted().map {
                    ContextDegradedSourceNotice(sourceID: $0, reason: "Knowledge graph source unavailable: \(error.localizedDescription)")
                })
        }
        let hashes = Dictionary(current.sources.map { ($0.descriptor.id, $0.sourceHash) }, uniquingKeysWith: { first, _ in first })
        var exclusion = ContextTurnExclusion(atomIDs: Set(relations.filter {
            hashes[$0.draft.sourceID] != $0.draft.sourceHash
        }.map(\.draft.id)))
        exclusion.unverified += current.failures.compactMap { id, reason in
            relations.contains { $0.draft.sourceID == id } ? ContextDegradedSourceNotice(sourceID: id, reason: reason) : nil
        }
        var supported: [(ContextStoredAtom, String, Date)] = []
        for atom in relations {
            guard let support = atom.draft.entities.first(where: { $0.kind == Self.supportKind }),
                  support.id != "none" else { continue }
            guard let at = support.id.lastIndex(of: "@"),
                  let version = MemoryContext.parseDate(String(support.id[support.id.index(after: at)...])) else {
                exclusion.atomIDs.insert(atom.draft.id)
                exclusion.unverified.append(ContextDegradedSourceNotice(sourceID: atom.draft.sourceID,
                    reason: "Graph supporting-memory version unavailable; repair its canonical source date."))
                continue
            }
            supported.append((atom, String(support.id[..<at]), version))
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

    /// Carry id@version provenance; none marks a relation with no asserting memory.
    static let supportKind = "supporting_memory"

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        let relations: [KnowledgeGraphContextRelation]
        do {
            guard try MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) else {
                return ContextCompiledProjectionResult(
                    owner: Self.owner, currentSources: [], previousSources: previousSources
                )
            }
            relations = try await readRelations()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Last known good remains rebuild input, never a claim of freshness.
            nativeLog("%@", "[context-kg] relation read failed: \(String(describing: error))")
            let ids = Set(previousSources.values.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
            let unavailable = ids.isEmpty ? [ContextStableID.source(owner: Self.owner, locator: "knowledge-graph")] : Array(ids)
            return ContextCompiledProjectionResult(changedSources: [], removedSourceIDs: [], sourceFailures:
                Dictionary(uniqueKeysWithValues: unavailable.map { ($0, "Knowledge graph source unavailable: \(error.localizedDescription)") }))
        }

        let prepared = Self.prepare(relations)
        return ContextCompiledProjectionResult(
            owner: Self.owner, currentSources: prepared.sources, previousSources: previousSources,
            sourceFailures: prepared.failures, verifiedSources: prepared.sources)
    }

    private func readRelations() async throws -> [KnowledgeGraphContextRelation] {
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
        return try await indexer.contextRelations(perSubjectLimit: Self.maximumRelationsPerEntity,
                                                maximumRelations: Self.maximumRelations)
    }
}

extension KnowledgeGraphContext {
    /// Group by subject so maximumAtomsPerSource prevents one entity consuming the packet's relationship budget.
    static func prepare(_ relations: [KnowledgeGraphContextRelation]) -> (sources: [ContextCompiledSource], failures: [ContextSourceID: String]) {
        let usable = relations.filter { relation in
            let body = self.body(relation)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !NativeContextProjectionText.containsDisallowedControl(body)
                && !ContextSecretContentPolicy.containsSecretLikeContent(body)
        }
        let grouped = Dictionary(grouping: usable, by: \.subjectID)
        var sources: [ContextCompiledSource] = []
        var failures: [ContextSourceID: String] = [:]
        for subjectID in grouped.keys.sorted() {
            guard let edges = grouped[subjectID], !edges.isEmpty else { continue }
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
            do {
                let atoms = try ordered.map { relation in
                    try atom(relation, sourceID: sourceID, sourceHash: sourceHash)
                }
                sources.append(ContextCompiledSource(descriptor: descriptor, sourceHash: sourceHash, atoms: atoms))
            } catch { failures[sourceID] = "Knowledge graph dates unavailable: \(error.localizedDescription)" }
        }
        return (sources, failures)
    }

    /// Keep the body a short structural pointer so graph context cannot become a second memory block.
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
    ) throws -> ContextAtomDraft {
        if let failure = relation.sourceDateFailure { throw MemoryV2Error.underlying(failure) }
        let body = self.body(relation)
        let edgeDigest = ContextStableID.digest(parts: [relation.predicate, relation.objectID])
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .relationship,
            headingPath: [],
            blockAnchor: "kg-relation-" + edgeDigest
        )
        // Only named endpoints establish eligibility; predicates would let generic questions pull unrelated edges.
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
            freshness: ContextFreshness(
                updatedAt: try NativeContextProjectionText.requiredDate(relation.lastSeen, owner: "graph \(relation.subjectID) lastSeen")),
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

    /// Predicates never participate in selection; only endpoint names do.
    static func triggers(_ relation: KnowledgeGraphContextRelation) -> [String] {
        let text = [relation.subject, relation.object].joined(separator: " ")
        return NativeContextProjectionText.triggers(text)
    }
}
