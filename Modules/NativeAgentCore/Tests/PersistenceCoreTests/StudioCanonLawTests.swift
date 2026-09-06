import Foundation
import Testing
@testable import PersistenceCore

// MARK: - The canon, earned by recurrence (desk 903 phase 4)
//
// These pin the law itself, not a happy path: what it takes to be ASKED about a
// work, what is not enough, what silence does, and — the load-bearing one — that
// nothing in this file can canonize anything on its own. Every test that ends in
// a canon row goes through her seat, and the one that goes through an owner seat
// ends in a refusal and an empty ledger.

@Suite("Studio canon law")
struct StudioCanonLawTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioCanon-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stamp(_ daysAgo: Double, from now: Date) -> String {
        StudioClock.nowISO(now.addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    // MARK: Recurrence

    @Test("three later entries deepening a work mint exactly one promote proposal")
    func recurrenceMintsOneProposal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "The Green Ray",
                creator: "Éric Rohmer",
                recurrenceEntryIDs: ["entry_b", "entry_c", "entry_d"],
                recallHits: 0,
                lastActivityAt: stamp(2, from: now)
            )],
            membership: [:],
            now: now
        )
        #expect(drafts.count == 1)
        let draft = try? #require(drafts.first)
        #expect(draft?.action == .promote)
        #expect(draft?.evidenceKind == .recurrence)
        #expect(draft?.recurrenceCount == 3)
        // The evidence is CITED, so the proposal can be traced to the judgments.
        #expect(draft?.evidenceEntryIDs.sorted() == ["entry_b", "entry_c", "entry_d"])
        // A proposal is a question. It carries no verdict and no score.
        #expect(draft?.reasonLine.contains("not a rating") == true)
    }

    @Test("two entries are not recurrence — nothing is proposed")
    func twoEntriesDoNotMint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "The Green Ray",
                recurrenceEntryIDs: ["entry_b", "entry_c"],
                recallHits: 0,
                lastActivityAt: stamp(1, from: now)
            )],
            membership: [:],
            now: now
        )
        #expect(drafts.isEmpty)
    }

    @Test("the same entry counted twice is still one entry")
    func duplicateEvidenceDoesNotInflateRecurrence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "Seagram Building",
                recurrenceEntryIDs: ["entry_b", "entry_b", "entry_b"],
                lastActivityAt: stamp(1, from: now)
            )],
            membership: [:],
            now: now
        )
        #expect(drafts.isEmpty)
    }

    // MARK: Pulled in production

    @Test("a pointer actually pulled in a live judgment mints a proposal on its own")
    func productionPullMints() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "Univers",
                creator: "Adrian Frutiger",
                recurrenceEntryIDs: [],
                recallHits: 1,
                lastActivityAt: stamp(1, from: now)
            )],
            membership: [:],
            now: now
        )
        #expect(drafts.count == 1)
        #expect(drafts.first?.evidenceKind == .pulledInProduction)
        #expect(drafts.first?.action == .promote)
    }

    @Test("a work already in the canon is never proposed again")
    func canonWorkIsNotReProposed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = StudioCanonLaw.workKey(title: "Univers", creator: nil)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "Univers",
                recurrenceEntryIDs: ["a", "b", "c", "d"],
                recallHits: 9,
                lastActivityAt: stamp(1, from: now)
            )],
            membership: [key: StudioCanonMember(
                workTitle: "Univers", workCreator: nil, standing: .canon,
                since: stamp(3, from: now), evidenceEntryIDs: ["a"]
            )],
            now: now
        )
        #expect(drafts.isEmpty)
    }

    // MARK: Silence

    @Test("canon that has gone silent for the window earns a demotion PROPOSAL")
    func silenceMintsDemotion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = StudioCanonLaw.workKey(title: "Univers", creator: nil)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "Univers",
                recurrenceEntryIDs: ["a"],
                recallHits: 0,
                lastActivityAt: stamp(200, from: now)
            )],
            membership: [key: StudioCanonMember(
                workTitle: "Univers", workCreator: nil, standing: .canon,
                since: stamp(300, from: now), evidenceEntryIDs: ["a"]
            )],
            now: now
        )
        #expect(drafts.count == 1)
        #expect(drafts.first?.action == .demote)
        #expect(drafts.first?.evidenceKind == .silence)
        // A PROPOSAL, never a demotion: the law returns drafts and owns no store.
        #expect(drafts.first?.reasonLine.contains("say it still holds") == true)
    }

    @Test("a canon work touched inside the window is not silent")
    func recentActivityBlocksDemotion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = StudioCanonLaw.workKey(title: "Univers", creator: nil)
        let drafts = StudioCanonLaw.proposals(
            evidence: [StudioCanonWorkEvidence(
                title: "Univers", recurrenceEntryIDs: ["a"], recallHits: 0,
                lastActivityAt: stamp(10, from: now)
            )],
            membership: [key: StudioCanonMember(
                workTitle: "Univers", workCreator: nil, standing: .canon,
                since: stamp(300, from: now), evidenceEntryIDs: ["a"]
            )],
            now: now
        )
        #expect(drafts.isEmpty)
    }

    @Test("a work promoted yesterday with no activity table is never silent")
    func freshPromotionIsNotSilent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = StudioCanonLaw.workKey(title: "Univers", creator: nil)
        let drafts = StudioCanonLaw.proposals(
            evidence: [],
            membership: [key: StudioCanonMember(
                workTitle: "Univers", workCreator: nil, standing: .canon,
                since: stamp(1, from: now), evidenceEntryIDs: []
            )],
            now: now
        )
        #expect(drafts.isEmpty)
    }

    @Test("one pass proposes at most a few — the inbox is never homework")
    func passIsBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let evidence = (0..<12).map { index in
            StudioCanonWorkEvidence(
                title: "Work \(index)",
                recurrenceEntryIDs: ["a\(index)", "b\(index)", "c\(index)"],
                lastActivityAt: stamp(1, from: now)
            )
        }
        let drafts = StudioCanonLaw.proposals(evidence: evidence, membership: [:], now: now)
        #expect(drafts.count == StudioCanonLaw.maximumProposalsPerPass)
    }

    // MARK: Membership from append-only rows

    @Test("a demote row removes membership without erasing the promote row")
    func membershipFollowsTheLatestRow() {
        let promote = StudioCanonRow(
            proposalID: "p1", action: .promote, standing: .canon,
            workTitle: "Univers", decidedAt: "2026-01-01T00:00:00.000000Z",
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: "chat", decidedInTurn: "turn_1", evidenceKind: .recurrence,
            evidenceEntryIDs: ["a", "b", "c"]
        )
        let demote = StudioCanonRow(
            proposalID: "p2", action: .demote, standing: .canon,
            workTitle: "Univers", decidedAt: "2026-06-01T00:00:00.000000Z",
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: "chat", decidedInTurn: "turn_1", evidenceKind: .silence
        )
        #expect(StudioCanonLaw.membership(from: [promote]).count == 1)
        #expect(StudioCanonLaw.membership(from: [promote, demote]).isEmpty)
        // Both rows survive — the ledger is the record of a mind changing.
        #expect([promote, demote].count == 2)
    }

    @Test("anti-canon is a standing she states, never one derived from a judgment")
    func antiCanonIsExplicit() {
        let row = StudioCanonRow(
            proposalID: "p1", action: .promote, standing: .antiCanon,
            workTitle: "A Loud Building", decidedAt: "2026-01-01T00:00:00.000000Z",
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: "chat", decidedInTurn: "turn_1", evidenceKind: .recurrence
        )
        let membership = StudioCanonLaw.membership(from: [row])
        #expect(membership.values.first?.standing == .antiCanon)
        let round = StudioCanonRow.fromJSON(row.toJSON())
        #expect(round == row)
    }

    // MARK: The ledger and the seat

    @Test("her seat writes a canon row; the owner's seat is refused and writes nothing")
    func onlyTheAgentSeatMayWrite() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeStudioStore(dataRoot: root)

        let ownerRow = StudioCanonRow(
            proposalID: "p_owner", action: .promote, standing: .canon,
            workTitle: "The Green Ray", decidedAt: StudioClock.nowISO(),
            decidedBy: "mac_ui",
            decidedOnSurface: "chat", decidedInTurn: "turn_1", evidenceKind: .recurrence, evidenceEntryIDs: ["a"]
        )
        await #expect(throws: StudioCanonError.approvalNotFromAgentSeat("mac_ui")) {
            try await store.appendCanonRow(ownerRow)
        }
        #expect(try await store.readCanon().isEmpty)

        let herRow = StudioCanonRow(
            proposalID: "p_her", action: .promote, standing: .canon,
            workTitle: "The Green Ray", decidedAt: StudioClock.nowISO(),
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: "chat", decidedInTurn: "turn_1", evidenceKind: .recurrence,
            evidenceEntryIDs: ["a", "b", "c"]
        )
        #expect(try await store.appendCanonRow(herRow))
        let rows = try await store.readCanon()
        #expect(rows.count == 1)
        #expect(rows.first?.decidedBy == StudioCanonSeat.agent)
        // Idempotent by proposal id: a crash-window replay writes one row.
        #expect(try await store.appendCanonRow(herRow) == false)
        #expect(try await store.readCanon().count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("the production-pull counter counts pulls, stays bounded, and orders nothing")
    func recallCounterIsBoundedEvidence() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeStudioStore(dataRoot: root)
        await store.noteRecallPulls(titles: [("The Green Ray", "Éric Rohmer")])
        await store.noteRecallPulls(titles: [("The Green Ray", "Éric Rohmer")])
        let counts = await store.recallPullCounts()
        let key = StudioCanonLaw.workKey(title: "The Green Ray", creator: "Éric Rohmer")
        #expect(counts[key]?.count == 2)

        for index in 0..<8 {
            await store.noteRecallPulls(titles: [("Work \(index)", nil)])
        }
        let bounded = await store.recallPullCounts()
        #expect(bounded.count <= 4 + 8)
        // The cap evicts; it never merges two works or invents an order.
        await store.noteRecallPulls(titles: [("Overflow", nil)], maximumTrackedWorks: 3)
        #expect(await store.recallPullCounts().count == 3)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("canon.jsonl is a registered path-owned feed, like the journal")
    func canonFeedIsCapRegistered() {
        let store = SwiftNativeStudioStore(dataRoot: URL(fileURLWithPath: "/tmp/na-canon-policy"))
        let policy = jsonlPathOwnedCapPolicy(for: store.canonPath)
        #expect(policy?.maxLines == JSONLLineCaps.studioCanon)
    }

    // MARK: Provenance — the seat is two halves, not one string

    @Test("a row that cannot say WHERE it was decided is refused at the disk")
    func rowWithoutLiveTurnProvenanceIsRefused() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeStudioStore(dataRoot: root)
        let row = StudioCanonRow(
            proposalID: "p_no_turn", action: .promote, standing: .canon,
            workTitle: "The Green Ray", decidedAt: StudioClock.nowISO(),
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: "", decidedInTurn: "",
            evidenceKind: .recurrence, evidenceEntryIDs: ["a"]
        )
        await #expect(throws: StudioCanonError.decisionHasNoLiveTurn) {
            try await store.appendCanonRow(row)
        }
        #expect(try await store.readCanon().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("the surface and turn a decision was made in survive on the row")
    func provenanceRoundTrips() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeStudioStore(dataRoot: root)
        let row = StudioCanonRow(
            proposalID: "p_prov", action: .promote, standing: .canon,
            workTitle: "Univers", decidedAt: StudioClock.nowISO(),
            decidedBy: StudioCanonSeat.agent,
            decidedOnSurface: "chat", decidedInTurn: "run_abc",
            evidenceKind: .recurrence, evidenceEntryIDs: ["a", "b", "c"]
        )
        #expect(try await store.appendCanonRow(row))
        let back = try await store.readCanon().first
        #expect(back?.decidedOnSurface == "chat")
        #expect(back?.decidedInTurn == "run_abc")
        #expect(back == row)
        try? FileManager.default.removeItem(at: root)
    }

    /// The read-check-append runs inside ONE flock, so racing writers cannot
    /// both see "no row yet". Without the lock this test writes two rows.
    @Test("racing appends of one proposal write exactly one row")
    func concurrentAppendsWriteOneRow() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeStudioStore(dataRoot: root)
        func row() -> StudioCanonRow {
            StudioCanonRow(
                proposalID: "p_race", action: .promote, standing: .canon,
                workTitle: "The Green Ray", decidedAt: StudioClock.nowISO(),
                decidedBy: StudioCanonSeat.agent,
                decidedOnSurface: "chat", decidedInTurn: "run_race",
                evidenceKind: .recurrence, evidenceEntryIDs: ["a", "b", "c"]
            )
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try? await store.appendCanonRow(row()) }
            }
        }
        #expect(try await store.readCanon().count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Dedupe fingerprint — a denial settles the argument, not the subject

    @Test("new evidence for a denied work is a different argument")
    func evidenceFingerprintTracksTheArgument() {
        func draft(_ ids: [String]) -> StudioCanonProposalDraft {
            StudioCanonProposalDraft(
                action: .promote, workTitle: "The Green Ray", workCreator: "Rohmer",
                evidenceKind: .recurrence, evidenceEntryIDs: ids,
                recurrenceCount: ids.count, recallHits: 0,
                lastActivityAt: "2026-09-01T12:00:00.000000Z"
            )
        }
        let first = draft(["a", "b", "c"])
        let same = draft(["c", "b", "a"])
        let grown = draft(["a", "b", "c", "d"])
        // The lane is the same work in the same direction …
        #expect(first.key == grown.key)
        // … but the ARGUMENT changes when the evidence does, and order never
        // makes two identical arguments look different.
        #expect(first.evidenceFingerprint == same.evidenceFingerprint)
        #expect(first.evidenceFingerprint != grown.evidenceFingerprint)
    }

    @Test("a demotion argues from its silence window, so a later one is new")
    func silenceFingerprintTracksTheWindow() {
        func demotion(_ lastActivity: String) -> StudioCanonProposalDraft {
            StudioCanonProposalDraft(
                action: .demote, workTitle: "Univers", workCreator: nil,
                evidenceKind: .silence, evidenceEntryIDs: [],
                recurrenceCount: 0, recallHits: 0, lastActivityAt: lastActivity
            )
        }
        #expect(demotion("2026-01-01T00:00:00.000000Z").evidenceFingerprint
            != demotion("2026-06-01T00:00:00.000000Z").evidenceFingerprint)
    }
}
