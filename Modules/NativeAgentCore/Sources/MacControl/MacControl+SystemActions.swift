import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
import IOKit.hidsystem
import CryptoKit
import AppKit
import IOKit.hidsystem
// Blueprint: | `MacControl+SystemActions.swift` | `SwiftNativeMacControl`: `handleFileRead`, `handleFileWrite`, `handleFileList`, `handleMedia` (Now Playing system keys and running-player observations) |
#endif

extension SwiftNativeMacControl {
    // MARK: file/read

    // Synchronous filesystem calls may wait for permission or a volume. They
    // must not hold the actor that owns the operation deadline and settlement.
    nonisolated func handleFileRead(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body["path"]?.stringValue, !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let maxBytes = max(1, min(body["max_bytes"]?.integerValue.flatMap(Int.init(exactly:)) ?? 1_000_000, 1_000_000))
        let started = now()
        // TOCTOU shrink: re-resolve right before the syscall + re-fence.
        // Foundation has no O_NOFOLLOW open, so this still leaves a window
        // between resolve and FileManager open — see fence doc comment.
        let url = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(
            path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
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
            durationMs: durationMs
        )
    }

    // MARK: file/write

    nonisolated func handleFileWrite(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body["path"]?.stringValue, !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        guard case .string(let content)? = body["content"] else {
            throw MacControlError.missingField("content")
        }
        var append = false
        if case .bool(let b) = body["append"] ?? .null { append = b }
        let started = now()
        let url = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(
            path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
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
            let expected = Data(content.utf8)
            guard fileManagerAdapter.itemExists(at: url),
                  let observed = try? fileManagerAdapter.readData(
                    at: url, maxBytes: expected.count + (append ? 0 : 1), fromEnd: append
                  ) else {
                return false
            }
            return observed == expected
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
            durationMs: durationMs
        )
    }

    // MARK: file/list

    nonisolated func handleFileList(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body["path"]?.stringValue, !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let url = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(
            path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
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
            durationMs: durationMs
        )
    }

    // MARK: file/move

    nonisolated func handleFileMove(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let src = body["src"]?.stringValue, !src.isEmpty else {
            throw MacControlError.missingField("src")
        }
        guard let dst = body["dst"]?.stringValue, !dst.isEmpty else {
            throw MacControlError.missingField("dst")
        }
        if let reason = MacControlSensitivePathFence.mutationReason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.mutationReason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let srcURL = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(src, relativeTo: base), followFinalLink: false)
        let dstURL = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(dst, relativeTo: base), followFinalLink: false)
        let resolvedSrc = NativeAgentWorkspaceRoot.canonicalFileURL(srcURL)
        let resolvedDst = NativeAgentWorkspaceRoot.canonicalFileURL(dstURL)
        if let reason = MacControlSensitivePathFence.mutationReason(forPath: resolvedSrc.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.mutationReason(forPath: resolvedDst.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolvedSrc.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolvedDst.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.moveItem(from: srcURL, to: dstURL)
        } catch {
            throw MacControlError.ioFailure("move \(src) -> \(dst): \(error)")
        }
        let verified = !fileManagerAdapter.itemExists(at: srcURL) && fileManagerAdapter.itemExists(at: dstURL)
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
            durationMs: durationMs
        )
    }

    // MARK: file/trash

    nonisolated func handleFileTrash(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body["path"]?.stringValue, !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.mutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let url = NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(
            path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)), followFinalLink: false)
        let resolved = NativeAgentWorkspaceRoot.canonicalFileURL(url)
        if let reason = MacControlSensitivePathFence.mutationReason(forPath: resolved.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolved.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.trashItem(at: url)
        } catch {
            throw MacControlError.ioFailure("trash \(path): \(error)")
        }
        let verified = !fileManagerAdapter.itemExists(at: url)
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/trash",
            output: .object([
                "path": .string(path),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs
        )
    }

    func handleVolume(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let level = body["level"]?.integerValue.flatMap(Int.init(exactly:)), adjust = body["adjust"]?.integerValue.flatMap(Int.init(exactly:))
        guard !(level != nil && adjust != nil),
              level.map({ (0...100).contains($0) }) ?? true,
              adjust.map({ (-100...100).contains($0) }) ?? true else {
            throw MacControlError.missingField("level 0–100 or adjust −100–100, not both")
        }
        var commands: [String] = []
        if let level { commands.append("set volume output volume \(level)") }
        if let adjust {
            commands.append("set v to (output volume of (get volume settings)) + (\(adjust))")
            commands.append("if v < 0 then set v to 0")
            commands.append("if v > 100 then set v to 100")
            commands.append("set volume output volume v")
        }
        if case .bool(let muted)? = body["muted"] { commands.append("set volume output muted \(muted)") }
        commands.append("return ((output volume of (get volume settings)) as string) & \"|||\" & ((output muted of (get volume settings)) as string)")
        let started = now()
        let raw = try await appleScriptAdapter.run(script: commands.joined(separator: "\n"))
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|||")
        guard parts.count == 2, let observed = Int(parts[0]), ["true", "false"].contains(parts[1]) else {
            throw MacControlError.malformedResponse("volume readback")
        }
        return MacControlResult(ok: true, action: "volume",
            output: .object(["level": .int(Int64(observed)), "muted": .bool(parts[1] == "true"),
                             "effects": .string(commands.count == 1 ? "none" : "occurred")]),
            error: nil, durationMs: Int(now().timeIntervalSince(started) * 1000))
    }

    func handleMedia(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let action = body["action"]?.stringValue?.lowercased(),
              ["play", "resume", "pause", "toggle", "next", "skip", "previous"].contains(action) else {
            throw MacControlError.missingField("action: play, resume, pause, toggle, next, skip or previous")
        }
        if ["play", "resume", "pause"].contains(action) {
            return MacControlResult(ok: false, action: "media", output: .object([
                "action": .string(action), "effects": .string("none"),
                "message": .string("The Now Playing owner and playback state cannot be established, so this idempotent action was not sent. Use the player's own action; toggle explicitly requests a play/pause toggle.")
            ]), error: "playback_owner_unavailable", durationMs: 0)
        }
        #if canImport(AppKit)
        let started = now()
        func states() async throws -> [String: JSONValue] {
            var result: [String: JSONValue] = [:]
            for (name, id) in [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")] {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { continue }
                do {
                    let state = try await appleScriptAdapter.run(script: """
                    if application id "\(id)" is running then
                        tell application id "\(id)" to return player state as text
                    end if
                    """)
                    result[name] = .object(["player_state": .string(state.isEmpty ? "not_running" : state)])
                } catch is CancellationError { throw CancellationError() }
                catch { result[name] = .object(["error": .string(error.localizedDescription)]) }
            }
            return result
        }
        let before = try await states()
        let key = ["next", "skip"].contains(action) ? NX_KEYTYPE_NEXT : action == "previous" ? NX_KEYTYPE_PREVIOUS : NX_KEYTYPE_PLAY
        let events = [0xA, 0xB].compactMap { state in
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: (Int(key) << 16) | (state << 8), data2: -1)?.cgEvent
        }
        guard events.count == 2 else { throw MacControlError.malformedResponse("system media key could not be created") }
        try Task.checkCancellation()
        for event in events { event.post(tap: .cghidEventTap) }
        let after = try await states()
        return MacControlResult(ok: true, action: "media",
            output: .object(["action": .string(action), "key_sent": .string(key == NX_KEYTYPE_PLAY ? "play_pause" : action == "previous" ? "previous" : "next"),
                "before": .object(before), "after": .object(after), "playback_state_confirmed": .bool(false),
                "message": .string("System media key sent to the Now Playing app. Play/pause is a toggle. Music and Spotify states, when available, are observations; the Now Playing owner and other apps' playback state cannot be confirmed.")]),
            error: nil, durationMs: Int(now().timeIntervalSince(started) * 1000))
        #else
        throw MacControlError.malformedResponse("system media keys require macOS")
        #endif
    }

    // MARK: applescript

    func handleAppleScript(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let script = body["script"]?.stringValue, !script.isEmpty else {
            throw MacControlError.missingField("script")
        }
        let started = now()
        let result: String
        do {
            // A script can drive the GUI, so it is her hands for its whole run:
            // his taking the Mac back ends the osascript process (cancellation
            // kills its process tree), exactly as it stops a hand mid-gesture.
            enum Lifetime: Sendable { case finished(String), takenOver, unwatched }
            let adapter = appleScriptAdapter, store = attentionStore, binding = MacDriverContext.binding
            let finished: String? = try await ScriptedInputSources.during { try await withThrowingTaskGroup(of: Lifetime.self) { group in
                group.addTask { .finished(try await adapter.run(script: script)) }
                if let binding {
                    group.addTask {
                        for await _ in await store.driverChanges() where !binding.allowsAction { return .takenOver }
                        return .unwatched
                    }
                }
                while let next = try await group.next() {
                    switch next {
                    case .finished(let output): group.cancelAll(); return output
                    case .takenOver: group.cancelAll(); return nil
                    case .unwatched: continue
                    }
                }
                return nil
            } }
            guard let finished else {
                return MacControlResult(
                    ok: false, action: "applescript",
                    output: .object(["script": .string(String(script.prefix(200))), "status": .string("yielded_to_user"),
                                     "effects": .string("unknown"),
                                     "guidance": .string("The person took the Mac back while the script ran, so it was stopped; what it already did is unknown. Look before running it again.")]),
                    error: MacAttentionSessionStore.driverRefusal,
                    durationMs: Int(now().timeIntervalSince(started) * 1000), httpStatus: 409, verification: .unverified)
            }
            result = finished
        } catch {
            return MacControlResult(
                ok: false,
                action: "applescript",
                output: .object(["script": .string(String(script.prefix(200)))]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000)
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
            durationMs: durationMs
        )
    }

    // MARK: focus_app / quit_app

    private func requestedAppName(_ body: [String: JSONValue]) throws -> String {
        let value = body["app"]?.stringValue
            ?? body["name"]?.stringValue
            ?? body["bundle_id"]?.stringValue
            ?? body["bundleId"]?.stringValue
            ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacControlError.missingField("app")
        }
        return trimmed
    }

    func handleFocusApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        if let rawPid = body["pid"]?.integerValue.flatMap(Int.init(exactly:)) {
            return await handleFocusExact(pid: Int32(clamping: rawPid), body: body)
        }
        if let continuation = MacWorkContinuation.current, continuation.isPending, body["background"] != .bool(true) {
            if let refusal = continuation.refusal() {
                return MacControlResult(ok: false, action: "focus_app",
                    output: .object(["message": .string(refusal)]), error: "continuation_unavailable",
                    durationMs: 0)
            }
            guard let app = continuation.app else {
                return MacControlResult(ok: false, action: "focus_app",
                    output: .object(["message": .string(continuation.modelContext)]), error: "continuation_unavailable",
                    durationMs: 0)
            }
            return await handleFocusExact(pid: app.processIdentifier, body: body)
        }
        let app = try requestedAppName(body)
        let started = now()
        var output: [String: JSONValue]
        let failure: String?
        do {
            try Task.checkCancellation()
            // `go` without front reopens or launches behind.
            if body["background"] == .bool(true) {
                let result = try await appControlAdapter.launchApp(named: app)
                return MacControlResult(
                    ok: true, action: "focus_app",
                    output: .object(appControlOutput(result, status: result.launched ? "launched" : "running", verified: false)),
                    error: nil, durationMs: Int(now().timeIntervalSince(started) * 1000)
                )
            }
            let result = try await appControlAdapter.focusApp(named: app)
            try Task.checkCancellation()
            failure = nil
            output = appControlOutput(result, status: "focused", verified: true)
        } catch {
            failure = error.localizedDescription
            output = [
                "requested": .string(app),
                "status": .string(error is CancellationError ? "cancelled" : "failed"),
                "error": .string(error.localizedDescription),
            ]
            if let evidence = error as? ToolFailureError {
                output.merge(evidence.failureEvidence(defaultCode: "focus_failed")) { _, owned in owned }
            }
        }
        return MacControlResult(ok: failure == nil, action: "focus_app", output: .object(output),
            error: failure, durationMs: Int(now().timeIntervalSince(started) * 1000))
    }

    /// Focus an exact process, and optionally one exact
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        #if canImport(AppKit)
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return finish("app_gone")
        }
        if pid == getpid() {
            // Activate our own app without an AX read of ourselves.
            let binding = MacDriverContext.binding
            await MainActor.run {
                if binding?.allowsEmission == true { NSApplication.shared.activate(ignoringOtherApps: true) }
            }
            if accessibilitySource.frontmostApp()?.processIdentifier != pid, binding?.allowsEmission == true { _ = app.activate() }
            try? await MacApplications.observeActivation(of: pid, within: 1)
            return finish("focused")
        }
        let exact = body["frame_id"]?.stringValue
        let continuation = MacWorkContinuation.current.flatMap { $0.isPending ? $0 : nil }
        var identity = continuation?.window
        if continuation != nil {
            guard identity?.pid == pid else { return finish("continuation_target_mismatch") }
        } else if let exact {
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
        } else if exact != nil || continuation != nil {
            return finish("front_window_changed")
        } else {
            chosen = windows.first
        }
        guard let chosen else {
            // Putting back an app that had no window (no window asked for):
            // activate that exact pid; `finish` verifies it is frontmost.
            guard identity == nil, exact == nil else { return finish("app_has_no_window") }
            guard MacDriverContext.binding?.allowsEmission == true else { return finish("yielded_to_user") }
            _ = app.activate()
            try? await MacApplications.observeActivation(of: pid, within: 1)
            return finish("focused", ["window_matched": .bool(false)])
        }
        if let refusal = continuation?.refusal() {
            return finish("continuation_unavailable", ["message": .string(refusal)])
        }
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
        guard let raw = body["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "file" || scheme == "x-apple.systempreferences"
                || (["http", "https"].contains(scheme) && url.host != nil)) else {
            throw MacControlError.missingField("url")
        }
        let started = now()
        do {
            var output = try await openTargetAdapter.requestOpen(url, background: body["background"] == .bool(true))
            output["status"] = .string("requested")
            output["verified"] = .bool(false)
            return MacControlResult(ok: true, action: "open_target", output: .object(output),
                error: nil, durationMs: Int(now().timeIntervalSince(started) * 1000))
        } catch {
            return MacControlResult(ok: false, action: "open_target",
                output: .object(["status": .string("request_refused"), "verified": .bool(false)]),
                error: "Launch Services could not open \(raw): \(error.localizedDescription)",
                durationMs: Int(now().timeIntervalSince(started) * 1000))
        }
    }

    func handleQuitApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let app = try requestedAppName(body)
        let started = now()
        do {
            let result = try await appControlAdapter.quitApp(named: app)
            let ok = result.terminated || result.alreadyInDesiredState
            let observedRunning = await appControlAdapter.isApplicationRunning(matching: app)
            let verified = ok && observedRunning == false
            return MacControlResult(
                ok: ok,
                action: "quit_app",
                output: .object(appControlOutput(
                    result,
                    status: ok ? "quit_requested" : "quit_failed",
                    verified: verified
                )),
                error: ok ? nil : "quit_app failed for \(app)",
                durationMs: Int(now().timeIntervalSince(started) * 1000)
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
    }

    private func appControlOutput(
        _ result: AppControlRunResult,
        status: String,
        verified: Bool
    ) -> [String: JSONValue] {
        [
            "requested": .string(result.requestedName),
            "matched_name": result.matchedName.map { .string($0) } ?? .null,
            "bundle_identifier": result.bundleIdentifier.map { .string($0) } ?? .null,
            "process_identifier": result.processIdentifier.map { .int(Int64($0)) } ?? .null,
            "launched": .bool(result.launched),
            "activated": .bool(result.activated),
            "terminated": .bool(result.terminated),
            "already_in_desired_state": .bool(result.alreadyInDesiredState),
            "verified": .bool(verified),
            "status": .string(status),
        ]
    }

    // MARK: spotlight

    func handleSpotlight(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let query = body["query"]?.stringValue ?? body["q"]?.stringValue ?? ""
        if query.isEmpty {
            throw MacControlError.missingField("query")
        }
        let limit = max(1, min(body["limit"]?.integerValue.flatMap(Int.init(exactly:)) ?? 10, 200))
        let started = now()
        // Her files and the Mac's apps, never the whole disk: unscoped, one
        // query took 10 s and timed out, then 15 s (fresh install, 10-19).
        let roots = [NSHomeDirectory(), "/Applications", "/System/Applications"]
        let scopes = roots.flatMap { ["-onlyin", $0] }
        // Words with no Spotlight syntax are almost always a name: asked as a
        // filename first, and as free words only when no name matches.
        let nameLike = query.rangeOfCharacter(from: CharacterSet(charactersIn: "=<>*\"&|()")) == nil && !query.contains("kMD")
        // What arrived within the budget is the answer, marked partial, with
        // the lever that narrows it; a slow index never turns into an error.
        let budget: TimeInterval = 4
        func search(_ arguments: [String]) async throws -> ProcessRunResult {
            try await processAdapter.run(executable: "/usr/bin/mdfind", arguments: scopes + arguments, currentDirectory: nil,
                                         environment: nil, standardInput: nil,
                                         timeoutSeconds: budget - now().timeIntervalSince(started))
        }
        var result = try await search(nameLike ? ["-name", query] : [query])
        var matched = nameLike ? "name" : "query"
        if nameLike, !result.timedOut, result.exitCode == 0,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           now().timeIntervalSince(started) < budget {
            result = try await search([query])
            matched = "query"
        }
        let partial = result.timedOut
        // A stopped search can end mid-line: only whole lines are paths.
        let whole = partial && !result.stdout.hasSuffix("\n")
            ? String(result.stdout[..<(result.stdout.lastIndex(of: "\n") ?? result.stdout.startIndex)]) : result.stdout
        let lines = whole
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
            // Consult the fence like the file handlers do — raw mdfind hits
            // would otherwise leak paths file read/list refuse to touch.
            .filter { MacControlSensitivePathFence.reason(forPath: $0) == nil }
            .prefix(limit)
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        let files: [JSONValue] = lines.map { path in
            let dates = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
            return .object(["path": .string(path),
                "modified_at": dates?.contentModificationDate.map { .string(NativeTimestampFormat.plainZulu($0)) } ?? .null,
                "added_at": dates?.addedToDirectoryDate.map { .string(NativeTimestampFormat.plainZulu($0)) } ?? .null])
        }
        var output: [String: JSONValue] = [
            "query": .string(query),
            "matched_by": .string(matched),
            "searched": .array(roots.map(JSONValue.string)),
            "results": .array(lines.map { .string($0) }),
            "files": .array(files),
            "count": .int(Int64(lines.count)),
            "partial": .bool(partial),
            "stdout_truncated": .bool(result.stdoutTruncated),
            "stderr_truncated": .bool(result.stderrTruncated),
        ]
        if partial {
            output["lever"] = .string("Spotlight was still searching at \(Int(budget)) s; these are the matches so far. "
                + "Ask again with more of the name, or list the folder it lives in with files.list {path}.")
        }
        return MacControlResult(
            ok: partial || result.exitCode == 0,
            action: "spotlight",
            output: .object(output),
            error: partial || result.exitCode == 0 ? nil : "mdfind exit \(result.exitCode) stderr=\(result.stderr.prefix(200))",
            durationMs: durationMs
        )
    }

    // MARK: shell

    func handleShell(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let command = body["command"]?.stringValue, !command.isEmpty else {
            throw MacControlError.missingField("command")
        }
        let timeout = max(1, min(body["timeout"]?.integerValue.flatMap(Int.init(exactly:)) ?? 60, 120))
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
                "stdout_truncated": .bool(result.stdoutTruncated || result.stdout.count > 4000),
                "stderr_truncated": .bool(result.stderrTruncated || result.stderr.count > 2000),
            ]),
            error: result.timedOut
                ? "shell timed out"
                : (result.exitCode == 0 ? nil : "shell exit \(result.exitCode)"),
            durationMs: durationMs
        )
    }
}
