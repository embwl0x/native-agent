import Foundation
import NativeAgentCore
import PersistenceCore

extension MacFourVerbs {
    // MARK: 3 — LEGS

    /// Get her THERE. A running app is raised through the existing focus organ,
    /// an installed one is launched, a path or a URL is opened. The reply is
    /// where she landed, as `screen()`.
    public func go(_ name: String) async -> MacFourVerbsReply {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MacFourVerbsReply(ok: false, text: "Where to? Give me an app, a folder, a file or a link.")
        }

        // AppKit cannot raise an app over loginwindow. In User's ordinary setup
        // that is the screensaver layer, and the existing wake organ is the
        // safe, bounded way through it. A four-verb caller should never have to
        // discover a fifth tool or translate `loginwindow` into that action.
        // `sight` nudges only when it actually observes that layer and keeps all
        // wake/injection gates below this surface.
        if case .blind(let readiness) = await sight(part: nil),
           readiness.detail["error"] == .string("display_obstructed") {
            return readiness
        }

        let result: MacControlResult
        let moved: String
        var verificationDestination = trimmed
        var settlesAsynchronously = false
        if let url = Self.webURL(trimmed) {
            do {
                result = try await host.dispatch(action: "open_target", body: ["url": .string(url.absoluteString)])
            } catch {
                return await landingFailure("I couldn't ask the Mac to open that link.")
            }
            moved = "The Mac accepted the request to open \(trimmed)."
            settlesAsynchronously = true
        } else if let path = Self.filePath(trimmed) {
            do {
                result = try await host.dispatch(action: "open_target", body: ["url": .string(path.absoluteString)])
            } catch {
                return await landingFailure("I couldn't ask the Mac to open that path.")
            }
            moved = "The Mac accepted the request to open \(path.path)."
            settlesAsynchronously = true
        } else {
            do {
                // The existing app-control organ both launches and raises, then
                // independently verifies that the requested app is frontmost.
                let appResult = try await host.dispatch(action: "focus_app", body: ["app": .string(trimmed)])
                if appResult.ok {
                    result = appResult
                    moved = "Switched to \(trimmed)."
                } else {
                    switch Self.namedFolder(trimmed, under: namedLocationRoots) {
                    case .unique(let folder):
                        result = try await host.dispatch(
                            action: "open_target",
                            body: ["url": .string(folder.absoluteString)]
                        )
                        moved = "The Mac accepted the request to open \(folder.path)."
                        verificationDestination = folder.path
                        settlesAsynchronously = true
                    case .ambiguous(let parents):
                        let places = parents.joined(separator: " and ")
                        return await landingFailure(
                            "More than one common folder is named \"\(trimmed)\" (in \(places)). Which one? I haven't opened any of them.",
                            detail: ["error": .string("named_location_ambiguous")]
                        )
                    case .none:
                        result = appResult
                        moved = "Switched to \(trimmed)."
                    }
                }
            } catch {
                return await landingFailure("I couldn't switch to \(trimmed).")
            }
        }
        var landing = await sight(part: nil)
        if settlesAsynchronously,
           case .seen(let first) = landing,
           Self.destination(verificationDestination, matches: first) != true {
            await clock.sleep(seconds: 0.5)
            landing = await sight(part: nil)
        }
        switch landing {
        case .blind(let reply):
            return MacFourVerbsReply(
                ok: result.ok,
                text: (result.ok ? moved : "I couldn't confirm that I got to \(trimmed).") + " " + reply.text,
                detail: Self.operationDetail(result).merging(reply.detail) { current, _ in current }
            )
        case .seen(let hit):
            let landed = Self.destination(verificationDestination, matches: hit)
            var detail = Self.operationDetail(result).merging(hit.detail) { current, _ in current }
            detail["observed_destination"] = landed.map(JSONValue.bool) ?? .null
            if landed == true {
                if result.ok == false {
                    detail["mechanism_operation_state"] = detail["operationState"] ?? .null
                    detail["mechanism_verification"] = detail["verification"] ?? .null
                    detail["operationState"] = .string(MacControlOperationState.completed.rawValue)
                    detail["outcome_reconciled"] = .bool(true)
                }
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_screen_destination_match")
                return MacFourVerbsReply(
                    ok: true,
                    text: (result.ok
                        ? moved
                        : "The activation report lagged, but the fresh screen shows I arrived at \(trimmed).")
                        + " Now looking at " + hit.place + ".\n" + hit.render,
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
                text: "I didn't arrive at \(trimmed). The fresh screen is still " + hit.place + ".\n" + hit.render,
                detail: detail
            )
        }
    }

    // MARK: - Where "there" is
    //
    // Three shapes, tested in order, with no app-name branch anywhere: a URL
    // with a web scheme, a filesystem path, then a NAME (running first, then
    // installed). A string that is none of those is not guessed at.

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        // Deliberately reject arbitrary custom schemes: `go` is a web/file/app
        // navigator, not a way for a string to select a privileged URL handler.
        guard ["http", "https"].contains(scheme), url.host != nil else { return nil }
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
        if let url = webURL(requested) {
            guard let host = url.host?.lowercased() else { return nil }
            let hostWords = host
                .replacingOccurrences(of: "www.", with: "")
                .split(separator: ".")
                .map(String.init)
                .filter { $0.count > 2 && !["com", "org", "net", "io", "app"].contains($0) }
            guard !hostWords.isEmpty else { return nil }
            let visible = normalize(sighting.place + " " + sighting.render)
            return hostWords.contains { visible.contains(normalize($0)) } ? true : nil
        }
        if let path = filePath(requested) {
            let leaf = normalize(path.lastPathComponent)
            guard !leaf.isEmpty else { return nil }
            let stem = normalize(path.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " "))
            let visible = normalize(sighting.place + " " + sighting.render)
            return visible.contains(leaf) || (stem.count >= 3 && visible.contains(stem))
        }
        let wanted = normalize(requested)
        guard !wanted.isEmpty, let app = sighting.appName.map(normalize) else { return nil }
        return app.contains(wanted) || wanted.contains(app)
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
