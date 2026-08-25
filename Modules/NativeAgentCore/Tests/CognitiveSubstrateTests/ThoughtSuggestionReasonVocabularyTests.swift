import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `thoughtSeeds.suggestionReasons` (fence core.substrate.field).
//
// Same dead-label shape as the workspace reasons: every provenance string on a
// CognitiveThoughtSuggestion is a literal chosen inside one private helper
// (CognitiveSubstrate+ThoughtSeeds.swift:290). A branch that stops being taken
// costs nothing visible — the suggestion just carries a blander explanation —
// and the surface goes quiet after ~a day of priority half-life anyway, so
// nobody would notice a label stopped appearing. The one existing test pins
// two parts incidentally ("active workspace evidence", "follow-up").
//
// The interruption floor is deliberately lowered to 0 in these tests so
// REASON reachability is decoupled from SCORE ranking: this suite is about the
// vocabulary, not about which suggestion wins.
@Suite("ThoughtSuggestionReasonVocabulary")
struct ThoughtSuggestionReasonVocabularyTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                workspaceEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                maximumWorkspaceItems: 8,
                maximumThoughtSeeds: 16
            ),
            dependencies: CognitiveSubstrateDependencies(now: { Self.fixedNow })
        )
    }

    /// The kind label is the FIRST part of every reason, one per seed kind.
    private static let kindLabels: [CognitiveThoughtSeedKind: String] = [
        .reflectionTakeaway: "reflection takeaway",
        .anomaly: "anomaly",
        .followUp: "follow-up",
        .openQuestion: "open question",
    ]

    private static let contextParts: Set<String> = [
        "active workspace evidence", "task pressure", "uncertainty",
    ]

    private static var declaredVocabulary: Set<String> {
        Set(kindLabels.values).union(contextParts)
    }

    private func parts(_ reason: String) -> [String] {
        reason.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    @Test("every seed kind produces its own label, and it leads the reason")
    func everySeedKindLabelIsReachable() async throws {
        let mind = substrate()
        var seedIDsByKind: [CognitiveThoughtSeedKind: UUID] = [:]
        for kind in CognitiveThoughtSeedKind.allCases {
            let seed = try #require(await mind.addThoughtSeed(
                kind: kind,
                text: "A distinct \(kind.rawValue) thought worth returning to.",
                priority: 0.8
            ))
            seedIDsByKind[kind] = seed.id
        }

        let suggestions = await mind.thoughtSuggestionSnapshot(
            surface: "observatory", limit: 20, minimumInterruptionScore: 0)
        #expect(suggestions.count == CognitiveThoughtSeedKind.allCases.count)

        for kind in CognitiveThoughtSeedKind.allCases {
            let id = try #require(seedIDsByKind[kind])
            let suggestion = try #require(suggestions.first { $0.seedId == id })
            let label = try #require(Self.kindLabels[kind])
            #expect(parts(suggestion.reason).first == label,
                    "seed kind \(kind.rawValue) lost its provenance label")
            // With a calm field and no workspace evidence the label is the WHOLE
            // reason — so a context part appearing here would mean it fires
            // unconditionally, which is how a reason stops meaning anything.
            #expect(parts(suggestion.reason) == [label])
        }
    }

    @Test("`active workspace evidence`, `task pressure` and `uncertainty` are each reachable")
    func contextPartsAreReachable() async throws {
        let mind = substrate()
        // Two provider failures put uncertainty and task pressure above their
        // 0.35 gates and leave a workspace-eligible node behind.
        for index in 0..<2 {
            await mind.ingest(CognitiveEvent(
                id: "provider-failure-\(index)",
                kind: .providerFailure,
                subject: CognitiveSubjectReference(type: "provider", id: "anthropic-\(index)"),
                sourceClass: .observed,
                occurredAt: Self.fixedNow,
                summary: "The provider call failed mid-turn.",
                importance: 1
            ))
        }
        let affect = await mind.affectSnapshot()
        #expect(affect.uncertainty >= 0.35)
        #expect(affect.taskPressure >= 0.35)

        let workspaceNodeID = try #require(await mind.workspaceSnapshot().items.first?.node.id)
        let anchored = try #require(await mind.addThoughtSeed(
            kind: .anomaly,
            text: "The provider dropped two calls in a row — check the vitals band.",
            priority: 0.9,
            sourceNodeIds: [workspaceNodeID]
        ))
        let unanchored = try #require(await mind.addThoughtSeed(
            kind: .anomaly,
            text: "Unrelated loose end with no evidence behind it.",
            priority: 0.9
        ))

        let suggestions = await mind.thoughtSuggestionSnapshot(
            surface: "observatory", limit: 20, minimumInterruptionScore: 0)
        let anchoredReason = try #require(suggestions.first { $0.seedId == anchored.id }).reason
        let unanchoredReason = try #require(suggestions.first { $0.seedId == unanchored.id }).reason

        #expect(parts(anchoredReason).contains("active workspace evidence"))
        #expect(parts(anchoredReason).contains("task pressure"))
        #expect(parts(anchoredReason).contains("uncertainty"))
        // The workspace part is EVIDENCE-specific, not ambient: a seed with no
        // live source node must not claim it.
        #expect(!parts(unanchoredReason).contains("active workspace evidence"))
        // …while the affect-derived parts are ambient and belong on both.
        #expect(parts(unanchoredReason).contains("task pressure"))
        #expect(parts(unanchoredReason).contains("uncertainty"))
    }

    @Test("no suggestion emits a reason part outside the declared vocabulary")
    func everyEmittedPartIsDeclared() async throws {
        let mind = substrate()
        for index in 0..<2 {
            await mind.ingest(CognitiveEvent(
                id: "provider-failure-\(index)",
                kind: .providerFailure,
                subject: CognitiveSubjectReference(type: "provider", id: "anthropic-\(index)"),
                sourceClass: .observed,
                occurredAt: Self.fixedNow,
                summary: "The provider call failed mid-turn.",
                importance: 1
            ))
        }
        let workspaceNodeID = try #require(await mind.workspaceSnapshot().items.first?.node.id)
        for kind in CognitiveThoughtSeedKind.allCases {
            _ = await mind.addThoughtSeed(
                kind: kind,
                text: "A distinct \(kind.rawValue) thought worth returning to.",
                priority: 0.8,
                sourceNodeIds: [workspaceNodeID]
            )
        }

        let suggestions = await mind.thoughtSuggestionSnapshot(
            surface: "observatory", limit: 20, minimumInterruptionScore: 0)
        #expect(!suggestions.isEmpty)
        let emitted = Set(suggestions.flatMap { parts($0.reason) })
        #expect(emitted.subtracting(Self.declaredVocabulary).isEmpty,
                "undeclared suggestion reason part(s): \(emitted.subtracting(Self.declaredVocabulary).sorted())")
        #expect(Self.declaredVocabulary.subtracting(emitted).isEmpty,
                "unreachable suggestion reason part(s): \(Self.declaredVocabulary.subtracting(emitted).sorted())")
        // The reason is bounded at 160 characters; the bound must never be the
        // thing that drops a provenance part.
        #expect(suggestions.allSatisfy { $0.reason.count <= 160 })
    }
}
