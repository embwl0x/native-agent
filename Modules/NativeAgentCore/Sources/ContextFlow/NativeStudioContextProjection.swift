import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio

// Blueprint: | `NativeStudioContextProjection.swift` | `StudioContext`: rebuildable journal/canon pointer atoms and invalidation; judgments remain behind on-demand pointers |

/// The studio journal, made REACHABLE — as a POINTER, never as the judgment.
///
/// ── WHAT AN ATOM SAYS ────────────────────────────────────────────────────────
/// One short line per journal entry: the work, its creator, its medium, the
/// entry id, the stance, and how to pull the entry itself. It does NOT carry the
/// response — the judgment is the point, and a paragraph of it in every packet
/// would be prompt mass wearing reach's name. Clause 6: selectable, expandable,
/// one pull away. The pull is `studio_recall`, which returns the entry verbatim.
///
/// Her own words for why the body stops here: "my first contact should be with
/// the work, not a prediction of my reaction." A pointer cannot pre-empt the
/// encounter; a pasted judgment can.
///
/// ── WHAT SELECTS AN ATOM ─────────────────────────────────────────────────────
/// The work TITLE, the CREATOR, and the MEDIUM. Nothing else — not the response,
/// not the stance, not a tag. Those three are published as
/// `ContextCorrectionScope.studioEntityKind` entities, which is also what GATES
/// eligibility, so an unnamed work is `outsideContextScope` outright rather than
/// left to rank low. The second admission is
/// `ContextCorrectionScope.isTasteJudgmentTask` — a design review or an
/// aesthetic call, where the pointer is relevant without the work being named.
/// An ops turn is neither, and that is deliberate: "if it shows up on ops turns
/// I'll learn to ignore it, and ignored is worse than absent."
///
/// ── ARTIFACT REFS ────────────────────────────────────────────────────────────
/// Rendered as TEXT, never dereferenced. Nothing in this file opens a path or
/// fetches a URL; a ref is a string the line happens to contain. Honest
/// encounters are made in front of the work, through the vision/browser organs,
/// never by a context projection quietly reading a file.
///
/// ── NO SCORES ────────────────────────────────────────────────────────────────
/// Every pointer carries the same neutral confidence. There is no rating on a
/// journal entry and there will not be one here either: ranking her judgments
/// against each other is the taste score the whole design refuses to keep.
///
/// ── BOUNDS ───────────────────────────────────────────────────────────────────
/// Per work (`maximumEntriesPerWork`), total (`maximumPointers`), and body shape
/// (one line, capped bytes). A work she keeps returning to cannot flood the
/// index, and the `.evidence` kind cap bounds how much of a packet these can
/// ever take.
///
/// ── FAILURE ──────────────────────────────────────────────────────────────────
/// Missing stores are empty. Unreadable stores retain published pointers for
/// rebuilding, but selection and expansion withhold them with an unavailable
/// receipt. Healthy independent Studio sources keep circulating.
struct StudioContext: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.studio"
    static let schemaVersion = "studio-context-projection-v2"
    /// The invalidation namespace the studio tool lane publishes on after a
    /// journal append, so a just-filed entry is reachable on the NEXT turn
    /// rather than after the next launch.
    static let invalidationNamespace = "studio"
    static let maximumPointers = 96
    static var canonSourceID: ContextSourceID { ContextStableID.source(owner: owner, locator: "studio/canon") }
    static var shelfSourceID: ContextSourceID { ContextStableID.source(owner: owner, locator: "studio/working_shelf") }
    static let maximumEntriesPerWork = 3
    /// One neutral value for every pointer. See "NO SCORES" above.
    static let pointerConfidence = 0.5

    /// Same tier the memory lane defaults to for a `local_private` record:
    /// User's authenticated personal surfaces, never Slack. Her aesthetic life is
    /// private by default and this is the line that keeps it that way.
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
            owner: Self.owner, currentSources: read.prepared + retained, previousSources: previousSources
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
            for id in ids { unavailable[id] = reason }
        }
        do {
            if let pointer = Self.prepareShelfPointer(try shelf.selections()) { prepared.append(pointer) }
        } catch is CancellationError { throw CancellationError() }
        catch { failed([Self.shelfSourceID], "shelf", error) }
        do {
            prepared += Self.prepare(try await store.journalEntriesIncludingArchive())
        } catch is CancellationError { throw CancellationError() }
        catch { failed(knownSourceIDs.subtracting([Self.shelfSourceID, Self.canonSourceID]), "journal", error) }
        do {
            let canon = StudioCanonLaw.membership(from: try await store.readCanon())
                .values.sorted { $0.workTitle < $1.workTitle }
            if let pointer = Self.prepareCanon(canon) { prepared.append(pointer) }
        } catch is CancellationError { throw CancellationError() }
        catch { failed([Self.canonSourceID], "canon", error) }
        return (prepared, unavailable)
    }
}

extension StudioContext {
    /// One line in the existing Studio projection, independent of journal availability.
    /// Keeping its own bounded atom preserves both the exact titles and journal pointers.
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

    /// One source per WORK, one atom per entry about it. Grouping this way lets
    /// the selector's existing `maximumAtomsPerSource` bound keep a work she has
    /// returned to five times from owning the whole studio budget of a packet.
    static func prepare(
        _ entries: [StudioJournalEntry]
    ) -> [ContextCompiledSource] {
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
        for key in grouped.keys.sorted() {
            guard remaining > 0, let all = grouped[key], !all.isEmpty else { continue }
            // Newest first inside a work: the entry that revised her mind is the
            // one worth reaching before the one it revised.
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
            let atoms = ordered.map { entry in
                atom(body: body(entry),
                     anchor: "studio-entry-" + ContextStableID.digest(parts: [entry.id]),
                     works: [entry.work],
                     updatedAt: NativeTimestampFormat.parseISO8601FractionalFirst(entry.recordedAt) ?? .distantPast,
                     sourceID: sourceID, sourceHash: sourceHash)
            }
            result.append(ContextCompiledSource(
                descriptor: descriptor,
                sourceHash: sourceHash,
                atoms: atoms
            ))
        }
        return result
    }

    /// ONE source for the whole canon, one atom per member.
    ///
    /// The canon is small by construction (it is earned, and demotion proposals
    /// keep it from only growing), so it does not need the per-work grouping the
    /// journal uses. Selection is identical: title / creator / medium-free
    /// entities and triggers, so a canon pointer reaches a turn on exactly the
    /// same admission rule as a journal pointer and never on an ops turn.
    static func prepareCanon(_ members: [StudioCanonMember]) -> ContextCompiledSource? {
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
        let atoms = ordered.map { member in
            atom(body: canonBody(member), anchor: "studio-canon-" + ContextStableID.digest(parts: [
                StudioCanonLaw.workKey(title: member.workTitle, creator: member.workCreator),
            ]), works: [StudioWork(title: member.workTitle, creator: member.workCreator)],
                 updatedAt: NativeTimestampFormat.parseISO8601FractionalFirst(member.since) ?? .distantPast,
                 sourceID: sourceID, sourceHash: sourceHash)
        }
        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: atoms
        )
    }

    /// A POINTER, exactly like the journal's. It says the work holds (or does
    /// not), since when, how many entries argued for it, and how to pull them.
    /// The judgment itself stays in the journal — a canon pointer must not
    /// become a shortcut past re-reading what she actually wrote.
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

    /// Title + creator, folded — two entries about the same work by the same
    /// hand are the same work however they were capitalised.
    static func workKey(_ work: StudioWork) -> String {
        [fold(work.title), fold(work.creator ?? "")].joined(separator: "\u{1f}")
    }

    /// The whole atom body: a POINTER, not the judgment. The `response` is
    /// deliberately absent — see the file note.
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
        // A corrected entry SAYS so on the pointer. Without this the model
        // reaches an entry whose claim she has already withdrawn and has no way
        // to know before it pulls — the correction would be durable and
        // unreachable, the exact failure this projection exists to prevent.
        if let latest = entry.amendments.last {
            parts.append("corrected \(latest.amendedOn)")
        }
        // TEXT ONLY. Nothing in this file opens this path or fetches this URL.
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

    /// Title, creator, medium — the three selection keys, and only those. They
    /// carry `ContextCorrectionScope.studioEntityKind`, which is what gates
    /// eligibility, so an entry whose work this message never named is excluded
    /// outright with an honest `outsideContextScope` receipt.
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

    /// Tokens of the three selection keys only. The response never becomes a
    /// trigger: admitting judgment words would let "is this sloppy?" pull an
    /// unrelated entry that happens to use the word.
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
