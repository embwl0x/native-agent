import Foundation
import Testing
import PersistenceCore
import GRDB
@testable import CognitiveSubstrate

// Felt dreams — the substrate read half. `feltDaySummary(at:)` is a PURE read
// (peekNodes + derivedMood) that hands the nightly dream ONE bounded summary of
// what the last ~24h FELT like, or nil when nothing was felt / affect is off so
// the dream section can be omitted (silence stays silence). Proves:
//  (1) a felt warm day → the mood-band language + a felt-direction word, ≤600 chars;
//  (2) neutral/legacy field → nil;
//  (3) felt nodes older than the 24h window are excluded;
//  (4) affect disabled → nil;
//  (5) the read never mutates the field.
@Suite("FeltDreams")
struct FeltDreamsTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    }

    private func config(affectEnabled: Bool = true) -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: affectEnabled,
            maximumActiveNodes: 256
        )
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-felt-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A node with an EXACT emotional tag and controllable activation recency.
    private func node(
        summary: String,
        kind: CognitiveNodeKind = .conversationFocus,
        valence: Double,
        arousal: Double,
        warmth: Double,
        createdAt: Date,
        lastActivatedAt: Date
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: kind,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "felt-\(UUID().uuidString)", label: "topic"),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: createdAt, lastActivatedAt: lastActivatedAt,
            decayHalfLife: 10_000, summary: summary, metadata: [:],
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth)
    }

    /// A felt node shaped exactly like the one the studio seam mints
    /// (CognitiveSubstrate+StudioEvents.swift): `.conversationFocus` from an
    /// `assistantTurnCompleted`, subject type "studio_entry" with the entry id
    /// and the work title as its label, and the entry id in metadata too.
    private func studioNode(
        entryID: String,
        title: String?,
        summary: String,
        valence: Double,
        arousal: Double,
        warmth: Double,
        createdAt: Date,
        lastActivatedAt: Date,
        kind: CognitiveNodeKind = .conversationFocus,
        subjectType: String = "studio_entry"
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: kind,
            subjectReference: CognitiveSubjectReference(type: subjectType, id: entryID, label: title),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .selfReported,
            createdAt: createdAt, lastActivatedAt: lastActivatedAt,
            decayHalfLife: 10_000, summary: summary,
            metadata: ["studioEntryId": .string(entryID), "turnKind": .string("live")],
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth)
    }

    private func substrate(
        with nodes: [CognitiveNode], clock: Clock, label: String, affectEnabled: Bool = true
    ) async throws -> CognitiveSubstrate {
        let root = try tempDataRoot(label)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        try await store.saveNodes(nodes, at: clock.now())
        let substrate = CognitiveSubstrate(
            configuration: config(affectEnabled: affectEnabled),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store
        )
        try await substrate.restorePersistentState()
        return substrate
    }

    // MARK: - (1) a felt warm day summarizes with band language + direction words

    @Test func warmDayProducesBandLanguageAndDirectionWord() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: "User and I are planning the weekend", valence: 0.6, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
                node(summary: "we shipped the felt layer together", valence: 0.6, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
                node(summary: "a good, warm exchange", valence: 0.6, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "warm")
        let summary = try #require(await s.feltDaySummary(at: clock.now()), "warm felt day should produce a summary")
        #expect(summary.contains("the day has a good feel"), "missing mood-band language: \(summary)")
        #expect(summary.contains("warm"), "missing felt-direction word: \(summary)")
        #expect(summary.contains("planning the weekend"), "missing node signal: \(summary)")
        #expect(summary.contains("felt moment"), "missing the felt-moment basis count: \(summary)")
        #expect(summary.count <= 600, "summary must be bounded ≤600 chars: \(summary.count)")
    }

    /// NO NEW EXPOSURE (gpt-5.5 HIGH, 2026-07-02): felt tool/system/execution
    /// nodes may feed the mood-band COUNT, but their summaries must NEVER be
    /// named — the dream prompt deliberately drops tool rows, so a felt
    /// toolObservation riding in through the felt section would be a brand-new
    /// injection surface. Only live conversationFocus/correction get named.
    @Test func feltToolAndSystemNodesAreNeverNamed() async throws {
        let now = Date(timeIntervalSince1970: 1_300_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: "a warm exchange about the roadmap", valence: 0.4, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now),
                // Stronger-felt than the conversation node — would out-rank it
                // if the population weren't filtered.
                node(summary: "SECRET-TOOL-OUTPUT sk-deadbeef result blob", kind: .toolObservation, valence: 0.9, arousal: 0.9, warmth: 0.9, createdAt: now, lastActivatedAt: now),
                node(summary: "PROVIDER-FAILURE trace with endpoint internals", kind: .providerHealth, valence: -0.9, arousal: 0.9, warmth: 0.0, createdAt: now, lastActivatedAt: now),
                node(summary: "EXECUTION-INTERNAL summary of scheduled job", kind: .workshopExecution, valence: 0.8, arousal: 0.8, warmth: 0.8, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "no-tool-naming")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        #expect(!summary.contains("SECRET-TOOL-OUTPUT"), "tool summary leaked into the dream felt section: \(summary)")
        #expect(!summary.contains("PROVIDER-FAILURE"), "provider summary leaked: \(summary)")
        #expect(!summary.contains("EXECUTION-INTERNAL"), "execution summary leaked: \(summary)")
        #expect(summary.contains("roadmap"), "the conversation memory should still be named: \(summary)")
        // The band count still integrates over all felt nodes (a count carries
        // no content) — 4 felt moments here.
        #expect(summary.contains("4 felt moments"), "band count should cover all felt nodes: \(summary)")
    }

    // MARK: - (1b) studio journal entries are NAMED, by pointer (Agent, 2026-09-01)

    /// A day shaped by the studio must SAY so: the entry is named by its work
    /// title and cited by id in the dream's `(studio entry <id>)` form, so the
    /// band's provenance is not misattributed to whatever conversation was near.
    @Test func studioEntryIsNamedByTitleAndCitedByID() async throws {
        let now = Date(timeIntervalSince1970: 1_400_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                studioNode(
                    entryID: "entry-42", title: "Blue Nude II",
                    summary: "Journal entry on Blue Nude II — stance formed.",
                    valence: 0.7, arousal: 0.4, warmth: 0.3,
                    createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "studio-named")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        #expect(summary.contains("Blue Nude II"), "the work title should name the line: \(summary)")
        #expect(summary.contains("(studio entry entry-42)"),
                "the entry id should be cited the dream's way: \(summary)")
        #expect(summary.contains("1 felt moment"), "the band still counts the entry: \(summary)")
    }

    /// The exposure rule stands for CONTENT: the entry's own text — which the
    /// seam's node summary is free to carry — must never ride the named line.
    @Test func studioEntryResponseTextIsNeverNamed() async throws {
        let now = Date(timeIntervalSince1970: 1_410_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                studioNode(
                    entryID: "entry-77", title: "Woman with a Hat",
                    summary: "RESPONSE-TEXT-SHE-WROTE about the sitter's face",
                    valence: 0.8, arousal: 0.4, warmth: 0.3,
                    createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "studio-no-content")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        #expect(!summary.contains("RESPONSE-TEXT-SHE-WROTE"),
                "the entry's own text must never be named: \(summary)")
        #expect(summary.contains("Woman with a Hat (studio entry entry-77)"),
                "the pointer — title + id — is what gets named: \(summary)")
    }

    /// No title on the node → the id alone is a complete pointer.
    @Test func titlelessStudioEntryCitesTheIDAlone() async throws {
        let now = Date(timeIntervalSince1970: 1_420_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                studioNode(
                    entryID: "entry-99", title: nil,
                    summary: "Journal entry — stance open.",
                    valence: -0.6, arousal: 0.4, warmth: 0.1,
                    createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "studio-untitled")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        let bullet = try #require(summary.split(separator: "\n").first { $0.hasPrefix("- ") })
        #expect(bullet.hasSuffix("(studio entry entry-99)"), "id-only citation expected: \(bullet)")
        #expect(!bullet.contains("stance open"), "the summary text must not be named: \(bullet)")
    }

    /// Carrying the metadata key is not a way in: a felt TOOL node stays unnamed
    /// even when it claims a studio entry id, because it is not a studio subject.
    @Test func toolNodeClaimingAStudioEntryIDIsStillNeverNamed() async throws {
        let now = Date(timeIntervalSince1970: 1_430_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: "a warm exchange about the roadmap", valence: 0.3, arousal: 0.1, warmth: 0.5,
                     createdAt: now, lastActivatedAt: now),
                studioNode(
                    entryID: "entry-forged", title: "FORGED-LABEL",
                    summary: "SECRET-TOOL-OUTPUT sk-deadbeef",
                    valence: 0.9, arousal: 0.9, warmth: 0.9,
                    createdAt: now, lastActivatedAt: now,
                    kind: .toolObservation, subjectType: "tool"),
            ],
            clock: clock, label: "studio-forged")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        #expect(!summary.contains("SECRET-TOOL-OUTPUT"), "tool summary leaked: \(summary)")
        #expect(!summary.contains("FORGED-LABEL"), "tool label leaked: \(summary)")
        #expect(!summary.contains("entry-forged"), "forged citation leaked: \(summary)")
        #expect(summary.contains("roadmap"), "the conversation memory should still be named: \(summary)")
    }

    /// The cap and the ordering are untouched: 6 felt nodes still name 4, and the
    /// strongest-felt studio entry sorts ahead of weaker conversation memories.
    @Test func studioEntriesKeepTheCapAndTheRanking() async throws {
        let now = Date(timeIntervalSince1970: 1_440_000)
        let clock = Clock(now)
        var nodes: [CognitiveNode] = []
        for idx in 0..<5 {
            nodes.append(node(summary: "felt-node-\(idx)", valence: 0.4, arousal: 0.1, warmth: 0.5,
                              createdAt: now, lastActivatedAt: now))
        }
        nodes.append(studioNode(
            entryID: "entry-1", title: "The Dance",
            summary: "Journal entry on The Dance — stance formed.",
            valence: 0.9, arousal: 0.5, warmth: 0.3,
            createdAt: now, lastActivatedAt: now))
        let s = try await substrate(with: nodes, clock: clock, label: "studio-cap")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        let bullets = summary.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(bullets.count == 4, "the named-line cap must hold: \(bullets.count)")
        #expect(bullets.first?.contains("(studio entry entry-1)") == true,
                "the strongest-felt node still ranks first: \(summary)")
        #expect(summary.contains("6 felt moments"), "the band counts every felt node: \(summary)")
        #expect(summary.count <= 600, "summary must stay bounded ≤600 chars: \(summary.count)")
    }

    /// A felt LOW day reads with the heavy-band language and the stung direction.
    @Test func heavyDayProducesHeavyBandAndStungWord() async throws {
        let now = Date(timeIntervalSince1970: 1_100_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: "a correction that landed hard", valence: -0.6, arousal: 0.3, warmth: 0.1, createdAt: now, lastActivatedAt: now),
                node(summary: "the tool kept failing", valence: -0.6, arousal: 0.3, warmth: 0.1, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "heavy")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        #expect(summary.contains("the day's been heavy"), "missing heavy-band language: \(summary)")
        #expect(summary.contains("stung"), "missing stung direction word: \(summary)")
        #expect(summary.count <= 600)
    }

    /// Only up to the 4 strongest-felt nodes are named — a 6-felt-node day names 4.
    @Test func summaryNamesAtMostFourNodes() async throws {
        let now = Date(timeIntervalSince1970: 1_200_000)
        let clock = Clock(now)
        var nodes: [CognitiveNode] = []
        for idx in 0..<6 {
            nodes.append(node(summary: "felt-node-\(idx)", valence: 0.5, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now))
        }
        let s = try await substrate(with: nodes, clock: clock, label: "cap-nodes")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        let bulletLines = summary.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(bulletLines.count == 4, "at most 4 felt nodes should be named: \(bulletLines.count)")
        #expect(summary.contains("6 felt moments"), "basis count should reflect all 6 felt nodes: \(summary)")
    }

    // MARK: - (2) neutral / legacy field → nil

    @Test func neutralLegacyFieldReturnsNil() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: "legacy one", valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now),
                node(summary: "legacy two", valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "neutral")
        let summary = await s.feltDaySummary(at: clock.now())
        #expect(summary == nil, "a neutral/legacy field must be felt-silent: \(String(describing: summary))")
    }

    @Test func emptyFieldReturnsNil() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 2_100_000))
        let s = try await substrate(with: [], clock: clock, label: "empty")
        #expect(await s.feltDaySummary(at: clock.now()) == nil)
    }

    // MARK: - (3) >24h-old felt nodes excluded

    @Test func staleFeltNodesExcluded() async throws {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let clock = Clock(now)
        let fresh = node(summary: "FRESH-FELT-TODAY", valence: 0.6, arousal: 0.1, warmth: 0.6,
                         createdAt: now, lastActivatedAt: now)
        let stale = node(summary: "STALE-FELT-YESTERDAY", valence: 0.6, arousal: 0.1, warmth: 0.6,
                         createdAt: now.addingTimeInterval(-25 * 60 * 60),
                         lastActivatedAt: now.addingTimeInterval(-25 * 60 * 60))
        let s = try await substrate(with: [fresh, stale], clock: clock, label: "stale")
        let summary = try #require(await s.feltDaySummary(at: clock.now()))
        #expect(summary.contains("FRESH-FELT-TODAY"), "fresh felt node must appear: \(summary)")
        #expect(!summary.contains("STALE-FELT-YESTERDAY"), "the >24h felt node must be excluded: \(summary)")
        #expect(summary.contains("1 felt moment"), "only the one in-window felt node counts: \(summary)")
    }

    /// A field whose ONLY felt node is stale → nothing felt in the window → nil.
    @Test func onlyStaleFeltNodeReturnsNil() async throws {
        let now = Date(timeIntervalSince1970: 3_100_000)
        let clock = Clock(now)
        let stale = node(summary: "only felt thing was long ago", valence: 0.6, arousal: 0.1, warmth: 0.6,
                         createdAt: now.addingTimeInterval(-30 * 60 * 60),
                         lastActivatedAt: now.addingTimeInterval(-30 * 60 * 60))
        let s = try await substrate(with: [stale], clock: clock, label: "only-stale")
        #expect(await s.feltDaySummary(at: clock.now()) == nil)
    }

    // MARK: - (4) affect disabled → nil

    @Test func affectDisabledReturnsNil() async throws {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: "would be warm if affect were on", valence: 0.6, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "affect-off", affectEnabled: false)
        #expect(await s.feltDaySummary(at: clock.now()) == nil, "affect disabled → whole construct off → nil")
    }

    // MARK: - (5) the read never mutates the field

    @Test func feltDaySummaryDoesNotMutateField() async throws {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let clock = Clock(now)
        let n = node(summary: "stable felt topic", valence: 0.5, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now)
        let s = try await substrate(with: [n], clock: clock, label: "no-mutate")

        let before = try #require(await s.snapshot().nodes.first { $0.summary == "stable felt topic" })
        _ = await s.feltDaySummary(at: now.addingTimeInterval(30 * 24 * 60 * 60))  // far-future read
        let after = try #require(await s.snapshot().nodes.first { $0.summary == "stable felt topic" },
                                 "node must survive a future-dated felt read")
        #expect(after.activation == before.activation,
                "felt read must not decay activation: \(before.activation) -> \(after.activation)")
        #expect(after.salience == before.salience)
    }
}
