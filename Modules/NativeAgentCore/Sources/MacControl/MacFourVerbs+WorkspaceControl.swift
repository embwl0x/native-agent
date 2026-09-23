import Foundation
import PersistenceCore

extension MacFourVerbs {
    /// A workspace selection already names the exact observed control. Never
    /// resolve its display label again: the canonical action owner checks the
    /// frame, app, window and handle for drift before injecting anything.
    public func actSelection(verb: String, handle: String, frameID: String,
                             text: String? = nil, direction: String? = nil) async -> MacFourVerbsReply {
        guard ["click", "open", "type", "select", "toggle", "scroll"].contains(verb),
              !handle.isEmpty, !frameID.isEmpty else {
            return .init(ok: false, text: "That selection is incomplete. Look again and select a current control.",
                         detail: ["error": .string("invalid_screen_selection")])
        }
        var body: [String: JSONValue] = ["verb": .string(verb), "handle": .string(handle), "frame_id": .string(frameID)]
        if let text { body["text"] = .string(text) }
        if let direction { body["direction"] = .string(direction) }
        do {
            let result = try await host.dispatch(action: "act", body: body)
            var detail = Self.operationDetail(result)
            // The owner's result is already redacted and distinguishes input
            // acceptance from an observed effect. Keep that evidence intact.
            detail["selection_result"] = result.toJSON()
            if !result.ok { detail["error"] = .string(result.error ?? "selection_refused") }
            return .init(ok: result.ok,
                text: result.ok
                    ? "The selected control was acted on. Its observed result is attached."
                    : "The selected control could not be acted on. Read the current screen and select again; the action was not retried.",
                detail: detail)
        } catch {
            return .init(ok: false,
                text: "The selected action did not return a usable result. It was not retried; look again before deciding what to do.",
                detail: ["error": .string("selection_outcome_unknown"), "message": .string(error.localizedDescription)])
        }
    }
}
