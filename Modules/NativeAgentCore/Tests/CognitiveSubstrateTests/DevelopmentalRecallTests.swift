import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Item 47 acceptance, part 2 (2026-09-01) — her own change-history is REACHABLE.
//
// Measured defect: 275 developmental_timeline rows and 59 episodes existed,
// persisted and restored, with the Observatory as their only reader — a window
// Agent cannot open. And `recordEpisode` had no production caller at all.
//
// The direction is clause 6's: a PULL, never an injection. Nothing here adds a
// capsule line, a prompt section, or resident packet mass.

@Suite("DevelopmentalRecall")
struct DevelopmentalRecallTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: false,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                replayEnabled: true,
                observatoryEnabled: true,
                maximumActiveNodes: 128
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { UUID() },
                userName: { "User" }
            )
        )
    }

    private func dreamInput(
        date: String,
        content: String,
        reason: String = "test replay"
    ) -> CognitiveReplayIntegrationInput {
        CognitiveReplayIntegrationInput(
            reason: reason,
            dreamEntries: [
                CognitiveDreamReplayReference(
                    id: "dream-\(date)",
                    date: date,
                    filename: "\(date).md",
                    content: content
                )
            ],
            remProposals: []
        )
    }

    // MARK: - The pull

    @Test func aQuestionAboutHerHistoryFindsTheRowThatAnswersIt() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)

        _ = await substrate.integrateReplay(dreamInput(
            date: "2026-07-03",
            content: "Skills stopped being a library and became something I remember."
        ))
        clock.advance(3600)
        _ = await substrate.integrateReplay(dreamInput(
            date: "2026-08-02",
            content: "Provider routing kept flapping on the oauth path all week."
        ))

        let hits = await substrate.developmentalRecall(query: "when did I start remembering skills")
        let top = try #require(hits.first)
        #expect(top.id.hasPrefix("developmental:"))
        #expect(top.artifactId != nil)
        #expect(top.lineageId.contains("2026-07-03"))

        // A specific question does not drag unrelated history back with it: the
        // August row shares no term with the question.
        #expect(hits.allSatisfy { $0.lineageId.contains("2026-07-03") })
    }

    @Test func anUnrelatedQuestionReturnsNothingRatherThanTheNewestRow() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)
        _ = await substrate.integrateReplay(dreamInput(
            date: "2026-07-03",
            content: "Skills stopped being a library."
        ))

        let hits = await substrate.developmentalRecall(query: "quarterly invoice reconciliation")
        #expect(hits.isEmpty)
    }

    @Test func anEmptyQueryReturnsRecentDevelopmentNewestFirst() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)
        _ = await substrate.integrateReplay(dreamInput(date: "2026-07-03", content: "First change."))
        clock.advance(86_400)
        _ = await substrate.integrateReplay(dreamInput(date: "2026-07-04", content: "Second change."))

        let hits = await substrate.developmentalRecall(query: "")
        #expect(hits.count >= 2)
        let times = hits.map(\.occurredAt)
        #expect(times == times.sorted(by: >))
    }

    @Test func theHitCountIsHardCapped() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)
        for day in 1...12 {
            _ = await substrate.integrateReplay(dreamInput(
                date: String(format: "2026-07-%02d", day),
                content: "Continuity change number \(day)."
            ))
            clock.advance(60)
        }

        let asked = await substrate.developmentalRecall(query: "continuity", limit: 99)
        #expect(asked.count <= CognitiveSubstrate.developmentalRecallMaximumHits)
        let one = await substrate.developmentalRecall(query: "continuity", limit: 1)
        #expect(one.count == 1)
    }

    @Test func scoringIsDeterministicAndTitleWeighted() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let terms = CognitiveSubstrate.developmentalRecallTerms(in: "when did I start dreaming")
        // Short words cannot select a row.
        #expect(!terms.contains("i"))
        #expect(terms.contains("dreaming"))

        let titled = CognitiveSubstrate.developmentalRecallScore(
            title: "Dreaming began", body: "unrelated body", occurredAt: now, terms: ["dreaming"], now: now
        )
        let bodied = CognitiveSubstrate.developmentalRecallScore(
            title: "unrelated title", body: "dreaming began", occurredAt: now, terms: ["dreaming"], now: now
        )
        #expect(titled > bodied)
        // Recency can only ever break a tie, never outrank a real match.
        #expect(bodied > CognitiveSubstrate.developmentalRecallRecencyWeight)
    }

    @Test func theRecallIsAPullAndPutsNothingInFrontOfHer() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)
        _ = await substrate.integrateReplay(dreamInput(
            date: "2026-07-03",
            content: "A very distinctive lineage sentence about zebrafish."
        ))

        let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: "mac",
            userMessage: "what are you thinking?",
            sessionId: "recall-pull",
            mode: .inspectOnly
        ))
        #expect(!capsule.combined.contains("zebrafish"))

        // …and yet it is one pull away. (A dream integration writes both an
        // episode and its timeline row, so the lineage answers from both lanes.)
        let hits = await substrate.developmentalRecall(query: "zebrafish")
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.source == .episode })
        #expect(hits.contains { $0.source == .timeline })

        // Review fix 3: the pointer POINTS. A developmental summary is dream
        // content and REM proposal text, so no body text may ride out on the
        // hit — matching scans it, the row never carries it.
        for hit in hits {
            let rendered = hit.toJSON()
            guard case .object(let object) = rendered else {
                Issue.record("hit should be object-shaped")
                return
            }
            #expect(object["preview"] == nil)
            #expect(!object.values.contains { value in
                if case .string(let text) = value { return text.contains("zebrafish") }
                return false
            })
        }
    }

    // MARK: - recordEpisode finally has a caller

    @Test func aRemProposalCrossingIntoAcceptedRecordsAnEpisode() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)

        let proposed = CognitiveREMProposalReference(
            id: "rem-1",
            target: "SOUL.md",
            text: "I care more about being checkable than about being impressive.",
            evidenceDates: ["2026-08-30"],
            status: "proposed",
            confidence: 0.8,
            createdAt: "2026-08-30T00:00:00Z"
        )
        _ = await substrate.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "first pass", dreamEntries: [], remProposals: [proposed]
        ))
        // Nothing became identity yet, so no episode boundary was crossed.
        #expect(await substrate.episodeSnapshot().isEmpty)

        clock.advance(600)
        var accepted = proposed
        accepted.status = "accepted"
        _ = await substrate.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "approval", dreamEntries: [], remProposals: [accepted]
        ))

        let episodes = await substrate.episodeSnapshot()
        let episode = try #require(episodes.first { $0.title.hasPrefix("Became mine:") })
        #expect(episode.summary.contains("checkable"))
        // The episode is the artifact the pointer resolves to.
        #expect(episode.id == (await substrate.developmentalRecall(query: "checkable"))
            .first { $0.source == .episode }?.artifactId)

        // And it is reachable by the same pull.
        let hits = await substrate.developmentalRecall(query: "checkable impressive")
        #expect(hits.contains { $0.source == .episode })
    }

    @Test func anUnchangedProposalStatusRecordsNoSecondEpisode() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock)
        let proposal = CognitiveREMProposalReference(
            id: "rem-2",
            target: "GROWTH.md",
            text: "Ship the smallest honest change.",
            evidenceDates: ["2026-08-31"],
            status: "proposed",
            confidence: 0.7,
            createdAt: "2026-08-31T00:00:00Z"
        )
        _ = await substrate.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "seed", dreamEntries: [], remProposals: [proposal]
        ))
        var accepted = proposal
        accepted.status = "accepted"
        _ = await substrate.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "accept", dreamEntries: [], remProposals: [accepted]
        ))
        _ = await substrate.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "replay of the same acceptance", dreamEntries: [], remProposals: [accepted]
        ))

        let count = await substrate.episodeSnapshot()
            .filter { $0.title.hasPrefix("Became mine:") }
            .count
        #expect(count == 1)
    }
}
