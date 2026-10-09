import Foundation
import PersistenceCore

extension MacFourVerbs {
    @TaskLocal static var nativeSurfaceApp: String?
    @TaskLocal static var nativeSurfaceLabel: String?

    /// A supplemental native surface has no window-relative handle. Resolve
    /// its role ordinal in a fresh app-anchored look. Physical input is allowed
    /// only while that observed app is already in front; never raise it.
    public func actNativeSurface(verb: String, target: String, app: String,
                                 label: String? = nil, text: String? = nil, mode: MacTypeMode = .replace) async -> MacFourVerbsReply {
        await Self.$nativeSurfaceApp.withValue(app) {
            await Self.$nativeSurfaceLabel.withValue(label) {
                await act(verb: verb, target: target, text: text, mode: mode, app: app)
            }
        }
    }

    /// A workspace selection already names the exact observed control. Never
    /// resolve its display label again: the canonical action owner checks the
    /// frame, app, window and handle for drift before injecting anything.
    public func actSelection(verb: String, handle: String, frameID: String,
                             text: String? = nil, mode: MacTypeMode = .replace, direction: String? = nil) async -> MacFourVerbsReply {
        // A screen page lists "press" among a control's verbs.
        let verb = verb == "press" ? "click" : verb
        guard ["click", "open", "type", "focus", "select", "toggle", "scroll"].contains(verb),
              let actionVerb = MacActVerb(rawValue: verb),
              !handle.isEmpty, !frameID.isEmpty else {
            return .init(ok: false, text: "That selection is incomplete. Look again and select a current control.",
                         detail: ["error": .string("invalid_screen_selection")])
        }
        var body: [String: JSONValue] = ["verb": .string(verb), "handle": .string(handle), "frame_id": .string(frameID)]
        if let text { body["text"] = .string(text) }
        body["mode"] = .string(mode.rawValue)
        if let direction { body["direction"] = .string(direction) }
        do {
            let result = try await host.dispatch(action: "act", body: body)
            var detail = Self.operationDetail(result)
            let output = Self.object(result.output)
            let effect = Self.effectWords(output: output, verb: actionVerb, typed: text)
            let verified = result.ok && output["verified"] == .bool(true)
            detail["status"] = .string(effect.status == "acted" && !verified ? "acted_unobserved" : effect.status)
            detail["verification"] = .string(verified ? "satisfied" : result.ok ? "unverified" : "failed")
            if verified {
                detail["verification_evidence"] = output["verification_evidence"] ?? .string(effect.sentence)
                detail["verification_scope"] = output["verification_scope"] ?? .string("observed_control_effect")
            } else { detail.removeValue(forKey: "verification_evidence") }
            // The owner's result is already redacted and distinguishes input
            // acceptance from an observed effect. Keep that evidence intact.
            detail["selection_result"] = result.toJSON()
            if !result.ok { detail["error"] = .string(result.error ?? "selection_refused") }
            return .init(ok: result.ok,
                text: (result.ok
                    ? (verified ? "Verified: " : "The selected input was delivered. ") + effect.sentence
                    : "The selected control could not be acted on. Read the current screen and select again; the action was not retried.")
                    + "\nraw view · accessibility · Selected control's closed-loop action receipt.",
                detail: detail)
        } catch {
            return .init(ok: false,
                text: "The selected action did not return a usable result. It was not retried; look again before deciding what to do.",
                detail: ["error": .string("selection_outcome_unknown"), "message": .string(error.localizedDescription)])
        }
    }
}
