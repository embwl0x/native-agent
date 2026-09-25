import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension SwiftNativeMacControl {
    // MARK: file/read

    // Synchronous filesystem calls may wait for permission or a volume. They
    // must not hold the actor that owns the operation deadline and settlement.
    nonisolated func handleFileRead(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let maxBytes = max(1, min(Self.intValue(body, "max_bytes") ?? 1_000_000, 1_000_000))
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        // TOCTOU shrink: re-resolve right before the syscall + re-fence.
        // Foundation has no O_NOFOLLOW open, so this still leaves a window
        // between resolve and FileManager open — see fence doc comment.
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let content: String
        let rawData: Data
        do {
            rawData = try fileManagerAdapter.readData(at: url, maxBytes: maxBytes)
            // Mirror Python's `errors="replace"`: non-UTF8 bytes become U+FFFD
            // rather than silently producing an empty string.
            content = String(decoding: rawData, as: UTF8.self)
        } catch {
            throw MacControlError.ioFailure("read \(path): \(error)")
        }
        let sha256Hex: String
        #if canImport(CryptoKit)
        sha256Hex = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        #else
        sha256Hex = ""
        #endif
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/read",
            output: .object([
                "path": .string(path),
                "content": .string(content),
                "bytes": .int(Int64(rawData.count)),
                "sha256": .string(sha256Hex),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/write

    nonisolated func handleFileWrite(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let content = body.stringValue("content") ?? ""
        var append = false
        if case .bool(let b) = body["append"] ?? .null { append = b }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.writeData(
                Data(content.utf8),
                to: url,
                append: append
            )
        } catch {
            throw MacControlError.ioFailure("write \(path): \(error)")
        }
        let verified: Bool = {
            guard let verifier = fileManagerAdapter as? any FileStateVerificationAdapter,
                  verifier.itemExists(at: url),
                  let observed = try? fileManagerAdapter.readData(at: url, maxBytes: 10_000_000) else {
                return false
            }
            let expected = Data(content.utf8)
            return append ? observed.suffix(expected.count) == expected[...] : observed == expected
        }()
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/write",
            output: .object([
                "path": .string(path),
                "bytes": .int(Int64(content.utf8.count)),
                "append": .bool(append),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/list

    nonisolated func handleFileList(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let entries: [URL]
        do {
            entries = try fileManagerAdapter.listDirectory(at: url)
        } catch {
            throw MacControlError.ioFailure("list \(path): \(error)")
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        let names = entries.map { JSONValue.string($0.lastPathComponent) }
        return MacControlResult(
            ok: true,
            action: "file/list",
            output: .object([
                "path": .string(path),
                "entries": .array(names),
                "count": .int(Int64(names.count)),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/move

    nonisolated func handleFileMove(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let src = body.stringValue("src"), !src.isEmpty else {
            throw MacControlError.missingField("src")
        }
        guard let dst = body.stringValue("dst"), !dst.isEmpty else {
            throw MacControlError.missingField("dst")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let srcURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        let dstURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: srcURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: dstURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: srcURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dstURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.moveItem(from: srcURL, to: dstURL)
        } catch {
            throw MacControlError.ioFailure("move \(src) -> \(dst): \(error)")
        }
        let verified = (fileManagerAdapter as? any FileStateVerificationAdapter)
            .map { !$0.itemExists(at: srcURL) && $0.itemExists(at: dstURL) } ?? false
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/move",
            output: .object([
                "src": .string(src),
                "dst": .string(dst),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/trash

    nonisolated func handleFileTrash(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.trashItem(at: url)
        } catch {
            throw MacControlError.ioFailure("trash \(path): \(error)")
        }
        let verified = (fileManagerAdapter as? any FileStateVerificationAdapter)
            .map { !$0.itemExists(at: url) } ?? false
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/trash",
            output: .object([
                "path": .string(path),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: applescript

    func handleAppleScript(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let script = body.stringValue("script"), !script.isEmpty else {
            throw MacControlError.missingField("script")
        }
        let started = now()
        let result: String
        do {
            result = try await appleScriptAdapter.run(script: script)
        } catch {
            return MacControlResult(
                ok: false,
                action: "applescript",
                output: .object(["script": .string(String(script.prefix(200)))]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "applescript",
            output: .object([
                "script": .string(String(script.prefix(200))),
                "stdout": .string(result),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: focus_app / quit_app

    private func requestedAppName(_ body: [String: JSONValue]) throws -> String {
        let value = body.stringValue("app")
            ?? body.stringValue("name")
            ?? body.stringValue("bundle_id")
            ?? body.stringValue("bundleId")
            ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacControlError.missingField("app")
        }
        return trimmed
    }

    func handleFocusApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        if let rawPid = Self.intValue(body, "pid") {
            return await handleFocusExact(pid: Int32(clamping: rawPid), body: body)
        }
        let app = try requestedAppName(body)
        let started = now()
        do {
            try Task.checkCancellation()
            let result = try await appControlAdapter.focusApp(named: app)
            // A cold launch takes a few seconds to come forward; look again
            // briefly before calling the switch failed.
            let verifier = appControlAdapter as? any AppStateVerificationAdapter
            let resolvedApp = result.bundleIdentifier ?? result.matchedName ?? app
            var observedFrontmost = await verifier?.isFrontmostApplication(matching: resolvedApp)
            var looks = 0
            while observedFrontmost == false, looks < 16 {
                try await Task.sleep(nanoseconds: 500_000_000)
                observedFrontmost = await verifier?.isFrontmostApplication(matching: resolvedApp)
                looks += 1
            }
            try Task.checkCancellation()
            let ok = observedFrontmost == true
            let failureReason: String? = if ok {
                nil
            } else if let reason = result.activationFailureReason {
                reason
            } else if observedFrontmost == nil {
                "focus verification unavailable after activation request"
            } else {
                "activation request returned \(result.activationRequestAccepted.map(String.init) ?? String(result.activated)); target was not observed frontmost"
            }
            return MacControlResult(
                ok: ok,
                action: "focus_app",
                output: appControlOutput(
                    result,
                    status: ok ? "focused" : "focus_failed",
                    verified: ok,
                    activated: ok,
                    failureReason: failureReason
                ),
                error: failureReason,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "focus_app",
                output: .object([
                    "requested": .string(app),
                    "status": .string(error is CancellationError ? "cancelled" : "failed"),
                    "error": .string("\(error)"),
                ]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    /// Her-screen Phase 4 — focus an EXACT process, and optionally one exact
    /// window of it: `frame_id` (the window a look was of — must still be
    /// there) or `window` (a recorded identity; falls back to the app's top
    /// window). Never by name, never another instance, never a launch: a pid
    /// that is gone answers `app_gone`. `ok` only when the frontmost pid IS
    /// this pid afterwards.
    func handleFocusExact(pid: Int32, body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        func finish(_ status: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            let front = accessibilitySource.frontmostApp()?.processIdentifier == pid
            let ok = status == "focused" && front
            let reported = ok || status != "focused" ? status : "focus_failed"
            var output: [String: JSONValue] = [
                "status": .string(reported),
                "pid": .int(Int64(pid)),
                "frontmost_pid_matches": .bool(front),
                "verified": .bool(ok),
            ]
            for (key, value) in extra { output[key] = value }
            return MacControlResult(
                ok: ok, action: "focus_app", output: .object(output),
                error: ok ? nil : reported,
                durationMs: Int(now().timeIntervalSince(started) * 1000), viaSwift: true
            )
        }
        #if canImport(AppKit)
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return finish("app_gone")
        }
        if pid == getpid() {
            // Our own app: activate it, never an AX read of ourselves. From the
            // back, NSRunningApplication.activate is cooperative on macOS 14+
            // and the raised app never yields, so NativeAgent was never put
            // back (3 of 3 in her traces, 09-24). NSApp's own call still takes it.
            await MainActor.run { NSApplication.shared.activate(ignoringOtherApps: true) }
            if accessibilitySource.frontmostApp()?.processIdentifier != pid { _ = app.activate() }
            for _ in 0..<20 where accessibilitySource.frontmostApp()?.processIdentifier != pid {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return finish("focused")
        }
        let exact = body.stringValue("frame_id")
        var identity: MacAXWindowIdentity?
        if let exact {
            identity = await lookFrameStore.frame(frameId: exact)?.windowIdentity
            guard let recorded = identity, recorded.pid == pid else { return finish("front_window_changed") }
        } else if case .object(let recorded)? = body["window"] {
            // Title leaves redacted, so the recorded rect/role carry the match.
            let frame = MacFourVerbs.frame(recorded["frame"])
            if case .string(let role)? = recorded["role"] {
                var subrole: String?
                if case .string(let value)? = recorded["subrole"] { subrole = value }
                identity = MacAXWindowIdentity(pid: pid, index: nil, role: role, subrole: subrole, frame: frame)
            }
        }
        let windows = accessibilityActSource.windows(pid: pid)
        var chosen: MacAXWindowRef?
        var windowMatched = false
        if let identity,
           case .matched(let hit, _) = MacAXWindowIdentity.match(identity, among: windows.map { ($0, $0.identity) }) {
            chosen = hit
            windowMatched = true
        } else if exact != nil {
            return finish("front_window_changed")
        } else {
            chosen = windows.first
        }
        guard let chosen else { return finish("app_has_no_window") }
        let outcome = accessibilityActSource.raise(chosen)
        guard outcome == .performed else {
            var extra: [String: JSONValue] = ["raise": .string(outcome.rawValue)]
            if let why = accessibilityActSource.raiseDiagnostic { extra["diagnostic"] = .string(why) }
            return finish("focus_failed", extra)
        }
        return finish("focused", [
            "window_matched": .bool(windowMatched),
            "window_frame": chosen.identity.frame?.toJSON() ?? .null,
        ])
        #else
        return finish("unsupported")
        #endif
    }

    /// Launch Services acceptance is transport evidence, not settlement. The
    /// result stays explicitly unverified; the four-verb surface follows this
    /// operation with a fresh screen and speaks only what that read shows.
    func handleOpenTarget(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let raw = body.stringValue("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "file" || (["http", "https"].contains(scheme) && url.host != nil)) else {
            throw MacControlError.missingField("url")
        }
        let started = now()
        let accepted = await openTargetAdapter.requestOpen(url)
        return MacControlResult(
            ok: accepted,
            action: "open_target",
            output: .object([
                "status": .string(accepted ? "requested" : "request_refused"),
                "verified": .bool(false),
            ]),
            error: accepted ? nil : "Launch Services did not accept the open request",
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    func handleQuitApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let app = try requestedAppName(body)
        let started = now()
        do {
            let result = try await appControlAdapter.quitApp(named: app)
            let ok = result.terminated || result.alreadyInDesiredState
            let observedRunning = await (appControlAdapter as? any AppStateVerificationAdapter)?
                .isApplicationRunning(matching: app)
            let verified = ok && observedRunning == false
            return MacControlResult(
                ok: ok,
                action: "quit_app",
                output: appControlOutput(
                    result,
                    status: ok ? "quit_requested" : "quit_failed",
                    verified: verified
                ),
                error: ok ? nil : "quit_app failed for \(app)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "quit_app",
                output: .object([
                    "requested": .string(app),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    private func appControlOutput(
        _ result: AppControlRunResult,
        status: String,
        verified: Bool,
        activated: Bool? = nil,
        failureReason: String? = nil
    ) -> JSONValue {
        .object([
            "requested": .string(result.requestedName),
            "matched_name": result.matchedName.map { .string($0) } ?? .null,
            "bundle_identifier": result.bundleIdentifier.map { .string($0) } ?? .null,
            "process_identifier": result.processIdentifier.map { .int(Int64($0)) } ?? .null,
            "launched": .bool(result.launched),
            "activated": .bool(activated ?? result.activated),
            "activation_request_accepted": result.activationRequestAccepted.map { .bool($0) } ?? .null,
            "activation_fallback_attempted": .bool(result.activationFallbackAttempted),
            "activation_fallback_succeeded": .bool(result.activationFallbackSucceeded),
            "failure_reason": failureReason.map { .string($0) } ?? .null,
            "terminated": .bool(result.terminated),
            "already_in_desired_state": .bool(result.alreadyInDesiredState),
            "verified": .bool(verified),
            "status": .string(status),
        ])
    }

    // MARK: spotlight

    func handleSpotlight(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let query = body.stringValue("query") ?? body.stringValue("q") ?? ""
        if query.isEmpty {
            throw MacControlError.missingField("query")
        }
        let limit = max(1, min(Self.intValue(body, "limit") ?? 10, 200))
        let started = now()
        let result = try await processAdapter.run(
            executable: "/usr/bin/mdfind",
            arguments: [query],
            timeoutSeconds: 10
        )
        let lines = result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
            // Consult the fence like the file handlers do — raw mdfind hits
            // would otherwise leak paths file read/list refuse to touch.
            .filter { MacControlSensitivePathFence.reason(forPath: $0) == nil }
            .prefix(limit)
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: result.exitCode == 0 && !result.timedOut,
            action: "spotlight",
            output: .object([
                "query": .string(query),
                "results": .array(lines.map { .string($0) }),
                "count": .int(Int64(lines.count)),
                "timed_out": .bool(result.timedOut),
            ]),
            error: result.timedOut
                ? "spotlight timed out"
                : (result.exitCode == 0 ? nil : "mdfind exit \(result.exitCode) stderr=\(result.stderr.prefix(200))"),
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: shell

    func handleShell(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let command = body.stringValue("command"), !command.isEmpty else {
            throw MacControlError.missingField("command")
        }
        if let reason = MacControlShellWhitelist.validate(command) {
            throw MacControlError.shellNotWhitelisted(reason)
        }
        let timeout = max(1, min(Self.intValue(body, "timeout") ?? 60, 120))
        let started = now()
        let result = try await processAdapter.run(
            executable: "/bin/sh",
            arguments: ["-c", command],
            timeoutSeconds: timeout
        )
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: result.exitCode == 0 && !result.timedOut,
            action: "shell",
            output: .object([
                "command": .string(String(command.prefix(200))),
                "stdout": .string(String(result.stdout.prefix(4000))),
                "stderr": .string(String(result.stderr.prefix(2000))),
                "exit_code": .int(Int64(result.exitCode)),
                "timed_out": .bool(result.timedOut),
            ]),
            error: result.timedOut
                ? "shell timed out"
                : (result.exitCode == 0 ? nil : "shell exit \(result.exitCode)"),
            durationMs: durationMs,
            viaSwift: true
        )
    }
}
