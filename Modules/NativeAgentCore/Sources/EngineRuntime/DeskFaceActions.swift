import Desk
import Foundation
import NativeAgentShared
// Blueprint: | `DeskFaceActions.swift` | Desk face actions return to the existing tool router, pursuit veto owner and mounted Mac editors |

/// Text entry and Mac navigation stay with the mounted window; the face owns the request, never another write path.
public enum DeskFaceRequest: Sendable {
    case findItem, newTask, schedule, research
    case note(String), reply(String), copy(String)
}

@MainActor extension NativeAgentEngine {
    @MainActor func deskAct(row: String, action: String, value: String?) async throws -> String? {
        guard !desk.faceActionInFlight else {
            throw PartCallError(code: "in_flight", message: "A Desk action is still being answered. Wait for its result.")
        }
        desk.faceActionInFlight = true
        defer { desk.faceActionInFlight = false }
        let snapshot = await desk.loadPage()
        let face = deskFace(snapshot)
        guard let offered = face.sections.flatMap(\.rows).first(where: { $0.id == row }),
              offered.actions?.contains(where: { $0.id == action }) == true || (action == "set" && offered.control != nil) else {
            throw PartCallError(code: "stale_row", message: "This Desk row no longer offers that action. Refresh the Desk.")
        }
        if row == "desk-selection", action == "board" { desk.faceItem = nil; return nil }
        if row == "desk:" + action {
            switch action {
            case "refresh":
                _ = await desk.refreshPage()
                return "Desk readings refreshed; any unavailable sources are named on the page."
            case "new-task": return try deskRequest(.newTask)
            case "find-item": return try deskRequest(.findItem)
            case "schedule": return try deskRequest(.schedule)
            case "research": return try deskRequest(.research)
            default: throw deskActionUnavailable()
            }
        }
        if action == "inspect", row.hasPrefix("execution:") {
            desk.faceItem = row
            return nil
        }
        if action == "copy-reference", let handle = desk.faceItem,
           let item = snapshot.items.first(where: { $0.handle == handle }),
           let ref = item.refs.first(where: { "ref:" + $0.refId == row }) {
            switch DeskRefAffordance.action(for: ref) {
            case .open(let text, _), .copy(let text, _): return try deskRequest(.copy(text))
            }
        }
        if action == "set" {
            guard value == "on" || value == "off" else {
                throw PartCallError(code: "invalid_value", message: "A reminder switch needs on or off.")
            }
            let on = value == "on"
            if row == "nag:global" { return try await deskPerform(.nagGlobal(on: on)) }
            if let lane = DeskNagPanelModel.lanes(items: snapshot.boardItems, config: snapshot.nagConfig)
                .first(where: { "nag:project:" + $0.project == row }) {
                return try await deskPerform(.nagProject(project: lane.project, on: on))
            }
            if let item = snapshot.boardItems.first(where: { "nag:item:" + $0.handle == row }) {
                return try await deskPerform(.nagItem(handle: item.handle, on: on))
            }
        }
        if row == "nag:mute" || row == "nag:" + action {
            switch action {
            case "unmute": return try await deskPerform(.nagUnmute)
            case "mute:indefinitely": return try await deskPerform(.nagMute(until: nil))
            default:
                if action.hasPrefix("mute:"), let preset = DeskDeferPreset(rawValue: String(action.dropFirst("mute:".count))) {
                    return try await deskPerform(.nagMute(until: preset.day(from: snapshot.now)))
                }
            }
        }
        let handle = row == "item-action:" + action ? desk.faceItem : row
        guard let item = snapshot.boardItems.first(where: { $0.handle == handle }), !item.status.isTerminal else {
            throw deskActionUnavailable()
        }
        switch action {
        case "reply": return try deskRequest(.reply(DeskPageContent.draft(about: item)))
        case "note": return try deskRequest(.note(item.handle))
        case "close": return try await deskPerform(.closeIfCurrent(handle: item.handle,
            outcome: DeskQuickAction.deskCloseOutcome, expectedUpdatedAt: value ?? item.updatedAt))
        case "unpark": return try await deskPerform(.defer_(handle: item.handle, until: nil))
        case "veto":
            let outcome = await desk.vetoHandler.veto(item.handle)
            _ = await desk.refreshPage()
            switch outcome {
            case .completed: return "Pursuit vetoed and closed."
            case .alreadyVetoed: return "Pursuit was already vetoed."
            case .inFlight: throw PartCallError(code: "in_flight", message: "That veto is still being written.")
            case .failed(let detail): throw PartCallError(code: "veto_failed", message: detail)
            }
        default:
            if action.hasPrefix("defer:"), let preset = DeskDeferPreset(rawValue: String(action.dropFirst("defer:".count))) {
                return try await deskPerform(.defer_(handle: item.handle, until: preset.day(from: snapshot.now)))
            }
            throw deskActionUnavailable()
        }
    }

    private func deskRequest(_ request: DeskFaceRequest) throws -> String {
        guard let host = desk.faceRequest else {
            throw PartCallError(code: "mac_window_unavailable", message: "Open Desk on the Mac to use this editor or clipboard action.")
        }
        return try host(request)
    }

    private func deskPerform(_ action: DeskQuickAction) async throws -> String {
        let outcome = await DeskToolDispatchRouter(dataRoot: dataRoot).perform(action)
        _ = await desk.refreshPage()
        guard outcome.ok else { throw PartCallError(code: "desk_action_unconfirmed", message: outcome.message) }
        return outcome.message
    }

    private func deskActionUnavailable() -> PartCallError {
        .init(code: "action_unavailable", message: "That action is not available on this Desk row. Refresh the Desk.")
    }
}
