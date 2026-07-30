import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - GET /v1/improvements/runs/<id>/diff — SwiftNative local port
//
// Wave 33 W09. This CORRECTS the wave-31 W07 (§6.55) classification of
// `GET /v1/improvements/runs/<id>/diff` as `KEPT_NO_NATIVE_IMPL`. W07's stated
// reason was *"get_improvement_diff shells `git -C <worktree> diff`; no Swift
// subprocess surface in this module"* — that second clause was factually wrong.
// `SelfImprovement+Git.swift` already ships `SelfImprovementGitOps`, a real
// `Foundation.Process`-backed `git -C <dir>` subprocess surface in THIS module
// (it powers `applyDiffAndCommit` / `revertCommit` / `stashSnapshot`). The diff
// route is therefore portable exactly like the wave-32 W09 gauntlet read: a
// run-record lookup over `improvements/runs.json` (the file this actor already
// reads) plus a read-only `git` invocation against the run's worktree.
//
// DAEMON BACKING — `get_improvement_diff(run_id)`:
//   1. `run = self._get_improvement(run_id)` (L44325) — reads
//      `improvements_path` (= `improvements/runs.json`) under `improvements_lock`,
//      coerces to a list, returns the first run whose `id == run_id`, else None.
//      None → the route handler sends 404 `{"error": "not_found", ...}`.
//   2. `worktree = run["worktree"]`; `worktree_exists = worktree and worktree.exists()`.
//   3. When the worktree exists:
//        - `diffText` = `git -C <worktree> diff --cached` stdout (best-effort; "" on error).
//        - `numstat`  = `git -C <worktree> diff --cached --numstat` stdout.
//        - `porcelain`= `git -C <worktree> status --porcelain` stdout.
//        - Build a status_map from porcelain: for each line ≥3 chars, `code =
//          line[:2].strip() or "M"`, `fpath = line[3:].strip()`.
//        - For each numstat line split on "\t" into ≤3 parts (exactly 3 used):
//          adds = int(parts[0]) (0 when "-" or non-int), dels likewise, fpath =
//          parts[2].strip(), status = status_map.get(fpath, "M"). Append
//          {path, status, additions, deletions}.
//        - Re-read the receipt from `<worktree>/AUTONOMY_RECEIPT.md` if present
//          (overrides the stored `autonomyReceipt` field, errors:"replace",
//          stripped).
//   4. Returns {runId, objective, phase, status, worktree, worktreeExists,
//      receipt, diffText, files}.
//
// CONSUMER — Mac-only. `NativeClient.getImprovementDiff(runId:)`
// (Sources/NativeAgentApp/NativeClient.swift) → `ImprovementDiffPayload`
// (Sources/NativeAgentApp/Models.swift:3462) → `ImprovementDiffSheet`
// (ContentView.swift:9493). NO iOS caller (rg of iOS/NativeAgentMobile = none),
// so the seam can flip Mac-only without an iOS pin holding the route live.
//
// DISPOSITION: Swift-native local port. The app reads this in-process; no
// daemon route or HTTP fallback remains. See CUTOVER_PLAN §6.96.

/// One changed-file entry in an improvement diff — mirrors the daemon dict
/// `{"path","status","additions","deletions"}`.
public struct ImprovementDiffFileEntry: Sendable, Codable, Equatable {
    public var path: String
    public var status: String
    public var additions: Int
    public var deletions: Int

    public init(path: String, status: String, additions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// Result of GET /v1/improvements/runs/<id>/diff. Mirrors the dict returned by
/// `get_improvement_diff()` field-for-field. Every
/// key is ALWAYS emitted (the daemon's return dict is unconditional), so this
/// encodes a fixed key set — no present-when-empty branching needed.
public struct ImprovementDiffPayload: Sendable, Codable, Equatable {
    public var runId: String
    public var objective: String
    public var phase: String
    public var status: String
    public var worktree: String
    public var worktreeExists: Bool
    public var receipt: String
    public var diffText: String
    public var files: [ImprovementDiffFileEntry]

    public init(
        runId: String,
        objective: String,
        phase: String,
        status: String,
        worktree: String,
        worktreeExists: Bool,
        receipt: String,
        diffText: String,
        files: [ImprovementDiffFileEntry]
    ) {
        self.runId = runId
        self.objective = objective
        self.phase = phase
        self.status = status
        self.worktree = worktree
        self.worktreeExists = worktreeExists
        self.receipt = receipt
        self.diffText = diffText
        self.files = files
    }
}

/// Raised when no run with the given id exists in `improvements/runs.json`.
/// Mirrors the daemon's `raise KeyError(f"run {run_id} not found")`
/// → the route handler's 404 `not_found`.
public struct ImprovementRunNotFound: Error, Equatable, Sendable {
    public let runId: String
    public init(runId: String) { self.runId = runId }
}

extension SwiftNativeSelfImprovement {

    /// The diff-staged `git` invocations a worktree needs, behind a seam so the
    /// run-lookup + porcelain/numstat parsing is unit-testable WITHOUT a real
    /// git repo (the InMemoryPersistenceCore harness has no filesystem). The
    /// default implementation shells `git -C <worktree> …` via the same
    /// `Foundation.Process` mechanism `SelfImprovementGitOps` uses.
    public struct DiffGitProbe: Sendable {
        /// `git -C <worktree> diff --cached` stdout, or "" on any failure
        /// (matches the daemon's `try: … except Exception: diff_text = ""`).
        public var diffCached: @Sendable (URL) -> String
        /// `git -C <worktree> diff --cached --numstat` stdout ("" on failure).
        public var numstat: @Sendable (URL) -> String
        /// `git -C <worktree> status --porcelain` stdout ("" on failure).
        public var statusPorcelain: @Sendable (URL) -> String
        /// Whether the worktree directory exists (default: FileManager check).
        public var directoryExists: @Sendable (URL) -> Bool
        /// Contents of `<worktree>/AUTONOMY_RECEIPT.md` if present, else nil
        /// (default: read with errors-replace + strip).
        public var receipt: @Sendable (URL) -> String?

        public init(
            diffCached: @escaping @Sendable (URL) -> String,
            numstat: @escaping @Sendable (URL) -> String,
            statusPorcelain: @escaping @Sendable (URL) -> String,
            directoryExists: @escaping @Sendable (URL) -> Bool,
            receipt: @escaping @Sendable (URL) -> String?
        ) {
            self.diffCached = diffCached
            self.numstat = numstat
            self.statusPorcelain = statusPorcelain
            self.directoryExists = directoryExists
            self.receipt = receipt
        }

        /// The production probe: real `git` subprocess + filesystem reads,
        /// byte-for-byte matching `get_improvement_diff`'s subprocess calls
        /// (`text=True, capture_output=True, timeout=30`) and its
        /// `AUTONOMY_RECEIPT.md` re-read (errors="replace", `.strip()`).
        public static let live = DiffGitProbe(
            diffCached: { wt in Self.runGitStdout(wt, ["diff", "--cached"]) },
            numstat: { wt in Self.runGitStdout(wt, ["diff", "--cached", "--numstat"]) },
            statusPorcelain: { wt in Self.runGitStdout(wt, ["status", "--porcelain"]) },
            directoryExists: { wt in
                // Python: `worktree.exists()` — true
                // for ANY existing path (regular file OR directory), NOT
                // directory-only. Match that with a plain existence check so a
                // malformed run whose `worktree` points at a file behaves
                // identically (the git probes then fail gracefully → empty).
                FileManager.default.fileExists(atPath: wt.path)
            },
            receipt: { wt in
                let receiptURL = wt.appendingPathComponent("AUTONOMY_RECEIPT.md")
                guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
                guard let data = try? Data(contentsOf: receiptURL) else { return nil }
                // Python: read_text(errors="replace").strip(). String(decoding:as:)
                // substitutes U+FFFD for invalid UTF-8, matching errors="replace".
                let text = String(decoding: data, as: UTF8.self)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        /// Run `git -C <worktree> <args>` with a 30s timeout (matching the
        /// daemon's `timeout=30`), returning stdout. Returns "" on spawn
        /// failure OR on timeout — both are cases where Python's
        /// `subprocess.run(..., timeout=30)` RAISES (TimeoutExpired /
        /// FileNotFoundError, both subclasses of Exception) and the daemon's
        /// `except Exception` collapses the result to "" (the retired daemon
        /// L44416-44417). NOTE: Python does NOT inspect the return code — a
        /// normal non-zero `git` exit still yields its captured stdout, so we
        /// likewise return stdout for any process that EXITS within the timeout,
        /// regardless of exit status.
        private static func runGitStdout(_ worktree: URL, _ args: [String]) -> String {
            let proc = Process()
            proc.launchPath = "/usr/bin/env"
            proc.arguments = ["git", "-C", worktree.path] + args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                return ""
            }
            // On timeout we `terminate()` the process (SIGTERM). Python RAISES
            // TimeoutExpired in that case and the partial stdout is discarded,
            // so we must return "" — NOT the partial capture. We detect the
            // termination-by-signal AFTER waitUntilExit() via the process's own
            // terminationReason (race-free: it's set by the time the process
            // has reaped), rather than a cross-closure mutable flag.
            let timeoutItem = DispatchWorkItem { [weak proc] in
                if let p = proc, p.isRunning { p.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30.0, execute: timeoutItem)
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            timeoutItem.cancel()
            // terminationReason == .uncaughtSignal means we SIGTERM'd it on the
            // 30s deadline (the timeout path). git itself exits cleanly with a
            // status code (.exit) even on error, so a signal-termination here is
            // unambiguously our timeout kill → Python's TimeoutExpired → "".
            if proc.terminationReason == .uncaughtSignal {
                return ""
            }
            return String(data: outData, encoding: .utf8) ?? ""
        }
    }

    /// `<root>/improvements/runs.json` — the daemon's `improvements_path`.
    private func improvementsRunsPath() -> URL {
        trainingPromotionDataRoot()
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("runs.json")
    }

    /// Local-disk port of `get_improvement_diff(run_id)` (the retired daemon
    /// L44396). Reads the run record from `improvements/runs.json`, then probes
    /// the run's worktree with read-only `git` to assemble the diff envelope.
    ///
    /// Throws `ImprovementRunNotFound` when no run matches `runId` (mirrors the
    /// daemon's `KeyError` → 404). All other fields default to "" / [] / false
    /// exactly as the daemon does when the worktree is absent.
    ///
    /// - Parameters:
    ///   - runId: the improvement run id to diff.
    ///   - probe: injectable git/filesystem surface (defaults to `.live`).
    public func improvementDiffLocal(
        runId: String,
        probe: DiffGitProbe = .live
    ) async throws -> ImprovementDiffPayload {
        // Step 1: _get_improvement — read runs.json, coerce to list, find by id.
        // PersistenceCore.readJSON is the same atomic-read the daemon's
        // read_json mirrors (tmp+os.replace on the write side guarantees the
        // reader never sees a torn file — no flock needed for this pure read).
        let raw = await trainingPromotionPersistence()
            .readJSON(improvementsRunsPath(), defaultValue: .array([]))
        let runs: [JSONValue]
        if case .array(let arr) = raw {
            runs = arr
        } else {
            // Python: `runs = runs if isinstance(runs, list) else []`.
            runs = []
        }
        var run: [String: JSONValue]?
        for entry in runs {
            guard case .object(let obj) = entry else { continue }
            guard let idValue = obj["id"], case .string(let id) = idValue else { continue }
            if id == runId {
                run = obj
                break
            }
        }
        guard let run else {
            throw ImprovementRunNotFound(runId: runId)
        }

        // Helper: `str(run.get(key) or "")` — Python coerces None/missing/"" to "".
        func str(_ key: String) -> String {
            if let value = run[key], case .string(let s) = value { return s }
            return ""
        }

        let worktreeStr = str("worktree")
        let worktreeURL = worktreeStr.isEmpty ? nil : URL(fileURLWithPath: worktreeStr)
        let worktreeExists = worktreeURL.map { probe.directoryExists($0) } ?? false

        var diffText = ""
        var files: [ImprovementDiffFileEntry] = []
        // Python seeds `receipt` from the stored field FIRST, then overrides
        // from disk only if the on-disk receipt exists.
        var receipt = str("autonomyReceipt")

        if worktreeExists, let worktreeURL {
            diffText = probe.diffCached(worktreeURL)
            let numstat = probe.numstat(worktreeURL)
            let porcelain = probe.statusPorcelain(worktreeURL)
            // PARITY NOTE (narrow divergence): Python wraps the numstat call, the
            // porcelain call, AND the parsing in ONE try/except (the retired daemon
            // L44418-44446), so if EITHER subprocess raises (e.g. a timeout),
            // `files` stays []. The `.live` probe returns "" on timeout for each
            // call independently, so parseDiffFiles("", "") = [] (numstat
            // timeout) and parseDiffFiles(numstat, "") would still yield rows
            // with the default "M" status (porcelain-only timeout). Only the
            // porcelain-times-out-but-numstat-succeeds sub-case differs
            // (Python: []; here: rows defaulting to "M"). Both git calls run
            // back-to-back against the same worktree, so a one-but-not-the-other
            // timeout is effectively unreachable; not worth coupling the
            // testable probe seam to match it exactly.
            files = Self.parseDiffFiles(numstat: numstat, porcelain: porcelain)
            if let onDisk = probe.receipt(worktreeURL) {
                receipt = onDisk
            }
        }

        return ImprovementDiffPayload(
            runId: runId,
            objective: str("objective"),
            phase: str("phase"),
            status: str("status"),
            worktree: worktreeStr,
            worktreeExists: worktreeExists,
            receipt: receipt,
            diffText: diffText,
            files: files
        )
    }

    /// Pure parser for the numstat + porcelain pair — extracted so it can be
    /// unit-tested without git. Mirrors the retired daemon exactly.
    static func parseDiffFiles(numstat: String, porcelain: String) -> [ImprovementDiffFileEntry] {
        // Build status_map from porcelain: "XY path" — code = line[:2].strip() or "M".
        // Python iterates `porcelain.splitlines()`; lines with len >= 3 only.
        var statusMap: [String: String] = [:]
        for line in porcelain.pythonSplitlines() where line.count >= 3 {
            // line[:2].strip() — the two status columns, whitespace-trimmed.
            let codeRaw = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            let code = codeRaw.isEmpty ? "M" : codeRaw
            // line[3:].strip() — skip the single space separator at index 2.
            let fpath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            statusMap[fpath] = code
        }

        var files: [ImprovementDiffFileEntry] = []
        for line in numstat.pythonSplitlines() {
            // Python: parts = line.split("\t", 2) — at most 3 fields. Only the
            // exactly-3-field case is used (adds, dels, path).
            let parts = line.pythonSplit(separator: "\t", maxSplit: 2)
            guard parts.count == 3 else { continue }
            // adds = int(parts[0]) if parts[0] != "-" else 0; non-int → 0
            // (Python wraps the int() in try/except ValueError → adds,dels=0,0).
            let adds = parts[0] == "-" ? 0 : (Int(parts[0]) ?? 0)
            let dels = parts[1] == "-" ? 0 : (Int(parts[1]) ?? 0)
            // BUT: Python catches ValueError for BOTH ints together, so if EITHER
            // is a non-"-" non-int, BOTH become 0. Reproduce that joint failure.
            let bothValid = (parts[0] == "-" || Int(parts[0]) != nil)
                && (parts[1] == "-" || Int(parts[1]) != nil)
            let additions = bothValid ? adds : 0
            let deletions = bothValid ? dels : 0
            let fpath = parts[2].trimmingCharacters(in: .whitespaces)
            let st = statusMap[fpath] ?? "M"
            files.append(ImprovementDiffFileEntry(path: fpath, status: st, additions: additions, deletions: deletions))
        }
        return files
    }
}

// MARK: - Python str-method parity helpers (file-local)

private extension String {
    /// Python `str.splitlines()` parity for the line shapes git emits: splits on
    /// "\n" (and "\r\n" via the trailing-"\r" trim), and — critically — does NOT
    /// produce a trailing empty element for a final newline (unlike Swift's
    /// `components(separatedBy:)`). git stdout always ends in "\n", so the naive
    /// split would add a spurious "" line that the Python code never sees.
    func pythonSplitlines() -> [String] {
        guard !isEmpty else { return [] }
        var lines = components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        // Drop a single trailing empty element caused by a terminating newline,
        // matching Python's splitlines (which yields no empty tail line).
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Python `str.split(sep, maxsplit)` parity: at most `maxSplit` splits →
    /// `maxSplit + 1` fields, with the remainder kept whole in the last field.
    func pythonSplit(separator: Character, maxSplit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var splits = 0
        for ch in self {
            if ch == separator && splits < maxSplit {
                result.append(current)
                current = ""
                splits += 1
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }
}
