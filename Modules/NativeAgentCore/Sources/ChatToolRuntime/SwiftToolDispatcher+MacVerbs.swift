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
import MacIntegration
import Context
import SwarmRuns
import Senses
import ToolRegistry
import ActivityWatch
import ChatTurnContracts
import NativeAgentShared
// Blueprint: | `SwiftToolDispatcher+MacVerbs.swift` | Four-verb arguments; observed image identity; shared deadlines; `impl_mac_four_verbs_tool` outlines its stages (desktop pixels, app material, sense-door app read, act routing, result) |

extension SwiftToolDispatcher {
    /// A watch shares four-verb access for opening and each act; revoking screen control ends it.
    @concurrent public func openScreenWatch(turn: Turn, invocation: ChatToolInvocation, _ request: MacScreenWatch.Request, hands: Bool,
        surface: String) async throws -> MacScreenWatch {
        let verbs: @Sendable () async throws -> MacFourVerbs = {
            let access = try await self.fullMacToolAccess(turn: turn, surface: surface)
            guard access.accessibilityAllowed else {
                throw MacScreenWatch.Refusal(receipt: self.macControlCategoryNeedEnvelope(invocation: invocation,
                    categories: ["accessibility"], mode: hands ? .write : .read,
                    why: "Screen control lets me read and control apps on your Mac.")
                    ?? ChatToolOutcome.failure(error: AutonomyGateError.toolDenied(
                        reason: "Trust Full Mac Accessibility category is not active for screen.watch"), tool: "screen.watch"))
            }
            let host = makeMacControl(policyProvider: TrustCenterMacControlPolicyProvider(admittedPolicy: access.macPolicy, dataRoot: self.dataRoot),
                                      auditDataRoot: self.dataRoot)
            return MacFourVerbs(host: host, supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(
                invocation: invocation,
                host: host, liveScene: self.fourVerbLiveScene))
        }
        do {
            return try await verbs().watch(request, dataRoot: dataRoot, hands: hands ? verbs : nil,
                                           turn: turn, context: invocation.macContext(dataRoot: dataRoot),
                                           authority: { try await self.fullMacToolAccess(turn: turn, surface: surface).accessibilityAllowed })
        } catch {
            let failure = SenseFailure(error)
            if turn.act == nil, case .object(let remedy)? = failure.remedy,
               remedy["kind"] == .string("repair"), case .string(let owner)? = remedy["owner"] {
                let tap: String? = if case .string(let value)? = remedy["tap"] { value } else { nil }
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "screen.watch:" + owner,
                    owner: owner, words: failure.message, nextCall: remedy["next_call"].flatMap { try? $0.serialize(pretty: false) }, tap: tap)
            }
            throw error
        }
    }

    /// A screen page's whole address given as `target` (an object or its JSON text) is that exact selection: its handle and frame, or a supplemental surface's
    /// current target in its app.
    static func unwrappingScreenAddress(_ input: [String: JSONValue]) -> [String: JSONValue] {
        MacAppActGate.unwrappingScreenAddress(input)
    }

    /// Screen and wait request read authority; act and go request write authority. All require Full Mac accessibility. Ordinary calls use words; workspace
    /// selections return exact bindings through the same gate and owner.
    @concurrent func impl_mac_four_verbs_tool(turn: Turn, invocation: ChatToolInvocation,
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        if invocation.waitDeadline == nil, ["act", "screen"].contains(tool) {
            do {
                return try await OperationWaitBudget.withDeadline(
                    seconds: Double(SwiftNativeMacControl.operationTimeoutSeconds(action: tool, body: input)),
                    budget: .init(deadline: invocation.waitDeadline)
                ) { budget in
                    try await self.impl_mac_four_verbs_tool(turn: turn, invocation: invocation.with(\.waitDeadline, budget.deadline), tool: tool, input: input,
                        surface: surface)
                }
            } catch is OperationWaitBudget.Exceeded {
                return SwiftNativeMacControl.deadlineResult(action: tool).toJSON(readContent: invocation.readContent)
            }
        }
        if invocation.observationMode != .passive,
           input["__sense_app_observation"] == .bool(true) || invocation.passiveObservation {
            return try await self.impl_mac_four_verbs_tool(turn: turn, invocation: invocation.with(\.observationMode, .passive), tool: tool, input: input,
                surface: surface)
        }
        let filtered = input.filter {
            !(["direction", "button"].contains($0.key) && ($0.value == .string("")))
        }
        let input = tool == "act" ? Self.unwrappingScreenAddress(filtered) : filtered
        if invocation.observationMode != .passive,
           let continuation = turn.macContinuation, continuation.isPending,
           let refusal = continuation.refusal(context: invocation.macContext(dataRoot: dataRoot)) {
            return .object(["ok": .bool(false), "text": .string(refusal), "effects": .string("none"),
                "detail": .object(["error": .string("continuation_unavailable")])])
        }
        let access = try await fullMacToolAccess(turn: turn, surface: surface)
        guard access.accessibilityAllowed else {
            if let need = macControlCategoryNeedEnvelope(invocation: invocation,
                categories: ["accessibility"], mode: (tool == "screen" || tool == "wait") ? .read : .write,
                why: "Screen control lets me read and control apps on your Mac."
            ) { return need }
            throw AutonomyGateError.toolDenied(
                reason: "Trust Full Mac Accessibility category is not active for \(tool)"
            )
        }
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        func num(_ key: String) -> Double? { input[key]?.doubleValue }
        if tool == "screen", input["__sense_app_material"] != .bool(true), try Self.desktopPixelsRequested(input) {
            return try await fourVerbDesktopPixels(turn: turn, invocation: invocation, input: input)
        }
        let context = invocation.macContext(dataRoot: dataRoot)
        let impl = makeMacControl(policyProvider: TrustCenterMacControlPolicyProvider(admittedPolicy: access.macPolicy, dataRoot: dataRoot),
            auditDataRoot: dataRoot
        )
        // The verbs count what they let out, so a failure says its own effects.
        let host = MacMotorCount(impl)
        if tool == "screen", input["__sense_app_material"] == .bool(true) {
            return try await fourVerbAppMaterial(host: host, turn: turn, invocation: invocation, input: input, context: context)
        }
        if tool == "screen", let corner = senseAppCorner(input), case .app(let bundle) = corner, !invocation.readingRaw {
            return try await fourVerbSenseAppRead(corner: corner, bundle: bundle, turn: turn, invocation: invocation, tool: tool,
                input: input, surface: surface)
        }
        // Set a prospective caption before acting: mid-verb frames are pre-action, and no new frame may arrive.
        let previewCaption = MacScreenPreviewCaption.intent(tool: tool, input: input)
        if let publish = turn.screenPreview, let previewCaption {
            await publish(MacScreenPreviewUpdate(image: nil, caption: previewCaption, at: Date()))
        }
        // Only `screen` may attach a window image.
        let pixels = tool == "screen"
            ? FourVerbPixelAttachment(part: str("part"), forced: input["pixels"] == .bool(true), turn: turn, invocation: invocation) : nil
        var verbs = MacFourVerbs(
            host: host,
            supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(
                invocation: invocation,
                host: host,
                liveScene: fourVerbLiveScene,
                previewCaption: previewCaption,
                pixels: pixels
            ), flowRoot: dataRoot, flowSession: turn.verifiedSessionID
        )
        let sighted = MacSightRecorder()
        verbs.sightRecorder = sighted
        let reply: MacFourVerbsReply
        switch tool {
        case "screen":
            let seen = await verbs.screen(part: str("part"), app: str("app"), structured: input["structured"] == .bool(true), turn: turn, context: context)
            reply = seen.ok ? pixels?.attach().map { line in
                var detail = seen.detail
                detail["pixel_capture_status"] = .string(line)
                detail["image"] = pixels?.imageFrame ?? .null
                return MacFourVerbsReply(ok: true, text: seen.text + "\n" + line, detail: detail)
            } ?? seen : seen
        case "act":
            reply = try await fourVerbAct(verbs: verbs, input: input, turn: turn, context: context)
        case "go":
            guard let name = str("name") else {
                throw AutonomyGateError.toolDenied(
                    reason: "go needs `name` — an app, a file or folder path, or a URL"
                )
            }
            if let continuation = turn.macContinuation, continuation.isPending,
               let app = continuation.app,
               name.caseInsensitiveCompare(app.name) != .orderedSame,
               name.caseInsensitiveCompare(app.bundleIdentifier ?? "") != .orderedSame {
                return .object(["ok": .bool(false), "text": .string(continuation.modelContext(context: context)), "effects": .string("none"),
                    "detail": .object(["error": .string("continuation_target_mismatch")])])
            }
            let went = await verbs.go(name, front: input["front"] == .bool(true), turn: turn, context: context)
            // A System Settings pane is where the person grants; the screen may be unreadable there, so the reply says what is granted now from
            // the app's own grant reading.
            if name.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("x-apple.systempreferences") {
                let reach = await SystemPermissionPreflight.reachNow()
                reply = MacFourVerbsReply(ok: went.ok, text: went.text + "\n" + reach.text,
                                          detail: went.detail.merging(["grants": reach.detail]) { _, new in new })
            } else {
                reply = went
            }
        case "wait":
            reply = await verbs.wait(until: str("until"), seconds: num("seconds"), turn: turn, context: context)
        default:
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' is not a four-verb tool"
            )
        }
        // Settle the preview from the action's receipt.
        if let publish = turn.screenPreview,
           let settled = MacScreenPreviewCaption.settled(tool: tool, input: input, reply: reply) {
            await publish(MacScreenPreviewUpdate(image: nil, caption: settled, at: Date()))
        }
        return fourVerbResult(reply: reply, sighted: sighted, host: host, access: access, tool: tool, input: input)
    }

    /// A screen call that asks for desktop pixels answers with that raw view; a `wrong` reading goes to the sense door with the pixels as its
    /// only raw view, which grows no app material from them.
    @concurrent private func fourVerbDesktopPixels(turn: Turn, invocation: ChatToolInvocation, input: [String: JSONValue]) async throws -> JSONValue {
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        // A failed picture reports its own cause; no other read stands in for it.
        let result = await Self.desktopPixels(turn: turn, invocation: invocation, context: invocation.macContext(dataRoot: dataRoot), input: input)
        if input["wrong"] == .bool(true), let corner = senseAppCorner(input) {
            return try await SenseDoor.read(corner: corner, address: str("part"), input: input,
                scope: turn.verifiedSessionID ?? "", operation: invocation.senseOperation(turn: turn), raw: { _ in result },
                material: { _, _ in throw SenseFailure(code: "source_unavailable",
                    message: "Desktop pixels are a raw view; app growth uses the running window's AX material.") })
        }
        if case .object(var fields) = result {
            fields["sense_provenance"] = .string("raw view · desktop pixels requested")
            return .object(fields)
        }
        return result
    }

    /// A concrete running app's accessibility material for the sense door: its look, recognized window text and window identity.
    @concurrent private func fourVerbAppMaterial(host: MacMotorCount, turn: Turn, invocation: ChatToolInvocation, input: [String: JSONValue],
        context: MacOperationContext) async throws -> JSONValue {
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        guard let bundle = str("app"), bundle != "*" else {
            throw SenseFailure(code: "source_unavailable", message: "App material needs a concrete already-running app.")
        }
        var body: [String: JSONValue] = ["grade": .string("look"),
            "app_map": .bool(true), "sense_material": .bool(true), "app": .string(bundle)]
        if let part = str("part") { body["seek"] = .string(part) }
        let readBody = body
        let passive = input["__sense_app_observation"] == .bool(true) || invocation.passiveObservation
            || invocation.observationMode == .passive
        let frameSource = "sense:app:" + bundle + (passive ? ":watch" : "")
        var readContext = context
        readContext.observationMode = passive ? .passive : .interactive
        readContext.frameSource = frameSource
        let view = try await host.dispatch(action: "look", body: readBody, turn: turn,
            context: readContext)
        if passive, !view.ok, case .object(let output) = view.output, case .string(let message)? = output["message"] {
            throw SenseFailure(code: "source_unavailable", message: message)
        }
        guard view.ok, case .object(let output) = view.output, case .object(var tree)? = output["accessibility"] else {
            throw SenseFailure(code: "source_unavailable", message: "The app's accessibility material could not be read.")
        }
        let recognized = try await MacAppWindowText.read(bundleID: bundle, window: output["window_identity"],
            context: readContext)
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

    /// A screen read of an app goes through the sense door: its raw view is this tool's structured read, its material the app's accessibility tree.
    @concurrent private func fourVerbSenseAppRead(corner: SenseCorner, bundle: String, turn: Turn, invocation: ChatToolInvocation, tool: String,
        input: [String: JSONValue], surface: String) async throws -> JSONValue {
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        return try await SenseDoor.read(corner: corner, address: str("part"), input: input,
            scope: turn.verifiedSessionID ?? "",
            operation: invocation.senseOperation(turn: turn),
            raw: { operation in
                var operation = operation
                operation.options.raw = true
                return try await self.impl_mac_four_verbs_tool(turn: turn, invocation: invocation.serving(sense: operation), tool: tool, input: input
                    .merging(["structured": .bool(true)]) { _, new in new },
                surface: surface) },
            material: { raw, operation in
                _ = try Self.senseTextMaterial(raw)
                let materialInput = input.merging(["app": .string(bundle), "__sense_app_material": .bool(true)]) { _, new in new }
                return .accessibility(try await self.impl_mac_four_verbs_tool(turn: turn, invocation: invocation.serving(sense: operation),
                    tool: "screen", input: materialInput, surface: surface))
            })
    }

    /// An act's arguments choose its route: a native surface selection, an exact handle selection, ordered steps, or one verb at a name or
    /// point. Every malformed field is refused before anything runs.
    @concurrent private func fourVerbAct(verbs: MacFourVerbs, input: [String: JSONValue], turn: Turn, context: MacOperationContext) async throws
        -> MacFourVerbsReply {
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        func num(_ key: String) -> Double? { input[key]?.doubleValue }
        let text = input["text"]?.stringValue
        for key in ["seconds", "interval"] where input[key] != nil && input[key] != .null {
            guard let value = num(key), value.isFinite else {
                throw AutonomyGateError.toolDenied(reason: "act \(key) must be a finite number; nothing was run")
            }
        }
        if input["__sense_native_surface"] == .bool(true) {
            guard let app = str("app"), let target = str("target"), let verb = str("verb").map({ $0 == "press" ? "click" : $0 }),
                  ["click", "type", "select", "focus", "toggle", "scroll"].contains(verb),
                  ["handle", "frame_id", "front", "steps", "to", "to_app", "seconds", "repeat", "interval", "holding", "button",
                      "scroll_amount"].allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                throw AutonomyGateError.toolDenied(
                    reason: "A native surface selection requires its app and current target, without foreground or gesture options.")
            }
            return await verbs.actNativeSurface(verb: verb, target: target, app: app,
                label: str("__sense_native_label"),
                text: text,
                mode: try typeMode(input), turn: turn, context: context)
        }
        let steps: [MacActStep]
        if case .array(let rawSteps)? = input["steps"] { steps = try rawSteps.map { try parseStep($0, input: input) } }
        else { steps = [] }
        // A move has one point; a lone `to` is where it goes.
        let moveTo = str("verb") == "move" && input["at"] == nil && input["from"] == nil ? input["to"] : nil
        let place = try imagePoint(input["at"] ?? input["from"] ?? moveTo).map {
            MacImagePlace(image: str("frame_id") ?? str("image"), at: $0, to: try moveTo == nil ? imagePoint(input["to"]) : nil)
        }
        // Empty optional fields are absent; only parsed points or steps consume a reference.
        let absent: [JSONValue?] = [nil, .null, .string("")]
        let hasText = text?.isEmpty == false
        let focusType = str("verb") == "type" && str("target") == nil && str("handle") == nil
            && place == nil && steps.isEmpty && hasText
        if !absent.contains(input["handle"]) || place == nil && steps.isEmpty
            && !focusType && ["frame_id", "image"].contains(where: { !absent.contains(input[$0]) }) {
            guard let handle = str("handle"), let frame = str("frame_id") ?? str("image"), let verb = str("verb"),
                  ["frame_id", "image"].allSatisfy({ absent.contains(input[$0]) || str($0) == frame }),
                  ["at", "from", "steps", "to", "to_app", "seconds", "repeat", "interval", "holding", "button"].allSatisfy({
                      input[$0] == nil || input[$0] == .null }),
                  verb == "scroll" || ["direction", "scroll_amount"].allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                throw AutonomyGateError.toolDenied(reason: """
                    An exact screen selection requires handle and frame_id together. Only scroll takes direction and scroll_amount. Point, \
                    drag, button, holding and repeat options are unavailable. Look again if the selection is stale.
                    """)
            }
            return await verbs.actSelection(verb: verb, handle: handle, frameID: frame,
                text: text, mode: try typeMode(input), direction: try scrollDirection(input["direction"]),
                scrollAmount: try scrollAmount(input["scroll_amount"]), app: str("app"), turn: turn, context: context)
        }
        let usedReferences = steps.isEmpty ? [place?.image].compactMap { $0 } : steps.compactMap { $0.place?.image ?? $0.frameID }
        // Name steps re-resolve on fresh reads; a frame_id beside them is the read the agent acted from, carried along, not a reference left unused.
        let nameSteps = !steps.isEmpty && steps.allSatisfy { $0.place == nil && $0.handle == nil }
        guard nameSteps || focusType || ["frame_id", "image"].allSatisfy({ key in
            absent.contains(input[key]) || str(key).map { usedReferences.contains($0) } == true
        }) else {
            throw AutonomyGateError.toolDenied(reason: "A screen reference requires a handle or an image point; nothing was run")
        }
        let pointPlaces = steps.isEmpty ? (place.map { [$0] } ?? []) : steps.compactMap(\.place)
        if pointPlaces.contains(where: { $0.image == nil }), MacImageFrames.frame(nil, turn: turn) == nil {
            throw AutonomyGateError.toolDenied(reason: """
                A point needs an image you have already seen. Read mac.look with pixels:true, then choose the point from that image; nothing \
                was run.
                """)
        }

        if !steps.isEmpty {
            return await verbs.act(verb: "", target: "", app: str("app"),
                                    front: input["front"] == .bool(true), steps: steps, again: input["again"] == .bool(true), turn: turn, context: context)
        }
        // No target: a type goes into whatever has focus; a key's chord may ride in text.
        let focusTarget: (String) -> String? = { verb in
            if ["key", "press"].contains(verb) { return str("text") }
            if verb == "type" && hasText || MacFourVerbs.isScrollVerb(verb) { return "" }
            return nil
        }
        guard let verb = str("verb") else {
            throw AutonomyGateError.toolDenied(reason: "act needs a `verb` — say what to do (click, type, move, drag, scroll, key)")
        }
        guard let target = place != nil ? "" : str("target") ?? focusTarget(verb) else {
            throw AutonomyGateError.toolDenied(
                reason: "act \(verb) needs a `target` (the name of the thing) or a point (`at`: {x, y}; a drag also takes `to`)"
            )
        }
        let direction = verb == "scroll" ? try scrollDirection(input["direction"]) : nil
        let button = try mouseButton(input)
        let amount = try scrollAmount(input["scroll_amount"])
        return await verbs.act(
            verb: direction.map { "scroll \($0)" } ?? verb,
            target: target,
            text: text,
            mode: try typeMode(input),
            to: str("to"),
            toApp: str("to_app"),
            seconds: num("seconds"),
            repeat: input["repeat"].flatMap { value in
                if case .int(let count) = value { return Int(clamping: count) }
                return nil
            },
            interval: num("interval"),
            holding: input["holding"]?.trimmedString,
            button: button,
            scrollAmount: amount,
            // Act in that app's window in the back; `front: true` brings it forward briefly and puts it back.
            app: str("app"),
            front: input["front"] == .bool(true),
            place: place, turn: turn, context: context
        )
    }

    // MARK: Four-verb act arguments

    private func scrollDirection(_ raw: JSONValue?) throws -> String? {
        guard let raw, raw != .null else { return nil }
        guard let value = raw.trimmedString, MacActScrollDirection(rawValue: value) != nil else {
            throw AutonomyGateError.toolDenied(reason: "scroll direction must be up, down, left or right")
        }
        return value
    }

    private func scrollAmount(_ raw: JSONValue?) throws -> Int? {
        guard let raw, raw != .null else { return nil }
        guard let value = raw.exactIntegerValue, (0...120).contains(value) else {
            throw AutonomyGateError.toolDenied(reason: "scroll_amount must be an integer from 0 to 120; 0 means default")
        }
        return value
    }

    private func mouseButton(_ fields: [String: JSONValue]) throws -> String? {
        let button = fields["button"]?.trimmedString
        if let raw = fields["button"], raw != .null, button == nil {
            throw AutonomyGateError.toolDenied(reason: "act button must be the string auto, left or right")
        }
        return button
    }
    private func typeMode(_ fields: [String: JSONValue]) throws -> MacTypeMode {
        guard let raw = fields["mode"], raw != .null, raw != .string("") else { return .replace }
        guard case .string(let value) = raw, let mode = MacTypeMode(rawValue: value),
              mode == .replace || fields["verb"] == .string("type") else {
            throw AutonomyGateError.toolDenied(reason: "act mode must be replace (default) or append; append requires type")
        }
        return mode
    }
    private func imagePoint(_ value: JSONValue?) throws -> MacPointerPosition? {
        guard case .object(let point)? = value else { return nil }
        guard let x = point["x"]?.doubleValue, let y = point["y"]?.doubleValue, let position = MacPointerPosition(x: x, y: y) else {
            throw AutonomyGateError.toolDenied(reason: "a point is {x, y} in pixels of the image it was read from; nothing was run")
        }
        return position
    }
    // String steps mean press; object steps retain verb, target, text or image-point geometry.
    private func parseStep(_ raw: JSONValue, input: [String: JSONValue]) throws -> MacActStep {
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        switch raw {
        case .string(let name) where !name.trimmingCharacters(in: .whitespaces).isEmpty:
            return MacActStep(verb: "press", target: name)
        case .object(let rawStep):
            let mode = try typeMode(rawStep)
            let holding = rawStep["holding"]?.trimmedString
            let button = try mouseButton(rawStep)
            // "" is absent here too, so it never hides the field beside it.
            let step = rawStep.filter { $0.value != .string("") && $0.value != .null }
            // {verb:"key", text:"cmd+s"}: a key's chord may ride in text.
            guard case .string(let verb)? = step["verb"] else { break }
            let at = try imagePoint(step["at"] ?? step["from"])
            var image = str("frame_id") ?? str("image")
            if case .string(let id)? = step["frame_id"] ?? step["image"] { image = id }
            var text: String?
            if case .string(let value)? = step["text"] ?? step["value"], !value.isEmpty { text = value }
            if let rawHandle = step["handle"] {
                guard case .string(let handle) = rawHandle, !handle.isEmpty, let frameID = image,
                      ["frame_id", "image"].allSatisfy({ step[$0] == nil || step[$0] == .string(frameID) }),
                      MacFourVerbs.selectionVerbs.contains(verb),
                      ["target", "at", "from", "holding", "button"].allSatisfy({ step[$0] == nil }),
                      verb == "scroll" || ["direction", "to", "scroll_amount"].allSatisfy({ step[$0] == nil }) else {
                    throw AutonomyGateError.toolDenied(reason: """
                        A handle step for \"\(verb)\" needs handle and frame_id together. Only scroll takes direction (or to) and scroll_amount. \
                        Names, points, holding and buttons are unavailable. No step ran. Use one of \
                        \(MacFourVerbs.selectionVerbs.joined(separator: ", ")).
                        """)
                }
                let direction = try scrollDirection(step["direction"])
                let toDirection = try scrollDirection(step["to"])
                if let direction, let toDirection, direction != toDirection {
                    throw AutonomyGateError.toolDenied(reason: "A handle scroll step's direction and to must agree. No step ran.")
                }
                return MacActStep(verb: verb, target: "", text: text, mode: mode, handle: handle, frameID: frameID,
                    direction: direction ?? toDirection, scrollAmount: try scrollAmount(step["scroll_amount"]))
            }
            guard ["frame_id", "image"].allSatisfy({ key in
                step[key] == nil || at != nil && step[key] == image.map(JSONValue.string)
            }) else {
                throw AutonomyGateError.toolDenied(reason: "A screen reference requires a handle or an image point; nothing was run")
            }
            if let at {
                return MacActStep(verb: verb, target: "", text: text, mode: mode, place: MacImagePlace(image: image, at: at,
                    to: try imagePoint(step["to"])),
                                  holding: holding, button: button)
            }
            // {verb:"type", text:…} with no target types into whatever has focus.
            if step["target"] == nil, verb == "type", text != nil {
                guard mode == .replace else {
                    throw AutonomyGateError.toolDenied(reason: "append requires a named text target; nothing was run")
                }
                return MacActStep(verb: verb, target: "", text: text, mode: mode, holding: holding, button: button)
            }
            let isScroll = MacFourVerbs.isScrollVerb(verb)
            let direction = isScroll ? try scrollDirection(step["direction"]) : nil
            let amount = isScroll ? try scrollAmount(step["scroll_amount"]) : nil
            if step["target"] == nil, isScroll {
                return MacActStep(verb: verb, target: "", holding: holding, button: button, direction: direction, scrollAmount: amount)
            }
            guard case .string(let target)? = step["target"]
                    ?? (["key", "press"].contains(verb) ? step["text"] : nil),
                  !target.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            var to: String?
            if case .string(let destination)? = step["to"] { to = destination }
            return MacActStep(verb: verb, target: target, text: text, mode: mode, to: to, holding: holding, button: button,
                direction: direction, scrollAmount: amount)
        default: break
        }
        throw AutonomyGateError.toolDenied(
            reason: "each step is a name (\"9\"), {verb, target, text?}, or {verb, at:{x,y}} / {verb:\"drag\", from:{x,y}, to:{x,y}}; nothing was run"
        )
    }

    /// The verb's reply as the tool's result: an act claims the window it acted in and a look refreshes a window already held, effects follow
    /// from what was let out, and a failure carries the repair it owes.
    private func fourVerbResult(reply: MacFourVerbsReply, sighted: MacSightRecorder, host: MacMotorCount, access: FullMacToolAccess, tool: String,
        input: [String: JSONValue]) -> JSONValue {
        func str(_ key: String) -> String? { input[key]?.trimmedString }
        // Acting claims a window; looking only refreshes a window the agent already holds.
        do {
            if let seen = sighted.last {
                let lookedInOwnedWindow: Bool
                if tool == "screen", str("app") != nil {
                    lookedInOwnedWindow = try AgentScreen.touched(dataRoot: dataRoot, now: Date()).contains { $0.app == AgentScreen.clip(seen.app, 40) }
                } else { lookedInOwnedWindow = false }
                if tool == "act" || lookedInOwnedWindow {
                    try AgentScreen.touch(dataRoot: dataRoot, app: seen.app, kind: seen.kind, readouts: seen.readouts, before: seen.before)
                }
            }
        } catch {
            let owner = dataRoot.appendingPathComponent("her_screen/touched.json")
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: "mac.recorded_windows", owner: owner.path,
                words: """
                    The Mac operation returned, but its recorded-window update failed: \(error.localizedDescription). Do not repeat the \
                    operation to repair bookkeeping.
                    """,
                tap: ToolFailureError.fileRepairInstruction(owner, shape: "Preserve the Touched array and restore read/write access."))
        }
        var payload: [String: JSONValue] = [
            "ok": .bool(reply.ok),
            "text": .string(reply.text),
        ]
        // A verb that failed having let nothing out changed nothing.
        // A dispatched act that reports it changed nothing keeps its own word.
        if !reply.ok { payload["effects"] = .string(host.started == 0 || reply.detail["effects"] == .string("none") ? "none" : "unknown") }
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

    /// Raw MacControl calls share accessibility admission; only injected actions carry body-bound, single-use capabilities. Clipboard reads stay redacted.
    @concurrent func impl_mac_control_tool(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        let access = try await fullMacToolAccess(turn: turn, surface: surface)
        guard access.accessibilityAllowed else {
            if let need = macControlCategoryNeedEnvelope(invocation: invocation,
                categories: ["accessibility"], mode: Self.screenControlReadToolNames.contains(tool) ? .read : .write,
                why: "Screen control lets me read and control apps on your Mac."
            ) { return need }
            throw AutonomyGateError.toolDenied(
                reason: "Trust Full Mac Accessibility category is not active for \(tool)"
            )
        }
        let action = tool.hasPrefix("mac_") ? String(tool.dropFirst(4)) : tool
        let context = invocation.macContext(dataRoot: dataRoot)
        let impl = makeMacControl(policyProvider: TrustCenterMacControlPolicyProvider(admittedPolicy: access.macPolicy, dataRoot: dataRoot),
            auditDataRoot: dataRoot
        )
        if Self.fullMacAccessibilityInjectionToolNames.contains(tool) || Self.macMenuPressToolNames.contains(tool) {
            guard let capability = turn.injectionCapability
                ?? MacInjectionCapability.mint(
                    approvalID: "yolo-\(UUID().uuidString)",
                    action: action,
                    body: input
                ) else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_approval_missing: \(tool) could not mint a capability"
                )
            }
            let result = try await impl.dispatchApprovedInjection(
                action: action,
                body: input,
                capability: capability, turn: turn, context: context
            )
            guard Self.macMenuPressToolNames.contains(tool) else { return result.toJSON(readContent: invocation.readContent) }
            // A direct press answers as an act's menu path does, through the same words and screen after, beside its own receipt.
            let path: String = if case .array(let levels)? = input["path"] {
                levels.compactMap(\.stringValue).joined(separator: " › ")
            } else { input["path"]?.stringValue ?? "" }
            // The screen after is the window of the app the receipt says was pressed, front or behind.
            let pressedApp = result.output.objectValue?["app"]?.objectValue
            let verbs = MacFourVerbs(host: impl, supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(
                invocation: invocation, host: impl, liveScene: fourVerbLiveScene))
            let said = await verbs.pressedMenu(result, path: path, app: pressedApp?["bundle_id"]?.stringValue ?? pressedApp?["name"]?.stringValue,
                screen: "", turn: turn, context: context)
            return result.toJSON(readContent: invocation.readContent, text: said.text, screenAfter: said.detail["screen_after"])
        }
        var body = input
        if tool == "menu" { body["words"] = input["find"] }
        return try await impl.dispatch(action: action, body: body, turn: turn, context: context).toJSON(readContent: invocation.readContent)
    }

    /// Reads require Full Mac Accessibility authority; explicit paths also require file authority. Without a path, MacControl reads live window text and
    /// restores any viewport it moves. Explicit file reads retain workspace policy and sensitive-path fences.
    @concurrent func impl_mac_read_tool(turn: Turn, invocation: ChatToolInvocation,
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
        let access = try await fullMacToolAccess(turn: turn, surface: surface)
        guard access.accessibilityAllowed, namedPath == nil || access.fileOpsAllowed else {
            if let need = macControlCategoryNeedEnvelope(invocation: invocation,
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
        let context = invocation.macContext(dataRoot: dataRoot)
        let impl = makeMacControl(policyProvider: TrustCenterMacControlPolicyProvider(admittedPolicy: access.macPolicy, dataRoot: dataRoot),
            auditDataRoot: dataRoot
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
                scope: turn.verifiedSessionID ?? "",
                nativeCorner: .stream(id: "mac.read"),
                nativeReadSupported: nativeReadSupported,
                fileAlreadyReadable: namedPath.map { FileReadSourceMaterial.nativeReadSupported(path: $0) } ?? false,
                operation: invocation.senseOperation(turn: turn),
                raw: { operation in
                    let invocation = invocation.serving(sense: operation)
                    return try await impl.dispatch(action: "read", body: input, turn: turn,
                        context: invocation.macContext(dataRoot: self.dataRoot)).toJSON(readContent: invocation.readContent)
                },
                material: { raw, operation in
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
                        let tree = try await self.impl_mac_four_verbs_tool(turn: turn, invocation: invocation.serving(sense: operation), tool: "screen",
                            input: ["app": .string(bundle), "raw": .bool(true), "__sense_app_material": .bool(true)], surface: surface)
                        return .accessibility(tree)
                    }
                    return try Self.senseTextMaterial(raw)
                })
    }

}
