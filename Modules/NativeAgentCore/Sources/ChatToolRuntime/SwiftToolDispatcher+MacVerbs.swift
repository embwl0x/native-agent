import AuthoredCapabilities
import AgentWorkspace
import Foundation
import TurnTrace
import Experiences
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
import Senses
import ToolRegistry
import ActivityWatch
import ChatTurnContracts
import NativeAgentShared
// Blueprint: | `SwiftToolDispatcher+MacVerbs.swift` | `SwiftToolDispatcher`: four-verb arguments and execution, screen-watch admission, clipboard, menu, document and input routes; implicit point acts use MacImageFrames' newest session image, acquiring the first through mac.look pixels:true before input; explicit unknown image references remain refused |

internal struct SwiftToolDispatcherMacControlPolicyProvider: MacControlPolicyProvider {
    let policy: MacControlPolicy

    func currentPolicy() async -> MacControlPolicy? {
        policy
    }
}

extension SwiftToolDispatcher {
    /// A part run's watch on one app's front window (MacScreenWatch): the four
    /// verbs' access, card and sight to open it; for hands, the four verbs
    /// again at each hand under the access it has then; and the same access,
    /// asked again while it runs, to end it when screen control is turned off.
    public func openScreenWatch(_ request: MacScreenWatch.Request, hands: Bool, surface: String) async throws -> MacScreenWatch {
        let verbs: @Sendable () async throws -> MacFourVerbs = {
            let access = await self.fullMacToolAccess(surface: surface)
            guard access.accessibilityAllowed else {
                throw MacScreenWatch.Refusal(receipt: self.macControlCategoryNeedEnvelope(
                    categories: ["accessibility"], mode: hands ? .write : .read,
                    why: "Screen control lets me read and control apps on your Mac.")
                    ?? ChatToolOutcome.failure(error: AutonomyGateError.toolDenied(
                        reason: "Trust Full Mac Accessibility category is not active for screen.watch"), tool: "screen.watch"))
            }
            let host = makeMacControl(policyProvider: SwiftToolDispatcherMacControlPolicyProvider(policy: access.macPolicy),
                                      auditAppendPath: self.dataRoot.appendingPathComponent("mac_control_audit.jsonl"))
            return MacFourVerbs(host: host, supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(
                host: host, liveScene: self.fourVerbLiveScene))
        }
        do {
            return try await verbs().watch(request, dataRoot: dataRoot, hands: hands ? verbs : nil,
                                           authority: { await self.fullMacToolAccess(surface: surface).accessibilityAllowed })
        } catch {
            let failure = SenseFailure(error)
            if Experience.currentAct == nil, case .object(let remedy)? = failure.remedy,
               remedy["kind"] == .string("repair"), case .string(let owner)? = remedy["owner"] {
                let tap: String? = if case .string(let value)? = remedy["tap"] { value } else { nil }
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "screen.watch:" + owner,
                    owner: owner, words: failure.message, nextCall: remedy["next_call"].flatMap { try? $0.serialize(pretty: false) }, tap: tap)
            }
            throw error
        }
    }

    /// A screen page's whole address given as `target` (an object or its JSON
    /// text) is that exact selection: its handle and frame, or a supplemental
    /// surface's current target in its app.
    static func unwrappingScreenAddress(_ input: [String: JSONValue]) -> [String: JSONValue] {
        let address: [String: JSONValue]
        switch input["target"] {
        case .object(let fields)?: address = fields
        case .string(let text)? where text.hasPrefix("{"):
            guard case .object(let fields)? = try? JSONValue.parse(Data(text.utf8)) else { return input }
            address = fields
        default: return input
        }
        var input = input
        if case .string? = address["handle"], case .string? = address["frame_id"] {
            input["target"] = nil
            input["handle"] = address["handle"]
            input["frame_id"] = address["frame_id"]
        } else if case .string? = address["target"], case .string? = address["app"],
                  case .string? = address["__sense_screen_frame"] {
            input["target"] = address["target"]
            input["app"] = address["app"]
            input["__sense_native_surface"] = .bool(true)
            input["__sense_native_label"] = address["label"]
        }
        return input
    }

    /// Screen and wait request read authority; act and go request write
    /// authority. All require Full Mac accessibility. Ordinary calls use words;
    /// workspace selections return exact bindings through the same gate and owner.
    func impl_mac_four_verbs_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        if MacObservationMode.current != .passive,
           input["__sense_app_observation"] == .bool(true) || SensesHub.passiveObservation {
            return try await MacObservationMode.$current.withValue(.passive) {
                try await self.impl_mac_four_verbs_tool(tool: tool, input: input, surface: surface)
            }
        }
        let filtered = input.filter {
            !(["direction", "button"].contains($0.key) && ($0.value == .string("")))
        }
        let input = tool == "act" ? Self.unwrappingScreenAddress(filtered) : filtered
        if MacObservationMode.current != .passive,
           let continuation = MacWorkContinuation.current, continuation.isPending,
           let refusal = continuation.refusal() {
            return .object(["ok": .bool(false), "text": .string(refusal), "effects": .string("none"),
                "detail": .object(["error": .string("continuation_unavailable")])])
        }
        let access = await fullMacToolAccess(surface: surface)
        guard access.accessibilityAllowed else {
            if let need = macControlCategoryNeedEnvelope(
                categories: ["accessibility"], mode: (tool == "screen" || tool == "wait") ? .read : .write,
                why: "Screen control lets me read and control apps on your Mac."
            ) { return need }
            throw AutonomyGateError.toolDenied(
                reason: "Trust Full Mac Accessibility category is not active for \(tool)"
            )
        }
        func str(_ key: String) -> String? {
            if case .string(let value)? = input[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        func num(_ key: String) -> Double? {
            switch input[key] {
            case .double(let value): return value
            case .int(let value): return Double(value)
            default: return nil
            }
        }
        if tool == "screen", input["__sense_app_material"] != .bool(true), try Self.desktopPixelsRequested(input) {
            // A failed picture reports its own cause; no other read stands in for it.
            let result = await Self.desktopPixels(input: input)
            if input["wrong"] == .bool(true), let corner = senseAppCorner(input) {
                return try await SenseDoor.read(corner: corner, address: str("part"), input: input,
                    scope: ChatToolSessionContext.verifiedSessionId ?? "", raw: { result },
                    material: { _ in throw SenseFailure(code: "source_unavailable", message: "Desktop pixels are a raw view; app growth uses the running window's AX material.") })
            }
            if case .object(var fields) = result {
                fields["sense_provenance"] = .string("raw view · desktop pixels requested")
                return .object(fields)
            }
            return result
        }
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(policy: access.macPolicy),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        // The verbs count what they let out, so a failure says its own effects.
        let host = MacMotorCount(impl)
        if tool == "screen", input["__sense_app_material"] == .bool(true) {
            guard let bundle = str("app"), bundle != "*" else {
                throw SenseFailure(code: "source_unavailable", message: "App material needs a concrete already-running app.")
            }
            var body: [String: JSONValue] = ["grade": .string("look"),
                "app_map": .bool(true), "sense_material": .bool(true), "app": .string(bundle)]
            if let part = str("part") { body["seek"] = .string(part) }
            let readBody = body
            let passive = input["__sense_app_observation"] == .bool(true) || SensesHub.passiveObservation
                || MacObservationMode.current == .passive
            let frameSource = "sense:app:" + bundle + (passive ? ":watch" : "")
            let view = try await MacObservationMode.$current.withValue(passive ? .passive : .interactive) {
                try await MacLookFrameStore.$source.withValue(frameSource) {
                    try await host.dispatch(action: "look", body: readBody)
                }
            }
            if passive, !view.ok, case .object(let output) = view.output, case .string(let message)? = output["message"] {
                throw SenseFailure(code: "source_unavailable", message: message)
            }
            guard view.ok, case .object(let output) = view.output, case .object(var tree)? = output["accessibility"] else {
                throw SenseFailure(code: "source_unavailable", message: "The app's accessibility material could not be read.")
            }
            let recognized = try await MacObservationMode.$current.withValue(passive ? .passive : .interactive) {
                try await MacAppWindowText.read(bundleID: bundle, window: output["window_identity"])
            }
            tree["seam"] = output["seam"]
            if case .object(let seam)? = output["seam"] { tree["renderer_wait_note"] = seam["renderer_wait_note"] }
            tree["recognized_text"] = recognized.rows
            tree["recognized_text_body"] = .string(recognized.text)
            tree["window_identity"] = output["window_identity"]
            tree["frame_id"] = output["frame_id"]
            tree["affordances"] = output["affordances"]
            tree["app_bundle_id"] = .string(bundle)
            return .object(tree)
        }
        if tool == "screen", let corner = senseAppCorner(input), case .app(let bundle) = corner, !SenseDoor.readingRaw {
            return try await SenseDoor.read(corner: corner, address: str("part"), input: input,
                scope: ChatToolSessionContext.verifiedSessionId ?? "",
                raw: { try await self.impl_mac_four_verbs_tool(tool: tool, input: input.merging(["structured": .bool(true)]) { _, new in new }, surface: surface) },
                material: { raw in
                    _ = try Self.senseTextMaterial(raw)
                    let materialInput = input.merging(["app": .string(bundle), "__sense_app_material": .bool(true)]) { _, new in new }
                    return .accessibility(try await self.impl_mac_four_verbs_tool(
                        tool: "screen", input: materialInput, surface: surface))
                })
        }
        // What the chat's working card says while this verb runs. Said BEFORE
        // the verb, so a click that produces no new capture still moves the
        // caption; the card keeps the frame it already has. Prospective on
        // purpose — every frame captured mid-verb is a pre-action frame.
        let previewCaption = MacScreenPreviewCaption.intent(tool: tool, input: input)
        if let publish = MacScreenPreviewBus.publish, let previewCaption {
            await publish(MacScreenPreviewUpdate(image: nil, caption: previewCaption, at: Date()))
        }
        // Only `screen` may attach a window image.
        let pixels = tool == "screen"
            ? FourVerbPixelAttachment(part: str("part"), forced: input["pixels"] == .bool(true)) : nil
        var verbs = MacFourVerbs(
            host: host,
            supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(
                host: host,
                liveScene: fourVerbLiveScene,
                previewCaption: previewCaption,
                pixels: pixels
            ), flowRoot: dataRoot, flowSession: ChatToolSessionContext.verifiedSessionId
        )
        let sighted = MacSightRecorder()
        verbs.sightRecorder = sighted
        let reply: MacFourVerbsReply
        switch tool {
        case "screen":
            let seen = await verbs.screen(part: str("part"), app: str("app"), structured: input["structured"] == .bool(true))
            reply = seen.ok ? pixels?.attach().map { line in
                var detail = seen.detail
                detail["pixel_capture_status"] = .string(line)
                detail["image"] = pixels?.imageFrame
                return MacFourVerbsReply(ok: true, text: seen.text + "\n" + line, detail: detail)
            } ?? seen : seen
        case "act":
            func typeMode(_ fields: [String: JSONValue]) throws -> MacTypeMode {
                guard let raw = fields["mode"], raw != .null, raw != .string("") else { return .replace }
                guard case .string(let value) = raw, let mode = MacTypeMode(rawValue: value),
                      mode == .replace || fields["verb"] == .string("type") else {
                    throw AutonomyGateError.toolDenied(reason: "act mode must be replace (default) or append; append requires type")
                }
                return mode
            }
            if input["__sense_native_surface"] == .bool(true) {
                // A screen page lists "press" among an item's verbs.
                guard let app = str("app"), let target = str("target"), let verb = str("verb").map({ $0 == "press" ? "click" : $0 }),
                      ["click", "type", "select", "focus", "toggle", "scroll"].contains(verb),
                      ["handle", "frame_id", "front", "steps", "to", "to_app", "seconds", "repeat", "interval", "holding", "button", "scroll_amount"].allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                    throw AutonomyGateError.toolDenied(reason: "A native surface selection requires its app and current target, without foreground or gesture options.")
                }
                reply = await verbs.actNativeSurface(verb: verb, target: target, app: app,
                    label: str("__sense_native_label"),
                    text: input["text"].flatMap { if case .string(let text) = $0 { return text }; return nil },
                    mode: try typeMode(input))
                break
            }
            // A place on an image she was handed: {x, y} in that image's pixels.
            func imagePoint(_ value: JSONValue?) throws -> MacPointerPosition? {
                guard case .object(let point)? = value else { return nil }
                func coordinate(_ key: String) -> Double? {
                    switch point[key] { case .double(let v)?: return v; case .int(let v)?: return Double(v); default: return nil }
                }
                guard let x = coordinate("x"), let y = coordinate("y"), let position = MacPointerPosition(x: x, y: y) else {
                    throw AutonomyGateError.toolDenied(reason: "a point is {x, y} in pixels of the image it was read from; nothing was run")
                }
                return position
            }
            // `steps` is a short ordered batch in one call.
            // A plain string is shorthand for press (a key/chord → key, a
            // name → click); an object is {verb, target, text?}, or a verb at
            // a place on an image (at, or a drag's from/to).
            func parseStep(_ raw: JSONValue) throws -> MacActStep {
                switch raw {
                case .string(let name) where !name.trimmingCharacters(in: .whitespaces).isEmpty:
                    return MacActStep(verb: "press", target: name)
                case .object(let rawStep):
                    let mode = try typeMode(rawStep)
                    // "" is absent here too, so it never hides the field beside it.
                    let step = rawStep.filter { $0.value != .string("") && $0.value != .null }
                    // {verb:"key", text:"cmd+s"}: a key's chord may ride in text.
                    guard case .string(var verb)? = step["verb"] else { break }
                    // A step's own button:"right" is a right-click, not a silent left one.
                    if verb == "click", step["button"] == .string("right") { verb = "right_click" }
                    let at = try imagePoint(step["at"] ?? step["from"])
                    var image = str("frame_id") ?? str("image")
                    if case .string(let id)? = step["frame_id"] ?? step["image"] { image = id }
                    guard ["frame_id", "image"].allSatisfy({ key in
                        step[key] == nil || at != nil && step[key] == image.map(JSONValue.string)
                    }) else {
                        throw AutonomyGateError.toolDenied(reason: "A screen reference requires a handle or an image point; nothing was run")
                    }
                    if let at {
                        return MacActStep(verb: verb, target: "", place: MacImagePlace(image: image, at: at, to: try imagePoint(step["to"])))
                    }
                    var text: String?
                    // `value` is the word the screen shows (`Save As text = …`).
                    if case .string(let value)? = step["text"] ?? step["value"], !value.isEmpty { text = value }
                    // {verb:"type", text:…} with no target types into whatever has focus.
                    if step["target"] == nil, verb == "type", text != nil {
                        guard mode == .replace else {
                            throw AutonomyGateError.toolDenied(reason: "append requires a named text target; nothing was run")
                        }
                        return MacActStep(verb: verb, target: "", text: text, mode: mode)
                    }
                    // A handle is one press on one frame: the frame changes under a
                    // batch, so steps go by name and re-resolve on each fresh read.
                    if step["handle"] != nil {
                        throw AutonomyGateError.toolDenied(
                            reason: "a step cannot carry a handle (handles are one act on one frame; the frame changes between steps): name each step as the screen shows it, like \"7\" or \"Clear\"; nothing was run")
                    }
                    guard case .string(let target)? = step["target"]
                            ?? (["key", "press"].contains(verb) ? step["text"] : nil),
                          !target.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    var to: String?
                    if case .string(let destination)? = step["to"] { to = destination }
                    return MacActStep(verb: verb, target: target, text: text, mode: mode, to: to)
                default: break
                }
                throw AutonomyGateError.toolDenied(
                    reason: "each step is a name (\"9\"), {verb, target, text?}, or {verb, at:{x,y}} / {verb:\"drag\", from:{x,y}, to:{x,y}}; nothing was run"
                )
            }
            let steps: [MacActStep]
            if case .array(let rawSteps)? = input["steps"] { steps = try rawSteps.map(parseStep) }
            else { steps = [] }
            let place = try imagePoint(input["at"] ?? input["from"]).map {
                MacImagePlace(image: str("frame_id") ?? str("image"), at: $0, to: try imagePoint(input["to"]))
            }
            // Empty optional fields are absent; only parsed points or steps consume a reference.
            let absent: [JSONValue?] = [nil, .null, .string("")]
            if !absent.contains(input["handle"]) || place == nil && steps.isEmpty
                && ["frame_id", "image"].contains(where: { !absent.contains(input[$0]) }) {
                guard let handle = str("handle"), let frame = str("frame_id") ?? str("image"), let verb = str("verb"),
                      ["frame_id", "image"].allSatisfy({ absent.contains(input[$0]) || str($0) == frame }),
                      ["at", "from", "steps", "to", "to_app", "seconds", "repeat", "interval", "holding", "button", "scroll_amount"].allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                    throw AutonomyGateError.toolDenied(reason: "An exact screen selection requires handle and frame_id together, with no physical gesture or repeat options. Look again if the selection is stale.")
                }
                reply = await verbs.actSelection(verb: verb, handle: handle, frameID: frame,
                    text: input["text"].flatMap { if case .string(let text) = $0 { return text }; return nil },
                    mode: try typeMode(input), direction: str("direction"))
                break
            }
            let usedReferences = steps.isEmpty ? [place?.image].compactMap { $0 } : steps.compactMap { $0.place?.image }
            // Name steps re-resolve on fresh reads; a frame_id beside them is the
            // read she acted from, carried along, not a reference left unused.
            let nameSteps = !steps.isEmpty && steps.allSatisfy { $0.place == nil }
            guard nameSteps || ["frame_id", "image"].allSatisfy({ key in
                absent.contains(input[key]) || str(key).map { usedReferences.contains($0) } == true
            }) else {
                throw AutonomyGateError.toolDenied(reason: "A screen reference requires a handle or an image point; nothing was run")
            }
            let pointPlaces = steps.isEmpty ? (place.map { [$0] } ?? []) : steps.compactMap(\.place)
            if pointPlaces.contains(where: { $0.image == nil }), MacImageFrames.frame(nil) == nil {
                let look = try await impl_mac_four_verbs_tool(tool: "screen", input: ["pixels": .bool(true)], surface: surface)
                if MacImageFrames.frame(nil) == nil { return look }
            }

            if !steps.isEmpty {
                reply = await verbs.act(verb: "", target: "", app: str("app"),
                                        front: input["front"] == .bool(true), steps: steps, again: input["again"] == .bool(true))
                break
            }
            // No target: a type goes into whatever has focus; a key's chord may ride in text.
            let focusTarget: (String) -> String? = { verb in
                ["key", "press"].contains(verb) ? str("text") : verb == "type" && str("text") != nil ? "" : nil
            }
            guard let verb = str("verb"), let target = place != nil ? "" : str("target") ?? focusTarget(verb) else {
                throw AutonomyGateError.toolDenied(
                    reason: "act needs `verb` and `target` — say what to do and the name of the thing"
                )
            }
            let directedVerb: String = {
                guard verb == "scroll", let direction = str("direction") else { return verb }
                return "scroll \(direction)"
            }()
            if verb == "scroll", let directionValue = input["direction"], directionValue != .null {
                guard let direction = str("direction"), ["up", "down", "left", "right"].contains(direction) else {
                    throw AutonomyGateError.toolDenied(reason: "scroll direction must be up, down, left or right")
                }
            }
            if let button = input["button"], button != .null, str("button") == nil {
                throw AutonomyGateError.toolDenied(reason: "act button must be the string auto, left or right")
            }
            let scrollAmount: Int?
            if let amount = input["scroll_amount"], amount != .null {
                guard let value = num("scroll_amount"), value.isFinite,
                      value.rounded() == value, (0...120).contains(value) else {
                    throw AutonomyGateError.toolDenied(reason: "scroll_amount must be an integer from 0 to 120; 0 means default")
                }
                scrollAmount = Int(value)
            } else { scrollAmount = nil }
            reply = await verbs.act(
                verb: directedVerb,
                target: target,
                text: input["text"].flatMap { value in
                    if case .string(let text) = value { return text }
                    return nil
                },
                mode: try typeMode(input),
                to: str("to"),
                // The app whose window receives the drop.
                toApp: str("to_app"),
                seconds: num("seconds"),
                repeat: input["repeat"].flatMap { value in
                    if case .int(let count) = value { return Int(clamping: count) }
                    return nil
                },
                interval: num("interval"),
                holding: str("holding"),
                button: str("button"),
                scrollAmount: scrollAmount,
                // Act in that app's window in the back;
                // `front: true` brings it forward briefly and puts it back.
                app: str("app"),
                front: input["front"] == .bool(true),
                place: place
            )
        case "go":
            guard let name = str("name") ?? str("target") else {
                throw AutonomyGateError.toolDenied(
                    reason: "go needs `name` — an app, a file or folder path, or a URL"
                )
            }
            if let continuation = MacWorkContinuation.current, continuation.isPending,
               let app = continuation.app,
               name.caseInsensitiveCompare(app.name) != .orderedSame,
               name.caseInsensitiveCompare(app.bundleIdentifier ?? "") != .orderedSame {
                return .object(["ok": .bool(false), "text": .string(continuation.modelContext), "effects": .string("none"),
                    "detail": .object(["error": .string("continuation_target_mismatch")])])
            }
            reply = await verbs.go(name, front: input["front"] == .bool(true))
        case "wait":
            reply = await verbs.wait(until: str("until"), seconds: num("seconds"))
        default:
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' is not a four-verb tool"
            )
        }
        // The verb has returned, and the last frame the card received is the
        // post-action look the verb took to verify itself. Only now may the
        // words move to the past tense, and only carrying the verb's own
        // verified result.
        if let publish = MacScreenPreviewBus.publish,
           let settled = MacScreenPreviewCaption.settled(tool: tool, input: input, ok: reply.ok) {
            await publish(MacScreenPreviewUpdate(image: nil, caption: settled, at: Date()))
        }
        // Acting claims a window; looking only refreshes a window already hers.
        if let seen = sighted.last, tool == "act"
            || (tool == "screen" && str("app") != nil
                && HerScreen.touched(dataRoot: dataRoot, now: Date()).contains { $0.app == HerScreen.clip(seen.app, 40) }) {
            HerScreen.touch(dataRoot: dataRoot, app: seen.app, kind: seen.kind, readouts: seen.readouts, before: seen.before)
        }
        var payload: [String: JSONValue] = [
            "ok": .bool(reply.ok),
            "text": .string(reply.text),
        ]
        // A verb that failed having let nothing out changed nothing.
        if !reply.ok { payload["effects"] = .string(host.started == 0 ? "none" : "unknown") }
        if !reply.ok, reply.detail["error"] == .string("accessibility_not_trusted") {
            payload["remedy"] = Repair.remedy(owner: "macOS Accessibility permission", nextCall: nil,
                tap: "System Settings > Privacy & Security > Accessibility > NativeAgent switch")
        }
        if let operationId = reply.detail["operationId"] { payload["operationId"] = operationId }
        if let operationState = reply.detail["operationState"] { payload["operationState"] = operationState }
        if let verification = reply.agentDetail["verification"] { payload["verification"] = verification }
        if let remedy = reply.detail["remedy"] { payload["remedy"] = remedy }
        if !reply.ok, case .string(let error)? = reply.detail["error"], error.hasPrefix("human_takeover:") {
            payload["remedy"] = access.fullMacActive ? .object([
                "kind": .string("correct_arguments"),
                "instruction": .string("The person took over. When they ask you to act again, repeat this call to reacquire control under Full Mac."),
                "next_call": .object(["tool": .string("app"), "input": .object([
                    "action": .string(ToolNameAliases.appAction(tool) ?? tool), "args": .object(input),
                ])]),
            ]) : Repair.why(owner: "Mac input handback",
                tap: "NativeAgent Mac chat > composer controls > Let [agent name] use the Mac")
        }
        if !reply.agentDetail.isEmpty { payload["detail"] = .object(reply.agentDetail) }
        if tool == "screen" { payload["sense_provenance"] = .string("raw view · existing screen reader") }
        return .object(payload)
    }

    /// Raw MacControl calls share accessibility admission; only injected actions
    /// carry body-bound, single-use capabilities. Clipboard reads stay redacted.
    func impl_mac_control_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.accessibilityAllowed else {
            if let need = macControlCategoryNeedEnvelope(
                categories: ["accessibility"], mode: Self.screenControlReadToolNames.contains(tool) ? .read : .write,
                why: "Screen control lets me read and control apps on your Mac."
            ) { return need }
            throw AutonomyGateError.toolDenied(
                reason: "Trust Full Mac Accessibility category is not active for \(tool)"
            )
        }
        let action = tool.hasPrefix("mac_") ? String(tool.dropFirst(4)) : tool
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(policy: access.macPolicy),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        if Self.fullMacAccessibilityInjectionToolNames.contains(tool) || Self.macMenuPressToolNames.contains(tool) {
            guard let capability = MacInjectionCapabilityContext.current
                ?? MacInjectionCapability.mint(
                    approvalID: "yolo-\(UUID().uuidString)",
                    action: action,
                    body: input
                ) else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_approval_missing: \(tool) could not mint a capability"
                )
            }
            return try await impl.dispatchApprovedInjection(
                action: action,
                body: input,
                capability: capability
            ).toJSON()
        }
        var body = input
        // Menu find also searches words over the walk.
        if tool == "menu" { body["words"] = input["find"] }
        return try await impl.dispatch(action: action, body: body).toJSON()
    }

    /// Reads require Full Mac Accessibility authority; explicit paths also require file authority.
    /// Without a path, MacControl reads live window text and restores any viewport it moves.
    /// Explicit file reads retain workspace policy and sensitive-path fences.
    func impl_mac_read_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        guard tool == "read" else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift read implementation"
            )
        }
        let namedPath: String? = {
            guard case .string(let path)? = input["path"] else { return nil }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let access = await fullMacToolAccess(surface: surface)
        guard access.accessibilityAllowed, namedPath == nil || access.fileOpsAllowed else {
            if let need = macControlCategoryNeedEnvelope(
                categories: ["accessibility"] + (namedPath == nil ? [] : ["file_ops"]), mode: .read,
                why: namedPath == nil ? "Screen control lets me read and control apps on your Mac."
                    : "Screen control and file access let me read the document you named on your Mac."
            ) { return need }
            throw AutonomyGateError.toolDenied(
                reason: !access.accessibilityAllowed
                    ? "Trust Full Mac Accessibility category is not active for \(tool)"
                    : "Trust Full Mac file access is not active for \(tool) with an explicit path; "
                    + "read what is on screen instead by calling it with no path"
            )
        }
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(policy: access.macPolicy),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        var selectedCorner = senseAppCorner(input) ?? SenseCorner.stream(id: "mac.read")
        var nativeReadSupported = true
        if let namedPath {
            let fileCorner = SenseCorner.fileKind(URL(fileURLWithPath: namedPath).pathExtension.lowercased())
            selectedCorner = fileCorner
            if case .unsupported = MacDocumentRead.kind(forPath: namedPath) {
                selectedCorner = fileCorner
                nativeReadSupported = false
            }
        }
        let corner = selectedCorner
        var senseInput = input
        senseInput["__sense_reader"] = .string("read")
        return try await SenseDoor.read(corner: corner, address: namedPath, input: senseInput,
                scope: ChatToolSessionContext.verifiedSessionId ?? "",
                nativeCorner: .stream(id: "mac.read"),
                nativeReadSupported: nativeReadSupported,
                fileAlreadyReadable: namedPath.map { FileReadSourceMaterial.nativeReadSupported(path: $0) } ?? false,
                raw: { try await impl.dispatch(action: "read", body: input).toJSON() },
                material: { raw in
                    if let namedPath {
                        guard case .object(let fields) = raw,
                              fields["ok"] == .bool(true) || fields["error"] == .string("unsupported_document_type") else {
                            throw SenseFailure(code: "source_unavailable", message: "The original document reader refused this file.")
                        }
                        let path = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(
                            namedPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))).path
                        guard MacControlSensitivePathFence.reason(forPath: path) == nil else {
                            throw SenseFailure(code: "source_unavailable", message: "This document is inside a protected path.")
                        }
                        let attributes = try FileManager.default.attributesOfItem(atPath: path)
                        return .file(path: path, bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0)
                    }
                    if case .app(let bundle) = corner {
                        let tree = try await self.impl_mac_four_verbs_tool(tool: "screen",
                            input: ["app": .string(bundle), "raw": .bool(true), "__sense_app_material": .bool(true)], surface: surface)
                        return .accessibility(tree)
                    }
                    return try Self.senseTextMaterial(raw)
                })
    }

}
