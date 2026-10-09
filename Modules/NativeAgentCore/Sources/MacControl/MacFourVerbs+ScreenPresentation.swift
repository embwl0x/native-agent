import Foundation
import NativeAgentCore
import PersistenceCore
import Senses

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
        let options: MacScreenRender.Options
        let note: String
        let scope: Scope

        init(screen: MacScreenRender.Screen, options: MacScreenRender.Options, note: String, scope: Scope = .whole) {
            self.screen = screen; self.options = options; self.note = note; self.scope = scope
        }
    }

    /// Scoping, WITHOUT renumbering. Controls carry no ordinals, so a control
    /// zoom filters them; content rows carry the addresses she acts with, so a
    /// content zoom raises the cap and names the matching ordinals instead of
    /// dropping their neighbours.
    static func zoom(
        _ screen: MacScreenRender.Screen,
        part: String,
        options: MacScreenRender.Options
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
                options: MacScreenRender.Options(
                    maxRows: max(options.maxRows, Self.zoomMaxRows),
                    maxControls: options.maxControls,
                    maxValues: options.maxValues,
                    maxWhereSteps: options.maxWhereSteps,
                    // Visual object details carry compact colour, normalized
                    // geometry, and motion. The ordinary 40-character UI
                    // label cap cuts those facts at "at …"; this scoped world
                    // has few rows and can afford the bounded wider field.
                    maxLabelChars: max(options.maxLabelChars, 96)
                ),
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
            return Zoom(screen: scoped, options: MacScreenRender.Options(
                maxRows: options.maxRows, maxControls: options.maxControls,
                maxValues: max(options.maxValues, Self.zoomMaxRows), maxWhereSteps: options.maxWhereSteps,
                maxLabelChars: options.maxLabelChars
            ), note: "\(matchingValues.count) observed readout\(matchingValues.count == 1 ? "" : "s") match; surrounding controls omitted.", scope: .readouts)
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
                options: MacScreenRender.Options(
                    maxRows: options.maxRows,
                    maxControls: max(options.maxControls, Self.zoomMaxRows),
                    maxValues: options.maxValues,
                    maxWhereSteps: options.maxWhereSteps,
                    maxLabelChars: options.maxLabelChars
                ),
                note: "\(matchingControls.count) of \(screen.totalControls) actionable match"
                    // A capped read is not the whole window: say what it left out.
                    + (asksForControls && screen.unclassifiedOmittedTargets > 0
                        ? " (\(screen.unclassifiedOmittedTargets) more weren't kept in this read; name one and I'll find it)"
                        : "")
                    + "; the rest of the screen is unchanged.",
                scope: .controls
            )
        }

        // Content zoom: the whole section, cap raised, ordinals intact.
        let wide = MacScreenRender.Options(
            maxRows: max(options.maxRows, Self.zoomMaxRows),
            maxControls: options.maxControls,
            maxValues: options.maxValues,
            maxWhereSteps: options.maxWhereSteps,
            maxLabelChars: options.maxLabelChars
        )
        if matchingRows.isEmpty {
            return Zoom(
                screen: screen,
                options: wide,
                note: "Nothing here is named \"\(part)\" — this is the whole screen."
            )
        }
        return Zoom(
            screen: screen,
            options: wide,
            note: "Matching row\(matchingRows.count == 1 ? "" : "s"): "
                + matchingRows.map(String.init).joined(separator: ", ") + "."
        )
    }

    static let zoomMaxRows = 60

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

    /// What changed, said plainly. Everything here is read off the effect diff
    /// the closed loop already computed and already redacted — no value is
    /// re-derived and none is re-rendered from a raw string.
    static func effectWords(
        output: [String: JSONValue],
        verb: MacActVerb,
        typed: String?
    ) -> EffectWords {
        let status = string(output["status"]) ?? "acted"
        let effect = object(output["effect"] ?? .null)
        var parts: [String] = []

        for row in array(effect["readouts_changed"]).prefix(3) {
            let readout = object(row)
            if let text = MacScreenText(string(readout["text"]) ?? "", redacted: readout["text"]).display {
                parts.append("it now reads \"\(text)\"")
            }
        }
        if parts.isEmpty {
            for row in array(effect["readouts_added"]).prefix(2) {
                let readout = object(row)
                if let text = MacScreenText(string(readout["text"]) ?? "", redacted: readout["text"]).display {
                    parts.append("\"\(text)\" appeared")
                }
            }
        }
        if case .bool(true)? = effect["window_changed"] {
            let reasons = array(effect["change_reasons"]).compactMap { string($0) }
            parts.append(reasons.isEmpty ? "the window changed" : "the window changed (\(reasons.joined(separator: ", ")))")
        }
        let added = int(effect["affordances_added_total"]) ?? 0
        let removed = int(effect["affordances_removed_total"]) ?? 0
        if added > 0 || removed > 0 {
            parts.append("\(added) thing\(added == 1 ? "" : "s") appeared, \(removed) went away")
        }
        if verb == .type, let typed, !typed.isEmpty, status == "acted" {
            parts.insert("the text went in", at: 0)
        }

        // The verdict from below is carried, not restated: `acted_unobserved`
        // means the event went out and nothing was seen to happen, and calling
        // that a success is the exact dishonesty the closed loop was built to
        // stop.
        var sentence: String
        if status == "acted" {
            sentence = parts.isEmpty ? "It landed; nothing else on screen moved." : parts.joined(separator: "; ") + "."
        } else if status == "acted_unobserved" {
            let why = string(output["status_reason"]).map { " (\($0))" } ?? ""
            sentence = "The press went out but nothing was seen to change\(why)"
                + (parts.isEmpty ? "." : " — " + parts.joined(separator: "; ") + ".")
        } else {
            sentence = (string(output["status_note"]) ?? "Status: \(status).")
        }
        return EffectWords(sentence: sentence, status: status)
    }

    /// THE HOMEWORK STRIPPER.
    ///
    /// The layers below write real words, and their guidance is used verbatim —
    /// except for the tail they were written with: "…call mac_look again",
    /// "…re-look", "…now do X and call me again". native-screen.md: "A refusal
    /// ending in '…now do X and call me again' is a BUG, not a safety feature."
    /// Those clauses name a tool she does not have any more and ask her to
    /// perform bookkeeping this file already performed — every refusal here is
    /// followed by a fresh screen. So the mechanism survives, the homework does
    /// not, and the reply says which of the two happened.
    static func plainWords(_ guidance: String?) -> String? {
        guard let guidance, !guidance.isEmpty else { return nil }
        // Clause-wise, so the MECHANISM (which is the part she reasons with) is
        // never truncated along with the instruction.
        let clauses = guidance
            .replacingOccurrences(of: " — ", with: "\u{1}")
            .replacingOccurrences(of: "; ", with: "\u{1}")
            .split(separator: "\u{1}", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let homework = ["mac_look", "call me again", "look again", "re-look", "take another look"]
        let kept = clauses.filter { clause in
            let lowered = clause.lowercased()
            return !homework.contains { lowered.contains($0) }
        }
        var mechanism = (kept.isEmpty ? clauses : kept).joined(separator: " — ")
        // …and the FRAME vocabulary goes with it. Below this file a frame is a
        // real object with a real name; in her hands it is the bookkeeping these
        // verbs deleted, and a mechanism she cannot map onto anything she did is
        // not a mechanism she can choose differently from.
        for (jargon, plain) in [
            ("the app this frame was captured from", "the app I was looking at"),
            ("the window this frame was captured from", "the window I was looking at"),
            ("this frame was captured from", "I was looking at"),
            ("the old frame is discarded", "I've let go of what I had"),
            ("this frame", "what I was looking at"),
            ("the frame", "what I was looking at"),
        ] {
            mechanism = mechanism.replacingOccurrences(of: jargon, with: plain)
        }
        var trimmed = mechanism.trimmingCharacters(in: CharacterSet(charactersIn: " .")).appending(".")
        if let first = trimmed.first, first.isLowercase {
            trimmed = first.uppercased() + trimmed.dropFirst()
        }
        // The re-look is stated as DONE, because it is: the fresh screen is
        // already attached below this line.
        return kept.count == clauses.count ? trimmed : trimmed + " I looked again — this is what's there now."
    }

    /// A refusal code with no `guidance` of its own — rare, since the layers
    /// below write their own words. Translated, never echoed bare.
    static func refusalWords(_ code: String) -> String {
        switch code {
        case "window_not_key":
            return "another window has the keyboard right now, so the keystroke would have gone "
                + "somewhere else — nothing was sent."
        case "handle_drifted", "window_drifted":
            return "the screen moved while I was reaching for it — nothing was touched; look again."
        case "frame_window_gone", "frame_app_gone":
            return "what I was looking at isn't there any more — nothing was touched."
        case "verb_not_supported_on_element":
            return "that thing doesn't do that."
        case "observer_unavailable":
            return "I couldn't watch that app for the effect, so I didn't press anything blind."
        default:
            return "it refused: \(code)."
        }
    }

    static func lookRefusalWords(_ code: String) -> String {
        switch code {
        case "no_frontmost_window": return "There's no window up to look at."
        case "ax_untrusted", "accessibility_untrusted":
            return "Accessibility isn't granted to me, so I can't read any window."
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

    static func operationDetail(_ result: MacControlResult) -> [String: JSONValue] {
        var detail: [String: JSONValue] = [:]
        if result.error?.hasPrefix("human_takeover:") == true, case .object(let receipt) = result.output {
            for key in ["status", "posted_events", "characters_sent", "text_character_count", "requested_events_emitted", "recovery_events_emitted", "gesture", "element", "app", "window", "frame_id", "handle", "method", "ax_delivered", "effect"] {
                detail[key] = receipt[key]
            }
        }
        if let operationId = result.operationId { detail["operationId"] = .string(operationId) }
        if let state = result.operationState { detail["operationState"] = .string(state.rawValue) }
        if let verification = result.verification { detail["verification"] = .string(verification.rawValue) }
        return detail
    }

}
