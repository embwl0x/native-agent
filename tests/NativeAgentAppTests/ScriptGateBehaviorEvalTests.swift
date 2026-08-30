import Foundation
import Testing

/// `scripts` fence — BEHAVIOUR evals.
///
/// Every eval here RUNS the real script from `script/` inside a throwaway
/// fixture root with stubs ahead of it on PATH, and asserts on exit code plus
/// an observed effect. Nothing touches the checkout's `data/` or `persona/`,
/// and no eval installs, signs, publishes, or otherwise exercises the release
/// lane's outward-facing behaviour.
///
/// Ledger rows: scripts.evals, scripts.evals.flag.live, scripts.evals.flag.ui,
/// scripts.test_ios, scripts.test.flag.requireIos, scripts.test.pythonCacheGuard,
/// scripts.test.workingTreePythonGuard, scripts.hooks.preCommit,
/// scripts.hooks.preCommit.gitleaksAbsentSkip, scripts.hooks.install,
/// scripts.cleanup_disk_hygiene.
@Suite("ScriptGateBehaviorEval", .serialized)
struct ScriptGateBehaviorEvalTests {

    // MARK: - script/evals.sh — the 2-minute check

    /// Build a fixture repo that `script/evals.sh` can run against end to end:
    /// the real evals.sh, stub sub-scripts, and stub `swift`/`git` on PATH.
    /// The stub swift records every invocation (argv + the live-bench env it
    /// saw) so the eval can assert on WHICH steps ran and with WHAT env.
    private func makeEvalsFixture() throws -> (root: URL, stubs: URL, swiftLog: URL, envLog: URL) {
        let root = try ScriptFenceEval.makeTempDir("evals")
        try ScriptFenceEval.copyScript("script/evals.sh", into: root)
        try ScriptFenceEval.copyScript("script/evals_ledger_merge.swift", into: root)
        let swiftLog = root.appendingPathComponent("swift-invocations.log")
        let envLog = root.appendingPathComponent("step-env.log")

        // Package-relative Tests/... refs are resolved against real files.
        // This changed-file fixture must own the test it expects to select;
        // a ledger mention alone is deliberately not executable evidence.
        try ScriptFenceEval.write(
            "import Testing\nstruct DirectEvalTests { @Test func directFixture() {} }\n",
            to: root.appendingPathComponent("Tests/DirectEvalTests.swift"))

        try ScriptFenceEval.write("""
        {
          "surfaces": [
            {
              "fence": "fixture.root",
              "id": "fixture.alpha",
              "where": "Sources/Alpha.swift:10 alpha production route",
              "coverage": [{"ref": "tests/NativeAgentAppTests/ZetaEvalTests.swift:20 zeta", "tier": "test"}]
            },
            {
              "fence": "fixture.root",
              "id": "fixture.beta",
              "where": "Sources/Alpha.swift:30 beta production route",
              "coverage": [{"ref": "tests/NativeAgentAppTests/ZetaEvalTests.swift:40 zetaAgain", "tier": "test"}]
            },
            {
              "fence": "fixture.core",
              "id": "fixture.core",
              "where": "Modules/NativeAgentCore/Sources/CoreOwner.swift:7 core route",
              "coverage": [{"ref": "Modules/NativeAgentCore/Tests/CoreOwnerTests.swift:12 coreOwner", "tier": "test"}]
            },
            {
              "fence": "fixture.direct",
              "id": "fixture.directTest",
              "where": "Sources/Elsewhere.swift:1",
              "coverage": [{"ref": "Tests/DirectEvalTests.swift:5 direct", "tier": "test"}]
            },
            {
              "fence": "fixture.shell",
              "id": "fixture.shellOnly",
              "where": "script/only.sh:1 shell-only behavior",
              "coverage": [{"ref": "tests/scripts/only_test.sh:4", "tier": "test"}]
            },
            {
              "fence": "fixture.timer",
              "id": "fixture.timerManifest",
              "where": "script/timer_inventory.tsv:1 timer manifest",
              "coverage": [{"ref": "executable: script/check_timer_inventory.swift", "tier": "smoke"}]
            },
            {
              "fence": "fixture.feed",
              "id": "fixture.mobileSnapshotCache",
              "where": "Sources/MobileSnapshotCache.swift:1 mobile snapshot cache",
              "coverage": [{"ref": "tests/NativeAgentAppTests/MobileSnapshotCacheEvalTests.swift:10 cache", "tier": "test"}]
            },
            {
              "fence": "fixture.tiers",
              "id": "fixture.smokeSwift",
              "where": "script/smoke-owner.sh:1 smoke-tier route",
              "coverage": [{"ref": "tests/NativeAgentAppTests/SmokeTierEvalTests.swift:10 smoke", "tier": "smoke"}]
            },
            {
              "fence": "fixture.tiers",
              "id": "fixture.benchSwift",
              "where": "script/bench-owner.sh:1 bench-tier route",
              "coverage": [{"ref": "tests/NativeAgentAppTests/BenchTierEvalTests.swift:10 bench", "tier": "bench"}]
            },
            {
              "fence": "fixture.tiers",
              "id": "fixture.replaySwift",
              "where": "script/replay-owner.sh:1 replay-tier route",
              "coverage": [{"ref": "tests/NativeAgentAppTests/ReplayTierEvalTests.swift:10 replay", "tier": "turn-replay"}]
            },
            {
              "fence": "fixture.shell",
              "id": "fixture.executableShell",
              "where": "script/shell-owner.sh:1 executable shell route",
              "coverage": [{"ref": "executable: tests/scripts/fixture_check.sh", "tier": "smoke"}]
            },
            {
              "fence": "core.memory",
              "id": "feed.memory.sqlite",
              "where": "Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+Storage.swift:607 (<dataRoot>/memory/memory.sqlite)",
              "coverage": [{"ref": "executable: tests/scripts/agent_instrument_test.sh", "tier": "smoke"}]
            }
          ]
        }
        """, to: root.appendingPathComponent("docs/evals/ledger.json"))

        // Stub sub-scripts. Each records itself into the same env log so a
        // step's environment is observable from the outside.
        let recorder = """
        #!/bin/bash
        echo "$(basename "$0")|LIVE=${NATIVEAGENT_RANGE_BENCH_LIVE:-unset}|PERSONA=${NATIVEAGENT_RANGE_BENCH_PERSONA_ROOT:-unset}|ARGS=$*" >> "$STEP_ENV_LOG"
        exit ${STUB_SCRIPT_EXIT:-0}
        """
        try ScriptFenceEval.write(recorder, to: root.appendingPathComponent("script/smoke_all.sh"), executable: true)
        try ScriptFenceEval.write(recorder, to: root.appendingPathComponent("script/user_mode_eval.sh"), executable: true)
        try ScriptFenceEval.write(
            "#!/bin/bash\necho \"test_ios.sh|ARGS=$*\" >> \"$STEP_ENV_LOG\"\necho 'Executed 3 tests, with 0 failures'\nexit ${STUB_SCRIPT_EXIT:-0}\n",
            to: root.appendingPathComponent("script/test_ios.sh"), executable: true)
        // evals.sh names this path for the instrument step; it is never read by
        // the stub, but the step target must exist for a faithful fixture.
        try ScriptFenceEval.write("// stub\n", to: root.appendingPathComponent("script/agent_instrument.swift"))
        try ScriptFenceEval.write(
            "#!/bin/bash\necho \"check_timer_inventory.swift|ARGS=$*\" >> \"$STEP_ENV_LOG\"\necho 'timer inventory checked'\nexit ${STUB_TIMER_EXIT:-0}\n",
            to: root.appendingPathComponent("script/check_timer_inventory.swift"), executable: true)
        try ScriptFenceEval.write(
            "#!/bin/bash\necho \"fixture_check.sh|ARGS=$*\" >> \"$STEP_ENV_LOG\"\nexit ${STUB_SHELL_CHECK_EXIT:-0}\n",
            to: root.appendingPathComponent("tests/scripts/fixture_check.sh"), executable: true)
        try ScriptFenceEval.write(
            "#!/bin/bash\necho \"agent_instrument_test.sh|ARGS=$*\" >> \"$STEP_ENV_LOG\"\nexit ${STUB_INSTRUMENT_SMOKE_EXIT:-0}\n",
            to: root.appendingPathComponent("tests/scripts/agent_instrument_test.sh"), executable: true)

        let stubs = root.appendingPathComponent("stubs", isDirectory: true)
        let swiftStub = """
        #!/bin/bash
        echo "$*" >> "$SWIFT_INVOCATION_LOG"
        echo "swift|LIVE=${NATIVEAGENT_RANGE_BENCH_LIVE:-unset}|PERSONA=${NATIVEAGENT_RANGE_BENCH_PERSONA_ROOT:-unset}|ARGS=$*" >> "$STEP_ENV_LOG"
        prev=""; out=""
        for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
        if [ -n "$out" ]; then printf '# instrument\\n**Health** — window 7d\\nBOOM: everything fine\\n' > "$out"; fi
        case " $* " in
          *" ${STUB_SWIFT_FAIL_PATTERN:-__never_matches__} "*) echo "fixture test failure for ${STUB_SWIFT_FAIL_PATTERN}"; exit 3 ;;
        esac
        case " $* " in
          *" ${STUB_ZERO_TEST_PATTERN:-__never_matches__} "*) echo "Test run with 0 tests passed"; exit 0 ;;
        esac
        if [ "$1" = "test" ] && [ "${STUB_ZERO_TESTS:-0}" = "1" ]; then
          echo "Test run with 0 tests passed"
        elif [ "$1" = "test" ]; then
          echo "Test run with 1 test passed"
        fi
        exit 0
        """
        try ScriptFenceEval.write(swiftStub, to: stubs.appendingPathComponent("swift"), executable: true)
        let gitStub = """
        #!/bin/bash
        args="$*"
        case "$args" in
          *" rev-parse --verify --quiet "*)
            [ "${STUB_GIT_INVALID:-0}" = "1" ] && exit 1
            echo 0123456789abcdef0123456789abcdef01234567
            ;;
          *" diff-tree "*) printf '%s\n' "${STUB_CHANGED_FILES:-README.md}" ;;
          *" rev-parse --short HEAD"*) echo deadbee ;;
          *) echo deadbee ;;
        esac
        exit 0
        """
        try ScriptFenceEval.write(gitStub, to: stubs.appendingPathComponent("git"), executable: true)
        return (root, stubs, swiftLog, envLog)
    }

    private func makeDocsOnlyEvalsFixture()
        throws -> (root: URL, stubs: URL, swiftLog: URL, envLog: URL)
    {
        let fixture = try makeEvalsFixture()
        try ScriptFenceEval.write("""
        [
          {
            "fence": "scripts",
            "fragment": {
              "ranRun": "fixture",
              "uncertain": [],
              "surfaces": [
                {
                  "id": "fixture.docsOnly",
                  "kind": "cli",
                  "where": "script/evals.sh:1",
                  "coverage": []
                }
              ]
            },
            "critic": {"missed": [], "disputed": []}
          }
        ]
        """, to: fixture.root.appendingPathComponent("docs/evals/phase1-fragments.json"))
        let merge = try ScriptFenceEval.run(
            "/usr/bin/env", [
                "swift", fixture.root.appendingPathComponent("script/evals_ledger_merge.swift").path,
                fixture.root.appendingPathComponent("docs/evals/phase1-fragments.json").path,
                "--out", fixture.root.appendingPathComponent("docs/evals").path,
            ],
            cwd: fixture.root,
            environment: ScriptFenceEval.environment(stubDir: nil),
            timeout: 60)
        guard merge.status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: merge.combined])
        }
        return fixture
    }

    private func runEvals(_ fixture: (root: URL, stubs: URL, swiftLog: URL, envLog: URL),
                          args: [String] = [],
                          extraEnv: [String: String] = [:]) throws -> ScriptFenceEval.RunResult {
        var env: [String: String] = [
            "SWIFT_INVOCATION_LOG": fixture.swiftLog.path,
            "STEP_ENV_LOG": fixture.envLog.path,
            "TMPDIR": fixture.root.appendingPathComponent("tmp").path,
            "NATIVEAGENT_EVALS_CHANGED_SWIFT": "/usr/bin/swift",
        ]
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        for (k, v) in extraEnv { env[k] = v }
        return try ScriptFenceEval.run(
            fixture.root.appendingPathComponent("script/evals.sh").path, args,
            cwd: fixture.root,
            environment: ScriptFenceEval.environment(stubDir: fixture.stubs, extra: env),
            timeout: 90)
    }

    /// scripts.evals — the 2-minute check runs every always-on step and exits
    /// with the FAILURE COUNT. `set -uo pipefail` has no `-e`, so a step that
    /// blows up must still be counted; if the accounting broke, evals.sh would
    /// print ✘ and exit 0 and the whole check becomes decorative.
    @Test func twoMinuteCheckRunsEveryAlwaysOnStepAndExitsZeroWhenTheyPass() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture)
        #expect(!result.timedOut)
        let names = [
            "smoke", "instrument", "turn-replay", "range-bench-L1", "ledger-keeper",
            "total-surface-contract",
        ]
        for name in names {
            #expect(result.stdout.contains("✔ \(name)"), Comment(rawValue: "step \(name) did not run/pass:\n\(result.combined)"))
        }
        #expect(result.status == 0, Comment(rawValue: "clean run exited \(result.status):\n\(result.combined)"))
        #expect(result.stdout.contains("0 failure(s)"))
        // The BOOM excerpt must be non-empty (scripts.evals.boomExcerpt): the
        // awk slice really selected the instrument's **Health** line.
        #expect(result.stdout.contains("instrument BOOM:"))
        #expect(result.stdout.contains("**Health**"),
                Comment(rawValue: "BOOM excerpt rendered empty — the awk marker no longer matches:\n\(result.stdout)"))
        print("evals.sh eval: \(names.count) always-on steps ran, exit \(result.status)")
    }

    /// NEGATIVE CONTROL / mutation proof for the accounting above: make exactly
    /// two steps fail and the exit code must be 2, not 0.
    @Test func twoMinuteCheckCountsFailingStepsIntoItsExitCode() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // One swift step fails (matched by filter name) and the smoke script fails.
        let result = try runEvals(fixture, extraEnv: [
            "STUB_SWIFT_FAIL_PATTERN": "TurnReplayBench",
            "STUB_SCRIPT_EXIT": "7",
        ])
        #expect(!result.timedOut)
        #expect(result.stdout.contains("✘ smoke"), Comment(rawValue: result.combined))
        #expect(result.stdout.contains("✘ turn-replay"), Comment(rawValue: result.combined))
        #expect(result.status == 2, Comment(rawValue: "expected exit 2 (two failing steps), got \(result.status):\n\(result.combined)"))
        #expect(result.stdout.contains("2 failure(s)"))
    }

    /// SwiftPM exits zero when a filter selects nothing. Require a positive
    /// executed-test count so a renamed suite cannot leave a decorative gate.
    @Test func twoMinuteCheckRejectsVacuousZeroTestFilters() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, extraEnv: ["STUB_ZERO_TESTS": "1"])
        #expect(result.status == 4, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("✘ turn-replay"))
        #expect(result.stdout.contains("✘ range-bench-L1"))
        #expect(result.stdout.contains("✘ ledger-keeper"))
        #expect(result.stdout.contains("✘ total-surface-contract"))
    }

    @Test func changedModeSelectsExactLedgerFiltersOnceInStableOrder() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "Sources/Alpha.swift\nModules/NativeAgentCore/Sources/CoreOwner.swift\nTests/DirectEvalTests.swift",
        ])
        #expect(result.status == 0, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("WE'RE GOOD"), Comment(rawValue: result.stdout))
        let invocations = try String(contentsOf: fixture.swiftLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let filters = invocations.compactMap { line -> String? in
            let parts = line.split(separator: " ").map(String.init)
            guard let index = parts.firstIndex(of: "--filter"), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }
        #expect(filters == ["CoreOwnerTests", "DirectEvalTests", "ZetaEvalTests", "EvalCoverageLedger", "TotalSurfaceContract"],
                Comment(rawValue: "unexpected selection/order/dedupe: \(filters)\n\(result.combined)"))
        #expect(!result.stdout.contains("smoke"))
        #expect(!result.stdout.contains("turn-replay"))
        #expect(result.stdout.components(separatedBy: "--filter ZetaEvalTests").count - 1 == 1)
    }

    @Test func changedModeRunsMappedSmokeChecksAndSnapshotCacheCoverageInStableOrder() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "script/timer_inventory.tsv\nSources/MobileSnapshotCache.swift",
        ])
        #expect(result.status == 0, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("SELECTED: root --filter MobileSnapshotCacheEvalTests"))
        #expect(result.stdout.contains("SELECTED: executable script/check_timer_inventory.swift"))
        let rootSelection = try #require(result.stdout.range(of: "SELECTED: root --filter MobileSnapshotCacheEvalTests"))
        let scriptSelection = try #require(result.stdout.range(of: "SELECTED: executable script/check_timer_inventory.swift"))
        #expect(rootSelection.lowerBound < scriptSelection.lowerBound)
        let scriptInvocations = try String(contentsOf: fixture.envLog, encoding: .utf8)
        #expect(scriptInvocations.contains("check_timer_inventory.swift|ARGS="))
        #expect(result.stdout.contains("WE'RE GOOD"))
    }

    @Test func changedModeRoutesEveryExecutableTierAndShellCheckInStableOrder() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "script/smoke-owner.sh\nscript/bench-owner.sh\nscript/replay-owner.sh\nscript/shell-owner.sh",
        ])
        #expect(result.status == 0, Comment(rawValue: result.combined))
        let selected = result.stdout.split(separator: "\n").map(String.init)
            .filter { $0.contains("SELECTED:") }
        #expect(selected == [
            "  SELECTED: root --filter BenchTierEvalTests",
            "  SELECTED: root --filter ReplayTierEvalTests",
            "  SELECTED: root --filter SmokeTierEvalTests",
            "  SELECTED: executable tests/scripts/fixture_check.sh",
        ], Comment(rawValue: selected.joined(separator: "\n")))
        let scriptInvocations = try String(contentsOf: fixture.envLog, encoding: .utf8)
        #expect(scriptInvocations.contains("fixture_check.sh|ARGS="))
        #expect(result.stdout.contains("WE'RE GOOD"))
    }

    @Test func changedModeShellFailurePreservesExitAndReverseMapsItsSurface() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "script/shell-owner.sh",
            "STUB_SHELL_CHECK_EXIT": "9",
        ])
        #expect(result.status == 9, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("BROKE: fixture.executableShell (script/shell-owner.sh:1 executable shell route)"))
        #expect(result.stdout.contains("command exit: 9"))
    }

    @Test func changedModeEvalBookkeepingRunsCanonicalMergeKeeperAndSeal() throws {
        let fixture = try makeDocsOnlyEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "docs/evals/phase1-fragments.json\ndocs/evals/ledger.json\ndocs/evals/COVERAGE.md\ndocs/evals/behavior-remap-residue-2026-08-26.json",
        ])
        #expect(result.status == 0, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("✔ canonical-merge"))
        #expect(result.stdout.contains("✔ ledger-keeper"))
        #expect(result.stdout.contains("✔ total-surface-contract"))
        #expect(result.stdout.contains("DOCS-ONLY: keeper+seal+merge green, nothing executable touched"))
        #expect(!result.stdout.contains("NO MAPPED EXECUTABLE REFS"))
    }

    @Test func changedModeDocsOnlyFailsOnStaleGenerationAndNeverCoversMixedChanges() throws {
        let stale = try makeDocsOnlyEvalsFixture()
        defer { try? FileManager.default.removeItem(at: stale.root) }
        let staleLedger = stale.root.appendingPathComponent("docs/evals/ledger.json")
        try ScriptFenceEval.write(
            try String(contentsOf: staleLedger, encoding: .utf8)
                .replacingOccurrences(of: "fixture.docsOnly", with: "fixture.stale"),
            to: staleLedger)
        let staleResult = try runEvals(stale, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "docs/evals/ledger.json",
        ])
        #expect(staleResult.status == 1, Comment(rawValue: staleResult.combined))
        #expect(staleResult.stdout.contains("✘ canonical-merge"))
        #expect(!staleResult.stdout.contains("DOCS-ONLY:"))

        let mixed = try makeDocsOnlyEvalsFixture()
        defer { try? FileManager.default.removeItem(at: mixed.root) }
        let mixedResult = try runEvals(mixed, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "docs/evals/ledger.json\nSources/Unmapped.swift",
        ])
        #expect(mixedResult.status == 1, Comment(rawValue: mixedResult.combined))
        #expect(mixedResult.stdout.contains("NO MAPPED EXECUTABLE REFS"))
        #expect(!mixedResult.stdout.contains("DOCS-ONLY:"))
        #expect(!mixedResult.stdout.contains("canonical-merge"))

        let generalDocs = try makeDocsOnlyEvalsFixture()
        defer { try? FileManager.default.removeItem(at: generalDocs.root) }
        let docsResult = try runEvals(generalDocs, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "docs/README.md",
        ])
        #expect(docsResult.status == 1, Comment(rawValue: docsResult.combined))
        #expect(!docsResult.stdout.contains("DOCS-ONLY:"))
    }

    @Test func changedModeReportsMappedSmokeCheckFailureWithoutHidingItsExit() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "script/timer_inventory.tsv",
            "STUB_TIMER_EXIT": "7",
        ])
        #expect(result.status == 7, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("BROKE: fixture.timerManifest (script/timer_inventory.tsv:1 timer manifest)"))
        #expect(result.stdout.contains("command exit: 7"))
        #expect(result.stdout.contains("timer inventory checked"))
        #expect(!result.stdout.contains("WE'RE GOOD"))
    }

    @Test func changedModeAlwaysRunsContractsAndFailsHonestlyWhenNothingMaps() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "README.md",
        ])
        #expect(result.status == 1, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("NO MAPPED EXECUTABLE REFS"))
        #expect(result.stdout.contains("✔ ledger-keeper"))
        #expect(result.stdout.contains("✔ total-surface-contract"))
        #expect(result.stdout.contains("NOT GOOD: 1 failure(s)"))
        #expect(!result.stdout.contains("WE'RE GOOD"))
    }

    @Test func changedModeRejectsMissingAndMalformedCommitsClearly() throws {
        let missing = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: missing.root) }
        let missingResult = try runEvals(missing, args: ["--changed"])
        #expect(missingResult.status == 2)
        #expect(missingResult.stderr.contains("--changed requires a commit SHA"))

        let malformed = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: malformed.root) }
        let malformedResult = try runEvals(malformed, args: ["--changed", "not-a-sha"], extraEnv: [
            "STUB_GIT_INVALID": "1",
        ])
        #expect(malformedResult.status == 2)
        #expect(malformedResult.stderr.contains("changed-mode planning failed"))
        #expect(malformedResult.stderr.contains("malformed commit SHA 'not-a-sha'"))
    }

    @Test func changedModeZeroTestFilterFailsClosedAndNamesEveryMappedSurface() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "Sources/Alpha.swift",
            "STUB_ZERO_TEST_PATTERN": "ZetaEvalTests",
        ])
        #expect(result.status == 1, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("BROKE: fixture.alpha (Sources/Alpha.swift:10 alpha production route)"))
        #expect(result.stdout.contains("BROKE: fixture.beta (Sources/Alpha.swift:30 beta production route)"))
        let alpha = try #require(result.stdout.range(of: "BROKE: fixture.alpha"))
        let beta = try #require(result.stdout.range(of: "BROKE: fixture.beta"))
        #expect(alpha.lowerBound < beta.lowerBound, "multiple surfaces were not printed deterministically")
        #expect(result.stdout.contains("no non-zero executed-test count found"))
        #expect(result.stdout.contains("command exit: 0"))
    }

    @Test func changedModePreservesMappedFailureDiagnosticsAndReportsUnmappedGateFailure() throws {
        let mapped = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: mapped.root) }
        let mappedResult = try runEvals(mapped, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "Sources/Alpha.swift",
            "STUB_SWIFT_FAIL_PATTERN": "ZetaEvalTests",
        ])
        #expect(mappedResult.status == 3, Comment(rawValue: mappedResult.combined))
        #expect(mappedResult.stdout.contains("BROKE: fixture.alpha"))
        #expect(mappedResult.stdout.contains("fixture test failure for ZetaEvalTests"),
                "the underlying Swift failure was hidden")
        #expect(mappedResult.stdout.contains("command exit: 3"))

        let unmapped = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: unmapped.root) }
        let unmappedResult = try runEvals(unmapped, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "Sources/Alpha.swift",
            "STUB_SWIFT_FAIL_PATTERN": "TotalSurfaceContract",
        ])
        #expect(unmappedResult.status == 3, Comment(rawValue: unmappedResult.combined))
        #expect(unmappedResult.stdout.contains("UNMAPPED FAILURE: total-surface-contract"))
        #expect(unmappedResult.stdout.contains("fixture test failure for TotalSurfaceContract"))
    }

    @Test func changedModeRejectsAffectedSurfaceWithoutASwiftPMCoverageRef() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--changed", "deadbee"], extraEnv: [
            "STUB_CHANGED_FILES": "script/only.sh",
        ])
        #expect(result.status == 1, Comment(rawValue: result.combined))
        #expect(result.stdout.contains("UNMAPPED SURFACE: fixture.shellOnly (script/only.sh:1 shell-only behavior)"))
        #expect(result.stdout.contains("NO MAPPED EXECUTABLE REFS"))
        #expect(result.stdout.contains("✔ ledger-keeper"))
        #expect(result.stdout.contains("✔ total-surface-contract"))
    }

    /// scripts.evals.flag.live — the ledger row's stated failure mode (the live
    /// env leaking into later steps) is empirically FALSE in non-POSIX bash, so
    /// this eval pins the property that actually matters and that a
    /// `set -o posix` or a hoisted `export` would break: the live env reaches
    /// the live step and NOTHING after it.
    @Test func liveFlagScopesTheRangeBenchEnvToItsOwnStep() throws {
        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--live", "--ui", "--ios"])
        #expect(!result.timedOut)
        #expect(result.stdout.contains("range-bench-live"), Comment(rawValue: result.combined))
        #expect(result.stdout.contains("ui-walk"), Comment(rawValue: result.combined))
        #expect(result.stdout.contains("ios-simulator"), Comment(rawValue: result.combined))
        let envLines = (try? String(contentsOf: fixture.envLog, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let liveStep = envLines.first { $0.contains("scenario2_theRange") }
        let uiStep = envLines.first { $0.hasPrefix("user_mode_eval.sh|") }
        let iosStep = envLines.first { $0.hasPrefix("test_ios.sh|") }
        #expect(liveStep?.contains("LIVE=1") == true,
                Comment(rawValue: "the live bench step did not receive NATIVEAGENT_RANGE_BENCH_LIVE=1: \(liveStep ?? "<step never ran>")"))
        #expect(uiStep?.contains("LIVE=unset") == true,
                Comment(rawValue: "live-bench env LEAKED into the ui-walk step: \(uiStep ?? "<step never ran>")"))
        // The persona root handed to the live bench must be the ROOT-relative
        // one, never an ambient path — hermeticity of the flag itself. It must
        // likewise be absent from the following step.
        #expect(liveStep?.contains("PERSONA=\(fixture.root.path)/persona") == true,
                Comment(rawValue: "the live bench did not get a ROOT-relative persona path: \(liveStep ?? "<step never ran>")"))
        #expect(uiStep?.contains("PERSONA=unset") == true,
                Comment(rawValue: "the live persona root LEAKED into the ui-walk step: \(uiStep ?? "<step never ran>")"))
        #expect(uiStep?.contains("ARGS=--strict-ui") == true,
                Comment(rawValue: "the UI lane was not strict: \(uiStep ?? "<step never ran>")"))
        #expect(iosStep?.contains("ARGS=--require") == true,
                Comment(rawValue: "the iOS lane allowed a silent skip: \(iosStep ?? "<step never ran>")"))
        print("evals.sh optional lanes: live scoped, UI strict, iOS required")
    }

    /// scripts.evals.flag.ui — `--ui` must ADD the ui-walk step and its failure
    /// must be counted, not swallowed by the `[ "$UI" = 1 ] && step …` idiom.
    @Test func uiFlagAddsTheWalkAndCountsItsFailure() throws {
        let clean = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: clean.root) }
        let withoutUI = try runEvals(clean)
        #expect(!withoutUI.stdout.contains("ui-walk"), "ui-walk ran without --ui")

        let fixture = try makeEvalsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runEvals(fixture, args: ["--ui"], extraEnv: ["STUB_SCRIPT_EXIT": "4"])
        #expect(!result.timedOut)
        #expect(result.stdout.contains("✘ ui-walk"), Comment(rawValue: result.combined))
        // smoke + ui-walk are both stubs and both fail => 2.
        #expect(result.status == 2, Comment(rawValue: "ui-walk failure was not counted (exit \(result.status)):\n\(result.combined)"))
    }

    // MARK: - script/test_ios.sh (scripts.test_ios, scripts.test.flag.requireIos)

    /// The whole job of test_ios.sh is to stop the iOS half rotting green. With
    /// no simulator it SKIPS at exit 0; `--require` must turn that same skip
    /// into a failure. Stub `xcrun` so the skip is deterministic on any host.
    @Test func iosRunnerSkipsWithoutASimulatorAndRefusesToUnderRequire() throws {
        let root = try ScriptFenceEval.makeTempDir("test-ios")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScriptFenceEval.copyScript("script/test_ios.sh", into: root)
        let stubs = root.appendingPathComponent("stubs", isDirectory: true)
        // `xcrun simctl list devices available` succeeds but reports no devices.
        try ScriptFenceEval.write("""
        #!/bin/bash
        if [ "$1" = "simctl" ]; then
          case " $* " in *" -j "*) echo '{"devices":{}}' ;; *) echo "== Devices ==" ;; esac
          exit 0
        fi
        exit 0
        """, to: stubs.appendingPathComponent("xcrun"), executable: true)

        let env = ScriptFenceEval.environment(stubDir: stubs)
        let script = root.appendingPathComponent("script/test_ios.sh").path
        let lenient = try ScriptFenceEval.run(script, [], cwd: root, environment: env, timeout: 60)
        #expect(lenient.status == 0, Comment(rawValue: "lenient run should skip cleanly:\n\(lenient.combined)"))
        #expect(lenient.combined.contains("SKIP"), Comment(rawValue: lenient.combined))
        #expect(lenient.combined.contains("no available iOS iPhone simulator installed"),
                Comment(rawValue: "skipped for the wrong reason:\n\(lenient.combined)"))

        let required = try ScriptFenceEval.run(script, ["--require"], cwd: root, environment: env, timeout: 60)
        #expect(required.status != 0, Comment(rawValue: "--require accepted a skip — a Mac-only machine can certify the iOS half:\n\(required.combined)"))
        #expect(required.combined.contains("FAIL"), Comment(rawValue: required.combined))
        #expect(required.combined.contains("required release proof"), Comment(rawValue: required.combined))
        print("test_ios eval: lenient exit \(lenient.status) (SKIP), --require exit \(required.status) (FAIL)")

        // The builder-sandbox branch is the other silent skip; it must obey
        // --require too, or the sandboxed builder tool certifies iOS forever.
        let sandboxEnv = ScriptFenceEval.environment(
            stubDir: stubs, extra: ["NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX": "1"])
        let sandboxLenient = try ScriptFenceEval.run(script, [], cwd: root, environment: sandboxEnv, timeout: 60)
        let sandboxRequired = try ScriptFenceEval.run(script, ["--require"], cwd: root, environment: sandboxEnv, timeout: 60)
        #expect(sandboxLenient.status == 0)
        #expect(sandboxLenient.combined.contains("builder sandbox"))
        #expect(sandboxRequired.status != 0, Comment(rawValue: "--require accepted the builder-sandbox skip:\n\(sandboxRequired.combined)"))
    }

    // MARK: - script/test.sh scanners (silent-scanner class)

    /// Extract one `NAME="$(` … `)"` command-substitution block verbatim from a
    /// shell source, so the eval runs the REAL scanner expression rather than a
    /// paraphrase of it. A prune-path or name change in test.sh flows straight
    /// into these evals.
    static func extractAssignmentBlock(_ source: String, variable: String) -> String? {
        guard let start = source.range(of: "\(variable)=\"$(") else { return nil }
        guard let end = source.range(of: "\n)\"", range: start.lowerBound..<source.endIndex) else { return nil }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// scripts.test.pythonCacheGuard — `find … -print -quit … || true` reads a
    /// scan that ERRORED as a scan that was CLEAN. Negative control: plant a
    /// `__pycache__` and prove the real expression finds it, i.e. the scan has
    /// a subject at all.
    @Test func pythonCacheGuardActuallyScansSomething() throws {
        let source = try ScriptFenceEval.text("script/test.sh")
        let block = try #require(Self.extractAssignmentBlock(source, variable: "cache_hit"),
                                 "the generated-Python-cache scanner moved out of script/test.sh")
        #expect(block.contains("__pycache__"))

        let root = try ScriptFenceEval.makeTempDir("pycache")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)

        func scan() throws -> String {
            let out = try ScriptFenceEval.bash(
                "set -uo pipefail\nROOT=\(root.path)\n\(block)\nprintf '%s' \"$cache_hit\"", timeout: 60)
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        #expect(try scan().isEmpty, "clean fixture reported a hit")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/__pycache__"), withIntermediateDirectories: true)
        let planted = try scan()
        #expect(planted.contains("__pycache__"),
                Comment(rawValue: "the guard's own find expression did NOT see a planted __pycache__ — the scan is blind: '\(planted)'"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/__pycache__"))
        try ScriptFenceEval.write("x = 1\n", to: root.appendingPathComponent("Sources/stale.pyc"))
        #expect(try scan().hasSuffix("stale.pyc"), "the *.pyc arm of the guard is blind")
        print("python-cache-guard eval: clean=empty, planted __pycache__ and .pyc both detected by the real expression")
    }

    /// scripts.test.workingTreePythonGuard — same swallow, and it is FIRING at
    /// HEAD. Assert (a) the real expression detects a planted .py, and (b) the
    /// repo's own hits stay within a dated known set.
    @Test func workingTreePythonGuardScansAndItsRepoHitsAreKnown() throws {
        let source = try ScriptFenceEval.text("script/test.sh")
        let block = try #require(Self.extractAssignmentBlock(source, variable: "working_py_hit"),
                                 "the working-tree Python scanner moved out of script/test.sh")

        let root = try ScriptFenceEval.makeTempDir("workingpy")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("script"), withIntermediateDirectories: true)

        /// The guard stops at the FIRST hit (`-print -quit`), which is fine for
        /// a gate but useless for an inventory. Drop only the `-quit` — the
        /// prune set and the name filter stay verbatim from script/test.sh, so
        /// a prune-path edit still flows into this eval.
        let enumerating = block.replacingOccurrences(of: "-print -quit", with: "-print")
        #expect(enumerating != block, "script/test.sh no longer uses `-print -quit` here — re-derive this eval")
        func scan(_ expression: String, _ rootPath: String) throws -> [String] {
            let out = try ScriptFenceEval.bash(
                "set -uo pipefail\nROOT=\(rootPath)\n\(expression)\nprintf '%s' \"$working_py_hit\"", timeout: 120)
            return out.stdout.split(separator: "\n").map {
                let path = String($0)
                return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            }.sorted()
        }
        #expect(try scan(block, root.path).isEmpty, "clean fixture reported a hit")
        try ScriptFenceEval.write("print(1)\n", to: root.appendingPathComponent("script/planted.py"))
        #expect(try scan(block, root.path) == ["script/planted.py"],
                "the working-tree Python scan is blind — a planted .py was not found")
        // Pruning must still work, or the guard would fire on its own exclusions.
        try ScriptFenceEval.write("print(2)\n", to: root.appendingPathComponent(".build/ignored.py"))
        #expect(try scan(block, root.path) == ["script/planted.py"], "the guard stopped pruning .build")

        // Dated known state (2026-08-23): the coverage campaign's two helper
        // scripts were ported to Swift (script/evals_apply_wave.swift,
        // script/evals_ledger_merge.swift), so the repo scan is clean; ANY
        // tracked .py in the working tree fails this eval.
        let known: Set<String> = []
        let repoHits = try scan(enumerating, ScriptFenceEval.repo.path)
        let unexpected = repoHits.filter { !known.contains($0) }
        print("working-tree-python-guard eval: planted file detected, .build pruned; repo hits = \(repoHits.isEmpty ? "<none>" : repoHits.joined(separator: ", "))")
        #expect(unexpected.isEmpty,
                Comment(rawValue: "NEW Python file(s) in the working tree — script/test.sh will refuse to run: \(unexpected.joined(separator: ", "))"))
    }

    // MARK: - script/hooks (scripts.hooks.install, scripts.hooks.preCommit)

    private func makeHookRepo() throws -> (root: URL, stubs: URL) {
        let root = try ScriptFenceEval.makeTempDir("hooks")
        let env = ScriptFenceEval.environment(stubDir: nil)
        _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "init", "-q", "-b", "main", root.path],
                                    environment: env, timeout: 60)
        for pair in [("user.email", "eval@local"), ("user.name", "Eval"), ("commit.gpgsign", "false")] {
            _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "-C", root.path, "config", pair.0, pair.1],
                                        environment: env, timeout: 30)
        }
        try ScriptFenceEval.copyScript("script/hooks/pre-commit", into: root)
        try ScriptFenceEval.copyScript("script/hooks/install.sh", into: root)
        try ScriptFenceEval.write("[extend]\n", to: root.appendingPathComponent(".gitleaks.toml"))
        return (root, root.appendingPathComponent("stubs", isDirectory: true))
    }

    /// scripts.hooks.install — the installer's whole product is a working
    /// `.git/hooks/pre-commit`. A relative symlink that resolves to nothing is
    /// the silent failure: git runs nothing and every commit sails through.
    @Test func hookInstallerProducesAnExecutableHookThatResolves() throws {
        let (root, _) = try makeHookRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ScriptFenceEval.run(
            root.appendingPathComponent("script/hooks/install.sh").path, [],
            cwd: root, environment: ScriptFenceEval.environment(stubDir: nil), timeout: 60)
        #expect(result.status == 0, Comment(rawValue: result.combined))
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        #expect(FileManager.default.fileExists(atPath: hook.path),
                "install.sh reported success but .git/hooks/pre-commit does not resolve")
        #expect(FileManager.default.isExecutableFile(atPath: hook.path))
        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: hook.path)
        #expect(resolved.hasSuffix("script/hooks/pre-commit"), Comment(rawValue: "unexpected link target: \(resolved)"))
        // Idempotent: a second run must not fail or double-link.
        let again = try ScriptFenceEval.run(
            root.appendingPathComponent("script/hooks/install.sh").path, [],
            cwd: root, environment: ScriptFenceEval.environment(stubDir: nil), timeout: 60)
        #expect(again.status == 0, Comment(rawValue: again.combined))
        print("hooks/install eval: hook installed, executable, resolves to \(resolved), idempotent")
    }

    /// scripts.hooks.preCommit.gitleaksAbsentSkip — with gitleaks absent the
    /// hook exits 0 by design, which means the leak guard is OFF on any machine
    /// that never installed it. Pin BOTH halves so the skip stays loud and the
    /// block stays real: absent => exit 0 with an explicit warning on stderr;
    /// present-and-failing => exit non-zero with BLOCKED.
    @Test func preCommitSkipsLoudlyWithoutGitleaksAndBlocksWithIt() throws {
        let (root, stubs) = try makeHookRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        try ScriptFenceEval.write("hello\n", to: root.appendingPathComponent("note.txt"))
        _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "-C", root.path, "add", "-A"],
                                    environment: ScriptFenceEval.environment(stubDir: nil), timeout: 30)

        let hook = root.appendingPathComponent("script/hooks/pre-commit").path
        // 1. gitleaks absent: PATH has no gitleaks stub.
        let absent = try ScriptFenceEval.run(
            hook, [], cwd: root, environment: ScriptFenceEval.environment(stubDir: stubs), timeout: 60)
        #expect(absent.status == 0, Comment(rawValue: "hook failed when gitleaks is absent:\n\(absent.combined)"))
        #expect(absent.stderr.contains("gitleaks not installed"),
                Comment(rawValue: "the skip was SILENT — nothing told the committer the guard was off:\n\(absent.combined)"))
        #expect(absent.stderr.contains("Skipping scan"))

        // 2. gitleaks present and finding something: the commit must be blocked.
        try ScriptFenceEval.write("#!/bin/bash\necho 'leak found' >&2\nexit 1\n",
                                  to: stubs.appendingPathComponent("gitleaks"), executable: true)
        let blocked = try ScriptFenceEval.run(
            hook, [], cwd: root, environment: ScriptFenceEval.environment(stubDir: stubs), timeout: 60)
        #expect(blocked.status != 0, Comment(rawValue: "a gitleaks hit did NOT block the commit:\n\(blocked.combined)"))
        #expect(blocked.stderr.contains("BLOCKED"), Comment(rawValue: blocked.combined))

        // 3. gitleaks present and clean: the hook must get out of the way.
        try ScriptFenceEval.write("#!/bin/bash\nexit 0\n",
                                  to: stubs.appendingPathComponent("gitleaks"), executable: true)
        let clean = try ScriptFenceEval.run(
            hook, [], cwd: root, environment: ScriptFenceEval.environment(stubDir: stubs), timeout: 60)
        #expect(clean.status == 0, Comment(rawValue: clean.combined))
        print("pre-commit eval: absent=exit 0 + loud warning, hit=exit \(blocked.status) BLOCKED, clean=exit 0")
    }

    /// scripts.hooks.preCommit.duplicatedTimerGuard — the staged-timer arm must
    /// actually reach `script/check_timer_inventory.swift` and must block on a
    /// non-zero result. (The hook carries the same guard block TWICE; that
    /// duplication is a production defect reported by this fence, so the eval
    /// pins the observable contract — it fires, and it blocks — and RECORDS the
    /// invocation count instead of blessing it.)
    @Test func preCommitTimerGuardFiresOnAStagedSleepAndBlocks() throws {
        let (root, stubs) = try makeHookRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        try ScriptFenceEval.write("#!/bin/bash\nexit 0\n",
                                  to: stubs.appendingPathComponent("gitleaks"), executable: true)
        let swiftLog = root.appendingPathComponent("timer-check.log")
        try ScriptFenceEval.write("""
        #!/bin/bash
        echo "$*" >> "\(swiftLog.path)"
        exit ${STUB_TIMER_EXIT:-0}
        """, to: stubs.appendingPathComponent("swift"), executable: true)
        try ScriptFenceEval.write("import Foundation\n", to: root.appendingPathComponent("Sources/Seed.swift"))
        let git = ScriptFenceEval.environment(stubDir: nil)
        _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "-C", root.path, "add", "-A"], environment: git, timeout: 30)
        _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "-C", root.path, "commit", "-q", "-m", "seed"], environment: git, timeout: 60)

        let hook = root.appendingPathComponent("script/hooks/pre-commit").path
        // A staged Swift change with no timer primitive must NOT invoke it.
        try ScriptFenceEval.write("import Foundation\nlet x = 1\n", to: root.appendingPathComponent("Sources/Seed.swift"))
        _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "-C", root.path, "add", "-A"], environment: git, timeout: 30)
        let quiet = try ScriptFenceEval.run(hook, [], cwd: root,
                                            environment: ScriptFenceEval.environment(stubDir: stubs), timeout: 60)
        #expect(quiet.status == 0, Comment(rawValue: quiet.combined))
        #expect(!FileManager.default.fileExists(atPath: swiftLog.path),
                "the timer inventory ran for a staged change with no timer primitive")

        // Now stage a real sleep: the guard must fire, and must block on failure.
        try ScriptFenceEval.write("import Foundation\nfunc f() async throws { try await Task.sleep(nanoseconds: 1) }\n",
                                  to: root.appendingPathComponent("Sources/Seed.swift"))
        _ = try ScriptFenceEval.run("/usr/bin/env", ["git", "-C", root.path, "add", "-A"], environment: git, timeout: 30)
        let passing = try ScriptFenceEval.run(hook, [], cwd: root,
                                              environment: ScriptFenceEval.environment(stubDir: stubs), timeout: 60)
        #expect(passing.status == 0, Comment(rawValue: passing.combined))
        let invocations = (try? String(contentsOf: swiftLog, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(invocations >= 1, "the staged Task.sleep never reached check_timer_inventory.swift")
        #expect((try? String(contentsOf: swiftLog, encoding: .utf8))?.contains("check_timer_inventory.swift") == true)
        print("pre-commit timer-guard eval: quiet change = 0 invocations, staged Task.sleep = \(invocations) invocation(s) of check_timer_inventory.swift (duplicated block in the hook: reported as a production seam)")

        let blocked = try ScriptFenceEval.run(
            hook, [], cwd: root,
            environment: ScriptFenceEval.environment(stubDir: stubs, extra: ["STUB_TIMER_EXIT": "1"]), timeout: 60)
        #expect(blocked.status != 0, Comment(rawValue: "an unclassified timer did NOT block the commit:\n\(blocked.combined)"))
        #expect(blocked.stderr.contains("classify the new timer"), Comment(rawValue: blocked.combined))
    }

    // MARK: - script/cleanup_disk_hygiene.sh (state lifecycle)

    /// scripts.cleanup_disk_hygiene — dry-run is the DEFAULT and the only thing
    /// between a routine hygiene run and permanent data loss. Assert the safety
    /// property, then prove the assertion is not vacuous by running the same
    /// fixture with `--delete --yes` and watching the same file disappear.
    @Test func diskHygieneDryRunDeletesNothingAndDeleteModeReallyDeletes() throws {
        let root = try ScriptFenceEval.makeTempDir("hygiene")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScriptFenceEval.copyScript("script/cleanup_disk_hygiene.sh", into: root)
        let oldRun = root.appendingPathComponent("data/runs/run-ancient")
        let freshRun = root.appendingPathComponent("data/runs/run-today")
        let oldWorktree = root.appendingPathComponent("data/self_worktrees/wt-ancient")
        for dir in [oldRun, freshRun, oldWorktree] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let ancient = Date().addingTimeInterval(-60 * 24 * 3600)
        for dir in [oldRun, oldWorktree] {
            try FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: dir.path)
        }
        let script = root.appendingPathComponent("script/cleanup_disk_hygiene.sh").path
        let env = ScriptFenceEval.environment(stubDir: nil)

        let dry = try ScriptFenceEval.run(script, [], cwd: root, environment: env, timeout: 120)
        #expect(dry.status == 0, Comment(rawValue: dry.combined))
        #expect(dry.stdout.contains("DRY-RUN (no changes)"), Comment(rawValue: dry.combined))
        #expect(dry.stdout.contains("DRY-RUN complete — nothing was deleted."), Comment(rawValue: dry.combined))
        for dir in [oldRun, freshRun, oldWorktree] {
            #expect(FileManager.default.fileExists(atPath: dir.path),
                    Comment(rawValue: "dry-run DELETED \(dir.lastPathComponent):\n\(dry.combined)"))
        }

        let destructive = try ScriptFenceEval.run(script, ["--delete", "--yes"], cwd: root, environment: env, timeout: 120)
        #expect(destructive.status == 0, Comment(rawValue: destructive.combined))
        #expect(destructive.stdout.contains("DELETE (destructive)"), Comment(rawValue: destructive.combined))
        #expect(!FileManager.default.fileExists(atPath: oldRun.path),
                Comment(rawValue: "--delete did not remove an aged run dir — the dry-run assertion above is vacuous:\n\(destructive.combined)"))
        #expect(!FileManager.default.fileExists(atPath: oldWorktree.path),
                Comment(rawValue: "--delete did not remove an aged worktree:\n\(destructive.combined)"))
        #expect(FileManager.default.fileExists(atPath: freshRun.path),
                Comment(rawValue: "--delete removed a run dir INSIDE the retention window:\n\(destructive.combined)"))
        print("disk-hygiene eval: dry-run kept 3/3 fixtures; --delete --yes removed 2 aged, kept 1 fresh")
    }
}
