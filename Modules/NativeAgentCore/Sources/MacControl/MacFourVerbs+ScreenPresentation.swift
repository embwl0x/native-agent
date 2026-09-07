import Foundation
import NativeAgentCore
import PersistenceCore

extension MacFourVerbs {
    // MARK: - Zoom

    struct Zoom {
        let screen: MacScreenRender.Screen
        let options: MacScreenRender.Options
        let note: String
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
                    + "; surrounding controls omitted."
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
            ), note: "\(matchingValues.count) observed readout\(matchingValues.count == 1 ? "" : "s") match; surrounding controls omitted.")
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
                note: "\(matchingControls.count) of \(screen.totalControls) actionable match; "
                    + "the rest of the screen is unchanged."
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
        let head = words.first ?? ""
        let direction: ScrollDirection = words.contains("up") ? .up
            : words.contains("left") ? .left : words.contains("right") ? .right : .down
        return (head, direction)
    }

    static func pastTense(_ verb: MacActVerb, direction: ScrollDirection) -> String {
        switch verb {
        case .click: return "Clicked"
        case .open: return "Opened"
        case .type: return "Typed into"
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

}
