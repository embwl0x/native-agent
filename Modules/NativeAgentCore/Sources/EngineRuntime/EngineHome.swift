import AgentConversations
import AgentWorkspace
import AuthoredCapabilities
import ChatToolRuntime
import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `EngineHome.swift` | Registers Home's retained world lifetime and binds the agent's door and row actions to the shared page owner |

extension NativeAgentEngine {
    @MainActor func homePageRead() -> PartFaces.Read {
        let workspace = ChatWorkspaceBinding.operation(turn: nil, invocation: ChatToolInvocation())
        let owner = HomeFace.Owner(workspace: workspace, dataRoot: dataRoot) { [weak pages] in
            await pages?.refresh(page: "home")
        }
        HomeFace.bind(dataRoot: dataRoot) { [weak pages] in await pages?.refresh(page: "home") }
        return { [layout, owner] in await owner.read(layout: layout.availability) }
    }

    func homePageAction() -> PartFaces.Act {
        { [weak self] row, action, value in
            guard let self else {
                throw PartCallError(code: "home_stopped", message: "Home's engine has stopped. Nothing changed; reopen NativeAgent.")
            }
            return try await self.homePageAct(row: row, action: action, value: value)
        }
    }

    private func homePageAct(row: String, action: String, value: String?) async throws -> String? {
        guard await MainActor.run(body: {
            pages.snapshots["home"]?.face?.sections.contains { section in
                section.rows.contains { $0.id == row && $0.actions?.contains(where: { $0.id == action }) == true }
            } == true
        }) else {
            throw PartCallError(code: "stale_action", message: "That action is not on this Home row. Read Home again; nothing changed.")
        }
        guard value == nil else {
            throw PartCallError(code: "unexpected_value", message: "Home actions take no setting value. Nothing changed.")
        }
        if action == "agent.read", row.hasPrefix("job:") {
            return try await AgentJobs.answer(tool: "agent_read", id: String(row.dropFirst("job:".count)), agent: nil,
                dataRoot: dataRoot).serialize(pretty: true)
        }
        if ["queue.done", "queue.drop"].contains(action), row.hasPrefix("desk.") {
            let store = SwiftNativeDeskStore(dataRoot: dataRoot)
            guard let entry = MyQueue.entries(try await store.liveState()).first(where: { $0.name == row }) else {
                throw PartCallError(code: "stale_step", message: "That MY QUEUE step is no longer open. Read Home again; nothing changed.")
            }
            if let holder = try await store.heldBy(entry.item.handle, session: "home-page") {
                throw PartCallError(code: "held_step", message: "\(row) is held by \(holder). Nothing changed; leave it to that conversation.")
            }
            let dropped = action == "queue.drop"
            try await MyQueue.finish(entry, dropped: dropped, why: dropped ? "dropped" : "done", store: store)
            if let run = MyQueue.skillRun(in: entry.step.words) {
                do { try PartRunStore.discard(run, root: dataRoot) }
                catch {
                    throw PartCallError(code: "checkpoint_cleanup_failed",
                        message: "The step closed, but its run checkpoint could not settle: \(error.localizedDescription). Repair that checkpoint.")
                }
            }
            return dropped ? "Dropped \(row)." : "Marked \(row) done."
        }
        guard action == "home.accept", row.hasPrefix("arrival:") else {
            throw PartCallError(code: "unknown_action", message: "That Home row has no such action. Read Home again for its current actions.")
        }
        let workspace = ChatWorkspaceBinding.operation(turn: nil, invocation: ChatToolInvocation())
        return try ResidentWake.shared.accept(workspace: workspace, dataRoot: dataRoot, id: String(row.dropFirst("arrival:".count)))
    }
}
