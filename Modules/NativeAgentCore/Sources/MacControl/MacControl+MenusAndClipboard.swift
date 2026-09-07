import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeMacControl {
    // MARK: - fable51 item 29: the menu bar organ

    /// Which app's menu bar. Defaults to the frontmost, but honours `app` the
    /// same way `look` does — reading another app's menu is exactly as
    /// focus-free as reading its window, and refusing to would have made the
    /// two organs disagree about what "which app" means.
    private enum MenuTarget {
        case app(MacAXAppInfo)
        case refused(MacControlResult)
    }

    private func menuTarget(_ body: [String: JSONValue]) -> MenuTarget {
        let started = now()
        func refuse(_ code: String, _ words: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            var output: [String: JSONValue] = [
                "status": .string(code),
                "error": .string(code),
                "message": .string(words),
            ]
            for (key, value) in extra { output[key] = value }
            return MacControlResult(
                ok: false,
                action: "menu",
                output: .object(output),
                error: code,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard let requested = body.stringValue("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            guard let front = accessibilitySource.frontmostApp() else {
                return .refused(refuse(
                    "no_frontmost_app",
                    "Nothing is frontmost right now, so there is no menu bar to read."
                ))
            }
            return .app(front)
        }
        let resolution = MacBackgroundSight.resolve(
            requested,
            among: accessibilitySource.runningApps()
        )
        guard case .matched(let app) = resolution else {
            let code = resolution.failureCode ?? "app_not_running"
            return .refused(refuse(
                code,
                MacBackgroundSight.words(for: resolution, requested: requested)
                    ?? "I couldn't find a running app called \"\(requested)\".",
                ["requested_app": .string(requested)]
            ))
        }
        return .app(app)
    }

    /// THE WALK. One bounded descent, read-only, and it never opens a menu:
    /// the AX tree publishes the items whether or not they are drawn.
    func handleMenu(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "menu") }
        let app: MacAXAppInfo
        switch menuTarget(body) {
        case .refused(let refusal): return refusal
        case .app(let hit): app = hit
        }
        let reading = MacMenuBar.read(source: accessibilitySource, pid: app.processIdentifier)
        var output: [String: JSONValue] = [:]
        if case .object(let menuJSON) = MacMenuBar.json(reading) {
            output = menuJSON
        }
        output["trusted"] = .bool(true)
        output["app"] = app.toJSON()
        if let unavailable = reading.unavailable {
            output["message"] = .string(
                unavailable == "no_menu_bar"
                    ? "\(app.name) publishes no menu bar, so there is nothing to list."
                    : "I can't read \(app.name)'s menu bar: \(unavailable)."
            )
            return MacControlResult(
                ok: false,
                action: "menu",
                output: .object(output),
                error: unavailable,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        return MacControlResult(
            ok: true,
            action: "menu",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// THE PRESS. Walk (to resolve the NAME into an address), then AXPress
    /// through the same actuator `ax_act` uses.
    ///
    /// A DISABLED item refuses IN WORDS and presses nothing. That is the same
    /// refusal shape `act` holds: greyed out is a fact about the app's state,
    /// and pressing anyway would either do nothing (and be reported as done) or
    /// hit whatever the index chain now points at.
    func handleMenuPress(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "menu_press") }
        func refuse(_ code: String, _ words: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            var output: [String: JSONValue] = [
                "pressed": .bool(false),
                "status": .string(code),
                "error": .string(code),
                "message": .string(words),
            ]
            for (key, value) in extra { output[key] = value }
            return MacControlResult(
                ok: false,
                action: "menu_press",
                output: .object(output),
                error: code,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard let requested = body.stringValue("path")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return refuse(
                "missing_path",
                "menu_press needs `path` — the menu path to press, like \"File › Export › PDF\"."
            )
        }
        let app: MacAXAppInfo
        switch menuTarget(body) {
        case .refused(let refusal): return refusal
        case .app(let hit): app = hit
        }
        let reading = MacMenuBar.read(source: accessibilitySource, pid: app.processIdentifier)
        if let unavailable = reading.unavailable {
            return refuse(
                unavailable,
                "\(app.name) publishes no menu bar I can press through."
            )
        }
        let resolution = MacMenuBar.resolve(requested, among: reading.items)
        guard case .matched(let item) = resolution else {
            let code: String = {
                switch resolution {
                case .disabled: return "menu_item_disabled"
                case .ambiguous: return "menu_path_ambiguous"
                default: return "menu_path_not_found"
                }
            }()
            return refuse(
                code,
                MacMenuBar.words(for: resolution, requested: requested)
                    ?? "I couldn't find \"\(requested)\" in \(app.name)'s menu bar.",
                ["requested_path": .string(requested)]
            )
        }
        // Resolved from the MENU BAR, never from a window root: a menu bar is
        // not under any window, so a window-relative resolve of this index
        // chain would land on an unrelated element inside the document.
        let target: MacAXActTarget
        switch accessibilityActSource.resolve(
            menuPath: item.path,
            inAppPid: app.processIdentifier
        ) {
        case .resolved(let hit):
            target = hit
        case .pathNotFound:
            return refuse(
                "menu_path_not_found",
                "\"\(item.display)\" was in the menu a moment ago and is not there now; "
                    + "read the menu again."
            )
        default:
            return refuse(
                "app_gone",
                "\(app.name)'s menu bar is not reachable any more."
            )
        }
        let outcome = accessibilityActSource.perform(target, action: "AXPress")
        guard outcome == .performed else {
            return refuse(
                "menu_press_refused",
                "\(app.name) refused the press on \"\(item.display)\" (\(outcome)); nothing happened.",
                ["requested_path": .string(item.display)]
            )
        }
        return MacControlResult(
            ok: true,
            action: "menu_press",
            output: .object([
                "pressed": .bool(true),
                "trusted": .bool(true),
                "app": app.toJSON(),
                "path": MacScreenViewTextRedaction.redactedLegendString(
                    item.display,
                    valueChars: MacMenuBar.maxTitleChars * MacMenuBar.maxPathDepth
                ),
                "opens_submenu": .bool(item.hasSubmenu),
                // The press ran the app's handler. Whether the INTENDED
                // consequence happened is for the next look to say, never for
                // this result to claim.
                "verified": .bool(false),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: - fable51 item 30: the clipboard organ

    /// READ. The only channel through which pasteboard characters reach a
    /// provider, and therefore the only place the redaction boundary has to
    /// hold.
    ///
    /// Order matters: REDACT FIRST, then truncate. Truncating first could cut a
    /// secret in half and hand out the surviving half as ordinary prose, and
    /// the cut token would no longer match any shape the redactor knows.
    func handleClipboardRead(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard let contents = pasteboardSource.read() else {
            return MacControlResult(
                ok: false,
                action: "clipboard_read",
                output: .object([
                    "available": .bool(false),
                    "note": .string("There is no pasteboard on this system, so there is nothing to read."),
                ]),
                error: "clipboard_unavailable",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let maxChars = MacClipboardRead.clampedMaxChars(Self.intValue(body, "max_chars"))
        var output: [String: JSONValue] = [
            "available": .bool(true),
            "change_count": .int(Int64(contents.changeCount)),
            "types": MacClipboardRead.typesJSON(contents.types),
            "has_non_text": .bool(MacClipboardRead.hasNonTextTypes(contents.types)),
        ]
        if let raw = contents.text {
            let redaction = MacClipboardRead.redacted(raw)
            let cut = MacClipboardRead.truncated(redaction.text, maxChars: maxChars)
            output["has_text"] = .bool(true)
            output["text"] = .string(cut.text)
            output["chars"] = .int(Int64(redaction.text.count))
            output["truncated"] = .bool(cut.truncated)
            if cut.truncated { output["returned_chars"] = .int(Int64(cut.text.count)) }
            output["redacted"] = .bool(redaction.didRedact)
            if redaction.didRedact {
                output["redactions"] = .array(redaction.redactedLines.map { line in
                    .object(["line": .int(Int64(line.line)), "reason": .string(line.reason)])
                })
            }
        } else {
            output["has_text"] = .bool(false)
            output["text"] = .null
            output["chars"] = .int(0)
            output["truncated"] = .bool(false)
            output["redacted"] = .bool(false)
        }
        return MacControlResult(
            ok: true,
            action: "clipboard_read",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// WRITE. Replaces the general pasteboard's text and then READS IT BACK:
    /// `verified` is that comparison, never the return value of the set call.
    /// The text itself is never echoed — the caller wrote it, and an echo would
    /// route it back out through a channel with no redactor on it.
    func handleClipboardWrite(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        func refuse(_ reason: String, _ words: String) -> MacControlResult {
            MacControlResult(
                ok: false,
                action: "clipboard_write",
                output: .object(["written": .bool(false), "note": .string(words)]),
                error: reason,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard let text = body.stringValue("text") else {
            return refuse("missing_text", "clipboard_write needs `text` — the characters to put on the clipboard.")
        }
        guard text.count <= MacClipboardRead.maxWriteChars else {
            return refuse(
                "text_too_long",
                "That is \(text.count) characters; the clipboard write is bounded at "
                    + "\(MacClipboardRead.maxWriteChars)."
            )
        }
        guard pasteboardSource.write(text: text) else {
            return refuse("clipboard_write_refused", "The system refused the clipboard write; nothing changed.")
        }
        let readBack = pasteboardSource.read()
        return MacControlResult(
            ok: true,
            action: "clipboard_write",
            output: .object([
                "written": .bool(true),
                "chars": .int(Int64(text.count)),
                "verified": .bool(readBack?.text == text),
                "change_count": readBack.map { .int(Int64($0.changeCount)) } ?? .null,
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }
}
