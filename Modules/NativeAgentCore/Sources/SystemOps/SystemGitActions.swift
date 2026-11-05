import Foundation
// Blueprint: | `SystemGitActions.swift` | `SystemGitActions` enum; `processDetail` |

/// Keep process effects in the host; shared formatting must not execute commands.
public enum SystemGitActions {
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
