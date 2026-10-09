import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(AppKit)
import AppKit
#endif

extension MacFourVerbs {
    // MARK: 3 — LEGS

    /// Get her THERE. A running app is raised through the existing focus organ,
    /// an installed one is launched, a path or a URL is opened. The reply is
    /// where she landed, as `screen()`. Without `front` nothing is activated:
    /// the app is launched or opened behind, and the reply reads its window.
    /// A launch is awaited to its real completion (a cold start can take
    /// longer than a read); each landing read carries its own AX deadline.
    public func go(_ name: String, front: Bool = false) async -> MacFourVerbsReply {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MacFourVerbsReply(ok: false, text: "Where to? Give me an app, a folder, a file or a link.")
        }
        let behind: [String: JSONValue] = front ? [:] : ["background": .bool(true)]
        func opening(_ url: URL) -> [String: JSONValue] { behind.merging(["url": .string(url.absoluteString)]) { _, new in new } }
        // Read the recipient even while foreground activation is settling.
        var landingApp: String?

        // AppKit cannot raise an app over loginwindow. In User's ordinary setup
        // that is the screensaver layer, and the existing wake organ is the
        // safe, bounded way through it. A four-verb caller should never have to
        // discover a fifth tool or translate `loginwindow` into that action.
        // The look owner wakes only while that layer covers the screen and
        // keeps all wake/injection gates below this surface.
        if front, case .blind(let readiness) = await sight(part: nil),
           readiness.detail["error"] == .string("display_obstructed")
            || readiness.detail["error"] == .string("mac_locked") {
            return readiness
        }

        let result: MacControlResult
        let moved: String
        var verificationDestination = trimmed
        var settlesAsynchronously = false
        if let url = Self.webURL(trimmed) ?? Self.settingsPaneURL(trimmed) {
            do {
                result = try await host.dispatch(action: "open_target", body: opening(url))
            } catch {
                return await landingFailure("I couldn't ask the Mac to open that link.")
            }
            moved = "The Mac accepted the request to open \(trimmed)."
            landingApp = Self.handlerApp(url)
            settlesAsynchronously = true
        } else if let path = Self.filePath(trimmed) ?? namedLocationRoots.first(where: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            do {
                result = try await host.dispatch(action: "open_target", body: opening(path))
            } catch {
                return await landingFailure("I couldn't ask the Mac to open that path.")
            }
            moved = "The Mac accepted the request to open \(path.path)."
            landingApp = Self.handlerApp(path)
            verificationDestination = path.path
            settlesAsynchronously = true
        } else {
            do {
                // The existing app-control organ both launches and raises, then
                // independently verifies that the requested app is frontmost.
                // Behind, it launches without activating and raises nothing.
                let appResult = try await host.dispatch(
                    action: "focus_app", body: behind.merging(["app": .string(trimmed)]) { _, new in new })
                if appResult.ok {
                    result = appResult
                    let out = Self.object(appResult.output)
                    // Arrival is checked against the app that was resolved,
                    // never a name that merely contains the one asked for.
                    verificationDestination = Self.string(out["bundle_identifier"]) ?? trimmed
                    landingApp = verificationDestination
                    moved = front ? "Switched to \(trimmed)."
                        : out["launched"] == .bool(true) ? "Launched \(trimmed) behind; nothing came to the front."
                        : "\(trimmed) is running behind; nothing came to the front."
                    settlesAsynchronously = true
                } else {
                    // Search folders only when no such app exists. An app that
                    // was found but slow to come forward is not a folder, and the
                    // search can raise a Desktop prompt that holds the whole turn.
                    var appMissing = false
                    if case .object(let out) = appResult.output, out["status"] == .string("failed") { appMissing = true }
                    switch !appMissing ? NamedFolderResolution.none : Self.namedFolder(trimmed, under: namedLocationRoots) {
                    case .unique(let folder):
                        result = try await host.dispatch(action: "open_target", body: opening(folder))
                        moved = "The Mac accepted the request to open \(folder.path)."
                        landingApp = Self.handlerApp(folder)
                        verificationDestination = folder.path
                        settlesAsynchronously = true
                    case .ambiguous(let parents):
                        let places = parents.joined(separator: " and ")
                        return await landingFailure(
                            "More than one common folder is named \"\(trimmed)\" (in \(places)). Which one? I haven't opened any of them.",
                            detail: ["error": .string("named_location_ambiguous")]
                        )
                    case .none:
                        // Say why the switch failed (e.g. the person took the Mac back), not just "unconfirmed".
                        if let why = appResult.error, !why.isEmpty, !why.contains("app_not_found") {
                            return MacFourVerbsReply(ok: false, text: "I couldn't switch to \(trimmed): \(why)",
                                                     detail: Self.operationDetail(appResult))
                        }
                        result = appResult
                        moved = "Switched to \(trimmed)."
                    }
                }
            } catch {
                return await landingFailure("I couldn't switch to \(trimmed).")
            }
        }
        guard !Task.isCancelled else { return MacFourVerbsReply(ok: false, text: "I stopped waiting for the app.") }
        if !front, landingApp == nil {
            return MacFourVerbsReply(ok: result.ok, text: result.ok ? moved + " Nothing came to the front."
                : "I couldn't complete the request to go to \(trimmed).", detail: Self.operationDetail(result))
        }
        let windowless: JSONValue = .string(landingApp == nil ? "no_frontmost_window" : "no_window_in_app")
        var landing = await sight(part: nil, app: landingApp)
        let needsSettlement: Bool
        switch landing {
        case .seen(let first): needsSettlement = Self.destination(verificationDestination, matches: first) != true
        case .blind(let reply): needsSettlement = landingApp != nil || reply.detail["error"] == windowless
        }
        if settlesAsynchronously, needsSettlement {
            await clock.sleep(seconds: 0.5)
            landing = await sight(part: nil, app: landingApp)
        }
        // 2026-09-22: an app raised with every window closed stays windowless
        // until reopened. Opening its bundle while it runs makes Launch
        // Services send kAEReopenApplication, the Dock-click event. Once.
        if !Task.isCancelled, case .blind(let reply) = landing, reply.detail["error"] == windowless,
           result.ok, result.action == "focus_app",
           case .object(let out) = result.output, case .string(let bundle)? = out["bundle_identifier"],
           let appURL = Self.applicationURL(bundleIdentifier: bundle) {
            _ = try? await host.dispatch(action: "open_target", body: opening(appURL))
            await clock.sleep(seconds: 0.5)
            landing = await sight(part: nil, app: landingApp)
        }
        switch landing {
        case .blind(let reply):
            var detail = Self.operationDetail(result).merging(reply.detail) { current, _ in current }
            let ownWindow = reply.detail["status"] == .string("in_process_route")
            if ownWindow, !result.ok { detail["execute_in_process"] = .bool(false) }
            return MacFourVerbsReply(
                ok: result.ok,
                text: (result.ok ? moved : "I couldn't confirm that I got to \(trimmed).")
                    + " " + (ownWindow ? "My own window uses in-process page inspection." : reply.text),
                detail: detail
            )
        case .seen(let hit):
            let landed = Self.destination(verificationDestination, matches: hit)
            var detail = Self.operationDetail(result).merging(hit.detail) { current, _ in current }
            detail["observed_destination"] = landed.map(JSONValue.bool) ?? .null
            // The fresh screen is the proof: already in front counts as arrived.
            if landed == true {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_screen_destination_match")
                return MacFourVerbsReply(
                    ok: true,
                    text: (result.ok ? moved : "\(trimmed) is in front.") + " Now looking at " + hit.place + ".\n" + hit.render,
                    detail: detail
                )
            }
            if landed == nil, result.ok {
                return MacFourVerbsReply(
                    ok: true,
                    text: moved + " The fresh screen is " + hit.place
                        + ", but it does not expose enough destination identity to prove the exact landing.\n"
                        + hit.render,
                    detail: detail
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
    //
    // Three shapes, tested in order, with no app-name branch anywhere: a URL
    // with a web scheme, a path or common home folder, then an app NAME
    // (running first, then installed). Other folder names use the bounded search.

    /// The app that receives this link or path, independent of activation.
    static func handlerApp(_ url: URL) -> String? {
        #if canImport(AppKit)
        if url.isFileURL, url.pathExtension.lowercased() == "app" { return Bundle(url: url)?.bundleIdentifier }
        return NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
        #else
        return nil
        #endif
    }

    static func applicationURL(bundleIdentifier: String) -> URL? {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        #else
        return nil
        #endif
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        // Deliberately reject arbitrary custom schemes: `go` is a web/file/app
        // navigator, not a way for a string to select a privileged URL handler.
        guard ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// The one custom scheme `go` opens: a System Settings pane link
    /// (`x-apple.systempreferences:com.apple.wifi-settings-extension`). It
    /// shows a pane and changes nothing.
    static func settingsPaneURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "x-apple.systempreferences" else { return nil }
        return url
    }

    static func filePath(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme?.lowercased() == "file" { return url }
        var path = text
        if path.hasPrefix("~") {
            path = NSHomeDirectory() + String(path.dropFirst())
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private enum NamedFolderResolution {
        case none
        case unique(URL)
        case ambiguous([String])
    }

    /// A bare destination name gets one small, predictable filesystem fallback
    /// after app activation says it is not an app. Search only direct children
    /// of the familiar home folders; never recurse, fuzzy-match, or pick the
    /// first duplicate. The roots are injected so tests do not inspect the
    /// developer's home directory.
    private static func namedFolder(_ name: String, under roots: [URL]) -> NamedFolderResolution {
        let manager = FileManager.default
        var matches: [URL] = []
        var seenPaths: Set<String> = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard let children = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where child.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let path = child.standardizedFileURL.path
                if seenPaths.insert(path).inserted { matches.append(child.standardizedFileURL) }
            }
        }

        if matches.isEmpty { return .none }
        if matches.count == 1 { return .unique(matches[0]) }
        return .ambiguous(matches.map { $0.deletingLastPathComponent().lastPathComponent })
    }

    static func commonHomeLocationRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Whether the fresh screen proves the requested destination. `nil` means
    /// the surface does not publish enough identity to decide (common for a URL
    /// whose page title does not resemble its host); it never means success.
    static func destination(_ requested: String, matches sighting: Sighting) -> Bool? {
        // Screen prose can mention a host or filename without being there.
        // Neither establishes destination identity.
        if webURL(requested) != nil || filePath(requested) != nil { return nil }
        // A pane id does not spell its window title ("Wi‑Fi"): Settings in
        // front is as far as the screen can prove.
        if settingsPaneURL(requested) != nil {
            return sighting.bundleIdentifier == "com.apple.systempreferences" ? nil : false
        }
        let wanted = normalize(requested)
        if let bundle = sighting.bundleIdentifier, bundle.lowercased() == requested.lowercased() { return true }
        guard !wanted.isEmpty, let app = sighting.appName.map(normalize) else { return nil }
        return app == wanted
    }

    private func landingFailure(
        _ line: String,
        detail: [String: JSONValue] = [:]
    ) async -> MacFourVerbsReply {
        switch await sight(part: nil) {
        case .blind:
            return MacFourVerbsReply(
                ok: false,
                text: line,
                detail: detail.merging(["error": .string("go_failed")]) { current, _ in current }
            )
        case .seen(let hit):
            return MacFourVerbsReply(
                ok: false,
                text: line + " Still looking at " + hit.place + ".\n" + hit.render,
                detail: detail.merging(["error": .string("go_failed")]) { current, _ in current }
            )
        }
    }
}
