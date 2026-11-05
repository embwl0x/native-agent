import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio

// Blueprint: | `NativeStudioContextProjection.swift` | `StudioContext`: bounded journal/canon pointers; judgments stay on demand |

/// Keep judgments behind selectable pointers so context cannot pre-empt encountering the work. Title, creator and medium gate eligibility; taste-judgment tasks
/// also admit pointers, while unrelated operations do not. Artifact refs remain text: only vision/browser organs may open the work. Neutral confidence avoids
/// ranking judgments as taste scores. Per-work, total and body caps prevent repeated encounters with one work from flooding the packet. Unreadable sources
/// retain rebuild inputs but withhold unverified pointers; healthy independent sources still circulate. Missing stores start empty; unreadable sources cannot
/// become evidence that no entries exist.
struct StudioContext: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.studio"
    static let schemaVersion = "studio-context-projection-v2"
    /// Journal appends invalidate this namespace so a new entry is reachable on the next turn.
    static let invalidationNamespace = "studio"
    static let maximumPointers = 96
    static var canonSourceID: ContextSourceID { ContextStableID.source(owner: owner, locator: "studio/canon") }
    static var shelfSourceID: ContextSourceID { ContextStableID.source(owner: owner, locator: "studio/working_shelf") }
    static let maximumEntriesPerWork = 3
    /// All pointers share neutral confidence to avoid scoring judgments.
    static let pointerConfidence = 0.5

    /// Personal-surface disclosure keeps aesthetic life private by default and off Slack.
    static let surfaces: Set<ContextSurface> = Set(
        MemoryRecordDisclosurePolicy.localPrivateSurfaces.map(ContextSurface.init(rawValue:))
    )

    var projectionIdentifier: String { Self.owner }
    var invalidationNamespaces: Set<String> { [Self.invalidationNamespace] }
    let invalidationSourceURL: URL?
    private let canonURL: URL

    private let store: SwiftNativeStudioStore
    private let shelf: StudioWorkingShelf

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.store = SwiftNativeStudioStore(dataRoot: dataRoot)
        self.shelf = StudioWorkingShelf(dataRoot: dataRoot)
        self.invalidationSourceURL = store.journalPath.standardizedFileURL
        self.canonURL = dataRoot.appendingPathComponent("studio/canon/canon.jsonl").standardizedFileURL
    }

    func isInvalidated(by change: DerivedSourceChange) -> Bool {
        guard change.semantic, invalidationNamespaces.contains(change.namespace) else { return false }
        guard let locator = change.canonicalLocator else { return true }
        let url = URL(fileURLWithPath: locator).standardizedFileURL
        return url == invalidationSourceURL || url == canonURL
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        let previousOwnedIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == Self.owner }
            .map(\.descriptor.id))
        let read = try await readPrepared(knownSourceIDs: previousOwnedIDs)
        let retained = read.unavailable.keys.compactMap { previousSources[$0] }
        return ContextCompiledProjectionResult(
            owner: Self.owner, currentSources: read.prepared + retained, previousSources: previousSources,
            sourceFailures: read.unavailable, verifiedSources: read.prepared
        )
    }

    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion {
        let owned = Set(generation.sources.lazy.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
        let atoms = chosen.filter { owned.contains($0.draft.sourceID) }
        guard !atoms.isEmpty else { return ContextTurnExclusion() }
        do {
            let read = try await readPrepared(knownSourceIDs: owned)
            let hashes = Dictionary(read.prepared.map { ($0.descriptor.id, $0.sourceHash) },
                                    uniquingKeysWith: { first, _ in first })
            let selectedSources = Set(atoms.map(\.draft.sourceID))
            return ContextTurnExclusion(atomIDs: Set(atoms.filter {
                !Self.surfaces.contains(surface) || hashes[$0.draft.sourceID] != $0.draft.sourceHash
            }.map(\.draft.id)), unverified: read.unavailable.compactMap { id, reason in
                selectedSources.contains(id) ? ContextDegradedSourceNotice(sourceID: id, reason: reason) : nil
            })
        } catch {
            return ContextTurnExclusion(atomIDs: Set(atoms.map(\.draft.id)), unverified:
                Set(atoms.map(\.draft.sourceID)).map { ContextDegradedSourceNotice(
                    sourceID: $0, reason: "Studio pointers withheld: \(error.localizedDescription)") })
        }
    }

    private func readPrepared(knownSourceIDs: Set<ContextSourceID>) async throws
        -> (prepared: [ContextCompiledSource], unavailable: [ContextSourceID: String]) {
        var prepared: [ContextCompiledSource] = []
        var unavailable: [ContextSourceID: String] = [:]
        func failed(_ ids: Set<ContextSourceID>, _ name: String, _ error: Error) {
            let reason = "Studio \(name) unavailable: \(error.localizedDescription)"
            nativeLog("%@", "[context-studio] \(reason)")
            let failedIDs: Set<ContextSourceID> = ids.isEmpty ? [ContextStableID.source(owner: Self.owner, locator: "studio/" + name)] : ids
            for id in failedIDs { unavailable[id] = reason }
        }
        do {
            if let pointer = Self.prepareShelfPointer(try shelf.selections()) { prepared.append(pointer) }
        } catch is CancellationError { throw CancellationError() }
        catch { failed([Self.shelfSourceID], "shelf", error) }
        do {
            let journal = Self.prepare(try await store.journalEntriesIncludingArchive())
            prepared += journal.sources
            unavailable.merge(journal.failures, uniquingKeysWith: { _, current in current })
        } catch is CancellationError { throw CancellationError() }
        catch { failed(knownSourceIDs.subtracting([Self.shelfSourceID, Self.canonSourceID]), "journal", error) }
        do {
            let canon = StudioCanonLaw.membership(from: try await store.readCanon())
                .values.sorted { $0.workTitle < $1.workTitle }
            if let pointer = try Self.prepareCanon(canon) { prepared.append(pointer) }
        } catch is CancellationError { throw CancellationError() }
        catch { failed([Self.canonSourceID], "canon", error) }
        return (prepared, unavailable)
    }
}

extension StudioContext {
    /// A separate bounded atom preserves exact titles and journal pointers independently of journal availability.
    static func prepareShelfPointer(_ slots: [StudioWorkingShelf.Slot]) -> ContextCompiledSource? {
        guard !slots.isEmpty else { return nil }
        let line = "Working shelf: " + slots.map(\.title).joined(separator: "; ") + "; open with app studio.shelf"
        guard !line.isEmpty, line.utf8.count <= 512,
              !NativeContextProjectionText.containsDisallowedControl(line),
              !ContextSecretContentPolicy.containsSecretLikeContent(line) else { return nil }
        let locator = "studio/working_shelf"
        let sourceID = ContextStableID.source(owner: owner, locator: locator)
        let sourceHash = ContextStableID.digest(parts: [schemaVersion, line])
        let descriptor = ContextSourceDescriptor(
            id: sourceID, owner: owner, kind: .other, canonicalLocator: locator,
            authority: .inferred, privacy: .localPrivate, permittedSurfaces: surfaces,
            injectionPolicy: .adaptive
        )
        let works = slots.map { StudioWork(title: $0.title) }
        let atom = Self.atom(
            body: line, anchor: "studio-working-shelf", works: works, updatedAt: .distantPast,
            sourceID: sourceID, sourceHash: sourceHash
        )
        return ContextCompiledSource(descriptor: descriptor, sourceHash: sourceHash, atoms: [atom])
    }

    /// Group entries by work so maximumAtomsPerSource prevents one revisited work consuming the studio budget.
    static func prepare(
        _ entries: [StudioJournalEntry]
    ) -> (sources: [ContextCompiledSource], failures: [ContextSourceID: String]) {
        let usable = entries.filter { entry in
            let body = self.body(entry)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !NativeContextProjectionText.containsDisallowedControl(body)
                && !ContextSecretContentPolicy.containsSecretLikeContent(body)
        }
        let grouped = Dictionary(grouping: usable, by: { workKey($0.work) })
        var remaining = maximumPointers
        var result: [ContextCompiledSource] = []
        var failures: [ContextSourceID: String] = [:]
        for key in grouped.keys.sorted() {
            guard remaining > 0, let all = grouped[key], !all.isEmpty else { continue }
            // Newest first: reach the entry that revised the judgment before the one it revised.
            let ordered = Array(
                all.sorted { lhs, rhs in
                    if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
                    return lhs.id > rhs.id
                }
                .prefix(min(maximumEntriesPerWork, remaining))
            )
            guard !ordered.isEmpty else { continue }
            remaining -= ordered.count
            let locatorDigest = ContextStableID.digest(parts: [key])
            let locator = "studio/journal/works/\(locatorDigest)"
            let sourceID = ContextStableID.source(owner: owner, locator: locator)
            let sourceHash = ContextStableID.digest(parts: [schemaVersion] + ordered.map {
                [self.body($0), $0.id, $0.recordedAt, $0.stance.kind.rawValue,
                 $0.amendments.map(\.id).joined(separator: ",")]
                    .joined(separator: "\u{1f}")
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
                let atoms = try ordered.map { entry in
                    atom(body: body(entry),
                         anchor: "studio-entry-" + ContextStableID.digest(parts: [entry.id]),
                         works: [entry.work],
                         updatedAt: try NativeContextProjectionText.requiredDate(entry.recordedAt, owner: "Studio journal \(entry.id) recordedAt"),
                         sourceID: sourceID, sourceHash: sourceHash)
                }
                result.append(ContextCompiledSource(
                    descriptor: descriptor,
                    sourceHash: sourceHash,
                    atoms: atoms
                ))
            } catch { failures[sourceID] = "Studio journal dates unavailable: \(error.localizedDescription)" }
        }
        return (result, failures)
    }

    /// The earned, demotable canon stays small enough for one source; its pointers share journal admission rules.
    static func prepareCanon(_ members: [StudioCanonMember]) throws -> ContextCompiledSource? {
        let usable = members.filter { member in
            let body = canonBody(member)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !NativeContextProjectionText.containsDisallowedControl(body)
                && !ContextSecretContentPolicy.containsSecretLikeContent(body)
        }
        guard !usable.isEmpty else { return nil }
        let ordered = Array(usable.sorted { lhs, rhs in
            if lhs.workTitle != rhs.workTitle { return lhs.workTitle < rhs.workTitle }
            return (lhs.workCreator ?? "") < (rhs.workCreator ?? "")
        }.prefix(maximumPointers))
        let locator = "studio/canon"
        let sourceID = ContextStableID.source(owner: owner, locator: locator)
        let sourceHash = ContextStableID.digest(parts: [schemaVersion] + ordered.map {
            [canonBody($0), $0.standing.rawValue, $0.since].joined(separator: "\u{1f}")
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
        let atoms = try ordered.map { member in
            atom(body: canonBody(member), anchor: "studio-canon-" + ContextStableID.digest(parts: [
                StudioCanonLaw.workKey(title: member.workTitle, creator: member.workCreator),
            ]), works: [StudioWork(title: member.workTitle, creator: member.workCreator)],
                 updatedAt: try NativeContextProjectionText.requiredDate(member.since, owner: "Studio canon \(member.workTitle) since"),
                 sourceID: sourceID, sourceHash: sourceHash)
        }
        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: atoms
        )
    }

    /// Keep judgments in the journal; canon pointers must lead back to the original entries.
    static func canonBody(_ member: StudioCanonMember) -> String {
        let title = NativeContextProjectionText.bounded(NativeContextProjectionText.clean(member.workTitle), to: 120)
        guard !title.isEmpty else { return "" }
        var head = title
        if let creator = member.workCreator.map(NativeContextProjectionText.clean), !creator.isEmpty {
            head += " — " + NativeContextProjectionText.bounded(creator, to: 80)
        }
        var parts = [
            head,
            member.standing == .canon ? "canon" : "anti-canon",
            "since \(NativeContextProjectionText.bounded(NativeContextProjectionText.clean(member.since), to: 40))",
        ]
        if !member.evidenceEntryIDs.isEmpty {
            parts.append("evidence \(member.evidenceEntryIDs.count) entries")
        }
        parts.append("pull: app studio.canon")
        return parts.joined(separator: " · ")
    }

    /// Fold title and creator so capitalization cannot split the same work's identity.
    static func workKey(_ work: StudioWork) -> String {
        [fold(work.title), fold(work.creator ?? "")].joined(separator: "\u{1f}")
    }

    /// Omit the response so a pointer cannot pre-empt the judgment.
    static func body(_ entry: StudioJournalEntry) -> String {
        let title = NativeContextProjectionText.bounded(NativeContextProjectionText.clean(entry.work.title), to: 120)
        guard !title.isEmpty else { return "" }
        var head = title
        if let creator = entry.work.creator.map(NativeContextProjectionText.clean), !creator.isEmpty {
            head += " — " + NativeContextProjectionText.bounded(creator, to: 80)
        }
        if let medium = entry.work.medium.map(NativeContextProjectionText.clean), !medium.isEmpty {
            head += " (" + NativeContextProjectionText.bounded(medium, to: 48) + ")"
        }
        var parts = [head, "journal \(entry.id)", "stance \(entry.stance.kind.rawValue)"]
        // Mark withdrawn claims on the pointer so corrections are visible before the entry is pulled.
        if let latest = entry.amendments.last {
            parts.append("corrected \(latest.amendedOn)")
        }
        // Refs stay text; context projection cannot open a path or fetch a URL.
        if let ref = entry.artifactRefs.first.map(NativeContextProjectionText.clean), !ref.isEmpty {
            parts.append("ref \(NativeContextProjectionText.bounded(ref, to: 120))")
        }
        parts.append("pull: app studio.recall title=\"\(NativeContextProjectionText.bounded(title, to: 80))\"")
        return parts.joined(separator: " · ")
    }

    static func atom(
        body: String,
        anchor: String,
        works: [StudioWork],
        updatedAt: Date,
        sourceID: ContextSourceID,
        sourceHash: String
    ) -> ContextAtomDraft {
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .evidence,
            headingPath: [],
            blockAnchor: anchor
        )
        return ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .evidence,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            authority: .inferred,
            confidence: pointerConfidence,
            freshness: ContextFreshness(updatedAt: updatedAt),
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: works.flatMap(entities),
            triggers: works.flatMap(triggers),
            activation: 0,
            recentUsefulness: 0,
            decayState: 1,
            embedding: nil
        )
    }

    /// Gate eligibility on title, creator and medium so unnamed works are excluded rather than merely ranked lower.
    static func entities(_ work: StudioWork) -> [ContextEntity] {
        var result: [ContextEntity] = []
        var seen = Set<String>()
        for label in [work.title, work.creator ?? "", work.medium ?? ""] {
            let cleaned = NativeContextProjectionText.bounded(NativeContextProjectionText.clean(label), to: 120)
            guard !cleaned.isEmpty, seen.insert(fold(cleaned)).inserted else { continue }
            result.append(ContextEntity(
                kind: ContextCorrectionScope.studioEntityKind,
                id: ContextStableID.digest(parts: [fold(cleaned)]),
                label: cleaned
            ))
        }
        return result
    }

    /// Only selection-key tokens may trigger recall; judgment words could pull unrelated works.
    static func triggers(_ work: StudioWork) -> [String] {
        let text = [work.title, work.creator ?? "", work.medium ?? ""].joined(separator: " ")
        return NativeContextProjectionText.triggers(text)
    }

    static func fold(_ value: String) -> String {
        NativeContextProjectionText.clean(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

}
