import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `MacFourVerbs+ScreenPresentation.swift` | `MacFourVerbs`: supplemental AX native-page merge, `zoom`, `parseVerb`, `isRightClick` |

extension MacFourVerbs {
    /// Merge every acquired pathless AX surface (notably open menus) into the
    /// native representation, ahead of the document; the window compiler owns
    /// every window-relative row. Pixel evidence stays with its own renderer.
    static func addingNativeAX(_ supplement: MacFourVerbsSupplement, to page: inout NativePage,
                               blocks: inout [[String: JSONValue]], targets: [ActTarget], frameID: String) throws {
        let bundle = if case .app(let bundle) = page.corner { bundle } else { "*" }
        var additions: [([String: JSONValue], NativeThing?)] = []
        func add(_ text: String, thing: NativeThing? = nil, target: String? = nil) {
            var block: [String: JSONValue] = ["text": .string(text), "path": .array([])]
            if let thing { block["address"] = .string(thing.address) }
            if let target { block["target"] = .string(target) }
            additions.append((block, thing))
        }
        for value in supplement.values where !value.provenance.isVision {
            add(value.text.display ?? (value.text.withheld ? "⟨redacted⟩" : ""))
        }
        var represented = Set(page.things.map(\.address))
        var usedControls: Set<Int> = []
        for candidate in supplement.targets where !candidate.provenance.isVision {
            // The complete window compiler owns window-relative AX rows,
            // including deliberately folded wrappers/decorations. A second
            // mark list cannot reintroduce their discarded action handles.
            // Pathless menus/popovers remain independent supplemental surfaces.
            if candidate.sourceAXPath != nil { continue }
            guard candidate.role != nil,
                  let index = supplementalDuplicateIndex(candidate, among: targets) else {
                // Still on screen: readable content, offered without verbs
                // because it cannot be bound to exactly one acting target.
                if let label = candidate.label?.display ?? (candidate.label?.withheld == true ? "⟨redacted⟩" : nil) {
                    add(label)
                }
                continue
            }
            let target = targets[index]
            let selector = target.roleOrdinal.map { "\(target.kind) \($0)" } ?? target.label
            let address: String
            if !target.handle.isEmpty {
                address = try JSONValue.object(["app": .string(bundle), "frame_id": .string(frameID),
                    "handle": .string(target.handle)]).serialize(pretty: false)
            } else if let selector {
                // Native popup items have no window handle or view mark.
                // Their existing action mechanism resolves a current target;
                // never invent a window-relative AX path for them.
                var selection: [String: JSONValue] = ["app": .string(bundle), "__sense_screen_frame": .string(frameID),
                    "target": .string(selector)]
                if let label = target.label { selection["label"] = .string(label) }
                address = try JSONValue.object(selection).serialize(pretty: false)
            } else {
                if let label = target.label { add(label) }
                continue
            }
            let controlIndex = supplement.controls.indices.first { index in
                let control = supplement.controls[index]
                return !usedControls.contains(index) && control.provenance == .ax && control.sourceAXPath == candidate.sourceAXPath
                    && control.kind == candidate.kind && control.label == candidate.label
            }
            let control = controlIndex.map { supplement.controls[$0] }
            if let controlIndex { usedControls.insert(controlIndex) }
            guard represented.insert(address).inserted else {
                // A popup can also appear inside the window tree. Move its
                // existing representation to the front, retaining its handle.
                if let existing = blocks.firstIndex(where: {
                    Self.string($0["text"])?.contains("[" + SenseScreenThings.printed(address) + "]") == true
                }) {
                    additions.append((blocks.remove(at: existing), nil))
                }
                continue
            }
            let row = supplement.contents.flatMap(\.rows).first {
                $0.provenance == .ax && $0.sourceAXPath == candidate.sourceAXPath && $0.label == candidate.label
            }
            var details = control?.states ?? []
            if let value = control?.value?.display { details.append(value) }
            details += row?.detail.compactMap(\.display) ?? []
            if !target.enabled, !details.contains("disabled") { details.append("disabled") }
            if target.secret { details.append("secure") }
            if let abstain = control?.abstain ?? row?.abstain { details.append(abstain) }
            let name = target.label ?? (candidate.label?.withheld == true ? "⟨redacted⟩" : selector ?? target.kind)
            let verbs = target.enabled && control?.abstain == nil && row?.abstain == nil
                ? Self.nativeAXVerbs(target) : []
            let detail = details.isEmpty ? nil : details.joined(separator: "; ")
            let thing = NativeThing(name: name, kind: target.kind, address: address, detail: detail, verbs: verbs)
            add("\(name) (\(target.kind)) [\(SenseScreenThings.printed(address))]"
                + (detail.map { ": " + $0 } ?? "")
                + (verbs.isEmpty ? "" : " · " + verbs.joined(separator: ", ")),
                thing: thing, target: target.handle.isEmpty ? selector : nil)
        }
        guard !additions.isEmpty else { return }
        add("Supplemental native surfaces were read through accessibility; their named targets are re-observed before acting.")
        // Insert backwards at the same position so acquisition order is retained.
        for (block, thing) in additions.reversed() {
            blocks.insert(block, at: min(2, blocks.count))
            if let thing { page.things.append(thing) }
        }
        page.text = blocks.compactMap { Self.string($0["text"]) }.joined(separator: "\n")
        let positions = page.things.reduce(into: [String: String.Index]()) { positions, thing in
            positions[thing.address] = page.text.range(of: "[" + SenseScreenThings.printed(thing.address) + "]")?.lowerBound
        }
        page.things.sort {
            (positions[$0.address] ?? page.text.endIndex) < (positions[$1.address] ?? page.text.endIndex)
        }
    }

    /// Publish capabilities of the exact route retained by fusion. A region
    /// cannot be pressed, even when its AX mark advertises AXPress. Mark-only
    /// dispatch supports AXPress and AXValue; handle dispatch also supports
    /// focus and typing into a focusable editor. Selection invokes AXPress,
    /// so a writable selection attribute alone cannot authorize that verb.
    /// Physical scrolling needs a safe frame.
    static func nativeAXVerbs(_ target: ActTarget) -> [String] {
        let scrollable = target.frame != nil && (target.regionOnly || Self.physicalScrollKinds.contains(target.kind))
            || (!target.isSupplemental && target.actions.contains("AXScrollToVisible"))
        if target.regionOnly { return scrollable ? ["scroll"] : [] }
        var verbs: [String] = []
        if target.actions.contains("AXPress") { verbs.append("press") }
        if target.physicalOnly { return verbs + (scrollable ? ["scroll"] : []) }
        if !target.secret, Self.keystrokeEditableKinds.contains(target.kind),
           target.settableAttributes.contains("AXValue")
            || (!target.isSupplemental && target.settableAttributes.contains("AXFocused")) { verbs.append("type") }
        if !target.isSupplemental {
            if target.actions.contains("AXPress"), target.settableAttributes.contains("AXSelected") { verbs.append("select") }
            if target.settableAttributes.contains("AXFocused") { verbs.append("focus") }
        }
        if scrollable { verbs.append("scroll") }
        return verbs
    }

    // MARK: - Zoom

    struct Zoom {
        enum Scope { case whole, controls, readouts, visual }
        let screen: MacScreenRender.Screen
        let note: String
        let scope: Scope

        init(screen: MacScreenRender.Screen, note: String, scope: Scope = .whole) {
            self.screen = screen; self.note = note; self.scope = scope
        }
    }

    /// Scoping, WITHOUT renumbering. Controls carry no ordinals, so a control
    /// zoom filters them; content rows carry the addresses she acts with, so a
    /// content zoom names the matching ordinals instead of
    /// dropping their neighbours.
    static func zoom(
        _ screen: MacScreenRender.Screen,
        part: String
    ) -> Zoom? {
        let needle = normalize(part)
        guard !needle.isEmpty else { return nil }

        // A visual world is a first-class screen section, not browser chrome.
        // Without this branch, "the open X canvas" can fuzzy-match the tab
        // named X and hide the pixel regions the agent actually asked to see,
        // forcing another full-screen/provider round before acting.
        let words = Set(needle.split(separator: " ").map(String.init))
        let asksForVisualSurface = words.contains("canvas")
            || words.contains("world")
            || words.contains("viewport")
            || needle.contains("visual surface")
        if asksForVisualSurface,
           screen.contents.contains(where: { $0.kind == .canvas }) {
            let visualContents = screen.contents.filter { content in
                content.kind == .canvas || content.rows.contains { $0.provenance.isVision }
            }
            let visualControls = screen.controls.filter { $0.provenance.isVision }
            let visualRows = visualContents.reduce(0) { $0 + $1.rows.count }
            let scoped = MacScreenRender.Screen(
                appName: screen.appName,
                windowTitle: screen.windowTitle,
                isFront: screen.isFront,
                otherWindows: screen.otherWindows,
                provenance: screen.provenance,
                modal: screen.modal,
                whereSteps: screen.whereSteps,
                contents: visualContents,
                controls: visualControls,
                totalControls: visualControls.count,
                unlabeledControls: [:],
                values: screen.values,
                totalValues: screen.totalValues,
                unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
            )
            return Zoom(
                screen: scoped,
                note: "Visual surface retained with \(visualRows + visualControls.count) interpreted region"
                    + (visualRows + visualControls.count == 1 ? "" : "s")
                    + "; surrounding controls omitted.",
                scope: .visual
            )
        }

        let asksForControls = ["controls", "actions", "actionable controls"].contains(needle)
        let matchingControls = asksForControls ? screen.controls
            : screen.controls.filter { matches(needle, $0.label.display, kind: $0.kind) }
        let matchingRows = screen.contents.flatMap { content in
            content.rows.enumerated().filter { matches(needle, $0.element.label?.display, kind: nil) }
                .map { $0.offset + 1 }
        }

        let asksForReadouts = ["hud", "the hud", "values", "readouts", "status text"].contains(needle)
        let matchingValues = asksForReadouts ? screen.values : screen.values.filter {
            matches(needle, $0.text.display, kind: nil)
        }
        if asksForReadouts || (!matchingValues.isEmpty && matchingControls.isEmpty && matchingRows.isEmpty) {
            let scoped = MacScreenRender.Screen(
                appName: screen.appName, windowTitle: screen.windowTitle, isFront: screen.isFront,
                otherWindows: screen.otherWindows, provenance: screen.provenance,
                modal: screen.modal, whereSteps: screen.whereSteps,
                values: matchingValues, totalValues: asksForReadouts ? screen.totalValues : matchingValues.count,
                unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
            )
            return Zoom(screen: scoped, note: "\(matchingValues.count) observed readout\(matchingValues.count == 1 ? "" : "s") match; surrounding controls omitted.", scope: .readouts)
        }

        if asksForControls || (!matchingControls.isEmpty && matchingRows.isEmpty) {
            let scoped = MacScreenRender.Screen(
                appName: screen.appName,
                windowTitle: screen.windowTitle,
                isFront: screen.isFront,
                otherWindows: screen.otherWindows,
                provenance: screen.provenance,
                modal: screen.modal,
                whereSteps: screen.whereSteps,
                contents: [],
                controls: matchingControls,
                totalControls: asksForControls ? screen.totalControls : matchingControls.count,
                unlabeledControls: asksForControls ? screen.unlabeledControls : [:],
                values: screen.values,
                totalValues: screen.totalValues,
                unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
            )
            return Zoom(
                screen: scoped,
                note: "\(matchingControls.count) of \(screen.totalControls) actionable match"
                    // A capped read is not the whole window: say what it left out.
                    + (asksForControls && screen.unclassifiedOmittedTargets > 0
                        ? " (\(screen.unclassifiedOmittedTargets) more weren't kept in this read; name one and I'll find it)"
                        : "")
                    + "; the rest of the screen is unchanged.",
                scope: .controls
            )
        }

        // Content zoom: the whole section, ordinals intact.
        if matchingRows.isEmpty {
            return Zoom(
                screen: screen,
                note: "Nothing here is named \"\(part)\" — this is the whole screen."
            )
        }
        return Zoom(
            screen: screen,
            note: "Matching row\(matchingRows.count == 1 ? "" : "s"): "
                + matchingRows.map(String.init).joined(separator: ", ") + "."
        )
    }

    // MARK: - Words

    enum ScrollDirection: String {
        case up, down, left, right
        var isHorizontal: Bool { self == .left || self == .right }
    }

    static func parseVerb(_ raw: String) -> (String, ScrollDirection) {
        let words = normalize(raw).split(separator: " ").map(String.init)
        // The words an agent naturally reaches for name the same verbs.
        let synonyms = ["set": "type", "fill": "type", "enter": "type", "choose": "select", "pick": "select", "tap": "click", "menu": "click", "chord": "key", "shortcut": "key", "keys": "key"]
        // A person right-clicks and double-clicks: "right_click" is a click
        // with the right button (see isRightClick), "double click" its own hand.
        let joined = words.joined(separator: "_").replacingOccurrences(of: "-", with: "_")
        let head = isRightClick(raw) ? "click"
            : ["double_click", "doubleclick", "dbl_click"].contains(joined) ? "double_click"
            : words.first.map { synonyms[$0] ?? $0 } ?? ""
        let direction: ScrollDirection = words.contains("up") ? .up
            : words.contains("left") ? .left : words.contains("right") ? .right : .down
        return (head, direction)
    }

    static func isRightClick(_ raw: String) -> Bool {
        let joined = normalize(raw).split(separator: " ").joined(separator: "_").replacingOccurrences(of: "-", with: "_")
        return ["right_click", "rightclick", "secondary_click", "context_click"].contains(joined)
    }

    static func pastTense(_ verb: MacActVerb, direction: ScrollDirection) -> String {
        switch verb {
        case .click: return "Clicked"
        case .open: return "Opened"
        case .type: return "Typed into"
        case .focus: return "Focused"
        case .select: return "Selected"
        case .toggle: return "Toggled"
        case .dismiss: return "Dismissed"
        case .scroll: return "Scrolled \(direction.rawValue) in"
        }
    }

    static func attempted(_ verb: MacActVerb, direction: ScrollDirection) -> String {
        switch verb {
        case .scroll: return "Tried to scroll \(direction.rawValue) in"
        default: return "Tried to \(verb.rawValue)"
        }
    }

    static func obstructedPointReply(screen: String) -> MacFourVerbsReply {
        MacFourVerbsReply(ok: false,
            text: "That point is covered by a foreground window; I haven't sent input. Name a clear part of the surface or move the obstruction first.\n" + screen,
            detail: ["error": .string("target_point_obstructed")])
    }

    struct EffectWords {
        let sentence: String
        let status: String
    }

    /// Carry the one verifier's sentence without judging the screen again.
    static func effectWords(output: [String: JSONValue]) -> EffectWords {
        let status = string(output["status"]) ?? "acted_unobserved"
        return EffectWords(
            sentence: string(output["status_note"]) ?? string(output["guidance"])
                ?? "The input went out, but the declared effect could not be read back.",
            status: status)
    }

    /// Present the action owner's refusal code; a fresh screen follows the reply.
    static func refusalWords(_ code: String) -> String {
        switch code {
        case "window_not_key":
            return "another window has the keyboard right now, so the keystroke would have gone "
                + "somewhere else — nothing was sent."
        case "handle_drifted", "window_drifted":
            return "the screen moved while I was reaching for it — nothing was touched."
        case "frame_window_gone", "frame_app_gone":
            return "what I was looking at isn't there any more — nothing was touched."
        case "verb_not_supported_on_element":
            return "that control does not support this action. Use mac.look for this app to inspect its controls and supported actions."
        case "observer_unavailable":
            return "I couldn't watch that app for the effect, so I didn't press anything blind."
        default:
            return "it refused: \(code)."
        }
    }

    static func inspectAppRemedy(_ app: String?, instruction: String) -> JSONValue {
        let args: [String: JSONValue] = app.map { ["app": .string($0)] } ?? [:]
        return Repair.reconcile(instruction: instruction, nextCall: .object([
            "tool": .string("app"), "input": .object([
                "action": .string("mac.look"), "args": .object(args),
            ]),
        ]))
    }

    static func unknownActionReply(_ error: any Error, operation: String = "the action", app: String?) -> MacFourVerbsReply {
        let cause = error.localizedDescription
        let evidence = error as? ToolFailureError
        let effects = evidence?.effects ?? .unknown
        let status = evidence?.status.rawValue ?? (error is CancellationError ? "cancelled" : "outcome_unknown")
        let outcome = effects == .none ? "\(operation) stopped" : "The outcome of \(operation) is unknown"
        let code = evidence?.code ?? (error is CancellationError ? "cancelled" : "mac_action_result_unavailable")
        var remedy = inspectAppRemedy(app, instruction: "Inspect the affected app to establish what changed before another action.")
        if let evidence, effects == .none {
            if evidence.recovery == .terminal {
                remedy = Repair.terminal(instruction: evidence.instruction ?? cause)
            } else if evidence.personDecides, let tap = evidence.tap {
                remedy = Repair.why(owner: evidence.owner ?? "Mac action", tap: tap, instruction: evidence.instruction)
            } else if let next = evidence.nextCall, let call = try? JSONValue.parse(Data(next.utf8)), case .object = call {
                remedy = .object(["kind": .string(evidence.recovery?.rawValue ?? "inspect"),
                    "instruction": .string(evidence.instruction ?? cause), "next_call": call])
            } else if let tap = evidence.tap {
                remedy = Repair.why(owner: evidence.owner ?? "Mac action", tap: tap, instruction: evidence.instruction)
            }
        }
        return MacFourVerbsReply(ok: false,
            text: "\(outcome): \(cause)\nInspect \(app ?? "the affected app") before another action.",
            detail: ["status": .string(status),
                "reason": .string(code), "error": .string(code),
                "detail": .string(cause), "message": .string(cause), "effects": .string(effects.rawValue),
                "outcome_unknown": .bool(effects != .none),
                "remedy": remedy])
    }

    static func lookRefusalWords(_ code: String) -> String {
        switch code {
        case "no_frontmost_window": return "There's no window up to look at."
        case "accessibility_not_trusted", "ax_untrusted", "accessibility_untrusted":
            return "Accessibility isn't granted to NativeAgent. System Settings > Privacy & Security > Accessibility > NativeAgent switch on."
        default: return "The read came back \(code)."
        }
    }

    static func place(_ percept: MacLookPercept) -> String {
        let app = percept.app?.name ?? "an unnamed app"
        guard let title = MacScreenText(percept.windowTitle ?? "", redacted: percept.windowTitleJSON).display else {
            return app
        }
        return "\(app) — \"\(title)\""
    }

    func unresolvedPhysical(_ target: String, nearest: [String], screen: String) -> MacFourVerbsReply {
        var line = "Nothing on this screen is called \"\(target)\"."
        if !nearest.isEmpty { line += " What I can see: " + nearest.joined(separator: " · ") + "." }
        return MacFourVerbsReply(ok: false, text: line + "\n" + screen, detail: ["error": .string("no_match")])
    }

    func ambiguousPhysical(_ target: String, candidates: [ActTarget], screen: String) -> MacFourVerbsReply {
        let names = candidates.map(Self.recoveryName).joined(separator: ", ")
        return MacFourVerbsReply(
            ok: false,
            text: "More than one thing matches \"\(target)\": \(names). Which one? I haven't touched anything.\n" + screen,
            detail: ["error": .string("ambiguous"), "target": .string(target),
                     "candidates": .array(candidates.map(Self.candidateDetail))]
        )
    }

    static func candidateDetail(_ candidate: ActTarget) -> JSONValue {
        .object([
            "role": .string(candidate.kind),
            "label": candidate.label.map(JSONValue.string) ?? .null,
            "target": .string(candidate.ordinal.map { "row \($0)" }
                ?? candidate.roleOrdinal.map { "\(candidate.kind) \($0)" }
                ?? candidate.label ?? candidate.kind),
            "position": candidate.frame.map { frame in
                .object(["x": .double(frame.x), "y": .double(frame.y),
                         "width": .double(frame.w), "height": .double(frame.h)])
            } ?? .null,
        ])
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1fs", max(0, value))
    }

    static func operationDetail(_ result: MacControlResult, app: String? = nil) -> [String: JSONValue] {
        var detail: [String: JSONValue] = [:]
        if case .object(let output) = result.output {
            // Emission counts ride every receipt: whether input went out is
            // what tells a refusal from an act that was not observed.
            for key in ["reason", "detail", "effects", "note", "guidance", "message", "remedy", "blocked_by", "block_reason", "matched_name", "bundle_identifier", "process_identifier",
                        "requested_events_emitted", "recovery_events_emitted", "effects_may_have_occurred"] { detail[key] = output[key] }
        }
        if let error = result.error { detail["error"] = .string(error) }
        if result.error?.hasPrefix("human_takeover:") == true, case .object(let receipt) = result.output {
            for key in ["status", "posted_events", "characters_sent", "text_character_count", "requested_events_emitted", "recovery_events_emitted", "gesture", "element", "app", "window", "frame_id", "handle", "method", "ax_delivered", "effect"] {
                detail[key] = receipt[key]
            }
        }
        if let operationId = result.operationId { detail["operationId"] = .string(operationId) }
        if let state = result.operationState { detail["operationState"] = .string(state.rawValue) }
        if let verification = result.verification { detail["verification"] = .string(verification.rawValue) }
        detail["duration_ms"] = .int(Int64(result.durationMs))
        let output = object(result.output)
        for key in ["status", "verified", "status_reason", "status_note", "verification_evidence", "verification_scope",
                    "hand_neutral", "text_value_verified"] {
            detail[key] = output[key]
        }
        if detail["status"] == .string("outcome_unknown"), let app {
            detail["remedy"] = inspectAppRemedy(app,
                instruction: "Inspect the affected app to establish what changed before another action.")
        }
        if output["verified"] == .bool(true) {
            detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
        } else if output["status"] == .string("acted_mismatch") {
            detail["verification"] = .string(MotorVerificationState.failed.rawValue)
        }
        return detail
    }

}
