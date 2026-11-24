import Foundation
import NativeAgentCore
import PersistenceCore
import AppKit
import SenseCore
import NativeAgentShared
import ApplicationServices
import DeskCore
import CoreGraphics
import UserNotifications
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacSemanticAct.swift` | `MacFourVerbs.actOnce`, `ActOnce`, `admitActOnce`: Fresh-name transactions preserve key intent, focus typing and current-content scroll; the act's outline over its admission, sight (`MacSemanticAct+Resolve.swift`) and hit (`MacSemanticAct+Hit.swift`) stages, and the state they share |
extension MacFourVerbs {
    /// The act's refusals that mean the screen changed under its sighting before anything was attempted.
    static let changedBeforeActing: Set<String> = ["ax_evidence_unavailable", "window_evidence_unavailable", "handle_drifted",
        "frame_window_gone", MacAccessibilityActuator.pathNotFoundError]

    /// A second look stays inside the exact window its step first sighted: the same process, the same AX window, and the same document where AX
    /// names one. Anywhere else it refuses untouched; it never looks for its subject in another window or app.
    static func outsideSightedWindow(_ first: MacAXWindowIdentity, _ sighting: Sighting, target: String) -> MacFourVerbsReply? {
        guard let now = sighting.window, now.pid == first.pid, let native = first.nativeWindow, now.nativeWindow == native
        else {
            if first.closed == true { return sightedWindowClosed(target, screen: "\n" + sighting.render) }
            return MacFourVerbsReply(ok: false,
                text: "The screen changed before I could act, and the window I first found \"\(target)\" in is no longer the one I can see. "
                    + "I haven't touched anything.\n" + sighting.render,
                detail: ["error": .string("sighted_window_changed"), "target": .string(target), "effects": .string("none")])
        }
        // Unrecorded on both sides is the same; a document on one side only, or a different one, is a changed window.
        guard now.document == first.document else {
            return MacFourVerbsReply(ok: false,
                text: "The screen changed before I could act, and the window I first found \"\(target)\" in now shows another document. "
                    + "I haven't touched anything.\n" + sighting.render,
                detail: ["error": .string("sighted_window_changed"), "target": .string(target), "effects": .string("none")])
        }
        return nil
    }
    static func sightedWindowClosed(_ target: String, screen: String) -> MacFourVerbsReply {
        MacFourVerbsReply(ok: false, text: "The window I first found \"\(target)\" in has closed, so I haven't touched anything." + screen,
            detail: ["error": .string("sighted_window_closed"), "target": .string(target), "effects": .string("none")])
    }

    /// A stage of `actOnce` either answers the act or hands on what it found.
    enum ActOnceStep<Found> {
        case reply(MacFourVerbsReply)
        case ready(Found)
    }

    /// One named act's state once its name is resolved: the request as meant and what the sight found. The stages that answer a resolution
    /// read it; it lives for one call and never crosses isolation.
    final class ActOnce {
        let rawVerb: String
        let target: String
        let text: String?
        let mode: MacTypeMode
        let destination: String?
        let destinationApp: String?
        let seconds: Double?
        let holding: String?
        let rawButton: String?
        let scrollAmount: Int?
        let attention: BurstAttention?
        let app: String?
        let expect: FrontExpectation?
        let carry: SightCarry?
        let commitFollows: Bool
        let menus: Bool
        let place: MacImagePlace?
        let firstSighted: (label: String, kind: String, window: MacAXWindowIdentity)?
        let amount: Int
        let button: String?
        let direction: ScrollDirection
        let verb: MacActVerb
        let reobservedAfterTransientMiss: Bool
        let fromMemory: Bool
        let bareFields: [ActTarget]
        let bareFieldHit: Bool

        init(rawVerb: String, target: String, text: String?, mode: MacTypeMode, destination: String?, destinationApp: String?, seconds: Double?,
             holding: String?, rawButton: String?, scrollAmount: Int?, attention: BurstAttention?, app: String?, expect: FrontExpectation?,
             carry: SightCarry?, commitFollows: Bool, menus: Bool, place: MacImagePlace?,
             firstSighted: (label: String, kind: String, window: MacAXWindowIdentity)?, amount: Int, button: String?, direction: ScrollDirection,
             verb: MacActVerb, reobservedAfterTransientMiss: Bool, fromMemory: Bool, bareFields: [ActTarget], bareFieldHit: Bool) {
            self.rawVerb = rawVerb
            self.target = target
            self.text = text
            self.mode = mode
            self.destination = destination
            self.destinationApp = destinationApp
            self.seconds = seconds
            self.holding = holding
            self.rawButton = rawButton
            self.scrollAmount = scrollAmount
            self.attention = attention
            self.app = app
            self.expect = expect
            self.carry = carry
            self.commitFollows = commitFollows
            self.menus = menus
            self.place = place
            self.firstSighted = firstSighted
            self.amount = amount
            self.button = button
            self.direction = direction
            self.verb = verb
            self.reobservedAfterTransientMiss = reobservedAfterTransientMiss
            self.fromMemory = fromMemory
            self.bareFields = bareFields
            self.bareFieldHit = bareFieldHit
        }
    }

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
        /// The subject this act first resolved and the exact window it was sighted in, when it is looking again after the screen changed under
        /// that sighting: the second look acts only on that same subject, inside that same window.
        firstSighted: (label: String, kind: String, window: MacAXWindowIdentity)? = nil,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        let admitted: (rawButton: String?, target: String, amount: Int, button: String?, direction: ScrollDirection, verb: MacActVerb)
        switch await admitActOnce(verb: rawVerb, target: target, text: text, mode: mode, to: destination, toApp: destinationApp, seconds: seconds,
                                  holding: holding, button: rawButton, scrollAmount: scrollAmount, attention: attention, app: app, expect: expect,
                                  carry: carry, place: place, turn: turn, context: context) {
        case .reply(let reply): return reply
        case .ready(let ready): admitted = ready
        }
        // From here the target and button are the ones the request meant (a chord carried in text, right-click's button), as admitted.
        let rawButton = admitted.rawButton, target = admitted.target, verb = admitted.verb
        if let reply = await typeWithoutTarget(verb: verb, target: target, text: text, app: app, carry: carry, expect: expect,
                                               attention: attention, turn: turn, context: context) { return reply }

        let sighted: (sighting: Sighting, resolution: Resolution, reobservedAfterTransientMiss: Bool, fromMemory: Bool, bareFields: [ActTarget],
                    bareFieldHit: Bool)
        switch await sightAndResolve(verb: verb, rawVerb: rawVerb, target: target, text: text, mode: mode, app: app, expect: expect, carry: carry,
                                     attention: attention, firstSighted: firstSighted, turn: turn, context: context) {
        case .reply(let reply): return reply
        case .ready(let ready): sighted = ready
        }
        let once = ActOnce(rawVerb: rawVerb, target: target, text: text, mode: mode, destination: destination, destinationApp: destinationApp,
            seconds: seconds, holding: holding, rawButton: rawButton, scrollAmount: scrollAmount, attention: attention, app: app, expect: expect,
            carry: carry, commitFollows: commitFollows, menus: menus, place: place, firstSighted: firstSighted, amount: admitted.amount,
            button: admitted.button, direction: admitted.direction, verb: verb, reobservedAfterTransientMiss: sighted.reobservedAfterTransientMiss,
            fromMemory: sighted.fromMemory, bareFields: sighted.bareFields, bareFieldHit: sighted.bareFieldHit)
        switch sighted.resolution {
        case .none(let nearest):
            return await noMatchReply(once, sighting: sighted.sighting, nearest: nearest, turn: turn, context: context)

        case .ambiguous(let candidates):
            return ambiguousReply(once, sighting: sighted.sighting, candidates: candidates)

        case .hit(let candidate):
            return await actOnHit(once, sighting: sighted.sighting, candidate: candidate, turn: turn, context: context)
        }
    }

    /// When the front is required, explain the untouched state and how the caller can request it.
    static func needsFront(_ reason: String, app: String?, screen: String? = nil, delivered: Bool = false) -> MacFourVerbsReply {
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

    /// Read the act's request: the verb and its target as meant (a key chord carried in text, right-click's button), refusals for fields that
    /// cannot apply, and the routes that need no name (a delivered point, a physical verb). What it admits carries on as a named act.
    func admitActOnce(
        verb rawVerb: String, target: String, text: String?, mode: MacTypeMode, to destination: String?, toApp destinationApp: String?,
        seconds: Double?, holding: String?, button rawButton: String?, scrollAmount: Int?, attention: BurstAttention?, app: String?,
        expect: FrontExpectation?, carry: SightCarry?, place: MacImagePlace?, turn: Turn, context: MacOperationContext
    ) async -> ActOnceStep<(rawButton: String?, target: String, amount: Int, button: String?, direction: ScrollDirection, verb: MacActVerb)> {
        let rawButton = Self.isRightClick(rawVerb) ? "right" : rawButton
        let parsedVerb = Self.parseVerb(rawVerb)
        var verbName = parsedVerb.0
        let parsedDirection = parsedVerb.1
        if mode == .append, verbName != "type" || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .reply(MacFourVerbsReply(ok: false,
                text: "Append requires type and a named text target; nothing was typed.",
                detail: ["error": .string("append_requires_named_type")]))
        }
        // Press syntax must distinguish keyboard chords from named controls.
        if verbName == "press" { verbName = Self.pressMeansKey(target) ? "key" : "click" }
        // Key requests may carry the chord in text; background typing with an empty target uses the focused field.
        let target = verbName == "key" && (try? MacKeySyntax.parseChords(Self.keySpec(target) ?? target)) == nil
            && text.map(Self.pressMeansKey) == true ? text ?? target
            : target
        if app != nil {
            if PhysicalVerb(rawValue: verbName) != nil || place != nil {
                return .reply(Self.needsFront("\(verbName) moves the real pointer or keyboard, which only reaches the app in front", app: app))
            }
            if holding != nil || rawButton.map({ ["left", "right"].contains($0.lowercased()) }) == true {
                return .reply(Self.needsFront("held keys and explicit mouse buttons are real input, which only reaches the app in front", app: app))
            }
        }
        // `to_app` applies only to drag; refuse it before observing rather than silently acting in the wrong window.
        let namedDestinationApp = destinationApp
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let namedDestinationApp {
            guard place == nil else {
                return .reply(MacFourVerbsReply(ok: false,
                    text: "A point is in the window in front, so to_app doesn't apply to it. Nothing was sent.",
                    detail: ["error": .string("to_app_with_point")]))
            }
            guard verbName == PhysicalVerb.drag.rawValue else {
                return .reply(MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.verbNotDraggableWords(verbName),
                    detail: ["error": .string(MacCrossAppDrag.verbNotDraggableReason)]
                ))
            }
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .reply(MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.missingDestinationWords(namedDestinationApp),
                    detail: ["error": .string(MacCrossAppDrag.missingDestinationReason)]
                ))
            }
        }
        let amount = scrollAmount ?? 0
        guard (0...120).contains(amount), amount == 0 || verbName == "scroll" else {
            return .reply(MacFourVerbsReply(ok: false,
                text: "Scroll amount must be 1–120 lines, or 0 for the ordinary/default action. I haven't sent input.",
                detail: ["error": .string("invalid_scroll_amount")]))
        }
        let normalizedButton = rawButton?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Explicit auto preserves ordinary verbs in tool bindings that require every declared field.
        let button = normalizedButton == "auto" ? nil : normalizedButton
        if let button {
            guard MacMouseButton(rawValue: button) != nil,
                  ["click", "open", "double_click", "drag", "hold"].contains(verbName),
                  !(verbName == "hold" && Self.keySpec(target) != nil) else {
                return .reply(MacFourVerbsReply(
                    ok: false,
                    text: "Use auto for the ordinary action, or left/right on a click, open, drag, or pointer hold. I haven't sent input.",
                    detail: ["error": .string("invalid_mouse_button_action")]
                ))
            }
        }
        if let place {
            let reply = await context.holding(\.requiredFrontPid, expect?.pid) {
                context in await performAtPlace(place, verb: verbName, text: text, seconds: seconds, holding: holding, button: button,
                                     before: carry?.take(), attention: attention, turn: turn, context: context)
            }
            return .reply(Self.frontChangedWords(reply, verbName: verbName))
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
            return .reply(Self.frontChangedWords(reply, verbName: verbName))
        }
        guard let verb = MacActVerb(rawValue: verbName) else {
            return .reply(MacFourVerbsReply(
                ok: false,
                text: "I don't have a \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                    + "hand yet. What I can do: "
                    + Self.actionVerbs.joined(separator: ", ") + ".",
                detail: ["error": .string("unknown_verb"), "verb": .string(rawVerb)]
            ))
        }
        if verb == .type, (text ?? "").isEmpty {
            return .reply(MacFourVerbsReply(
                ok: false,
                text: "Nothing to type — give me the words and I'll put them in \"\(target)\".",
                detail: ["error": .string("missing_text")]
            ))
        }
        return .ready((rawButton, target, amount, button, direction, verb))
    }
    /// Explain when an intervening app switch refused the hand.
}
