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
@Suite("ScriptGateBehaviorEval", .serialized)
struct ScriptGateBehaviorEvalTests {

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
        try ScriptFenceEval.write("print(3)\n", to: root.appendingPathComponent("Modules/Core/.build/ignored.py"))
        try ScriptFenceEval.write("print(4)\n", to: root.appendingPathComponent("tests/a2a_sdk/peer.py"))
        #expect(try scan(block, root.path) == ["script/planted.py"], "the guard stopped pruning .build")
        try ScriptFenceEval.write("print(5)\n", to: root.appendingPathComponent("Modules/Core/Sources/planted.py"))
        #expect(try scan(enumerating, root.path) == ["Modules/Core/Sources/planted.py", "script/planted.py"],
                "test fixtures and build exclusions must not hide runtime Python")

        // Any tracked .py in the working tree fails this check.
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

    /// The staged-timer arm runs the inventory once and blocks on failure.
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
        #expect(invocations == 1, "the staged sleep must run check_timer_inventory.swift once")
        #expect((try? String(contentsOf: swiftLog, encoding: .utf8))?.contains("check_timer_inventory.swift") == true)
        print("pre-commit timer-guard eval: quiet change = 0 invocations, staged sleep = \(invocations) invocation of check_timer_inventory.swift")

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
