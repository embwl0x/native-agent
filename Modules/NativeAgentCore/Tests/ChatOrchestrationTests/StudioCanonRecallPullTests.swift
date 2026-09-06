import Context
import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
@testable import PersistenceCore

/// "Pulled in production" is one of the two doors into the canon, so what counts
/// as a pull decides what can become canon. The first cut counted EVERY
/// successful `studio_recall`, which meant she could promote a work into her own
/// museum by browsing her journal — and a bridge, a tending pass or a replay
/// could do it for her.
///
/// Two runtime-derived conditions now gate the counter, both required and
/// neither readable from tool input: the same live-local-turn provenance the
/// canon seat demands, and the projection's own taste-judgment admission rule.
@Suite("Studio recall production pulls")
struct StudioCanonRecallPullTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioRecallPull-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seedJournal(_ root: URL) async throws {
        _ = try await SwiftNativeStudioStore(dataRoot: root).appendJournalEntry(
            encounteredAt: nil,
            work: StudioWork(title: "The Green Ray", creator: "Éric Rohmer", medium: "film"),
            reception: StudioReception(how: "screening", wholeOrPart: "whole"),
            artifactRefs: ["/tmp/green-ray.png"],
            origin: StudioOrigin(kind: .wandering),
            response: "The colour holds because he refuses to explain it.",
            stance: StudioStanceValue(kind: .formed),
            relations: [],
            tags: []
        )
    }

    private func inHerLiveTurn<T>(
        surface: String = "chat",
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await ChatTurnRuntimeContext.$current.withValue(
            .init(model: "test-model", surface: surface, personaID: "agent", providerID: "test")
        ) {
            try await ChatToolSessionContext.$verifiedSessionId.withValue("run_live_1") {
                try await body()
            }
        }
    }

    /// The security-relevant half: a bridge tool run reads her journal happily
    /// and moves nothing toward canon.
    @Test("a bridge tool run reads the journal and records no production pull")
    func bridgeRecallRecordsNoPull() async throws {
        let root = hermeticRoot()
        try await seedJournal(root)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        // No ChatTurnRuntimeContext at all — exactly what a bridge tool run has.
        let result = try await dispatcher.impl_studio_recall(
            input: ["title": .string("Green Ray")]
        )
        guard case .object(let obj) = result, case .array(let entries)? = obj["entries"] else {
            Issue.record("unexpected recall result: \(result)")
            return
        }
        // The read still works — a gate on the counter must never withhold her
        // own journal from a caller entitled to read it.
        #expect(entries.count == 1)
        #expect(await SwiftNativeStudioStore(dataRoot: root).recallPullCounts().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    /// Her own turn, but she is just looking something up. Browsing is not
    /// production, and a work must not climb toward canon because she reread it.
    @Test("browsing her own journal in an ordinary turn records no production pull")
    func browsingRecordsNoPull() async throws {
        let root = hermeticRoot()
        try await seedJournal(root)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        _ = try await inHerLiveTurn {
            try await dispatcher.impl_studio_recall(
                input: ["title": .string("Green Ray")]
            )
        }
        #expect(await SwiftNativeStudioStore(dataRoot: root).recallPullCounts().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    /// Fail closed: with no prepared turn there is no evidence of production
    /// context, so the answer is no.
    @Test("no prepared turn means no production context")
    func noPreparedTurnIsNotProduction() {
        #expect(!StudioCanonSeatGate.isProductionTasteJudgment())
    }

    /// The rule the gate defers to is the projection's OWN admission rule, so
    /// "used in production" means the same thing here as it does where the
    /// pointer gets selected — not a second, looser classifier.
    @Test("the production rule is the projection's taste-judgment rule, not a new one")
    func productionRuleIsTheProjectionRule() {
        #expect(ContextCorrectionScope.isTasteJudgmentTask(
            "design review: which of these two covers reads better?"))
        #expect(!ContextCorrectionScope.isTasteJudgmentTask(
            "restart the telegram poller and check the logs"))
    }

    /// And the counter itself still counts by title AND creator, which is how
    /// the canon keys a work.
    @Test("a recorded pull is keyed by title and creator together")
    func pullIsKeyedByWorkIdentity() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeStudioStore(dataRoot: root)
        await store.noteRecallPulls(titles: [("Untitled", "Agnes Martin")])
        await store.noteRecallPulls(titles: [("Untitled", "Donald Judd")])
        let counts = await store.recallPullCounts()
        #expect(counts.count == 2)
        #expect(counts[StudioCanonLaw.workKey(title: "Untitled", creator: "Agnes Martin")]?.count == 1)
        try? FileManager.default.removeItem(at: root)
    }
}
