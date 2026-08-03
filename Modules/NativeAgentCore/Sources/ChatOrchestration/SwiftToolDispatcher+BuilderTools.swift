import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {
    /// Conventional source checkout retained only as one validated candidate.
    /// Public installs do not need this path in order to execute ordinary work.
    static let nativeAgentRepoRoot: String =
        NSString(string: "~/Projects/NativeAgent").expandingTildeInPath

    static func builderSourceRepoRoot(dataRoot: URL) -> URL? {
        if let injected = resolveSandboxRepoRoot(dataRoot: dataRoot) {
            return injected.standardizedFileURL.resolvingSymlinksInPath()
        }
        let conventional = URL(fileURLWithPath: nativeAgentRepoRoot)
            .standardizedFileURL
        return resolveSandboxRepoRoot(
            dataRoot: conventional.appendingPathComponent("data", isDirectory: true)
        )?.resolvingSymlinksInPath()
    }

    static func builderWorkspaceRoot(dataRoot: URL) -> URL {
        NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    static func builderAllowedRoots(dataRoot: URL) -> [URL] {
        var roots = [builderWorkspaceRoot(dataRoot: dataRoot)]
        if let source = builderSourceRepoRoot(dataRoot: dataRoot),
           !roots.contains(where: { $0.path == source.path }) {
            roots.append(source)
        }
        return roots
    }

    // Resolve a caller-supplied cwd: expand `~`, standardize, resolve
    // symlinks. Returns nil if the path doesn't exist, isn't a directory,
    // or escapes both the canonical NativeAgent workspace and an optional
    // verified source checkout.
    static func builderNormalizeCwd(
        _ raw: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        allowOutsideWorkspace: Bool = false
    ) -> String? {
        let expanded = NSString(string: raw).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolved = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        for root in builderAllowedRoots(dataRoot: dataRoot) {
            let rootPath = root.path
            if resolved == rootPath || resolved.hasPrefix(rootPath + "/") {
                return resolved
            }
        }
        guard allowOutsideWorkspace else { return nil }
        // Full Mac/explicit break-glass may select an ordinary external
        // project as cwd, but changing cwd must not become a quieter bypass of
        // the same credential/authority and protected-system fences enforced
        // by native file operations.
        guard MacControlSensitivePathFence.reason(forPath: resolved) == nil,
              MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolved) == nil else {
            return nil
        }
        return resolved
    }

    static func builderSourceCheckoutRequiredEnvelope(tool: String, dataRoot: URL) -> JSONValue {
        let runId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let auditEntry: [String: Any] = [
            "toolName": tool,
            "runId": runId,
            "createdAt": now,
            "completedAt": now,
            "status": "failed_pre_spawn",
            "reason": "source_checkout_required",
            "workspace_root": builderWorkspaceRoot(dataRoot: dataRoot).path,
        ]
        let (auditURL, auditError) = builderWriteAudit(
            runId: runId,
            entry: auditEntry,
            dataRoot: dataRoot
        )
        var envelope: [String: JSONValue] = [
            "status": .string("failed"),
            "tool": .string(tool),
            "reason": .string("source_checkout_required"),
            "workspace_root": .string(builderWorkspaceRoot(dataRoot: dataRoot).path),
            "runId": .string(runId),
            "audit_path": .string(auditURL.path),
            "detail": .string(
                "This NativeAgent self-maintenance operation requires a verified source checkout. Ordinary shell, bash, git, patch, and project work remain available inside the canonical workspace."
            ),
        ]
        if let auditError { envelope["audit_error"] = .string(auditError) }
        return .object(envelope)
    }

    static func builderFullMacRequiredEnvelope(tool: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string("trust_center_full_mac_required"),
            "tool": .string(tool),
            "detail": .string(
                "Trust Center Full Mac file_ops_allowed must be active to dispatch shell-class tools. Toggle Full Mac in the Trust Center."
            ),
        ])
    }

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func builderMaskedExitCode(stdout: String, stderr: String) -> Int32? {
        let text = stdout + "\n" + stderr
        let pattern = #"^\s*=*\s*(?:EXIT|exit_code|exit code)\s*[:=]\s*(-?\d+)\s*=*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(80)
        for rawLine in lines.reversed() {
            let line = String(rawLine)
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange),
                  match.numberOfRanges >= 2,
                  let codeRange = Range(match.range(at: 1), in: line),
                  let code = Int32(line[codeRange]),
                  code != 0 else {
                continue
            }
            return code
        }
        return nil
    }

    static func builderNormalizeShellCommand(_ raw: String) -> (cmd: String, rewrites: [String]) {
        var cmd = raw
        var rewrites: [String] = []
        if cmd.contains("cat -A") {
            cmd = cmd.replacingOccurrences(of: "cat -A", with: "cat -vet")
            rewrites.append("cat -A -> cat -vet")
        }
        let timeoutPattern = #"(^|[;&|]\s*)timeout\s+\d+(?:\.\d+)?[smhd]?\s+"#
        if let regex = try? NSRegularExpression(pattern: timeoutPattern) {
            let before = cmd
            let full = NSRange(cmd.startIndex..<cmd.endIndex, in: cmd)
            cmd = regex.stringByReplacingMatches(in: cmd, range: full, withTemplate: "$1")
            if cmd != before {
                rewrites.append("removed GNU timeout wrapper; use timeout_seconds")
            }
        }
        return (cmd, rewrites)
    }

    /// Fresh macOS installs keep developer-tool shims such as `/usr/bin/git`,
    /// `python3`, and `strings` even when no Xcode/Command Line Tools payload is
    /// installed. Invoking one opens Apple's interactive installer. A tool turn
    /// must never manufacture UI or start an install handoff merely by probing
    /// host readiness.
    ///
    /// `DEVELOPER_DIR` is Apple's supported per-process override. Pointing it
    /// at a deliberately absent path makes those shims fail immediately with
    /// an ordinary `xcrun` error, while Homebrew/non-Apple binaries remain
    /// unaffected. Preserve an explicit caller override and a real selected
    /// developer directory.
    static func builderEnvironmentSuppressingDeveloperToolsPrompt(
        environment: [String: String],
        selectedDeveloperDirectory: String?
    ) -> (environment: [String: String], suppressed: Bool) {
        if let explicit = environment["DEVELOPER_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return (environment, false)
        }
        if let selected = selectedDeveloperDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return (environment, false)
        }
        var guarded = environment
        guarded["DEVELOPER_DIR"] = "/.nativeagent-no-developer-tools"
        return (guarded, true)
    }

    /// `xcode-select --print-path` is the noninteractive Apple readiness probe.
    /// It exits nonzero on a fresh install without opening the installer.
    private static func builderSelectedDeveloperDirectory(
        environment: [String: String]
    ) -> String? {
        if let explicit = environment["DEVELOPER_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--print-path"]
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let selected = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selected?.isEmpty == false ? selected : nil
    }

    /// Is `xcodebuild` invoked anywhere in this command?
    ///
    /// Detection for a REFUSAL, not for a lift — so it is deliberately BROAD
    /// where the old lift detector was deliberately narrow. The costs are
    /// asymmetric now: a false positive costs a clear message the operator can
    /// argue with, a false negative costs the exit-74 riddle below. So this
    /// scans every token, not just segment heads, and matches on the last path
    /// component rather than a trusted-path allowlist.
    static func builderCommandInvokesXcodebuild(_ cmd: String) -> Bool {
        let separators: Set<Character> = [" ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "`", "<", ">"]
        for token in cmd.split(whereSeparator: { separators.contains($0) }) {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if (bare as NSString).lastPathComponent == "xcodebuild" { return true }
        }
        return false
    }

    /// xcodebuild cannot run inside the outer profile, and is no longer allowed
    /// to escape it. Refuse up front with the reason, rather than letting the
    /// operator decode a spawn failure.
    ///
    /// MEASURED, 2026-07-25, on NativeAgentMobile.xcodeproj under
    /// `.workspaceWrite`: every xcodebuild invocation — including a plain
    /// `-list` — dies at package-graph resolution with
    ///     `xcodebuild: error: Could not resolve package dependencies:`
    ///     `  sandbox-exec: sandbox_apply: Operation not permitted`   (exit 74)
    /// while the identical command unsandboxed completes. xcodebuild has no
    /// `--disable-sandbox` equivalent, so the SwiftPM nesting shim cannot cover
    /// it: `-disableAutomaticPackageResolution`,
    /// `-onlyUsePackageVersionsFromResolvedFile`, `-skipMacroValidation` and
    /// `-skipPackagePluginValidation` were each tried and each fails
    /// identically. xcodebuild resolves the package graph unconditionally.
    ///
    /// It used to be granted a sandbox lift for exactly that reason. That lift
    /// is retired: an `.xcodeproj` in the writable workspace can declare a Run
    /// Script build phase, so a lifted xcodebuild is an arbitrary-execution
    /// carrier wearing a build tool's name. Confined means confined; the way
    /// to run xcodebuild is to raise the posture, not to punch through it.
    static func builderXcodebuildRefusalEnvelope(tool: String, cmd: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "tool": .string(tool),
            "reason": .string("xcodebuild_requires_full_mac_posture"),
            "sandboxed": .bool(true),
            "cmd": .string(cmd),
            "error": .string(
                "xcodebuild cannot run from a sandboxed posture. It always resolves the "
                + "package graph, which spawns its own sandbox-exec, and macOS cannot nest "
                + "sandbox profiles — so it fails with 'sandbox_apply: Operation not permitted' "
                + "(exit 74) no matter which flags are passed. It is not granted an exception, "
                + "because an .xcodeproj can declare a Run Script build phase and would then "
                + "execute arbitrary shell outside the sandbox. "
                + "To run xcodebuild, switch the Trust Center to the Full Mac posture. "
                + "SwiftPM is unaffected: `swift build`, `swift test` and `swift run` all work "
                + "from here, and swift_build / swift_test / run_tests remain available."
            ),
        ])
    }

    static func builderParseArgString(_ raw: String) -> (args: [String]?, error: String?) {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for ch in raw {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if ch == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if ch == activeQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if escaping {
            current.append("\\")
        }
        if quote != nil {
            return (nil, "unclosed_quote")
        }
        if !current.isEmpty {
            args.append(current)
        }
        return (args, nil)
    }

    struct BuilderContextPatchHunk {
        var oldBlock: String
        var newBlock: String
    }

    struct BuilderContextPatchFile {
        var path: String
        var hunks: [BuilderContextPatchHunk]
    }

    static func builderPatchHeaderPath(_ line: String) -> String {
        var raw = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let tab = raw.firstIndex(of: "\t") {
            raw = String(raw[..<tab])
        }
        if raw.hasPrefix("a/") || raw.hasPrefix("b/") {
            raw = String(raw.dropFirst(2))
        }
        return raw
    }

    static func builderParseRangeLessUnifiedPatch(_ patch: String) -> (applicable: Bool, files: [BuilderContextPatchFile], error: String?) {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: [BuilderContextPatchFile] = []
        var sawRangeLessHunk = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if !line.hasPrefix("--- ") {
                index += 1
                continue
            }
            guard index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") else {
                return (true, [], "file_header_missing_plus")
            }
            let path = builderPatchHeaderPath(lines[index + 1])
            guard !path.isEmpty, path != "/dev/null" else {
                return (true, [], "context_patch_requires_existing_file")
            }
            index += 2
            var hunks: [BuilderContextPatchHunk] = []

            while index < lines.count, !lines[index].hasPrefix("--- ") {
                let header = lines[index]
                if header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    index += 1
                    continue
                }
                guard header.hasPrefix("@@") else {
                    return (true, [], "hunk_header_missing")
                }
                if header.contains("-") && header.contains("+") {
                    return (false, [], nil)
                }
                sawRangeLessHunk = true
                index += 1

                var oldLines: [String] = []
                var newLines: [String] = []
                while index < lines.count,
                      !lines[index].hasPrefix("@@"),
                      !lines[index].hasPrefix("--- ") {
                    let hunkLine = lines[index]
                    if hunkLine.hasPrefix("\\ No newline") {
                        index += 1
                        continue
                    }
                    guard let prefix = hunkLine.first else {
                        oldLines.append("")
                        newLines.append("")
                        index += 1
                        continue
                    }
                    if prefix == " " {
                        let body = String(hunkLine.dropFirst())
                        oldLines.append(body)
                        newLines.append(body)
                    } else if prefix == "-" {
                        oldLines.append(String(hunkLine.dropFirst()))
                    } else if prefix == "+" {
                        newLines.append(String(hunkLine.dropFirst()))
                    } else {
                        oldLines.append(hunkLine)
                        newLines.append(hunkLine)
                    }
                    index += 1
                }

                guard !oldLines.isEmpty else {
                    return (true, [], "context_patch_add_only_hunk_not_supported")
                }
                hunks.append(BuilderContextPatchHunk(
                    oldBlock: oldLines.joined(separator: "\n"),
                    newBlock: newLines.joined(separator: "\n")
                ))
            }

            guard !hunks.isEmpty else {
                return (true, [], "file_has_no_hunks")
            }
            files.append(BuilderContextPatchFile(path: path, hunks: hunks))
        }

        guard sawRangeLessHunk else {
            return (false, [], nil)
        }
        guard !files.isEmpty else {
            return (true, [], "no_file_patches")
        }
        return (true, files, nil)
    }

    static func builderRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    static func builderContextPatchFileURL(
        path: String,
        cwd: String,
        dataRoot: URL
    ) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let base = URL(fileURLWithPath: cwd).standardizedFileURL
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard builderAllowedRoots(dataRoot: dataRoot).contains(where: { root in
            resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
        }) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return nil
        }
        return resolved
    }

    static func builderApplyRangeLessUnifiedPatch(
        files: [BuilderContextPatchFile],
        patch: String,
        cwd: String,
        runId: String,
        startedAt: Date,
        dataRoot: URL
    ) -> JSONValue {
        var pendingWrites: [(url: URL, content: String)] = []
        var changedFiles: [String] = []

        func failure(_ reason: String, detail: String? = nil, path: String? = nil) -> JSONValue {
            var auditEntry: [String: Any] = [
                "toolName": "apply_patch",
                "runId": runId,
                "createdAt": ISO8601DateFormatter().string(from: startedAt),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "failed_pre_spawn",
                "reason": reason,
                "cwd": cwd,
                "patch_format": "range_less_unified_context",
                "sourcePayload": patch.count > 4_096 ? String(patch.prefix(4_096)) : patch,
            ]
            if let detail { auditEntry["detail"] = detail }
            if let path { auditEntry["path"] = path }
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string("apply_patch"),
                "reason": .string(reason),
                "runId": .string(runId),
                "patch_format": .string("range_less_unified_context"),
                "audit_path": .string(auditURL.path),
                "fix": .string("Retry with a normal unified diff containing @@ -old,+new hunk ranges, or make the context block unique."),
            ]
            if let detail { env["detail"] = .string(detail) }
            if let path { env["path"] = .string(path) }
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }

        for filePatch in files {
            guard let url = builderContextPatchFileURL(
                path: filePatch.path,
                cwd: cwd,
                dataRoot: dataRoot
            ) else {
                return failure("context_patch_path_invalid_or_missing", path: filePatch.path)
            }
            let original: String
            do {
                original = try String(contentsOf: url, encoding: .utf8)
            } catch {
                return failure("context_patch_read_failed", detail: String(describing: error), path: filePatch.path)
            }
            var updated = original
            for hunk in filePatch.hunks {
                let ranges = builderRanges(of: hunk.oldBlock, in: updated)
                guard ranges.count == 1, let range = ranges.first else {
                    return failure(
                        ranges.isEmpty ? "context_patch_old_block_not_found" : "context_patch_old_block_ambiguous",
                        detail: "matched \(ranges.count) locations",
                        path: filePatch.path
                    )
                }
                updated.replaceSubrange(range, with: hunk.newBlock)
            }
            if updated != original {
                pendingWrites.append((url, updated))
                changedFiles.append(filePatch.path)
            }
        }

        for write in pendingWrites {
            do {
                try write.content.write(to: write.url, atomically: true, encoding: .utf8)
            } catch {
                return failure("context_patch_write_failed", detail: String(describing: error), path: write.url.path)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let auditEntry: [String: Any] = [
            "toolName": "apply_patch",
            "runId": runId,
            "createdAt": ISO8601DateFormatter().string(from: startedAt),
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "durationMs": durationMs,
            "status": "completed",
            "exitCode": 0,
            "processExitCode": 0,
            "cwd": cwd,
            "patch_format": "range_less_unified_context",
            "changed_files": changedFiles,
            "sourcePayload": patch.count > 4_096 ? String(patch.prefix(4_096)) : patch,
            "sandboxed": false,
            "sandbox_mode": "swift_context_patch",
            "outer_sandbox_policy": "not_applicable",
        ]
        let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
        var env: [String: JSONValue] = [
            "status": .string("completed"),
            "tool": .string("apply_patch"),
            "runId": .string(runId),
            "exit_code": .int(0),
            "process_exit_code": .int(0),
            "stdout": .string(changedFiles.isEmpty ? "No file content changed." : "Applied context patch to \(changedFiles.joined(separator: ", "))"),
            "stderr": .string(""),
            "durationMs": .int(Int64(durationMs)),
            "cwd": .string(cwd),
            "patch_format": .string("range_less_unified_context"),
            "changed_files": .array(changedFiles.map { .string($0) }),
            "sandboxed": .bool(false),
            "sandbox_mode": .string("swift_context_patch"),
            "outer_sandbox_policy": .string("not_applicable"),
            "audit_path": .string(auditURL.path),
        ]
        if let auditErr { env["audit_error"] = .string(auditErr) }
        return .object(env)
    }

    /// nil-EvolutionToolBridge envelope (mirror dispatchMacIntegrationTool's
    /// bridge_not_wired handling): the app-side bridge wasn't injected
    /// (headless / restricted surface). Returned, never thrown — keep the turn
    /// intact for the LLM to explain.
    static func evolutionBridgeNotWiredEnvelope(tool: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string("bridge_not_wired"),
            "tool": .string(tool),
            "fix": .string("App-side EvolutionToolBridge not injected; this surface cannot reach the self-evolution store."),
        ])
    }

    // Write the audit receipt to disk. Returns (auditURL, optional error
    // string). Fail-soft + visible: if the write fails the caller folds
    // `audit_error` into the response envelope so failures aren't silent.
    @discardableResult
    static func builderWriteAudit(
        runId: String,
        entry: [String: Any],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> (url: URL, error: String?) {
        let auditDir = dataRoot
            .appendingPathComponent("builder_audit", isDirectory: true)
        let auditURL = auditDir.appendingPathComponent("\(runId).json")
        do {
            try FileManager.default.createDirectory(
                at: auditDir, withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: entry, options: [.prettyPrinted]
            )
            try data.write(to: auditURL)
            return (auditURL, nil)
        } catch {
            return (auditURL, String(describing: error))
        }
    }

    // U4 Wave B — Seatbelt/sandbox-exec wrapping for shell-class tools.
    //
    // Shell-class builder Processes (shell/bash/git/apply_patch/run_tests) are
    // wrapped in a macOS sandbox profile scoped to the NativeAgent workspace:
    // reads + process-exec + network stay open (git/swift build NEED network for
    // package resolution — cutting it would cut capability), but file-WRITES are
    // confined to the repo + the standard build caches. Sensitive writes (~/.ssh,
    // Keychains, and — crucially — the trust policy at <repo>/data/trust) are
    // denied even though some live inside the workspace. This is pure hardening
    // (a tightening, not a loosening), so it ships ON by default; the live
    // autonomy posture is unchanged (builder tools stay where policy puts them).
    //
    // swift_build/swift_test use this same audited runner and are CONFINED by
    // it. They used to lift the outer wrapper because SwiftPM applies its own
    // sandbox-exec while compiling Package.swift and profiles cannot nest;
    // the PATH shim now disables that inner sandbox, so the lift is retired.
    // Nothing is lifted any more: there is no caller-supplied way to request an
    // unconfined lane. xcodebuild, which cannot run confined, is refused up
    // front — see builderXcodebuildRefusalEnvelope.
    //
    // Profile validated empirically 2026-06-11: workspace write ✓, git status ✓
    // (capability preserved); ~/.ssh write 🔒, data/trust write 🔒 (security bites).
    // Escape a path for safe interpolation into an SBPL string literal. SBPL
    // string literals are C-like, so a `"` or `\` in a path would break (or
    // inject) the profile. the user's paths are clean, but escape defensively so a
    // weird HOME can never produce a malformed/permissive profile (gpt-5.5
    // Wave B review).
    static func sbplEscapeLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - SwiftPM nesting shim
    //
    // macOS refuses to nest sandbox profiles (`sandbox_apply: Operation not
    // permitted`), and SwiftPM applies its own sandbox when it compiles a
    // Package.swift manifest. So under our wrapper ANY `swift build/test/run/
    // package` fails at manifest compile — including a `swift run` buried inside
    // a shell script, which no command-shape detector can see.
    //
    // User's tiering (2026-07-25) says confinement must not mean execution
    // denial, so the answer is NOT to lift the wrapper for those commands (that
    // trades containment for capability). It is to stop SwiftPM from trying to
    // nest: a `swift` shim first on PATH that injects `--disable-sandbox` into
    // the sandbox-taking subcommands. Our OUTER profile is still the one
    // enforcing write confinement, so the posture is unchanged — this is exactly
    // the mechanism run_tests has used since Wave B, generalized from one tool
    // to every sandboxed spawn.
    //
    // Verified empirically 2026-07-25 under the real workspace profile:
    // `swift run` → "Invalid manifest" / `sandbox_apply: Operation not
    // permitted`; `swift run --disable-sandbox` → builds, links, and RUNS, while
    // an out-of-workspace write from the same shell is still denied.

    /// The `swift` wrapper installed on PATH for sandboxed spawns. Injects
    /// `--disable-sandbox` only for the subcommands that accept it, only when the
    /// caller has not already passed it, and always re-execs the real toolchain
    /// binary by absolute path (so the shim can never recurse into itself).
    static func builderSwiftPMShimScript(realSwiftPath: String) -> String {
        """
        #!/bin/sh
        # NativeAgent builder shim — generated, do not edit.
        # sandbox-exec cannot nest, so SwiftPM's own manifest sandbox must be off
        # while NativeAgent's outer profile provides the confinement.
        real='\(realSwiftPath)'
        case "$1" in
          build|test|run|package)
            sub="$1"
            shift
            for a in "$@"; do
              if [ "$a" = "--disable-sandbox" ]; then
                exec "$real" "$sub" "$@"
              fi
            done
            exec "$real" "$sub" --disable-sandbox "$@"
            ;;
        esac
        exec "$real" "$@"
        """
    }

    /// Absolute path of the real `swift` driver, resolved without consulting the
    /// shim directory. `/usr/bin/swift` is the system xcrun stub and is what an
    /// unsandboxed spawn would have hit anyway.
    static func builderRealSwiftPath() -> String? {
        let candidates = [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
            "/opt/homebrew/bin/swift",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Create (idempotently) the shim directory and return it, or nil if it could
    /// not be built. Failing to nil is fail-SAFE: the spawn keeps its sandbox and
    /// a SwiftPM command fails loudly, rather than silently running unconfined.
    static func builderSwiftPMShimDirectory() -> URL? {
        guard let realSwift = builderRealSwiftPath() else { return nil }
        let fm = FileManager.default
        // Per-user private temp (/var/folders/<hash>/T, mode 700) — not the
        // world-writable /tmp, so the shim cannot be pre-planted by another user.
        let dir = fm.temporaryDirectory
            .appendingPathComponent("nativeagent-swiftpm-shim", isDirectory: true)
        let shim = dir.appendingPathComponent("swift", isDirectory: false)
        let script = builderSwiftPMShimScript(realSwiftPath: realSwift)

        if let existing = try? String(contentsOf: shim, encoding: .utf8),
           existing == script,
           fm.isExecutableFile(atPath: shim.path) {
            return dir
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Stage under a unique name, mark executable, then atomically swap in.
            // A concurrent spawn therefore sees either the old shim or the new
            // one — never a half-written or not-yet-executable file.
            let staged = dir.appendingPathComponent("swift.staged-\(UUID().uuidString)")
            try script.write(to: staged, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            if fm.fileExists(atPath: shim.path) {
                _ = try fm.replaceItemAt(shim, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: shim)
            }
            return dir
        } catch {
            // Lost a race with a sibling writer? Accept whatever landed.
            if fm.isExecutableFile(atPath: shim.path) { return dir }
            return nil
        }
    }

    static func builderSandboxProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        let writableRoots = builderAllowedRoots(dataRoot: dataRoot)
            .map { #"          (subpath "\#(Self.sbplEscapeLiteral($0.path))")"# }
            .joined(separator: "\n")
        let home = Self.sbplEscapeLiteral(
            URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path)
        var trustPaths = [
            dataRoot.appendingPathComponent("trust", isDirectory: true)
        ]
        if let source = builderSourceRepoRoot(dataRoot: dataRoot) {
            trustPaths.append(
                source
                    .appendingPathComponent("data", isDirectory: true)
                    .appendingPathComponent("trust", isDirectory: true)
            )
        }
        var seenTrustPaths = Set<String>()
        let trustRules = trustPaths.compactMap { url -> String? in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seenTrustPaths.insert(path).inserted else { return nil }
            return #"        (deny file-write* (subpath "\#(Self.sbplEscapeLiteral(path))"))"#
        }.joined(separator: "\n")
        // allow-default then carve file-write* down to the workspace + build
        // caches; the LAST matching rule wins in SBPL, so the trailing deny on
        // the trust dir overrides the workspace allow for that subpath. NOTE:
        // this is WRITE confinement — reads, process-exec, and network stay open
        // by design (git fetch/push + SwiftPM package resolution need network;
        // denying it would cut capability). It contains workspace-escaping
        // WRITES, not secret reads; receipts say sandbox_mode=workspace_write.
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write*
        \(writableRoots)
          (subpath "/tmp")
          (subpath "/private/tmp")
          (subpath "/private/var/folders")
          (subpath "\(home)/Library/Caches")
          (subpath "\(home)/Library/Developer")
          (subpath "\(home)/.swiftpm")
          (subpath "\(home)/.cache")
          (literal "/dev/null"))
        \(trustRules)
        """
    }

    /// Developer Mode removes workspace-only confinement without removing the
    /// non-bypassable system and authority floor. The process may write across
    /// ordinary user space (Desktop, Documents, checked-out repositories, and
    /// build caches), while macOS still enforces denials for protected OS roots,
    /// credentials, and NativeAgent-owned state. The canonical workspace is
    /// allowed back after the data-root denial because public installs place it
    /// inside Application Support.
    static func builderDeveloperSandboxProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        let workspace = builderWorkspaceRoot(dataRoot: dataRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let protectedPaths = MacControlSensitivePathFence.protectedSystemMutationPrefixes
            + [
                dataRoot.standardizedFileURL.resolvingSymlinksInPath().path,
                NSHomeDirectory() + "/.ssh",
                NSHomeDirectory() + "/Library/Keychains",
            ]
        var seen = Set<String>()
        let denyRules = protectedPaths.compactMap { raw -> String? in
            let path = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return nil }
            return #"        (deny file-write* (subpath "\#(Self.sbplEscapeLiteral(path))"))"#
        }.joined(separator: "\n")
        let trustPath = dataRoot.appendingPathComponent("trust", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return """
        (version 1)
        (allow default)
        \(denyRules)
        (allow file-write* (subpath "\(Self.sbplEscapeLiteral(workspace))"))
        (deny file-write* (subpath "\(Self.sbplEscapeLiteral(trustPath))"))
        """
    }

    enum BuilderShellSandboxMode: String, Sendable {
        /// Strict / locked-down posture: workspace-confined AND the off-ramps
        /// (env break-glass, `securityPolicy.shellSandboxEnabled`) do not apply.
        case lockedDown = "locked_down"
        case workspaceWrite = "workspace_write"
        case developerFullMac = "developer_full_mac"
        case off
    }

    /// The trust modes User means by "yolo": the operator has explicitly taken
    /// the wrapper off, so the harness must not second-guess it with one.
    static let builderYoloPermissionLevels: Set<String> = [
        "full_mac_os", "wide_open_receipts",
    ]

    /// Resolve the shell-class Process confinement posture. The wrap is TIERED
    /// to the trust mode (User's directive, 2026-07-25) rather than applied
    /// uniformly:
    ///
    ///   - **strict / locked-down** → `.lockedDown`. Workspace-confined, and the
    ///     off-ramps below are ignored: a strict posture cannot be un-sandboxed
    ///     by an env var or a legacy policy flag. This is the only tier where
    ///     the heavy wrap is non-negotiable.
    ///   - **yolo** (`permissionLevel ∈ {full_mac_os, wide_open_receipts}` AND a
    ///     live Full Mac window) → `.off`. That mode IS the trust decision;
    ///     wrapping it anyway was a leftover, not a boundary. Requires BOTH the
    ///     explicit permission level and an unexpired window, so a lapsed yolo
    ///     session falls back to a real profile rather than staying open.
    ///   - **Developer Mode** → `.developerFullMac`. User space is writable, the
    ///     protected OS/credential/authority floor still bites.
    ///   - **everything else (workspace/balanced)** → `.workspaceWrite`.
    ///
    /// Confinement is not execution denial: every sandboxed tier gets the SwiftPM
    /// nesting shim in `runShellLikeProcess`, so builds/tests/`swift run` work
    /// inside the wrap instead of being blocked by it.
    ///
    /// `environment` is a parameter, not a `ProcessInfo` read at the point of
    /// use, so a test can exercise the break-glass without `setenv` — process
    /// env is global state and swift-testing runs the suite in parallel in one
    /// process, so mutating it corrupts unrelated sibling tests.
    static func builderShellSandboxMode(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> BuilderShellSandboxMode {
        let policy = await SwiftNativeTrustCenter(
            dataRoot: dataRoot,
            persistence: SwiftNativePersistenceCore()
        ).loadTrustPolicy()

        var permissionLevel = "balanced"
        if case .string(let raw)? = policy["permissionLevel"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { permissionLevel = trimmed }
        }

        // Tier 3 first: a locked-down posture outranks every off-ramp below,
        // including the env break-glass. Checked before the env var on purpose.
        if permissionLevel == "strict" || permissionLevel == "locked_down" {
            return .lockedDown
        }

        // Tier 1: yolo. Explicit permission level AND a live Full Mac window.
        if Self.builderYoloPermissionLevels.contains(permissionLevel),
           let trust = MacControlPolicy.fromTrustPolicyObject(policy).trustPolicy,
           MacControlGate.fullMacActive(trust) {
            return .off
        }

        if let v = environment["NATIVE_AGENT_SHELL_SANDBOX"],
           v == "0" || v.lowercased() == "false" {
            return .off
        }
        if case .bool(true)? = policy["developerMode"] {
            return .developerFullMac
        }
        if case .object(let sec)? = policy["securityPolicy"],
           case .bool(let enabled)? = sec["shellSandboxEnabled"] {
            return enabled ? .workspaceWrite : .off
        }
        return .workspaceWrite
    }

    /// Compatibility predicate retained for focused policy tests and callers.
    /// Developer Mode remains sandbox-wrapped, but not workspace-confined.
    /// Off-ramps fail safe to the workspace profile on malformed policy.
    ///   - break-glass env `NATIVE_AGENT_SHELL_SANDBOX=0` (relaunch to disable);
    ///   - user-facing Trust Center flag `securityPolicy.shellSandboxEnabled`.
    static func builderShellSandboxEnabled(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Bool {
        await builderShellSandboxMode(dataRoot: dataRoot, environment: environment) != .off
    }

    static func runShellLikeProcess(
        toolName: String,
        executable: String,
        args: [String],
        cwd: String,
        timeoutSeconds: Int,
        sourcePayloadForAudit: String? = nil,
        compatRewrites: [String] = [],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue {
        // The workspace is infrastructure, not a model-created side effect.
        // Launch prepares it, and this closes the race for headless/tests.
        _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)

        // Pre-allocate runId + started timestamp BEFORE any validation so a
        // pre-spawn failure still produces an audit receipt. Audit fail-open
        // is what made the original review NEEDS_FIX list.
        let runId = UUID().uuidString
        let started = Date()

        // Resolve the effective confinement posture before cwd validation.
        // Full Mac YOLO deliberately removes the workspace wrapper, so it must
        // also be able to start in a user-selected external project. Ordinary
        // modes retain the canonical workspace/source-checkout boundary.
        let sandboxMode: BuilderShellSandboxMode = await Self.builderShellSandboxMode(dataRoot: dataRoot)

        // Normalize and bound-check cwd. On failure: write a pre-spawn
        // audit envelope, then return a clean denied envelope (carry the
        // audit_error if the write itself failed so it's visible).
        guard let resolvedCwd = builderNormalizeCwd(
            cwd,
            dataRoot: dataRoot,
            allowOutsideWorkspace: sandboxMode == .off
        ) else {
            let auditEntry: [String: Any] = [
                "toolName": toolName,
                "runId": runId,
                "createdAt": ISO8601DateFormatter().string(from: started),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "failed_pre_spawn",
                "reason": "cwd_invalid_or_outside_workspace",
                "cwd_requested": cwd,
                "workspace_root": builderWorkspaceRoot(dataRoot: dataRoot).path,
                "executable": executable,
                "args": args,
                "outer_sandbox_policy": "policy",
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string(toolName),
                "reason": .string("cwd_invalid_or_outside_workspace"),
                "cwd_requested": .string(cwd),
                "workspace_root": .string(builderWorkspaceRoot(dataRoot: dataRoot).path),
                "source_checkout_available": .bool(builderSourceRepoRoot(dataRoot: dataRoot) != nil),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
                "outer_sandbox_policy": .string("policy"),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }

        let clampedTimeout = max(1, min(3600, timeoutSeconds))

        // U4 Wave B: wrap the spawn in sandbox-exec (workspace-scoped writes)
        // unless the kill switch is set or the caller is a fixed-argv escape
        // hatch such as swift_build/swift_test. sandbox-exec EXEC-replaces into
        // the target, so the pid/pgid the timeout watchdog signals is the real
        // command — the kill machinery below is unaffected.
        //
        // ALL builder tools are sandboxed, INCLUDING run_tests. Excluding it was
        // a confused-deputy hole (gpt-5.5 Wave B review): script/test.sh + the
        // whole test/source tree are workspace-WRITABLE, so a sandboxed shell/
        // apply_patch could poison a test/source file and then call an
        // unsandboxed run_tests to execute it OUT of the sandbox. Containment is
        // only as strong as its weakest tool. SwiftPM self-sandboxes its manifest
        // compile and sandbox-exec cannot nest (outer wrap → "Invalid manifest"),
        // so run_tests sets NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX=1 → script/test.sh
        // adds `--disable-sandbox` to its swift invocations; the OUTER sandbox
        // still confines every write, so the build runs AND stays contained
        // (verified empirically 2026-06-11). The same nesting limit hits a
        // sandboxed shell/bash that runs `swift build` directly — documented; use
        // swift_build/swift_test for fixed SwiftPM work, run_tests for the repo
        // suite, invoke_codex for broader build work, or the kill switch.
        let sandboxed = sandboxMode != .off
        let process = Process()
        if sandboxed {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            let profile = sandboxMode == .developerFullMac
                ? Self.builderDeveloperSandboxProfile(dataRoot: dataRoot)
                : Self.builderSandboxProfile(dataRoot: dataRoot)
            process.arguments = ["-p", profile, executable] + args
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        }

        // Environment. Two concerns, both only relevant when we DID wrap:
        //
        //  1. SwiftPM nesting shim. `sandbox_apply` refuses to nest, and SwiftPM
        //     self-sandboxes its manifest compile, so ANY `swift build/test/run/
        //     package` under our wrapper dies with "Invalid manifest" before a
        //     line of Swift executes — including indirect ones inside a shell
        //     script (e.g. script/task_ledger.sh). Confinement is not supposed to
        //     mean execution denial, so instead of lifting the wrapper we put a
        //     `swift` shim first on PATH that injects `--disable-sandbox`. The
        //     OUTER profile still confines every write (verified empirically:
        //     `swift run --disable-sandbox` builds AND runs under the workspace
        //     profile, while an out-of-workspace write is still denied).
        //  2. run_tests' NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX, which script/test.sh
        //     reads to thread `--disable-sandbox` into its own swift invocations.
        //     Set when sandboxed; STRIPPED when not (defense-in-depth, gpt-5.5
        //     review — a parent/CI shell that already exported it must not let
        //     test.sh drop SwiftPM's sandbox with no outer wrap).
        var env = ProcessInfo.processInfo.environment
        var effectiveCompatRewrites = compatRewrites
        let developerDirectory = Self.builderSelectedDeveloperDirectory(environment: env)
        let developerPromptPolicy = Self.builderEnvironmentSuppressingDeveloperToolsPrompt(
            environment: env,
            selectedDeveloperDirectory: developerDirectory
        )
        env = developerPromptPolicy.environment
        if developerPromptPolicy.suppressed {
            effectiveCompatRewrites.append(
                "suppressed interactive Apple developer-tools install prompt; install Xcode Command Line Tools manually to use Apple toolchain shims"
            )
        }
        let resolvedCompatRewrites = effectiveCompatRewrites
        if sandboxed, let shimDir = Self.builderSwiftPMShimDirectory() {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = shimDir.path + ":" + existingPath
        }
        if toolName == "run_tests" {
            if sandboxed {
                env["NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX"] = "1"
            } else {
                env.removeValue(forKey: "NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX")
            }
        }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedCwd)
        process.qualityOfService = .utility

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Bounded concurrent drain — prevents the 64KB-pipe-buffer deadlock
        // where the subprocess fills the pipe, blocks on write, and
        // terminationHandler never fires.
        let stdoutBuf = BoundedBuffer(cap: 16 * 1024 * 1024)
        let stderrBuf = BoundedBuffer(cap: 16 * 1024 * 1024)

        // FileHandle.readabilityHandler uses dispatch sources internally. The
        // builder tools can launch long SwiftPM/test subprocess trees from the
        // app, so keep pipe ownership explicit with short-lived drain threads.
        let stdoutDrain = PipeDrainLoop(
            fileDescriptor: stdout.fileHandleForReading.fileDescriptor,
            buffer: stdoutBuf
        )
        let stderrDrain = PipeDrainLoop(
            fileDescriptor: stderr.fileHandleForReading.fileDescriptor,
            buffer: stderrBuf
        )
        stdoutDrain.start()
        stderrDrain.start()

        return await withCheckedContinuation { (cont: CheckedContinuation<JSONValue, Never>) in
            let resumed = ResumeGuard()

            process.terminationHandler = { proc in
                // The direct child exiting does NOT guarantee EOF — a
                // backgrounded grandchild can inherit the write end and keep it
                // open. Stop the live drains, then grab any already-buffered
                // bytes without waiting for EOF.
                stdoutDrain.stopAndWait()
                stderrDrain.stopAndWait()
                drainPipeNonBlocking(stdout.fileHandleForReading, into: stdoutBuf)
                drainPipeNonBlocking(stderr.fileHandleForReading, into: stderrBuf)
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()

                let stdoutText = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
                let stderrText = String(data: stderrBuf.data, encoding: .utf8) ?? ""
                let pipeTruncated = stdoutBuf.truncated || stderrBuf.truncated
                let processExitCode = proc.terminationStatus
                let maskedExitCode = processExitCode == 0
                    ? builderMaskedExitCode(stdout: stdoutText, stderr: stderrText)
                    : nil
                let exitCode = maskedExitCode ?? processExitCode
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let status = exitCode == 0 ? "completed" : "failed"

                // Audit truncation: 16KB out/err, 4KB payload.
                let auditStdout = stdoutText.count > 16_384
                    ? String(stdoutText.prefix(16_384))
                    : stdoutText
                let auditStderr = stderrText.count > 16_384
                    ? String(stderrText.prefix(16_384))
                    : stderrText
                let auditPayload: String? = sourcePayloadForAudit.map {
                    $0.count > 4_096 ? String($0.prefix(4_096)) : $0
                }

                var auditEntry: [String: Any] = [
                    "toolName": toolName,
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: started),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "status": status,
                    "durationMs": durationMs,
                    "exitCode": Int(exitCode),
                    "processExitCode": Int(processExitCode),
                    "cwd": resolvedCwd,
                    "executable": executable,
                    "args": args,
                    "stdout_len": stdoutText.count,
                    "stderr_len": stderrText.count,
                    "stdout": auditStdout,
                    "stderr": auditStderr,
                    "pipe_truncated": pipeTruncated,
                    "sandboxed": sandboxed,
                    "sandbox_mode": sandboxMode.rawValue,
                    "outer_sandbox_policy": "policy",
                ]
                if let auditPayload { auditEntry["sourcePayload"] = auditPayload }
                if let maskedExitCode {
                    auditEntry["masked_exit_detected"] = true
                    auditEntry["masked_exit_code"] = Int(maskedExitCode)
                    auditEntry["reason"] = "masked_subcommand_exit"
                }
                if !resolvedCompatRewrites.isEmpty {
                    auditEntry["compat_rewrites"] = resolvedCompatRewrites
                }
                let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)

                // Envelope-side truncation cap (~32KB each). Head+tail, NOT
                // head-only: build/test errors land at the END of the stream, so
                // a bare .prefix(32K) kept the progress noise and dropped the
                // errors — blinding her on any build that outran the cap. Keep
                // 8KB head (command echo + first/root-cause error) + 24KB tail
                // (final errors + test summary + exit). Same budget, errors survive.
                let (envStdout, envStdoutTruncated) = SwiftToolDispatcher.headTailPreserve(
                    stdoutText, headBudget: 8_192, tailBudget: 24_576)
                let (envStderr, envStderrTruncated) = SwiftToolDispatcher.headTailPreserve(
                    stderrText, headBudget: 8_192, tailBudget: 24_576)

                guard resumed.tryResume() else { return }
                var envelope: [String: JSONValue] = [
                    "status": .string(status),
                    "tool": .string(toolName),
                    "runId": .string(runId),
                    "exit_code": .int(Int64(exitCode)),
                    "process_exit_code": .int(Int64(processExitCode)),
                    "stdout": .string(envStdout),
                    "stderr": .string(envStderr),
                    "durationMs": .int(Int64(durationMs)),
                    "cwd": .string(resolvedCwd),
                    "sandboxed": .bool(sandboxed),
                    "sandbox_mode": .string(sandboxMode.rawValue),
                    "outer_sandbox_policy": .string("policy"),
                    "audit_path": .string(auditURL.path),
                ]
                if let maskedExitCode {
                    envelope["reason"] = .string("masked_subcommand_exit")
                    envelope["detail"] = .string("The process exited 0, but its output reported EXIT: \(maskedExitCode). Treating the tool call as failed.")
                    envelope["masked_exit_detected"] = .bool(true)
                    envelope["masked_exit_code"] = .int(Int64(maskedExitCode))
                }
                if !resolvedCompatRewrites.isEmpty {
                    envelope["compat_rewrites"] = .array(resolvedCompatRewrites.map { .string($0) })
                }
                if envStdoutTruncated || envStderrTruncated || pipeTruncated {
                    envelope["_truncated"] = .bool(true)
                }
                if let auditErr { envelope["audit_error"] = .string(auditErr) }
                cont.resume(returning: .object(envelope))
            }

            do {
                try process.run()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
            } catch {
                stdoutDrain.stopAndWait()
                stderrDrain.stopAndWait()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
                let spawnAudit: [String: Any] = [
                    "toolName": toolName,
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: started),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "status": "failed_pre_spawn",
                    "reason": "spawn_failed",
                    "detail": String(describing: error),
                    "cwd": resolvedCwd,
                    "executable": executable,
                    "args": args,
                    "sandboxed": sandboxed,
                    "outer_sandbox_policy": "policy",
                ]
                let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: spawnAudit, dataRoot: dataRoot)
                guard resumed.tryResume() else { return }
                var env: [String: JSONValue] = [
                    "status": .string("failed"),
                    "tool": .string(toolName),
                    "reason": .string("spawn_failed"),
                    "detail": .string(String(describing: error)),
                    "runId": .string(runId),
                    "sandboxed": .bool(sandboxed),
                    "outer_sandbox_policy": .string("policy"),
                    "audit_path": .string(auditURL.path),
                ]
                if let auditErr { env["audit_error"] = .string(auditErr) }
                cont.resume(returning: .object(env))
                return
            }

            armSubprocessTimeout(process: process, timeoutSeconds: clampedTimeout)
        }
    }

    private static func builderDefaultCwd(dataRoot: URL) -> String {
        builderSourceRepoRoot(dataRoot: dataRoot)?.path
            ?? builderWorkspaceRoot(dataRoot: dataRoot).path
    }

    private static func builderResolveCwd(
        _ input: [String: JSONValue],
        dataRoot: URL
    ) -> String {
        if case .string(let raw)? = input["cwd"] {
            let cwd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                if cwd.hasPrefix("/") || cwd.hasPrefix("~") { return cwd }
                let workspace = builderWorkspaceRoot(dataRoot: dataRoot)
                let workspaceAlias = normalizeWorkspaceAlias(cwd, workspaceRoot: workspace)
                if workspaceAlias != cwd { return workspaceAlias }
                if let source = builderSourceRepoRoot(dataRoot: dataRoot) {
                    let sourceCandidate = source.appendingPathComponent(cwd).standardizedFileURL
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(
                        atPath: sourceCandidate.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue {
                        return sourceCandidate.path
                    }
                }
                return workspace.appendingPathComponent(cwd).standardizedFileURL.path
            }
        }
        return builderDefaultCwd(dataRoot: dataRoot)
    }

    private static func builderResolveTimeout(
        _ input: [String: JSONValue], defaultSeconds: Int, maxSeconds: Int
    ) -> Int {
        if case .int(let i)? = input["timeout_seconds"] {
            return max(1, min(maxSeconds, Int(i)))
        }
        return defaultSeconds
    }

    private static func builderResolveString(
        _ input: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let raw)? = input[key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func builderResolveBool(
        _ input: [String: JSONValue],
        keys: [String],
        default defaultValue: Bool
    ) -> Bool {
        for key in keys {
            if case .bool(let value)? = input[key] {
                return value
            }
        }
        return defaultValue
    }

    private static func builderResolveJobs(_ input: [String: JSONValue]) -> Int? {
        guard case .int(let raw)? = input["jobs"] else { return nil }
        return max(1, min(64, Int(raw)))
    }

    private static func swiftPMResolvedConfiguration(
        _ input: [String: JSONValue],
        tool: String
    ) -> (configuration: String?, failure: JSONValue?) {
        let raw = builderResolveString(input, keys: ["configuration", "config"]) ?? "debug"
        let normalized = raw.lowercased()
        switch normalized {
        case "debug", "release":
            return (normalized, nil)
        default:
            return (nil, .object([
                "status": .string("failed"),
                "tool": .string(tool),
                "reason": .string("invalid_configuration"),
                "configuration": .string(raw),
                "expected": .string("debug or release"),
            ]))
        }
    }

    private static func swiftPMResolvedPackagePath(
        _ input: [String: JSONValue],
        dataRoot: URL
    ) -> String {
        builderResolveString(input, keys: ["package_path", "packagePath", "cwd"])
            ?? builderDefaultCwd(dataRoot: dataRoot)
    }

    static func impl_shell(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        guard case .string(let cmd)? = input["cmd"], !cmd.isEmpty else {
            return .object([
                "status": .string("failed"),
                "tool": .string("shell"),
                "reason": .string("missing_cmd"),
            ])
        }
        let cwd = builderResolveCwd(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 120, maxSeconds: 600)
        let normalized = builderNormalizeShellCommand(cmd)
        // No command escapes the profile. xcodebuild physically cannot run
        // inside it, so it is refused with a reason instead of being lifted or
        // left to fail as exit 74 — see builderXcodebuildRefusalEnvelope.
        if builderCommandInvokesXcodebuild(normalized.cmd),
           await builderShellSandboxMode(dataRoot: dataRoot) != .off {
            return builderXcodebuildRefusalEnvelope(tool: "shell", cmd: cmd)
        }
        return await runShellLikeProcess(
            toolName: "shell",
            executable: "/bin/sh",
            args: ["-c", normalized.cmd],
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: cmd,
            compatRewrites: normalized.rewrites,
            dataRoot: dataRoot
        )
    }

    static func impl_bash(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        guard case .string(let cmd)? = input["cmd"], !cmd.isEmpty else {
            return .object([
                "status": .string("failed"),
                "tool": .string("bash"),
                "reason": .string("missing_cmd"),
            ])
        }
        let cwd = builderResolveCwd(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 120, maxSeconds: 600)
        let normalized = builderNormalizeShellCommand(cmd)
        // See impl_shell: xcodebuild is refused, everything else rides the shim.
        if builderCommandInvokesXcodebuild(normalized.cmd),
           await builderShellSandboxMode(dataRoot: dataRoot) != .off {
            return builderXcodebuildRefusalEnvelope(tool: "bash", cmd: cmd)
        }
        return await runShellLikeProcess(
            toolName: "bash",
            executable: "/bin/bash",
            args: ["-c", normalized.cmd],
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: cmd,
            compatRewrites: normalized.rewrites,
            dataRoot: dataRoot
        )
    }

    static func impl_git(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let parsedArgs: [String]
        switch input["args"] {
        case .array(let rawArgs)?:
            var args: [String] = []
            for v in rawArgs {
                if case .string(let s) = v { args.append(s) }
                else {
                    return .object([
                        "status": .string("failed"),
                        "tool": .string("git"),
                        "reason": .string("args_must_be_string_array_or_shell_string"),
                        "fix": .string("Pass args as [\"status\", \"--short\"] or as a shell-style string like \"status --short\"."),
                    ])
                }
            }
            parsedArgs = args
        case .string(let raw)?:
            let parsed = builderParseArgString(raw)
            guard let args = parsed.args else {
                return .object([
                    "status": .string("failed"),
                    "tool": .string("git"),
                    "reason": .string("args_string_parse_failed"),
                    "detail": .string(parsed.error ?? "invalid_args_string"),
                    "fix": .string("Use an args array when quoting is complex, e.g. [\"log\", \"--oneline\", \"-5\"]."),
                ])
            }
            parsedArgs = args
        default:
            return .object([
                "status": .string("failed"),
                "tool": .string("git"),
                "reason": .string("missing_args"),
                "fix": .string("Pass args as [\"status\", \"--short\"] or as a shell-style string like \"status --short\"."),
            ])
        }
        if parsedArgs.isEmpty {
            return .object([
                "status": .string("failed"),
                "tool": .string("git"),
                "reason": .string("empty_args"),
                "fix": .string("Pass at least one git subcommand, e.g. \"status --short\"."),
            ])
        }
        let cwd = builderResolveCwd(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 60, maxSeconds: 600)
        return await runShellLikeProcess(
            toolName: "git",
            executable: "/usr/bin/env",
            args: ["git"] + parsedArgs,
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: parsedArgs.joined(separator: " "),
            dataRoot: dataRoot
        )
    }

    static func impl_apply_patch(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        guard case .string(let patch)? = input["patch"], !patch.isEmpty else {
            return .object([
                "status": .string("failed"),
                "tool": .string("apply_patch"),
                "reason": .string("missing_patch"),
            ])
        }
        let threeWay: Bool = {
            if case .bool(let b)? = input["three_way"] { return b }
            return true
        }()
        let cwd = builderResolveCwd(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 60, maxSeconds: 600)

        // runId allocated BEFORE the tmp-file write so a pre-spawn audit
        // entry can be emitted (and surfaced in the envelope) if the
        // write fails — mirrors the spawn_failed audit shape.
        let runId = UUID().uuidString
        let startedAt = Date()

        let trimmedPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPatch.hasPrefix("*** Begin Patch") {
            let auditEntry: [String: Any] = [
                "toolName": "apply_patch",
                "runId": runId,
                "createdAt": ISO8601DateFormatter().string(from: startedAt),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "failed_pre_spawn",
                "reason": "codex_apply_patch_format_not_supported",
                "cwd": cwd,
                "sourcePayload": patch.count > 4_096 ? String(patch.prefix(4_096)) : patch,
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string("apply_patch"),
                "reason": .string("codex_apply_patch_format_not_supported"),
                "detail": .string("NativeAgent chat apply_patch accepts unified diffs. Codex *** Begin Patch format is not interpreted by the app runtime."),
                "fix": .string("Retry with a unified diff, or use write_file for a complete-file replacement."),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }

        let contextPatch = builderParseRangeLessUnifiedPatch(patch)
        if contextPatch.applicable {
            if let error = contextPatch.error {
                let auditEntry: [String: Any] = [
                    "toolName": "apply_patch",
                    "runId": runId,
                    "createdAt": ISO8601DateFormatter().string(from: startedAt),
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "status": "failed_pre_spawn",
                    "reason": error,
                    "cwd": cwd,
                    "patch_format": "range_less_unified_context",
                    "sourcePayload": patch.count > 4_096 ? String(patch.prefix(4_096)) : patch,
                ]
                let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
                var env: [String: JSONValue] = [
                    "status": .string("failed"),
                    "tool": .string("apply_patch"),
                    "reason": .string(error),
                    "runId": .string(runId),
                    "patch_format": .string("range_less_unified_context"),
                    "audit_path": .string(auditURL.path),
                    "fix": .string("Retry with a normal unified diff containing @@ -old,+new hunk ranges."),
                ]
                if let auditErr { env["audit_error"] = .string(auditErr) }
                return .object(env)
            }
            return builderApplyRangeLessUnifiedPatch(
                files: contextPatch.files,
                patch: patch,
                cwd: cwd,
                runId: runId,
                startedAt: startedAt,
                dataRoot: dataRoot
            )
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-patch-\(runId).diff")
        do {
            try patch.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            let preSpawnAudit: [String: Any] = [
                "toolName": "apply_patch",
                "runId": runId,
                "createdAt": ISO8601DateFormatter().string(from: startedAt),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "failed_pre_spawn",
                "reason": "apply_patch_tmp_write_failed",
                "detail": String(describing: error),
                "cwd": cwd,
                "tmpPath": tmpURL.path,
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: preSpawnAudit, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string("apply_patch"),
                "reason": .string("apply_patch_tmp_write_failed"),
                "detail": .string(String(describing: error)),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }

        var gitArgs: [String] = ["git", "apply"]
        if threeWay { gitArgs.append("--3way") }
        gitArgs.append(tmpURL.path)

        return await runShellLikeProcess(
            toolName: "apply_patch",
            executable: "/usr/bin/env",
            args: gitArgs,
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: patch,
            dataRoot: dataRoot
        )
    }

    static func impl_run_tests(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        // run_tests is always anchored at the NativeAgent repo root —
        // there's only one test entrypoint (script/test.sh) and accepting
        // a caller-supplied cwd would let a misrouted call run the wrong
        // suite. cwd is intentionally NOT consulted here.
        let timeout = builderResolveTimeout(input, defaultSeconds: 600, maxSeconds: 3600)
        let scope: String? = {
            if case .string(let s)? = input["scope"], !s.isEmpty { return s }
            return nil
        }()
        guard let sourceRoot = builderSourceRepoRoot(dataRoot: dataRoot) else {
            return builderSourceCheckoutRequiredEnvelope(tool: "run_tests", dataRoot: dataRoot)
        }
        return await runShellLikeProcess(
            toolName: "run_tests",
            executable: "/bin/bash",
            args: ["script/test.sh"],
            cwd: sourceRoot.path,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: scope,
            dataRoot: dataRoot
        )
    }

    static func impl_swift_build(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let packagePath = swiftPMResolvedPackagePath(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 600, maxSeconds: 3600)
        let resolvedConfiguration = swiftPMResolvedConfiguration(input, tool: "swift_build")
        if let failure = resolvedConfiguration.failure {
            return failure
        }
        let configuration = resolvedConfiguration.configuration ?? "debug"

        let product = builderResolveString(input, keys: ["product"])
        let target = builderResolveString(input, keys: ["target"])
        if product != nil && target != nil {
            return .object([
                "status": .string("failed"),
                "tool": .string("swift_build"),
                "reason": .string("product_and_target_are_mutually_exclusive"),
            ])
        }

        var args = ["swift", "build"]
        if builderResolveBool(input, keys: ["disable_swiftpm_sandbox", "disableSwiftPMSandbox"], default: true) {
            args.append("--disable-sandbox")
        }
        args += ["--package-path", packagePath, "--configuration", configuration]
        if let jobs = builderResolveJobs(input) {
            args += ["--jobs", "\(jobs)"]
        }
        if let product {
            args += ["--product", product]
        }
        if let target {
            args += ["--target", target]
        }

        return await runShellLikeProcess(
            toolName: "swift_build",
            executable: "/usr/bin/env",
            args: args,
            cwd: packagePath,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: args.joined(separator: " "),
            dataRoot: dataRoot
        )
    }

    static func impl_swift_test(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let packagePath = swiftPMResolvedPackagePath(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 900, maxSeconds: 3600)
        let resolvedConfiguration = swiftPMResolvedConfiguration(input, tool: "swift_test")
        if let failure = resolvedConfiguration.failure {
            return failure
        }
        let configuration = resolvedConfiguration.configuration ?? "debug"

        var args = ["swift", "test"]
        if builderResolveBool(input, keys: ["disable_swiftpm_sandbox", "disableSwiftPMSandbox"], default: true) {
            args.append("--disable-sandbox")
        }
        args += ["--package-path", packagePath, "--configuration", configuration]
        if let jobs = builderResolveJobs(input) {
            args += ["--jobs", "\(jobs)"]
        }
        if let filter = builderResolveString(input, keys: ["filter"]) {
            args += ["--filter", filter]
        }

        return await runShellLikeProcess(
            toolName: "swift_test",
            executable: "/usr/bin/env",
            args: args,
            cwd: packagePath,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: args.joined(separator: " "),
            dataRoot: dataRoot
        )
    }

    static func impl_install_app(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) -> JSONValue {
        let runId = UUID().uuidString
        let started = Date()
        guard let repo = builderSourceRepoRoot(dataRoot: dataRoot) else {
            return builderSourceCheckoutRequiredEnvelope(tool: "install_app", dataRoot: dataRoot)
        }
        let script = repo
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("install_app.sh")
        let reason = builderResolveString(input, keys: ["reason"]) ?? "unspecified"
        let delay: Int = {
            if case .int(let value)? = input["start_delay_seconds"] {
                return max(5, min(120, Int(value)))
            }
            if case .double(let value)? = input["start_delay_seconds"] {
                return max(5, min(120, Int(value)))
            }
            return Int(AppRestartCoordinator.terminateGraceSeconds.rounded(.up))
        }()
        let logURL = dataRoot
            .appendingPathComponent("builder_audit", isDirectory: true)
            .appendingPathComponent("\(runId)-install_app.log")

        guard FileManager.default.fileExists(atPath: script.path) else {
            let auditEntry: [String: Any] = [
                "toolName": "install_app",
                "runId": runId,
                "createdAt": ISO8601DateFormatter().string(from: started),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "failed_pre_spawn",
                "reason": "script_missing",
                "script": script.path,
                "outer_sandbox_policy": "forced_off",
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string("install_app"),
                "reason": .string("script_missing"),
                "script_path": .string(script.path),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            let auditEntry: [String: Any] = [
                "toolName": "install_app",
                "runId": runId,
                "createdAt": ISO8601DateFormatter().string(from: started),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "failed_pre_spawn",
                "reason": "log_dir_create_failed",
                "detail": String(describing: error),
                "outer_sandbox_policy": "forced_off",
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string("install_app"),
                "reason": .string("log_dir_create_failed"),
                "detail": .string(String(describing: error)),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }

        let command = "sleep \(delay); cd \(shellSingleQuote(repo.path)); exec /bin/bash \(shellSingleQuote(script.path)) >> \(shellSingleQuote(logURL.path)) 2>&1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = repo
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var auditEntry: [String: Any] = [
            "toolName": "install_app",
            "runId": runId,
            "createdAt": ISO8601DateFormatter().string(from: started),
            "status": "scheduled",
            "reason": reason,
            "script": script.path,
            "repo": repo.path,
            "log_path": logURL.path,
            "start_delay_seconds": delay,
            "detached": true,
            "sandboxed": false,
            "sandbox_mode": "off",
            "outer_sandbox_policy": "forced_off",
        ]

        do {
            try process.run()
        } catch {
            auditEntry["completedAt"] = ISO8601DateFormatter().string(from: Date())
            auditEntry["status"] = "failed_pre_spawn"
            auditEntry["spawn_error"] = String(describing: error)
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "tool": .string("install_app"),
                "reason": .string("spawn_failed"),
                "detail": .string(String(describing: error)),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }

        auditEntry["pid"] = Int(process.processIdentifier)
        let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
        var env: [String: JSONValue] = [
            "status": .string("scheduled"),
            "tool": .string("install_app"),
            "runId": .string(runId),
            "pid": .int(Int64(process.processIdentifier)),
            "reason": .string(reason),
            "script_path": .string(script.path),
            "log_path": .string(logURL.path),
            "audit_path": .string(auditURL.path),
            "start_delay_seconds": .int(Int64(delay)),
            "detached": .bool(true),
            "sandboxed": .bool(false),
            "sandbox_mode": .string("off"),
            "outer_sandbox_policy": .string("forced_off"),
            "note": .string("Canonical install scheduled. It runs script/install_app.sh, rebuilds/signs/installs NativeAgent.app, and restarts the app. Keep the final reply brief before the delay elapses."),
        ]
        if let auditErr { env["audit_error"] = .string(auditErr) }
        return .object(env)
    }

}
