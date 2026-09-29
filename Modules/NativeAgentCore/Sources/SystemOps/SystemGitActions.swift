import Foundation
import PersistenceCore

/// Git command selection and receipt formatting; the host executes the process.
public enum SystemGitActions {
    public static func gitPush(runGit: ([String], URL, TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String)) async throws -> (ok: Bool, branch: String?, output: String?, error: String?) {
        let repoRoot = PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        let branchResult = try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], repoRoot, 10)
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteResult = try await runGit(["remote"], repoRoot, 10)
        let remotes = remoteResult.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !remotes.isEmpty else {
            return (ok: false, branch: branch.isEmpty ? nil : branch, output: nil, error: "No GitHub remote configured")
        }
        let pushResult = try await runGit(["push"], repoRoot, 120)
        let output = [pushResult.stdout, pushResult.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (
            ok: pushResult.status == 0,
            branch: branch.isEmpty ? nil : branch,
            output: output.isEmpty ? nil : output,
            error: pushResult.status == 0 ? nil : (output.isEmpty ? "git push failed" : output)
        )
    }

    public static func processDetail(_ result: (status: Int32, stdout: String, stderr: String)) -> String {
        let output = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !output.isEmpty else {
            return "exit \(result.status)"
        }
        let tail = output
            .split(whereSeparator: \.isNewline)
            .suffix(6)
            .joined(separator: " ")
        let clipped = String(tail.prefix(500))
        return "exit \(result.status): \(clipped)"
    }

}

