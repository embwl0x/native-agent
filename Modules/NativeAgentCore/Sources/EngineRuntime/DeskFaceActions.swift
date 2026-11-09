import AuthoredCapabilities
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `DeskFaceActions.swift` | Desk's Mac-only places (editors, palette, clipboard, the item shown) as links its rows open, and the owner code behind desk.refresh, desk.remind and desk.veto |

/// What the Mac's mounted Desk view opens: an editor, the palette, research, or the clipboard. Nothing here runs through a door.
public enum DeskFaceRequest: Sendable {
    case findItem, newTask, research
    case note(String), reply(String), copy(String)
}

/// Where a Desk row's Mac-only link leads, read from the Desk as it stands: something the Mac's Desk view opens, or the item it shows
/// (nil: the board).
public enum DeskFaceOpening: Sendable {
    case request(DeskFaceRequest)
    case show(String?)
}

/// The Mac-only places a Desk row opens, each the item of its link (`page:desk/<item>`). A Desk item's handle (`desk_…`) is never one.
enum DeskMacPlace: Equatable {
    case newTask, findItem, research, board
    case note(String), reply(String), copy(String), inspect(String)

    init?(item: String) {
        switch item {
        case "new-task": self = .newTask
        case "find-item": self = .findItem
        case "research": self = .research
        case "board": self = .board
        default:
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            switch parts[0] {
            case "note": self = .note(parts[1])
            case "reply": self = .reply(parts[1])
            case "copy": self = .copy(parts[1])
            case "execution": self = .inspect(item)
            default: return nil
            }
        }
    }

    var link: String {
        let item = switch self {
        case .newTask: "new-task"
        case .findItem: "find-item"
        case .research: "research"
        case .board: "board"
        case .note(let handle): "note:" + handle
        case .reply(let handle): "reply:" + handle
        case .copy(let ref): "copy:" + ref
        case .inspect(let row): row
        }
        return "page:desk/" + item
    }
}

@MainActor extension NativeAgentEngine {
    /// What a Desk row's Mac-only link asks of the Mac's Desk view, read from the Desk as it stands; nil when the item is not such a place
    /// (a Desk item's handle, which the page opens). A place whose item or reference is gone throws.
    public func deskOpening(item: String) async throws -> DeskFaceOpening? {
        guard let place = DeskMacPlace(item: item) else { return nil }
        let gone = PartCallError(code: "action_unavailable", message: "That is no longer on the Desk. Read the Desk again; nothing opened.")
        let snapshot = await desk.loadPage()
        switch place {
        case .newTask: return .request(.newTask)
        case .findItem: return .request(.findItem)
        case .research: return .request(.research)
        case .board: return .show(nil)
        case .inspect(let row):
            guard snapshot.agentJobs.items.contains(where: { WorkOverviewRead.row(for: $0, now: snapshot.now).id == row }) else { throw gone }
            return .show(row)
        case .note(let handle), .reply(let handle):
            guard let item = snapshot.boardItems.first(where: { $0.handle == handle }), !item.status.isTerminal else { throw gone }
            if case .note = place { return .request(.note(item.handle)) }
            return .request(.reply(DeskPageContent.draft(about: item)))
        case .copy(let refID):
            guard let handle = desk.faceItem, let item = snapshot.items.first(where: { $0.handle == handle }),
                  let ref = item.refs.first(where: { $0.refId == refID }) else { throw gone }
            switch DeskRefAffordance.action(for: ref) {
            case .open(let text, _), .copy(let text, _): return .request(.copy(text))
            }
        }
    }

    func deskRefresh() async -> String {
        _ = await desk.refreshPage()
        return "Desk readings refreshed; any unavailable sources are named on the page."
    }

    /// A reminder switch: every project (global), one project, or one Desk item, written through the reminder settings' owner.
    func deskRemind(_ input: [String: JSONValue]) async throws -> String {
        guard case .bool(let on)? = input["value"] else {
            throw PartCallError(code: "invalid_value", message: "A reminder switch takes value true or false; nothing changed.")
        }
        let id = input["scope_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let store = DeskNagConfigStore(dataRoot: dataRoot)
        let named: String
        switch input["scope_kind"]?.stringValue {
        case "global":
            _ = try await store.update { $0.settingGlobal(on) }
            named = "every project"
        case "project":
            guard !id.isEmpty else { throw PartCallError(code: "invalid_input", message: "A project's switch needs scope_id, its name.") }
            _ = try await store.update { $0.settingScope(kind: .project, id: id, enabled: on) }
            named = "project " + id
        case "item":
            guard let item = await desk.loadPage().boardItems.first(where: { $0.handle == id }) else {
                throw PartCallError(code: "invalid_input", message: "An item's switch needs scope_id, the handle of an item on the Desk board.")
            }
            _ = try await store.update { $0.settingScope(kind: .item, id: item.handle, enabled: on) }
            named = "desk." + item.alias
        default:
            throw PartCallError(code: "invalid_input", message: "scope_kind is global, project or item; nothing changed.")
        }
        _ = await desk.refreshPage()
        return "Reminders \(on ? "on" : "off") for \(named)."
    }

    /// The person's Veto closes an open pursuit through the pursuit veto owner.
    func deskVeto(_ input: [String: JSONValue]) async throws -> String {
        let handle = input["handle"]?.stringValue ?? ""
        guard let item = await desk.loadPage().boardItems.first(where: { $0.handle == handle }), !item.status.isTerminal,
              DeskBoardLayout.isPursuitLaneItem(item), item.pursuit != nil else {
            throw PartCallError(code: "action_unavailable", message: "That is not an open pursuit on the Desk board; nothing was vetoed.")
        }
        let outcome = await desk.vetoHandler.veto(item.handle)
        _ = await desk.refreshPage()
        switch outcome {
        case .completed: return "Pursuit vetoed and closed."
        case .alreadyVetoed: return "Pursuit was already vetoed."
        case .inFlight: throw PartCallError(code: "in_flight", message: "That veto is still being written.")
        case .failed(let detail): throw PartCallError(code: "veto_failed", message: detail)
        }
    }
}
