import Foundation
import NativeAgentCore
import PersistenceCore
import AppKit
import Experiences
import NativeAgentShared
import ApplicationServices
import TrustCenter
import CoreGraphics
import UserNotifications
import Senses
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacSemanticAct+Hit.swift` | `MacFourVerbs`: `actOnHit`, `hitRefusal`, `hitRoute`, `dispatchHit`, `hitFailed`, `hitLanded` (one resolved candidate: admission, pointer/wheel/supplemental/popup routes, the closed-loop dispatch with one same-window second look, and the receipt naming what was actually acted on) |
extension MacFourVerbs {
    /// One resolved candidate: admit it, take a route that is not one native act, or act through the closed loop and report what landed.
    func actOnHit(_ once: ActOnce, sighting: Sighting, candidate: ActTarget, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        if let reply = await hitRefusal(once, sighting: sighting, candidate: candidate, turn: turn, context: context) { return reply }
        if let reply = await hitRoute(once, sighting: sighting, candidate: candidate, turn: turn, context: context) { return reply }
        let dispatched: (result: MacControlResult, postRead: MacSightCaptureBinding, output: [String: JSONValue])
        switch await dispatchHit(once, sighting: sighting, candidate: candidate, turn: turn, context: context) {
        case .reply(let reply): return reply
        case .ready(let ready): dispatched = ready
        }
        guard dispatched.result.ok else {
            return await hitFailed(once, sighting: sighting, candidate: candidate, result: dispatched.result, postRead: dispatched.postRead,
                output: dispatched.output, turn: turn, context: context)
        }
        return await hitLanded(once, sighting: sighting, candidate: candidate, result: dispatched.result, postRead: dispatched.postRead,
            output: dispatched.output, turn: turn, context: context)
    }

    /// The candidate must match the subject first sighted, answer the name (exactly for a commit), and suit the verb.
    /// Only scroll can use a candidate without positive enabled-state evidence.
    func hitRefusal(_ once: ActOnce, sighting: Sighting, candidate: ActTarget, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply? {
        // A second look acts only on the subject first resolved; a different one under the same name is refused untouched.
        if let first = once.firstSighted, candidate.label != first.label || candidate.kind != first.kind {
            return MacFourVerbsReply(ok: false,
                text: "The screen changed before I could act, and \"\(once.target)\" no longer names the \(first.kind) \"\(first.label)\" "
                    + "I first found. I haven't touched anything.\n" + sighting.render,
                detail: ["error": .string("subject_changed"), "target": .string(once.target), "effects": .string("none")])
        }
        // The resolved target must answer to the name before the act is admitted.
        if !candidate.regionOnly, !once.bareFieldHit, !(once.verb == .scroll && once.target.isEmpty), !Self.answers(once.target, candidate) {
            let hint = once.menus ? await menuHint(once.target, verb: once.verb, app: once.app ?? sighting.appName, turn: turn, context: context) : MenuHint()
            return MacFourVerbsReply(
                ok: false,
                text: "Nothing here answers to \"\(once.target)\" exactly — the closest is \(Self.name(candidate)), "
                    + "which isn't it. I haven't touched anything." + hint.text + "\n" + sighting.render,
                detail: hint.detail.merging(["error": .string("no_match"), "target": .string(once.target),
                         "nearest": .array([.string(Self.recoveryName(candidate))])]) { _, new in new }
            )
        }
        // Containment cannot authorize a commit: Delete must not press Delete All.
        if Self.committingVerbs.contains(once.verb), !candidate.regionOnly, !once.bareFieldHit,
           !Self.answers(once.target, candidate, exact: true) {
            let containing = sighting.targets.filter { $0 == candidate || Self.containsName(Self.askedName(once.target), $0) }
            return MacFourVerbsReply(
                ok: false,
                text: "Nothing here is named exactly \"\(once.target)\"; it is only part of "
                    + containing.map { Self.recoveryName($0) + " (\($0.kind))" }.joined(separator: ", ")
                    + ". Name the one you mean exactly. I haven't touched anything.\n" + sighting.render,
                detail: ["error": .string("inexact_name"), "target": .string(once.target),
                         "candidates": .array(containing.map(Self.candidateDetail))]
            )
        }
        if context.nativeSurfaceApp != nil, let label = context.nativeSurfaceLabel, candidate.label != label {
            return MacFourVerbsReply(ok: false,
                text: "The selected native surface changed before I could act. I haven't touched it; read the screen again.\n" + sighting.render,
                detail: ["error": .string("native_surface_changed")])
        }
        if once.verb != .scroll, candidate.enabled == nil {
            return MacFourVerbsReply(ok: false,
                text: "\(Self.name(candidate)) has no readable enabled state. Read the app again before acting.\n" + sighting.render,
                detail: ["error": .string("enabled_state_unavailable"), "target": .string(once.target), "effects": .string("none"),
                    "remedy": Self.inspectAppRemedy(once.app ?? sighting.appName, instruction: "Read this control's Accessibility state before acting.")])
        }
        if once.verb != .scroll, candidate.enabled == false {
            return MacFourVerbsReply(
                ok: false, text: "\(Self.name(candidate)) is disabled. Nothing was touched. Inspect this app for the prerequisite that enables it.\n"
                    + sighting.render,
                detail: ["error": .string("target_disabled"), "target": .string(once.target), "effects": .string("none"),
                    "remedy": Self.inspectAppRemedy(once.app ?? sighting.appName,
                        instruction: "Inspect this app for the prerequisite that enables the control; do not press it while disabled.")]
            )
        }
        if candidate.regionOnly, once.verb != .scroll {
            return MacFourVerbsReply(
                ok: false,
                text: """
                    \(Self.name(candidate)) is a region, not a control. I can scroll it; name a visible thing inside it to click, open, type, select, \
                    toggle, or dismiss.
                    """,
                detail: ["error": .string("region_needs_inner_target")]
            )
        }
        if candidate.physicalOnly,
           ![MacActVerb.click, .open, .scroll].contains(once.verb) {
            return MacFourVerbsReply(
                ok: false,
                text: """
                    \(Self.name(candidate)) is an unlabeled visual region, so I can physically click, open, scroll, move, hover, hold, or drag there \
                    without pretending I know its semantic role.
                    """,
                detail: ["error": .string("visual_region_needs_physical_action")]
            )
        }
        if once.mode == .append, candidate.isSupplemental {
            return MacFourVerbsReply(ok: false,
                text: "Append requires an accessibility text target whose contents and end position can be verified; nothing was typed.",
                detail: ["error": .string("append_target_unverifiable")])
        }
        return nil
    }

    /// Routes that are not one native act: wheel scroll, a held key or explicit button through the pointer (learning the pointer route),
    /// a pixel-found control, a popup selection.
    func hitRoute(_ once: ActOnce, sighting: Sighting, candidate: ActTarget, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply? {
        // Wheel input needs the named region’s aim; containers and explicit amounts retain the physical route.
        let physicalScroll = once.verb == .scroll
            && (once.target.isEmpty || once.amount > 0 || once.direction.isHorizontal || Self.physicalScrollKinds.contains(candidate.kind))
            && (once.amount > 0 || once.direction.isHorizontal || candidate.kind == "web area" || candidate.frame != nil)
        // Only AX actions can run in the background; pixel targets and wheel input require explicit front permission.
        if once.app != nil, physicalScroll || candidate.isSupplemental,
           !(context.nativeSurfaceApp == once.app && sighting.isFront) {
            return Self.needsFront(
                physicalScroll
                    ? "scrolling it needs the wheel over the window"
                    : "\(Self.name(candidate)) was found in pixels, not accessibility, so it needs a real click",
                app: once.app, screen: sighting.render
            )
        }
        if physicalScroll {
            return await performSupplementalSemantic(
                once.verb,
                direction: once.direction,
                scrollAmount: once.amount,
                candidate: candidate,
                target: once.target,
                text: once.text,
                holding: once.holding,
                attention: once.attention,
                before: sighting
            , turn: turn, context: context)
        }
        // A remembered pointer route is only a hypothesis; background presses must still try the app’s AX handler.
        var learnedPointer = false
        let pointerHypothesis: Bool
        do {
            pointerHypothesis = once.verb == .click && once.holding == nil && once.button == nil
                && !candidate.isSupplemental && candidate.frame != nil
                ? try await pressesByPointer(candidate, in: sighting) : false
        } catch { return Self.appMapFailure(error) }
        if once.verb == .click, once.holding == nil, once.button == nil, !candidate.isSupplemental, candidate.frame != nil,
           pointerHypothesis, once.app == nil {
            learnedPointer = true
        }
        let pressButton = learnedPointer ? "left" : once.button
        if once.holding != nil || pressButton != nil {
            guard once.verb != .type else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can't hold keys while typing text; use a key or chord action instead.",
                    detail: ["error": .string("holding_not_supported_for_type")]
                )
            }
            // Every pointer event reaches only the app it was aimed at.
            let reply = await context.holding(\.requiredFrontPid, context.requiredFrontPid ?? sighting.pid) {
                context in await performSupplementalSemantic(
                    once.verb,
                    direction: once.direction,
                    scrollAmount: once.amount,
                    candidate: candidate,
                    target: once.target,
                    text: once.text,
                    holding: once.holding,
                    button: pressButton,
                    attention: once.attention,
                    before: sighting
                , turn: turn, context: context)
            }
            guard once.verb == .click, once.holding == nil, pressButton == "left" else { return reply }
            do { try await learnRoute(pointer: true, pressed: candidate, reply: reply, in: sighting) }
            catch { return Self.appMapFailure(error, after: reply) }
            guard learnedPointer else { return reply }
            return MacFourVerbsReply(
                ok: reply.ok,
                text: "(Trying the pointer from this control's last verified outcome.) " + reply.text,
                detail: reply.detail.merging(["route": .string("pointer")]) { _, new in new }
            )
        }
        if candidate.isSupplemental {
            let reply = await performSupplementalSemantic(
                once.verb,
                direction: once.direction,
                scrollAmount: once.amount,
                candidate: candidate,
                target: once.target,
                text: once.text,
                holding: once.holding,
                attention: once.attention,
                before: sighting
            , turn: turn, context: context)
            guard once.reobservedAfterTransientMiss else { return reply }
            var detail = reply.detail
            detail["dynamic_reobserved"] = .bool(true)
            return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
        }
        // Popup selection needs a verified value change; pressing alone merely opens its menu.
        if once.verb == .select, once.app == nil, candidate.kind == "popup" {
            return await selectInPopup(candidate, option: once.text ?? once.target, before: sighting, attention: once.attention, turn: turn, context: context)
        }
        return nil
    }

    /// Hand the candidate to the closed loop by its fresh handle; when the screen changed before anything was attempted, look again once
    /// for the same subject inside the same window.
    func dispatchHit(_ once: ActOnce, sighting: Sighting, candidate: ActTarget, turn: Turn, context: MacOperationContext) async
        -> ActOnceStep<(result: MacControlResult, postRead: MacSightCaptureBinding, output: [String: JSONValue])> {
        // Use the fresh look’s internal frame and handle through the existing closed loop so admission and effect verification stay shared.
        var body: [String: JSONValue] = [
            "verb": .string(once.verb.rawValue),
            "handle": .string(candidate.handle),
            "frame_id": .string(sighting.frameId),
        ]
        if let text = once.text { body["text"] = .string(text) }
        if once.verb == .type { body["mode"] = .string(once.mode.rawValue) }
        if once.verb == .scroll { body["direction"] = .string(once.direction.rawValue) }
        // Search and submit fields need real typing; setting an AX value alone may leave their action unfired.
        if once.verb == .type, Self.keystrokeEditableKinds.contains(candidate.kind),
           once.commitFollows || Self.searchLike(candidate) {
            if once.app != nil {
                return .reply(Self.needsFront("\(Self.name(candidate)) runs its search or submit only on real keystrokes", app: once.app, screen: sighting.render))
            }
            body["keystrokes"] = .bool(true)
        }
        if once.app != nil { body["background"] = .bool(true) }
        Self.addAttention(once.attention, to: &body)

        let result: MacControlResult
        let postRead = MacSightCaptureBinding(frameID: UUID().uuidString)
        do {
            result = try await context.holding(\.capture, postRead) { context in
                try await host.dispatch(action: "act", body: body, turn: turn, context: context)
            }
        } catch {
            return .reply(Self.unknownActionReply(error, operation: "\(once.verb.rawValue) \(Self.name(candidate))", app: once.app ?? sighting.appName))
        }
        let output = Self.object(result.output)
        // The screen changed between the sighting and the act (an element or window that went away, a handle that no longer names its
        // control) and nothing was attempted: look again, once, and act only on the same subject by its identity, inside the exact window
        // first sighted. A positional address (`button 2`, `row 3`) is never resolved again: after a reorder it can name another subject, so
        // it keeps the refusal; so does a sighting that kept no window of its own.
        if !result.ok, once.firstSighted == nil, output["performed"] == nil, Self.changedBeforeActing.contains(result.error ?? ""),
           Self.mapName(once.target) != nil, let label = candidate.label, !label.isEmpty,
           let window = sighting.window, window.nativeWindow != nil {
            // Its window gone, the step refuses here and never looks in another window or app.
            if window.closed == true { return .reply(Self.sightedWindowClosed(once.target, screen: "")) }
            return .reply(await actOnce(verb: once.rawVerb, target: once.target, text: once.text, mode: once.mode, to: once.destination, toApp: once.destinationApp,
                seconds: once.seconds, holding: once.holding, button: once.rawButton, scrollAmount: once.scrollAmount, attention: once.attention, app: once.app,
                expect: once.expect, carry: once.carry, commitFollows: once.commitFollows, menus: once.menus, place: once.place,
                firstSighted: (label, candidate.kind, window), turn: turn, context: context))
        }
        return .ready((result, postRead, output))
    }

    /// The closed loop reported no verified result: say why with the screen after, and learn that the semantic press did not land.
    func hitFailed(_ once: ActOnce, sighting: Sighting, candidate: ActTarget, result: MacControlResult, postRead: MacSightCaptureBinding,
                   output: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        let mechanism = Self.string(output["status_note"]) ?? Self.string(output["guidance"]) ?? Self.string(output["detail"]) ?? Self.string(
            output["message"]) ?? Self.refusalWords(result.error ?? "unknown")
        let after = await sight(part: nil, app: once.app, observed: postRead, turn: turn, context: context)
        if result.error == "needs_front" {
            var screen: String?
            if case .seen(let hit) = after { screen = hit.render }
            let refusal = Self.needsFront(
                Self.string(output["needs_front_reason"]) ?? "it needs real input to the window in front",
                app: once.app, screen: screen,
                delivered: Self.bool(output["ax_delivered"]) == true
            )
            return MacFourVerbsReply(ok: refusal.ok, text: refusal.text,
                detail: Self.operationDetail(result, app: once.app ?? sighting.appName)
                    .merging(refusal.detail) { _, new in new })
        }
        var line = "No verified result for \(once.verb.rawValue) \(Self.name(candidate)). " + mechanism
        if case .seen(let hit) = after { line += "\n" + hit.render }
        var detail = Self.operationDetail(result, app: once.app ?? sighting.appName).merging([
            "error": .string(result.error ?? "refused"),
            "verb": .string(once.verb.rawValue),
            "target": .string(once.target),
        ]) { current, _ in current }
        if let changed = output["front_app_changed"] { detail["owner_front_changed"] = changed }
        if result.error == "verb_not_supported_on_element", detail["remedy"] == nil {
            detail["remedy"] = Self.inspectAppRemedy(once.app ?? sighting.appName,
                instruction: "Inspect this app's controls and choose a supported action.")
        }
        var reply = MacFourVerbsReply(ok: false, text: line, detail: detail)
        if once.verb == .click {
            do { try await learnRoute(pointer: false, pressed: candidate, reply: reply, in: sighting) }
            catch { reply = Self.appMapFailure(error, after: reply) }
        }
        return reply
    }

    /// The act landed: name what was actually acted on, the effect and the window after, refuse a different target than the one named,
    /// and remember a verified location.
    func hitLanded(_ once: ActOnce, sighting: Sighting, candidate: ActTarget, result: MacControlResult, postRead: MacSightCaptureBinding,
                   output: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        var effect = Self.effectWords(output: output)
        let after = await sight(part: nil, app: once.app, observed: postRead, turn: turn, context: context)
        if case .seen(let hit) = after { once.carry?.last = hit }
        if case .seen(let hit) = after, hit.place != sighting.place {
            effect = EffectWords(sentence: effect.sentence + " The window is now \(hit.place).", status: effect.status)
        }
        // Name the actual acted element rather than the caller’s alias; editable content-derived labels need place names.
        let acted = Self.object(Self.object(Self.object(output["effect"])["acted_element"])["before"])
        let actedKind = Self.string(acted["role"]).map { MacScreenRender.kindName(role: $0) }
        let dismissPressed = Self.string(Self.object(output["dismiss_target"])["label"])
        func answersLabel(_ label: String) -> Bool {
            guard Self.exactName(label) == Self.exactName(candidate.label ?? "") else {
                return Self.exactName(label) == Self.exactName(once.target)
            }
            return Self.answers(once.target, candidate)
        }
        let matchedName: String = {
            if once.verb == .dismiss, let pressed = dismissPressed {
                return "\"\(pressed)\"" + (answersLabel(pressed) ? "" : " in the same dialog as \(Self.name(candidate))")
            }
            guard let actedKind else { return Self.name(candidate) }
            if Self.editableKinds.contains(actedKind) { return "the \(actedKind) in \(sighting.place)" }
            if let label = Self.string(acted["label"]), !label.isEmpty { return "\(actedKind) \"\(label)\"" }
            return "\(actedKind) \(Self.name(candidate))"
        }()
        let typedInto = once.verb == .type
            ? " into " + matchedName
            : nil
        var line = (effect.status == "acted" || effect.status == "acted_changed"
            ? (typedInto == nil ? Self.pastTense(once.verb, direction: once.direction) : "Typed")
            : (typedInto == nil ? Self.attempted(once.verb, direction: once.direction) : "Tried to type"))
            + (typedInto ?? " " + matchedName) + ". " + effect.sentence
        let frontChanged = Self.bool(output["front_app_changed"])
        if once.app != nil, !sighting.isFront, frontChanged == false {
            line += " Done in \(sighting.appName ?? "that app")'s window in the background; nothing came to the front."
        }
        if let note = Self.bareNumberNote(once.target, chose: candidate, among: sighting.targets) { line += " " + note }
        if let leftOpen = Self.bool(output["menu_left_open"]) {
            line += leftOpen
                ? " It opened a menu I couldn't close — it may still be open in \(sighting.appName ?? "that app")."
                : " It opened a menu; I closed it."
        }
        if case .seen(let hit) = after { line += "\n" + hit.render }
        var detail = Self.operationDetail(result)
        if let frontChanged { detail["owner_front_changed"] = .bool(frontChanged) }
        if once.app != nil { detail["background"] = .bool(true) }
        if let leftOpen = output["menu_left_open"] { detail["menu_left_open"] = leftOpen }
        detail["verb"] = .string(once.verb.rawValue)
        detail["target"] = .string(once.target)
        detail["matched"] = .string(matchedName)
        detail["status"] = .string(effect.status)
        detail["dynamic_reobserved"] = .bool(once.reobservedAfterTransientMiss)
        // Satisfaction requires the intended control: exact handle identity or the named control’s own modal-dismiss action.
        let wrongLabel: String? = {
            if once.verb == .dismiss {
                guard let pressed = dismissPressed, !answersLabel(pressed),
                      !MacActClosedLoop.dismissLabels.contains(pressed.lowercased()) else { return nil }
                return pressed
            }
            // The revalidated handle establishes identity even when the page supplied an alternate reading name.
            if Self.string(Self.object(Self.object(output["effect"])["acted_element"])["handle"]) == candidate.handle { return nil }
            guard let actedLabel = Self.string(acted["label"]), !answersLabel(actedLabel) else { return nil }
            return actedLabel
        }()
        if once.fromMemory {
            detail["from_memory"] = .bool(true)
            line = "(From memory of this app, checked live.) " + line
        }
        if let actedLabel = wrongLabel {
            if once.fromMemory, let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
               let path = candidate.sourceAXPath {
                do { try await MacAppMapStore.shared.penalize(bundle: bundle, window: window, path: path, evict: true) }
                catch { detail["app_map_error"] = .string(error.localizedDescription) }
            }
            detail["status"] = .string("acted_on_different_target")
            detail["requested"] = .string(once.target)
            detail["matched"] = .string(actedLabel)
            detail["verification"] = .string(MotorVerificationState.failed.rawValue)
            detail.removeValue(forKey: "verification_evidence")
            var wrong = "\(Self.pastTense(once.verb, direction: once.direction)) \"\(actedLabel)\", not \"\(once.target)\" — "
                + "acted on a different target. Verify before claiming success."
            if case .seen(let hit) = after { wrong += "\n" + hit.render }
            return MacFourVerbsReply(ok: false, text: wrong, detail: detail)
        }
        if once.verb == .click {
            do {
                try await learnRoute(pointer: false,
                    pressed: candidate, reply: MacFourVerbsReply(ok: effect.status != "acted_mismatch", text: line, detail: detail),
                    in: sighting)
            } catch {
                detail["app_map_error"] = .string(error.localizedDescription)
                line += "\nApp-map learning failed: " + error.localizedDescription
            }
        }
        if effect.status == "acted_mismatch" {
            return MacFourVerbsReply(ok: false, text: line, detail: detail)
        }
        // Remember location only after verification and agreement with the requested name.
        if effect.status == "acted", [MacActVerb.click, .open, .select, .toggle].contains(once.verb) {
            do { try await rememberVerified(once.target, candidate, in: sighting, turn: turn, context: context) }
            catch {
                detail["app_map_error"] = .string(error.localizedDescription)
                line += "\nApp-map learning failed: " + error.localizedDescription
            }
        }
        let reply = MacFourVerbsReply(ok: true, text: line, detail: detail)
        return reply
    }
}
