import Foundation
import ChatOrchestration
import PersistenceCore
import Testing
@testable import NativeAgentApp

private func deskPaletteApplyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskPaletteApply-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Palette commands become lazy Desk tools at the dispatch boundary. Supply
/// the same unique chat-session loadout that the app supplies, so this eval
/// reaches the command it resolved instead of stopping at session authority.
private struct PaletteAuthorizedDeskRouter: DeskToolInvoking {
    let router: DeskToolDispatchRouter
    let sessionID: String

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        var authorizedInput = input
        authorizedInput["session_id"] = .string(sessionID)
        return try await router.run(tool: tool, input: authorizedInput)
    }
}

private func paletteAuthorizedDeskRouter(dataRoot: URL) async throws -> PaletteAuthorizedDeskRouter {
    let sessionID = "desk-palette-apply-eval-\(UUID().uuidString)"
    _ = try await ActiveToolsStore(dataRoot: dataRoot).addLoaded(
        sessionId: sessionID,
        names: ["desk_close"]
    )
    return PaletteAuthorizedDeskRouter(
        router: DeskToolDispatchRouter(dataRoot: dataRoot),
        sessionID: sessionID
    )
}

@Suite("Desk palette command application")
struct DeskPaletteApplyCommandEvalTests {
    // app.desk / desk.palette.applyCommand
    @Test("close resolves the current palette target and settles through the real Desk dispatcher")
    func closeCommandChangesOnlyTheResolvedLiveRow() async throws {
        let root = try deskPaletteApplyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let selected = try await store.createItem(
            kind: .plan, project: "Release", title: "Apply this command", parent: nil, summary: nil)
        let neighbor = try await store.createItem(
            kind: .plan, project: "Release", title: "Leave this alone", parent: nil, summary: nil)
        let active = DeskBoardLayout.activeItems((try await store.liveState()).items)
        let expectedUpdatedAt = try #require(active.first { $0.handle == selected.handle }?.updatedAt)

        let resolution = DeskPaletteCommandApplication.resolve(
            verb: .close,
            handle: selected.handle,
            activeItems: active
        )
        guard case let .dispatch(action) = resolution else {
            Issue.record("an active close target must resolve to the shared Desk action")
            return
        }
        #expect(action == .closeIfCurrent(
            handle: selected.handle,
            outcome: DeskQuickAction.deskCloseOutcome,
            expectedUpdatedAt: expectedUpdatedAt
        ))

        let router = try await paletteAuthorizedDeskRouter(dataRoot: root)
        let outcome = await DeskActionRunner.perform(action, via: router)
        #expect(outcome.ok)
        let persisted = try await store.liveState()
        #expect(persisted.items.first { $0.handle == selected.handle }?.status == .done)
        #expect(persisted.items.first { $0.handle == neighbor.handle }?.status != .done)
    }

    // app.desk / desk.palette.applyCommand
    @Test("stale, blank, and incomplete commands produce no fabricated completion")
    func adverseCommandsRefuseOrAwaitRealInput() async throws {
        let root = try deskPaletteApplyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(
            kind: .plan, project: "Release", title: "Race the palette", parent: nil, summary: nil)
        let activeSnapshot = DeskBoardLayout.activeItems((try await store.liveState()).items)

        #expect(DeskPaletteCommandApplication.resolve(
            verb: .close, handle: "  ", activeItems: activeSnapshot
        ) == .refused("Palette command was not applied: no Desk item was selected."))
        #expect(DeskPaletteCommandApplication.resolve(
            verb: .close, handle: "gone", activeItems: activeSnapshot
        ) == .refused("Palette command was not applied: that item is no longer active."))
        var missingVersion = item
        missingVersion.updatedAt = " \n"
        #expect(DeskPaletteCommandApplication.resolve(
            verb: .close, handle: item.handle, activeItems: [missingVersion]
        ) == .refused("Palette command was not applied: the item's current version is unavailable."))
        #expect(DeskPaletteCommandApplication.resolve(
            verb: .deferItem, handle: item.handle, activeItems: activeSnapshot
        ) == .beginDefer(handle: item.handle))
        #expect(DeskPaletteCommandApplication.resolve(
            verb: .note, handle: item.handle, activeItems: activeSnapshot
        ) == .beginNote(handle: item.handle))

        // The row can advance after resolution but before dispatch. The real
        // tool remains authoritative and its refusal leaves no fake success.
        guard case let .dispatch(staleAction) = DeskPaletteCommandApplication.resolve(
            verb: .close, handle: item.handle, activeItems: activeSnapshot
        ) else {
            Issue.record("fixture must resolve a close before the race")
            return
        }
        try await store.setStatus(item.handle, status: .done)
        let router = try await paletteAuthorizedDeskRouter(dataRoot: root)
        let refused = await DeskActionRunner.perform(
            staleAction,
            via: router
        )
        #expect(!refused.ok)
        let canonicalAfterRace = (try await store.liveState()).items
        #expect(canonicalAfterRace.first { $0.handle == item.handle }?.status == .done)
        let optimistic = DeskOptimisticItemPatch.applying(
            staleAction,
            to: activeSnapshot,
            timestamp: "2030-01-01T00:00:00Z"
        )
        #expect(DeskOptimisticItemPatch.reconciled(
            preAction: activeSnapshot,
            optimistic: optimistic,
            reloaded: canonicalAfterRace,
            loadFailed: false,
            outcome: refused,
            action: staleAction
        ) == canonicalAfterRace)
    }
}
