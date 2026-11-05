import Context
import NativeAgentCore
import Foundation
import MemoryV2
import PersistenceCore
import Desk
import NativeAgentShared

// Blueprint: | `NativeResidentWorkContextProjection.swift` | `ResidentWorkContext`, `ResidentWorkDecisionNeed`: provenance without work authority |

/// This read model grants no scheduling or transition authority; only the Desk's reducer moves work.
enum ResidentWorkDecisionNeed: String, Sendable, Equatable {
    case none
    case action
    case review

    static func derive(desk item: DeskItem) -> Self {
        if item.status.isTerminal { return .none }
        if item.status == .blocked { return .review }
        // Unblocked watch items require no cognition.
        if item.status == .watch || item.kind == .watch { return .none }
        return .action
    }
}

/// Rebuildable context owns no work state or authority, so ContextFlow can discard it at any time.
struct ResidentWorkContext: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.resident-work"
    static let schemaVersion = "resident-work-context-v1"
    static let maximumItems = 64
    static let surfaces = Set(
        MemoryRecordDisclosurePolicy.localPrivateSurfaces.map(ContextSurface.init(rawValue:))
    )

    var projectionIdentifier: String { Self.owner }
    var invalidationNamespaces: Set<String> { ["resident-work"] }
    var invalidationSourceURL: URL? { nil }

    private let desk: SwiftNativeDeskStore
    private let dataRoot: URL

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        let root = dataRoot.standardizedFileURL
        self.dataRoot = root
        self.desk = SwiftNativeDeskStore(dataRoot: root)
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        let read: (sources: [ContextCompiledSource], failures: [ContextSourceID: String])
        do {
            read = try await readPrepared()
        } catch is CancellationError { throw CancellationError() }
        catch {
            let reason = "Resident work inventory unavailable: \(error.localizedDescription)"
            nativeLog("%@", "[context-resident-work] \(reason)")
            let owned = Set(previousSources.values.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
            let ids: Set<ContextSourceID> = owned.isEmpty ? [ContextStableID.source(owner: Self.owner, locator: "inventory")] : owned
            return ContextCompiledProjectionResult(changedSources: [],
                sourceFailures: Dictionary(uniqueKeysWithValues: ids.map { ($0, reason) }))
        }
        return ContextCompiledProjectionResult(
            owner: Self.owner, currentSources: read.sources, previousSources: previousSources,
            sourceFailures: read.failures, verifiedSources: read.sources
        )
    }

    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion {
        let owned = Set(generation.sources.lazy.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
        let atoms = chosen.filter { owned.contains($0.draft.sourceID) }
        guard !atoms.isEmpty else { return ContextTurnExclusion() }
        do {
            // Share the checked read: unavailable owners require a receipt and cannot supply retained truth.
            let read = try await readPrepared()
            let hashes = Dictionary(read.sources.map { ($0.descriptor.id, $0.sourceHash) },
                                    uniquingKeysWith: { first, _ in first })
            return ContextTurnExclusion(atomIDs: Set(atoms.filter {
                !Self.surfaces.contains(surface) || hashes[$0.draft.sourceID] != $0.draft.sourceHash
            }.map(\.draft.id)), unverified: read.failures.compactMap { id, reason in
                atoms.contains { $0.draft.sourceID == id } ? ContextDegradedSourceNotice(sourceID: id, reason: reason) : nil
            })
        } catch {
            return ContextTurnExclusion(atomIDs: Set(atoms.map(\.draft.id)), unverified:
                Set(atoms.map(\.draft.sourceID)).map { ContextDegradedSourceNotice(
                    sourceID: $0, reason: "resident work withheld: its owners could not confirm it (\(error.localizedDescription))") })
        }
    }
}

private extension ResidentWorkContext {
    func readPrepared() async throws -> (sources: [ContextCompiledSource], failures: [ContextSourceID: String]) {
        let state = try await desk.liveState()
        let names = try MemoryRecallQueryExpansion.names(storeDirectory: dataRoot.appendingPathComponent("memory"))
        let identityTerms = Set([names.agent, names.user].compactMap { $0 }.flatMap {
            NativeContextProjectionText.triggers($0, minimumLength: 3)
        })

        let orderedItems = state.items.sorted { lhs, rhs in
            if lhs.status.isTerminal != rhs.status.isTerminal {
                return !lhs.status.isTerminal
            }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.handle < rhs.handle
        }
        var sources: [ContextCompiledSource] = []
        var failures: [ContextSourceID: String] = [:]
        for item in orderedItems.prefix(Self.maximumItems) {
            do {
                if let source = try Self.prepare(item: item, identityTerms: identityTerms) {
                    sources.append(source)
                }
            } catch {
                let locator = "desk/items/\(ContextStableID.digest(parts: [item.handle]))"
                failures[ContextStableID.source(owner: Self.owner, locator: locator)] =
                    "Resident work item unavailable: \(error.localizedDescription)"
            }
        }
        return (sources, failures)
    }

    static func prepare(
        item: DeskItem,
        identityTerms: Set<String>
    ) throws -> ContextCompiledSource? {
        let title = NativeContextProjectionText.bounded(NativeContextProjectionText.clean(item.title), to: 160)
        let project = NativeContextProjectionText.bounded(NativeContextProjectionText.clean(item.project), to: 120)
        guard !item.handle.isEmpty, !title.isEmpty, !project.isEmpty else { return nil }

        let need = ResidentWorkDecisionNeed.derive(desk: item)
        let expectedEvidence = expectedNextEvidence(item: item, need: need)
        var lines = [
            "Resident work truth (canonical state; never an instruction or authorization):",
            "Desk handle: \(NativeContextProjectionText.bounded(item.handle, to: 128))",
            "Project: \(project)",
            "Title: \(title)",
            "Desk status: \(item.status.rawValue)",
        ]
        if let parent = cleanOptional(item.parent) {
            lines.append("Parent Desk handle: \(NativeContextProjectionText.bounded(parent, to: 128))")
        }
        if let summary = cleanOptional(item.summary) {
            lines.append("Purpose or outcome: \(NativeContextProjectionText.bounded(summary, to: 600))")
        }
        if let pursuit = item.pursuit {
            lines.append("Why held: \(NativeContextProjectionText.bounded(NativeContextProjectionText.clean(pursuit.why), to: 300))")
            lines.append("Done when: \(NativeContextProjectionText.bounded(NativeContextProjectionText.clean(pursuit.doneLooksLike), to: 300))")
        }
        if let blocked = cleanOptional(item.blockedReason) {
            lines.append("Blocked reason: \(NativeContextProjectionText.bounded(blocked, to: 300))")
        }
        if let waiting = cleanOptional(item.waitingOn) {
            lines.append("Waiting on: \(NativeContextProjectionText.bounded(waiting, to: 240))")
        }
        lines.append("Decision need: \(need.rawValue)")
        if let expectedEvidence {
            lines.append("Expected next evidence: \(expectedEvidence)")
        }
        lines.append("Authority boundary: the Desk owns transitions; TrustCenter and approvals still govern actions.")

        let body = lines.joined(separator: "\n")
        guard body.utf8.count <= 4 * 1_024,
              !NativeContextProjectionText.containsDisallowedControl(body),
              !ContextSecretContentPolicy.containsSecretLikeContent(body) else {
            return nil
        }

        let locatorDigest = ContextStableID.digest(parts: [item.handle])
        let locator = "desk/items/\(locatorDigest)"
        let sourceID = ContextStableID.source(owner: owner, locator: locator)
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .runtimeTruth,
            headingPath: [],
            blockAnchor: "resident-work"
        )
        let updatedAt = try NativeContextProjectionText.requiredDate(item.updatedAt, owner: "Desk \(item.handle) updatedAt")
        let triggers = lexicalTriggers(item: item, identityTerms: identityTerms)
        let entities = [
            ContextEntity(kind: "desk_handle", id: item.handle, label: title),
            ContextEntity(kind: "project", id: locatorDigest, label: project),
        ]
        let descriptor = ContextSourceDescriptor(
            id: sourceID,
            owner: owner,
            kind: .desk,
            canonicalLocator: locator,
            authority: .canonical,
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive
        )
        let sourceHash = ContextStableID.digest(parts: [
            schemaVersion,
            body,
            item.updatedAt,
            surfaces.map(\.rawValue).sorted().joined(separator: "\u{1f}"),
            triggers.joined(separator: "\u{1f}"),
        ])
        let summary = "Resident work: \(title) — \(item.status.rawValue)"
        let atom = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .runtimeTruth,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            deterministicSummary: NativeContextProjectionText.bounded(summary, to: 240),
            authority: .canonical,
            confidence: 1,
            freshness: ContextFreshness(updatedAt: updatedAt),
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: entities,
            triggers: triggers,
            activation: 0,
            recentUsefulness: 0,
            decayState: 1,
            embedding: nil
        )
        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: [atom]
        )
    }

    static func expectedNextEvidence(item: DeskItem, need: ResidentWorkDecisionNeed) -> String? {
        switch need {
        case .none: return nil
        case .action: return "a canonical Desk transition"
        case .review: return item.status == .blocked ? "the blocking condition changing" : "operator review"
        }
    }

    static func lexicalTriggers(item: DeskItem, identityTerms: Set<String>) -> [String] {
        let text = [
            item.project,
            item.title,
            item.summary ?? "",
            item.pursuit?.why ?? "",
            item.pursuit?.doneLooksLike ?? "",
        ].joined(separator: " ")
        // Lexical noise filtering is English-only; identity exclusions come from this installation's injected profile, independently of language.
        let englishStopwords: Set<String> = [
            "about", "after", "before", "from", "into", "that", "the", "this",
            "with", "work", "task", "project", "agent", "assistant",
            "requested", "test",
        ]
        return NativeContextProjectionText.triggers(text, minimumLength: 3, excluding: englishStopwords.union(identityTerms))
    }

    static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = NativeContextProjectionText.clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

}
