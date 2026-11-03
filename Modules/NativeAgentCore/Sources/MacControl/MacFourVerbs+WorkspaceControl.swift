import Experiences
import Foundation
import PersistenceCore
import NativeAgentShared

// Blueprint: | `MacFourVerbs+WorkspaceControl.swift` | `MacFourVerbs`: schema and screen offers read the executing hand's verb inventory; exact frame/handle acts share admission and serial ownership with batches, including focus, double/right click and hover; validate selected app and retain the canonical effect verdict |

extension MacFourVerbs {
    public static let selectionVerbs = MacActVerb.allCases.map(\.rawValue) + ["press"]
    /// The schema, screen offers and refusal help read the executing hand's vocabulary.
    public static let actionVerbs = Array(Set(selectionVerbs + PhysicalVerb.allCases.map(\.rawValue))).sorted()

    static func offeredVerbs(_ verbs: [String]) -> [String] {
        verbs.filter { actionVerbs.contains($0) }
    }
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

    /// Workspace-owned frame/handle references select the exact observed control.
    /// The action owner checks drift and ordinary admission before input;
    /// the structured selection receipt retains those references.
    public func actSelection(verb: String, handle: String, frameID: String,
                             text: String? = nil, mode: MacTypeMode = .replace, direction: String? = nil,
                             app: String? = nil) async -> MacFourVerbsReply {
        if TaskWaitDeadline.current == nil {
            do {
                return try await TaskWaitDeadline.withDeadline(
                    seconds: Double(SwiftNativeMacControl.operationTimeoutSeconds(action: "act", body: [:]))
                ) { await self.actSelection(verb: verb, handle: handle, frameID: frameID,
                    text: text, mode: mode, direction: direction, app: app) }
            } catch { return Self.interruptedActReply(error) }
        }
        let ownsSerial = !Self.holdsActSerial
        if ownsSerial {
            guard await MacActSerial.shared.acquire() else {
                return .init(ok: false, text: "The action was cancelled before it started.", detail: ["error": .string("cancelled")])
            }
        }
        defer { if ownsSerial { Task { await MacActSerial.shared.release() } } }
        await MacActSerial.shared.ownInputs(MacDriverContext.binding)
        // An exact act moves the screen on too: a stopped batch in this chat is over.
        if ownsSerial, let root = flowRoot, let session = flowSession { Flow.dropped(root, scope: Self.actFlowScope(session)) }
        // A screen page lists "press" among a control's verbs.
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
            guard let frame = await MacLookFrameStore.shared.frame(frameId: frameID),
                  [frame.appName, frame.bundleId].compactMap({ $0 }).contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) else {
                return .init(ok: false, text: "That handle does not identify the requested app. Nothing was sent; read its screen again.",
                    detail: ["error": .string("selection_app_mismatch")])
            }
            body["background"] = .bool(true)
        }
        if let text { body["text"] = .string(text) }
        body["mode"] = .string(mode.rawValue)
        if let direction { body["direction"] = .string(direction) }
        // The action owner's post-effect read, carried to the reply look.
        let postRead = MacSightCaptureBinding(frameID: UUID().uuidString)
        do {
            let result = try await MacSightCaptureBinding.$current.withValue(postRead) {
                try await host.dispatch(action: "act", body: body)
            }
            var detail = Self.operationDetail(result, app: postRead.walked?.read.app?.bundleIdentifier ?? postRead.walked?.read.app?.name)
            let output = Self.object(result.output)
            let effect = Self.effectWords(output: output)
            let mismatch = effect.status == "acted_mismatch"
            let verified = result.ok && output["verified"] == .bool(true)
            // The owner's result is already redacted and distinguishes input
            // acceptance from an observed effect. Keep that evidence intact.
            detail["selection_result"] = result.toJSON()
            if !result.ok { detail["error"] = .string(result.error ?? "selection_refused") }
            // The fresh screen the act left, as a look prints it, anchored to
            // the app of the owner's own post-effect read, so no look is needed
            // after it. Its frame supersedes the receipt's frame and glance.
            var screen = "raw view · accessibility · Selected control's closed-loop action receipt."
            if let acted = postRead.walked?.read.app,
               case .seen(let after) = await sight(part: nil, app: acted.bundleIdentifier ?? acted.name, observed: postRead) {
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
                    : "The selected action is unverified: " + (Self.string(output["detail"]) ?? Self.string(output["guidance"]) ?? result.error ?? effect.sentence))
                    + "\n" + screen,
                detail: detail)
        } catch {
            return Self.unknownActionReply(error, operation: "the selected action",
                app: postRead.walked?.read.app?.bundleIdentifier ?? postRead.walked?.read.app?.name)
        }
    }
}
