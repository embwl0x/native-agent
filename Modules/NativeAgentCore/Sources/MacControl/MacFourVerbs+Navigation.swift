import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: `go`, `webURL`; landing targets the recipient returned by Launch Services |

extension MacFourVerbs {
    // MARK: 3 — LEGS

    /// Await launch completion before reading the landing surface; cold starts can outlast read deadlines. Each landing read gets its own bounded AX budget.
    public func go(_ name: String, front: Bool = false, turn: Turn, context: MacOperationContext) async -> MacFourVerbsReply {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MacFourVerbsReply(ok: false, text: "No destination was supplied. Set name to an app, folder, file or link in mac.go.",
                detail: ["error": .string("missing_destination"), "effects": .string("none"),
                    "remedy": .object(["kind": .string("correct_arguments"),
                        "instruction": .string("Supply the intended destination in mac.go args.name."),
                        "next_call": .object(["tool": .string("app"), "input": .object(["find": .string("mac.go")])])])])
        }
        // AppKit cannot raise over loginwindow. Use the shared bounded wake before foreground moves so callers need no separate wake action; background opens
        // leave focus alone.
        let front = front || PersonOnlyWindows.isShowing
        let placement: [String: JSONValue] = front ? ["require_front": .bool(true)] : ["background": .bool(true)]
        func opening(_ url: URL) -> [String: JSONValue] { placement.merging(["url": .string(url.absoluteString)]) { _, new in new } }
        func covered(_ result: MacControlResult) -> MacFourVerbsReply? {
            guard let code = result.error, ["display_obstructed", "mac_locked"].contains(code) else { return nil }
            let why = Self.string(Self.object(result.output)["message"]) ?? MacScreenLock.reply
            return MacFourVerbsReply(ok: false, text: "I can't see the screen right now. " + why,
                                     detail: ["error": .string(code), "message": .string(why)])
        }
        // Read the recipient even while foreground activation is settling.
        var landingApp: String?
        var landedOnSelf = false

        let result: MacControlResult
        var moved: String
        var verificationDestination = trimmed
        var settlesAsynchronously = false
        if let url = Self.webURL(trimmed) ?? Self.settingsPaneURL(trimmed) {
            do {
                result = try await host.dispatch(action: "open_target", body: opening(url), turn: turn, context: context)
            } catch {
                return Self.unknownActionReply(error, operation: "opening \(trimmed)", app: landingApp)
            }
            moved = "The Mac accepted the request to open \(trimmed)."
            settlesAsynchronously = true
        } else if let path = Self.filePath(trimmed) ?? namedLocationRoots.first(where: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            do {
                result = try await host.dispatch(action: "open_target", body: opening(path), turn: turn, context: context)
            } catch {
                return Self.unknownActionReply(error, operation: "opening \(path.path)", app: landingApp)
            }
            moved = "The Mac accepted the request to open \(path.path)."
            verificationDestination = path.path
            settlesAsynchronously = true
        } else {
            do {
                // The app-control owner verifies requested foreground identity; background opens must not activate or raise.
                let appResult = try await host.dispatch(
                    action: "focus_app", body: placement.merging(["app": .string(trimmed)]) { _, new in new }, turn: turn, context: context)
                if let refusal = covered(appResult) { return refusal }
                if appResult.ok {
                    result = appResult
                    let out = Self.object(appResult.output)
                    // Arrival is checked against the app that was resolved, never a name that merely contains the one asked for.
                    verificationDestination = Self.string(out["bundle_identifier"]) ?? trimmed
                    landingApp = verificationDestination
                    // The exact-pid continuation path reports "pid"; the by-name path reports "process_identifier".
                    landedOnSelf = (out["process_identifier"]?.integerValue ?? out["pid"]?.integerValue) == Int64(getpid())
                    moved = front ? "Switched to \(trimmed)."
                        : out["launched"] == .bool(true) ? "Launched \(trimmed) without activating it."
                        : "\(trimmed) is already running; its windows were left as they were."
                    settlesAsynchronously = true
                } else {
                    return MacFourVerbsReply(ok: false,
                        text: """
                            I couldn't open \(trimmed): \(appResult.error ?? "the app could not be resolved"). Use an exact installed app name, bundle \
                            identifier or .app path; address a folder by its path.
                            """,
                        detail: Self.operationDetail(appResult))
                }
            } catch {
                return Self.unknownActionReply(error, operation: "opening \(trimmed)", app: trimmed)
            }
        }
        guard !Task.isCancelled else {
            var detail = Self.operationDetail(result)
            detail["status"] = .string("cancelled")
            detail["error"] = .string("cancelled")
            detail["effects"] = detail["effects"] ?? .string("unknown")
            detail["remedy"] = Self.inspectAppRemedy(landingApp,
                instruction: "Waiting was cancelled after the open or focus request; inspect the receiving app before another action.")
            return MacFourVerbsReply(ok: false,
                text: """
                    Waiting for the app was cancelled. The open or focus request may already have taken effect; inspect the receiving app before continuing.
                    """, detail: detail)
        }
        if let refusal = covered(result) { return refusal }
        if result.action == "open_target" {
            let output = Self.object(result.output)
            landingApp = Self.string(output["bundle_identifier"]) ?? Self.string(output["matched_name"])
            if result.ok, let receiver = Self.string(output["matched_name"]) ?? landingApp {
                moved += " The receiving app is \(receiver)."
            }
        }
        // Launch Services owns opening the recipient; landing reads describe sight, not delivery. Missing Accessibility or a different window title cannot
        // disprove an accepted open.
        let opened = result.action == "open_target" && result.ok
        func openedDetail(_ base: [String: JSONValue]) -> [String: JSONValue] {
            var detail = base
            detail["status"] = .string("opened")
            if front { detail["front"] = .string("by Launch Services") }
            return detail
        }
        // Going to ourselves is navigation: the arrival is the receipt. Only reading our own window over Accessibility deadlocks, so nothing is read.
        if landedOnSelf {
            var detail = Self.operationDetail(result)
            detail["status"] = .string(front ? "focused" : "running")
            detail["landing_read"] = .string("not read: this app's own window is never read; app (desk.read, mind.inner_state) shows its state")
            return MacFourVerbsReply(ok: result.ok,
                text: moved + " My own window is not read here; app (desk.read, mind.inner_state, agent.introspect) shows my own state.",
                detail: detail)
        }
        if !front, landingApp == nil {
            return MacFourVerbsReply(ok: result.ok, text: result.ok ? moved + " Nothing came to the front."
                : "I couldn't complete the request to go to \(trimmed).",
                detail: opened ? openedDetail(Self.operationDetail(result)) : Self.operationDetail(result))
        }
        var landing = await sight(part: nil, app: landingApp, turn: turn, context: context)
        let needsSettlement: Bool
        switch landing {
        case .seen(let first): needsSettlement = Self.destination(verificationDestination, matches: first) != true
        case .blind(let reply): needsSettlement = landingApp != nil || Self.windowlessApp(reply.detail)
            || reply.detail["error"] == .string("no_frontmost_window")
        }
        if settlesAsynchronously, needsSettlement {
            await clock.sleep(seconds: 0.5)
            landing = await sight(part: nil, app: landingApp, turn: turn, context: context)
        }
        switch landing {
        case .blind(let reply):
            if opened {
                var detail = openedDetail(Self.operationDetail(result))
                detail["landing_read"] = .string(reply.text)
                return MacFourVerbsReply(ok: true, text: moved, detail: detail)
            }
            var detail = reply.detail
            detail["navigation"] = .object(Self.operationDetail(result).merging(["ok": .bool(result.ok)]) { _, new in new })
            let ownWindow = reply.detail["status"] == .string("in_process_route")
            if ownWindow, !result.ok { detail["execute_in_process"] = .bool(false) }
            return MacFourVerbsReply(
                ok: result.ok && reply.ok,
                text: (result.ok ? moved : "I couldn't confirm that I got to \(trimmed).")
                    + " " + (ownWindow ? "My own window uses in-process page inspection." : reply.text),
                detail: detail
            )
        case .seen(let hit):
            // A background request grants no raise, but the recipient may activate itself; let fresh observation report its actual front state.
            let receipt = front ? moved : moved
                + (hit.isFront ? " \(hit.appName ?? trimmed) is in front." : " Nothing came to the front.")
            let landed = Self.destination(verificationDestination, matches: hit)
            var detail = Self.operationDetail(result).merging(hit.detail) { current, _ in current }
            detail["observed_destination"] = landed.map(JSONValue.bool) ?? .null
            // An already-front destination still satisfies arrival when the fresh screen confirms it.
            if landed == true {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_screen_destination_match")
                return MacFourVerbsReply(
                    ok: true,
                    text: (result.ok ? receipt : "\(trimmed) is in front.") + " Now looking at " + hit.place + ".\n" + hit.render,
                    detail: opened ? openedDetail(detail) : detail
                )
            }
            if opened || (landed == nil && result.ok) {
                return MacFourVerbsReply(
                    ok: true,
                    text: receipt + " The fresh screen is " + hit.place
                        + (landed == nil ? ", but it does not expose enough destination identity to prove the exact landing.\n" : ".\n")
                        + hit.render,
                    detail: opened ? openedDetail(detail) : detail
                )
            }
            return MacFourVerbsReply(
                ok: false,
                text: (result.ok ? "I didn't arrive at \(trimmed)." : "I couldn't complete the request to go to \(trimmed).")
                    + " The fresh screen is " + hit.place + ".\n" + hit.render,
                detail: detail
            )
        }
    }

    // MARK: - Where "there" is
    // Parse web URLs, paths/home folders, then app names in that order so an app-name guess cannot capture an explicit destination.

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        // Deliberately reject arbitrary custom schemes: `go` is a web/file/app navigator, not a way for a string to select a privileged URL handler.
        guard ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Allow only the System Settings custom scheme because it opens a pane without granting arbitrary privileged URL handlers.
    static func settingsPaneURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "x-apple.systempreferences" else { return nil }
        return url
    }

    static func filePath(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme?.lowercased() == "file" { return url }
        let path = NativeAgentWorkspaceRoot.fileSpelling(text)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func commonHomeLocationRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Whether the fresh screen proves the requested destination. `nil` means the surface does not publish enough identity to decide (common for a URL whose
    /// page title does not resemble its host); it never means success.
    static func destination(_ requested: String, matches sighting: Sighting) -> Bool? {
        // Screen prose can mention a host or filename without being there. Neither establishes destination identity.
        if webURL(requested) != nil || filePath(requested) != nil { return nil }
        // A pane id does not spell its window title ("Wi‑Fi"): Settings in front is as far as the screen can prove.
        if settingsPaneURL(requested) != nil {
            return sighting.bundleIdentifier == "com.apple.systempreferences" ? nil : false
        }
        let wanted = normalize(requested)
        if let bundle = sighting.bundleIdentifier, bundle.lowercased() == requested.lowercased() { return true }
        guard !wanted.isEmpty, let app = sighting.appName.map(normalize) else { return nil }
        return app == wanted
    }

}
