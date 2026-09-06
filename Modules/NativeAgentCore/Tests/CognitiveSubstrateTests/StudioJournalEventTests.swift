import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

/// Desk 903 phase 2 — "Journal rides the cognitive event bus."
///
/// The agent's requirement, verbatim: "delta comes from the ENTRY, not the act:
/// sign from `stance`, magnitude from the response actually written; a neutral
/// entry moves nothing; no fixed '+0.1 for filing'."
@Suite("Studio journal on the cognitive bus")
struct StudioJournalEventTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 32
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { self.t0 }, makeUUID: { UUID() }, userName: { "" }
            )
        )
    }

    // MARK: - The law

    @Test("an abstention moves nothing, whatever it says")
    func abstentionIsStill() async {
        let felt = await substrate().studioJournalFelt(for: entry(
            id: "e_abstain",
            stance: .abstained,
            // Deliberately full of lexicon-positive words: the stance gate runs
            // FIRST so nothing can smuggle a delta onto a deliberate abstention.
            response: "Perfect, exactly right, that helped — but I have not seen enough of it."
        ))
        #expect(felt == .still)
    }

    @Test("a judgment that lands on nothing moves nothing — there is no fee for filing")
    func neutralEntryIsStill() async {
        let felt = await substrate().studioJournalFelt(for: entry(
            id: "e_neutral",
            response: "A five-panel sequence, printed on uncoated stock, dated 1974."
        ))
        #expect(felt == .still, "silence is the default; a flat delta for filing is not")
    }

    @Test("the sign and the size come from the response she actually wrote")
    func responseSignsAndSizesTheDelta() async {
        let s = substrate()
        let warm = await s.studioJournalFelt(for: entry(
            id: "e_warm", response: "This is exactly right — the restraint is what makes it land."
        ))
        let cold = await s.studioJournalFelt(for: entry(
            id: "e_cold", response: "Sloppy. It is over-engineered and it disappoints on every page."
        ))
        #expect(warm.valence > 0)
        #expect(cold.valence < 0)
        #expect(abs(warm.valence) <= CognitiveSubstrate.studioJournalFeltCeiling)
        #expect(abs(cold.valence) <= CognitiveSubstrate.studioJournalFeltCeiling)
    }

    @Test("a stance still forming moves less than a settled one")
    func openStanceIsDamped() async {
        let s = substrate()
        let response = "This is exactly right — the restraint is what makes it land."
        let formed = await s.studioJournalFelt(for: entry(id: "e_f", response: response))
        let open = await s.studioJournalFelt(
            for: entry(id: "e_o", stance: .open, response: response)
        )
        #expect(open.valence > 0)
        #expect(open.valence < formed.valence)
    }

    /// A description-only consult can never become an entry — the store refuses
    /// it at both ends. The nearest thing that CAN reach the bus is an entry
    /// with no refs of its own, and it is weighted down.
    @Test("an entry carrying no artifact refs is weighted down")
    func refslessEntryIsWeightedDown() async {
        let s = substrate()
        let response = "This is exactly right — the restraint is what makes it land."
        let withRefs = await s.studioJournalFelt(
            for: entry(id: "e_r", response: response, refs: ["/tmp/plate.png"])
        )
        let withoutRefs = await s.studioJournalFelt(for: entry(id: "e_n", response: response))
        #expect(withoutRefs.valence > 0)
        #expect(withoutRefs.valence < withRefs.valence)
    }

    // MARK: - The event

    /// THE DREAM-CITATION SEAM. The dream felt-summary owner reads the felt
    /// node's subject and metadata to say what a feeling came from. Both carry
    /// the entry id, so the citation can be written without touching this lane.
    @Test("the event carries the entry id so the dream can cite it")
    func eventCarriesTheEntryIDForCitation() async {
        let event = await substrate().studioJournalEvent(for: entry(
            id: "entry_20260901T120000_abcd",
            title: "The Green Ray",
            response: "This is exactly right — the restraint is what makes it land."
        ))
        let minted = try? #require(event)
        #expect(minted?.subject.type == "studio_entry")
        #expect(minted?.subject.id == "entry_20260901T120000_abcd")
        #expect(minted?.metadata[CognitiveEvent.studioEntryIDMetadataKey]
            == .string("entry_20260901T120000_abcd"))
        #expect(minted?.metadata[CognitiveEvent.studioStanceMetadataKey] == .string("formed"))
        // The summary names the ACT. Her judgment stays in the journal.
        #expect(minted?.summary.contains("The Green Ray") == true)
        #expect(minted?.summary.contains("restraint") == false)
    }

    @Test("the entry's measured feeling lands on the node as-is")
    func measuredFeelingLandsOnTheNode() async {
        let s = substrate()
        let entry = entry(
            id: "entry_felt",
            title: "The Green Ray",
            response: "Sloppy. It is over-engineered and it disappoints on every page.",
            refs: ["/tmp/plate.png"]
        )
        let expected = await s.studioJournalFelt(for: entry)
        await s.ingestStudioJournalEntry(entry)
        let node = await s.snapshot().nodes.first { $0.subjectReference.id == "entry_felt" }
        let stamped = try? #require(node)
        #expect(stamped != nil)
        #expect(abs((stamped?.emotionalValence ?? 0) - expected.valence) < 0.0001)
        #expect(expected.valence < 0)
    }

    /// No fixed delta for the ACT of filing: a neutral entry leaves affect
    /// exactly where it found it.
    @Test("filing a neutral entry moves affect not at all")
    func filingItselfMovesNoAffect() async {
        let s = substrate()
        let before = await s.affectSnapshot()
        await s.ingestStudioJournalEntry(entry(
            id: "entry_flat",
            response: "A five-panel sequence, printed on uncoated stock, dated 1974."
        ))
        let after = await s.affectSnapshot()
        #expect(before.arousal == after.arousal)
        #expect(before.uncertainty == after.uncertainty)
        #expect(before.taskPressure == after.taskPressure)
        #expect(before.socialWarmth == after.socialWarmth)
    }

    /// The event id is derived from the entry id, so a replay is inert — the
    /// journal is append-only and an entry is one moment, not a repeating one.
    @Test("re-ingesting the same entry is inert")
    func replayIsInert() async {
        let s = substrate()
        let e = entry(id: "entry_once", response: "This is exactly right.")
        await s.ingestStudioJournalEntry(e)
        let first = await s.snapshot().nodes.count
        await s.ingestStudioJournalEntry(e)
        #expect(await s.snapshot().nodes.count == first)
    }

    // MARK: - The seam

    @Test("the bus delivers a filed entry to the installed sink")
    func busDeliversToTheInstalledSink() async {
        let inbox = EntryInbox()
        await StudioJournalCognitiveBus.install { await inbox.record($0.id) }
        #expect(await StudioJournalCognitiveBus.isInstalled)
        await StudioJournalCognitiveBus.publish(entry(id: "entry_bus"))
        #expect(await inbox.ids == ["entry_bus"])
        // Leave the process bus as we found it for any suite that runs after.
        await StudioJournalCognitiveBus.install { _ in }
    }

    // MARK: - Fixtures

    private actor EntryInbox {
        private(set) var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
    }

    private func entry(
        id: String,
        title: String = "A Work",
        stance: StudioStance = .formed,
        response: String? = "A judgment, written out.",
        refs: [String] = []
    ) -> StudioJournalEntry {
        StudioJournalEntry(
            id: id,
            encounteredAt: "2026-09-01T12:00:00.000000Z",
            recordedAt: "2026-09-01T12:00:00.000000Z",
            work: StudioWork(title: title, creator: "Someone", medium: "film"),
            artifactRefs: refs,
            origin: StudioOrigin(kind: .wandering),
            response: response,
            stance: StudioStanceValue(kind: stance)
        )
    }
}
