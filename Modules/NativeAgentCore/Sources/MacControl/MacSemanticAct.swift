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
// Blueprint: | `MacSemanticAct.swift` | `MacFourVerbs.actOnce`: Fresh-name transactions preserve key intent, focus typing and current-content scroll |
extension MacFourVerbs {
    func actOnce(
        verb rawVerb: String,
        target: String,
        text: String?,
        mode: MacTypeMode,
        to destination: String?,
        toApp destinationApp: String?,
        seconds: Double?,
        holding: String?,
        button rawButton: String?,
        scrollAmount: Int?,
        attention: BurstAttention?,
        /// Every look in a background act reads the named app's window without raising it.
        app: String? = nil,
        /// After a `front:true` raise: the pid that must be in front, or the act refuses rather than land in whatever took the front instead.
        expect: FrontExpectation? = nil,
        /// Carry the post-act read into the next batch step to avoid duplicate observation.
        carry: SightCarry? = nil,
        /// A following submit key changes how this step’s typing must be delivered.
        commitFollows: Bool = false,
        /// Optional misses skip without menu discovery because the caller did not require that control.
        menus: Bool = true,
        /// Pin recovery to the first sighting; delivered-image points go through the hand.
        place: MacImagePlace? = nil,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        let rawButton = Self.isRightClick(rawVerb) ? "right" : rawButton
        let parsedVerb = Self.parseVerb(rawVerb)
        var verbName = parsedVerb.0
        let parsedDirection = parsedVerb.1
        if mode == .append, verbName != "type" || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MacFourVerbsReply(ok: false,
                text: "Append requires type and a named text target; nothing was typed.",
                detail: ["error": .string("append_requires_named_type")])
        }
        // Press syntax must distinguish keyboard chords from named controls.
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        // Key requests may carry the chord in text; background typing with an empty target uses the focused field.
        let target = verbName == "key" && (try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target)) == nil
            && text.map(Self.pressMeansKey) == true ? text ?? target
            : target
        /// When the front is required, explain the untouched state and how the caller can request it.
        func needsFront(_ reason: String, screen: String? = nil, delivered: Bool = false) -> MacFourVerbsReply {
            let name = app ?? "that app"
            let touched = delivered
                ? "An accessibility action already went to \(name) without confirming, so check the screen below before repeating; nothing came to the front. "
                : "I haven't touched \(name) and nothing came to the front. "
            return MacFourVerbsReply(
                ok: false,
                text: "I need the screen because \(reason). " + touched
                    + "Only use front:true when the task explicitly asks to bring \(name) forward."
                    + (screen.map { "\n" + $0 } ?? ""),
                detail: [
                    "error": .string("needs_front"),
                    "status": .string("needs_front"),
                    "needs_front_reason": .string(reason),
                    "background": .bool(true),
                    "owner_front_changed": .bool(false),
                    "ax_delivered": .bool(delivered),
                ]
            )
        }
        if app != nil {
            if PhysicalVerb(rawValue: verbName) != nil || place != nil {
                return needsFront("\(verbName) moves the real pointer or keyboard, which only reaches the app in front")
            }
            if holding != nil || rawButton.map({ ["left", "right"].contains($0.lowercased()) }) == true {
                return needsFront("held keys and explicit mouse buttons are real input, which only reaches the app in front")
            }
        }
        // `to_app` applies only to drag; refuse it before observing rather than silently acting in the wrong window.
        let namedDestinationApp = destinationApp
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let namedDestinationApp {
            guard place == nil else {
                return MacFourVerbsReply(ok: false,
                    text: "A point is in the window in front, so to_app doesn't apply to it. Nothing was sent.",
                    detail: ["error": .string("to_app_with_point")])
            }
            guard verbName == PhysicalVerb.drag.rawValue else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.verbNotDraggableWords(verbName),
                    detail: ["error": .string(MacCrossAppDrag.verbNotDraggableReason)]
                )
            }
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.missingDestinationWords(namedDestinationApp),
                    detail: ["error": .string(MacCrossAppDrag.missingDestinationReason)]
                )
            }
        }
        let amount = scrollAmount ?? 0
        guard (0...120).contains(amount), amount == 0 || verbName == "scroll" else {
            return MacFourVerbsReply(ok: false,
                text: "Scroll amount must be 1–120 lines, or 0 for the ordinary/default action. I haven't sent input.",
                detail: ["error": .string("invalid_scroll_amount")])
        }
        let normalizedButton = rawButton?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Explicit auto preserves ordinary verbs in tool bindings that require every declared field.
        let button = normalizedButton == "auto" ? nil : normalizedButton
        if let button {
            guard MacMouseButton(rawValue: button) != nil,
                  ["click", "open", "double_click", "drag", "hold"].contains(verbName),
                  !(verbName == "hold" && Self.keySpec(target) != nil) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "Use auto for the ordinary action, or left/right on a click, open, drag, or pointer hold. I haven't sent input.",
                    detail: ["error": .string("invalid_mouse_button_action")]
                )
            }
        }
        if let place {
            let reply = await context.holding(\.requiredFrontPid, expect?.pid) {
                context in await performAtPlace(place, verb: verbName, text: text, seconds: seconds, holding: holding, button: button,
                                     before: carry?.take(), attention: attention, turn: turn, context: context)
            }
            return Self.frontChangedWords(reply, verbName: verbName)
        }
        let direction: ScrollDirection = {
            guard verbName == MacActVerb.scroll.rawValue else { return parsedDirection }
            let hint = Self.normalize(text ?? "")
            if hint == "up" || hint.contains("scroll up") { return .up }
            if hint == "down" || hint.contains("scroll down") { return .down }
            if hint == "left" || hint.contains("scroll left") { return .left }
            if hint == "right" || hint.contains("scroll right") { return .right }
            return parsedDirection
        }()
        // Menu discovery cannot reinterpret a requested keyboard chord or make it ambiguous.
        if let physical = PhysicalVerb(rawValue: verbName) {
            // After raising, every posted event still requires that app in front so intervening person input cannot redirect it.
            let reply = await context.holding(\.requiredFrontPid, expect?.pid) {
                context in await performPhysical(
                    physical,
                    target: target,
                    destination: destination,
                    destinationApp: namedDestinationApp,
                    seconds: seconds,
                    holding: holding,
                    button: button,
                    attention: attention,
                    carried: carry?.take()
                , turn: turn, context: context)
            }
            return Self.frontChangedWords(reply, verbName: verbName)
        }
        guard let verb = MacActVerb(rawValue: verbName) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I don't have a \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                    + "hand yet. What I can do: "
                    + Self.actionVerbs.joined(separator: ", ") + ".",
                detail: ["error": .string("unknown_verb"), "verb": .string(rawVerb)]
            )
        }
        if verb == .type, (text ?? "").isEmpty {
            return MacFourVerbsReply(
                ok: false,
                text: "Nothing to type — give me the words and I'll put them in \"\(target)\".",
                detail: ["error": .string("missing_text")]
            )
        }
        // Targetless typing follows actual keyboard focus.
        if verb == .type, target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text {
            if app != nil { return needsFront("typing at keyboard focus needs the app in front") }
            var before = carry?.take()
            var windowlessPid: Int32?
            if before == nil {
                switch await sight(part: nil, turn: turn, context: context) {
                case .seen(let hit): before = hit
                case .blind(let reply):
                    guard Self.string(reply.detail["error"]) == "no_frontmost_window" else { return reply }
                    windowlessPid = Self.int(Self.object(reply.detail["frontmost_app"])["pid"]).flatMap(Int32.init(exactly:))
                }
            }
            return await typeKeystrokes(text, into: "whatever has focus", before: before, frontPid: windowlessPid,
                                        expect: expect, attention: attention, turn: turn, context: context)
        }
        // Resolve names against current perception rather than stored frames.
        var sighting: Sighting
        if let carried = carry?.take() {
            // The previous post-act read is the next step’s fresh baseline; do not read the window twice.
            sighting = carried
        } else {
            // Seek expands bounded discovery for controls hidden beyond the ordinary walk cap.
            switch await sight(part: nil, app: app, seek: verb == .scroll || Self.isMenuPath(target) ? nil : target, turn: turn, context: context) {
            case .blind(let reply):
                if mode == .replace, reply.detail["status"] == .string("in_process_route") {
                    return Self.ownAppRoute(verb: rawVerb, target: target, text: text)
                }
                if app == nil, Self.isMenuPath(target), [.click, .open, .select, .toggle].contains(verb),
                   Self.string(reply.detail["error"]) == "no_frontmost_window" {
                    return await menuPressNoWindow(target, frontPid: expect?.pid, turn: turn, context: context)
                }
                return reply
            case .seen(let hit): sighting = hit
            }
        }
        // After raising, require both pid and window geometry so a same-app sibling cannot receive input.
        if let expect, sighting.pid != expect.pid
            || (expect.frame != nil && !MacAXWindowIdentity.rectsMatch(expect.frame, sighting.windowFrame)) {
            return MacFourVerbsReply(
                ok: false,
                text: "The front window changed before I could act (front_window_changed), so I haven't touched anything.\n"
                    + sighting.render,
                // Respect the person’s app switch; never cover it by restoring the agent’s target.
                detail: ["error": .string(sighting.pid != expect.pid ? "owner_changed_apps" : "front_window_changed")]
            )
        }
        // Explicit menu paths need no fuzzy control discovery.
        if Self.isMenuPath(target),
           let menu = await menuCommandReply(target, verb: verb, app: app, seen: sighting, turn: turn, context: context) {
            return menu
        }
        let scrollViewport = sighting.visibleFrame ?? sighting.windowFrame
        func resolve(_ targets: [ActTarget]) -> Resolution {
            verb == .scroll ? Self.resolveScrollTarget(target, among: targets, viewport: scrollViewport)
                : Self.resolve(target, among: targets, pressing: [.click, .select, .toggle, .open].contains(verb))
        }
        var acquisitionSamples = 0
        // Motion sampling reads the FRONT screen; a background act never uses it.
        if app == nil {
            let acquisition = await reacquireSight(for: target, sighting: &sighting, turn: turn, context: context) {
                if case .none = resolve($0) { return true }
                return false
            }
            if let reply = acquisition.reply { return reply }
            acquisitionSamples = acquisition.samples
        }
        let reobservedAfterTransientMiss = acquisitionSamples > 0
        var resolution = resolve(sighting.targets)
        if app == nil, verb == .click || verb == .open {
            // Allow at most two fresh motion samples, then resolve again; absent or ambiguous targets cannot use remembered points.
            let sampledApp = sighting.bundleIdentifier ?? sighting.appName
            for _ in 0..<max(0, 2 - acquisitionSamples) {
                guard case .hit(let candidate) = resolution,
                      candidate.physicalOnly, candidate.motionUncertain else { break }
                switch await sight(part: nil, turn: turn, context: context) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return MacFourVerbsReply(
                            ok: false,
                            text: "The foreground app changed while I was observing motion. I haven't clicked.\n" + refreshed.render,
                            detail: ["error": .string("motion_sampling_app_changed")]
                        )
                    }
                    sighting = refreshed
                    resolution = Self.resolve(target, among: refreshed.targets, pressing: [.click, .select, .toggle, .open].contains(verb))
                }
            }
        }
        // Use a remembered control only when fresh perception finds its kind and label at the stored path and it answers the name.
        var fromMemory = false
        if case .none = resolution, verb != .scroll {
            do {
                if let remembered = try await mapResolve(target, in: sighting) {
                    resolution = remembered
                    if case .hit = remembered { fromMemory = true }
                }
            } catch { return Self.appMapFailure(error) }
        }
        var bareFields: [ActTarget] = []
        var bareFieldHit = false
        let unanswered: Bool = {
            switch resolution {
            case .none: return true
            case .hit(let candidate): return !candidate.regionOnly && !Self.answers(target, candidate)
            case .ambiguous: return false
            }
        }()
        if unanswered, verb != .scroll, let bare = Self.bareField(target, in: sighting) {
            if let hit = bare.hit { resolution = .hit(hit); bareFieldHit = true } else { bareFields = bare.candidates }
        }
        if mode == .replace, unanswered, verb == .type, let text, Self.typesAtFocus(target, in: sighting) {
            if app != nil { return needsFront("typing where the keyboard focus is takes real keystrokes", screen: sighting.render) }
            let focused = sighting.targets.first { !$0.isSupplemental && $0.sourceAXPath == sighting.focusPath }
            return await typeKeystrokes(text, into: focused.map(Self.name) ?? "the focused element",
                                        before: sighting, expect: expect, attention: attention, turn: turn, context: context)
        }
        switch resolution {
        case .none(let nearest):
            var line = "Nothing on this screen is called \"\(target)\"."
            if bareFields.count > 1 {
                line += " Fields here, none focused: " + bareFields.map(Self.recoveryName).joined(separator: " · ") + " — name one."
            } else if !nearest.isEmpty {
                line += " What I can see: " + nearest.joined(separator: " · ") + "."
            } else {
                line += " Nothing here is named at all — the screen below is everything I can read."
            }
            let hint = menus ? await menuHint(target, verb: verb, app: app ?? sighting.appName, turn: turn, context: context) : MenuHint()
            line += hint.text
            // Sparse AX can hide a visible target; explain the available next step rather than claiming it absent.
            let named = sighting.targets.filter { candidate in
                !(candidate.label ?? "").isEmpty && !["window", "web area"].contains(candidate.kind)
            }
            if named.count < 3 {
                line += " This window exposes almost nothing to accessibility, so a name can't reach it:"
                    + " look at this app again (it attaches the window's image when accessibility is thin)"
                    + " and act on the visual target it lists."
            }
            return MacFourVerbsReply(
                ok: false,
                text: line + "\n" + sighting.render,
                detail: hint.detail.merging([
                    "error": .string("no_match"),
                    "target": .string(target),
                    "dynamic_reobserved": .bool(reobservedAfterTransientMiss),
                ]) { _, new in new }
            )

        case .ambiguous(let candidates):
            // Ambiguity returns a question without acting.
            let listed = candidates.map { candidate -> String in
                Self.recoveryName(candidate) + " (\(candidate.kind))"
            }
            let qualified = candidates.compactMap { candidate -> String? in
                guard let label = candidate.label, !label.isEmpty else { return nil }
                let phrase = label + " " + candidate.kind
                guard case .hit(let hit) = Self.resolve(phrase, among: sighting.targets),
                      hit == candidate else { return nil }
                return "target:\"\(phrase)\""
            }
            let guidance = qualified.count == candidates.count
                ? " Use " + qualified.joined(separator: " or ")
                    + " with the same app and verb. The trailing role selects that kind of control."
                : ""
            return MacFourVerbsReply(
                ok: false,
                text: "\(candidates.count) things match \"\(target)\": "
                    + listed.joined(separator: ", ")
                    + ". Which one? I haven't touched anything." + guidance + "\n" + sighting.render,
                detail: [
                    "error": .string("ambiguous"),
                    "target": .string(target),
                    "candidates": .array(candidates.map(Self.candidateDetail)),
                ]
            )

        case .hit(let candidate):
            // The resolved target must answer to the name before the act is admitted.
            if !candidate.regionOnly, !bareFieldHit, !(verb == .scroll && target.isEmpty), !Self.answers(target, candidate) {
                let hint = menus ? await menuHint(target, verb: verb, app: app ?? sighting.appName, turn: turn, context: context) : MenuHint()
                return MacFourVerbsReply(
                    ok: false,
                    text: "Nothing here answers to \"\(target)\" exactly — the closest is \(Self.name(candidate)), "
                        + "which isn't it. I haven't touched anything." + hint.text + "\n" + sighting.render,
                    detail: hint.detail.merging(["error": .string("no_match"), "target": .string(target),
                             "nearest": .array([.string(Self.recoveryName(candidate))])]) { _, new in new }
                )
            }
            // Containment cannot authorize a commit: Delete must not press Delete All.
            if Self.committingVerbs.contains(verb), !candidate.regionOnly, !bareFieldHit,
               !Self.answers(target, candidate, exact: true) {
                let containing = sighting.targets.filter { $0 == candidate || Self.containsName(Self.askedName(target), $0) }
                return MacFourVerbsReply(
                    ok: false,
                    text: "Nothing here is named exactly \"\(target)\"; it is only part of "
                        + containing.map { Self.recoveryName($0) + " (\($0.kind))" }.joined(separator: ", ")
                        + ". Name the one you mean exactly. I haven't touched anything.\n" + sighting.render,
                    detail: ["error": .string("inexact_name"), "target": .string(target),
                             "candidates": .array(containing.map(Self.candidateDetail))]
                )
            }
            if context.nativeSurfaceApp != nil, let label = context.nativeSurfaceLabel, candidate.label != label {
                return MacFourVerbsReply(ok: false,
                    text: "The selected native surface changed before I could act. I haven't touched it; read the screen again.\n" + sighting.render,
                    detail: ["error": .string("native_surface_changed")])
            }
            if candidate.enabled == nil {
                return MacFourVerbsReply(ok: false,
                    text: "\(Self.name(candidate)) has no readable enabled state. Read the app again before acting.\n" + sighting.render,
                    detail: ["error": .string("enabled_state_unavailable"), "target": .string(target), "effects": .string("none"),
                        "remedy": Self.inspectAppRemedy(app ?? sighting.appName, instruction: "Read this control's Accessibility state before acting.")])
            }
            guard candidate.enabled == true else {
                return MacFourVerbsReply(
                    ok: false, text: "\(Self.name(candidate)) is disabled. Nothing was touched. Inspect this app for the prerequisite that enables it.\n"
                        + sighting.render,
                    detail: ["error": .string("target_disabled"), "target": .string(target), "effects": .string("none"),
                        "remedy": Self.inspectAppRemedy(app ?? sighting.appName,
                            instruction: "Inspect this app for the prerequisite that enables the control; do not press it while disabled.")]
                )
            }
            if candidate.regionOnly, verb != .scroll {
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
               ![MacActVerb.click, .open, .scroll].contains(verb) {
                return MacFourVerbsReply(
                    ok: false,
                    text: """
                        \(Self.name(candidate)) is an unlabeled visual region, so I can physically click, open, scroll, move, hover, hold, or drag there \
                        without pretending I know its semantic role.
                        """,
                    detail: ["error": .string("visual_region_needs_physical_action")]
                )
            }
            if mode == .append, candidate.isSupplemental {
                return MacFourVerbsReply(ok: false,
                    text: "Append requires an accessibility text target whose contents and end position can be verified; nothing was typed.",
                    detail: ["error": .string("append_target_unverifiable")])
            }
            // Wheel input needs the named region’s aim; containers and explicit amounts retain the physical route.
            let physicalScroll = verb == .scroll
                && (target.isEmpty || amount > 0 || direction.isHorizontal || Self.physicalScrollKinds.contains(candidate.kind))
                && (amount > 0 || direction.isHorizontal || candidate.kind == "web area" || candidate.frame != nil)
            // Only AX actions can run in the background; pixel targets and wheel input require explicit front permission.
            if app != nil, physicalScroll || candidate.isSupplemental,
               !(context.nativeSurfaceApp == app && sighting.isFront) {
                return needsFront(
                    physicalScroll
                        ? "scrolling it needs the wheel over the window"
                        : "\(Self.name(candidate)) was found in pixels, not accessibility, so it needs a real click",
                    screen: sighting.render
                )
            }
            if physicalScroll {
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                , turn: turn, context: context)
            }
            // A remembered pointer route is only a hypothesis; background presses must still try the app’s AX handler.
            var learnedPointer = false
            let pointerHypothesis: Bool
            do {
                pointerHypothesis = verb == .click && holding == nil && button == nil
                    && !candidate.isSupplemental && candidate.frame != nil
                    ? try await pressesByPointer(candidate, in: sighting) : false
            } catch { return Self.appMapFailure(error) }
            if verb == .click, holding == nil, button == nil, !candidate.isSupplemental, candidate.frame != nil,
               pointerHypothesis, app == nil {
                learnedPointer = true
            }
            let pressButton = learnedPointer ? "left" : button
            if holding != nil || pressButton != nil {
                guard verb != .type else {
                    return MacFourVerbsReply(
                        ok: false,
                        text: "I can't hold keys while typing text; use a key or chord action instead.",
                        detail: ["error": .string("holding_not_supported_for_type")]
                    )
                }
                // Every pointer event reaches only the app it was aimed at.
                let reply = await context.holding(\.requiredFrontPid, context.requiredFrontPid ?? sighting.pid) {
                    context in await performSupplementalSemantic(
                        verb,
                        direction: direction,
                        scrollAmount: amount,
                        candidate: candidate,
                        target: target,
                        text: text,
                        holding: holding,
                        button: pressButton,
                        attention: attention,
                        before: sighting
                    , turn: turn, context: context)
                }
                guard verb == .click, holding == nil, pressButton == "left" else { return reply }
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
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                , turn: turn, context: context)
                guard reobservedAfterTransientMiss else { return reply }
                var detail = reply.detail
                detail["dynamic_reobserved"] = .bool(true)
                return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
            }
            // Popup selection needs a verified value change; pressing alone merely opens its menu.
            if verb == .select, app == nil, candidate.kind == "popup" {
                return await selectInPopup(candidate, option: text ?? target, before: sighting, attention: attention, turn: turn, context: context)
            }
            // Use the fresh look’s internal frame and handle through the existing closed loop so admission and effect verification stay shared.
            var body: [String: JSONValue] = [
                "verb": .string(verb.rawValue),
                "handle": .string(candidate.handle),
                "frame_id": .string(sighting.frameId),
            ]
            if let text { body["text"] = .string(text) }
            if verb == .type { body["mode"] = .string(mode.rawValue) }
            if verb == .scroll { body["direction"] = .string(direction.rawValue) }
            // Search and submit fields need real typing; setting an AX value alone may leave their action unfired.
            if verb == .type, Self.keystrokeEditableKinds.contains(candidate.kind),
               commitFollows || Self.searchLike(candidate) {
                if app != nil {
                    return needsFront("\(Self.name(candidate)) runs its search or submit only on real keystrokes", screen: sighting.render)
                }
                body["keystrokes"] = .bool(true)
            }
            if app != nil { body["background"] = .bool(true) }
            Self.addAttention(attention, to: &body)

            let result: MacControlResult
            let postRead = MacSightCaptureBinding(frameID: UUID().uuidString)
            do {
                result = try await context.holding(\.capture, postRead) { context in
                    try await host.dispatch(action: "act", body: body, turn: turn, context: context)
                }
            } catch {
                return Self.unknownActionReply(error, operation: "\(verb.rawValue) \(Self.name(candidate))", app: app ?? sighting.appName)
            }
            let output = Self.object(result.output)

            guard result.ok else {
                let mechanism = Self.string(output["status_note"]) ?? Self.string(output["guidance"]) ?? Self.string(output["detail"]) ?? Self.string(
                    output["message"]) ?? Self.refusalWords(result.error ?? "unknown")
                let after = await sight(part: nil, app: app, observed: postRead, turn: turn, context: context)
                if result.error == "needs_front" {
                    var screen: String?
                    if case .seen(let hit) = after { screen = hit.render }
                    let refusal = needsFront(
                        Self.string(output["needs_front_reason"]) ?? "it needs real input to the window in front",
                        screen: screen,
                        delivered: Self.bool(output["ax_delivered"]) == true
                    )
                    return MacFourVerbsReply(ok: refusal.ok, text: refusal.text,
                        detail: Self.operationDetail(result, app: app ?? sighting.appName)
                            .merging(refusal.detail) { _, new in new })
                }
                var line = "No verified result for \(verb.rawValue) \(Self.name(candidate)). " + mechanism
                if case .seen(let hit) = after { line += "\n" + hit.render }
                var detail = Self.operationDetail(result, app: app ?? sighting.appName).merging([
                    "error": .string(result.error ?? "refused"),
                    "verb": .string(verb.rawValue),
                    "target": .string(target),
                ]) { current, _ in current }
                if let changed = output["front_app_changed"] { detail["owner_front_changed"] = changed }
                if result.error == "verb_not_supported_on_element", detail["remedy"] == nil {
                    detail["remedy"] = Self.inspectAppRemedy(app ?? sighting.appName,
                        instruction: "Inspect this app's controls and choose a supported action.")
                }
                var reply = MacFourVerbsReply(ok: false, text: line, detail: detail)
                if verb == .click {
                    do { try await learnRoute(pointer: false, pressed: candidate, reply: reply, in: sighting) }
                    catch { reply = Self.appMapFailure(error, after: reply) }
                }
                return reply
            }
            var effect = Self.effectWords(output: output)
            let after = await sight(part: nil, app: app, observed: postRead, turn: turn, context: context)
            if case .seen(let hit) = after { carry?.last = hit }
            if case .seen(let hit) = after, hit.place != sighting.place {
                effect = EffectWords(sentence: effect.sentence + " The window is now \(hit.place).", status: effect.status)
            }
            // Name the actual acted element rather than the caller’s alias; editable content-derived labels need place names.
            let acted = Self.object(Self.object(Self.object(output["effect"])["acted_element"])["before"])
            let actedKind = Self.string(acted["role"]).map { MacScreenRender.kindName(role: $0) }
            let dismissPressed = Self.string(Self.object(output["dismiss_target"])["label"])
            func answersLabel(_ label: String) -> Bool {
                guard Self.exactName(label) == Self.exactName(candidate.label ?? "") else {
                    return Self.exactName(label) == Self.exactName(target)
                }
                return Self.answers(target, candidate)
            }
            let matchedName: String = {
                if verb == .dismiss, let pressed = dismissPressed {
                    return "\"\(pressed)\"" + (answersLabel(pressed) ? "" : " in the same dialog as \(Self.name(candidate))")
                }
                guard let actedKind else { return Self.name(candidate) }
                if Self.editableKinds.contains(actedKind) { return "the \(actedKind) in \(sighting.place)" }
                if let label = Self.string(acted["label"]), !label.isEmpty { return "\(actedKind) \"\(label)\"" }
                return "\(actedKind) \(Self.name(candidate))"
            }()
            let typedInto = verb == .type
                ? " into " + matchedName
                : nil
            var line = (effect.status == "acted" || effect.status == "acted_changed"
                ? (typedInto == nil ? Self.pastTense(verb, direction: direction) : "Typed")
                : (typedInto == nil ? Self.attempted(verb, direction: direction) : "Tried to type"))
                + (typedInto ?? " " + matchedName) + ". " + effect.sentence
            let frontChanged = Self.bool(output["front_app_changed"])
            if app != nil, !sighting.isFront, frontChanged == false {
                line += " Done in \(sighting.appName ?? "that app")'s window in the background; nothing came to the front."
            }
            if let note = Self.bareNumberNote(target, chose: candidate, among: sighting.targets) { line += " " + note }
            if let leftOpen = Self.bool(output["menu_left_open"]) {
                line += leftOpen
                    ? " It opened a menu I couldn't close — it may still be open in \(sighting.appName ?? "that app")."
                    : " It opened a menu; I closed it."
            }
            if case .seen(let hit) = after { line += "\n" + hit.render }
            var detail = Self.operationDetail(result)
            if let frontChanged { detail["owner_front_changed"] = .bool(frontChanged) }
            if app != nil { detail["background"] = .bool(true) }
            if let leftOpen = output["menu_left_open"] { detail["menu_left_open"] = leftOpen }
            detail["verb"] = .string(verb.rawValue)
            detail["target"] = .string(target)
            detail["matched"] = .string(matchedName)
            detail["status"] = .string(effect.status)
            detail["dynamic_reobserved"] = .bool(reobservedAfterTransientMiss)
            // Satisfaction requires the intended control: exact handle identity or the named control’s own modal-dismiss action.
            let wrongLabel: String? = {
                if verb == .dismiss {
                    guard let pressed = dismissPressed, !answersLabel(pressed),
                          !MacActClosedLoop.dismissLabels.contains(pressed.lowercased()) else { return nil }
                    return pressed
                }
                // The revalidated handle establishes identity even when the page supplied an alternate reading name.
                if Self.string(Self.object(Self.object(output["effect"])["acted_element"])["handle"]) == candidate.handle { return nil }
                guard let actedLabel = Self.string(acted["label"]), !answersLabel(actedLabel) else { return nil }
                return actedLabel
            }()
            if fromMemory {
                detail["from_memory"] = .bool(true)
                line = "(From memory of this app, checked live.) " + line
            }
            if let actedLabel = wrongLabel {
                if fromMemory, let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
                   let path = candidate.sourceAXPath {
                    do { try await MacAppMapStore.shared.penalize(bundle: bundle, window: window, path: path, evict: true) }
                    catch { detail["app_map_error"] = .string(error.localizedDescription) }
                }
                detail["status"] = .string("acted_on_different_target")
                detail["requested"] = .string(target)
                detail["matched"] = .string(actedLabel)
                detail["verification"] = .string(MotorVerificationState.failed.rawValue)
                detail.removeValue(forKey: "verification_evidence")
                var wrong = "\(Self.pastTense(verb, direction: direction)) \"\(actedLabel)\", not \"\(target)\" — "
                    + "acted on a different target. Verify before claiming success."
                if case .seen(let hit) = after { wrong += "\n" + hit.render }
                return MacFourVerbsReply(ok: false, text: wrong, detail: detail)
            }
            if verb == .click {
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
            if effect.status == "acted", [MacActVerb.click, .open, .select, .toggle].contains(verb) {
                do { try await rememberVerified(target, candidate, in: sighting, turn: turn, context: context) }
                catch {
                    detail["app_map_error"] = .string(error.localizedDescription)
                    line += "\nApp-map learning failed: " + error.localizedDescription
                }
            }
            let reply = MacFourVerbsReply(ok: true, text: line, detail: detail)
            return reply
        }
    }
    /// Explain when an intervening app switch refused the hand.
}
