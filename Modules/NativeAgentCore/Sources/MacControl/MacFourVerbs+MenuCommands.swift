import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+MenuCommands.swift` | `MacFourVerbs`: menu lookup, command receipts and popup selection; menu paths retain foreground targeting, ambiguity and declared-effect verification |

extension MacFourVerbs {
    /// Resolve explicit menu paths through menu reads; foreground acts press the command, background acts report its location and key equivalent.
    func menuCommandReply(
        _ target: String, verb: MacActVerb, app: String?, seen before: Sighting
    ) async -> MacFourVerbsReply? {
        guard [.click, .open, .select, .toggle].contains(verb) else { return nil }
        let screen = before.render
        if app == nil, before.pid == nil {
            return MacFourVerbsReply(ok: false, text: "I can't identify the front app's process, so nothing was pressed.",
                detail: ["error": .string("front_unknown")])
        }
        let lookup = await menuLookup(target, app: app ?? before.appName, frontPid: app == nil ? before.pid : nil)
        if let refusal = Self.menuLookupRefusal(target, lookup: lookup, screen: screen) { return refusal }
        guard let row = lookup.row, let path = Self.string(row["path"]) else { return nil }
        if app == nil, let pid = before.pid {
            return await pressMenu(path, ["path": .string(path), "require_front": .bool(true),
                                          "require_front_pid": .int(Int64(pid))], screen: "\n" + screen)
        }
        guard let app else { return nil }
        let menuName = MacMenuBar.components(path).first ?? path
        let glyphs = Self.string(row["shortcut"])
        let chord = Self.string(row["chord"])
        let greyed = Self.bool(row["enabled"]) == false ? " It's greyed out right now."
            : (row["enabled"] == nil ? " Whether it's greyed out is unknown until \(app) is in front." : "")
        let shortcut = glyphs.map { " (\($0))" } ?? ""
        var detail: [String: JSONValue] = [
            "menu_path": .string(path),
            "target": .string(target),
            "owner_front_changed": .bool(false),
        ]
        if let glyphs { detail["shortcut"] = .string(glyphs) }
        if let chord { detail["chord"] = .string(chord) }
        detail["error"] = .string("needs_front")
        detail["status"] = .string("needs_front")
        detail["needs_front_reason"] = .string("it's a menu command")
        detail["background"] = .bool(true)
        let text = "\"\(target)\" is in \(app)'s \(menuName) menu\(shortcut) — I need the screen because it's a menu command. "
            + "Nothing was touched. Only use front:true when the task explicitly asks to bring \(app) forward." + greyed
        return MacFourVerbsReply(ok: false, text: text + "\n" + screen, detail: detail)
    }

    /// A windowless app's menu can open a window; `frontPid` must still own the front.
    func menuPressNoWindow(_ target: String, frontPid: Int32?) async -> MacFourVerbsReply {
        let lookup = await menuLookup(target, app: nil, frontPid: frontPid)
        if let refusal = Self.menuLookupRefusal(target, lookup: lookup) { return refusal }
        let path = lookup.row.flatMap { Self.string($0["path"]) } ?? target
        var body: [String: JSONValue] = ["path": .string(path), "require_front": .bool(true)]
        if let frontPid { body["require_front_pid"] = .int(Int64(frontPid)) }
        return await pressMenu(path, body, screen: "")
    }

    /// One menu press with its refusal carried whole: the checker's own error,
    /// reason and remedy reach her, never a generic "the app refused it".
    func pressMenu(_ path: String, _ body: [String: JSONValue], screen: String) async -> MacFourVerbsReply {
        let pressed: MacControlResult
        do { pressed = try await host.dispatch(action: "menu_press", body: body) } catch {
            return MacFourVerbsReply(ok: false, text: "Couldn't press the menu command \(path): \(error)" + screen,
                                     detail: ["error": .string("menu_press_unavailable"), "message": .string("\(error)"),
                                              "outcome_unknown": .bool(true),
                                              "menu_path": .string(path)])
        }
        if pressed.error == "front_changed" {
            // The person took the front during the lookup: their choice stands.
            return MacFourVerbsReply(ok: false, text: "The person changed apps; nothing pressed.",
                                     detail: ["error": .string("owner_changed_apps"), "menu_path": .string(path)])
        }
        if pressed.ok {
            let output = Self.object(pressed.output)
            var text = "Pressed the menu command \(path). " + (Self.string(output["status_note"]) ?? "")
            if case .seen(let after) = await sight(part: nil) { text += "\n" + after.render }
            var detail = Self.operationDetail(pressed)
            detail["menu_path"] = .string(path)
            return MacFourVerbsReply(ok: true, text: text, detail: detail)
        }
        var detail = Self.operationDetail(pressed)
        detail["error"] = detail["error"] ?? .string("menu_press_failed")
        detail["menu_path"] = .string(path)
        let why = Self.string(Self.object(pressed.output)["message"]) ?? pressed.error ?? "the app refused it"
        return MacFourVerbsReply(ok: false, text: "Couldn't press the menu command \(path): \(why)" + screen, detail: detail)
    }

    /// Popup selection verifies the named item's value; an absent option dismisses and reports the available options.
    func selectInPopup(_ popup: ActTarget, option: String, before: Sighting, attention: BurstAttention?) async -> MacFourVerbsReply {
        func fail(_ words: String, _ error: String, screen: String) -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: words + "\n" + screen,
                              detail: ["error": .string(error), "verb": .string("select"), "target": .string(option)])
        }
        var body: [String: JSONValue] = [
            "verb": .string("click"), "handle": .string(popup.handle), "frame_id": .string(before.frameId),
        ]
        Self.addAttention(attention, to: &body)
        let opened: MacControlResult
        do { opened = try await host.dispatch(action: "act", body: body) } catch {
            let refusal = fail("Couldn't open \(Self.name(popup)): \(error)", "popup_not_opened", screen: before.render)
            return MacFourVerbsReply(ok: false, text: refusal.text,
                                     detail: refusal.detail.merging(["outcome_unknown": .bool(true)]) { _, new in new })
        }
        guard opened.ok else {
            let refusal = fail("Couldn't open \(Self.name(popup)): "
                + (Self.string(Self.object(opened.output)["message"]) ?? opened.error ?? "the Mac refused the click") + ".",
                "popup_not_opened", screen: before.render)
            return MacFourVerbsReply(ok: false, text: refusal.text,
                                     detail: refusal.detail.merging(Self.operationDetail(opened)) { current, _ in current })
        }
        let open: Sighting
        switch await sight(part: nil) {
        case .seen(let hit): open = hit
        case .blind(let reply):
            // The click went out; only the look failed.
            let unseen = fail("Clicked \(Self.name(popup)) but couldn't see whether it opened. " + reply.text,
                              "popup_unobserved", screen: "")
            return MacFourVerbsReply(ok: false, text: unseen.text,
                                     detail: reply.detail.merging(["status": .string("acted_unobserved")]) { _, new in new })
        }
        let items = open.targets.filter { $0.kind == "menu item" }
        guard case .hit(let item) = Self.resolve(option, among: items), Self.answers(option, item, exact: true), item.enabled else {
            let dismissed = try? await host.dispatch(action: "hand", body: ["gesture": .string("key"), "keys": .string("escape")])
            let offered = items.compactMap { $0.enabled ? $0.label : nil }.filter { !$0.isEmpty }
            let words = "\(Self.name(popup)) has no \"\(option)\" to choose"
                + (offered.isEmpty ? "." : "; it offers: " + offered.joined(separator: ", ") + ".")
            switch await sight(part: nil) {
            case .blind(let reply):
                return fail(words + " I couldn't confirm that the popup closed. " + reply.text,
                            "popup_dismissal_unverified", screen: "")
            case .seen(let after):
                let closed = dismissed?.ok == true && after.pid == open.pid
                    && !after.targets.contains { $0.kind == "menu item" }
                    && after.targets.contains {
                        $0.handle == popup.handle
                            || (popup.sourceAXPath != nil && $0.sourceAXPath == popup.sourceAXPath)
                    }
                return fail(
                    words + (closed ? " The popup is closed; I didn't select an option."
                                    : " I couldn't confirm that the popup closed; I didn't select an option."),
                    closed ? "option_not_offered" : "popup_dismissal_unverified", screen: after.render
                )
            }
        }
        let picked = await performSupplementalSemantic(
            .click, direction: .down, candidate: item, target: option, text: nil, holding: nil,
            attention: attention, before: open
        )
        guard picked.ok, case .seen(let after) = await sight(part: nil) else { return picked }
        // The popup's own value is the evidence, not the menu closing.
        let value = Self.array(Self.object(after.controls)["affordances"]).map { Self.object($0) }.first { row in
            (popup.sourceAXPath.map { Self.path(row["path"]) == $0 } ?? false)
                || Self.string(row["handle"]) == popup.handle
        }.flatMap { Self.string($0["value"]) }
        let wanted = item.label ?? option
        let verdict = MacActClosedLoop.verify(.state(wanted), value: value)
        var detail = picked.detail.merging(verdict.receipt) { _, new in new }
        detail["verb"] = .string("select")
        detail["target"] = .string(option)
        detail["matched"] = .string(wanted)
        return MacFourVerbsReply(ok: verdict.status != "acted_mismatch",
            text: "Chose \"\(wanted)\" in \(Self.name(popup)). " + (verdict.note ?? "") + "\n" + after.render, detail: detail)
    }

    struct MenuLookup {
        let row: [String: JSONValue]?
        var candidates: [String] = []
        var ambiguous: Bool = false
        /// The read's own refusal when the menus could not be read at all.
        var failure: MacFourVerbsReply?
    }

    static func menuLookupRefusal(_ target: String, lookup: MenuLookup, screen: String? = nil) -> MacFourVerbsReply? {
        // An explicit menu path whose menus could not be read is that read's
        // refusal, not a miss that falls through to the window.
        if lookup.row == nil, isMenuPath(target), let failure = lookup.failure {
            return MacFourVerbsReply(ok: false, text: failure.text + " Nothing was pressed." + (screen.map { "\n" + $0 } ?? ""),
                                     detail: failure.detail)
        }
        guard lookup.ambiguous else { return nil }
        return MacFourVerbsReply(
            ok: false,
            text: "More than one menu command matches \"\(target)\""
                + (lookup.candidates.isEmpty ? "." : ": " + lookup.candidates.joined(separator: "; ") + ".")
                + " Use an explicit menu path. No command was pressed." + (screen.map { "\n" + $0 } ?? ""),
            detail: ["error": .string("menu_path_ambiguous"),
                     "target": .string(target), "candidates": .array(lookup.candidates.map(JSONValue.string))]
        )
    }

    /// A bare name targets the window; the menus are reached by path. When
    /// the menus hold a name the window lacks, its miss says where.
    func menuHint(_ target: String, verb: MacActVerb, app: String?) async -> String {
        guard [.click, .open, .select, .toggle].contains(verb) else { return "" }
        let lookup = await menuLookup(target, app: app)
        let paths = lookup.row.flatMap { Self.string($0["path"]) }.map { [$0] } ?? lookup.candidates
        guard !paths.isEmpty else { return "" }
        return " The menus have it at " + paths.joined(separator: "; ")
            + (paths.count == 1 ? "; pass that path." : "; pass the path you mean.")
    }

    /// Menu titles are literal: try the name as said, then without a trailing
    /// role word. A repeated name is not a hit; a walk the caps cut is read
    /// for what it found, and finding nothing there is a miss.
    func menuLookup(_ target: String, app: String?, frontPid: Int32? = nil) async -> MenuLookup {
        let said = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = Self.stripRoleWords(said)
        let names = MacMenuBar.isPath(said) || stripped == Self.normalize(said) ? [said] : [said, stripped]
        var failure: MacFourVerbsReply?
        for name in names {
            var body: [String: JSONValue] = ["find": .string(name)]
            if let app { body["app"] = .string(app) }
            if let frontPid { body["require_front_pid"] = .int(Int64(frontPid)) }
            let found: MacControlResult
            do { found = try await host.dispatch(action: "menu", body: body) } catch {
                failure = MacFourVerbsReply(ok: false, text: "I couldn't read the menus: \(error).",
                                            detail: ["error": .string("menu_unavailable"), "message": .string("\(error)")])
                continue
            }
            let output = Self.object(found.output)
            guard found.ok else {
                failure = MacFourVerbsReply(ok: false, text: "I couldn't read the menus: "
                    + (Self.string(output["message"]) ?? found.error ?? "the Mac refused the read") + ".",
                    detail: Self.operationDetail(found))
                continue
            }
            let hits = Self.array(output["found"]).map(Self.object)
            if hits.count > 1 {
                return MenuLookup(row: nil,
                                  candidates: hits.compactMap { Self.string($0["path"]) }, ambiguous: true)
            }
            if let first = hits.first { return MenuLookup(row: first) }
        }
        return MenuLookup(row: nil, failure: failure)
    }

    /// "Format › Make Plain Text": an explicit menu path, never a window name.
    static func isMenuPath(_ target: String) -> Bool {
        MacMenuBar.isPath(target) && MacMenuBar.components(target).count > 1
    }
}
