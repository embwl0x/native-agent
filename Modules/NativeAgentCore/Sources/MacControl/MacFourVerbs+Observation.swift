import Foundation
import CoreGraphics
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `MacFourVerbs+Observation.swift` | `MacFourVerbs`, `screen`, `observedReply`, `visible`, `appBehindMe` |

extension MacFourVerbs {
    // MARK: 1 — EYES

    /// An app can be running without supplying a window for an act.
    static func windowlessApp(_ observation: [String: JSONValue]) -> Bool {
        observation["running"] == .bool(true) && observation["windows"] == .int(0)
    }

    static func runningAppsLine(_ output: [String: JSONValue]) -> String {
        guard case .array(let running)? = output["running_apps"] else { return "" }
        let names = running.compactMap { value -> String? in
            let row = object(value)
            return string(row["name"]).map { $0 + (row["front"] == .bool(true) ? " (frontmost)" : "") }
        }
        let omitted = int(output["running_apps_omitted"]) ?? 0
        return "Running apps: " + names.joined(separator: ", ")
            + (omitted > 0 ? " (+\(omitted) more)" : "") + "\n"
    }

    /// Keep stable ordinals through zoom so the same printed address cannot silently retarget a control.
    public func screen(part: String? = nil, app: String? = nil, structured: Bool = false, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        // The menu bar belongs to the app, not the window, so the window read never spends its budget there; `part: menu` reads it on purpose.
        if let part, ["menu", "menus", "menu bar"].contains(Self.normalize(part)) {
            var body: [String: JSONValue] = [:]
            if let app { body["app"] = .string(app) }
            let result: MacControlResult
            do { result = try await host.dispatch(action: "menu", body: body, turn: turn, context: context) } catch {
                return MacFourVerbsReply(ok: false, text: "I couldn't read that app's menu bar: \(error).",
                                         detail: ["error": .string("menu_unavailable"), "message": .string("\(error)")])
            }
            guard result.ok else {
                if result.error == "app_not_running", let app {
                    // The menu reader keeps its strict target precondition; through look, a stopped app is an observation of absence.
                    let message = Self.string(Self.object(result.output)["message"]) ?? "\(app) is not running."
                    return MacFourVerbsReply(ok: true, text: message + " Nothing was launched or opened.",
                        detail: ["status": .string("ok"), "app": .string(app), "running": .bool(false)])
                }
                return MacFourVerbsReply(ok: false, text: "I couldn't read that app's menu bar: "
                    + (Self.string(Self.object(result.output)["message"]) ?? result.error ?? "the Mac refused the read") + ".",
                    detail: Self.operationDetail(result).merging(["error": .string("menu_unavailable")]) { current, _ in current })
            }
            let output = Self.object(result.output)
            let rows = Self.array(output["paths"]).compactMap { row -> String? in
                let item = Self.object(row)
                guard let path = Self.string(item["path"]) else { return nil }
                let enabled = Self.bool(item["enabled"])
                return path + (enabled == false ? "  (greyed out)" : enabled == true ? "" : "  (enabled state unavailable)")
            }
            let name = Self.string(Self.object(output["app"])["name"]) ?? "The app"
            return MacFourVerbsReply(
                ok: true,
                text: "\(name)'s menus, read without opening anything (press one with app mac.menu_press, or menu_press where that is your tool)"
                    + (output["enabled_state"] != nil ? "; which are greyed out is unknown until it's in front" : "")
                    + ":\n"
                    + rows.joined(separator: "\n"),
                detail: ["menu_items": .int(Int64(rows.count))]
            )
        }
        switch await sight(part: part, app: app, requiresWindow: false, turn: turn, context: context) {
        case .blind(let reply):
            return reply
        case .seen(let sighting):
            let contentRoute = MacIntegrationID.owning(appBundleID: sighting.bundleIdentifier ?? "")
                .flatMap { [MacIntegrationID.mail: "mail.*", MacIntegrationID.messages: "messages.*", MacIntegrationID.notes: "notes.*"][$0] }
            var lead = "Looking at " + sighting.place + "."
            if let part, let note = sighting.zoomNote {
                lead = "Zoomed on \"\(part)\" in " + sighting.place + ". " + note
            }
            if app != nil {
                lead += " I read it where it sits — nothing was brought to the front."
            }
            return MacFourVerbsReply(
                ok: true,
                text: (sighting.detail["native_page"] != nil ? sighting.render : lead + "\n" + sighting.render)
                    + (contentRoute.map { "\nUse \($0) for content; this is only the on-screen view." } ?? ""),
                detail: (structured
                    ? sighting.detail.merging(["controls": sighting.controls]) { _, new in new }
                    : sighting.detail.filter { $0.key != "native_page" }
                ).merging(MacPersonInput.idleDetail) { _, new in new }
            )
        }
    }

    func observedReply(
        result: MacControlResult,
        description: String,
        unverifiedDescription: String? = nil,
        before: Sighting?,
        afterPart: String? = nil,
        pointerTarget: String? = nil,
        /// Use the shared press judge so pointer and semantic actions require the same target-owned effect evidence.
        pressed: ActTarget? = nil,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply {
        switch await sight(part: afterPart, turn: turn, context: context) {
        case .blind(let reply):
            let output = Self.object(result.output)
            return MacFourVerbsReply(
                ok: output["status"] != .string("acted_mismatch"),
                text: (output["verified"] == .bool(true) ? description : unverifiedDescription ?? description)
                    + " " + (Self.string(output["status_note"])
                        ?? "The input went out, but the declared effect could not be read back.")
                    + " I couldn't take the fresh screen look. " + reply.text,
                detail: Self.operationDetail(result).merging(["observed_after": .bool(false)]) { current, _ in current }
            )
        case .seen(let after):
            let mechanism = Self.object(result.output)
            var detail = Self.operationDetail(result)
            detail["observed_after"] = .bool(true)
            // The fresh screen is a witness only. Verification comes from the declared effect's AX readback, never a render or pixel delta.
            detail["screen_changed"] = before.map { .bool($0.effectRender != after.effectRender) } ?? .null
            var verdict: MacActClosedLoop.ActClassification?
            if let pointerTarget, let before {
                let inside = before.pid != nil && before.pid == after.pid
                    ? after.pointer.flatMap { pointer -> Bool? in
                        guard case .hit(let target) = Self.resolve(pointerTarget, among: after.targets),
                              let frame = target.observedFrame else { return nil }
                        return pointer.isInside(frame) && !target.excludedFrames.contains { pointer.isInside($0) }
                    } : nil
                verdict = MacActClosedLoop.verify(.pointer, pointerOnTarget: inside)
                detail["pointer_on_target"] = inside.map(JSONValue.bool) ?? .null
            } else if let pressed, let before, mechanism["verified"] != .bool(true) {
                verdict = await Self.pressVerdict(pressed, before: before, after: after) {
                    if case .seen(let again) = await sight(part: afterPart, turn: turn, context: context) { return again.percept }
                    return nil
                }
            }
            if let verdict { detail.merge(verdict.receipt) { _, new in new } }
            let verified = detail["verified"] == .bool(true)
            let note = Self.string(detail["status_note"])
                ?? "The input went out, but the declared effect could not be read back."
            let neutral = mechanism["holding"] != nil && mechanism["holding"] != .null
                && mechanism["hand_neutral"] == .bool(true)
                ? " The held keys were released and the hand returned neutral." : ""
            return MacFourVerbsReply(
                ok: detail["status"] != .string("acted_mismatch"),
                text: (verified ? description : unverifiedDescription ?? description)
                    + " " + note + neutral + "\n" + after.render, detail: detail)
        }
    }

    /// Pointer and AX presses declare the same surface effect, judged from AX. Only target-linked content counts; an unrelated screen delta cannot prove the
    /// press. A target-linked readout also has to read the same again: when it is the only evidence, the screen is looked at once more.
    static func pressVerdict(
        _ pressed: ActTarget, before: Sighting, after: Sighting, again: () async -> MacLookPercept?
    ) async -> MacActClosedLoop.ActClassification {
        guard before.pid != nil, before.pid == after.pid,
              let beforePercept = before.percept, let afterPercept = after.percept else {
            return MacActClosedLoop.verify(.surface(nil))
        }
        func caps(_ percept: MacLookPercept) -> MacLookCompileCaps {
            MacLookCompileCaps(truncated: percept.truncated || percept.affordancesOmitted > 0)
        }
        let frame = MacLookFrame.from(percept: beforePercept, frameId: before.frameId, capturedAt: Date(),
                                      windowTitle: beforePercept.windowTitle, caps: caps(beforePercept))
        guard let entry = frame.entries[pressed.handle] else { return MacActClosedLoop.verify(.surface(nil)) }
        let diff = MacActClosedLoop.diff(before: frame, after: afterPercept,
                                         afterWindowTitle: afterPercept.windowTitle, afterCaps: caps(afterPercept))
        func texts(_ percept: MacLookPercept) -> [String: String] {
            Dictionary(percept.readouts.map { (MacLookReadoutRecord.key(handle: $0.handle, path: $0.path), $0.text) }) { first, _ in first }
        }
        var held: [String: String] = [:]
        if !diff.readoutsChanged.isEmpty,
           !MacActClosedLoop.pressEvidence(diff, before: frame, pressed: entry, settled: { _ in false }).consequence,
           let again = await again() {
            let read = texts(afterPercept)
            held = texts(again).filter { read[$0.key] == $0.value }
        }
        return MacActClosedLoop.verify(.surface(nil), diff: diff, press: (frame, entry, { row in
            held[MacLookReadoutRecord.key(handle: row.handle, path: row.path)] != nil
        }))
    }

    // MARK: - One sighting

    /// Keep one call's render and target bookkeeping together without persisting handles across calls. Windowless looks remain valid observations; acts still
    /// require a window.
    enum Sighted {
        case seen(Sighting)
        case blind(MacFourVerbsReply)
    }

    struct Sighting {
        let render: String
        /// Match waits against screen content only; app lists, provenance and frame IDs are not app-state changes.
        let effectRender: String
        let pointer: MacPointerPosition?
        let place: String
        let appName: String?
        let bundleIdentifier: String?
        /// The observed pid for `wait`; nil reports no observer rather than guessing a process.
        let pid: Int32?
        /// Measured front state for anchored looks; cross-app drag uses it to decide whether to raise.
        let isFront: Bool
        let visibleFrame: MacAXFrame?
        /// The anchored window's own frame, or nil; target unions and usable screen area cannot establish its coverage.
        let windowFrame: MacAXFrame?
        let targets: [ActTarget]
        let frameId: String
        let zoomNote: String?
        /// Already-redacted canonical handles, used by the workspace to bind selections. Normal prose screen calls do not emit this extra data.
        let controls: JSONValue
        let detail: [String: JSONValue]
        /// Use window kind for map identity so content titles cannot enter its key.
        var windowKind: String? = nil
        /// Focus shares target sourceAXPath ordering so it names an element in this same observation.
        var focusPath: [Int]? = nil
        /// Track editability explicitly because the rendered text kind also includes noneditable labels.
        var editableHandles: Set<String> = []
        /// Keyboard focus may be (or is) a password field. Unknown counts as secure.
        var focusSecure: Bool = true
        /// Other apps' windows over this one, in screen points: a hand landing on one would reach that app, so no physical act ends or passes there.
        var obstructions: [MacAXFrame] = []
        /// The look this sighting was read from, so a pointer press is judged by the same evidence as an accessibility one.
        var percept: MacLookPercept? = nil
    }

    /// A resolvable thing on the screen. `label` is the DISPLAY text — what the renderer printed — so anything redaction withheld cannot be named.
    struct ActTarget: Equatable {
        var actions: [String]
        let settableAttributes: [String]
        let sourceAXPath: [Int]?
        let handle: String
        var label: String?
        /// Additional exact natural names for this SAME target. These never create a second address or carry a second handle; they let transient state such as
        /// keyboard focus name the element already in the model.
        var aliases: [String]
        let kind: String
        let secret: Bool
        /// Use the ordinal printed by the renderer so selection cannot address another content row.
        let ordinal: Int?
        /// A stable one-based ordinal within this target's visible kind. This is how repeated unnamed controls remain addressable as `button 2` without
        /// pretending that one of them is uniquely named.
        let roleOrdinal: Int?
        let enabled: Bool?
        let frame: MacAXFrame?
        let observedFrame: MacAXFrame?
        let excludedFrames: [MacAXFrame]
        let viewId: String?
        let mark: Int?
        let regionOnly: Bool
        let physicalOnly: Bool
        let motionUncertain: Bool
        /// Placeholders name fields only after exact screen labels so a secondary name cannot hide a visible target.
        var placeholder: String? = nil

        // Keep the semantic handle after fusion so destination/readback verification survives physical enrichment. Frame/mark evidence adds gestures without
        // creating another semantic address.
        var isSupplemental: Bool { handle.isEmpty }

        init(
            handle: String,
            label: String?,
            aliases: [String] = [],
            kind: String,
            secret: Bool = false,
            ordinal: Int?,
            roleOrdinal: Int? = nil,
            enabled: Bool?,
            frame: MacAXFrame? = nil,
            observedFrame: MacAXFrame? = nil,
            excludedFrames: [MacAXFrame] = [],
            viewId: String? = nil,
            mark: Int? = nil,
            regionOnly: Bool = false,
            physicalOnly: Bool = false,
            motionUncertain: Bool = false,
            sourceAXPath: [Int]? = nil,
            actions: [String] = [],
            settableAttributes: [String] = []
        ) {
            self.handle = handle
            self.actions = actions
            self.settableAttributes = settableAttributes
            self.sourceAXPath = sourceAXPath
            self.label = label
            self.aliases = aliases
            self.kind = kind
            self.secret = secret || MacCrossAppDrag.isSecureKind(kind)
            self.ordinal = ordinal
            self.roleOrdinal = roleOrdinal
            self.enabled = enabled
            self.frame = frame
            self.observedFrame = observedFrame ?? frame
            self.excludedFrames = excludedFrames
            self.viewId = viewId
            self.mark = mark
            self.regionOnly = regionOnly
            self.physicalOnly = physicalOnly
            self.motionUncertain = motionUncertain
        }
    }

    static func ownAppRoute(verb: String? = nil, target: String = "", text: String? = nil) -> MacFourVerbsReply {
        var input: [String: JSONValue] = ["page": .string("visible")]
        let verb = verb?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var executable = verb == nil
        if verb == "type", ["composer", "message", "message box", "draft"].contains(target), let text {
            input = ["action": .string("chat.draft"), "args": .object(["value": .string(text)])]
            executable = true
        } else if let verb, ["click", "navigate", "open"].contains(verb) {
            // The app resolves page names against its canonical rail catalog.
            input = ["action": .string("page.show"), "args": .object(["page": .string(target)])]
            executable = true
            if ["send", "send button"].contains(target) {
                input = ["action": .string("chat.send")]
            } else if let card = ["trust", "model", "think", "context"].first(where: {
                target == $0 || target == "\($0) card"
            }) {
                input = ["action": .string("chat.open_card"), "args": .object(["card": .string(card)])]
            }
        }
        // Self-front looks read the agent's own page and name the person's app behind it so callers can look past the app without guessing.
        let behind = verb == nil ? Self.appBehindMe().map {
            "NativeAgent (me) is in front; the person's app behind me is \($0): mac.look {app:\"\($0)\"} reads it, with pixels:true for its picture."
        } : nil
        return MacFourVerbsReply(
            ok: false,
            text: """
                This is my own app. Use app with the input in next_action to \
                \(executable ? "work in process" : "inspect its available controls; this gesture has no in-process equivalent").
                """,
            detail: ["status": .string("in_process_route"),
                     "execute_in_process": .bool(executable),
                     "behind": behind.map(JSONValue.string) ?? .null,
                     "next_action": .object(["tool": .string("app"), "input": .object(input)])]
        )
    }

    /// Use topmost nonself window ownership to name the app behind; owner names need no Screen Recording grant, and no window stays nil.
    static func appBehindMe() -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = getpid()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let name = window[kCGWindowOwnerName as String] as? String,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            return name
        }
        return nil
    }

    /// Keep temporal evidence and both drag endpoints in the same fresh sight.
    func reacquireSight(
        for target: String,
        sighting: inout Sighting,
        turn: Turn, context: MacOperationContext, whileMissing: ([ActTarget]) -> Bool) async -> (reply: MacFourVerbsReply?, samples: Int) {
        guard Self.isPotentialDynamicVisualReference(target) else { return (nil, 0) }
        let temporal = Self.hasTemporalQualifier(target)
        let sampledApp = sighting.bundleIdentifier ?? sighting.appName
        var previousTargets = sighting.targets
        var samples = 0
        for sample in 0..<(temporal ? 3 : 1) {
            guard whileMissing(sighting.targets) else { break }
            if sample == 2, !Self.canConfirmTemporalTurn(target, previous: previousTargets, current: sighting.targets) { break }
            switch await resampleSight(temporal: temporal, expectedApp: sampledApp, turn: turn, context: context) {
            case .blind(let reply): return (reply, samples)
            case .seen(let refreshed):
                previousTargets = sighting.targets
                sighting = refreshed
                samples += 1
            }
        }
        return (nil, samples)
    }

    func resampleSight(temporal: Bool, expectedApp: String?, turn: Turn, context: MacOperationContext) async -> Sighted {
        if temporal { await clock.sleep(seconds: 0.06) }
        let observed = await sight(part: nil, turn: turn, context: context)
        if case .seen(let refreshed) = observed,
           (refreshed.bundleIdentifier ?? refreshed.appName) != expectedApp {
            return .blind(Self.motionAppChangedReply(screen: refreshed.render))
        }
        return observed
    }

    private static func motionAppChangedReply(screen: String) -> MacFourVerbsReply {
        MacFourVerbsReply(ok: false,
            text: "The foreground app changed while I was observing motion. I haven't sent input.\n" + screen,
            detail: ["error": .string("motion_sampling_app_changed")])
    }

}
