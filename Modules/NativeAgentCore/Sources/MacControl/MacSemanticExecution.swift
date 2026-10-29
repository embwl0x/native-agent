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
// Blueprint: | `MacSemanticExecution.swift` | MacFourVerbs supplemental semantic/native-hand execution and input grammar under the same driver and act lifetime |
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

    /// A search field by its kind, name or placeholder ("Search Maps").
    static func searchLike(_ candidate: ActTarget) -> Bool {
        [candidate.kind, candidate.label ?? "", candidate.placeholder ?? ""].contains { words in
            normalize(words).split(separator: " ").contains { $0.hasPrefix("search") }
        }
    }
    /// A step that presses return or enter.
    static func pressesReturn(_ step: MacActStep) -> Bool {
        let verb = parseVerb(step.verb).0
        guard verb == "key" || (verb == "press" && pressMeansKey(step.target)) else { return false }
        return ["return", "enter"].contains(normalize(keySpec(step.target) ?? step.target))
    }
    /// Only the caller's explicit front:true permits a cross-app drag to raise.
    @TaskLocal static var foregroundRequested = false

    /// In a batch, what the step before a key step typed: a change that is
    /// only that text is not the key's effect.
    @TaskLocal static var typedJustBefore: String?

    /// The named element (exact) or something inside it holds keyboard focus in this read.
    static func holdsFocus(_ target: String, in seen: Sighting, exact: Bool) -> Bool {
        guard let focus = seen.focusPath, case .hit(let hit) = resolve(target, among: seen.targets),
              let path = hit.sourceAXPath else { return false }
        return exact ? focus == path : focus.starts(with: path)
    }
    static func personActiveRefusal() -> MacFourVerbsReply? {
        guard let ago = MacPersonInput.activeSecondsAgo() else { return nil }
        return MacFourVerbsReply(
            ok: false,
            text: "The person is using the Mac (input \(Int(ago.rounded()))s ago), so nothing was typed. Let them finish and hand back control before continuing.",
            detail: ["error": .string("person_active"), "person_active": .bool(true), "effects": .string("unknown"),
                "remedy": Repair.why(owner: "Mac foreground control", tap: "NativeAgent Mac chat > composer controls > Let [agent name] use the Mac",
                    instruction: "Let the person finish. Under Full Mac, the next action reacquires control; otherwise ask them to use Let [agent name] use the Mac.")]
        )
    }
    /// Real keystrokes to whatever has focus in the app in front — how a
    /// person types where accessibility has no value to set.
    internal func typeKeystrokes(
        _ text: String, into place: String, before: Sighting?, frontPid: Int32? = nil,
        expect: FrontExpectation?, attention: BurstAttention?
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
        let reply = await Self.$requiredFrontPid.withValue(pid) {
            await performHand(
                body: ["gesture": .string("type"), "text": .string(text)],
                description: "Typed into \(place) with the keyboard.",
                attention: attention,
                before: before
            )
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
        before: Sighting
    ) async -> MacFourVerbsReply {
        let spokenTarget = Self.spokenName(candidate, requestedAs: target)
        // A left click on a control the look named is judged by its consequence.
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
            )
            // On mark drift, refresh once and resolve the same name before one dispatch.
            guard !first.ok, Self.string(first.detail["error"])?.hasPrefix("mark_drifted") == true,
                  case .seen(let fresh) = await sight(part: nil),
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
            )
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
                // Live Chrome proof: synthesized wheel events were accepted
                // but inert on the AX web area, while the ordinary Page key
                // moved the same visible document and produced fresh proof.
                // Keep that physical distinction below the natural scroll
                // verb; the caller still names the region and direction.
                body["gesture"] = .string("key")
                body["keys"] = .string(direction == .up ? "pageup" : "pagedown")
            } else {
                body["gesture"] = .string("scroll")
                let magnitude = Int64(scrollAmount == 0 ? 6 : scrollAmount)
                body["dx"] = .int(direction == .left ? magnitude : direction == .right ? -magnitude : 0)
                body["dy"] = .int(direction == .up ? magnitude : direction == .down ? -magnitude : 0)
            }
        }
        // The native-surface exception permits real input only for this exact
        // observed app. Carry its PID through the hand's per-event front guard,
        // including any await between this capture and dispatch.
        if Self.nativeSurfaceApp != nil, before.pid == nil {
            return MacFourVerbsReply(ok: false,
                text: "The selected native surface changed before I could act. I haven't touched it; read the screen again.\n" + before.render,
                detail: ["error": .string("native_surface_changed")])
        }
        let frontPid = Self.nativeSurfaceApp != nil ? before.pid : Self.requiredFrontPid
        let reply = await Self.$requiredFrontPid.withValue(frontPid) {
            // A press on a named control takes the one pointer tail: clear of
            // anything covering the window, at the safe aim, the observed pid.
            if let pressed, let aim {
                return await performPointer(
                    "click", at: aim, to: nil, saying: spokenTarget, destination: nil, before: before,
                    excluding: candidate.excludedFrames, seconds: nil, holding: holding, button: button,
                    attention: attention, pressed: pressed
                )
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
            )
        }
        var detail = reply.detail
        detail["verb"] = .string(verb.rawValue)
        if let button { detail["button"] = .string(button) }
        detail["target"] = .string(target)
        detail["matched"] = .string(Self.name(candidate))
        let physicalRoute: String
        switch verb {
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
    /// Acted (observed or not) needs evidence that input went out: a reply
    /// that succeeded, or one whose events say some were emitted. A refusal
    /// before the first event stays the refusal it is.
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
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        do { result = try await host.dispatch(action: action, body: request) }
        catch {
            return Self.unknownActionReply(error, operation: "\(verb) \(target)", app: before.appName)
        }
        guard result.ok else {
            return MacFourVerbsReply(
                ok: false,
                text: "No verified result for \(verb) \"\(target)\". \(Self.string(Self.object(result.output)["detail"]) ?? result.error ?? "The Mac refused the action.")\n" + before.render,
                detail: Self.operationDetail(result, app: before.appName).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        return await observedReply(result: result, description: description, before: before)
    }
    /// After a `front:true` raise: the pid every posted hand event requires in front.
    @TaskLocal static var requiredFrontPid: Int32?
    /// A watch's hand: the exact window that must be its app's front window at every event.
    @TaskLocal static var requiredFrontWindow: Int?
    @TaskLocal static var holdsActSerial = false
    func performHand(
        body: [String: JSONValue],
        description: String,
        unverifiedDescription: String? = nil,
        attention: BurstAttention? = nil,
        before: Sighting?,
        afterPart: String? = nil,
        pointerTarget: String? = nil,
        pressed: ActTarget? = nil,
        confirm: Bool = true
    ) async -> MacFourVerbsReply {
        // Named acts retain the slot through observation/settlement; watch hands share its owner and held-input rule.
        if !Self.holdsActSerial {
            guard await MacActSerial.shared.acquire() else {
                return .init(ok: false, text: "The action was cancelled before it started.", detail: ["error": .string("cancelled")])
            }
            await MacActSerial.shared.ownInputs(MacDriverContext.binding)
            let reply = await Self.$holdsActSerial.withValue(true) {
                await performHand(body: body, description: description, unverifiedDescription: unverifiedDescription,
                    attention: attention, before: before, afterPart: afterPart, pointerTarget: pointerTarget,
                    pressed: pressed, confirm: confirm)
            }
            return await settle {
                await MacActSerial.shared.release()
                return reply
            }
        }
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        guard let pid = Self.requiredFrontPid ?? (before?.isFront == true ? before?.pid : nil) else {
            return .init(ok: false, text: "I can't bind this input to the observed foreground app. Nothing was sent; read the screen again.",
                         detail: ["error": .string("front_unknown"), "effects": .string("none")])
        }
        request["require_front_pid"] = .int(Int64(pid))
        if let number = Self.requiredFrontWindow { request["require_front_window"] = .int(Int64(number)) }
        // This composed physical-only act already owns a fresh pre-observation
        // and the mandatory observedReply below. Recapturing inside the hand
        // delays input after its motion-compensated point was calculated. A
        // watch's hand (no confirm) is observed by its stream instead.
        if !confirm || before != nil && afterPart == "visual surface" {
            request["defer_visual_verification"] = .bool(true)
        }
        do { result = try await host.dispatch(action: "hand", body: request) }
        catch {
            return Self.unknownActionReply(error, operation: "the requested input", app: before?.appName)
        }
        guard result.ok else {
            if Self.nativeSurfaceApp != nil, result.error == "front_changed" {
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
                text: "No verified result. \(Self.string(Self.object(result.output)["guidance"]) ?? Self.string(Self.object(result.output)["note"]) ?? Self.string(Self.object(result.output)["detail"]) ?? result.error ?? "The Mac refused the action.")"
                    + (before.map { "\n" + $0.render } ?? ""),
                detail: Self.operationDetail(result, app: before?.appName).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        guard confirm else {
            return MacFourVerbsReply(ok: Self.object(result.output)["status"] != .string("acted_mismatch"),
                text: description, detail: Self.operationDetail(result))
        }
        return await observedReply(
            result: result,
            description: description,
            unverifiedDescription: unverifiedDescription,
            before: before,
            afterPart: afterPart,
            pointerTarget: pointerTarget,
            pressed: pressed
        )
    }
    /// An act verb this hand has, or the short answer listing them.
    static func unknownVerb(_ rawVerb: String, target: String) -> MacFourVerbsReply? {
        var name = parseVerb(rawVerb).0
        if name == "press" { name = pressMeansKey(target) ? "key" : "click" }
        guard MacActVerb(rawValue: name) == nil, PhysicalVerb(rawValue: name) == nil else { return nil }
        let verbs = (MacActVerb.allCases.map(\.rawValue) + PhysicalVerb.allCases.map(\.rawValue) + ["press"])
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
