import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+MenuCommands.swift` | `MacFourVerbs`: Menu/popup actions retain ambiguity, effect verification and read failures |

extension MacFourVerbs {
    /// Explicit menu paths keep their own owner so they cannot resolve as same-named window controls.
    func menuCommandReply(
        _ target: String, verb: MacActVerb, app: String?, seen before: Sighting,
        turn: Turn, context: MacOperationContext
    ) async -> MacFourVerbsReply? {
        guard [.click, .open, .select, .toggle].contains(verb) else { return nil }
        let screen = before.render
        if app == nil, before.pid == nil {
            return MacFourVerbsReply(ok: false, text: "I can't identify the front app's process, so nothing was pressed.",
                detail: ["error": .string("front_unknown")])
        }
        let lookup = await menuLookup(target, app: app ?? before.appName, frontPid: app == nil ? before.pid : nil, turn: turn, context: context)
        if let refusal = Self.menuLookupRefusal(target, lookup: lookup, screen: screen) { return refusal }
        guard let row = lookup.row, let path = Self.string(row["path"]) else { return nil }
        if app == nil, let pid = before.pid {
            return await pressMenu(path, ["path": .string(path), "require_front": .bool(true),
                                          "require_front_pid": .int(Int64(pid))], screen: "\n" + screen, turn: turn, context: context)
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
    func menuPressNoWindow(_ target: String, frontPid: Int32?, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        let lookup = await menuLookup(target, app: nil, frontPid: frontPid, turn: turn, context: context)
        if let refusal = Self.menuLookupRefusal(target, lookup: lookup) { return refusal }
        let path = lookup.row.flatMap { Self.string($0["path"]) } ?? target
        var body: [String: JSONValue] = ["path": .string(path), "require_front": .bool(true)]
        if let frontPid { body["require_front_pid"] = .int(Int64(frontPid)) }
        return await pressMenu(path, body, screen: "", turn: turn, context: context)
    }

    /// One menu press with its refusal carried whole: the checker's own error, reason and remedy reach the agent, never a generic "the app refused it".
    func pressMenu(_ path: String, _ body: [String: JSONValue], screen: String, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        let pressed: MacControlResult
        do { pressed = try await host.dispatch(action: "menu_press", body: body, turn: turn, context: context) } catch {
            return MacFourVerbsReply(ok: false, text: "Couldn't press the menu command \(path): \(error)" + screen,
                                     detail: ["error": .string("menu_press_unavailable"), "message": .string("\(error)"),
                                              "outcome_unknown": .bool(true),
                                              "menu_path": .string(path)])
        }
        return await pressedMenu(pressed, path: path, app: nil, screen: screen, turn: turn, context: context)
    }

    /// What a menu press says, for an act's menu path and the direct `menu_press` alike: the sentence, then the screen after it (`app`'s
    /// window, the front one when nil or when `app` is gone), or why that screen could not be read. A refusal carries `screen`, the look
    /// it was refused against.
    public func pressedMenu(_ pressed: MacControlResult, path: String, app: String?, screen: String, turn: Turn,
        context: MacOperationContext) async -> MacFourVerbsReply {
        if pressed.error == "front_changed" {
            // The person took the front during the lookup: their choice stands.
            return MacFourVerbsReply(ok: false, text: "The person changed apps; nothing pressed.",
                                     detail: ["error": .string("owner_changed_apps"), "menu_path": .string(path)])
        }
        if pressed.ok {
            let output = Self.object(pressed.output)
            var text = "Pressed the menu command \(path). " + (Self.string(output["status_note"]) ?? "")
            // A press can end the app it was pressed in (Quit, closing its last window); what the person then sees is the front screen.
            var look = await sight(part: nil, app: app, turn: turn, context: context)
            if app != nil, case .blind = look { look = await sight(part: nil, turn: turn, context: context) }
            switch look {
            case .seen(let after): text += "\n" + after.render
            case .blind(let unseen):
                text = text.trimmingCharacters(in: .whitespaces) + " The screen after could not be read: "
                    + (Self.string(unseen.detail["message"]) ?? unseen.text)
            }
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
    func selectInPopup(_ popup: ActTarget, option: String, before: Sighting, attention: BurstAttention?, turn: Turn,
        context: MacOperationContext) async -> MacFourVerbsReply {
        func fail(_ words: String, _ error: String, screen: String) -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: words + "\n" + screen,
                              detail: ["error": .string(error), "verb": .string("select"), "target": .string(option)])
        }
        var body: [String: JSONValue] = [
            "verb": .string("click"), "handle": .string(popup.handle), "frame_id": .string(before.frameId),
        ]
        Self.addAttention(attention, to: &body)
        let opened: MacControlResult
        do { opened = try await host.dispatch(action: "act", body: body, turn: turn, context: context) } catch {
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
        switch await sight(part: nil, turn: turn, context: context) {
        case .seen(let hit): open = hit
        case .blind(let reply):
            // A failed post-click look cannot erase input already emitted.
            let unseen = fail("Clicked \(Self.name(popup)) but couldn't see whether it opened. " + reply.text,
                              "popup_unobserved", screen: "")
            return MacFourVerbsReply(ok: false, text: unseen.text,
                                     detail: reply.detail.merging(["status": .string("acted_unobserved")]) { _, new in new })
        }
        guard let pid = open.pid, pid == before.pid else {
            return fail("The popup's app changed during observation; no selection or cleanup key was sent.",
                "popup_owner_changed", screen: open.render)
        }
        let items = open.targets.filter { $0.kind == "menu item" }
        guard case .hit(let item) = Self.resolve(option, among: items), Self.answers(option, item, exact: true), item.enabled == true else {
            var cleanup: [String: JSONValue] = ["gesture": .string("key"), "keys": .string("escape"),
                                               "require_frame_id": .string(open.frameId)]
            Self.addAttention(attention, to: &cleanup)
            let dismissed = await context.holding(\.requiredFrontPid, open.pid) {
                context in await performHand(body: cleanup, description: "Sent Escape to the observed popup.",
                    attention: attention, before: open, confirm: false, turn: turn, context: context)
            }
            func cleanupResult(_ reply: MacFourVerbsReply) -> MacFourVerbsReply {
                MacFourVerbsReply(ok: reply.ok, text: reply.text + (dismissed.ok ? "" : " Cleanup: " + dismissed.text),
                    detail: reply.detail.merging(["popup_cleanup": .object(dismissed.detail)]) { _, new in new })
            }
            let offered = items.compactMap { $0.enabled == true ? $0.label : nil }.filter { !$0.isEmpty }
            let words = "\(Self.name(popup)) has no \"\(option)\" to choose"
                + (offered.isEmpty ? "." : "; it offers: " + offered.joined(separator: ", ") + ".")
            switch await sight(part: nil, turn: turn, context: context) {
            case .blind(let reply):
                return cleanupResult(fail(words + " I couldn't confirm that the popup closed. " + reply.text,
                            "popup_dismissal_unverified", screen: ""))
            case .seen(let after):
                let closed = dismissed.ok && after.pid == open.pid && after.percept?.truncated == false
                    && !after.targets.contains { $0.kind == "menu item" }
                    && after.targets.contains {
                        $0.handle == popup.handle
                            || (popup.sourceAXPath != nil && $0.sourceAXPath == popup.sourceAXPath)
                    }
                return cleanupResult(fail(
                    words + (closed ? " The popup is closed; I didn't select an option."
                                    : " I couldn't confirm that the popup closed; I didn't select an option."),
                    closed ? "option_not_offered" : "popup_dismissal_unverified", screen: after.render
                ))
            }
        }
        let picked = await performSupplementalSemantic(
            .click, direction: .down, candidate: item, target: option, text: nil, holding: nil,
            attention: attention, before: open
        , turn: turn, context: context)
        guard picked.ok, case .seen(let after) = await sight(part: nil, turn: turn, context: context) else { return picked }
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
        /// Retain a menu read's own refusal so unreadability cannot become a missing-command answer.
        var failure: MacFourVerbsReply?
    }

    static func menuLookupRefusal(_ target: String, lookup: MenuLookup, screen: String? = nil) -> MacFourVerbsReply? {
        // An explicit menu path whose menus could not be read is that read's refusal, not a miss that falls through to the window.
        if lookup.row == nil, isMenuPath(target), let failure = lookup.failure {
            return MacFourVerbsReply(ok: false, text: failure.text + " Nothing was pressed." + (screen.map { "\n" + $0 } ?? ""),
                                     detail: failure.detail)
        }
        guard lookup.ambiguous else { return nil }
        return MacFourVerbsReply(
            ok: false,
            text: "More than one menu command matches \"\(target)\""
                + (lookup.candidates.isEmpty ? "." : ": " + lookup.candidates.joined(separator: "; ") + ".")
                + """
                     Use a displayed path including its [first]/[second] suffix when shown, or the command's key chord. No command was pressed.
                    """ + (screen.map { "\n" + $0 } ?? ""),
            detail: ["error": .string("menu_path_ambiguous"),
                     "target": .string(target), "candidates": .array(lookup.candidates.map(JSONValue.string))]
        )
    }

    struct MenuHint {
        var text: String = ""
        var detail: [String: JSONValue] = [:]
    }

    /// A bare name targets the window; the menus are reached by path. A failed menu read is evidence of unreadability, never of a missing item.
    func menuHint(_ target: String, verb: MacActVerb, app: String?, turn: Turn, context: MacOperationContext) async -> MenuHint {
        guard [.click, .open, .select, .toggle].contains(verb) else { return MenuHint() }
        let lookup = await menuLookup(target, app: app, turn: turn, context: context)
        let paths = lookup.row.flatMap { Self.string($0["path"]) }.map { [$0] } ?? lookup.candidates
        guard !paths.isEmpty else {
            guard let failure = lookup.failure else { return MenuHint() }
            return MenuHint(text: " " + failure.text,
                            detail: ["menu_lookup_failure": .object(failure.detail)])
        }
        return MenuHint(text: " The menus have it at " + paths.joined(separator: "; ")
            + (paths.count == 1 ? "; pass that path." : "; pass the path you mean."))
    }

    /// Parse the accepted name/role grammar once, then ask the menu owner once. A source failure is returned whole and never retried under another name.
    func menuLookup(_ target: String, app: String?, frontPid: Int32? = nil, turn: Turn, context: MacOperationContext) async -> MenuLookup {
        let said = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleName = MacMenuBar.isPath(said) ? nil : Self.stripRoleWords(said)
        var body: [String: JSONValue] = ["find": .string(said)]
        if let roleName, roleName != Self.normalize(said), !roleName.isEmpty { body["role_name"] = .string(roleName) }
        if let app { body["app"] = .string(app) }
        if let frontPid { body["require_front_pid"] = .int(Int64(frontPid)) }
        let found: MacControlResult
        do { found = try await host.dispatch(action: "menu", body: body, turn: turn, context: context) } catch {
            return MenuLookup(row: nil, failure: MacFourVerbsReply(ok: false,
                text: "I couldn't read the menus: \(error).",
                detail: ["error": .string("menu_unavailable"), "message": .string("\(error)")]))
        }
        let output = Self.object(found.output)
        guard found.ok else {
            return MenuLookup(row: nil, failure: MacFourVerbsReply(ok: false,
                text: "I couldn't read the menus: "
                    + (Self.string(output["message"]) ?? found.error ?? "the Mac refused the read") + ".",
                detail: Self.operationDetail(found)))
        }
        let hits = Self.array(output["found"]).map(Self.object)
        if hits.count > 1 {
            return MenuLookup(row: nil, candidates: hits.compactMap { row in
                Self.string(row["path"]).map { path in
                    path + (Self.string(row["chord"]).map { " (key: \($0))" } ?? "")
                }
            }, ambiguous: true)
        }
        return MenuLookup(row: hits.first)
    }

    /// An explicit menu path never names a window target.
    static func isMenuPath(_ target: String) -> Bool {
        MacMenuBar.isPath(target) && MacMenuBar.components(target).count > 1
    }
}
