import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

@Suite("Desk run preview fallback behavior")
struct DeskRunPreviewFallbackBehaviorTests {
    private func run(
        error: String? = nil,
        output: String? = nil,
        prompt: String? = nil
    ) throws -> RunRecord {
        var object: [String: Any] = [
            "id": "run-preview",
            "kind": "mission",
            "status": "finished",
            "createdAt": "2026-08-24T12:00:00Z",
        ]
        if let error { object["error"] = error } else { object["error"] = NSNull() }
        if let output { object["output"] = output } else { object["output"] = NSNull() }
        if let prompt { object["prompt"] = prompt } else { object["prompt"] = NSNull() }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RunRecord.self, from: data)
    }

    // app.desk / desk.runs.previewFallback
    @Test("run preview distinguishes error, output, prompt-only, and absent evidence")
    func previewNeverPresentsPromptAsAnUnlabeledResult() throws {
        let errored = RunPreviewPresentation.preview(for: try run(
            error: "Provider timed out",
            output: "An older partial output",
            prompt: "Inspect logs"
        ))
        #expect(errored.kind == .error)
        #expect(errored.text == "Provider timed out")

        let output = RunPreviewPresentation.preview(for: try run(
            output: "  Migration completed.  ",
            prompt: "Run migration"
        ))
        #expect(output.kind == .output)
        #expect(output.text == "Output: Migration completed.")

        let promptOnly = RunPreviewPresentation.preview(for: try run(prompt: "  Inspect the migration.  "))
        #expect(promptOnly.kind == .promptOnly)
        #expect(promptOnly.text == "Prompt (no result yet): Inspect the migration.")

        let empty = RunPreviewPresentation.preview(for: try run(error: " \n", output: "\t", prompt: "  "))
        #expect(empty.kind == .unavailable)
        #expect(empty.text == "No result or prompt recorded.")
    }
}
