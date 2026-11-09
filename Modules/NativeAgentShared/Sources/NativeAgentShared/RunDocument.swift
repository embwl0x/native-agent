import Foundation
// Blueprint: | `RunDocument.swift` | One saved run's complete read-only document, shared by every door |

public enum RunDocument {
    public static func text(_ run: RunRecord) -> String {
        func known(_ value: String?) -> String {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unknown" }
            return value
        }
        var lines = [RunKindVocabulary.displayName(run.kind, on: .mac),
            "Started: " + known(run.createdAt), "Status: " + known(run.status),
            "Duration: " + (run.durationSeconds.map { String($0) + " seconds" } ?? "Unknown"),
            "Model: " + known(run.model), "Requested model: " + known(run.requestedModel),
            "Reasoning effort: " + known(run.reasoningEffort), "Sandbox: " + known(run.codexSandbox),
            "File access: " + known(run.fileAccessMode), "Run ID: " + known(run.id)]
        for (title, text) in [("Error", run.error), ("Prompt", run.prompt), ("Output", run.output)] {
            if let text { lines += ["", title, text] }
            else { lines += ["", title + ": Not recorded"] }
        }
        return lines.joined(separator: "\n")
    }
}
