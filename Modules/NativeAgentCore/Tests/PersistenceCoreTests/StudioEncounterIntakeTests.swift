import Foundation
import Testing
@testable import PersistenceCore

/// Desk 903 phase 1, the INTAKE half: what is actually in reach.
///
/// User's nudges are "invitations left on a table, never assignments", and a
/// consult with real refs is exactly that shape. These pin that only real,
/// unanswered, receivable things reach the queue.
@Suite("Studio encounter intake")
struct StudioEncounterIntakeTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioIntake-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a consult with real refs and no entry is an invitation on the table")
    func unansweredConsultIsIntake() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        let consult = try await store.fileConsult(
            artifactRefs: ["/tmp/cover-a.png"],
            description: nil,
            portionAvailable: "the full cover",
            question: "Does this hold up at thumbnail size?",
            projectContext: nil, stage: nil, constraints: nil, priorDiscussion: nil,
            descriptionOnly: false
        )
        let intake = try await store.namedEncounterIntake()
        #expect(intake.count == 1)
        #expect(intake.first?.source == .named)
        #expect(intake.first?.originID == consult.id)
        #expect(intake.first?.reference == "/tmp/cover-a.png")
        // A consult carries refs, not a title. Inventing one would be exactly
        // the dishonesty the honest-encounter rule exists to prevent.
        #expect(intake.first?.title == nil)
    }

    /// Her hardest veto, at the intake end: a description-only consult can never
    /// become an encounter, so it can never become an invitation to one either.
    @Test("a description-only consult is never an invitation")
    func descriptionOnlyIsNeverIntake() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        _ = try await store.fileConsult(
            artifactRefs: [],
            description: "A concept for a reissue series — no artwork yet.",
            portionAvailable: nil,
            question: "Is the idea any good?",
            projectContext: nil, stage: nil, constraints: nil, priorDiscussion: nil,
            descriptionOnly: true
        )
        #expect(try await store.namedEncounterIntake().isEmpty)
    }

    @Test("a consult she already answered leaves the table")
    func answeredConsultLeavesIntake() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        let consult = try await store.fileConsult(
            artifactRefs: ["/tmp/cover-a.png"],
            description: nil, portionAvailable: nil,
            question: "Does this hold up?",
            projectContext: nil, stage: nil, constraints: nil, priorDiscussion: nil,
            descriptionOnly: false
        )
        #expect(try await store.namedEncounterIntake().count == 1)

        _ = try await store.appendJournalEntry(
            encounteredAt: nil,
            work: StudioWork(title: "Cover A", creator: "Someone", medium: "print"),
            reception: StudioReception(how: "reproduction", wholeOrPart: "whole"),
            artifactRefs: ["/tmp/cover-a.png"],
            origin: StudioOrigin(kind: .consult, ref: consult.id),
            response: "It survives the thumbnail; the type does not.",
            stance: StudioStanceValue(kind: .formed),
            relations: [],
            tags: []
        )
        #expect(try await store.namedEncounterIntake().isEmpty,
                "something she has written about is not unattended")
    }

    /// The same artifact answered under a different origin still counts as
    /// attended: the ref is the thing, not the paperwork around it.
    @Test("an entry sharing the artifact answers the consult too")
    func sharedRefCountsAsAnswered() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        _ = try await store.fileConsult(
            artifactRefs: ["/tmp/cover-a.png"],
            description: nil, portionAvailable: nil,
            question: "Does this hold up?",
            projectContext: nil, stage: nil, constraints: nil, priorDiscussion: nil,
            descriptionOnly: false
        )
        _ = try await store.appendJournalEntry(
            encounteredAt: nil,
            work: StudioWork(title: "Cover A"),
            reception: StudioReception(),
            artifactRefs: ["/tmp/cover-a.png"],
            origin: StudioOrigin(kind: .wandering),
            response: "Seen it, judged it.",
            stance: StudioStanceValue(kind: .formed),
            relations: [],
            tags: []
        )
        #expect(try await store.namedEncounterIntake().isEmpty)
    }

    @Test("journaled titles come back folded for the graph half of the intake")
    func journaledTitlesAreFolded() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        _ = try await store.appendJournalEntry(
            encounteredAt: nil,
            work: StudioWork(title: "The Green Ray", creator: "Éric Rohmer"),
            reception: StudioReception(),
            artifactRefs: ["/tmp/still.png"],
            origin: StudioOrigin(kind: .wandering),
            response: "A judgment.",
            stance: StudioStanceValue(kind: .formed),
            relations: [],
            tags: []
        )
        let titles = try await store.journaledWorkTitles()
        #expect(titles.contains("the green ray"))
    }
}
