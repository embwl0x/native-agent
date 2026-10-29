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
// Blueprint: | `MacSemanticAct.swift` | MacFourVerbs actOnce remains one semantic effect transaction with its existing observation identity |
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
        /// After a `front:true` raise: the pid that must be in front, or the
        /// act refuses rather than land in whatever took the front instead.
        expect: FrontExpectation? = nil,
        /// Batched steps: hands the post-act read to the next step.
        carry: SightCarry? = nil,
        /// A batch's next step presses return or enter on what this one types.
        commitFollows: Bool = false,
        /// False for an optional step ("Replace?"): a miss skips it, so the
        /// menus are not asked where its name lives.
        menus: Bool = true,
        /// One-call recovery pins its second attempt to this first sighting.
        retrySighting: SightCarry? = nil,
        /// A place on an image instead of a name: the hand goes there.
        place: MacImagePlace? = nil
    ) async -> MacFourVerbsReply {
        // "right_click" / "secondary_click" is a click with the right button.
        let rawButton = Self.isRightClick(rawVerb) ? "right" : rawButton
        let parsedVerb = Self.parseVerb(rawVerb)
        var verbName = parsedVerb.0
        let parsedDirection = parsedVerb.1
        if mode == .append, verbName != "type" || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MacFourVerbsReply(ok: false,
                text: "Append requires type and a named text target; nothing was typed.",
                detail: ["error": .string("append_requires_named_type")])
        }
        // "press" is how people say both: a key or chord → key, a name → click.
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        // Key requests may carry the chord in text; background typing with an empty target uses the focused field.
        let target = verbName == "key" && (try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target)) == nil
            && text.map(Self.pressMeansKey) == true ? text ?? target
            : verbName == "type" && app != nil && target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "focused field" : target
        /// The escalation ladder's middle rung, in words: nothing was touched,
        /// here is why the front is needed, and how to ask for it.
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
        // Some tool bindings require every declared field. An explicit auto
        // value preserves ordinary semantic/key/hover actions in those bindings.
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
            let reply = await Self.$requiredFrontPid.withValue(expect?.pid) {
                await performAtPlace(place, verb: verbName, seconds: seconds, holding: holding, button: button,
                                     before: carry?.take(), attention: attention)
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
        // In a front:true flow a command chord that a menu item carries
        // presses that item: right after a menu or sheet closes a posted key
        // can be dropped, and the menu route is verified by its effect.
        if verbName == "key", let expect, holding == nil,
           let chords = try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target),
           chords.count == 1, chords[0].modifiers.contains(.command) {
            let before: Sighting? = if let carried = carry?.take() { carried }
                else if case .seen(let hit) = await sight(part: nil) { hit } else { nil }
            if let before, before.pid != expect.pid {
                return MacFourVerbsReply(
                    ok: false, text: "The person changed apps; nothing pressed.",
                    detail: ["error": .string("owner_changed_apps"), "owner_front_changed": .bool(true)]
                )
            }
            // A sheet, dialog or panel (Open, Save) takes its own keys — cmd+shift+g
            // is Go to Folder there, not the main menu's Find Previous — and a
            // command the menu has greyed out is left to the real key too.
            let panel = before?.windowKind.map { $0.contains("AXSheet") || $0.contains("Dialog") } == true
            if let before, !panel {
                var body: [String: JSONValue] = ["chord": .string(Self.keySpec(target) ?? target)]
                body["require_front_pid"] = .int(Int64(expect.pid))
                if let found = try? await host.dispatch(action: "menu", body: body),
                   let row = Self.array(Self.object(found.output)["found"]).first.map({ Self.object($0) }),
                   let path = Self.string(row["path"]) {
                    let menu = await pressMenu(path, ["path": .string(path), "require_front": .bool(true),
                        "require_front_pid": .int(Int64(expect.pid))], screen: "\n" + before.render)
                    if Self.string(menu.detail["error"]) != "menu_item_disabled" { return menu }
                }
            }
        }
        if let physical = PhysicalVerb(rawValue: verbName) {
            // A real key or pointer reaches whatever is in front: after a
            // front:true raise the hand refuses, at the moment of posting,
            // when the front is no longer that app (User switched mid-act).
            let reply = await Self.$requiredFrontPid.withValue(expect?.pid) {
                await performPhysical(
                    physical,
                    target: target,
                    destination: destination,
                    destinationApp: namedDestinationApp,
                    seconds: seconds,
                    holding: holding,
                    button: button,
                    attention: attention,
                    carried: carry?.take()
                )
            }
            return Self.frontChangedWords(reply, verbName: verbName)
        }
        guard let verb = MacActVerb(rawValue: verbName) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I don't have a \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                    + "hand yet. What I can do: "
                    + (MacActVerb.allCases.map(\.rawValue) + PhysicalVerb.allCases.map(\.rawValue))
                        .joined(separator: ", ") + ".",
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
        // No target: type into whatever has focus, as a person does.
        if verb == .type, target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text {
            var before = carry?.take()
            var windowlessPid: Int32?
            if before == nil {
                switch await sight(part: nil) {
                case .seen(let hit): before = hit
                case .blind(let reply):
                    guard Self.string(reply.detail["error"]) == "no_frontmost_window" else { return reply }
                    windowlessPid = Self.int(Self.object(reply.detail["frontmost_app"])["pid"]).flatMap(Int32.init(exactly:))
                }
            }
            return await typeKeystrokes(text, into: "whatever has focus", before: before, frontPid: windowlessPid,
                                        expect: expect, attention: attention)
        }
        // a. A FRESH percept. Never a stored one: resolution happens against the
        //    screen as it is at the moment of acting, which is the entire reason
        //    `frame_id` can leave her hands.
        var sighting: Sighting
        if let carried = carry?.take() {
            // A batched step: the previous step's post-act read IS this step's
            // fresh pre-read — the window is not read twice.
            sighting = carried
        } else {
            // `seek`: a web page can bury the control past the walk's caps; the
            // look then searches deeper for this name and frames it.
            switch await sight(part: nil, app: app, seek: verb == .scroll || Self.isMenuPath(target) ? nil : target) {
            case .blind(let reply):
                if mode == .replace, reply.detail["status"] == .string("in_process_route") {
                    return Self.ownAppRoute(verb: rawVerb, target: target, text: text)
                }
                if app == nil, Self.isMenuPath(target), [.click, .open, .select, .toggle].contains(verb),
                   Self.string(reply.detail["error"]) == "no_frontmost_window" {
                    return await menuPressNoWindow(target, frontPid: expect?.pid)
                }
                return reply
            case .seen(let hit): sighting = hit
            }
        }
        if retrySighting?.last == nil { retrySighting?.last = sighting }
        // After a `front:true` raise the front must be THAT process AND that
        // window (by its rect) — another window of the same app is refused.
        if let expect, sighting.pid != expect.pid
            || (expect.frame != nil && !MacAXWindowIdentity.rectsMatch(expect.frame, sighting.windowFrame)) {
            return MacFourVerbsReply(
                ok: false,
                text: "The front window changed before I could act (front_window_changed), so I haven't touched anything.\n"
                    + sighting.render,
                // Another app took the front (User, mostly): his choice stands, nothing is put back over it.
                detail: ["error": .string(sighting.pid != expect.pid ? "owner_changed_apps" : "front_window_changed")]
            )
        }
        // An explicit menu path goes straight to the menu organ.
        if Self.isMenuPath(target),
           let menu = await menuCommandReply(target, verb: verb, app: app, seen: sighting) {
            return menu
        }
        // b. RESOLVE BY NAME.
        func resolve(_ targets: [ActTarget]) -> Resolution {
            verb == .scroll ? Self.resolveScrollTarget(target, among: targets)
                : Self.resolve(target, among: targets, pressing: [.click, .select, .toggle, .open].contains(verb))
        }
        var acquisitionSamples = 0
        // Motion sampling reads the FRONT screen; a background act never uses it.
        if app == nil {
            let acquisition = await reacquireSight(for: target, sighting: &sighting) {
                if case .none = resolve($0) { return true }
                return false
            }
            if let reply = acquisition.reply { return reply }
            acquisitionSamples = acquisition.samples
        }
        let reobservedAfterTransientMiss = acquisitionSamples > 0
        var resolution = resolve(sighting.targets)
        if app == nil, verb == .click || verb == .open {
            // A model round trip can leave only one usable motion sample.
            // Acquire at most two more, inside this act, and always resolve
            // again against the newest evidence. No click is sent while the
            // target is absent/ambiguous, and no remembered point is reused.
            let sampledApp = sighting.bundleIdentifier ?? sighting.appName
            for _ in 0..<max(0, 2 - acquisitionSamples) {
                guard case .hit(let candidate) = resolution,
                      candidate.physicalOnly, candidate.motionUncertain else { break }
                switch await sight(part: nil) {
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
                                        before: sighting, expect: expect, attention: attention)
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
            if menus { line += await menuHint(target, verb: verb, app: app ?? sighting.appName) }
            // A window that names (almost) nothing is not a real miss: the
            // control may be right there, only invisible to accessibility.
            // Say the next step now instead of leaving her to guess.
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
                detail: [
                    "error": .string("no_match"),
                    "target": .string(target),
                    "dynamic_reobserved": .bool(reobservedAfterTransientMiss),
                ]
            )

        case .ambiguous(let candidates):
            // The reply IS the question. Nothing is acted on.
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
            if !candidate.regionOnly, !bareFieldHit, !Self.answers(target, candidate) {
                let hint = menus ? await menuHint(target, verb: verb, app: app ?? sighting.appName) : ""
                return MacFourVerbsReply(
                    ok: false,
                    text: "Nothing here answers to \"\(target)\" exactly — the closest is \(Self.name(candidate)), "
                        + "which isn't it. I haven't touched anything." + hint + "\n" + sighting.render,
                    detail: ["error": .string("no_match"), "target": .string(target),
                             "nearest": .array([.string(Self.recoveryName(candidate))])]
                )
            }
            // "Delete" must never press "Delete All": a name that only appears
            // inside longer labels is answered with those labels, not acted on.
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
            if Self.nativeSurfaceApp != nil, let label = Self.nativeSurfaceLabel, candidate.label != label {
                return MacFourVerbsReply(ok: false,
                    text: "The selected native surface changed before I could act. I haven't touched it; read the screen again.\n" + sighting.render,
                    detail: ["error": .string("native_surface_changed")])
            }
            guard candidate.enabled else {
                return MacFourVerbsReply(
                    ok: false, text: "\(Self.name(candidate)) is disabled. Nothing was touched. Inspect this app for the prerequisite that enables it.\n" + sighting.render,
                    detail: ["error": .string("target_disabled"), "target": .string(target), "effects": .string("none"),
                        "remedy": Self.inspectAppRemedy(app ?? sighting.appName,
                            instruction: "Inspect this app for the prerequisite that enables the control; do not press it while disabled.")]
                )
            }
            if candidate.regionOnly, verb != .scroll {
                return MacFourVerbsReply(
                    ok: false,
                    text: "\(Self.name(candidate)) is a region, not a control. I can scroll it; name a visible thing inside it to click, open, type, select, toggle, or dismiss.",
                    detail: ["error": .string("region_needs_inner_target")]
                )
            }
            if candidate.physicalOnly,
               ![MacActVerb.click, .open, .scroll].contains(verb) {
                return MacFourVerbsReply(
                    ok: false,
                    text: "\(Self.name(candidate)) is an unlabeled visual region, so I can physically click, open, scroll, move, hover, hold, or drag there without pretending I know its semantic role.",
                    detail: ["error": .string("visual_region_needs_physical_action")]
                )
            }
            if mode == .append, candidate.isSupplemental {
                return MacFourVerbsReply(ok: false,
                    text: "Append requires an accessibility text target whose contents and end position can be verified; nothing was typed.",
                    detail: ["error": .string("append_target_unverifiable")])
            }
            // Scroll routes emit directional wheel input; containers and explicit
            // amounts use the hand aimed at the named region.
            let physicalScroll = verb == .scroll
                && (amount > 0 || direction.isHorizontal || Self.physicalScrollKinds.contains(candidate.kind))
                && (amount > 0 || direction.isHorizontal || candidate.kind == "web area" || candidate.frame != nil)
            // Background: only the app's own accessibility actions run in the
            // back. A pixel-found target or a wheel gesture is window-server
            // input, so it asks for the front instead of taking it.
            if app != nil, physicalScroll || candidate.isSupplemental,
               !(Self.nativeSurfaceApp == app && sighting.isFront) {
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
                )
            }
            // The last evidenced route for this exact control is a hypothesis.
            // Background presses still try Accessibility; a pointer belief
            // never refuses an action that may work through AX.
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
                let reply = await Self.$requiredFrontPid.withValue(Self.requiredFrontPid ?? sighting.pid) {
                    await performSupplementalSemantic(
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
                    )
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
                )
                guard reobservedAfterTransientMiss else { return reply }
                var detail = reply.detail
                detail["dynamic_reobserved"] = .bool(true)
                return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
            }
            // Select on a popup means choose an item in it, verified by its
            // value — pressing it only opens the menu.
            if verb == .select, app == nil, candidate.kind == "popup" {
                return await selectInPopup(candidate, option: text ?? target, before: sighting, attention: attention)
            }
            // c. DRIVE THE EXISTING ACT PATH. The handle and the frame id are
            //    OURS — they are read off the look we just took and never
            //    appear in the reply. Raise/focus setup, the observer, the
            //    diff and every gate are the closed loop's, unchanged.
            var body: [String: JSONValue] = [
                "verb": .string(verb.rawValue),
                "handle": .string(candidate.handle),
                "frame_id": .string(sighting.frameId),
            ]
            if let text { body["text"] = .string(text) }
            if verb == .type { body["mode"] = .string(mode.rawValue) }
            if verb == .scroll { body["direction"] = .string(direction.rawValue) }
            // A search field, or a field a return will submit, runs the app's
            // action only on real typing: a value set through accessibility
            // sits in the field and the search never fires.
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
            // The action owner's post-effect read, carried to the reply look.
            let postRead = MacSightCaptureBinding(frameID: UUID().uuidString)
            do {
                result = try await MacSightCaptureBinding.$current.withValue(postRead) {
                    try await host.dispatch(action: "act", body: body)
                }
            } catch {
                return Self.unknownActionReply(error, operation: "\(verb.rawValue) \(Self.name(candidate))", app: app ?? sighting.appName)
            }
            let output = Self.object(result.output)

            // d. THE REPLY, IN WORDS — then the fresh screen.
            guard result.ok else {
                let mechanism = Self.string(output["status_note"]) ?? Self.string(output["guidance"]) ?? Self.string(output["detail"]) ?? Self.string(output["message"]) ?? Self.refusalWords(result.error ?? "unknown")
                let after = await sight(part: nil, app: app, observed: postRead)
                if result.error == "needs_front" {
                    var screen: String?
                    if case .seen(let hit) = after { screen = hit.render }
                    return needsFront(
                        Self.string(output["needs_front_reason"]) ?? "it needs real input to the window in front",
                        screen: screen,
                        delivered: Self.bool(output["ax_delivered"]) == true
                    )
                }
                // Accessibility can't set a value here (a text box with no AX
                // value): a person just types. Only into an editable field, or
                // an unnamed group/scroll area that itself holds focus, and
                // only once the named element really has the keyboard focus.
                let focusOnly = ["group", "scroll area"].contains(candidate.kind)
                if mode == .replace, verb == .type, result.error == "verb_not_supported_on_element", let text,
                   Self.keystrokeEditableKinds.contains(candidate.kind)
                    || (focusOnly && Self.holdsFocus(target, in: sighting, exact: true)) {
                    var now: Sighting = if case .seen(let hit) = after { hit } else { sighting }
                    if app != nil {
                        return needsFront("this element takes typing only as real keystrokes", screen: now.render)
                    }
                    if let busy = Self.personActiveRefusal() { return busy }
                    // Another app in front now: its focused thing is not the one named.
                    func sameApp(_ seen: Sighting) -> Bool { seen.pid != nil && seen.pid == sighting.pid }
                    func otherApp() -> MacFourVerbsReply {
                        MacFourVerbsReply(
                            ok: false,
                            text: "Another app came to the front before I could type (owner_changed_apps), so I typed nothing.\n" + now.render,
                            detail: ["error": .string("owner_changed_apps"), "verb": .string("type"), "target": .string(target)]
                        )
                    }
                    guard sameApp(now) else { return otherApp() }
                    // An editable field takes the focus from a click, as a person's would.
                    if !focusOnly, !Self.holdsFocus(target, in: now, exact: false) {
                        let clicked = await Self.$requiredFrontPid.withValue(expect?.pid ?? now.pid) {
                            await performSupplementalSemantic(
                                .click, direction: direction, candidate: candidate, target: target, text: nil,
                                holding: nil, attention: attention, before: now
                            )
                        }
                        if clicked.ok, case .seen(let fresh) = await sight(part: nil) { now = fresh }
                        guard sameApp(now) else { return otherApp() }
                    }
                    guard Self.holdsFocus(target, in: now, exact: focusOnly) else {
                        return MacFourVerbsReply(
                            ok: false,
                            text: "\(Self.name(candidate)) doesn't hold the keyboard focus, so I typed nothing — keys would have gone somewhere else.\n"
                                + now.render,
                            detail: ["error": .string("target_not_focused"), "verb": .string("type"), "target": .string(target)]
                        )
                    }
                    return await typeKeystrokes(text, into: Self.name(candidate), before: now, expect: expect, attention: attention)
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
            let after = await sight(part: nil, app: app, observed: postRead)
            if case .seen(let hit) = after { carry?.last = hit }
            if case .seen(let hit) = after, hit.place != sighting.place {
                effect = EffectWords(sentence: effect.sentence + " The window is now \(hit.place).", status: effect.status)
            }
            // Name the element the app ACTUALLY acted on, not the address she
            // used for it: `type row 1` lands in a text area, and a field's
            // label may be its content, so an editable one is named by place.
            let acted = Self.object(Self.object(Self.object(output["effect"])["acted_element"])["before"])
            let actedKind = Self.string(acted["role"]).map { MacScreenRender.kindName(role: $0) }
            let actedOn = Self.object(output["acted_on"])
            let redirected = Self.bool(actedOn["redirected"]) == true
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
                if redirected {
                    let kind = Self.string(actedOn["role"]).map { MacScreenRender.kindName(role: $0) } ?? "item"
                    return "the \(kind) containing \(Self.name(candidate))"
                }
                guard let actedKind else { return Self.name(candidate) }
                if Self.editableKinds.contains(actedKind) { return "the \(actedKind) in \(sighting.place)" }
                if let label = Self.string(acted["label"]), !label.isEmpty { return "\(actedKind) \"\(label)\"" }
                return "\(actedKind) \(Self.name(candidate))"
            }()
            let typedInto = verb == .type
                ? " into " + matchedName
                : nil
            var line = (effect.status == "acted"
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
            // "Satisfied" means the INTENDED control was hit. The element the
            // app acted on must answer to the name asked; a redirected open must
            // be an ANCESTOR of the named thing; a dismiss press must be the
            // named control or a Cancel/Close/Done/OK (the lower layer keeps it
            // to the named thing's own modal).
            let wrongLabel: String? = {
                if verb == .dismiss {
                    guard let pressed = dismissPressed, !answersLabel(pressed),
                          !MacActClosedLoop.dismissLabels.contains(pressed.lowercased()) else { return nil }
                    return pressed
                }
                if redirected {
                    let ancestor = Self.path(actedOn["path"])
                    return Self.path(output["path"]).starts(with: ancestor) ? nil
                        : (Self.string(actedOn["role"]).map { MacScreenRender.kindName(role: $0) } ?? "another element")
                }
                // The element acted on IS the handle that was resolved (the
                // loop re-checked its identity): a page that renamed it for
                // reading ("(unnamed button)", a row identity) is not a miss.
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
                    try await learnRoute(pointer: Self.string(output["method"]) == "cgevent_click_fallback",
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
            // Verified, and the element acted on answered the name: remember
            // where it lives (or refresh it).
            if effect.status == "acted", !redirected, [MacActVerb.click, .open, .select, .toggle].contains(verb) {
                do { try await rememberVerified(target, candidate, in: sighting) }
                catch {
                    detail["app_map_error"] = .string(error.localizedDescription)
                    line += "\nApp-map learning failed: " + error.localizedDescription
                }
            }
            let reply = MacFourVerbsReply(ok: true, text: line, detail: detail)
            return reply
        }
    }
    /// A hand refused because another app took the front mid-act, in words.
}
