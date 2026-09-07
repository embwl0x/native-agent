import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import TrustCenter

extension SwiftToolDispatcher {
    // MARK: - invoke_claude session pointer

    /// Cross-process exclusion for the `invoke_claude` session pointer.
    ///
    /// Deliberately SYNCHRONOUS. The pointer's lifecycle has two halves — the
    /// read/check before the run and the write/reset after it — and the second
    /// half executes inside `Process.terminationHandler`, which cannot await.
    /// It locks the same `<path>.lock` sidecar `PersistenceCore.withFileLock`
    /// uses, with the same LOCK_EX and the same acquire-then-validate-inode
    /// contract, so the two remain mutually exclusive.
    ///
    /// 2026-09-06: bounded acquisition failure skips the body. Running it
    /// unlocked can overwrite a concurrent invocation's resume pointer.
    @discardableResult
    static func withSessionPointerLock<T>(_ target: URL, _ body: () -> T) -> T? {
        let lockPath = target.path + ".lock"
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let deadline = Date().addingTimeInterval(5)
        var attempts = 0
        while attempts < 8 {
            attempts += 1
            let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0 { break }
            var acquired = false
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
                let e = errno
                if e != EWOULDBLOCK && e != EINTR { break }
                if Date() >= deadline { break }
                usleep(20_000)
            }
            guard acquired else { Darwin.close(fd); break }
            // Do we hold the file that is CURRENTLY at lockPath? A reaped or
            // replaced sidecar would otherwise leave us locking a corpse while
            // a newcomer locks the live one — mutual exclusion silently gone.
            var held = stat()
            var atPath = stat()
            let sameInode = fstat(fd, &held) == 0
                && stat(lockPath, &atPath) == 0
                && held.st_dev == atPath.st_dev
                && held.st_ino == atPath.st_ino
            if !sameInode {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
                usleep(5_000)
                continue
            }
            defer {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
            return body()
        }
        return nil
    }

    /// The session id a pointer file currently names, or nil when it is absent
    /// or empty. Callers hold `withSessionPointerLock`; this is the re-read
    /// that makes the lock load-bearing across the long gap between the two
    /// halves of the pointer's lifecycle.
    static func sessionPointerSessionID(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let first = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: - invoke_claude spawn handler
    //
    // Spawns `claude -p "<context+question>"` as a Process, blocks until
    // the subprocess exits (or timeout fires + we terminate). Captures
    // stdout/stderr. Writes audit envelope to data/from_claude/<uuid>.json
    // with prompt, exit code, duration, summary. Returns Agent-facing
    // JSON envelope with the reply text.
    // 2026-06-09 notify-don't-hang: emits live notice events (start /
    // 30s heartbeat / timeout) through ToolNoticeBus so the user sees
    // progress instead of a silent multi-minute hang.
    //
    // Async via withCheckedContinuation — Process.terminationHandler
    // resumes the continuation exactly once. Timeout watchdog terminates the
    // spawned process group, then the same handler returns the envelope.
    static func runInvokeClaude(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
                // 2026-09-06: every outcome reports pointer handling evidence.
                "sessionPointerStatus": .string("not_checked"),
            ])
        }
        let context: String = {
            if case .string(let c)? = input["context"] { return c }
            return ""
        }()
        let commitHash: String? = {
            if case .string(let h)? = input["commit_hash"], !h.isEmpty { return h }
            return nil
        }()
        let cwdRaw: String = {
            if case .string(let c)? = input["cwd"], !c.isEmpty { return c }
            _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
            return builderSourceRepoRoot(dataRoot: dataRoot)?.path
                ?? builderWorkspaceRoot(dataRoot: dataRoot).path
        }()
        let timeoutSeconds: Int = {
            if case .int(let i)? = input["timeout_seconds"] { return max(30, min(3600, Int(i))) }
            // 600 -> 180 (the user, 2026-06-09): a hung invoke held the chat for 10
            // silent minutes. 3 min surfaces failure fast; callers with a real
            // long task pass timeout_seconds explicitly (clamp stays 30-3600).
            return 180
        }()

        var promptParts: [String] = []
        if let commitHash {
            promptParts.append("Anchor commit: \(commitHash)")
        }
        if !context.isEmpty {
            promptParts.append("Context from NativeAgent:\n\(context)")
        }
        promptParts.append("Question/task:\n\(text)")
        let fullPrompt = promptParts.joined(separator: "\n\n")

        let runId = UUID().uuidString
        let started = Date()

        // Notify-don't-hang: capture the turn's notice sink from the task-local
        // BEFORE entering the continuation — the Process terminationHandler and
        // the watchdog run off the task tree and can't read TaskLocals. nil when
        // invoked outside a chat turn (background loops): emission just no-ops.
        let notify = ToolNoticeBus.emit
        await notify?(
            "invoke_started",
            "⏳ Invoking Claude — your ongoing thread, up to \(timeoutSeconds)s…"
        )
        let timedOutFlag = AtomicFlag()
        let heartbeat = Task {
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                elapsed += 30
                await notify?("invoke_progress", "⏳ Claude still working (\(elapsed)s elapsed)…")
            }
        }
        // 2026-09-06: admission and launch failures own the heartbeat too.
        defer { heartbeat.cancel() }

        // Persistent agent-to-Claude session. Instead of a blank `claude -p`
        // per message, resume the same dedicated thread every time so the
        // configured resident agent and Claude retain real continuity. The id
        // is pinned at <dataRoot>/from_claude/agent_session.txt:
        // first call creates it via --session-id, every call after --resume's it.
        // (A `claude` session already loads the full persona + memory + MCP tools
        // via the inherited env — the only thing missing before was CONTINUITY.)
        let sessionDirectory = dataRoot
            .appendingPathComponent("from_claude", isDirectory: true)
        let sessionFile = sessionDirectory.appendingPathComponent("agent_session.txt")
        // Read-only migration compatibility for pointers written before the
        // filename became identity-neutral. Build the retired name from
        // fragments so a fresh binary does not advertise the private instance
        // identity that the old filename contained.
        let legacySessionName = [
            "claude",
            ["ay", "ala"].joined(),
            "session.txt",
        ].joined(separator: "_")
        let legacySessionFile = sessionDirectory.appendingPathComponent(legacySessionName)
        let existingSessionFile = FileManager.default.fileExists(atPath: sessionFile.path)
            ? sessionFile
            : legacySessionFile
        // Resume is project-scoped: retain the creation cwd with the ID.
        // Admission and termination each lock and reread the pointer so a
        // settlement cannot reset a different invocation's current session.
        let pointerProvenance = dataRoot.standardizedFileURL.path
        let lockedDecision: (id: String, args: [String], isNew: Bool, cwd: String)?
            = withSessionPointerLock(sessionFile) {
                let existingLines = (try? String(contentsOf: existingSessionFile, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let pointerIsForeign = existingLines?.count ?? 0 >= 3
                    && existingLines?[2] != pointerProvenance
                if pointerIsForeign {
                    let rejected = existingSessionFile.deletingPathExtension()
                        .appendingPathExtension("foreign-\(Int(started.timeIntervalSince1970))")
                    try? FileManager.default.moveItem(at: existingSessionFile, to: rejected)
                }
                if !pointerIsForeign, let existingLines, let first = existingLines.first, !first.isEmpty {
                    return (
                        first,
                        ["--resume", first],
                        false,
                        (existingLines.count >= 2 && !existingLines[1].isEmpty) ? existingLines[1] : cwdRaw
                    )
                }
                let fresh = UUID().uuidString.lowercased()
                return (fresh, ["--session-id", fresh], true, cwdRaw)
            }
        guard let pointerDecision = lockedDecision else {
            return .object([
                "status": .string("failed"),
                "reason": .string("session_pointer_lock_unavailable"),
                "sessionPointerStatus": .string("lock_unavailable"),
            ])
        }
        let sessionId = pointerDecision.id
        let sessionArgs = pointerDecision.args
        let isNewSession = pointerDecision.isNew
        let sessionCwd = pointerDecision.cwd

        // Resolve `claude` binary. Most users have it in /usr/local/bin/
        // or ~/.claude/bin/, sometimes /opt/homebrew/bin/. Use `env` to
        // honor PATH. Process inherits the user's environment so MCP
        // config, auth, ~/.claude/settings.json all come along.
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let claude = AgentBridgeRuntime.executableURL(named: "claude", environment: environment) else {
            heartbeat.cancel()
            return .object([
                "status": .string("failed"),
                "reason": .string("claude_cli_not_found"),
                "sessionPointerStatus": .string("admitted_not_settled"),
                "fix": .string("Install and sign in to Claude Code, then restart NativeAgent."),
            ])
        }
        let process = Process()
        process.executableURL = claude
        process.arguments = sessionArgs + ["-p", fullPrompt]
        process.currentDirectoryURL = URL(fileURLWithPath: sessionCwd)
        process.environment = environment

        let outputCapture = InvokeOutputCapture(process: process)

        let cancellation = InvokeCancellation()
        let result: JSONValue = await withTaskCancellationHandler {
          await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            // Single-fire guard — both terminationHandler and the timeout
            // watchdog could try to resume. Continuation must resume EXACTLY once.
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                let (stdoutText, stderrText) = outputCapture.finish()
                let exitCode = proc.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)

                heartbeat.cancel()
                // Guard the edge where the watchdog fires just as the process
                // exits cleanly: only report a timeout when the exit was
                // actually fatal (gpt-5.5 review nit).
                let didTimeOut = timedOutFlag.isSet && exitCode != 0
                let cancelled = cancellation.isCancelled

                // Audit envelope to data/from_claude/<uuid>.json (best-effort,
                // failure is non-fatal — Agent already has the reply in hand).
                let auditDir = dataRoot
                    .appendingPathComponent("from_claude", isDirectory: true)
                try? FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
                let auditURL = auditDir.appendingPathComponent("\(runId).json")
                var auditEntry: [String: Any] = [
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: started),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "durationMs": durationMs,
                    "exitCode": Int(exitCode),
                    "cwd": cwdRaw,
                    "timeoutSeconds": timeoutSeconds,
                    // 2026-06-09 (Agent's catch): exit 143 + empty reply was
                    // ambiguous — record whether OUR watchdog killed it.
                    "timedOut": didTimeOut,
                    "cancelled": cancelled,
                    "outcome": cancelled ? "unknown" : "settled",
                    "sessionId": sessionId,
                    "prompt": fullPrompt,
                    "reply": stdoutText,
                    "stderr": stderrText,
                ]
                if let commitHash { auditEntry["commitHash"] = commitHash }
                if let data = try? JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted]) {
                    try? data.write(to: auditURL)
                    Self.trimAgentBridgeAudits(in: auditDir)
                }

                // Persist the delegated session id on first successful create
                // so the next invoke RESUMES it. Clear it on a genuine
                // (non-timeout) resume failure so a dead session self-heals into a
                // fresh thread next time instead of failing forever.
                // Same lock as the read/check above: this is the WRITE half of
                // one read-check-write, and the two halves are separated by a
                // minutes-long subprocess. The lock alone cannot span that gap,
                // so each branch re-reads the live pointer under it — that is
                // what stops one invoke's settlement landing on another's.
                let pointerSettlement: Void? = Self.withSessionPointerLock(sessionFile) {
                    if isNewSession {
                        if exitCode == 0 && !cancelled {
                            // Persist id + the creation cwd so the next invoke resumes
                            // the SAME thread from the SAME project dir. Never clobber
                            // a pointer another invoke established while we ran: the
                            // first thread to land owns the topic, and last-writer-wins
                            // here silently orphans it.
                            if Self.sessionPointerSessionID(sessionFile) == nil {
                                try? "\(sessionId)\n\(sessionCwd)\n\(pointerProvenance)".write(to: sessionFile, atomically: true, encoding: .utf8)
                            }
                        }
                    } else if exitCode == 0, existingSessionFile != sessionFile {
                        // Promote a successfully resumed legacy pointer to the
                        // identity-neutral filename. Keep the legacy file as a
                        // rollback breadcrumb; all future reads prefer the new one.
                        // Only when nothing newer already sits there.
                        let live = Self.sessionPointerSessionID(sessionFile)
                        if live == nil || live == sessionId {
                            try? "\(sessionId)\n\(sessionCwd)\n\(pointerProvenance)".write(
                                to: sessionFile,
                                atomically: true,
                                encoding: .utf8
                            )
                        }
                    } else if exitCode != 0 && !didTimeOut && !cancelled {
                        // Self-heal ONLY a genuinely-gone session (explicit
                        // session-not-found marker), and RENAME the pointer aside
                        // rather than delete it — a transient / concurrent / auth
                        // failure must NEVER silently wipe the resident thread
                        // review BLOCKING). Every other failure keeps the pointer.
                        let lower = stderrText.lowercased()
                        let sessionGone = lower.contains("no conversation found")
                            || lower.contains("session not found")
                            || lower.contains("no session found")
                            || (lower.contains("session") && lower.contains("does not exist"))
                        // ...and only when the pointer on disk is still the one
                        // THIS run resumed. A concurrent invoke may have healed
                        // the thread while we ran; renaming its fresh pointer
                        // aside is precisely the live `.stale-<ts>` damage.
                        if sessionGone, Self.sessionPointerSessionID(existingSessionFile) == sessionId {
                            let stale = existingSessionFile.deletingPathExtension()
                                .appendingPathExtension("stale-\(Int(started.timeIntervalSince1970))")
                            try? FileManager.default.moveItem(at: existingSessionFile, to: stale)
                        }
                    }
                }

                if pointerSettlement == nil {
                    NSLog("invoke_claude: resume pointer lock unavailable; session remains in the invocation audit")
                }

                if didTimeOut {
                    // Best-effort user-visible line; the failed envelope below is
                    // the durable signal. Sync handler -> hop onto a Task.
                    let timeoutText = "⚠️ Claude invoke timed out after \(timeoutSeconds)s — no reply."
                    Task { await notify?("invoke_timeout", timeoutText) }
                }

                guard resumed.tryResume() else { return }
                if exitCode == 0 && !cancelled {
                    cont.resume(returning: .object([
                        "status": .string("completed"),
                        "runId": .string(runId),
                        "reply": .string(stdoutText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "auditPath": .string(auditURL.path),
                        "sessionId": .string(sessionId),
                        "sessionPointerStatus": .string(pointerSettlement == nil ? "lock_unavailable" : "checked"),
                    ]))
                } else {
                    cont.resume(returning: .object([
                        "status": .string(cancelled ? "cancelled" : "failed"),
                        "outcome": .string(cancelled ? "unknown" : "settled"),
                        "sessionId": .string(sessionId),
                        "sessionPointerStatus": .string(pointerSettlement == nil ? "lock_unavailable" : "checked"),
                        "reason": .string(cancelled ? "cancelled_effects_uncertain" : didTimeOut
                            ? "timeout_after_\(timeoutSeconds)s"
                            : "subprocess_exit_\(exitCode)"),
                        "runId": .string(runId),
                        "reply": .string(stdoutText),
                        "stderr": .string(stderrText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "timedOut": .bool(didTimeOut),
                        "auditPath": .string(auditURL.path),
                    ]))
                }
            }

            do {
                try cancellation.launch(process)
            } catch {
                heartbeat.cancel()
                outputCapture.stopReading()
                guard resumed.tryResume() else { return }
                cont.resume(returning: .object([
                    "status": .string(error is CancellationError ? "cancelled" : "failed"),
                    "reason": .string(error is CancellationError ? "cancelled_before_spawn" : "spawn_failed"),
                    "sessionPointerStatus": .string("admitted_not_settled"),
                    "runId": .string(runId),
                    "detail": .string(String(describing: error)),
                ]))
                return
            }

            armSubprocessTimeout(process: process, timeoutSeconds: timeoutSeconds) {
                timedOutFlag.set()
            }
          }
        } onCancel: {
            cancellation.cancel()
        }
        // Runs-ledger row (R25 follow-up): the Runs UI + iOS runs snapshot read
        // <dataRoot>/runs/runs.json. Every spawn that reached the continuation
        // gets one row; validation refusals above never spawned and stay off
        // the ledger. Best-effort — never fails the invoke.
        await Self.appendSpawnRunToLedger(
            kind: "claude",
            result: result,
            model: nil,
            prompt: fullPrompt,
            startedAt: started,
            dataRoot: dataRoot
        )
        return result
    }

    // MARK: - invoke_codex spawn handler
    //
    // Spawns `codex exec` as a Process, waits for a bounded non-interactive
    // answer, and writes an audit envelope to data/from_codex/<uuid>.json.
    // This is the Codex-side twin of invoke_claude: Agent can ask Codex to
    // work a focused task, then continue with Codex's final reply.
    static func runInvokeCodex(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        guard case .string(let text)? = input["text"], !text.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_text"),
            ])
        }
        let context: String = {
            if case .string(let c)? = input["context"] { return c }
            return ""
        }()
        let commitHash: String? = {
            if case .string(let h)? = input["commit_hash"], !h.isEmpty { return h }
            return nil
        }()
        let cwdRaw: String = {
            if case .string(let c)? = input["cwd"], !c.isEmpty { return c }
            _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
            return builderSourceRepoRoot(dataRoot: dataRoot)?.path
                ?? builderWorkspaceRoot(dataRoot: dataRoot).path
        }()
        let timeoutSeconds: Int = {
            if case .int(let i)? = input["timeout_seconds"] { return max(30, min(3600, Int(i))) }
            return 600
        }()
        let sandbox: String = {
            if case .string(let s)? = input["sandbox"] {
                let lower = s.lowercased()
                if ["read-only", "workspace-write", "danger-full-access"].contains(lower) {
                    return lower
                }
            }
            return "workspace-write"
        }()
        if sandbox == "danger-full-access" {
            // Same root as the audit write below — policy and audit must
            // never diverge on a privileged path (gpt-5.5 review catch).
            let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
            guard codexDangerFullAccessAllowed(policy: policy) else {
                return .object([
                    "status": .string("denied"),
                    "reason": .string("developer_mode_required"),
                    "sandbox": .string(sandbox),
                    "message": .string("invoke_codex danger-full-access requires Developer Mode. Retry with workspace-write or enable Developer Mode locally."),
                ])
            }
        }
        let brain: CodexBrainControls
        switch codexBrainControls(from: input) {
        case .success(let controls): brain = controls
        case .failure(let error): return error.envelope
        }
        let model = brain.model

        var promptParts: [String] = []
        promptParts.append("You are Codex running as a bounded subprocess spawned by NativeAgent.")
        promptParts.append("Return a concise final answer with what you did, what you checked, and any follow-up.")
        if let commitHash {
            promptParts.append("Anchor commit: \(commitHash)")
        }
        if !context.isEmpty {
            promptParts.append("Context from NativeAgent:\n\(context)")
        }
        promptParts.append("Question/task:\n\(text)")
        let fullPrompt = promptParts.joined(separator: "\n\n")

        let runId = UUID().uuidString
        let started = Date()
        let auditDir = dataRoot
            .appendingPathComponent("from_codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        let auditURL = auditDir.appendingPathComponent("\(runId).json")
        let lastMessageURL = auditDir.appendingPathComponent("\(runId)-last-message.txt")

        let environment = AgentBridgeRuntime.processEnvironment()
        guard let codex = AgentBridgeRuntime.executableURL(named: "codex", environment: environment) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("codex_cli_not_found"),
                "fix": .string("Install and sign in to Codex CLI, then restart NativeAgent."),
            ])
        }
        let process = Process()
        process.executableURL = codex
        let args = codexExecArguments(
            sandbox: sandbox,
            cwd: cwdRaw,
            lastMessagePath: lastMessageURL.path,
            model: model,
            reasoningEffort: brain.reasoningEffort,
            serviceTier: brain.serviceTier,
            prompt: fullPrompt
        )
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwdRaw)
        process.environment = environment

        let outputCapture = InvokeOutputCapture(process: process)

        // Watchdog-timeout latch — mirrors invoke_claude so a kill by OUR
        // watchdog reports as a timeout, not an anonymous subprocess_exit_143
        // (gpt-5.5 review MED, 2026-07-02).
        let timedOutFlag = AtomicFlag()
        let cancellation = InvokeCancellation()
        let result: JSONValue = await withTaskCancellationHandler {
          await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                let (stdoutText, stderrText) = outputCapture.finish()
                let lastMessage = (try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? ""
                let replyText = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? stdoutText
                    : lastMessage
                let exitCode = proc.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                // Only report a timeout when the exit was actually fatal —
                // same clean-exit-vs-watchdog edge guard as invoke_claude.
                let didTimeOut = timedOutFlag.isSet && exitCode != 0
                let cancelled = cancellation.isCancelled

                var auditEntry: [String: Any] = [
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: started),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "durationMs": durationMs,
                    "exitCode": Int(exitCode),
                    "cwd": cwdRaw,
                    "sandbox": sandbox,
                    "timeoutSeconds": timeoutSeconds,
                    "timedOut": didTimeOut,
                    "cancelled": cancelled,
                    "outcome": cancelled ? "unknown" : "settled",
                    "prompt": fullPrompt,
                    "reply": replyText,
                    "stdout": stdoutText,
                    "stderr": stderrText,
                    "lastMessagePath": lastMessageURL.path,
                ]
                if let commitHash { auditEntry["commitHash"] = commitHash }
                if let model { auditEntry["model"] = model }
                if let effort = brain.reasoningEffort { auditEntry["reasoningEffort"] = effort }
                if let tier = brain.serviceTier { auditEntry["serviceTier"] = tier }
                if let fast = brain.fast { auditEntry["fast"] = fast }
                if let data = try? JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted]) {
                    try? data.write(to: auditURL)
                    Self.trimAgentBridgeAudits(in: auditDir)
                }

                guard resumed.tryResume() else { return }
                if exitCode == 0 && !cancelled {
                    cont.resume(returning: .object([
                        "status": .string("completed"),
                        "runId": .string(runId),
                        "reply": .string(replyText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "sandbox": .string(sandbox),
                        "brain": brain.jsonValue,
                        "auditPath": .string(auditURL.path),
                    ]))
                } else {
                    cont.resume(returning: .object([
                        "status": .string(cancelled ? "cancelled" : "failed"),
                        "outcome": .string(cancelled ? "unknown" : "settled"),
                        "reason": .string(cancelled ? "cancelled_effects_uncertain" : didTimeOut
                            ? "timeout_after_\(timeoutSeconds)s"
                            : "subprocess_exit_\(exitCode)"),
                        "runId": .string(runId),
                        "reply": .string(replyText),
                        "stderr": .string(stderrText),
                        "durationMs": .int(Int64(durationMs)),
                        "exitCode": .int(Int64(exitCode)),
                        "timedOut": .bool(didTimeOut),
                        "sandbox": .string(sandbox),
                        "brain": brain.jsonValue,
                        "auditPath": .string(auditURL.path),
                    ]))
                }
            }

            do {
                try cancellation.launch(process)
            } catch {
                outputCapture.stopReading()
                guard resumed.tryResume() else { return }
                cont.resume(returning: .object([
                    "status": .string(error is CancellationError ? "cancelled" : "failed"),
                    "reason": .string(error is CancellationError ? "cancelled_before_spawn" : "spawn_failed"),
                    "runId": .string(runId),
                    "detail": .string(String(describing: error)),
                ]))
                return
            }

            armSubprocessTimeout(process: process, timeoutSeconds: timeoutSeconds) {
                timedOutFlag.set()
            }
          }
        } onCancel: {
            cancellation.cancel()
        }
        // Runs-ledger row — see the invoke_claude twin above for rationale.
        await Self.appendSpawnRunToLedger(
            kind: "codex",
            result: result,
            model: model,
            prompt: fullPrompt,
            startedAt: started,
            dataRoot: dataRoot
        )
        return result
    }

    // MARK: - Runs-ledger append for sub-agent spawns
    //
    // Shared tail for invoke_claude / invoke_codex: translate the tool-result
    // envelope into one RunRecord row in <dataRoot>/runs/runs.json. The
    // envelope's "completed" maps to the ledger's "succeeded" (the status
    // string the Runs UI colors green); a watchdog kill maps to "timeout".
    static func appendSpawnRunToLedger(
        kind: String,
        result: JSONValue,
        model: String?,
        prompt: String,
        startedAt: Date,
        dataRoot: URL
    ) async {
        guard case .object(let obj) = result else { return }
        let rawStatus: String = {
            if case .string(let s)? = obj["status"] { return s }
            return "unknown"
        }()
        let timedOut: Bool = {
            if case .bool(let b)? = obj["timedOut"] { return b }
            if case .string(let reason)? = obj["reason"], reason.hasPrefix("timeout_after_") { return true }
            return false
        }()
        let status = rawStatus == "completed" ? "succeeded" : (timedOut ? "timeout" : rawStatus)
        let runId: String = {
            if case .string(let r)? = obj["runId"], !r.isEmpty { return r }
            return UUID().uuidString
        }()
        let reply: String? = {
            if case .string(let r)? = obj["reply"], !r.isEmpty { return r }
            return nil
        }()
        var errorParts: [String] = []
        if status != "succeeded" {
            if case .string(let reason)? = obj["reason"] { errorParts.append(reason) }
            if case .string(let detail)? = obj["detail"], !detail.isEmpty { errorParts.append(detail) }
            if case .string(let stderrText)? = obj["stderr"], !stderrText.isEmpty { errorParts.append(stderrText) }
        }
        await RunLedger.append(
            id: runId,
            kind: kind,
            status: status,
            model: model,
            prompt: prompt,
            output: reply,
            error: errorParts.isEmpty ? nil : errorParts.joined(separator: "\n"),
            createdAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            dataRoot: dataRoot
        )
    }

    static func codexExecArguments(
        sandbox: String,
        cwd: String,
        lastMessagePath: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        prompt: String
    ) -> [String] {
        var args = [
            "codex", "exec",
            "--ephemeral",
            "--sandbox", sandbox,
            "-C", cwd,
            "--color", "never",
            "-o", lastMessagePath,
        ]
        if let model {
            args.append(contentsOf: ["-m", model])
        }
        if let reasoningEffort {
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""])
        }
        if let serviceTier {
            args.append(contentsOf: ["-c", "service_tier=\"\(serviceTier)\""])
        }
        args.append(prompt)
        return args
    }

    static func codexDangerFullAccessAllowed(policy: [String: JSONValue]) -> Bool {
        if case .bool(true)? = policy["developerMode"] {
            return true
        }
        return false
    }

}
