import Foundation
import NativeAgentCore
import PersistenceCore
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
import MacControl
import SwarmRuns
import MacIntegration
import TurnTrace
// Blueprint: | `BuilderPatchExecution.swift` | Patch admission and native execution through the dispatcher |
extension SwiftToolDispatcher {
    static func builderValidatePatch(input: [String: JSONValue]) -> (refusal: JSONValue?, files: [BuilderContextPatchFile]?) {
        guard case .string(let patch)? = input["patch"], !patch.isEmpty else {
            return (.object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("apply_patch"),
                "reason": .string("missing_patch"),
                "detail": .string("Pass the unified diff to apply as patch, a non-empty string."),
            ]), nil)
        }
        if patch.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("*** Begin Patch") {
            return (.object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("apply_patch"),
                "reason": .string("codex_apply_patch_format_not_supported"),
                "detail": .string("NativeAgent chat apply_patch accepts unified diffs. Codex *** Begin Patch format is not interpreted by the app runtime."),
                "fix": .string("Retry with files.patch using relative a/ and b/ paths and cwd set to their directory. Replace the example's path, old/new lines and hunk ranges with the actual edit; include \\ No newline at end of file only after lines that lack a final newline."),
                "example_call": .object([
                    "action": .string("files.patch"),
                    "args": .object([
                        "cwd": .string("/absolute/path/to/repo"),
                        "patch": .string("--- a/note.txt\n+++ b/note.txt\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"),
                    ]),
                ]),
            ]), nil)
        }
        let contextPatch = builderParseRangeLessUnifiedPatch(patch)
        if contextPatch.applicable, let error = contextPatch.error {
            return (.object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("apply_patch"),
                "reason": .string(error),
                "patch_format": .string("range_less_unified_context"),
                "fix": .string("Retry with a normal unified diff containing @@ -old,+new hunk ranges."),
            ]), nil)
        }
        if !contextPatch.applicable, !builderUnifiedPatchIsValid(patch) {
            return (.object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("apply_patch"),
                "reason": .string("invalid_unified_patch"),
                "detail": .string("Provide a unified diff with paired ---/+++ file headers and complete @@ -old,count +new,count @@ hunks whose line counts match the body."),
            ]), nil)
        }
        return (nil, contextPatch.applicable ? contextPatch.files : nil)
    }
    /// Syntax only: no subprocess, file lookup, permission prompt or audit.
    /// Git still owns applicability, index state and binary payload decoding.
    private static func builderUnifiedPatchIsValid(_ patch: String) -> Bool {
        guard patch.hasSuffix("\n") else { return false }
        let lines = patch.components(separatedBy: "\n")
        let header = try! NSRegularExpression(pattern: #"^@@ -[0-9]+(?:,([0-9]+))? \+[0-9]+(?:,([0-9]+))? @@(?: .*)?$"#)
        var index = 0
        var sawChange = false
        var fileHasHunk = false
        var inFile = false
        var gitHeader = false
        var gitHasChange = false
        var metadata: Set<String> = []
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                if (inFile && !fileHasHunk) || (gitHeader && !gitHasChange) { return false }
                inFile = false
                gitHeader = true
                gitHasChange = false
                metadata = []
            } else if line.hasPrefix("--- ") {
                if inFile && !fileHasHunk { return false }
                guard index + 1 < lines.count, lines[index + 1].hasPrefix("+++ "),
                      line.count > 4, lines[index + 1].count > 4 else { return false }
                inFile = true
                fileHasHunk = false
                index += 1
            } else if line.hasPrefix("@@") {
                guard inFile,
                      let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return false }
                func count(_ group: Int) -> Int? {
                    guard let range = Range(match.range(at: group), in: line) else { return 1 }
                    return Int(line[range])
                }
                guard var old = count(1), var new = count(2), old > 0 || new > 0 else { return false }
                index += 1
                while old > 0 || new > 0 {
                    guard index < lines.count else { return false }
                    switch lines[index].first {
                    case " ": old -= 1; new -= 1
                    case "-": old -= 1
                    case "+": new -= 1
                    case "\\" where lines[index] == "\\ No newline at end of file": break
                    default: return false
                    }
                    guard old >= 0, new >= 0 else { return false }
                    index += 1
                }
                fileHasHunk = true
                sawChange = true
                gitHasChange = true
                continue
            } else if inFile, line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") {
                // Surplus hunk lines are corrupt even when the declared counts matched.
                if line != "-- " { return false } // git format-patch signature
            } else if gitHeader {
                for prefix in ["old mode ", "new mode ", "new file mode ", "deleted file mode "] where line.hasPrefix(prefix) {
                    let mode = line.dropFirst(prefix.count)
                    guard mode.count == 6, mode.allSatisfy({ "01234567".contains($0) }) else { return false }
                }
                for prefix in ["old mode ", "new mode ", "rename from ", "rename to ", "copy from ", "copy to "]
                where line.hasPrefix(prefix) && line.count > prefix.count { metadata.insert(prefix) }
                if metadata.isSuperset(of: ["old mode ", "new mode "])
                    || metadata.isSuperset(of: ["rename from ", "rename to "])
                    || metadata.isSuperset(of: ["copy from ", "copy to "])
                    || line.hasPrefix("new file mode ") || line.hasPrefix("deleted file mode ") {
                    sawChange = true
                    gitHasChange = true
                }
                if line == "GIT binary patch" {
                    let alphabet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~".utf8)
                    index += 1
                    var blocks = 0
                    while index < lines.count, lines[index].hasPrefix("literal ") || lines[index].hasPrefix("delta ") {
                        guard let size = lines[index].split(separator: " ").last,
                              !size.isEmpty, size.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(size) != nil else { return false }
                        index += 1
                        let bodyStart = index
                        while index < lines.count, !lines[index].isEmpty {
                            let bytes = Array(lines[index].utf8)
                            guard let first = bytes.first else { return false }
                            let length: Int
                            switch first {
                            case 65...90: length = Int(first - 65) + 1
                            case 97...122: length = Int(first - 97) + 27
                            default: return false
                            }
                            guard bytes.count == 1 + ((length + 3) / 4) * 5,
                                  bytes.dropFirst().allSatisfy({ alphabet.contains($0) }) else { return false }
                            index += 1
                        }
                        guard index > bodyStart else { return false }
                        blocks += 1
                        index += 1
                    }
                    guard blocks > 0 else { return false }
                    sawChange = true
                    gitHasChange = true
                    continue
                }
            }
            index += 1
        }
        return sawChange && (!inFile || fileHasHunk) && (!gitHeader || gitHasChange)
    }
    static func impl_apply_patch(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let validation = builderValidatePatch(input: input)
        if let refusal = validation.refusal {
            // Argument checks are pure; only an execution attempt writes an audit.
            guard case .object(var result) = refusal else { return refusal }
            let runId = UUID().uuidString
            let now = NativeTimestampFormat.plainZulu(Date())
            let sourcePayload: String
            if case .string(let patch)? = input["patch"] { sourcePayload = patch }
            else { sourcePayload = "" }
            var entry: [String: Any] = [
                "toolName": "apply_patch", "runId": runId,
                "createdAt": now, "completedAt": now, "status": "failed_pre_spawn",
                "reason": builderResolveString(result, keys: ["reason"]) ?? "invalid_arguments",
                "cwd": builderResolveCwd(input, dataRoot: dataRoot),
                "sourcePayload": sourcePayload,
            ]
            if case .string(let format)? = result["patch_format"] { entry["patch_format"] = format }
            let (auditURL, auditError) = builderWriteAudit(runId: runId, entry: entry, dataRoot: dataRoot)
            result["runId"] = .string(runId)
            result["audit_path"] = .string(auditURL.path)
            if let auditError { result["audit_error"] = .string(auditError) }
            return .object(result)
        }
        guard case .string(let patch)? = input["patch"] else { preconditionFailure("Validated patch missing") }
        let threeWay = builderResolveBool(input, keys: ["three_way"], default: true)
        let cwd = builderResolveCwd(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 60, maxSeconds: 600)
        // Allocate identity before temporary storage so failures retain their audit.
        let runId = UUID().uuidString
        let startedAt = Date()
        if let files = validation.files {
            return builderApplyRangeLessUnifiedPatch(
                files: files,
                patch: patch,
                cwd: cwd,
                runId: runId,
                startedAt: startedAt,
                dataRoot: dataRoot,
                sandboxMode: await builderShellSandboxMode(dataRoot: dataRoot)
            )
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(InstallPaths.current.name("nativeagent-patch-\(runId).diff"))
        do {
            try patch.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            let preSpawnAudit: [String: Any] = [
                "toolName": "apply_patch",
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(startedAt),
                "completedAt": NativeTimestampFormat.plainZulu(Date()),
                "status": "failed_pre_spawn",
                "reason": "apply_patch_tmp_write_failed",
                "detail": String(describing: error),
                "cwd": cwd,
                "tmpPath": tmpURL.path,
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: preSpawnAudit, dataRoot: dataRoot)
            var env = Self.builderFailureFields(error,
                tool: "apply_patch", reason: "apply_patch_tmp_write_failed", effects: .none,
                owner: tmpURL.path,
                instruction: "Repair temporary patch storage at the reported path. The patch was not applied.")
            env.merge([
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
            ], uniquingKeysWith: { _, receipt in receipt })
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        // Select the mode in the same confined cwd/environment as the apply.
        // This is repository discovery, never a retry of a failed three-way apply.
        let command = """
        if [ "$1" = true ] && git rev-parse --git-dir >/dev/null 2>&1; then
            exec git apply --3way "$2"
        else
            exec git apply "$2"
        fi
        """
        return await runShellLikeProcess(
            toolName: "apply_patch",
            executable: "/bin/sh",
            args: ["-c", command, "apply_patch", threeWay ? "true" : "false", tmpURL.path],
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: patch,
            dataRoot: dataRoot
        )
    }
}
