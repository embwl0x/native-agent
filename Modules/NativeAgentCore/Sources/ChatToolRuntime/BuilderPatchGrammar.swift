import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import AgentWorkspace
import AuthoredCapabilities
import AppKit
import NativeAgentShared
import TrustCenter
import ApprovalInbox
import PersonaEngine
import StandingBots
import ProviderRouting
import Darwin
import CryptoKit
import MemoryV2
import Dispatcher
import SwarmRuns
import MacIntegration
import TurnTrace
// Blueprint: | `BuilderPatchGrammar.swift` | Patch grammar, path authority and range-less application |
extension SwiftToolDispatcher {
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
        var oldLines: [String]
        var newLines: [String]
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
        guard lines.contains(where: { $0.hasPrefix("@@") && !$0.hasPrefix("@@ -") }) else {
            return (false, [], nil)
        }
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
                    return (true, [], "mixed_patch_hunk_formats")
                }
                sawRangeLessHunk = true
                index += 1
                var oldLines: [String] = []
                var newLines: [String] = []
                var previousPrefix: Character?
                while index < lines.count,
                      !lines[index].hasPrefix("@@"),
                      !lines[index].hasPrefix("--- ") {
                    let hunkLine = lines[index]
                    if hunkLine.hasPrefix("\\ No newline") {
                        if previousPrefix == "-" || previousPrefix == " " {
                            if let last = oldLines.indices.last { oldLines[last].removeLast() }
                        }
                        if previousPrefix == "+" || previousPrefix == " " {
                            if let last = newLines.indices.last { newLines[last].removeLast() }
                        }
                        previousPrefix = nil
                        index += 1
                        continue
                    }
                    if hunkLine.isEmpty, index == lines.count - 1 { break }
                    guard let prefix = hunkLine.first else {
                        oldLines.append("\n")
                        newLines.append("\n")
                        previousPrefix = " "
                        index += 1
                        continue
                    }
                    if prefix == " " {
                        let body = String(hunkLine.dropFirst()) + "\n"
                        oldLines.append(body)
                        newLines.append(body)
                    } else if prefix == "-" {
                        oldLines.append(String(hunkLine.dropFirst()) + "\n")
                    } else if prefix == "+" {
                        newLines.append(String(hunkLine.dropFirst()) + "\n")
                    } else {
                        oldLines.append(hunkLine + "\n")
                        newLines.append(hunkLine + "\n")
                    }
                    previousPrefix = [" ", "-", "+"].contains(prefix) ? prefix : " "
                    index += 1
                }
                guard !oldLines.isEmpty else {
                    return (true, [], "context_patch_add_only_hunk_not_supported")
                }
                hunks.append(BuilderContextPatchHunk(
                    oldLines: oldLines,
                    newLines: newLines
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
    static func builderDeveloperProtectedRoots(dataRoot: URL) -> [String] {
        (MacControlSensitivePathFence.protectedSystemMutationPrefixes
            + [dataRoot.standardizedFileURL.resolvingSymlinksInPath().path,
               NSHomeDirectory() + "/.ssh", NSHomeDirectory() + "/Library/Keychains"])
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    }
    /// The subtrees the builder sandbox profile denies `file-write*` on — the
    /// live trust policy under the data root, and the repo-local `data/trust`
    /// of the source checkout. One list, so the SBPL profile and the
    /// in-process patch path fence the same directories.
    static func builderWriteDeniedSubtrees(dataRoot: URL) -> [URL] {
        var paths = [dataRoot.appendingPathComponent("trust", isDirectory: true)]
        if let source = builderSourceRepoRoot(dataRoot: dataRoot) {
            paths.append(
                source
                    .appendingPathComponent("data", isDirectory: true)
                    .appendingPathComponent("trust", isDirectory: true)
            )
        }
        return paths.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }
    static func builderContextPatchFileURL(
        path: String,
        cwd: String,
        dataRoot: URL,
        sandboxMode: BuilderShellSandboxMode
    ) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let base = URL(fileURLWithPath: cwd).standardizedFileURL
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        let inAllowedRoot = builderAllowedRoots(dataRoot: dataRoot).contains(where: { root in
            NativeAgentWorkspaceRoot.relativePath(resolved.path, under: root.path) != nil
        })
        guard inAllowedRoot || sandboxMode == .off else { return nil }
        if sandboxMode == .off {
            guard builderNormalizeCwd(cwd, dataRoot: dataRoot, allowOutsideWorkspace: true).rejection == nil,
                  MacControlSensitivePathFence.reason(forPath: resolved.path) == nil,
                  MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolved.path) == nil else {
                return nil
            }
        }
        // In-process patches enforce the same Trust-directory write denial as sandboxed subprocesses.
        if builderWriteDeniedSubtrees(dataRoot: dataRoot).contains(where: { denied in
            NativeAgentWorkspaceRoot.relativePath(resolved.path, under: denied.path) != nil
        }) {
            return nil
        }
        if sandboxMode == .developerFullMac {
            let workspace = builderWorkspaceRoot(dataRoot: dataRoot).standardizedFileURL.resolvingSymlinksInPath().path
            let inWorkspace = NativeAgentWorkspaceRoot.relativePath(resolved.path, under: workspace) != nil
            if !inWorkspace, builderDeveloperProtectedRoots(dataRoot: dataRoot).contains(where: { denied in
                NativeAgentWorkspaceRoot.relativePath(resolved.path, under: denied) != nil
            }) { return nil }
        }
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
        dataRoot: URL,
        sandboxMode: BuilderShellSandboxMode
    ) -> JSONValue {
        // One staged body per resolved path. Repeated sections (including
        // symlink/path aliases) apply in order to the previous section's result,
        // not to independent copies that would overwrite earlier changes.
        var stagedFiles: [(url: URL, path: String, original: [String], lines: [String])] = []
        var stagedIndex: [String: Int] = [:]
        func failure(_ reason: String, detail: String? = nil, path: String? = nil, effects: String = "none") -> JSONValue {
            var auditEntry: [String: Any] = [
                "toolName": "apply_patch",
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(startedAt),
                "completedAt": NativeTimestampFormat.plainZulu(Date()),
                "status": "failed_pre_spawn",
                "reason": reason,
                "cwd": cwd,
                "patch_format": "range_less_unified_context",
                "sourcePayload": patch,
            ]
            if let detail { auditEntry["detail"] = detail }
            if let path { auditEntry["path"] = path }
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "effects": .string(effects),
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
                dataRoot: dataRoot,
                sandboxMode: sandboxMode
            ) else {
                return failure("context_patch_path_invalid_or_missing", path: filePatch.path)
            }
            let index: Int
            if let existing = stagedIndex[url.path] {
                index = existing
            } else {
                let original: String
                do {
                    original = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    return failure("context_patch_read_failed", detail: String(describing: error), path: filePatch.path)
                }
                index = stagedFiles.count
                stagedIndex[url.path] = index
                var lines = original.components(separatedBy: "\n")
                for index in lines.indices.dropLast() { lines[index] += "\n" }
                if lines.last?.isEmpty == true { lines.removeLast() }
                stagedFiles.append((url, filePatch.path, lines, lines))
            }
            var lines = stagedFiles[index].lines
            for hunk in filePatch.hunks {
                let ranges: [Range<Int>] = lines.count < hunk.oldLines.count ? []
                    : (0...(lines.count - hunk.oldLines.count)).compactMap { start in
                        let range = start..<(start + hunk.oldLines.count)
                        return lines[range].elementsEqual(hunk.oldLines) ? range : nil
                    }
                guard ranges.count == 1, let range = ranges.first else {
                    return failure(
                        ranges.isEmpty ? "context_patch_old_block_not_found" : "context_patch_old_block_ambiguous",
                        detail: "matched \(ranges.count) locations",
                        path: filePatch.path
                    )
                }
                guard hunk.newLines.dropLast().allSatisfy({ $0.hasSuffix("\n") }),
                      hunk.newLines.last?.hasSuffix("\n") != false || range.upperBound == lines.count else {
                    return failure("context_patch_newline_marker_not_at_end", path: filePatch.path)
                }
                var replacement = hunk.newLines.joined().components(separatedBy: "\n")
                for index in replacement.indices.dropLast() { replacement[index] += "\n" }
                if replacement.last?.isEmpty == true { replacement.removeLast() }
                lines.replaceSubrange(range, with: replacement)
            }
            stagedFiles[index].lines = lines
        }
        // Validate the entire patch before the first write; publish only net
        // changes, once per file. This is not a cross-file atomic transaction.
        let pendingWrites = stagedFiles.filter { $0.lines != $0.original }
        let changedFiles = pendingWrites.map(\.path)
        for write in pendingWrites {
            do {
                try write.lines.joined().write(to: write.url, atomically: true, encoding: .utf8)
            } catch {
                return failure("context_patch_write_failed", detail: String(describing: error), path: write.url.path, effects: "unknown")
            }
        }
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let auditEntry: [String: Any] = [
            "toolName": "apply_patch",
            "runId": runId,
            "createdAt": NativeTimestampFormat.plainZulu(startedAt),
            "completedAt": NativeTimestampFormat.plainZulu(Date()),
            "durationMs": durationMs,
            "status": "completed",
            "exitCode": 0,
            "processExitCode": 0,
            "cwd": cwd,
            "patch_format": "range_less_unified_context",
            "changed_files": changedFiles,
            "sourcePayload": patch,
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
}
