import NativeAgentCore
import Experiences
import Foundation
import PersistenceCore
import NativeAgentShared

// Blueprint: | `MacFourVerbs+WorkspaceControl.swift` | `MacFourVerbs`: One verb vocabulary and exact frame/handle admission with canonical effects |

extension MacFourVerbs {
    public static let selectionVerbs = MacActVerb.allCases.map(\.rawValue) + ["press"]
    /// Read one executing vocabulary so schema, offers and refusal help cannot drift.
    public static let actionVerbs = Array(Set(selectionVerbs + PhysicalVerb.allCases.map(\.rawValue))).sorted()

    static func offeredVerbs(_ verbs: [String]) -> [String] {
        verbs.filter { actionVerbs.contains($0) }
    }

    /// Supplemental surfaces lack window handles; reobserve role ordinals and allow physical input only in the already-frontmost app.
    public func actNativeSurface(verb: String, target: String, app: String,
                                 label: String? = nil, text: String? = nil, mode: MacTypeMode = .replace, turn: Turn,
                                     context: MacOperationContext) async -> MacFourVerbsReply {
        await context.holding(\.nativeSurfaceApp, app) { context in
            await context.holding(\.nativeSurfaceLabel, label) { context in
                await act(verb: verb, target: target, text: text, mode: mode, app: app, turn: turn, context: context)
            }
        }
    }

    /// Exact references retain drift checks and ordinary admission; selection receipts preserve the chosen identity.
    public func actSelection(verb: String, handle: String, frameID: String,
                             text: String? = nil, mode: MacTypeMode = .replace, direction: String? = nil,
                             app: String? = nil, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        let ownsSerial = !context.holdsActSerial
        if ownsSerial {
            guard await MacActSerial.shared.acquire(context: context) else {
                return .init(ok: false, text: "The action was cancelled before it started.", detail: ["error": .string("cancelled")])
            }
        }
        defer { if ownsSerial { Task { await MacActSerial.shared.release() } } }
        await MacActSerial.shared.ownInputs(context.driver)
        // An exact act moves the screen on too: a stopped batch in this chat is over.
        if ownsSerial, let root = flowRoot, let session = flowSession { Flow.dropped(root, scope: Self.actFlowScope(session)) }
        let verb = verb == "press" ? "click" : verb
        guard Self.selectionVerbs.contains(verb) else {
            return .init(ok: false, text: "A handle cannot use \"\(verb)\". Allowed verbs: "
                + Self.selectionVerbs.joined(separator: ", ") + ". Nothing was sent.",
                detail: ["error": .string("unsupported_selection_verb"), "verb": .string(verb),
                         "allowed_verbs": .array(Self.selectionVerbs.map(JSONValue.string))])
        }
        guard !handle.isEmpty, !frameID.isEmpty else {
            return .init(ok: false, text: "That selection is incomplete. Look again and select a current control.",
                         detail: ["error": .string("invalid_screen_selection")])
        }
        var body: [String: JSONValue] = ["verb": .string(verb), "handle": .string(handle), "frame_id": .string(frameID)]
        if let app {
            guard let frame = await MacLookFrameStore.shared.frame(frameId: frameID, context: context),
                  [frame.appName, frame.bundleId].compactMap({ $0 }).contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) else {
                return .init(ok: false, text: "That handle does not identify the requested app. Nothing was sent; read its screen again.",
                    detail: ["error": .string("selection_app_mismatch")])
            }
            body["background"] = .bool(true)
        }
        if let text { body["text"] = .string(text) }
        body["mode"] = .string(mode.rawValue)
        if let direction { body["direction"] = .string(direction) }
        let postRead = MacSightCaptureBinding(frameID: UUID().uuidString)
        do {
            let result = try await context.holding(\.capture, postRead) {
                context in try await host.dispatch(action: "act", body: body, turn: turn, context: context)
            }
            var detail = Self.operationDetail(result, app: postRead.walked?.read.app?.bundleIdentifier ?? postRead.walked?.read.app?.name)
            let output = Self.object(result.output)
            let effect = Self.effectWords(output: output)
            let mismatch = effect.status == "acted_mismatch"
            let verified = result.ok && output["verified"] == .bool(true)
            // Preserve the owner’s redacted distinction between accepted input and an observed effect.
            detail["selection_result"] = result.toJSON(readContent: context.readContent)
            if !result.ok { detail["error"] = .string(result.error ?? "selection_refused") }
            // Anchor the reply to the owner’s post-effect app and frame so a redundant look cannot replace its evidence.
            var screen = "raw view · accessibility · Selected control's closed-loop action receipt."
            if let acted = postRead.walked?.read.app,
               case .seen(let after) = await sight(part: nil, app: acted.bundleIdentifier ?? acted.name, observed: postRead, turn: turn, context: context) {
                screen = after.render
                if case .object(var receipt)? = detail["selection_result"] {
                    receipt["output"] = .object(output.filter { !["frame_id", "frame_ttl_seconds", "glance", "how_to_read"].contains($0.key) })
                    detail["selection_result"] = .object(receipt)
                }
            }
            return .init(ok: result.ok && !mismatch,
                text: (result.ok
                    ? (mismatch ? "The selected effect did not match. "
                        : verified ? "Verified: " : "The selected input was delivered. ") + effect.sentence
                    : "The selected action is unverified: " + (Self.string(output["detail"]) ?? Self.string(output["guidance"])
                        ?? result.error ?? effect.sentence))
                    + "\n" + screen,
                detail: detail)
        } catch {
            return Self.unknownActionReply(error, operation: "the selected action",
                app: postRead.walked?.read.app?.bundleIdentifier ?? postRead.walked?.read.app?.name)
        }
    }
}
