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
// Blueprint: | `MacSemanticAct+Resolve.swift` | `MacFourVerbs`: `typeWithoutTarget`, `sightAndResolve`, `noMatchReply`, `ambiguousReply` (a named act's sight: targetless typing at focus, the fresh read held to its window, name resolution with motion samples, live-checked memory and bare fields; no match and ambiguity answer without acting) |
extension MacFourVerbs {
    /// A type with no target goes to whatever has keyboard focus, read fresh when no carried read is handed on.
    func typeWithoutTarget(verb: MacActVerb, target: String, text: String?, app: String?, carry: SightCarry?, expect: FrontExpectation?,
                           attention: BurstAttention?, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply? {
        // Targetless typing follows actual keyboard focus.
        if verb == .type, target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text {
            if app != nil { return Self.needsFront("typing at keyboard focus needs the app in front", app: app) }
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
        return nil
    }

    /// Look at the window (or take the carried read), hold the act to the window it must land in, then resolve the name: motion samples,
    /// remembered controls checked live, a bare field. What it resolves to decides the rest.
    func sightAndResolve(verb: MacActVerb, rawVerb: String, target: String, text: String?, mode: MacTypeMode, app: String?,
                         expect: FrontExpectation?, carry: SightCarry?, attention: BurstAttention?,
                         firstSighted: (label: String, kind: String, window: MacAXWindowIdentity)?, turn: Turn, context: MacOperationContext)
        async -> ActOnceStep<(sighting: Sighting, resolution: Resolution, reobservedAfterTransientMiss: Bool, fromMemory: Bool,
                              bareFields: [ActTarget], bareFieldHit: Bool)> {
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
                    if let expect, !PersonOnlyWindows.isOwnProcess(expect.pid) {
                        return .reply(MacFourVerbsReply(ok: false,
                            text: "Another app came to the front before I could act. Nothing was sent.",
                            detail: ["error": .string("owner_changed_apps"), "effects": .string("none")]))
                    }
                    return .reply(Self.ownAppRoute(verb: rawVerb, target: target, text: text))
                }
                if Self.isMenuPath(target), [.click, .open, .select, .toggle].contains(verb),
                   (app == nil && Self.string(reply.detail["error"]) == "no_frontmost_window")
                    || (app != nil && Self.windowlessApp(reply.detail)) {
                    return .reply(await menuPressNoWindow(target, app: app, frontPid: expect?.pid, turn: turn, context: context))
                }
                return .reply(reply)
            case .seen(let hit): sighting = hit
            }
        }
        // After raising, require both pid and window geometry so a same-app sibling cannot receive input.
        if let expect, sighting.pid != expect.pid
            || (expect.frame != nil && !MacAXWindowIdentity.rectsMatch(expect.frame, sighting.windowFrame)) {
            return .reply(MacFourVerbsReply(
                ok: false,
                text: "The front window changed before I could act (front_window_changed), so I haven't touched anything.\n"
                    + sighting.render,
                // Respect the person’s app switch; never cover it by restoring the agent’s target.
                detail: ["error": .string(sighting.pid != expect.pid ? "owner_changed_apps" : "front_window_changed")]
            ))
        }
        if let first = firstSighted, let outside = Self.outsideSightedWindow(first.window, sighting, target: target) { return .reply(outside) }
        // Explicit menu paths need no fuzzy control discovery.
        if Self.isMenuPath(target),
           let menu = await menuCommandReply(target, verb: verb, app: app, seen: sighting, turn: turn, context: context) {
            return .reply(menu)
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
            if let reply = acquisition.reply { return .reply(reply) }
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
                case .blind(let reply): return .reply(reply)
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return .reply(MacFourVerbsReply(
                            ok: false,
                            text: "The foreground app changed while I was observing motion. I haven't clicked.\n" + refreshed.render,
                            detail: ["error": .string("motion_sampling_app_changed")]
                        ))
                    }
                    sighting = refreshed
                    resolution = Self.resolve(target, among: refreshed.targets, pressing: [.click, .select, .toggle, .open].contains(verb))
                }
            }
        }
        // Motion samples read the screen again; a second look still resolves only in its first window.
        if let first = firstSighted, let outside = Self.outsideSightedWindow(first.window, sighting, target: target) { return .reply(outside) }
        // Use a remembered control only when fresh perception finds its kind and label at the stored path and it answers the name.
        var fromMemory = false
        if case .none = resolution, verb != .scroll {
            do {
                if let remembered = try await mapResolve(target, in: sighting) {
                    resolution = remembered
                    if case .hit = remembered { fromMemory = true }
                }
            } catch { return .reply(Self.appMapFailure(error)) }
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
        // A second look types only into its re-resolved subject, never into whatever has focus now.
        if mode == .replace, unanswered, verb == .type, let text, firstSighted == nil, Self.typesAtFocus(target, in: sighting) {
            if app != nil { return .reply(Self.needsFront("typing where the keyboard focus is takes real keystrokes", app: app, screen: sighting.render)) }
            let focused = sighting.targets.first { !$0.isSupplemental && $0.sourceAXPath == sighting.focusPath }
            return .reply(await typeKeystrokes(text, into: focused.map(Self.name) ?? "the focused element",
                                        before: sighting, expect: expect, attention: attention, turn: turn, context: context))
        }
        return .ready((sighting, resolution, reobservedAfterTransientMiss, fromMemory, bareFields, bareFieldHit))
    }

    /// Nothing answers the name: say what can be seen, any menu that has it, and when the window is too thin for names at all.
    func noMatchReply(_ once: ActOnce, sighting: Sighting, nearest: [String], turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        var line = "Nothing on this screen is called \"\(once.target)\"."
        if once.bareFields.count > 1 {
            line += " Fields here, none focused: " + once.bareFields.map(Self.recoveryName).joined(separator: " · ") + " — name one."
        } else if !nearest.isEmpty {
            line += " What I can see: " + nearest.joined(separator: " · ") + "."
        } else {
            line += " Nothing here is named at all — the screen below is everything I can read."
        }
        let hint = once.menus ? await menuHint(once.target, verb: once.verb, app: once.app ?? sighting.appName, turn: turn, context: context) : MenuHint()
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
                "target": .string(once.target),
                "dynamic_reobserved": .bool(once.reobservedAfterTransientMiss),
            ]) { _, new in new }
        )
    }

    /// More than one thing answers the name: ask which, naming each with the role that would select it.
    func ambiguousReply(_ once: ActOnce, sighting: Sighting, candidates: [ActTarget]) -> MacFourVerbsReply {
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
            text: "\(candidates.count) things match \"\(once.target)\": "
                + listed.joined(separator: ", ")
                + ". Which one? I haven't touched anything." + guidance + "\n" + sighting.render,
            detail: [
                "error": .string("ambiguous"),
                "target": .string(once.target),
                "candidates": .array(candidates.map(Self.candidateDetail)),
            ]
        )
    }
}
