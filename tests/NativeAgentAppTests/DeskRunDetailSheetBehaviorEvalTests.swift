import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

@Suite("Desk run detail sheet behavior")
struct DeskRunDetailSheetBehaviorEvalTests {
    private func runRecord(json: String) throws -> RunRecord {
        try JSONDecoder().decode(RunRecord.self, from: try #require(json.data(using: .utf8)))
    }

    // app.desk / desk.runs.detailSheet
    @Test("a populated durable run renders every detail fact with its persisted value")
    func populatedRunRendersEveryFact() throws {
        let run = try runRecord(json: """
        {
          "id": "run-populated",
          "kind": "codex",
          "status": "succeeded",
          "model": "gpt-5.6",
          "requestedModel": "gpt-5.6",
          "reasoningEffort": "high",
          "codexSandbox": "workspace-write",
          "fileAccessMode": "read-write",
          "prompt": "Inspect the migration.",
          "output": "Migration is complete.",
          "createdAt": "2027-01-15T12:00:00Z",
          "durationSeconds": 42
        }
        """)

        let facts = RunDetailPresentation.facts(for: run)
        #expect(facts.map(\.label) == [
            "Duration", "Model", "Requested", "Reasoning effort",
            "Sandbox", "File access", "Run ID",
        ])
        #expect(Dictionary(uniqueKeysWithValues: facts.map { ($0.label, $0.value) }) == [
            "Duration": "42s",
            "Model": "gpt-5.6",
            "Requested": "gpt-5.6",
            "Reasoning effort": "High",
            "Sandbox": "workspace-write",
            "File access": "read-write",
            "Run ID": "run-populated",
        ])
    }

    // app.desk / desk.runs.detailSheet
    @Test("missing, empty, whitespace, and invalid durable facts render as unknown instead of disappearing")
    func adverseFieldsRemainVisibleAndHonest() throws {
        let run = try runRecord(json: """
        {
          "id": " ",
          "kind": "mission",
          "status": "failed",
          "model": "",
          "requestedModel": "  ",
          "reasoningEffort": "\\n",
          "codexSandbox": null,
          "fileAccessMode": "",
          "createdAt": "",
          "durationSeconds": -1
        }
        """)

        let facts = RunDetailPresentation.facts(for: run)
        #expect(facts.count == 7)
        #expect(facts.allSatisfy { $0.value == "Unknown" })
        #expect(RunDetailPresentation.createdAtText(for: run) == "Unknown")
    }
}
