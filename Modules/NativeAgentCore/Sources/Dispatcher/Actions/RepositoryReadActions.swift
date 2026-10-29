import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import MacControl
import PersistenceCore
import TrustCenter
import CoreWLAN
import SystemConfiguration
#if canImport(Darwin)
import Darwin
import Darwin
#endif
// Blueprint: | `RepositoryReadActions.swift` | `FileSystemActions` repository reads: descriptor-pinned grep, parsed Git status, dated diff/log and dirty summary; Git executable, environment, config and sandbox policy shared with `FileReadSourceMaterial.shellReadLaunch` |

let connectorGrepMaxResults = 50

extension FileReadSourceMaterial {
    /// Certified shell reads share Git's existing read-only process boundary,
    /// including its config, environment and sensitive-store fences.
    package static func shellReadLaunch(words: [String], cwd: String, dataRoot: URL) -> (arguments: [String], environment: [String: String]) {
        let ctx = ConnectorActionContext(repoRoot: URL(fileURLWithPath: cwd),
            fileAccess: ["mode": .string("full"), "sandbox": .string("danger-full-access")], dataRoot: dataRoot)
        var command = words
        if command.first == "/usr/bin/git" {
            command.insert(contentsOf: FileSystemActions.gitReadOnlyConfigOverrideArgs, at: 1)
            // Diff/show/log must not invoke conversion or external diff helpers.
            if let operation = words.dropFirst().first, operation != "status" {
                command.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 2 + FileSystemActions.gitReadOnlyConfigOverrideArgs.count)
            }
        }
        return (["-p", FileSystemActions.gitReadOnlySandboxProfile(ctx)] + command,
                FileSystemActions.gitReadOnlyEnvironment)
    }
}

extension FileSystemActions {
    // MARK: - grep
    //
    // Read-only search through verified paths, with bounded capture and matches.

    static func grep(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let pattern = (input["pattern"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return errResult("pattern is required", code: "bad_input") }
        let rawMr = input["max_results"]
        guard let parsedMr = safeInt(rawMr, default: connectorGrepMaxResults) else {
            return errResult("max_results must be an integer, got \(jsonRepr(rawMr))", code: "bad_input")
        }
        // Pass negative limits to the engine for grep_error; guard prefix separately.
        let maxResults = min(parsedMr, connectorGrepMaxResults)
        let sliceCount = max(0, maxResults)

        // An empty search path uses the repository root.
        let rawPathField = input["path"]?.stringValue ?? ""
        let rawSearchPath = rawPathField.isEmpty ? "." : rawPathField
        let searchPath = resolvePath(rawSearchPath, repoRoot: ctx.repoRoot, workspaceRoot: ctx.workspaceRoot)

        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(searchPath, allowed) {
            return errResult(
                "Path '\(searchPath.path)' is outside sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(searchPath, ctx) {
            return errResult(
                "Path '\(searchPath.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Use dedicated Swift runtime tools instead.",
                code: "path_not_allowed"
            )
        }

        // Search "." in the verified directory descriptor; refuse every walk failure.
        var searchTarget = searchPath.path
        var spawnDirectory: URL? = nil
        var fileDisplayPath: String? = nil
        #if canImport(Darwin)
        // Single-file searches inherit the verified file descriptor itself.
        let inheritedChildDescriptor: Int32 = 3
        var cwdFD: Int32 = -1
        var searchFD: Int32 = -1
        defer {
            if cwdFD >= 0 { _ = Darwin.close(cwdFD) }
            if searchFD >= 0 { _ = Darwin.close(searchFD) }
        }
        do {
            let parent = try VerifiedPath.openParent(of: searchPath)
            // The deferred owner holds this descriptor even if openFinal throws.
            cwdFD = parent.fd
            // O_NOFOLLOW on the final component too: it is part of the path the
            // sandbox check judged.
            let finalFD = try VerifiedPath.openFinal(parent, flags: O_RDONLY | O_NONBLOCK)
            var metadata = stat()
            guard fstat(finalFD, &metadata) == 0 else {
                _ = Darwin.close(finalFD)
                return errResult(
                    "The authorized path could not be verified before the search.",
                    code: "path_not_allowed"
                )
            }
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                // The parent has done its job; ownership of the verified
                // DIRECTORY transfers to the same deferred owner.
                _ = Darwin.close(cwdFD)
                cwdFD = finalFD
                searchTarget = "."
                spawnDirectory = searchPath
            case mode_t(S_IFREG):
                // Kept open and handed to the child as `/dev/fd/<n>`, which
                // resolves to this exact vnode and never to a name.
                searchFD = finalFD
                searchTarget = "/dev/fd/\(inheritedChildDescriptor)"
                fileDisplayPath = searchPath.path
            default:
                // A fifo, socket or device is not a search target, and opening
                // one by name for an engine is exactly the swap this fence is
                // about. Refuse rather than guess.
                _ = Darwin.close(finalFD)
                return errResult(
                    "Only a directory or a regular file can be searched.",
                    code: "path_not_allowed"
                )
            }
        } catch let failure as VerifiedPath.Failure {
            return errResult(failure.message, code: "path_not_allowed")
        } catch {
            return errResult(
                "The authorized path could not be verified before the search.",
                code: "path_not_allowed"
            )
        }
        #endif

        let rgPath = which("rg")
        let launch: String
        let args: [String]
        // Patterns are regex data, never CLI options (e.g. searching --help
        // must not execute the engine's help command and report it as matches).
        // The sensitive-path filter parses NUL-delimited filenames.
        // `--no-config` stops an inherited RIPGREP_CONFIG_PATH from rewriting
        // it (or the search), and `--with-filename` / `-H` keep the filename on
        // every line even when the search path is a single file.
        if let rg = rgPath {
            launch = rg
            args = [
                "--no-config", "--null", "--with-filename", "--no-heading", "--line-number",
                "-m", String(maxResults), "-e", pattern, "--", searchTarget,
            ]
        } else if let grepBin = which("grep") {
            launch = grepBin
            args = ["-rHnE", "--null", "--include=*", "-m", String(maxResults), "-e", pattern, "--", searchTarget]
        } else {
            // Missing engines retain a generic error without error_code.
            return errResult("grep not found")
        }

        // -m limits each file, not the complete recursive output. Keep pipe
        // capture bounded as well as the agent-facing presentation.
        let captureLimit = 1_048_576
        #if canImport(Darwin)
        let run = runProcess(
            launch, args, cwdDescriptor: cwdFD,
            inheritDescriptor: searchFD >= 0
                ? (source: searchFD, target: inheritedChildDescriptor) : nil,
            timeout: 30, captureByteLimit: captureLimit
        )
        #else
        let run = runProcess(launch, args, timeout: 30, captureByteLimit: captureLimit)
        #endif
        if run.timedOut { return errResult("grep timed out after 30s", code: "bash_timeout") }
        if !run.launched { return errResult("could not run grep") }
        // Only 0 (matches) and 1 (no matches) establish a completed search.
        // A killed/aborted engine may leave partial stdout, not valid coverage.
        if run.captureReadFailed {
            return errResult("Could not read the search engine output; search coverage is unknown.", code: "grep_error")
        }
        if run.status != 0 && run.status != 1 {
            let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return errResult(stderr.isEmpty ? "grep exited with status \(run.status)" : stderr, code: "grep_error")
        }
        // Filenames may contain newlines and colons. Judge the complete NUL-
        // delimited filename before formatting any match for the transcript.
        let admitted = grepMatchRecords(run.stdout).compactMap { record -> String? in
            let path: String
            if let display = fileDisplayPath {
                guard record.path == searchTarget else { return nil }
                path = display
            } else if let directory = spawnDirectory, !record.path.hasPrefix("/") {
                let relative = record.path.hasPrefix("./") ? String(record.path.dropFirst(2)) : record.path
                path = directory.path + "/" + relative
            } else {
                path = record.path
            }
            guard path.hasPrefix("/"), !isSensitiveDataPath(URL(fileURLWithPath: path), ctx) else { return nil }
            return path + ":" + record.match
        }
        // Negative limits have already failed in the engine.
        let lines = Array(admitted.prefix(sliceCount))
        let selectedText = lines.joined(separator: "\n")
        let outputClipped = selectedText.count > connectorResultMaxChars
        let output = outputClipped
            ? String(selectedText.prefix(connectorResultMaxChars)) + "\n[match output truncated]"
            : selectedText
        // -m is a per-file engine ceiling; the presentation limit is global.
        // Reaching it cannot establish the total, even when no extra admitted
        // line was observed. Counts never include filtered sensitive paths.
        let limitReached = sliceCount == 0 || admitted.count >= sliceCount
        let omittedObserved = max(0, admitted.count - lines.count)
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "pattern": .string(pattern),
            "status": .string("ok"),
            "path": .string(searchPath.path),
            "matches": .int(Int64(lines.count)),
            "output": .string(output),
            "coverage": .object([
                "complete": .bool(!limitReached && !outputClipped && !run.stdoutTruncated),
                "scope": .string("Text matches admitted by the existing path policy and search engine ignore/binary rules; not every file on disk."),
                "matches_are_total": .bool(!limitReached && !outputClipped && !run.stdoutTruncated),
                "observed_matches_lower_bound": .int(Int64(admitted.count)),
                "omitted_observed_matches": .int(Int64(omittedObserved)),
                "match_limit_reached": .bool(limitReached),
                "output_truncated": .bool(outputClipped),
                "output_character_limit": .int(Int64(connectorResultMaxChars)),
                "capture_truncated": .bool(run.stdoutTruncated),
                "capture_byte_limit": .int(Int64(captureLimit)),
            ]),
        ]
        if limitReached || outputClipped || run.stdoutTruncated {
            result["coverage_note"] = .string("Matches is the selected line count, not the total number of occurrences. More evidence may be omitted; narrow path/pattern or raise max_results up to 50. Read an identified file with file_excerpt for surrounding lines. Do not infer absence from this limited result.")
        }
        return .object(result)
    }

    /// Both engines emit `filename NUL line:text LF`. Only complete records
    /// count; a capture cut anywhere in a filename or match is discarded.
    static func grepMatchRecords(_ output: String) -> [(path: String, match: String)] {
        var remaining = output.utf8[...]
        var records: [(path: String, match: String)] = []
        while let separator = remaining.firstIndex(of: 0) {
            let path = String(decoding: remaining[..<separator], as: UTF8.self)
            let body = remaining[remaining.index(after: separator)...]
            guard let end = body.firstIndex(of: 10) else { break }
            var match = body[..<end]
            if match.last == 13 { match = match.dropLast() }
            guard !path.isEmpty, let colon = match.firstIndex(of: 58),
                  colon != match.startIndex,
                  match[..<colon].allSatisfy({ (48...57).contains($0) }) else { break }
            records.append((path, String(decoding: match, as: UTF8.self)))
            remaining = body[body.index(after: end)...]
        }
        return records
    }

    // MARK: - git_status
    //
    // Parsed branch and changed files from a confined repository read.
    package static func gitStatus(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, timeout: TimeInterval = 15, captureByteLimit: Int? = nil) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "git_status") else {
            return gitCwdBlocked(input, ctx, tool: "git_status")
        }
        let run = runGit(["status", "--short", "--branch"], cwd: cwd, timeout: timeout, label: "git status", context: ctx, captureByteLimit: captureByteLimit)
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git status failed", code: "git_unavailable") }

        var fields = gitStatusFields(result.stdout)
        fields["cwd"] = .string(cwd.path)
        return .object(fields)
    }

    private static func gitStatusFields(_ output: String) -> [String: JSONValue] {
        var staged: [JSONValue] = []
        var unstaged: [JSONValue] = []
        var untracked: [JSONValue] = []
        var branch = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        for (idx, line) in splitLines(output).enumerated() {
            if idx == 0 && line.hasPrefix("## ") {
                let header = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if header.contains("[ahead ") {
                    ahead = parseTrailingInt(header, after: "[ahead ") ?? 0
                }
                if header.contains("behind ") {
                    behind = parseTrailingInt(header, after: "behind ") ?? 0
                }
                let tracking = header.components(separatedBy: "...")
                branch = tracking[0].components(separatedBy: " [")[0]
                if tracking.count > 1 { upstream = tracking[1].components(separatedBy: " [")[0] }
                continue
            }
            let chars = Array(line)
            if chars.count < 2 { continue }
            let x = chars[0]
            let y = chars[1]
            let fname = chars.count > 3 ? String(chars[3...]) : ""
            if x == "?" && y == "?" {
                untracked.append(.string(fname))
            } else {
                if x != " " && x != "?" { staged.append(.string(fname)) }
                if y != " " && y != "?" { unstaged.append(.string(fname)) }
            }
        }
        let clean = staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
        return [
            "ok": .bool(true),
            "branch": .string(branch),
            "upstream": upstream.map(JSONValue.string) ?? .null,
            "status": .string("ok"),
            "ahead": .int(Int64(ahead)),
            "behind": .int(Int64(behind)),
            "clean": .bool(clean),
            "staged": .array(staged),
            "unstaged": .array(unstaged),
            "untracked": .array(untracked),
        ]
    }

    // MARK: - git_diff
    //
    // Working-tree, staged or dated diffs accept exit 0/1 and retain full scalar count.

    static func gitDiff(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "git_diff") else {
            return gitCwdBlocked(input, ctx, tool: "git_diff")
        }
        let staged: Bool = {
            if case .bool(let b)? = input["staged"] { return b }
            return false
        }()
        let pathFilter = input["path"]?.stringValue ?? ""
        // Per-command exec fences complement runGit's global config overrides.
        let since = gitSince(input)
        if !since.isEmpty && staged { return errResult("since reads committed changes; omit staged", code: "bad_input") }
        var args = since.isEmpty ? ["diff"] : ["log", "--since-as-filter=\(since)", "--format=commit %h %s", "--patch"]
        args += ["--no-ext-diff", "--no-textconv"]
        if staged { args.append("--staged") }
        if !pathFilter.isEmpty { args.append(contentsOf: ["--", pathFilter]) }

        let run = runGit(args, cwd: cwd, timeout: 30, label: "git diff", context: ctx, okStatuses: [0, 1])
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git diff failed", code: "git_unavailable") }
        return .object([
            "ok": .bool(true),
            "staged": .bool(staged),
            "since": since.isEmpty ? .null : .string(since),
            "status": .string("ok"),
            "diff": .string(truncate(result.stdout)),
            "cwd": .string(cwd.path),
            // The bytes field counts Unicode scalars, not grapheme clusters.
            "bytes": .int(Int64(result.stdout.unicodeScalars.count)),
        ])
    }

    // MARK: - git_log
    //
    // Recent commits: absent, invalid or zero limit means ten, capped at 100.
    static func gitLog(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "git_log") else {
            return gitCwdBlocked(input, ctx, tool: "git_log")
        }
        let parsed = safeInt(input["limit"], default: 10)
        let limit = max(1, min((parsed == nil || parsed == 0) ? 10 : parsed!, 100))
        let since = gitSince(input)
        var args = ["log", "--format=%x1e%h|%an|%ai|%s", "--name-only"]
        args.append(since.isEmpty ? "-n\(limit + 1)" : "--since-as-filter=\(since)")
        let pathFilter = input["path"]?.stringValue ?? ""
        if !pathFilter.isEmpty { args += ["--", pathFilter] }

        let run = runGit(args, cwd: cwd, timeout: 15, label: "git log", context: ctx)
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git log failed", code: "git_unavailable") }

        var commits: [JSONValue] = []
        var files: Set<String> = []
        let records = result.stdout.components(separatedBy: "\u{1e}").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for record in records.prefix(since.isEmpty ? limit : records.count) {
            let lines = splitLines(record)
            guard let line = lines.first else { continue }
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            let changed = lines.dropFirst().filter { !$0.isEmpty }
            files.formUnion(changed)
            if commits.count >= limit { continue }
            commits.append(.object([
                "hash": .string(parts.count > 0 ? parts[0] : ""),
                "author": .string(parts.count > 1 ? parts[1] : ""),
                "date": .string(parts.count > 2 ? parts[2] : ""),
                "subject": .string(parts.count > 3 ? parts[3] : ""),
                "files": .array(changed.map(JSONValue.string)),
            ]))
        }
        return .object([
            "ok": .bool(true),
            "commits": .array(commits),
            "cwd": .string(cwd.path),
            "status": .string("ok"),
            "count": .int(Int64(commits.count)),
            "since": since.isEmpty ? .null : .string(since),
            "files": .array(files.sorted().map(JSONValue.string)),
            "has_more": .bool(records.count > limit),
            "coverage": .string(since.isEmpty
                ? "Files across returned commits only; has_more means older commit details and files were omitted. Git quotes unusual filenames."
                : "Files across every matching commit in the period; has_more means older commit details were omitted, not their files. Git quotes unusual filenames."),
        ])
    }

    static func gitSince(_ input: [String: JSONValue]) -> String {
        let since = (input["since"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return since.lowercased() == "today"
            ? ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date())) : since
    }

    // MARK: - repo_dirty_summary
    //
    // Parsed status plus a short log; a nonzero log exit leaves the commit list empty.

    static func repoDirtySummary(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "repo_dirty_summary") else {
            return gitCwdBlocked(input, ctx, tool: "repo_dirty_summary")
        }
        let parsed = safeInt(input["log_limit"], default: 5)
        let logLimit = min((parsed == nil || parsed == 0) ? 5 : parsed!, 20)

        // Status failure aborts; process-level log failures also abort the summary.
        let statusRun = runGit(["status", "--short", "--branch"], cwd: cwd, timeout: 15,
                               label: "git status", context: ctx)
        switch statusRun {
        case .failure(let f): return f
        case .success(let status):
            let logRun = runGit(["log", "-n\(logLimit)", "--format=%h|%s"], cwd: cwd, timeout: 15,
                                label: "git log", context: ctx)
            if case .failure(let lf) = logRun, isProcessLevelFailure(logRun) { return lf }

            var commits: [JSONValue] = []
            if case .success(let log) = logRun {
                for line in splitLines(log.stdout) {
                    let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    commits.append(.object([
                        "hash": .string(parts.count > 0 ? parts[0] : ""),
                        "subject": .string(parts.count > 1 ? parts[1] : ""),
                    ]))
                }
            }
            var fields = gitStatusFields(status.stdout)
            fields["commits"] = .array(commits)
            fields["cwd"] = .string(cwd.path)
            return .object(fields)
        }
    }

    // MARK: - Git reads

    /// Complete confined output or the named failure that prevented it.
    package enum GitRun: Sendable {
        case success(GitResult)
        case failure(JSONValue)
    }
    package struct GitResult: Sendable { package let stdout: String; let status: Int32 }

    /// Resolve cwd (or repo_root) against allowed roots; nil means gitCwdBlocked.
    static func gitResolveCwd(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, tool: String) -> URL? {
        let rawCwd = input["cwd"]?.stringValue ?? ""
        let base = rawCwd.isEmpty ? "." : rawCwd
        let cwd = resolvePath(base, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(cwd, allowed) { return nil }
        return cwd
    }

    static func gitCwdBlocked(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, tool: String) -> JSONValue {
        let rawCwd = input["cwd"]?.stringValue ?? ""
        let base = rawCwd.isEmpty ? "." : rawCwd
        let cwd = resolvePath(base, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        return errResult(
            "\(tool) cwd '\(cwd.path)' is outside allowed sandbox roots: \(rootsRepr(allowed))",
            code: "path_not_allowed"
        )
    }

    /// Read Git in a verified directory; incomplete output and process failures
    /// remain unavailable, with stderr retained for an unsuccessful exit.
    /// GIT_OPTIONAL_LOCKS=0 prevents index stat-cache writes, keeping concurrent reads read-only.
    static let gitReadOnlyEnvironmentOverrides: [String: String] = [
        "GIT_OPTIONAL_LOCKS": "0",
        // Pin command-bearing environment/config and confine all children to read authority.
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        // Git helpers resolve only through the system PATH.
        "PATH": gitSanitizedSearchPath,
    ]

    /// The ONLY PATH a read-tier git child sees, and the only directories
    /// `gitExecutablePath` will resolve the binary from.
    static let gitSanitizedSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolve Git from a fixed path or the developer toolchain, never inherited PATH.
    static func gitExecutablePath() -> String? {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return nil }
        // Give xcrun PATH alone and admit only developer-tools locations.
        let run = runProcess(
            xcrun, ["--find", "git"], timeout: 10,
            environment: ["PATH": gitSanitizedSearchPath]
        )
        guard run.launched, !run.timedOut, run.status == 0 else { return nil }
        let found = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDeveloperToolchainPath(found),
              FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return found
    }

    /// The only locations a toolchain binary may be taken from: Xcode's own
    /// bundle in /Applications, or the developer-tools tree (which is where
    /// the Command Line Tools install and every `xcode-select` root live).
    /// Both are root-owned; anywhere else is a path a user or an inherited
    /// environment could have arranged.
    static func isDeveloperToolchainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.hasPrefix("/Library/Developer/") { return true }
        let parts = standardized.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2, parts[0] == "Applications" else { return false }
        let bundle = String(parts[1])
        return bundle.hasPrefix("Xcode") && bundle.hasSuffix(".app")
    }

    /// Environment variables that name a command for git to execute. Removed
    /// outright (an empty value is not always the same as unset).
    static let gitReadOnlyEnvironmentRemovals: [String] = [
        "GIT_EXTERNAL_DIFF",
        "GIT_PAGER",
        "GIT_SSH",
        "GIT_SSH_COMMAND",
        "GIT_ASKPASS",
        "SSH_ASKPASS",
        "GIT_EDITOR",
        "GIT_SEQUENCE_EDITOR",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
    ]

    /// Global `-c` overrides prepended to every read-tier git invocation. The
    /// exec-capable knobs a repository's own `.git/config` / `.gitattributes`
    /// can set: an external diff driver, a textconv filter, an fsmonitor hook
    /// (`git status` runs it), the hooks directory, and the pager.
    static let gitReadOnlyConfigOverrideArgs: [String] = [
        "--no-pager",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.pager=cat",
        "-c", "core.sshCommand=",
        "-c", "diff.external=",
        "-c", "protocol.ext.allow=never",
    ]

    /// The inherited environment with the read-only overrides applied. Built by
    /// merging (not replacing) because `Process.environment` is wholesale.
    static var gitReadOnlyEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
            .merging(gitReadOnlyEnvironmentOverrides) { _, override in override }
        for key in gitReadOnlyEnvironmentRemovals { env.removeValue(forKey: key) }
        return env
    }

    /// Conversion filters and submodule children inherit the caller's read
    /// authority. Confinement applies at execution, including config changes.
    static func gitReadOnlySandboxProfile(_ ctx: ConnectorActionContext) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Use explicit alternatives: Seatbelt regexes must match the same
        // case-folded sensitive paths as isSensitiveDataPath.
        func foldedPattern(_ path: String) -> String {
            path.map { character in
                let value = String(character)
                let forms = Set([value, value.lowercased(), value.uppercased()]).sorted()
                    .map { NSRegularExpression.escapedPattern(for: $0) }
                return forms.count == 1 ? forms[0] : "(" + forms.joined(separator: "|") + ")"
            }.joined()
        }
        var rules = [
            "(version 1)", "(allow default)",
            "(deny file-write*)", "(allow file-write* (literal \"/dev/null\"))",
            "(deny network*)", "(deny appleevent-send)", "(deny mach-lookup)",
            // Seatbelt names this operation `signal`, not `process-signal`.
            "(deny signal)",
        ]
        let roots = allowedRoots(ctx)
        if !roots.isEmpty {
            let runtimeRoots = ["/System/Library", "/usr/lib", "/usr/libexec", "/usr/bin", "/bin", "/sbin", "/Library/Developer", "/Applications/Xcode.app/Contents/Developer"]
            let reads = (runtimeRoots + roots.map(\.path))
                .map { "(subpath \(quoted($0)))" }.joined(separator: " ")
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
            rules += [
                "(deny file-read-data)",
                "(allow file-read-data \(reads) (literal \"/dev/null\") (literal \"/dev/random\") (literal \"/dev/urandom\") (literal \(quoted(home + "/.gitconfig"))) (literal \(quoted(home + "/.config/git/config"))))",
            ]
        }
        let dataRoot = NativeAgentWorkspaceRoot.canonicalFileURL(ctx.dataRoot ?? PersistenceCore.defaultDataRoot())
        // A local backup's payload is fenced as the data root it copies.
        let dataPattern = foldedPattern(dataRoot.path) + "(/" + foldedPattern("backups") + "/[^/]+/" + foldedPattern("data") + ")?"
        for path in connectorSensitiveDataSubpaths.sorted() + [
            "jev/credential.json", "agents/peers.json", "agents/peer-claims",
            "workflows/approvals", "memory/vault", "nextgen/remote", "mcp/servers.json",
        ] {
            rules.append("(deny file-read-data (regex \(quoted("^" + dataPattern + "/" + foldedPattern(path) + "(/|$)"))))")
        }
        for suffix in [
            "/[^/]+" + foldedPattern(".bin") + "$",
            "/" + foldedPattern("connectors") + "/(.*/)?("
                + ["auth.json", "credential.json", "credentials.json"].map(foldedPattern).joined(separator: "|") + ")(/|$)",
            "/" + foldedPattern("tools/.manifest_signing_key") + "[^/]*(/|$)",
            "/" + foldedPattern("catalog/.pack_signing_key") + "[^/]*(/|$)",
        ] {
            rules.append("(deny file-read-data (regex \(quoted("^" + dataPattern + suffix))))")
        }
        return rules.joined(separator: "\n")
    }

    package static func runGit(
        _ args: [String],
        cwd: URL,
        timeout: TimeInterval,
        label: String,
        context: ConnectorActionContext,
        okStatuses: [Int32] = [0],
        captureByteLimit: Int? = nil
    ) -> GitRun {
        guard let git = gitExecutablePath() else {
            return .failure(errResult("git not found", code: "git_unavailable"))
        }
        let directoryFD: Int32
        do { directoryFD = try VerifiedPath.open(cwd, flags: O_RDONLY | O_DIRECTORY) }
        catch {
            return .failure(errResult("The authorized Git directory could not be verified.", code: "path_not_allowed"))
        }
        defer { _ = Darwin.close(directoryFD) }
        let sandbox = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandbox) else {
            return .failure(errResult("Git read-only protection is unavailable.", code: "git_unavailable"))
        }
        let run = runProcess(sandbox, ["-p", gitReadOnlySandboxProfile(context), git] + gitReadOnlyConfigOverrideArgs + args,
                             cwdDescriptor: directoryFD, timeout: timeout,
                             environment: gitReadOnlyEnvironment, captureByteLimit: captureByteLimit)
        if run.timedOut {
            return .failure(errResult("\(label) timed out", code: "git_unavailable"))
        }
        if !run.launched {
            return .failure(errResult("Git could not be started with read-only access.", code: "git_unavailable"))
        }
        if run.stdoutTruncated || run.stderrTruncated || run.captureReadFailed {
            return .failure(errResult("\(label) output is incomplete", code: "git_unavailable"))
        }
        if !okStatuses.contains(run.status) {
            let err = (run.stderr.isEmpty ? run.stdout : run.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = err.isEmpty ? "\(label) exited \(run.status)" : err
            return .failure(errResult(msg, code: "git_unavailable"))
        }
        return .success(GitResult(stdout: run.stdout, status: run.status))
    }

    /// Missing, timed-out or incomplete reads abort the repository summary.
    static func isProcessLevelFailure(_ run: GitRun) -> Bool {
        guard case .failure(let v) = run, case .object(let o) = v else { return false }
        // Launch/protection failures and timeouts abort the whole summary.
        if case .string(let msg)? = o["error"] {
            return msg == "git not found" || msg.hasSuffix("timed out") || msg.hasSuffix("output is incomplete")
                || msg == "Git read-only protection is unavailable."
                || msg == "Git could not be started with read-only access."
        }
        return false
    }
}

/// Universal newlines, without a trailing empty element for the final newline.
private func splitLines(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines: [String] = []
    var current = ""
    var previousWasCR = false
    // Scalar boundaries recognize CRLF and every universal line separator.
    for scalar in text.unicodeScalars {
        if previousWasCR && scalar.value == 0x0A {
            previousWasCR = false
            continue
        }
        previousWasCR = scalar.value == 0x0D
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
            lines.append(current)
            current = ""
        default:
            current.unicodeScalars.append(scalar)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// Parse the leading integer that appears immediately after `marker` in `s`.
func parseTrailingInt(_ s: String, after marker: String) -> Int? {
    guard let r = s.range(of: marker) else { return nil }
    let rest = s[r.upperBound...]
    // Take up to the first ']' or ','.
    var digits = ""
    for ch in rest {
        if ch == "]" || ch == "," { break }
        digits.append(ch)
    }
    return Int(digits.trimmingCharacters(in: .whitespaces))
}
