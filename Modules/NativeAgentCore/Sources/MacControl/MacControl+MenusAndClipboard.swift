import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`: `handleMenu`, `handleMenuPress`, `handleClipboardRead`; menu discovery and press share displayed occurrence choices for unpublished duplicates; surface commands await transition notifications within the existing deadline before owned-window readback; Select All keeps its range readback |

extension SwiftNativeMacControl {
    // MARK: - Menu bar

    /// Which app's menu bar. Defaults to the frontmost, but honours `app` the
    /// same way `look` does — reading another app's menu is exactly as
    /// focus-free as reading its window, and refusing to would have made the
    /// two organs disagree about what "which app" means.
    private enum MenuTarget {
        case app(MacAXAppInfo)
        case refused(MacControlResult)
    }

    private func menuTarget(_ body: [String: JSONValue], continuation: MacWorkContinuation? = nil) -> MenuTarget {
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        // Refuse if the app an act brought forward no longer owns the front PID.
        if let pid = body["require_front_pid"]?.integerValue.flatMap(Int.init(exactly:)) {
            guard let front = accessibilitySource.frontmostApp(), Int(front.processIdentifier) == pid else {
                return .refused(refuse("front_changed", "That app is no longer in front, so nothing was pressed."))
            }
            return .app(front)
        }
        guard let requested = body["app"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            guard let front = continuation == nil ? accessibilitySource.frontmostApp() : continuation?.app else {
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
        // `find` keeps every match within the bounded walk so repeated names
        // remain ambiguous across menus.
        // A path ("Format › Make Plain Text") finds that item under that menu.
        // A bare name ("Find/Replace") is never split.
        let selected = body["find"]?.stringValue.map(MacMenuBar.selection)
        let wantedLevels = selected.map {
            (MacMenuBar.isPath($0.path) ? MacMenuBar.components($0.path) : [$0.path]).map(MacMenuBar.normalized)
        } ?? []
        let wanted = wantedLevels.last.flatMap { $0.isEmpty ? nil : $0 }
        // The four-verb parser supplies its optional trailing-role grammar.
        // Literal names win; both alternatives resolve against this one reading.
        let roleName = body["role_name"]?.stringValue.map(MacMenuBar.normalized)
        func isWanted(_ item: MacMenuBar.Item) -> Bool {
            let levels = item.titlePath.map(MacMenuBar.normalized)
            guard levels.last == wanted else { return false }
            return wantedLevels.count == 1
                || (levels.count == wantedLevels.count && zip(levels, wantedLevels).allSatisfy { $0.hasPrefix($1) })
        }
        // `chord` ("cmd+s"): the item whose key equivalent that is, so a key
        // step can press the command itself.
        let wantedChord = body["chord"]?.stringValue
            .flatMap { try? MacKeySyntax.parseChords($0) }.flatMap { $0.count == 1 ? $0.first : nil }
        // One AX read per ask; a cached map would be sent across the reader's isolation.
        func shortcut(_ item: MacMenuBar.Item) -> (glyphs: String, chord: String)? {
            guard case .resolved(let element) = accessibilityActSource.resolve(menuPath: item.path, inAppPid: app.processIdentifier, titlePath: nil) else { return nil }
            return accessibilityActSource.menuShortcut(element)
        }
        func hasChord(_ item: MacMenuBar.Item) -> Bool {
            guard let wantedChord, !item.hasSubmenu,
                  let shortcut = shortcut(item),
                  let chord = try? MacKeySyntax.parseChords(shortcut.chord).first else { return false }
            return chord.keyCode == wantedChord.keyCode && chord.modifiers == wantedChord.modifiers
        }
        // Walk the named menus whole: a later enabled duplicate or matching
        // key equivalent must remain available to the one-command selector.
        let reading = MacMenuBar.read(
            source: accessibilitySource, pid: app.processIdentifier,
            top: wantedLevels.count > 1 ? wantedLevels.first : nil,
            depth: wanted == nil && wantedChord == nil ? MacMenuBar.maxPathDepth : MacMenuBar.findPathDepth
        )
        // A background app's menus report stale enabled states (File › Save
        // "disabled" on an edited document), so they are not claimed.
        let statesKnown = accessibilitySource.frontmostApp()?.processIdentifier == app.processIdentifier
        // `words` (the door's find): only the items whose path holds every
        // word, rendered at the find depth, instead of the whole bar.
        let words = body["words"]?.stringValue.map { $0.lowercased().split { !$0.isLetter && !$0.isNumber } }
        let listed = words.map { words in
            MacMenuBar.Reading(items: reading.items.filter { item in
                let path = item.titlePath.joined(separator: " ").lowercased()
                return words.allSatisfy(path.contains)
            }, truncated: reading.truncated, unavailable: reading.unavailable, attributeGaps: reading.attributeGaps)
        } ?? reading
        var output: [String: JSONValue] = [:]
        if case .object(let menuJSON) = MacMenuBar.json(listed, statesKnown: statesKnown,
                                                         depth: words == nil ? MacMenuBar.maxPathDepth : MacMenuBar.findPathDepth) {
            output = menuJSON
        }
        output["trusted"] = .bool(true)
        output["app"] = app.toJSON()
        // Find a window-unmatched command in menu names and key equivalents; read only matched items without opening or pressing.
        if wanted != nil || wantedChord != nil {
            // Exact titles first, level by level from the top; prefix only
            // where no exact one exists.
            func exact(_ item: MacMenuBar.Item) -> [Bool] {
                zip(item.titlePath.map(MacMenuBar.normalized), wantedLevels).map { $0 == $1 }
            }
            let literalHits = reading.items.filter(isWanted)
            let nameHits = literalHits.isEmpty && wantedLevels.count == 1 && roleName != nil
                ? reading.items.filter { $0.titlePath.last.map(MacMenuBar.normalized) == roleName }
                : literalHits
            var hits = wanted == nil
                ? reading.items.filter(hasChord)
                : nameHits.enumerated().sorted {
                    exact($0.element) != exact($1.element)
                        ? exact($0.element).lexicographicallyPrecedes(exact($1.element)) { $0 && !$1 }
                        : $0.offset < $1.offset
                }.map(\.element)
            if wantedLevels.count > 1, let first = hits.first {
                let best = exact(first)
                hits = hits.filter { exact($0) == best }
            }
            hits = MacMenuBar.uniqueCommands(hits, prefer: hasChord)
            let choices = hits
            if let occurrence = selected?.occurrence {
                // An ordinal names an occurrence of ONE full path. Across
                // different paths it remains ambiguous, never a global rank.
                let paths = Set(hits.map { $0.titlePath.map(MacMenuBar.normalized) })
                if paths.count == 1 {
                    hits = hits.indices.contains(occurrence - 1) ? [hits[occurrence - 1]] : []
                }
            }
            output["found"] = .array(hits.prefix(3).map { item in
                var row: [String: JSONValue] = [
                    "path": MacScreenViewTextRedaction.redactedLegendString(
                        MacMenuBar.choice(item, among: choices), valueChars: MacMenuBar.pathChars(MacMenuBar.findPathDepth) + 24
                    ),
                ]
                if statesKnown { row["enabled"] = item.enabled.map(JSONValue.bool) ?? .null }
                if !item.attributeGaps.isEmpty { row["attribute_gaps"] = .array(item.attributeGaps.map(JSONValue.string)) }
                if let shortcut = shortcut(item) {
                    row["shortcut"] = .string(shortcut.glyphs)
                    row["chord"] = .string(shortcut.chord)
                }
                return .object(row)
            })
        }
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        return MacControlResult(
            ok: true,
            action: "menu",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// THE PRESS. Walk (to resolve the NAME into an address), then AXPress
    /// through the same actuator `ax_act` uses.
    ///
    /// A DISABLED item refuses IN WORDS and presses nothing. That is the same
    /// refusal shape `act` holds: greyed out is a fact about the app's state,
    /// and pressing anyway would either do nothing (and be reported as done) or
    /// hit whatever the index chain now points at.
    func handleMenuPress(_ body: [String: JSONValue]) async -> MacControlResult {
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        // A string or list names one path; each listed title is one level without separators.
        let requested: String
        if case .array(let parts)? = body["path"] {
            var levels: [String] = []
            for part in parts {
                guard case .string(let text) = part else {
                    return refuse("bad_path", "menu_press path as a list takes one menu title per entry, as text.")
                }
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.rangeOfCharacter(from: CharacterSet(charactersIn: "›»→>/|")) == nil else {
                    return refuse("bad_path", "A listed menu title is empty or contains a level separator (› » → > / |); give each level as its own entry.")
                }
                levels.append(title)
            }
            requested = levels.joined(separator: " › ")
        } else {
            requested = body["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !requested.isEmpty else {
            return refuse(
                "missing_path",
                "menu_press needs `path` — the menu path to press, like \"File › Export › PDF\" (a string, or its components as a list)."
            )
        }
        let continuation = MacWorkContinuation.current.flatMap { $0.isPending ? $0 : nil }
        let app: MacAXAppInfo
        switch menuTarget(body, continuation: continuation) {
        case .refused(let refusal): return refusal
        case .app(let hit): app = hit
        }
        if let continuation, continuation.app?.processIdentifier != app.processIdentifier {
            return refuse("continuation_target_mismatch", continuation.modelContext)
        }
        // Walk only the path's own top-level menu.
        let reading = MacMenuBar.read(
            source: accessibilitySource, pid: app.processIdentifier,
            top: MacMenuBar.components(MacMenuBar.selection(requested).path).first,
            matchingPath: MacMenuBar.components(MacMenuBar.selection(requested).path),
            depth: MacMenuBar.findPathDepth
        )
        if let unavailable = reading.unavailable {
            return refuse(
                unavailable,
                "\(app.name)'s menu bar could not be read: \(unavailable). No command was pressed."
            )
        }
        guard !reading.truncated else {
            return refuse("menu_coverage_incomplete", "The requested menu branch could not be read completely; command absence or uniqueness is unknown. No command was pressed. Read that branch before continuing.",
                          ["attribute_gaps": .array(reading.attributeGaps.map(JSONValue.string))])
        }
        // A background app's enabled states are stale: let its own handler
        // decide instead of refusing on them. A front:true press (just raised)
        // judges enabled below, after the app has revalidated.
        let requireFront = body["require_front"] == .bool(true)
        let statesKnown = !requireFront && accessibilitySource.frontmostApp()?.processIdentifier == app.processIdentifier
        let wantedChord = body["chord"]?.stringValue
            .flatMap { try? MacKeySyntax.parseChords($0) }.flatMap { $0.count == 1 ? $0.first : nil }
        func hasChord(_ item: MacMenuBar.Item) -> Bool {
            guard let wantedChord,
                  case .resolved(let element) = accessibilityActSource.resolve(menuPath: item.path, inAppPid: app.processIdentifier, titlePath: item.titlePath),
                  let shortcut = accessibilityActSource.menuShortcut(element),
                  let chord = try? MacKeySyntax.parseChords(shortcut.chord).first else { return false }
            return chord.keyCode == wantedChord.keyCode && chord.modifiers == wantedChord.modifiers
        }
        // Rank using the app's published enabled states before temporarily
        // admitting stale background states for the live revalidation below.
        let commands = MacMenuBar.uniqueCommands(reading.items, prefer: hasChord)
        let resolution = MacMenuBar.resolve(requested, among: statesKnown ? commands : commands.map {
            MacMenuBar.Item(titlePath: $0.titlePath, path: $0.path, enabled: true, hasSubmenu: $0.hasSubmenu, commandKey: $0.commandKey, attributeGaps: $0.attributeGaps)
        }, prefer: hasChord)
        guard case .matched(let item) = resolution else {
            let code: String = {
                switch resolution {
                case .disabled: return "menu_item_disabled"
                case .unavailable: return "menu_item_state_unavailable"
                case .ambiguous: return "menu_path_ambiguous"
                default: return "menu_path_not_found"
                }
            }()
            var words = MacMenuBar.words(for: resolution, requested: requested)
                ?? "I couldn't find \"\(requested)\" in \(app.name)'s menu bar."
            if case .ambiguous = resolution {
                let wanted = MacMenuBar.components(MacMenuBar.selection(requested).path).map(MacMenuBar.normalized)
                let chords = commands.filter { $0.titlePath.map(MacMenuBar.normalized) == wanted }.compactMap { item -> String? in
                    guard case .resolved(let element) = accessibilityActSource.resolve(
                        menuPath: item.path, inAppPid: app.processIdentifier, titlePath: item.titlePath),
                          let shortcut = accessibilityActSource.menuShortcut(element) else { return nil }
                    let name = MacScreenViewTextRedaction.redactedLegendString(
                        MacMenuBar.choice(item, among: commands), valueChars: MacMenuBar.pathChars(MacMenuBar.findPathDepth) + 24)
                    return (name.stringValue ?? "[redacted]") + ": " + shortcut.chord
                }
                if !chords.isEmpty {
                    words += " Key chords: " + chords.joined(separator: "; ") + ". Use mac.act with verb:key and target:the chord."
                }
            }
            return refuse(
                code,
                words,
                ["requested_path": .string(requested)]
            )
        }
        // Resolved from the MENU BAR, never from a window root: a menu bar is
        // not under any window, so a window-relative resolve of this index
        // chain would land on an unrelated element inside the document.
        func driftRefusal() -> MacControlResult {
            refuse("menu_path_drifted", "The menu changed, so the selected command was not pressed. Read the menu again.")
        }
        var target: MacAXActTarget
        switch accessibilityActSource.resolve(
            menuPath: item.path,
            inAppPid: app.processIdentifier, titlePath: item.titlePath
        ) {
        case .unavailable(let detail): return refuse("ax_evidence_unavailable", detail)
        case .resolved(let hit):
            target = hit
        case .menuPathDrifted: return driftRefusal()
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
        // A front-only press (act with front:true): re-checked at the last
        // moment, so a person who switched apps during the walk wins.
        if requireFront, accessibilitySource.frontmostApp()?.processIdentifier != app.processIdentifier {
            return refuse("front_changed", "\(app.name) is no longer in front, so nothing was pressed.")
        }
        if let refusal = continuation?.refusal() {
            return refuse("continuation_unavailable", refusal)
        }
        // Right after a raise an item can still read greyed out from its last
        // (background) validation. Opening its menu makes the app revalidate,
        // as a person's click does; then it is read again. Still greyed out:
        // the menu is closed and nothing is pressed.
        if requireFront, !target.enabled, let top = item.path.first,
           case .resolved(let bar) = accessibilityActSource.resolve(menuPath: [top], inAppPid: app.processIdentifier, titlePath: nil) {
            guard MacMenuBar.cleanTitle(bar.title ?? bar.value) == item.titlePath.first else {
                return driftRefusal()
            }
            _ = accessibilityActSource.perform(bar, action: "AXPress")
            usleep(150_000)
            guard case .resolved(let fresh) = accessibilityActSource.resolve(menuPath: item.path, inAppPid: app.processIdentifier, titlePath: item.titlePath) else { return driftRefusal() }
            target = fresh
            if !target.enabled {
                if case .resolved(let menu) = accessibilityActSource.resolve(
                    menuPath: Array(item.path.prefix(2)), inAppPid: app.processIdentifier, titlePath: nil
                ) {
                    _ = accessibilityActSource.perform(menu, action: "AXCancel")
                }
                return refuse(
                    "menu_item_disabled",
                    MacMenuBar.words(for: .disabled(item), requested: requested) ?? "\"\(item.display)\" is greyed out.",
                    ["requested_path": .string(requested)]
                )
            }
        }
        guard case .resolved(let fresh) = accessibilityActSource.resolve(menuPath: item.path, inAppPid: app.processIdentifier, titlePath: item.titlePath) else { return driftRefusal() }
        target = fresh
        if requireFront, !target.enabled {
            return refuse(
                "menu_item_disabled",
                MacMenuBar.words(for: .disabled(item), requested: requested) ?? "The menu item is greyed out.",
                ["requested_path": .string(requested)]
            )
        }
        // Again right before the press: the revalidation above takes ~150 ms.
        if requireFront, accessibilitySource.frontmostApp()?.processIdentifier != app.processIdentifier {
            return refuse("front_changed", "\(app.name) is no longer in front, so nothing was pressed.")
        }
        if let refusal = continuation?.refusal() {
            return refuse("continuation_unavailable", refusal)
        }
        let pid = app.processIdentifier
        let windowsBefore: [MacAXWindowRef]
        do { windowsBefore = try accessibilityActSource.windows(pid: pid) }
        catch { return refuse("window_evidence_unavailable", error.localizedDescription) }
        let focusedBefore = accessibilityActSource.focusedElement(pid: pid)
        let shortcut = accessibilityActSource.menuShortcut(target)
            .flatMap { try? MacKeySyntax.parseChords($0.chord).first }
        let declaration: MacActClosedLoop.DeclaredEffect =
            shortcut?.keyCode == 0x00 && shortcut?.modifiers == .command ? .selectAll : .surface(nil)
        let collector = MacAXEffectCollector()
        let observation = effectObserverSource.install(
            pid: pid, kinds: MacActClosedLoop.notificationKinds,
            onNotification: { collector.record($0) })
        defer { observation?.stop() }
        let performedAt = now()
        let outcome = accessibilityActSource.perform(target, action: "AXPress")
        guard outcome == .performed else {
            var evidence = outcome.receipt
            evidence["requested_path"] = .string(item.display)
            evidence["pressed"] = outcome.emissionAttempted ? .null : .bool(false)
            evidence["effects"] = .string(outcome.emissionAttempted ? "unknown" : "none")
            evidence["effects_may_have_occurred"] = .bool(outcome.emissionAttempted)
            evidence["verification"] = .string(MotorVerificationState.unverified.rawValue)
            if outcome.emissionAttempted {
                evidence["ax_readback"] = accessibilityActSource.reread(target).map {
                    MacActReceiptRendering.actedElementJSON($0, redactingValue: true)
                } ?? .null
            }
            return refuse(
                outcome.emissionAttempted ? "menu_press_outcome_unknown" : "menu_press_refused",
                (outcome.emissionAttempted
                    ? "The press on \"\(item.display)\" was attempted, but \(app.name)'s reply did not establish its result. Inspect the app before another action. "
                    : "The press on \"\(item.display)\" was refused before emission. ")
                    + (outcome.cause ?? outcome.rawValue), evidence
            )
        }
        let clock = now
        // A menu/focus reaction is not the command's surface effect. Keep
        // observing within the same deadline until that transition arrives,
        // then enumerate the owning process's windows for the readback.
        let surfaceCommand = if case .surface = declaration { true } else { false }
        let wait = await MacActClosedLoop.waitForEffect(collector: collector,
            waitMs: MacActClosedLoop.defaultWaitMs, startedAt: performedAt, clock: { clock() },
            until: surfaceCommand ? MacActClosedLoop.navigationNotificationKinds : [])
        observation?.stop()
        let windowsAfter: [MacAXWindowRef]
        do { windowsAfter = try accessibilityActSource.windows(pid: pid) }
        catch {
            return MacControlResult(ok: true, action: "menu_press", output: .object([
                "pressed": .bool(true), "status": .string("acted_unobserved"),
                "message": .string("The menu press was delivered, but its window readback failed: " + error.localizedDescription + " Inspect this app before another press.")
            ]), error: nil, durationMs: Int(now().timeIntervalSince(started) * 1000))
        }
        let input = surfaceCommand ? nil : focusedBefore.flatMap { accessibilityActSource.textInput($0) }
        let verdict = MacActClosedLoop.verify(declaration,
            value: input?.value, selection: input?.selection,
            surfaceChanged: windowsAfter.contains { window in
                !windowsBefore.contains { $0.handle == window.handle && $0.identity.title == window.identity.title }
            } ? true : nil,
            dismissed: windowsBefore.contains { accessibilityActSource.windowPresence($0) == false } ? true : nil,
            processGone: accessibilitySource.appInfo(pid: pid) == nil,
            notifications: wait.notifications)
        return MacControlResult(
            ok: true,
            action: "menu_press",
            output: .object([
                "pressed": .bool(true),
                "trusted": .bool(true),
                "app": app.toJSON(),
                "path": MacScreenViewTextRedaction.redactedLegendString(
                    item.display,
                    valueChars: MacMenuBar.pathChars(MacMenuBar.findPathDepth)
                ),
                "opens_submenu": .bool(item.hasSubmenu),
                "effect": .object(["notifications": .array(wait.notifications.map(JSONValue.string))]),
            ].merging(verdict.receipt) { _, new in new }),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    // MARK: - Clipboard

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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        let maxChars = MacClipboardRead.clampedMaxChars(body["max_chars"]?.integerValue.flatMap(Int.init(exactly:)))
        var output: [String: JSONValue] = [
            "available": .bool(true),
            "change_count": .int(Int64(contents.changeCount)),
            "types": MacClipboardRead.typesJSON(contents.types),
            "has_non_text": .bool(MacClipboardRead.hasNonTextTypes(contents.types)),
        ]
        if maxChars == 0 {
            output["has_text"] = .bool(contents.text != nil)
            output["text"] = .null
            output["chars"] = .int(Int64(contents.text?.count ?? 0))
            output["returned_chars"] = .int(0)
            output["truncated"] = .bool(!(contents.text?.isEmpty ?? true))
            output["metadata_only"] = .bool(true)
        } else if let raw = contents.text {
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
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }

    /// WRITE. Replaces the general pasteboard's text and then READS IT BACK:
    /// `verified` is that comparison, never the return value of the set call.
    /// The text itself is never echoed — the caller wrote it, and an echo would
    /// route it back out through a channel with no redactor on it.
    func handleClipboardWrite(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        func refuse(_ reason: String, _ words: String, effects: String = "none", remedy: JSONValue? = nil) -> MacControlResult {
            MacControlResult(
                ok: false,
                action: "clipboard_write",
                output: .object(["written": .bool(false), "note": .string(words),
                    "reason": .string(reason), "effects": .string(effects), "remedy": remedy ?? .null]),
                error: reason,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        guard let text = body["text"]?.stringValue else {
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
            return refuse("clipboard_write_refused", "The clipboard write failed after it may have cleared the previous contents. Read the clipboard before deciding what to write.",
                effects: "unknown", remedy: .object([
                    "instruction": .string("Inspect the clipboard's current contents before another write."),
                    "next_call": .object(["tool": .string("app"), "input": .object([
                        "action": .string("mac.clipboard_read"), "args": .object([:])])]),
                ]))
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
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
}
