import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - SwiftNative — CrashReport

public actor SwiftNativeCrashReportClient: CrashReportClient {
    private let crashReportsDir: URL
    private let persistence: any PersistenceCoreProtocol
    private let now: @Sendable () -> Date
    private let suffixFactory: @Sendable () -> String
    private let autonomyGate: @Sendable () async -> Bool
    private let masterAutonomyEnabled: @Sendable () -> Bool
    private let improvementSpawner: @Sendable (String) async throws -> Void
    private var lastCrashImprovementAt: TimeInterval = 0

    /// - Parameters:
    ///   - autonomyGate:         Async closure returning the live
    ///                           `trust_policy.enableAutonomy` flag. Default
    ///                           returns `false` (closed-fail) — production
    ///                           callers MUST wire this to the live TrustCenter
    ///                           read at the AppDelegate layer for the
    ///                           autonomous-improvement spawn to trip.
    ///   - masterAutonomyEnabled: Closure returning the app-level autonomy
    ///                           switch. Default returns `false` for safety.
    ///   - improvementSpawner:   Closure invoked with the constructed objective
    ///                           string when the gate + throttle permit. Default
    ///                           fails closed unless the app injects a Swift
    ///                           self-improvement spawner. Tests pass a stub.
    ///                           The closure should THROW on failure; the actor
    ///                           catches and logs, never
    ///                           re-throws (retired behavior: crash still stored).
    public init(
        crashReportsDir: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> Date = { Date() },
        suffixFactory: @escaping @Sendable () -> String = {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
        },
        autonomyGate: @escaping @Sendable () async -> Bool = { false },
        masterAutonomyEnabled: @escaping @Sendable () -> Bool = { false },
        improvementSpawner: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.crashReportsDir = crashReportsDir
            ?? PersistenceCore.defaultDataRoot().appendingPathComponent("crash_reports", isDirectory: true)
        self.persistence = persistence
        self.now = now
        self.suffixFactory = suffixFactory
        self.autonomyGate = autonomyGate
        self.masterAutonomyEnabled = masterAutonomyEnabled
        self.improvementSpawner = improvementSpawner
            ?? SwiftNativeCrashReportClient.defaultImprovementSpawner()
    }

    /// Default spawner: fail closed. SystemOps does not depend on the
    /// SelfImprovement module, so production must inject a Swift-native
    /// improvement spawner at the app layer when autonomous crash repair is
    /// enabled.
    private static func defaultImprovementSpawner() -> @Sendable (String) async throws -> Void {
        return { objective in
            _ = objective
            throw SystemOpsError.malformedResponse("Swift self-improvement spawner is not wired")
        }
    }

    public func postCrashReport(
        traceback: String,
        stderrTail: String,
        exitCode: Int?,
        capturedAt: String?
    ) async throws -> CrashReportOpResult {
        let rawTb = String(traceback.prefix(8000))
        let rawErr = String(stderrTail.prefix(4000))
        let redactedTb = Self.redactUserData(rawTb)
        let redactedErr = Self.redactUserData(rawErr)
        let capturedAtFinal = (capturedAt?.isEmpty == false ? capturedAt! : Self.isoTimestamp(now()))

        var sanitized = capturedAtFinal
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        if sanitized.count > 25 { sanitized = String(sanitized.prefix(25)) }
        let suffix = suffixFactory()
        let filename = "crash-\(sanitized)-\(suffix).json"
        let crashPath = crashReportsDir.appendingPathComponent(filename)

        var report: [String: JSONValue] = [
            "traceback": .string(redactedTb),
            "stderr_tail": .string(redactedErr),
            "captured_at": .string(capturedAtFinal),
        ]
        if let code = exitCode {
            report["exit_code"] = .int(Int64(code))
        } else {
            report["exit_code"] = .null
        }

        try await persistence.writeJSON(.object(report), to: crashPath)
        try? await persistence.writeJSON(.object(report), to: crashReportsDir.appendingPathComponent("last.json"))

        Self.pruneOldCrashFiles(in: crashReportsDir, keep: 50)

        // Autonomous-improvement spawn gate. Mirrors the retired daemon.
        // BOTH the master switch AND the trust-policy flag must be on, and the
        // 300s anti-storm throttle must have elapsed since the previous spawn.
        var improvementSpawned = false
        let trustOK = await autonomyGate()
        let nowSec = now().timeIntervalSince1970
        let shouldSpawn =
            masterAutonomyEnabled()
            && trustOK
            && (nowSec - lastCrashImprovementAt) > 300
        if shouldSpawn {
            // Advance BEFORE the call so a thrown spawn still consumes the
            // throttle slot (Python fix-9 anti-storm semantics).
            lastCrashImprovementAt = nowSec
            let tb = redactedTb.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tb.isEmpty {
                let tbCapped = String(tb.prefix(3000))
                let objective =
                    "Fix the app crash captured at \(capturedAtFinal). The traceback is:\n"
                    + "\(tbCapped)\n\n"
                    + "Read recent activity, audit the module that crashed, propose a fix in a worktree, "
                    + "run ./script/test.sh to verify."
                do {
                    try await improvementSpawner(objective)
                    improvementSpawned = true
                } catch {
                    NSLog("[crash-report] startImprovement failed: \(error.localizedDescription)")
                }
            }
        }

        return CrashReportOpResult(
            stored: true,
            path: crashPath.path,
            improvementSpawned: improvementSpawned
        )
    }

    /// Port of Daemon._redact_user_data byte-for-byte.
    /// Five sequential substitutions; NSRegularExpression for each.
    public static func redactUserData(_ s: String) -> String {
        var out = s
        let patterns: [(String, String, NSRegularExpression.Options)] = [
            (#"/Users/[^/"'`\n\r]+/[^"'`\n\r]*"#, "/Users/<user>/<path>", []),
            (#"(["`\ ])(.{500,})(["`\ ])"#, "$1[user content redacted]$3", [.dotMatchesLineSeparators]),
            (#"\bsk-[A-Za-z0-9_-]{20,}"#, "[token-redacted]", []),
            (#"\bBearer\s+[A-Za-z0-9._\-]{20,}"#, "Bearer [token-redacted]", []),
            (#"((?:OPENAI|ANTHROPIC|GH|GITHUB|API)[\w]*[_\s]*(?:KEY|TOKEN|SECRET)\s*[=:]\s*)[^\s"']{8,}"#, "$1[redacted]", [.caseInsensitive]),
        ]
        for (pat, repl, opts) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat, options: opts) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: repl)
        }
        return out
    }

    /// Keep at most `keep` `crash-*.json` files in the directory, sorted by
    /// modification time ascending (oldest pruned first). Mirrors Python's
    /// `_all_crash_files[:-50]` excess list.
    public static func pruneOldCrashFiles(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else { return }
        let candidates = entries.filter { url in
            url.lastPathComponent.hasPrefix("crash-") && url.lastPathComponent.hasSuffix(".json")
        }
        // Mirrors Python's `except Exception: pass` at the top of the prune
        // block: if ANY stat fails or isRegularFile
        // can't be resolved, abort pruning silently. Also drops non-regular
        // entries (symlinks, directories matching the glob) before sorting.
        var withDates: [(URL, Date)] = []
        for url in candidates {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  let isRegular = values.isRegularFile else {
                return
            }
            if !isRegular { continue }
            withDates.append((url, values.contentModificationDate ?? .distantPast))
        }
        guard withDates.count > keep else { return }
        let sorted = withDates.sorted { $0.1 < $1.1 }
        let excessCount = sorted.count - keep
        for (url, _) in sorted.prefix(excessCount) {
            try? fm.removeItem(at: url)
        }
    }

    public static func isoTimestamp(_ date: Date) -> String {
        SwiftNativeRouterPlanClient.isoTimestamp(date)
    }

    /// Byte-faithful Swift mirror of the `# Crash reports (last 24 h)` slice of
    /// `Runtime.health_card`. Counts
    /// `crash-*.json` regular files in `dir` whose mtime is >= (`now` − 24h);
    /// status is "warn" if any are recent, else "ok"; detail is
    /// `"<n> in last 24h"` truncated to 60 chars (Python `[:60]`).
    ///
    /// PARITY NOTES (the daemon wraps the WHOLE slice in ONE try/except, L28753-
    /// L28763, but the two failure shapes differ — verified empirically wave 39):
    ///  • A MISSING / non-directory / unreadable `dir` is NOT the `except`
    ///    fallback: Python's `Path.glob("crash-*.json")` returns an EMPTY
    ///    iterator (no raise) for a missing dir or a path that is a file, so the
    ///    daemon reports "0 in last 24h" / status "ok". So does this helper —
    ///    `contentsOfDirectory` throwing maps to ZERO crash files, NOT to the
    ///    "dir unavailable" row. (gpt-5.5 wave-39 review BLOCKER fix.)
    ///  • The `except`→"Crash report dir unavailable" fallback fires ONLY on a
    ///    genuine `f.stat().st_mtime` failure on an existing file mid-iteration
    ///    (the only call inside the `try` that can raise after glob). Python's
    ///    `if f.is_file()` SUPPRESSES type-stat errors (treats them as non-file),
    ///    it does NOT trip the outer except — so a file whose `is_file()` check
    ///    can't be resolved is skipped, not a whole-slice bail. (review SHOULD-
    ///    FIX fix: is_file resolution failure → skip; mtime read failure → fallback.)
    ///
    /// PURE HELPER — see `HealthCardSubsystem` doc. Not wired to a live route;
    /// the composite health_card stays daemon-side until all 3 live slices port.
    /// `now` is injectable for deterministic tests; defaults to wall-clock.
    public static func recentCrashSubsystemEntry(in dir: URL, now: Date = Date()) -> HealthCardSubsystem {
        // Mirrors `cutoff = now - timedelta(hours=24)` (L28754). 24h = 86400s.
        let cutoff = now.addingTimeInterval(-86_400)
        let fm = FileManager.default
        // `dir.glob("crash-*.json")` on a missing/non-dir path → EMPTY, no raise.
        // So a listing failure == zero crash files == "0 in last 24h" (status ok),
        // NOT the `except` row. Only a per-file mtime stat failure below = fallback.
        let entries = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        )) ?? []
        // Mirrors `[f for f in dir.glob("crash-*.json") if f.is_file()]` (L28755).
        let crashFiles = entries.filter { url in
            url.lastPathComponent.hasPrefix("crash-") && url.lastPathComponent.hasSuffix(".json")
        }
        var nRecent = 0
        for url in crashFiles {
            // `if f.is_file()` (L28755): Python returns False on a stat error
            // here (SUPPRESSED) rather than raising. So resolve the is-regular-
            // file status in ITS OWN read and SKIP on any failure (treat as
            // non-file) — do NOT whole-slice bail. Kept a SEPARATE read from the
            // mtime fetch below so a stat failure on the is_file probe maps to
            // Python's `is_file()` suppression, not to the outer `except`.
            guard let fileVals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  let isRegular = fileVals.isRegularFile else {
                continue
            }
            if !isRegular { continue }   // mirrors `if f.is_file()` → False
            // `f.stat().st_mtime` (L28758): THIS is the only call inside the
            // daemon's `try` that raises into the outer `except`. Fetch the mtime
            // in a SEPARATE read so its failure (throw OR nil) is the one that
            // maps to the daemon fallback — matching Python's split between
            // suppressed `is_file()` and raising `stat().st_mtime`.
            guard let mtimeVals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = mtimeVals.contentModificationDate else {
                return HealthCardSubsystem(
                    id: "crash_reports", label: "Recent crashes",
                    status: "ok", detail: "Crash report dir unavailable"
                )
            }
            if mtime >= cutoff { nRecent += 1 }   // `datetime.fromtimestamp(...) >= cutoff`
        }
        // `crash_status = "warn" if n_recent > 0 else "ok"` (L28760).
        let status = nRecent > 0 ? "warn" : "ok"
        // `f"{n_recent} in last 24h"[:60]` (L28761). The string is always far
        // under 60 chars; the truncation is kept for exact parity.
        let detail = String("\(nRecent) in last 24h".prefix(60))
        return HealthCardSubsystem(
            id: "crash_reports", label: "Recent crashes",
            status: status, detail: detail
        )
    }

    /// Byte-faithful Swift mirror of the `# Autonomy` slice of
    /// `Runtime.health_card`. Reads the
    /// on-disk trust policy at `<dataRoot>/trust/policy.json` (the SAME path /
    /// reader the autonomy gates use — `readAutonomyTrustPolicy`, TrustCenter),
    /// then emits the EXACT daemon row:
    ///   • `enableAutonomy == true`  → status "ok",   detail "Enabled",  no fixAction
    ///   • `enableAutonomy == false` → status "warn",  detail "Disabled", fixAction "enable_autonomy"
    ///
    /// Pure helper for the Swift-owned health-card composition. It reads the
    /// canonical trust policy rather than maintaining an independent health state.
    ///
    /// PARITY NOTE: the daemon wraps the WHOLE autonomy slice in ONE try/except
    /// (L28729-L28737) whose `except` emits a THIRD row shape — status "warn",
    /// detail "Could not check autonomy policy", no fixAction. That branch fires
    /// ONLY when `trust_policy()` itself raises. The Swift reader's
    /// `readAutonomyTrustPolicy` is fail-OPEN-to-deny (missing / unreadable /
    /// malformed file → `enableAutonomy=false` via `.parse(.object([:]))`), so a
    /// missing-file case maps to the DISABLED row ("Disabled" / "enable_autonomy"),
    /// NOT the except row — exactly matching the daemon, whose `read_json(...,{})`
    /// likewise returns `{}` → `enableAutonomy=False` for a missing file (the
    /// `except` only fires on a genuine raise inside `trust_policy()`, which the
    /// pure file read cannot reproduce here). The except-row shape is documented
    /// but unreachable from this pure helper; the caller composing the full card
    /// can fall back to it if its own policy load throws.
    ///
    /// `dataRoot` is injectable for deterministic tests; defaults to the daemon's
    /// data root. PURE READ (no write-back) — no flock needed.
    public static func autonomySubsystemEntry(
        in dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async -> HealthCardSubsystem {
        let policy = await readAutonomyTrustPolicy(dataRoot: dataRoot, persistence: persistence)
        // Mirrors `autonomy_on = bool(policy.get("enableAutonomy", False))` (L28731).
        // BYTE-FAITHFUL: the daemon applies Python `bool()` truthiness to the RAW
        // stored value, so a non-boolean truthy value (e.g. 1, "true", a non-empty
        // container) reports "Enabled". We therefore read the raw `enableAutonomy`
        // off the policy's `raw` JSON and apply retired truthiness via
        // `pythonBoolGet` (default False, matching `.get(..., False)`) — NOT the
        // TrustCenter view's `enableAutonomy`, whose `boolAt` accepts ONLY a strict
        // `.bool(true)` and would mis-report a legacy/hand-edited non-bool value
        // as Disabled. `enableAutonomy` is absent from `default_trust_policy()`
        //, so the raw saved file is the source of truth
        // for this key — reading `raw` here is equivalent to
        // `trust_policy().get("enableAutonomy", False)` with no merge divergence.
        // (gpt-5.5 wave-40 review finding #1.)
        let rawPolicy: [String: JSONValue]
        if case .object(let obj) = policy.raw { rawPolicy = obj } else { rawPolicy = [:] }
        let autonomyOn = Self.pythonBoolGet(rawPolicy, "enableAutonomy", default: false)
        if autonomyOn {
            // `_add("autonomy", "Autonomy", "ok", "Enabled")` (L28733).
            return HealthCardSubsystem(
                id: "autonomy", label: "Autonomy", status: "ok", detail: "Enabled"
            )
        }
        // `_add("autonomy", "Autonomy", "warn", "Disabled", "enable_autonomy")` (L28735).
        return HealthCardSubsystem(
            id: "autonomy", label: "Autonomy", status: "warn",
            detail: "Disabled", fixAction: "enable_autonomy"
        )
    }

    /// File-backed half of the scheduler health slice. Reads
    /// `<dataRoot>/scheduler/jobs.json` and counts enabled jobs; `enabled`
    /// defaults true, so a job is counted unless it carries an explicit falsy
    /// `enabled`.
    ///
    /// The caller supplies scheduler liveness separately; this helper does not
    /// fabricate an ok status from the jobs file alone. A caller that cannot
    /// observe the loop passes `schedulerThreadAlive: false`, yielding the
    /// conservative "warn" — never a falsely-green "ok". This keeps the
    /// blocked sub-fact honest rather than silently misreporting it (the
    /// [[feedback_run_dont_just_build]] failure made structural).
    ///
    /// `dataRoot` is injectable for deterministic tests; defaults to the daemon's
    /// data root. PURE READ (no write-back) — no flock needed.
    public static func schedulerSubsystemEntry(
        in dataRoot: URL? = nil,
        schedulerThreadAlive: Bool,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async -> HealthCardSubsystem {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root.appendingPathComponent("scheduler").appendingPathComponent("jobs.json")
        // Mirrors `jobs = read_json(self.jobs_path, [])` (L28777). PersistenceCore
        // returns the default ([]) on a missing / unreadable / non-array file —
        // matching the daemon's `read_json(self.jobs_path, [])` +
        // `if not isinstance(jobs, list): return []` (list_jobs L43330) → 0 jobs.
        let value = await persistence.readJSON(path, defaultValue: .array([]))
        var nEnabled = 0
        if case .array(let jobs) = value {
            for job in jobs {
                // PARITY (gpt-5.5 wave-40 review finding #2): the daemon's
                // list_jobs does `d = dict(j)` for EVERY element (L43341), OUTSIDE
                // any per-element try/except. For a non-dict element (string / int
                // / bool / null / non-pair list) `dict(j)` RAISES, the exception
                // propagates out of list_jobs into the scheduler slice's
                // `except Exception:` (L28782), and the daemon emits the WHOLE-SLICE
                // FALLBACK row `_add("scheduler","Scheduler","warn","Scheduler status
                // unavailable")` — NOT a partial count. So a non-object entry must
                // map to that fallback row here, NOT a silent skip-and-count (the
                // earlier `continue` diverged). (A JSON object element = a dict =
                // never raises; that is the only non-raising element shape, so a
                // single non-object entry trips the whole-slice fallback.)
                guard case .object(let obj) = job else {
                    return HealthCardSubsystem(
                        id: "scheduler", label: "Scheduler",
                        status: "warn", detail: "Scheduler status unavailable"
                    )
                }
                // `j.get("enabled", True)` — DEFAULTS TRUE. Count unless an explicit
                // `enabled` key is present AND Python-falsy. `pythonBoolGet` with
                // default True mirrors `bool(j.get("enabled", True))`.
                if Self.pythonBoolGet(obj, "enabled", default: true) { nEnabled += 1 }
            }
        }
        // `sched_status = "ok" if sched_alive else "warn"` (L28780) — STATUS is
        // the daemon-owned thread-liveness, supplied by the caller (BLOCKED slice).
        let status = schedulerThreadAlive ? "ok" : "warn"
        // `f"{n_enabled} enabled jobs"[:60]` (L28781).
        let detail = String("\(nEnabled) enabled jobs".prefix(60))
        return HealthCardSubsystem(
            id: "scheduler", label: "Scheduler", status: status, detail: detail
        )
    }

    /// Byte-faithful Swift mirror of the `# Pending approvals` slice of
    /// `Runtime.health_card`. Reads the
    /// on-disk approvals queue at `<dataRoot>/workflows/approvals/requests.json`
    /// (the daemon's `self.approvals_path = root / "workflows" / "approvals" /
    /// "requests.json"`, L2314 — the SAME path `list_approval_requests` reads,
    /// L7474), counts the records whose `status == "pending"`, and emits the
    /// EXACT daemon row:
    ///   • `n_pending == 0` → status "ok",   detail "No pending approvals", no fixAction
    ///   • `n_pending  > 0` → status "warn", detail "<n> pending", fixAction "show_approvals"
    ///
    /// Pure helper for the Swift-owned health-card composition. Pending approval
    /// state is derived from the canonical approval store.
    ///
    /// PARITY NOTES (gpt-5.5-grade, verified against `list_approval_requests` +
    /// the health_card slice):
    ///  • `read_json(self.approvals_path, [])` + `if not isinstance(approvals,
    ///    list): return []` (L7474-L7476) → a MISSING / unreadable / non-array file
    ///    yields ZERO approvals → the "No pending approvals" (ok) row, NOT the
    ///    daemon's `except`→"Approval queue unavailable" branch. PersistenceCore's
    ///    `readJSON(path, defaultValue: .array([]))` returns `[]` on exactly those
    ///    cases, matching. The `except` row is documented-but-unreachable from this
    ///    pure read (it fires only on a genuine raise inside `list_approval_requests`,
    ///    which the file read cannot reproduce).
    ///  • `a.get("status") == "pending"` (L28757): the daemon iterates the RAW list
    ///    elements. A non-object element (string/int/null/array) has no `.get` in
    ///    Python and WOULD raise `AttributeError` mid-comprehension → the WHOLE-SLICE
    ///    `except`→"Approval queue unavailable" (ok) row. So a non-object element
    ///    maps to that fallback row here, NOT a silent skip (mirrors the scheduler
    ///    slice's whole-slice-bail-on-bad-element parity, gpt-5.5 wave-40 finding #2).
    ///  • The detail string `f"{n_pending} pending"` (L28762) is NOT truncated in the
    ///    daemon (no `[:60]`, UNLIKE the inbox/scheduler/crash slices) — kept verbatim.
    ///
    /// `dataRoot` is injectable for deterministic tests; defaults to the daemon's
    /// data root. PURE READ (no write-back) — no flock needed.
    public static func approvalsSubsystemEntry(
        in dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async -> HealthCardSubsystem {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root
            .appendingPathComponent("workflows")
            .appendingPathComponent("approvals")
            .appendingPathComponent("requests.json")
        // `read_json(self.approvals_path, [])` + non-list → [] (L7474-L7476).
        let value = await persistence.readJSON(path, defaultValue: .array([]))
        var nPending = 0
        if case .array(let approvals) = value {
            for approval in approvals {
                // `a.get("status")` on a non-dict element raises AttributeError in
                // the daemon's comprehension → the WHOLE-SLICE except fallback, NOT
                // a partial count. (Parity with the scheduler slice's non-object
                // bail; gpt-5.5 wave-40 review finding #2.)
                guard case .object(let obj) = approval else {
                    return HealthCardSubsystem(
                        id: "approvals", label: "Approvals",
                        status: "ok", detail: "Approval queue unavailable"
                    )
                }
                // `a.get("status") == "pending"` (L28757). A missing key → None
                // (not "pending"); a non-string `status` → not equal to "pending".
                if case .string(let s)? = obj["status"], s == "pending" {
                    nPending += 1
                }
            }
        }
        if nPending == 0 {
            // `_add("approvals", "Approvals", "ok", "No pending approvals")` (L28760).
            return HealthCardSubsystem(
                id: "approvals", label: "Approvals", status: "ok",
                detail: "No pending approvals"
            )
        }
        // `_add("approvals","Approvals","warn",f"{n_pending} pending","show_approvals")` (L28762).
        // NOTE: NO `[:60]` truncation in the daemon for this slice.
        return HealthCardSubsystem(
            id: "approvals", label: "Approvals", status: "warn",
            detail: "\(nPending) pending", fixAction: "show_approvals"
        )
    }

    /// Byte-faithful Swift mirror of the `# Inbox` slice of `Runtime.health_card`
    ///. Reproduces the daemon's
    /// `self._get_inbox().list(unread_only=False, limit=1000)` + unread-recount
    /// against the inbox's TWO-FILE store:
    ///   • `<dataRoot>/inbox/items.jsonl` — append-only item log
    ///   • `<dataRoot>/inbox/index.json`  — status overlay (id → {status, read_at})
    /// then emits the EXACT daemon row:
    ///   • `n_unread <= 10` → status "ok"
    ///   • `n_unread  > 10` → status "warn"
    /// with detail `f"{n_unread} pending"[:60]` (L28771 — TRUNCATED at 60, UNLIKE
    /// the approvals slice). No fixAction on either branch.
    ///
    /// WAVE 42 W17 (§6.260) — the FOURTH genuinely-portable health_card slice.
    /// PURE HELPER, behind the existing default-OFF `.systemHealthCard` flag (NO new
    /// flag). Same MULTI-FLAG full-card-blocked note as `approvalsSubsystemEntry`.
    ///
    /// PARITY NOTES (verified against `Inbox._load_all` + `Inbox.list` + the slice):
    ///  • `_load_all` returns `[]` if `items.jsonl` does NOT exist —
    ///    REGARDLESS of `index.json`. So a missing items log = 0 items = "0 pending"
    ///    (ok) — NOT the daemon's `except`→"Inbox unavailable" row (that fires only
    ///    on a genuine raise, unreproducible from a pure read). PersistenceCore's
    ///    `readJSONL` returns `[]` for a missing file, matching.
    ///  • Each line is parsed; UNPARSEABLE lines are SKIPPED (`except: pass`, L281).
    ///    `readJSONL`'s `compactMap { try? JSONValue.parse }` already drops
    ///    unparseable lines, matching.
    ///  • Per-item `status` DEFAULTS to "unread" when the JSONL record omits it
    ///    (`InboxItem.from_dict`: `status=str(d.get("status", "unread"))`, L121).
    ///  • OVERLAY (L276-L279): if `item.id in index`, the item's status is REPLACED
    ///    by `str(index[item.id].get("status", item.status))`. So an item dismissed/
    ///    read via the index overlay no longer counts as unread even if its JSONL
    ///    record still says "unread" — and an index entry can flip a stored "read"
    ///    BACK to "unread". `item.id in index` uses the item's id AS-PARSED
    ///    (`str(d.get("id",""))`); an item with empty id ("") matches an index key
    ///    "". We mirror EXACTLY: parse id with the same `str(...,"")` default.
    ///  • `list(unread_only=False, limit=1000)`: sort the FULL
    ///    overlaid set by `created_at` DESC, then take the first 1000. The health_card
    ///    then re-counts unread among THOSE (up to) 1000 (L28768-L28769). So with
    ///    >1000 items, only the 1000 MOST-RECENT-by-created_at are considered — a
    ///    silent cap we reproduce, NOT a count over the whole file. Python's string
    ///    sort on `created_at` (ISO-8601) is lexicographic; we sort the same string
    ///    field with `>` for DESC. Python's `list.sort` is STABLE — Swift
    ///    `sorted(by:)` is NOT guaranteed stable, and the 1000-cap CAN make tie
    ///    order observable (an equal-`created_at` tie straddling item 1000 with
    ///    mixed unread/read changes the count). So we reproduce stability EXACTLY
    ///    by decorating with `enumerated()` and tie-breaking on the original parse
    ///    index (ascending) — Python's stable `reverse=True` order. (gpt-5.5 wave-42
    ///    review finding #1.)
    ///  • `getattr(i, "status", None) == "unread"` (L28769): InboxItem.status is
    ///    always a str, so this is a plain `== "unread"`.
    ///  • detail `f"{n_unread} pending"[:60]` (L28771) — TRUNCATED (unlike approvals).
    ///  • KNOWN RESIDUAL (gpt-5.5 wave-42 re-review finding #3, INTENTIONALLY NOT
    ///    FIXED here): Python `_load_all` reads via `read_text(encoding="utf-8")`,
    ///    which RAISES `UnicodeDecodeError` on a file containing invalid UTF-8 →
    ///    the "Inbox unavailable" fallback row. Swift `readJSONL` →
    ///    `PersistenceCore.decodeLines` decodes invalid UTF-8 with REPLACEMENT
    ///    (DELIBERATE `errors="replace"` parity for `tail_jsonl`), so a non-UTF-8
    ///    existing items.jsonl yields "0 pending" instead of the fallback. The fix
    ///    belongs in shared `decodeLines` (whose replace-semantics other JSONL
    ///    callers rely on), NOT this slice — touching it would be cross-cutting
    ///    scope-creep. The case is unreproducible in practice (the daemon writes
    ///    ONLY valid UTF-8 JSON to items.jsonl); documented honestly rather than
    ///    fixed by reaching into shared infra.
    ///
    /// `dataRoot` is injectable for deterministic tests; defaults to the daemon's
    /// data root. PURE READ (no write-back) — no flock needed.
    public static func inboxSubsystemEntry(
        in dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async -> HealthCardSubsystem {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        // A5.2 (2026-07-24): the legacy <root>/inbox/ silo is retired. The
        // health card now counts the LIVE inbox (notifications/inbox.jsonl) —
        // append-only, last-write-wins per id (a status change appends a full
        // replacement row), no index overlay.
        let itemsPath = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")

        // `_load_all`: returns [] ONLY if items.jsonl does NOT
        // exist. An EXISTING-but-unreadable file (permission / decode error) lets
        // `read_text` raise OUT of _load_all → out of `list()` → into the
        // health_card slice's `except` → the "Inbox unavailable" (ok) row (L28772).
        // So we must DISTINGUISH missing (→ zero) from exists-but-unreadable
        // (→ fallback row). (gpt-5.5 wave-42 review finding #3.)
        let fm = FileManager.default
        let rawItems: [JSONValue]
        if !fm.fileExists(atPath: itemsPath.path) {
            // Missing file → empty (L264). readJSONL also returns [] here; we
            // short-circuit so the catch below applies ONLY to a present file.
            rawItems = []
        } else {
            do {
                rawItems = try await persistence.readJSONL(itemsPath)
            } catch {
                // Existing file, read failed → daemon's `except`→"Inbox unavailable".
                return HealthCardSubsystem(
                    id: "inbox", label: "Inbox", status: "ok",
                    detail: "Inbox unavailable"
                )
            }
        }

        // Collapse to the FINAL row per id (last-write-wins): a dismissed or
        // archived card must count by its latest status, not its first
        // appearance. Rows keep the file position of their FIRST occurrence
        // for the stable sort tie-break below.
        struct _Item { let id: String; let createdAt: String; let status: String }
        var order: [String] = []
        var latest: [String: _Item] = [:]
        for raw in rawItems {
            // Non-object lines are dropped, mirroring the old per-line
            // tolerance — one malformed row must not fail the whole card.
            guard case .object(let obj) = raw else { continue }
            let id = Self.pythonStrGet(obj, "id", default: "")
            guard !id.isEmpty else { continue }
            let createdAt = Self.pythonStrGet(obj, "created_at", default: "")
            let status = Self.pythonStrGet(obj, "status", default: "unread")
            if latest[id] == nil { order.append(id) }
            latest[id] = _Item(id: id, createdAt: createdAt, status: status)
        }
        let items: [_Item] = order.compactMap { latest[$0] }

        // `list(unread_only=False, limit=1000)`: sort by created_at DESC, take 1000
        //. Python `list.sort` is STABLE — equal-`created_at`
        // items keep their original (file/insertion) order. Swift `sorted(by:)` is
        // NOT guaranteed stable, so we tie-break on the original parse index to
        // reproduce the stable order EXACTLY — otherwise an equal-timestamp tie
        // straddling the 1000-cap with mixed unread/read could change the count.
        // (gpt-5.5 wave-42 review finding #1.) reverse=True on created_at → DESC;
        // the tie-break keeps ascending original order (Python sort stability).
        let indexed = Array(items.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt   // DESC
            }
            return lhs.offset < rhs.offset   // stable: original order on ties
        }
        let capped = sorted.prefix(1000).map { $0.element }

        // `n_unread = sum(1 for i in inbox_items if i.status == "unread")` (L28768-L28769).
        let nUnread = capped.reduce(into: 0) { acc, item in
            if item.status == "unread" { acc += 1 }
        }
        // `inbox_status = "warn" if n_unread > 10 else "ok"` (L28770).
        let status = nUnread > 10 ? "warn" : "ok"
        // `f"{n_unread} pending"[:60]` (L28771) — TRUNCATED at 60.
        let detail = String("\(nUnread) pending".prefix(60))
        return HealthCardSubsystem(
            id: "inbox", label: "Inbox", status: status, detail: detail
        )
    }

    /// Byte-faithful Swift mirror of Python `str(obj.get(key, default))` for a JSON
    /// object — i.e. `.get(key, default)` followed by Python `str(...)`.
    ///   • KEY ABSENT   → returns `default` (the caller's Python default string).
    ///   • KEY PRESENT  → `str(value)` of the STORED JSON value: a JSON string is
    ///     returned verbatim; null → "None"; true/false → "True"/"False"; an int
    ///     prints without a decimal; a whole double prints with a trailing ".0"
    ///     (Python `str(1.0) == "1.0"`); containers stringify to their Python repr.
    /// Used by the inbox slice for `id` / `created_at` / `status` extraction, all of
    /// which the daemon wraps in `str(...)`. (For the inbox parity the realistic
    /// stored values are strings; the non-string branches exist for faithful
    /// `str()` coercion so a hand-edited / legacy non-string field cannot diverge.)
    static func pythonStrGet(_ obj: [String: JSONValue], _ key: String, default def: String) -> String {
        guard let value = obj[key] else { return def }   // key absent → default
        switch value {
        case .string(let s): return s
        case .null:          return "None"
        case .bool(let b):   return b ? "True" : "False"
        case .int(let i):    return String(i)
        case .double(let d):
            // Python str(float): whole values keep a trailing ".0"; others use the
            // shortest round-trip repr. Swift's default Double description matches
            // closely enough for the realistic (always-string) inbox fields; we add
            // the ".0" for integral doubles to mirror Python's `str(1.0) == "1.0"`.
            if d == d.rounded() && abs(d) < 1e16 {
                return String(format: "%.1f", d)
            }
            return String(d)
        case .array, .object:
            // Containers are never expected for these scalar fields; fall back to a
            // best-effort repr. (Unreachable in practice for id/created_at/status.)
            return String(describing: value)
        }
    }

    /// Byte-faithful predicate for whether Python `list(value or [])` would RAISE.
    /// Mirrors `InboxItem.from_dict`'s `actions=list(d.get("actions") or [])`
    ///: the `or []` substitutes [] for any FALSY value
    /// (null / false / 0 / 0.0 / "" / [] / {}), so those never reach `list(...)`
    /// of a scalar; `list(x)` then RAISES TypeError only for a TRUTHY NON-ITERABLE
    /// — i.e. a truthy int / float / bool. (A truthy string is iterable → list of
    /// chars; a non-empty array/object is iterable → no raise.) Returns true ONLY
    /// for the raise cases, so the caller can DROP that line exactly like the
    /// daemon's per-line `except: pass`. (gpt-5.5 wave-42 review finding #4.)
    static func pythonListWouldRaise(_ value: JSONValue) -> Bool {
        switch value {
        case .null:            return false   // None → falsy → `or []` → list([]) ok
        case .bool(let b):     return b       // True is truthy non-iterable → raise
        case .int(let i):      return i != 0  // truthy int → list(int) raises
        case .double(let d):   return d != 0  // truthy float → list(float) raises
        case .string:          return false   // any string is iterable → list(str) ok
        case .array, .object:  return false   // iterable → list(...) ok
        }
    }

    /// Byte-faithful Swift mirror of Python `bool(obj.get(key, default))` for a
    /// JSON object — i.e. `.get(key, default)` followed by retired truthiness.
    ///   • KEY ABSENT      → returns `default` (the caller's Python default).
    ///   • KEY PRESENT      → retired truthiness of the STORED value, regardless of
    ///     the default: null / false / 0 / 0.0 / "" / empty array / empty object
    ///     → false; any other value → true.
    /// In Swift, `obj[key]` is `nil` ONLY when the key is ABSENT; a JSON `null`
    /// parses to `.null` (present-but-falsy). Exposed `static` (not private) so the
    /// parity tests can pin the truthiness table directly. Used by BOTH the
    /// autonomy slice (`bool(policy.get("enableAutonomy", False))`, default false)
    /// and the scheduler enabled-count (`bool(j.get("enabled", True))`,
    /// default true).
    static func pythonBoolGet(_ obj: [String: JSONValue], _ key: String, default def: Bool) -> Bool {
        guard let value = obj[key] else { return def }   // key absent → default
        switch value {
        case .null:            return false    // explicit null is falsy
        case .bool(let b):     return b
        case .int(let i):      return i != 0
        case .double(let d):   return d != 0   // -0.0 == 0 → false, matching Python
        case .string(let s):   return !s.isEmpty
        case .array(let a):    return !a.isEmpty
        case .object(let o):   return !o.isEmpty
        }
    }
}
