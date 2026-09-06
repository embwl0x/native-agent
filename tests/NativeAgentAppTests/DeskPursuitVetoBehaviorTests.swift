import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk pursuit veto behavior", .serialized)
struct DeskPursuitVetoBehaviorTests {
    private enum RefusingAppend: Error { case noteWriteDenied }

    /// Uses the actual file reader and Desk operation, refusing only the final
    /// durable append that makes the cancellation and rationale visible.
    private struct RefusingVetoPersistence: PersistenceCoreProtocol {
        private let base = SwiftNativePersistenceCore()

        func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
            await base.readJSON(path, defaultValue: defaultValue)
        }
        func writeJSON(_ value: JSONValue, to path: URL) async throws {
            try await base.writeJSON(value, to: path)
        }
        func appendJSONL(_ record: JSONValue, to path: URL) async throws {
            try await base.appendJSONL(record, to: path)
        }
        func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
            try await base.tailJSONL(path, limit: limit, maxBytes: maxBytes)
        }
        func readJSONL(_ path: URL) async throws -> [JSONValue] {
            try await base.readJSONL(path)
        }
        func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
            throw RefusingAppend.noteWriteDenied
        }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskPursuitVeto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pursuit() -> Pursuit {
        Pursuit(
            why: "The owner vetoed the pursuit.",
            evidence: PromotionDossier(citations: [.standingView(id: "cognition-veto-eval")]),
            doneLooksLike: "Canceled status and rationale survive reload.",
            maxSessions: 2,
            abandonCondition: "The owner vetoes it."
        )
    }

    // app.desk / ui.desk.pursuits.veto
    @Test("a mounted-handler veto commits canceled status and rationale before presenting success")
    func successfulVetoIsDurableBeforeTheObservatoryClaimsSuccess() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let opened = try await store.openPursuit(project: "evaluation", title: "Veto me", pursuit: pursuit())

        let outcome = await WorkshopObservatoryVetoHandler(dataRoot: dataRoot).veto(opened.handle)
        #expect(DeskPursuitVetoNotice.receipt(for: outcome)
            == DeskActionNotice(text: "Pursuit vetoed and closed.", isError: false))
        #expect(WorkshopObservatoryVetoPresentation.shouldRefresh(after: outcome))

        let reloaded = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        let settled = try #require(reloaded.items.first { $0.handle == opened.handle })
        #expect(settled.status == .canceled)
        #expect(settled.notes.contains { $0.text == WorkshopObservatoryVetoHandler.rationale })
    }

    // app.desk / ui.desk.pursuits.veto
    @Test("a failed durable rationale write remains an error notice and leaves the pursuit open")
    func noteWriteFailureDoesNotBecomeAVetoSuccess() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let live = SwiftNativeDeskStore(dataRoot: dataRoot)
        let opened = try await live.openPursuit(project: "evaluation", title: "Stay open", pursuit: pursuit())
        let refusingStore = SwiftNativeDeskStore(dataRoot: dataRoot, persistence: RefusingVetoPersistence())

        let outcome = await WorkshopObservatoryVetoHandler(store: refusingStore).veto(opened.handle)
        guard case let .failed(message) = outcome else {
            Issue.record("the refused durable note append must not report a completed veto")
            return
        }
        let notice = DeskPursuitVetoNotice.receipt(for: outcome)
        #expect(notice.isError)
        #expect(notice.text == "Veto failed: \(message)")
        #expect(!WorkshopObservatoryVetoPresentation.shouldRefresh(after: outcome))

        let reloaded = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        let remaining = try #require(reloaded.items.first { $0.handle == opened.handle })
        #expect(!remaining.status.isTerminal)
        #expect(!remaining.notes.contains { $0.text == WorkshopObservatoryVetoHandler.rationale })
    }
}
