import Foundation
import NativeAgentCore
import PersistenceCore
import AppKit
import Experiences
import CryptoKit
import NativeAgentShared
import ApplicationServices
import TrustCenter
import CoreGraphics
import UserNotifications
import Senses
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacSemanticExecution.swift` | Shared semantic/physical execution; uncertain delivered text remains unverified with a pixel-look remedy |
extension MacFourVerbs {
    static func frontChangedWords(_ reply: MacFourVerbsReply, verbName: String) -> MacFourVerbsReply {
        guard string(reply.detail["error"]) == "front_changed" else { return reply }
        return MacFourVerbsReply(
            ok: false,
            text: "Another app came to the front before I could \(verbName) (owner_changed_apps), so I sent nothing more.\n" + reply.text,
            detail: reply.detail.merging(["error": .string("owner_changed_apps")]) { _, new in new }
        )
    }
    static let keystrokeEditableKinds: Set<String> = ["text", "text area", "combo", "searchfield", "search field"]

    static func searchLike(_ candidate: ActTarget) -> Bool {
        [candidate.kind, candidate.label ?? "", candidate.placeholder ?? ""].contains { words in
            normalize(words).split(separator: " ").contains { $0.hasPrefix("search") }
        }
    }
    static func pressesReturn(_ step: MacActStep) -> Bool {
        let verb = parseVerb(step.verb).0
        guard verb == "key" || (verb == "press" && pressMeansKey(step.target)) else { return false }
        return ["return", "enter"].contains(normalize(keySpec(step.target) ?? step.target))
    }

    /// Keyboard focus must belong to the exact named element or its subtree.
    static func holdsFocus(_ target: String, in seen: Sighting, exact: Bool) -> Bool {
        guard let focus = seen.focusPath, case .hit(let hit) = resolve(target, among: seen.targets),
              let path = hit.sourceAXPath else { return false }
        return exact ? focus == path : focus.starts(with: path)
    }
    static func personActiveRefusal() -> MacFourVerbsReply? {
        guard let ago = MacPersonInput.activeSecondsAgo() else { return nil }
        return MacFourVerbsReply(
            ok: false,
            text: """
                The person is using the Mac (input \(Int(ago.rounded()))s ago), so nothing was typed. Let them finish and hand back control before \
                continuing.
                """,
            detail: ["error": .string("person_active"), "person_active": .bool(true), "effects": .string("unknown"),
                "remedy": Repair.why(owner: "Mac foreground control", tap: "NativeAgent Mac chat > composer controls > Let [agent name] use the Mac",
                    instruction: """
                        Let the person finish. Under Full Mac, the next action reacquires control; otherwise ask them to use Let [agent name] use \
                        the Mac.
                        """)]
        )
    }
    /// Use real keys at observed focus when AX exposes no value setter.
    internal func typeKeystrokes(
        _ text: String, into place: String, before: Sighting?, frontPid: Int32? = nil,
        expect: FrontExpectation?, attention: BurstAttention?,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        if let busy = Self.personActiveRefusal() { return busy }
        // Every key goes only while the app this read saw in front still is.
        guard let pid = expect?.pid ?? before.flatMap({ $0.isFront ? $0.pid : nil }) ?? frontPid else {
            return MacFourVerbsReply(
                ok: false, text: "The front app could not be identified, so nothing was typed. Inspect the intended app before continuing.",
                detail: ["error": .string("front_unknown"), "verb": .string("type"), "effects": .string("unknown"),
                    "remedy": Self.inspectAppRemedy(before?.appName,
                        instruction: "Inspect the intended app and confirm keyboard focus before typing.")]
            )
        }
        let reply = await context.holding(\.requiredFrontPid, pid) {
            context in await performHand(
                body: ["gesture": .string("type"), "text": .string(text)],
                description: "Typed into \(place) with the keyboard.",
                attention: attention,
                before: before
            , turn: turn, context: context)
        }
        var detail = reply.detail
        detail["verb"] = .string("type")
        detail["physical_route"] = .string("keystrokes")
        return Self.frontChangedWords(MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail), verbName: "type")
    }
    func performSupplementalSemantic(
        _ verb: MacActVerb,
        direction: ScrollDirection,
        scrollAmount: Int = 0,
        candidate: ActTarget,
        target: String,
        text: String?,
        holding: String?,
        button: String? = nil,
        attention: BurstAttention?,
        before: Sighting,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        let spokenTarget = Self.spokenName(candidate, requestedAs: target)
        // Judge named left clicks by their observed consequence.
        let pressed = verb == .click && button != "right" && !candidate.isSupplemental && !candidate.physicalOnly
            ? candidate : nil
        if let viewId = candidate.viewId, let mark = candidate.mark,
           verb != .open, verb != .scroll, holding == nil, button == nil {
            var body: [String: JSONValue] = [
                "view": .string(viewId),
                "mark": .int(Int64(mark)),
            ]
            if verb == .type {
                guard let text, !text.isEmpty else {
                    return MacFourVerbsReply(ok: false, text: "Nothing to type into \(spokenTarget).")
                }
                body["value"] = .string(text)
            } else {
                body["action"] = .string("AXPress")
            }
            let first = await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + spokenTarget + ".",
                before: before,
                target: target,
                verb: verb.rawValue,
                attention: attention
            , turn: turn, context: context)
            // On mark drift, refresh once and resolve the same name before one dispatch.
            guard !first.ok, Self.string(first.detail["error"])?.hasPrefix("mark_drifted") == true,
                  case .seen(let fresh) = await sight(part: nil, turn: turn, context: context),
                  case .hit(let again) = Self.resolve(target, among: fresh.targets),
                  Self.answers(target, again, exact: Self.committingVerbs.contains(verb)),
                  let freshView = again.viewId, let freshMark = again.mark else { return first }
            body["view"] = .string(freshView)
            body["mark"] = .int(Int64(freshMark))
            return await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + Self.spokenName(again, requestedAs: target) + ".",
                before: fresh,
                target: target,
                verb: verb.rawValue,
                attention: attention
            , turn: turn, context: context)
        }
        var body: [String: JSONValue] = [:]
        var aim: MacPointerPosition?
        let usesPageKey = verb == .scroll && candidate.kind == "web area"
            && !direction.isHorizontal && scrollAmount == 0
        if !usesPageKey {
            guard let candidateFrame = Self.visiblePortion(of: candidate.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can see \(spokenTarget), but I do not have a safe point for it.",
                    detail: ["error": .string("target_has_no_physical_point")]
                )
            }
            guard let point = Self.safeAimPoint(for: candidate, in: candidateFrame,
                describedBy: target) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            body["x"] = .double(point.x)
            body["y"] = .double(point.y)
            aim = point
        }
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        switch verb {
        case .doubleClick: body["gesture"] = .string("double_click")
        case .rightClick:
            body["gesture"] = .string("click")
            body["button"] = .string("right")
        case .hover: body["gesture"] = .string("hover")
        case .focus:
            return MacFourVerbsReply(ok: false, text: "This thing has no accessibility focus target; no input was sent.",
                detail: ["error": .string("focus_requires_accessibility")])
        case .click, .select, .toggle, .dismiss:
            body["gesture"] = .string("click")
        case .open:
            body["gesture"] = .string("double_click")
        case .type:
            guard let text, !text.isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Nothing to type into \(spokenTarget).")
            }
            body["gesture"] = .string("click_type")
            body["text"] = .string(text)
        case .scroll:
            if usesPageKey {
                // Web-area wheel input may be accepted without moving content; Page keys use the physical route that moves the observed document.
                body["gesture"] = .string("key")
                body["keys"] = .string(direction == .up ? "pageup" : "pagedown")
            } else {
                body["gesture"] = .string("scroll")
                let magnitude = Int64(scrollAmount == 0 ? 6 : scrollAmount)
                body["dx"] = .int(direction == .left ? magnitude : direction == .right ? -magnitude : 0)
                body["dy"] = .int(direction == .up ? magnitude : direction == .down ? -magnitude : 0)
            }
        }
        // Native-surface input stays bound to the exact observed pid across awaits and every posted event.
        if context.nativeSurfaceApp != nil, before.pid == nil {
            return MacFourVerbsReply(ok: false,
                text: "The selected native surface changed before I could act. I haven't touched it; read the screen again.\n" + before.render,
                detail: ["error": .string("native_surface_changed")])
        }
        let frontPid = context.nativeSurfaceApp != nil ? before.pid : context.requiredFrontPid
        let reply = await context.holding(\.looking, verb == .scroll) { context in await context.holding(\.requiredFrontPid, frontPid) { context in
            // Named pointer presses retain safe aim, obstruction checks and observed-pid admission.
            if let pressed, let aim {
                return await performPointer(
                    "click", at: aim, to: nil, saying: spokenTarget, destination: nil, before: before,
                    excluding: candidate.excludedFrames, seconds: nil, holding: holding, button: button,
                    attention: attention, pressed: pressed
                , turn: turn, context: context)
            }
            return await performHand(
                body: body,
                description: (button == "right" ? (verb == .open ? "Double-right-clicked" : "Right-clicked")
                    : Self.pastTense(verb, direction: direction)) + " " + spokenTarget + ".",
                unverifiedDescription: verb == .scroll
                    ? "Tried to scroll \(direction.rawValue) in \(spokenTarget)."
                    : nil,
                attention: attention,
                before: before,
                afterPart: candidate.physicalOnly ? "visual surface" : nil
            , turn: turn, context: context)
        }
        }
        var detail = reply.detail
        detail["verb"] = .string(verb.rawValue)
        if let button { detail["button"] = .string(button) }
        detail["target"] = .string(target)
        detail["matched"] = .string(Self.name(candidate))
        let physicalRoute: String
        switch verb {
        case .doubleClick: physicalRoute = "double_click"
        case .rightClick: physicalRoute = "right_click"
        case .hover: physicalRoute = "hover"
        case .focus: physicalRoute = "none"
        case .click, .select, .toggle, .dismiss: physicalRoute = "click"
        case .open: physicalRoute = "double_click"
        case .type: physicalRoute = "click_type"
        case .scroll: physicalRoute = usesPageKey ? "page_key" : "wheel"
        }
        detail["physical_route"] = .string(physicalRoute)
        // A hand refused because the person took the front: their choice stands.
        return Self.frontChangedWords(MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail), verbName: verb.rawValue)
    }
    /// An acted verdict needs emitted-input evidence; pre-emission refusals remain refusals.
    static func inputLeftTheHand(_ reply: MacFourVerbsReply) -> Bool {
        reply.ok || (Self.int(reply.detail["requested_events_emitted"]) ?? 0) > 0
            || reply.detail["effects_may_have_occurred"] == .bool(true)
    }
    private func performObservedDispatch(
        action: String,
        body: [String: JSONValue],
        description: String,
        before: Sighting,
        target: String,
        verb: String,
        attention: BurstAttention?,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        do { result = try await host.dispatch(action: action, body: request, turn: turn, context: context) }
        catch {
            return Self.unknownActionReply(error, operation: "\(verb) \(target)", app: before.appName)
        }
        guard result.ok else {
            return MacFourVerbsReply(
                ok: false,
                text: """
                    No verified result for \(verb) \"\(target)\". \
                    \(Self.string(Self.object(result.output)["detail"]) ?? result.error ?? "The Mac refused the action.")\n
                    """ + before.render,
                detail: Self.operationDetail(result, app: before.appName).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        return await observedReply(result: result, description: description, before: before, turn: turn, context: context)
    }

    func performHand(
        body: [String: JSONValue],
        description: String,
        unverifiedDescription: String? = nil,
        attention: BurstAttention? = nil,
        before: Sighting?,
        afterPart: String? = nil,
        pointerTarget: String? = nil,
        pressed: ActTarget? = nil,
        confirm: Bool = true,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        // Named acts retain the slot through observation/settlement; watch hands share its owner and held-input rule.
        if !context.holdsActSerial {
            guard await MacActSerial.shared.acquire(context: context) else {
                return .init(ok: false, text: "The action was cancelled before it started.", detail: ["error": .string("cancelled")])
            }
            await MacActSerial.shared.ownInputs(context.driver)
            let reply = await context.holding(\.holdsActSerial, true) {
                context in await performHand(body: body, description: description, unverifiedDescription: unverifiedDescription,
                    attention: attention, before: before, afterPart: afterPart, pointerTarget: pointerTarget,
                    pressed: pressed, confirm: confirm, turn: turn, context: context)
            }
            return await settle {
                await MacActSerial.shared.release()
                return reply
            }
        }
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        guard let pid = context.requiredFrontPid ?? (before?.isFront == true ? before?.pid : nil) else {
            return .init(ok: false, text: "I can't bind this input to the observed foreground app. Nothing was sent; read the screen again.",
                         detail: ["error": .string("front_unknown"), "effects": .string("none")])
        }
        request["require_front_pid"] = .int(Int64(pid))
        if let number = context.requiredFrontWindow { request["require_front_window"] = .int(Int64(number)) }
        // Physical acts already own fresh pre-observation and mandatory post-observation; another capture would age the motion-compensated aim.
        // Read-only confirmation for watch hands comes from their stream.
        if !confirm || before != nil && afterPart == "visual surface" {
            request["defer_visual_verification"] = .bool(true)
        }
        do { result = try await host.dispatch(action: "hand", body: request, turn: turn, context: context) }
        catch {
            return Self.unknownActionReply(error, operation: "the requested input", app: before?.appName)
        }
        guard result.ok else {
            if context.nativeSurfaceApp != nil, result.error == "front_changed" {
                let output = Self.object(result.output)
                var detail = Self.operationDetail(result)
                if Self.int(output["requested_events_emitted"]) == 0 {
                    detail["error"] = .string("native_surface_changed")
                    return MacFourVerbsReply(ok: false,
                        text: "The selected native surface changed before I could act. I haven't touched it; read the screen again."
                            + (before.map { "\n" + $0.render } ?? ""), detail: detail)
                }
                detail["error"] = .string("front_changed")
                return Self.frontChangedWords(MacFourVerbsReply(ok: false,
                    text: before?.render ?? "", detail: detail), verbName: "act")
            }
            return MacFourVerbsReply(
                ok: false,
                text: """
                    No verified result. \
                    \(Self.string(Self.object(result.output)["guidance"]) ?? Self.string(Self.object(result.output)["note"]) ?? Self.string(Self.object(result.output)["detail"]) ?? result.error ?? "The Mac refused the action.")
                    """
                    + (before.map { "\n" + $0.render } ?? ""),
                detail: Self.operationDetail(result, app: before?.appName).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        func offerTextLook(_ reply: MacFourVerbsReply) -> MacFourVerbsReply {
            guard body["text"] != nil, Self.object(result.output)["status"] == .string("acted_unobserved") else { return reply }
            var args: [String: JSONValue] = ["pixels": .bool(true)]
            if let app = before?.bundleIdentifier ?? before?.appName { args["app"] = .string(app) }
            var detail = reply.detail
            detail["next_call"] = .object(["tool": .string("app"), "input": .object([
                "action": .string("mac.look"), "args": .object(args)])])
            return MacFourVerbsReply(ok: reply.ok,
                text: reply.text + "\nText delivery is unverified; use next_call for a pixel look before typing again.", detail: detail)
        }
        guard confirm else {
            return offerTextLook(MacFourVerbsReply(ok: Self.object(result.output)["status"] != .string("acted_mismatch"),
                text: description, detail: Self.operationDetail(result)))
        }
        return offerTextLook(await observedReply(
            result: result,
            description: description,
            unverifiedDescription: unverifiedDescription,
            before: before,
            afterPart: afterPart,
            pointerTarget: pointerTarget,
            pressed: pressed
        , turn: turn, context: context))
    }
    /// Refusals list the executing hand’s own verbs.
    static func unknownVerb(_ rawVerb: String, target: String) -> MacFourVerbsReply? {
        var name = parseVerb(rawVerb).0
        if name == "press" { name = pressMeansKey(target) ? "key" : "click" }
        guard MacActVerb(rawValue: name) == nil, PhysicalVerb(rawValue: name) == nil else { return nil }
        let verbs = Self.actionVerbs
        return MacFourVerbsReply(
            ok: false,
            text: "No \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" verb. Use: "
                + verbs.joined(separator: ", ") + ". Nothing moved.",
            detail: ["error": .string("unknown_verb"), "verb": .string(rawVerb), "owner_front_changed": .bool(false)]
        )
    }
    static func keySpec(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["key ", "key:", "chord ", "chord:"] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
