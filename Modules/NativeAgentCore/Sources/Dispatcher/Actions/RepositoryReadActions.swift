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
#endif
// Blueprint: | `RepositoryReadActions.swift` | `FileSystemActions` repository reads: descriptor-pinned system grep skips build/VCS and supported root ignore globs, retaining per-record gaps and deadline partials; parsed Git status, dated diff/log and dirty summary; Git policy shared with `FileReadSourceMaterial.shellReadLaunch` |

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

        let launch = "/usr/bin/grep"
        guard FileManager.default.isExecutableFile(atPath: launch) else {
            return errResult("The macOS search tool /usr/bin/grep is unavailable. Repair the macOS installation before searching files.", code: "grep_unavailable")
        }
        // Patterns are regex data, never CLI options (e.g. searching --help
        // must not execute the engine's help command and report it as matches).
        // The sensitive-path filter parses NUL-delimited filenames.
        // macOS grep is the only engine. -p refuses recursive symlink traversal;
        // -I skips binary files and --devices=skip avoids FIFOs/devices. The
        // fixed environment removes GREP_OPTIONS and makes matching byte-based,
        // so invalid UTF-8 in one text line cannot hide its valid siblings.
        // The verified single file is handed through /dev/fd, itself a symlink:
        // read it directly, rather than asking recursive -p to walk it.
        var traversal: [String] = []
        if fileDisplayPath == nil {
            traversal = ["-r", "-p"] + [".git", ".build", "DerivedData*", "node_modules"].flatMap {
                ["--exclude-dir=\($0)", "--exclude-dir=*/\($0)"]
            }
            if let repository = enclosingRepository(searchPath) {
                switch grepIgnoreArguments(at: repository) {
                case .success(let exclusions): traversal += exclusions
                case .failure(let failure): return errResult(failure.message, code: failure.code)
                }
            }
        }
        let args = traversal + [
            "-I", "-H", "-n", "-E", "--null", "--devices=skip",
            "-m", String(maxResults), "-e", pattern, "--", searchTarget,
        ]
        let environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        // -m limits each file, not the complete recursive output. Keep pipe
        // capture bounded as well as the agent-facing presentation.
        let captureLimit = 1_048_576
        let searchDeadline: TimeInterval = 30
        #if canImport(Darwin)
        let run = runProcess(
            launch, args, cwdDescriptor: cwdFD,
            inheritDescriptor: searchFD >= 0
                ? (source: searchFD, target: inheritedChildDescriptor) : nil,
            timeout: searchDeadline, environment: environment, captureByteLimit: captureLimit, captureAsBytes: true
        )
        #else
        let run = runProcess(launch, args, timeout: searchDeadline, environment: environment,
            captureByteLimit: captureLimit, captureAsBytes: true)
        #endif
        if !run.launched { return errResult("Could not start /usr/bin/grep: \(run.stderr)", code: "grep_error") }
        guard let raw = run.rawOutput else {
            return errResult("Search capture did not return its requested bytes; search coverage is unknown.", code: "grep_error")
        }
        var gaps: [JSONValue] = []
        var gapCount = 0
        func gap(_ fields: [String: JSONValue]) {
            gapCount += 1
            if gaps.count < connectorGrepMaxResults { gaps.append(.object(fields)) }
        }
        func displayPath(_ recordPath: String) -> String? {
            let path: String
            if let display = fileDisplayPath {
                guard recordPath == searchTarget else { return nil }
                path = display
            } else if let directory = spawnDirectory, !recordPath.hasPrefix("/") {
                let relative = recordPath.hasPrefix("./") ? String(recordPath.dropFirst(2)) : recordPath
                path = relative == "." ? directory.path : directory.path + "/" + relative
            } else {
                path = recordPath
            }
            guard path.hasPrefix("/"), !isSensitiveDataPath(URL(fileURLWithPath: path), ctx) else { return nil }
            return path
        }
        // Filenames may contain newlines and colons. Judge the complete NUL-
        // delimited filename before exposing either its match or its line gap.
        let admitted = grepMatchRecords(raw.stdout, capped: run.stdoutTruncated || run.timedOut).compactMap { record -> String? in
            guard let pathBytes = record.path, let recordPath = String(data: pathBytes, encoding: .utf8),
                  !recordPath.isEmpty else {
                gap(["code": .string("unreadable_match_path"),
                     "capture_byte_offset": .int(Int64(record.offset)),
                     "message": .string("Match filename is incomplete or not valid UTF-8; this record is unavailable.")])
                return nil
            }
            guard let path = displayPath(recordPath) else { return nil }
            var detail: [String: JSONValue] = ["path": .string(path), "capture_byte_offset": .int(Int64(record.offset))]
            guard let colon = record.body.firstIndex(of: 58), colon != record.body.startIndex,
                  record.body[..<colon].allSatisfy({ (48...57).contains($0) }) else {
                detail["code"] = .string("unreadable_match_record")
                detail["message"] = .string("The match's line number is unavailable; this record is omitted.")
                gap(detail)
                return nil
            }
            let line = String(decoding: record.body[..<colon], as: UTF8.self) // validated ASCII digits
            detail["line"] = .string(line)
            var text = Data(record.body[record.body.index(after: colon)...])
            let dropped = record.partial ? grepIncompleteUTF8SuffixCount(text) : 0
            if dropped > 0 { text.removeLast(dropped) }
            guard let decoded = String(data: text, encoding: .utf8) else {
                detail["code"] = .string("invalid_utf8")
                detail["message"] = .string("This matched line is not valid UTF-8; its text is unavailable.")
                gap(detail)
                return nil
            }
            if record.partial {
                detail["code"] = .string("capture_cut_line")
                detail["dropped_trailing_utf8_bytes"] = .int(Int64(dropped))
                detail["message"] = .string("Capture ended inside this line; output retains only its captured text through the last complete character.")
                gap(detail)
            }
            return path + ":" + line + ":" + decoded
        }
        // BSD warn/warnx emits `grep: path: reason` in the fixed C locale.
        // Split at the last colon-space so colons in a filename stay in its path.
        // Each warning starts with grep's prefix. Keep embedded filename LFs
        // inside that warning. Undecodable/cut diagnostics remain named by byte
        // offset rather than an invented filename or reason.
        let diagnosticBoundary = Data("\ngrep: ".utf8)
        var remainingDiagnostics = raw.stderr[...]
        var hasPathDiagnostic = false
        while !remainingDiagnostics.isEmpty {
            let offset = remainingDiagnostics.startIndex
            let end = remainingDiagnostics.range(of: diagnosticBoundary)?.lowerBound ?? remainingDiagnostics.endIndex
            var row = remainingDiagnostics[..<end]
            let cut = end == remainingDiagnostics.endIndex && run.stderrTruncated && row.last != 10
            remainingDiagnostics = end == remainingDiagnostics.endIndex
                ? remainingDiagnostics[end...] : remainingDiagnostics[remainingDiagnostics.index(after: end)...]
            if row.last == 10 { row = row.dropLast() }
            if row.isEmpty { continue }
            var detail: [String: JSONValue] = ["code": .string("search_diagnostic"),
                "capture_byte_offset": .int(Int64(offset))]
            if cut {
                detail["message"] = .string("Search diagnostic was capped; its full path and reason are unavailable.")
            } else if let diagnostic = String(data: Data(row), encoding: .utf8) {
                let body = diagnostic.hasPrefix("grep: ") ? String(diagnostic.dropFirst(6)) : diagnostic
                if diagnostic.hasPrefix("grep: "), let separator = body.range(of: ": ", options: .backwards) {
                    let recordPath = String(body[..<separator.lowerBound])
                    if recordPath.hasPrefix("./") || recordPath.hasPrefix("/") || recordPath == searchTarget {
                        hasPathDiagnostic = true
                        guard let path = displayPath(recordPath) else { continue }
                        detail["code"] = .string("unreadable_search_path")
                        detail["path"] = .string(path)
                        detail["message"] = .string(String(body[separator.upperBound...]))
                    } else {
                        detail["message"] = .string(diagnostic)
                    }
                } else {
                    detail["message"] = .string(diagnostic)
                }
            } else {
                detail["message"] = .string("Search diagnostic is not valid UTF-8; its text is unavailable.")
            }
            gap(detail)
        }
        if run.captureReadFailed {
            gap(["code": .string("search_output_read_incomplete"),
                 "message": .string("The search's output could not be read completely; matches shown may be missing some.")])
        }
        if run.stderrTruncated {
            gap(["code": .string("search_diagnostic_capture_cut"),
                 "message": .string("Search diagnostic capture was capped; further path failures may be unavailable.")])
        }
        if run.timedOut {
            gap(["code": .string("search_timed_out"),
                 "deadline_seconds": .int(Int64(searchDeadline)),
                 "message": .string("Search reached its \(Int(searchDeadline))-second deadline; these are only the matches captured before it stopped. Narrow the path or pattern; no matches does not establish absence.")])
        }
        // Grep's exit status and captured output decide the result. Exit 0
        // means matches; exit 1 without stderr means no matches. Exit 2 keeps
        // stdout matches and path-specific gaps, even with no sibling matches.
        // Judge stdout before decoding/filtering: those steps cannot turn a
        // matched but unavailable record into a whole-search failure.
        let failure: String? = run.timedOut || run.status == 0 || (run.status == 1 && raw.stderr.isEmpty)
            ? nil : "grep exited with status \(run.status); search coverage is incomplete."
        if let failure {
            if raw.stdout.isEmpty && !hasPathDiagnostic {
                let diagnostic = String(data: raw.stderr, encoding: .utf8)
                    ?? "Search diagnostic is not valid UTF-8; its text is unavailable."
                return errResult(failure + "\n" + diagnostic, code: "grep_error")
            }
            gap(["code": .string("search_incomplete"), "message": .string(failure),
                 "exit_status": .int(Int64(run.status))])
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
            "status": .string(run.timedOut || failure != nil ? "partial" : "ok"),
            "timed_out": .bool(run.timedOut),
            "deadline_seconds": .int(Int64(searchDeadline)),
            "path": .string(searchPath.path),
            "matches": .int(Int64(lines.count)),
            "output": .string(output),
            "coverage": .object([
                "complete": .bool(!limitReached && !outputClipped && !run.stdoutTruncated && gapCount == 0),
                "scope": .string("Byte-based POSIX extended-regex matches from macOS grep, admitted by the path policy. Recursive searches skip .git, .build, DerivedData*, node_modules and supported repository-root .gitignore basename globs. Anchored/path-specific, escaped and nested ignore rules are not applied; hidden files otherwise remain searchable. Binary files, devices and recursive symlinks are skipped. Explicit files are searched regardless of ignore rules."),
                "matches_are_total": .bool(!limitReached && !outputClipped && !run.stdoutTruncated && gapCount == 0),
                "observed_matches_lower_bound": .int(Int64(admitted.count)),
                "omitted_observed_matches": .int(Int64(omittedObserved)),
                "match_limit_reached": .bool(limitReached),
                "output_truncated": .bool(outputClipped),
                "output_character_limit": .int(Int64(connectorResultMaxChars)),
                "capture_truncated": .bool(run.stdoutTruncated),
                "capture_byte_limit": .int(Int64(captureLimit)),
                "gap_count": .int(Int64(gapCount)),
                "gaps_omitted": .int(Int64(gapCount - gaps.count)),
            ]),
            "gaps": .array(gaps),
        ]
        if limitReached || outputClipped || run.stdoutTruncated || gapCount > 0 {
            result["coverage_note"] = .string("Matches is the selected line count, not the total number of occurrences. More evidence may be omitted; narrow path/pattern or raise max_results up to 50. Read an identified file with file_excerpt for surrounding lines. Do not infer absence from this limited result.")
        }
        return .object(result)
    }

    /// Grep supports basename exclusion globs, not Git's ordered path language.
    /// Read the repository's rules once for this call; never cache a second truth.
    /// A negation that might re-include a basename prevents its exclusion.
    /// The work tree a search runs in: the nearest directory at or above it holding `.git`.
    private static func enclosingRepository(_ path: URL) -> URL? {
        var directory = NativeAgentWorkspaceRoot.canonicalFileURL(path)
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    private static func grepIgnoreArguments(at root: URL) -> Result<[String], FileReadFailure> {
        let url = root.appendingPathComponent(".gitignore")
        let data: Data
        switch FileBytes().readbackData(at: url, maxBytes: 65_537, fromEnd: false) {
        case .absent: return .success([])
        case .unavailable(let error):
            return .failure(FileReadFailure(message: "Could not read repository ignore rules at \(url.path): \(error.localizedDescription)", code: "grep_ignore_unavailable"))
        case .present(let bytes): data = bytes
        }
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            return .failure(FileReadFailure(message: "Repository .gitignore exceeds 65536 bytes or is not valid UTF-8; search exclusions are unavailable.", code: "grep_ignore_unavailable"))
        }
        let rules = text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var arguments: [String] = []
        for (index, rule) in rules.enumerated() {
            guard !rule.hasPrefix("!"), !rule.contains("\\"), !rule.hasSuffix(" ") else { continue }
            let directoryOnly = rule.hasSuffix("/")
            let pattern = directoryOnly ? String(rule.dropLast()) : rule
            guard !pattern.isEmpty, !pattern.contains("/"), !pattern.contains("**") else { continue }
            let mayReinclude = rules.dropFirst(index + 1).contains { later in
                guard later.hasPrefix("!") else { return false }
                let name = String(later.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                // Wildcard/escaped negations cannot be safely translated into
                // grep's unordered excludes. Keep that earlier rule searchable.
                if name.contains(where: { "*?[\\".contains($0) }) { return true }
                #if canImport(Darwin)
                return fnmatch(pattern, (name as NSString).lastPathComponent, 0) == 0
                #else
                return true
                #endif
            }
            guard !mayReinclude else { continue }
            arguments.append("--exclude-dir=\(pattern)")
            arguments.append("--exclude-dir=*/\(pattern)")
            if !directoryOnly {
                arguments.append("--exclude=\(pattern)")
                arguments.append("--exclude=*/\(pattern)")
            }
        }
        return .success(arguments)
    }

    /// macOS grep emits `filename NUL line:text LF`. Framing happens before
    /// decoding, including filenames containing LF. A known capture cap or
    /// search deadline permits a partial final body; a cut filename is a gap.
    static func grepMatchRecords(_ output: Data, capped: Bool) -> [(path: Data?, body: Data, partial: Bool, offset: Int)] {
        var remaining = output[...]
        var records: [(path: Data?, body: Data, partial: Bool, offset: Int)] = []
        while !remaining.isEmpty {
            let offset = remaining.startIndex
            guard let separator = remaining.firstIndex(of: 0) else {
                records.append((nil, Data(), false, offset))
                break
            }
            let path = Data(remaining[..<separator])
            let body = remaining[remaining.index(after: separator)...]
            guard let end = body.firstIndex(of: 10) else {
                records.append((path, capped ? Data(body) : Data(), capped, offset))
                break
            }
            var match = body[..<end]
            if match.last == 13 { match = match.dropLast() }
            records.append((path, Data(match), false, offset))
            remaining = body[body.index(after: end)...]
        }
        return records
    }

    /// Remove only an unfinished UTF-8 scalar at a known byte cap. Invalid
    /// bytes elsewhere still fail that line's strict decode; never replace them.
    static func grepIncompleteUTF8SuffixCount(_ data: Data) -> Int {
        let tail = Array(data.suffix(4))
        guard !tail.isEmpty else { return 0 }
        var start = tail.count - 1
        while start > 0 && (0x80...0xBF).contains(tail[start]) { start -= 1 }
        let lead = tail[start]
        let width: Int
        switch lead {
        case 0xC2...0xDF: width = 2
        case 0xE0...0xEF: width = 3
        case 0xF0...0xF4: width = 4
        default: return 0
        }
        let count = tail.count - start
        guard count < width, tail[(start + 1)...].allSatisfy({ (0x80...0xBF).contains($0) }) else { return 0 }
        if count > 1 {
            let second = tail[start + 1]
            if (lead == 0xE0 && second < 0xA0) || (lead == 0xED && second > 0x9F)
                || (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second > 0x8F) { return 0 }
        }
        return count
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
            "history_state": .string(result.historyState ?? "committed"),
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
    // Parsed status plus a checked short log; only an observed unborn HEAD has no history.

    static func repoDirtySummary(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "repo_dirty_summary") else {
            return gitCwdBlocked(input, ctx, tool: "repo_dirty_summary")
        }
        let parsed = safeInt(input["log_limit"], default: 5)
        let logLimit = min((parsed == nil || parsed == 0) ? 5 : parsed!, 20)

        // Every failed status or history read aborts the summary.
        let statusRun = runGit(["status", "--short", "--branch"], cwd: cwd, timeout: 15,
                               label: "git status", context: ctx)
        switch statusRun {
        case .failure(let f): return f
        case .success(let status):
            let logRun = runGit(["log", "-n\(logLimit)", "--format=%h|%s"], cwd: cwd, timeout: 15,
                                label: "git log", context: ctx)
            if case .failure(let lf) = logRun { return lf }

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
            if case .success(let log) = logRun { fields["history_state"] = .string(log.historyState ?? "committed") }
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
    package struct GitResult: Sendable {
        package let stdout: String
        let status: Int32
        var historyState: String? = nil
    }

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

    /// The ONLY PATH a read-tier git child sees for Git's own helpers.
    static let gitSanitizedSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The supported Git executable is the system's developer-tools entry point.
    static func gitExecutablePath() -> String? {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
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
            return .failure(errResult("/usr/bin/git is unavailable. Install or repair Apple's Command Line Tools (xcode-select --install), then request this read again.", code: "git_unavailable"))
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
        func execute(_ arguments: [String], label: String, accepted: [Int32]) -> GitRun {
            let run = runProcess(sandbox, ["-p", gitReadOnlySandboxProfile(context), git] + gitReadOnlyConfigOverrideArgs + arguments,
                                 cwdDescriptor: directoryFD, timeout: timeout,
                                 environment: gitReadOnlyEnvironment, captureByteLimit: captureByteLimit)
            if run.timedOut { return .failure(errResult("\(label) timed out", code: "git_unavailable")) }
            if !run.launched {
                return .failure(errResult("Git could not be started with read-only access: \(run.stderr)", code: "git_unavailable"))
            }
            if run.stdoutTruncated || run.stderrTruncated || run.captureReadFailed {
                return .failure(errResult("\(label) output is incomplete: \(run.stderr)", code: "git_unavailable"))
            }
            if !accepted.contains(run.status) {
                let err = (run.stderr.isEmpty ? run.stdout : run.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(errResult(err.isEmpty ? "\(label) exited \(run.status)" : err, code: "git_unavailable"))
            }
            return .success(GitResult(stdout: run.stdout, status: run.status))
        }
        if args.first == "log" {
            // Git's porcelain-v2 branch header explicitly names an unborn HEAD.
            // A failed log, missing output or a broken ref is never that evidence.
            let head = execute(["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
                label: "git history state", accepted: [0])
            switch head {
            case .failure(let failure): return .failure(failure)
            case .success(let result):
                let headers = result.stdout.split(separator: "\n").filter { $0.hasPrefix("# branch.oid ") }
                guard headers.count == 1 else {
                    return .failure(errResult("Git did not report its history state; repair the repository's HEAD before reading history.", code: "git_unavailable"))
                }
                if headers[0] == "# branch.oid (initial)" {
                    return .success(GitResult(stdout: "", status: 0, historyState: "unborn"))
                }
            }
        }
        return execute(args, label: label, accepted: okStatuses)
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
