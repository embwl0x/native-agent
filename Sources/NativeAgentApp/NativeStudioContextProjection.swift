import Context
import Foundation
import MemoryV2
import PersistenceCore

/// The studio journal, made REACHABLE — as a POINTER, never as the judgment.
///
/// Phase 5 of desk 903, and the one the agent said matters most: "never called
/// in production means pull failed". Before this, everything she had ever
/// written about a work lived in `studio/journal/journal.jsonl` and reached a
/// live turn only if someone remembered to call `studio_recall` by hand. Her
/// taste was durable and unreachable at the same time.
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
/// A missing journal is an empty journal. An unreadable one keeps the last good
/// pointers and says so in the log — a garnish must never fail the whole context
/// generation that also carries persona, memory and resident work.
struct NativeStudioContextProjection: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.studio"
    static let schemaVersion = "studio-context-projection-v1"
    /// The invalidation namespace the studio tool lane publishes on after a
    /// journal append, so a just-filed entry is reachable on the NEXT turn
    /// rather than after the next launch.
    static let invalidationNamespace = "studio"
    static let maximumPointers = 96
    static var canonSourceID: ContextSourceID { ContextStableID.source(owner: owner, locator: "studio/canon") }
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

    private let loadEntries: @Sendable () async throws -> [StudioJournalEntry]
    /// The SECOND source kind (desk 903 phase 4): decided canon rows, reduced to
    /// current membership. Same pointer shape, same caps, same privacy — a canon
    /// pointer says a work holds and how to pull the argument, never the
    /// argument itself.
    private let loadCanon: @Sendable () async throws -> [StudioCanonMember]
    private let diagnostics: @Sendable (String) -> Void

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        maximumPointers: Int = NativeStudioContextProjection.maximumPointers,
        maximumEntriesPerWork: Int = NativeStudioContextProjection.maximumEntriesPerWork,
        loadEntries: (@Sendable () async throws -> [StudioJournalEntry])? = nil,
        loadCanon: (@Sendable () async throws -> [StudioCanonMember])? = nil,
        diagnostics: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }
    ) {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        self.invalidationSourceURL = store.journalPath.standardizedFileURL
        self.diagnostics = diagnostics
        self.totalCap = max(0, maximumPointers)
        self.perWorkCap = max(1, maximumEntriesPerWork)
        // 2026-09-06: hot PLUS shelf. Reading only the hot file made the
        // context projection forget every entry the cap had archived — the
        // encounters simply stopped being pointed at.
        self.loadEntries = loadEntries ?? { try await store.journalEntriesIncludingArchive() }
        self.loadCanon = loadCanon ?? {
            StudioCanonLaw.membership(from: try await store.readCanon())
                .values.sorted { $0.workTitle < $1.workTitle }
        }
    }

    private let totalCap: Int
    private let perWorkCap: Int

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        let entries: [StudioJournalEntry]
        do {
            entries = try await loadEntries()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Last known good: publish nothing, retire nothing.
            diagnostics("[context-studio] journal read failed: \(String(describing: error))")
            return ContextCompiledProjectionResult(changedSources: [], removedSourceIDs: [])
        }

        var prepared = Self.prepare(entries, totalCap: totalCap, perWorkCap: perWorkCap)
        // Missing is empty at the store owner. Failure is not absence: retain
        // the prior canon while still publishing healthy journal updates.
        let canon: [StudioCanonMember]
        var canonUnavailable = false
        do { canon = try await loadCanon() }
        catch is CancellationError { throw CancellationError() }
        catch {
            diagnostics("[context-studio] canon read failed; keeping last good source: \(String(describing: error))")
            canon = []
            canonUnavailable = true
        }
        if let canonSource = Self.prepareCanon(canon) { prepared.append(canonSource) }
        var selectedIDs = Set(prepared.map(\.sourceID))
        if canonUnavailable { selectedIDs.insert(Self.canonSourceID) }
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

extension NativeStudioContextProjection {
    struct Prepared: Sendable {
        let sourceID: ContextSourceID
        let sourceHash: String
        let compiledSource: ContextCompiledSource
    }

    /// One source per WORK, one atom per entry about it. Grouping this way lets
    /// the selector's existing `maximumAtomsPerSource` bound keep a work she has
    /// returned to five times from owning the whole studio budget of a packet.
    static func prepare(
        _ entries: [StudioJournalEntry],
        totalCap: Int = maximumPointers,
        perWorkCap: Int = maximumEntriesPerWork
    ) -> [Prepared] {
        guard totalCap > 0 else { return [] }
        let usable = entries.filter { entry in
            let body = self.body(entry)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !containsDisallowedControl(body)
                && !ContextSecretContentPolicy.containsSecretLikeContent(body)
        }
        let grouped = Dictionary(grouping: usable, by: { workKey($0.work) })
        var remaining = totalCap
        var result: [Prepared] = []
        for key in grouped.keys.sorted() {
            guard remaining > 0, let all = grouped[key], !all.isEmpty else { continue }
            // Newest first inside a work: the entry that revised her mind is the
            // one worth reaching before the one it revised.
            let ordered = Array(
                all.sorted { lhs, rhs in
                    if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
                    return lhs.id > rhs.id
                }
                .prefix(min(perWorkCap, remaining))
            )
            guard !ordered.isEmpty else { continue }
            remaining -= ordered.count
            let locatorDigest = ContextStableID.digest(parts: [key])
            let locator = "studio/journal/works/\(locatorDigest)"
            let sourceID = ContextStableID.source(owner: owner, locator: locator)
            let sourceHash = ContextStableID.digest(parts: [schemaVersion] + ordered.map {
                [self.body($0), $0.id, $0.recordedAt, $0.stance.kind.rawValue]
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
            let atoms = ordered.map { atom($0, sourceID: sourceID, sourceHash: sourceHash) }
            result.append(Prepared(
                sourceID: sourceID,
                sourceHash: sourceHash,
                compiledSource: ContextCompiledSource(
                    descriptor: descriptor,
                    sourceHash: sourceHash,
                    atoms: atoms
                )
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
    static func prepareCanon(_ members: [StudioCanonMember]) -> Prepared? {
        let usable = members.filter { member in
            let body = canonBody(member)
            return !body.isEmpty
                && body.utf8.count <= 512
                && !containsDisallowedControl(body)
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
        let atoms = ordered.map { canonAtom($0, sourceID: sourceID, sourceHash: sourceHash) }
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

    /// A POINTER, exactly like the journal's. It says the work holds (or does
    /// not), since when, how many entries argued for it, and how to pull them.
    /// The judgment itself stays in the journal — a canon pointer must not
    /// become a shortcut past re-reading what she actually wrote.
    static func canonBody(_ member: StudioCanonMember) -> String {
        let title = bounded(clean(member.workTitle), to: 120)
        guard !title.isEmpty else { return "" }
        var head = title
        if let creator = member.workCreator.map(clean), !creator.isEmpty {
            head += " — " + bounded(creator, to: 80)
        }
        var parts = [
            head,
            member.standing == .canon ? "canon" : "anti-canon",
            "since \(bounded(clean(member.since), to: 40))",
        ]
        if !member.evidenceEntryIDs.isEmpty {
            parts.append("evidence \(member.evidenceEntryIDs.count) entries")
        }
        parts.append("pull: studio_canon")
        return parts.joined(separator: " · ")
    }

    static func canonAtom(
        _ member: StudioCanonMember,
        sourceID: ContextSourceID,
        sourceHash: String
    ) -> ContextAtomDraft {
        let body = canonBody(member)
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .evidence,
            headingPath: [],
            blockAnchor: "studio-canon-" + ContextStableID.digest(parts: [
                StudioCanonLaw.workKey(title: member.workTitle, creator: member.workCreator),
            ])
        )
        let work = StudioWork(title: member.workTitle, creator: member.workCreator)
        return ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .evidence,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            authority: .inferred,
            // Same neutral value every journal pointer carries. Canon membership
            // is not a higher score — it is a different fact.
            confidence: pointerConfidence,
            freshness: ContextFreshness(
                updatedAt: StudioClock.parseISO(member.since) ?? .distantPast
            ),
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: entities(work),
            triggers: triggers(work),
            activation: 0,
            recentUsefulness: 0,
            decayState: 1,
            embedding: nil
        )
    }

    /// Title + creator, folded — two entries about the same work by the same
    /// hand are the same work however they were capitalised.
    static func workKey(_ work: StudioWork) -> String {
        [fold(work.title), fold(work.creator ?? "")].joined(separator: "\u{1f}")
    }

    /// The whole atom body: a POINTER, not the judgment. The `response` is
    /// deliberately absent — see the file note.
    static func body(_ entry: StudioJournalEntry) -> String {
        let title = bounded(clean(entry.work.title), to: 120)
        guard !title.isEmpty else { return "" }
        var head = title
        if let creator = entry.work.creator.map(clean), !creator.isEmpty {
            head += " — " + bounded(creator, to: 80)
        }
        if let medium = entry.work.medium.map(clean), !medium.isEmpty {
            head += " (" + bounded(medium, to: 48) + ")"
        }
        var parts = [head, "journal \(entry.id)", "stance \(entry.stance.kind.rawValue)"]
        // TEXT ONLY. Nothing in this file opens this path or fetches this URL.
        if let ref = entry.artifactRefs.first.map(clean), !ref.isEmpty {
            parts.append("ref \(bounded(ref, to: 120))")
        }
        parts.append("pull: studio_recall title=\"\(bounded(title, to: 80))\"")
        return parts.joined(separator: " · ")
    }

    static func atom(
        _ entry: StudioJournalEntry,
        sourceID: ContextSourceID,
        sourceHash: String
    ) -> ContextAtomDraft {
        let body = self.body(entry)
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .evidence,
            headingPath: [],
            blockAnchor: "studio-entry-" + ContextStableID.digest(parts: [entry.id])
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
            freshness: ContextFreshness(
                updatedAt: StudioClock.parseISO(entry.recordedAt) ?? .distantPast
            ),
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: entities(entry.work),
            triggers: triggers(entry.work),
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
            let cleaned = bounded(clean(label), to: 120)
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
        var seen = Set<String>()
        var values: [String] = []
        let text = [work.title, work.creator ?? "", work.medium ?? ""].joined(separator: " ")
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(token)
            guard value.count >= 2, seen.insert(value).inserted else { continue }
            values.append(bounded(value, to: 64))
            if values.count == 12 { break }
        }
        return values
    }

    static func fold(_ value: String) -> String {
        clean(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
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
}
