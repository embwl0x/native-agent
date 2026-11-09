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
// Blueprint: | `RepositoryReadActions.swift` | `FileSystemActions`: confined grep/Git; `FileReadSourceMaterial.shellReadLaunch` shares Git policy |

let connectorGrepMaxResults = 50

extension FileReadSourceMaterial {
    /// Shell reads share Git's read-only process, configuration and sensitive-store authority.
    package static func shellReadLaunch(words: [String], cwd: String, dataRoot: URL, turn: Turn?) -> (arguments: [String], environment: [String: String]) {
        let ctx = ConnectorActionContext(repoRoot: URL(fileURLWithPath: cwd),
            fileAccess: ["mode": .string("full"), "sandbox": .string("danger-full-access")], dataRoot: dataRoot, turn: turn)
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

    static func grep(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let pattern = (input["pattern"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return errResult("pattern is required", code: "bad_input") }
        let rawMr = input["max_results"]
        guard let parsedMr = safeInt(rawMr, default: connectorGrepMaxResults) else {
            return errResult("max_results must be an integer, got \(jsonRepr(rawMr))", code: "bad_input")
        }
        let maxResults = min(parsedMr, connectorGrepMaxResults)
        let sliceCount = max(0, maxResults)

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

        var searchTarget = searchPath.path
        var spawnDirectory: URL? = nil
        var fileDisplayPath: String? = nil
        #if canImport(Darwin)
        let inheritedChildDescriptor: Int32 = 3
        var cwdFD: Int32 = -1
        var searchFD: Int32 = -1
        defer {
            if cwdFD >= 0 { _ = Darwin.close(cwdFD) }
            if searchFD >= 0 { _ = Darwin.close(searchFD) }
        }
        do {
            let parent = try VerifiedPath.openParent(of: searchPath)
            // Defer already owns the descriptor, including when openFinal throws.
            cwdFD = parent.fd
            // The final component also needs O_NOFOLLOW so every authorized path component resists a swap.
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
                // Transfer the verified directory to the deferred owner before any later throw.
                _ = Darwin.close(cwdFD)
                cwdFD = finalFD
                searchTarget = "."
                spawnDirectory = searchPath
            case mode_t(S_IFREG):
                // Pass the held vnode through /dev/fd so the child cannot resolve a different pathname.
                searchFD = finalFD
                searchTarget = "/dev/fd/\(inheritedChildDescriptor)"
                fileDisplayPath = searchPath.path
            default:
                // Refuse FIFOs, sockets and devices rather than reopening a name that could block or be swapped.
                _ = Darwin.close(finalFD)
                return errResult(
                    "Only a directory or a regular file can be searched.",
                    code: "path_not_allowed"
                )
            }
        } catch let failure as VerifiedPath.Failure {
            return errResult(failure.message, code: failure.code, path: searchPath)
        } catch {
            return errResult(
                "The authorized path could not be verified before the search.",
                code: "path_not_allowed"
            )
        }
        #endif

        let launch = "/usr/bin/grep"
        guard FileManager.default.isExecutableFile(atPath: launch) else {
            return errResult(
                "The macOS search tool /usr/bin/grep is unavailable. Repair the macOS installation before searching files.", code: "grep_unavailable")
        }
        // Treat patterns as data, never options; NUL framing protects sensitive-path checks for arbitrary filenames. macOS grep -p refuses symlink traversal;
        // -I and --devices=skip avoid binary files and devices. Pin the environment to remove GREP_OPTIONS and match bytes so one invalid UTF-8 line cannot
        // hide valid siblings. Read a verified /dev/fd file directly: recursive -p would refuse that descriptor symlink.
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

        // -m bounds each file, not recursive output; also bound pipe capture and presentation.
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
        // Filenames can contain newlines and colons; judge the entire NUL-delimited path before exposing matches or gaps.
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
            let line = String(decoding: record.body[..<colon], as: UTF8.self) // ASCII validation makes strict text conversion safe.
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
        // BSD diagnostics use grep: path: reason in the fixed C locale; split at the last colon-space. Preserve embedded filename LFs; name undecodable or cut
        // diagnostics by byte offset without inventing a path.
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
                 "message": .string("""
                     Search reached its \(Int(searchDeadline))-second deadline; these are only the matches captured before it stopped. Narrow the \
                     path or pattern; no matches does not establish absence.
                     """)])
        }
        // Exit 0 proves matches; exit 1 without stderr proves none; exit 2 retains matches and item-scoped gaps. Judge raw stdout first so decoding or
        // filtering cannot turn unavailable matches into whole-search failure.
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
        let lines = Array(admitted.prefix(sliceCount))
        let selectedText = lines.joined(separator: "\n")
        let outputClipped = selectedText.count > connectorResultMaxChars
        let output = outputClipped
            ? String(selectedText.prefix(connectorResultMaxChars)) + "\n[match output truncated]"
            : selectedText
        // -m is per-file and presentation is global; hitting either bound cannot establish the total. Counts exclude filtered sensitive paths.
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
                "scope": .string("""
                    Byte-based POSIX extended-regex matches from macOS grep, admitted by the path policy. Recursive searches skip .git, .build, \
                    DerivedData*, node_modules and supported repository-root .gitignore basename globs. Anchored/path-specific, escaped and \
                    nested ignore rules are not applied; hidden files otherwise remain searchable. Binary files, devices and recursive symlinks \
                    are skipped. Explicit files are searched regardless of ignore rules.
                    """),
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
            result["coverage_note"] = .string("""
                Matches is the selected line count, not the total number of occurrences. More evidence may be omitted; narrow path/pattern \
                or raise max_results up to 50. Read an identified file with file_excerpt for surrounding lines. Do not infer absence from \
                this limited result.
                """)
        }
        return .object(result)
    }

    /// Read Git rules once; grep supports unordered basename globs, not Git's ordered path language. Negations that may re-include a basename must prevent its
    /// exclusion.
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
            return .failure(
                FileReadFailure(message: "Could not read repository ignore rules at \(url.path): \(error.localizedDescription)",
                code: "grep_ignore_unavailable"))
        case .present(let bytes): data = bytes
        }
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            return .failure(
                FileReadFailure(message: "Repository .gitignore exceeds 65536 bytes or is not valid UTF-8; search exclusions are unavailable.",
                code: "grep_ignore_unavailable"))
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
                // Wildcard or escaped negations cannot safely become unordered excludes; keep the earlier rule searchable.
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

    /// Frame filename NUL line:text LF before decoding so LF inside a filename cannot split it. Only a known cap or deadline permits a partial final body; a
    /// cut filename stays a gap.
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

    /// Trim only a scalar cut by a known byte cap; other invalid bytes fail strict decoding.
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
    package static func gitStatus(
        _ input: [String: JSONValue], _ ctx: ConnectorActionContext, timeout: TimeInterval = 15, captureByteLimit: Int? = nil) -> JSONValue {
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
            "bytes": .int(Int64(result.stdout.unicodeScalars.count)),
        ])
    }

    // MARK: - git_log
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
                : """
                    Files across every matching commit in the period; has_more means older commit details were omitted, not their files. Git \
                    quotes unusual filenames.
                    """),
        ])
    }

    static func gitSince(_ input: [String: JSONValue]) -> String {
        let since = (input["since"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return since.lowercased() == "today"
            ? ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date())) : since
    }

    // MARK: - repo_dirty_summary

    static func repoDirtySummary(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "repo_dirty_summary") else {
            return gitCwdBlocked(input, ctx, tool: "repo_dirty_summary")
        }
        let parsed = safeInt(input["log_limit"], default: 5)
        let logLimit = min((parsed == nil || parsed == 0) ? 5 : parsed!, 20)

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

    package enum GitRun: Sendable {
        case success(GitResult)
        case failure(JSONValue)
    }
    package struct GitResult: Sendable {
        package let stdout: String
        let status: Int32
        var historyState: String? = nil
    }

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

    /// Keep incomplete output and process failures unavailable; unsuccessful exits retain stderr. GIT_OPTIONAL_LOCKS=0 prevents index stat-cache writes during
    /// concurrent reads.
    static let gitReadOnlyEnvironmentOverrides: [String: String] = [
        "GIT_OPTIONAL_LOCKS": "0",
        // Pin command-bearing environment/config and confine all children to read authority.
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "PATH": gitSanitizedSearchPath,
    ]

    static let gitSanitizedSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func gitExecutablePath() -> String? {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
    }

    /// Unset command-bearing variables entirely; empty values can still select executable behavior.
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

    /// Override repository-controlled execution: diff/textconv drivers, fsmonitor, hooks and pager cannot run on reads.
    static let gitReadOnlyConfigOverrideArgs: [String] = [
        "--no-pager",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.pager=cat",
        "-c", "core.sshCommand=",
        "-c", "diff.external=",
        "-c", "protocol.ext.allow=never",
    ]

    /// Merge read-only overrides with the inherited environment; Process.environment replaces the whole environment.
    static var gitReadOnlyEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
            .merging(gitReadOnlyEnvironmentOverrides) { _, override in override }
        for key in gitReadOnlyEnvironmentRemovals { env.removeValue(forKey: key) }
        return env
    }

    /// Confine children at execution so conversion, submodules or concurrent config changes cannot expand read authority.
    static func gitReadOnlySandboxProfile(_ ctx: ConnectorActionContext) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Explicit Seatbelt alternatives must match the file fence's case-folded sensitive paths.
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
            // Seatbelt accepts signal; process-signal is not an operation.
            "(deny signal)",
        ]
        let roots = allowedRoots(ctx)
        if !roots.isEmpty {
            let runtimeRoots = ["/System/Library", "/usr/lib", "/usr/libexec", "/usr/bin", "/bin", "/sbin", "/Library/Developer",
                "/Applications/Xcode.app/Contents/Developer"]
            let reads = (runtimeRoots + roots.map(\.path))
                .map { "(subpath \(quoted($0)))" }.joined(separator: " ")
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
            rules += [
                "(deny file-read-data)",
                """
                    (allow file-read-data \(reads) (literal \"/dev/null\") (literal \"/dev/random\") (literal \"/dev/urandom\") (literal \
                    \(quoted(home + "/.gitconfig"))) (literal \(quoted(home + "/.config/git/config"))))
                    """,
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
            return .failure(errResult("""
                /usr/bin/git is unavailable. Install or repair Apple's Command Line Tools (xcode-select --install), then request this read \
                again.
                """, code: "git_unavailable"))
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
            // Only an explicit porcelain-v2 unborn header proves no history; failed logs and broken refs cannot.
            let head = execute(["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
                label: "git history state", accepted: [0])
            switch head {
            case .failure(let failure): return .failure(failure)
            case .success(let result):
                let headers = result.stdout.split(separator: "\n").filter { $0.hasPrefix("# branch.oid ") }
                guard headers.count == 1 else {
                    return .failure(
                        errResult("Git did not report its history state; repair the repository's HEAD before reading history.", code: "git_unavailable"))
                }
                if headers[0] == "# branch.oid (initial)" {
                    return .success(GitResult(stdout: "", status: 0, historyState: "unborn"))
                }
            }
        }
        return execute(args, label: label, accepted: okStatuses)
    }

}

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

func parseTrailingInt(_ s: String, after marker: String) -> Int? {
    guard let r = s.range(of: marker) else { return nil }
    let rest = s[r.upperBound...]
    var digits = ""
    for ch in rest {
        if ch == "]" || ch == "," { break }
        digits.append(ch)
    }
    return Int(digits.trimmingCharacters(in: .whitespaces))
}
