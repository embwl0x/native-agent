import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Workshop observatory veto button behavior", .serialized)
struct WorkshopObservatoryVetoButtonBehaviorEvalTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-observatory-veto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pursuit() -> Pursuit {
        Pursuit(
            why: "A user-visible veto needs one durable outcome.",
            evidence: PromotionDossier(citations: [
                .standingView(id: "veto-button-eval"),
                .feltSalience(dates: ["2026-08-23", "2026-08-24"]),
            ]),
            doneLooksLike: "The canceled state and rationale survive a relaunch.",
            maxSessions: 3,
            abandonCondition: "The owner vetoes this pursuit."
        )
    }

    // app.desk / workshop.observatory.vetoButton
    @Test("only the clicked pursuit is disabled, and only settled outcomes request a refresh")
    func buttonPendingAndRefreshPresentationAreOutcomeBound() {
        let pending: Set<String> = ["desk-pending"]
        #expect(WorkshopObservatoryVetoPresentation.buttonIsDisabled(
            handle: "desk-pending", pendingHandles: pending))
        #expect(!WorkshopObservatoryVetoPresentation.buttonIsDisabled(
            handle: "desk-other", pendingHandles: pending))
        #expect(WorkshopObservatoryVetoPresentation.shouldRefresh(after: .completed))
        #expect(WorkshopObservatoryVetoPresentation.shouldRefresh(after: .alreadyVetoed))
        #expect(!WorkshopObservatoryVetoPresentation.shouldRefresh(after: .inFlight))
        #expect(!WorkshopObservatoryVetoPresentation.shouldRefresh(after: .failed("disk unavailable")))
    }

    // app.desk / workshop.observatory.vetoButton
    @Test("the mounted-button handler persists one veto, refreshes only after settlement, and refuses an absent target")
    func durableVetoAndAdverseTargetAreHonest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let opened = try await store.openPursuit(
            project: "evaluation", title: "Veto from observatory", pursuit: pursuit())
        let handler = WorkshopObservatoryVetoHandler(dataRoot: root)

        let completed = await handler.veto(opened.handle)
        #expect(completed == .completed)
        #expect(WorkshopObservatoryVetoPresentation.shouldRefresh(after: completed))

        let relaunched = SwiftNativeDeskStore(dataRoot: root)
        let closed = try #require((try await relaunched.liveState()).items.first { $0.handle == opened.handle })
        #expect(closed.status == .canceled)
        #expect(closed.notes.contains { $0.text == WorkshopObservatoryVetoHandler.rationale })

        let repeated = await handler.veto(opened.handle)
        #expect(repeated == .alreadyVetoed)
        #expect(WorkshopObservatoryVetoPresentation.shouldRefresh(after: repeated))

        let missing = await handler.veto("desk-does-not-exist")
        guard case .failed = missing else {
            Issue.record("an absent pursuit must not report a completed veto")
            return
        }
        #expect(!WorkshopObservatoryVetoPresentation.shouldRefresh(after: missing))
    }
}
