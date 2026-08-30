import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Cognition evaluation samplers", .serialized)
struct CognitionEvalSamplersEvalTests {
    private struct ShellFixture {
        let root: URL
        let stubs: URL
        let state: URL
        let token: URL
        let curlLog: URL
    }

    private func root(_ label: String) throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-eval-samplers-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func enabledRuntime(dataRoot: URL) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
    }

    private func shellFixture(_ label: String) throws -> ShellFixture {
        let root = try ScriptFenceEval.makeTempDir("cognition-sampler-\(label)")
        try ScriptFenceEval.copyScript("script/cognition_eval.sh", into: root)
        try ScriptFenceEval.copyScript("script/cognition_event_driven_eval.sh", into: root)
        try ScriptFenceEval.copyScript("script/organism_longitudinal_eval.sh", into: root)
        try ScriptFenceEval.copyScript("script/lib/nativeagent_bridge.sh", into: root)

        let state = root.appendingPathComponent("bridge-state.json")
        try ScriptFenceEval.write(
            """
            {
              "uptimeSeconds": 321,
              "organism": {
                "enabled": true,
                "signalCount": 7,
                "bodySchema": {"posture": "steady"},
                "prediction": {"open": 2},
                "dreamRepair": {"pending": 1},
                "reflex": {"held": 3},
                "behavior": {"mode": "careful"}
              },
              "cognition": {
                "microcycle": {"processIdentifier": 1, "status": "idle"},
                "lastInjectedCapsule": "capsule-1"
              },
              "contextFlow": {
                "mode": "active",
                "storeGeneration": 12,
                "arenaGeneration": 12,
                "degradedSources": 0,
                "pressure": "normal"
              }
            }
            """,
            to: state
        )
        let token = root.appendingPathComponent("bridge-token")
        try ScriptFenceEval.write("fixture-token\n", to: token)
        let curlLog = root.appendingPathComponent("curl-bodies.jsonl")
        let stubs = root.appendingPathComponent("stubs", isDirectory: true)
        try ScriptFenceEval.write(
            #"""
            #!/bin/bash
            body=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--data" ]; then body="$argument"; fi
              previous="$argument"
            done
            if [ -z "$body" ]; then
              cat "$FAKE_BRIDGE_STATE"
            elif [[ "$body" == *'"action":"clear"'* ]]; then
              printf '%s\n' '{"status":"cleared"}'
              jq -c . <<<"$body" >> "$FAKE_CURL_LOG"
            else
              printf '%s\n' '{"status":"active"}'
              jq -c . <<<"$body" >> "$FAKE_CURL_LOG"
            fi
            """#,
            to: stubs.appendingPathComponent("curl"),
            executable: true
        )
        return ShellFixture(root: root, stubs: stubs, state: state, token: token, curlLog: curlLog)
    }

    private func shellEnvironment(
        _ fixture: ShellFixture,
        extra: [String: String]
    ) -> [String: String] {
        ScriptFenceEval.environment(stubDir: fixture.stubs, extra: [
            "FAKE_BRIDGE_STATE": fixture.state.path,
            "FAKE_CURL_LOG": fixture.curlLog.path,
            "NATIVE_AGENT_BRIDGE_TOKEN": fixture.token.path,
            "NATIVE_AGENT_BRIDGE_URL": "http://fixture.invalid",
        ].merging(extra) { _, replacement in replacement })
    }

    private func jsonLines(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }

    @Test("records each real sampler exactly once and bounds repeated runs")
    func recordsAllSamplersWithBoundedResults() async throws {
        let dataRoot = try root("complete")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = enabledRuntime(dataRoot: dataRoot)

        let first = await runtime.runResearchHarness()
        #expect(first.isComplete)
        #expect(!first.isFailed)
        #expect(first.recordedKinds == CognitiveExperimentKind.allCases)
        #expect(first.unavailableKinds.isEmpty)

        let second = await runtime.runResearchHarness()
        #expect(second.isComplete)
        let detail = await runtime.observatoryDetail()
        #expect(
            Set(detail.experiments.map(\.kind)) == Set(CognitiveExperimentKind.allCases),
            "each sampler must write its concrete experiment result through the real substrate"
        )
        #expect(
            detail.experiments.count == CognitiveExperimentKind.allCases.count,
            "re-running the fixed sampler set must replace its stable results instead of growing without bound"
        )
    }

    @Test("reports disabled samplers as unavailable rather than a successful empty run")
    func disabledSamplersAreUnavailable() async throws {
        let dataRoot = try root("disabled")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: .disabled,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        let outcome = await runtime.runResearchHarness()
        #expect(!outcome.isComplete)
        #expect(!outcome.isFailed)
        #expect(outcome.recordedKinds.isEmpty)
        #expect(outcome.unavailableKinds == CognitiveExperimentKind.allCases)
        #expect(outcome.presentationText.contains("unavailable"))
    }

    @Test("organism wrapper writes the six valid longitudinal samples")
    func organismScriptWritesItsOwnedJSONLContract() throws {
        let fixture = try shellFixture("organism")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("organism.jsonl")
        let result = try ScriptFenceEval.run(
            fixture.root.appendingPathComponent("script/organism_longitudinal_eval.sh").path,
            [output.path],
            cwd: fixture.root,
            environment: shellEnvironment(fixture, extra: [
                "NATIVE_AGENT_ORGANISM_EVAL_RUN_ID": "organism-run",
                "NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX": "17",
                "NATIVE_AGENT_ORGANISM_EVAL_NOTE": "fixture-note",
            ])
        )

        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.combined))
        let rows = try jsonLines(at: output)
        #expect(rows.count == 6)
        #expect(rows.compactMap { $0["label"] as? String } == [
            "baseline",
            "scenario:provider_brittle",
            "scenario:stale_phone",
            "scenario:resource_tight",
            "scenario:approval_closed",
            "cleared",
        ])
        #expect(rows.compactMap { $0["sampleKind"] as? String } == [
            "baseline", "scenario", "scenario", "scenario", "scenario", "cleared",
        ])
        for row in rows {
            #expect(row["runId"] as? String == "organism-run")
            #expect(row["dayIndex"] as? Int == 17)
            #expect(row["note"] as? String == "fixture-note")
            #expect(row["enabled"] as? Bool == true)
            #expect(row["signalCount"] as? Int == 7)
            #expect((row["bodySchema"] as? [String: Any])?["posture"] as? String == "steady")
            #expect((row["behavior"] as? [String: Any])?["mode"] as? String == "careful")
            #expect(row["lastInjectedCapsule"] as? String == "capsule-1")
        }
        let requests = try jsonLines(at: fixture.curlLog)
        #expect(requests.count == 5)
        #expect(requests.compactMap { $0["scenario"] as? String } == [
            "provider_brittle", "stale_phone", "resource_tight", "approval_closed",
        ])
        #expect(requests.last?["action"] as? String == "clear")
    }

    @Test("cognition wrapper writes a bounded valid sample and rejects malformed state")
    func cognitionScriptWritesItsOwnedContractAndFailsClosed() throws {
        let fixture = try shellFixture("cognition")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("cognition.jsonl")
        let retained = (0..<256).map { "{\"schema\":\"retained\",\"index\":\($0)}" }.joined(separator: "\n") + "\n"
        try retained.write(to: output, atomically: true, encoding: .utf8)

        let result = try ScriptFenceEval.run(
            fixture.root.appendingPathComponent("script/cognition_event_driven_eval.sh").path,
            [output.path],
            cwd: fixture.root,
            environment: shellEnvironment(fixture, extra: [
                "NATIVE_AGENT_COGNITION_EVAL_RUN_ID": "cognition-run",
                "NATIVE_AGENT_COGNITION_EVAL_DAY_INDEX": "23",
                "NATIVE_AGENT_COGNITION_EVAL_NOTE": "bounded-fixture",
            ])
        )

        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.combined))
        let rows = try jsonLines(at: output)
        #expect(rows.count == 256)
        #expect(rows.first?["index"] as? Int == 1)
        let row = try #require(rows.last)
        #expect(row["schema"] as? String == "cognition.event-driven.eval.v1")
        #expect(row["runId"] as? String == "cognition-run")
        #expect(row["dayIndex"] as? Int == 23)
        #expect(row["note"] as? String == "bounded-fixture")
        #expect(row["appUptimeSeconds"] as? Int == 321)
        #expect(row["organismSignalCount"] as? Int == 7)
        #expect((row["microcycle"] as? [String: Any])?["status"] as? String == "idle")
        let context = try #require(row["contextFlow"] as? [String: Any])
        #expect(context["mode"] as? String == "active")
        #expect(context["storeGeneration"] as? Int == 12)
        #expect(context["arenaGeneration"] as? Int == 12)
        #expect(context["degradedSources"] as? Int == 0)
        #expect(context["pressure"] as? String == "normal")

        try ScriptFenceEval.write(
            #"{"organism":{},"cognition":{},"contextFlow":{}}"#,
            to: fixture.state
        )
        let malformedOutput = fixture.root.appendingPathComponent("malformed.jsonl")
        let malformed = try ScriptFenceEval.run(
            fixture.root.appendingPathComponent("script/cognition_event_driven_eval.sh").path,
            [malformedOutput.path],
            cwd: fixture.root,
            environment: shellEnvironment(fixture, extra: [:])
        )
        #expect(malformed.status != 0)
        #expect(malformed.stderr.contains("bridge state is incomplete or malformed"))
        #expect(!FileManager.default.fileExists(atPath: malformedOutput.path))
    }
}
