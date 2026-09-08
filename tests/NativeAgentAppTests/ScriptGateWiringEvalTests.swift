import Foundation
import Testing

/// `scripts` fence — WIRING evals.
///
/// Ledger rows covered here: scripts.test.orphanSuiteGuard,
/// scripts.test.nodeSuiteGlob, scripts.guardSuites.orphaned, scripts.evals,
/// scripts.evals.step.ledgerKeeper, scripts.evals.boomExcerpt,
/// scripts.smoke_all, scripts.releaseLane.gateReachability.
///
/// The shared silent-failure class is DROPPED ROW: one script names a target in
/// another file (a suite, a `--filter`, a check script, an awk marker) and the
/// target moves. Nothing in the repo re-checks the name, so the gate keeps
/// printing ✔ while covering nothing. Each eval below pairs the live-repo
/// assertion with a fixture NEGATIVE CONTROL proving the detector bites.
@Suite("ScriptGateWiringEval")
struct ScriptGateWiringEvalTests {

    // MARK: - scripts.test.orphanSuiteGuard

    /// The canonical checker requires actual command-shaped invocations;
    /// comments and echoed paths cannot make an orphan look covered.
    static func orphanSuites(scriptsDirListing: [String], testShellSource: String) -> [String] {
        let commands = testShellSource.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^gate_spawn [A-Za-z0-9_-]+ "#, with: "", options: .regularExpression)
        }
        return scriptsDirListing.filter { name in
            !commands.contains { line in
                line.hasPrefix("\"$ROOT/tests/scripts/\(name)\"")
                    || line.hasPrefix("bash \"$ROOT/tests/scripts/\(name)\"")
            }
        }.sorted()
    }

    @Test func everyGuardSuiteIsInvokedByTheCanonicalGate() throws {
        let suites = ScriptFenceEval.names(in: "tests/scripts", suffix: ".sh")
        let testShell = try ScriptFenceEval.text("script/test.sh")
        #expect(suites.count >= 10, "tests/scripts looks empty: \(suites.count) suites")
        let orphans = Self.orphanSuites(scriptsDirListing: suites, testShellSource: testShell)
        #expect(orphans.isEmpty, Comment(rawValue: "Orphaned guard suite(s) — wire them into script/test.sh: \(orphans.joined(separator: ", "))"))
    }

    /// NEGATIVE CONTROL for the eval above: on a synthetic listing where one
    /// suite is deliberately unwired, the detector must name exactly that one.
    @Test func orphanSuiteDetectorNamesTheUnwiredSuite() {
        let listing = ["alpha_test.sh", "beta_test.sh", "gamma_test.sh"]
        let wired = """
        "$ROOT/tests/scripts/alpha_test.sh"
        gate_spawn gamma "$ROOT/tests/scripts/gamma_test.sh"
        """
        #expect(Self.orphanSuites(scriptsDirListing: listing, testShellSource: wired) == ["beta_test.sh"])
        // And it must not manufacture orphans when everything is wired.
        let allWired = wired + "\n\"$ROOT/tests/scripts/beta_test.sh\"\n"
        #expect(Self.orphanSuites(scriptsDirListing: listing, testShellSource: allWired).isEmpty)
        let commentOnly = wired + "\n# \"$ROOT/tests/scripts/beta_test.sh\"\necho \"tests/scripts/beta_test.sh\"\n"
        #expect(Self.orphanSuites(scriptsDirListing: listing, testShellSource: commentOnly) == ["beta_test.sh"])
    }

    /// Pin both the checker invocation and its executable behavior, rather
    /// than the old inline loop's diagnostic text after owner extraction.
    @Test func canonicalGateStillCarriesTheOrphanGuardLoop() throws {
        let testShell = try ScriptFenceEval.text("script/test.sh")
        #expect(testShell.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == #""$ROOT/script/check_canonical_test_wiring.sh" "$ROOT" "${BASH_SOURCE[0]}""#
        }, "canonical gate must invoke its script-wiring checker")
        let result = try ScriptFenceEval.run(
            ScriptFenceEval.repo.appendingPathComponent("tests/scripts/canonical_test_wiring_guards_test.sh").path,
            [], environment: ScriptFenceEval.environment(stubDir: nil), timeout: 30)
        #expect(!result.timedOut && result.status == 0, Comment(rawValue: result.combined))
    }

    // MARK: - scripts.test.nodeSuiteGlob / scripts.guardSuites.orphaned

    /// Node suites use a glob; deterministic shell suites have exact commands.
    /// Standalone mechanism demonstrations are not product regression proof.
    static func unrunnableScriptTestsSuites(listing: [String], testShellSource: String) -> [String] {
        listing.filter { name in
            guard let dot = name.range(of: ".", options: .backwards) else { return true }
            let ext = String(name[dot.lowerBound...])           // ".js" / ".sh" / ".swift"
            let byName = testShellSource.contains("script/tests/\(name)")
            let byGlob = testShellSource.contains("script/tests/*\(ext)")
                || testShellSource.contains("script/tests/*.test\(ext)")
            return !(byName || byGlob)
        }.sorted()
    }

    /// Explicit diagnostic-only exception: this standalone script compares a
    /// historical broken pipe mechanism with a replacement, not shipped code.
    /// The canonical Node suites pin the shipped SystemProcessAdapter wiring.
    /// ios_release.test.sh joined the canonical gate on 2026-08-30.
    static let knownUnrunnableScriptTests: Set<String> = [
        "codex_wakeup_helper_pipe.test.swift",
    ]

    @Test func everyScriptTestsSuiteHasARunner() throws {
        let listing = ScriptFenceEval.names(in: "script/tests", suffix: "")
            .filter { $0.contains(".test.") }
        let testShell = try ScriptFenceEval.text("script/test.sh")
        #expect(listing.count >= 5, "script/tests looks empty: \(listing.count) suites")
        let unrunnable = Self.unrunnableScriptTestsSuites(listing: listing, testShellSource: testShell)
        let newOnes = unrunnable.filter { !Self.knownUnrunnableScriptTests.contains($0) }
        print("script/tests runner eval: \(listing.count) suites, \(unrunnable.count) invoked by nothing (\(newOnes.count) NEW) — \(unrunnable.joined(separator: ", "))")
        #expect(newOnes.isEmpty, Comment(rawValue: "script/tests suite(s) with no runner: \(newOnes.joined(separator: ", "))"))
    }

    /// NEGATIVE CONTROL: the glob credit must be extension-specific, or the
    /// `.test.js` loop would silently vouch for a `.test.sh` sibling.
    @Test func scriptTestsRunnerDetectorDoesNotCreditTheWrongGlob() {
        let listing = ["a.test.js", "b.test.sh", "c.test.swift"]
        let onlyJSLoop = "for suite in \"$ROOT\"/script/tests/*.test.js; do node --test \"$suite\"; done"
        #expect(Self.unrunnableScriptTestsSuites(listing: listing, testShellSource: onlyJSLoop)
                == ["b.test.sh", "c.test.swift"])
        let bothLoops = onlyJSLoop + "\nfor s in \"$ROOT\"/script/tests/*.test.sh; do bash \"$s\"; done\n"
        #expect(Self.unrunnableScriptTestsSuites(listing: listing, testShellSource: bothLoops)
                == ["c.test.swift"])
    }

    // MARK: - scripts.evals + scripts.evals.step.ledgerKeeper

    /// One `step` line. `scriptTargets` are repo-relative paths the step names;
    /// `directlyInvoked` are the subset run as the command word (those must be
    /// executable — a target passed as an ARGUMENT, e.g. `swift foo.swift`,
    /// only has to exist).
    struct EvalsStep {
        var name: String
        var scriptTargets: [String]
        var directlyInvoked: Set<String>
        var filters: [String]
    }

    /// Parse every `step <name> ...` invocation out of script/evals.sh. Each
    /// step names either a script (via "$ROOT/script/...") or a
    /// `swift test --filter <pattern>`; a step whose target has been renamed
    /// can only ever print ✘, and evals.sh swallows its output into a log.
    static func parseEvalsSteps(_ source: String) -> [EvalsStep] {
        var steps: [EvalsStep] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let stepRange = line.range(of: "step ") else { continue }
            if line.hasPrefix("step()") || line.hasPrefix("#") { continue }
            let tail = String(line[stepRange.upperBound...])
            let fields = tail.split(separator: " ").map(String.init)
            guard let name = fields.first, !name.isEmpty else { continue }
            var scripts: [String] = []
            var direct: Set<String> = []
            var filters: [String] = []
            var index = 1 // field 0 is the step name; the command word is field 1.
            while index < fields.count {
                let field = fields[index]
                if field.contains("$ROOT/script/") {
                    let cleaned = field.replacingOccurrences(of: "\"", with: "")
                    if let r = cleaned.range(of: "$ROOT/") {
                        let rel = String(cleaned[r.upperBound...])
                        scripts.append(rel)
                        if index == 1 { direct.insert(rel) }
                    }
                }
                if field == "--filter", index + 1 < fields.count {
                    filters.append(fields[index + 1].replacingOccurrences(of: "\"", with: ""))
                }
                index += 1
            }
            steps.append(EvalsStep(name: name, scriptTargets: scripts, directlyInvoked: direct, filters: filters))
        }
        return steps
    }

    /// A `--filter` pattern resolves when some test source declares a matching
    /// suite or test symbol. Swift Testing matches against `Suite/testName`, so
    /// accept a hit in an `@Suite("…")`, a `struct …Tests`, or a `func …`.
    static func filterResolves(_ pattern: String, in sources: [String]) -> Bool {
        sources.contains { text in
            text.contains("@Suite(\"\(pattern)") || text.contains("struct \(pattern)")
                || text.contains("func \(pattern)")
        }
    }

    static func allTestSources() -> [String] {
        var texts: [String] = []
        for root in ["tests", "Modules/NativeAgentCore/Tests", "Modules/NativeAgentShared/Tests"] {
            let base = ScriptFenceEval.repo.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let rel as String in e where rel.hasSuffix(".swift") {
                if let t = try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8) {
                    texts.append(t)
                }
            }
        }
        return texts
    }

    @Test func everyEvalsStepTargetStillResolves() throws {
        let source = try ScriptFenceEval.text("script/evals.sh")
        let steps = Self.parseEvalsSteps(source)
        #expect(steps.count >= 5, "script/evals.sh parsed to \(steps.count) steps — the parser or the script moved")
        let sources = Self.allTestSources()
        #expect(sources.count > 100, "test-source sweep found only \(sources.count) files")

        var dead: [String] = []
        for step in steps {
            for target in step.scriptTargets {
                let url = ScriptFenceEval.repo.appendingPathComponent(target)
                if !FileManager.default.fileExists(atPath: url.path) {
                    dead.append("\(step.name): missing \(target)")
                } else if step.directlyInvoked.contains(target),
                          !FileManager.default.isExecutableFile(atPath: url.path) {
                    dead.append("\(step.name): \(target) is invoked directly but is not executable")
                }
            }
            for filter in step.filters where !Self.filterResolves(filter, in: sources) {
                dead.append("\(step.name): --filter \(filter) matches no test symbol")
            }
        }
        print("evals.sh step eval: \(steps.count) steps — " + steps.map {
            "\($0.name)[\($0.scriptTargets.count) script, \($0.filters.count) filter]"
        }.joined(separator: " "))
        #expect(dead.isEmpty, Comment(rawValue: "dead step target(s) in the 2-minute check:\n  " + dead.joined(separator: "\n  ")))
    }

    /// NEGATIVE CONTROL: a renamed keeper filter (the exact
    /// scripts.evals.step.ledgerKeeper failure mode) must not resolve.
    @Test func evalsFilterResolverBitesOnARenamedSuite() {
        let sources = ["@Suite(\"EvalCoverageLedger\")\nstruct EvalCoverageLedgerTests {}"]
        #expect(Self.filterResolves("EvalCoverageLedger", in: sources))
        #expect(!Self.filterResolves("EvalCoverageLedgerRenamed", in: sources))
        // …and the parser must actually find that filter in the real line shape.
        let line = #"step ledger-keeper      swift test --package-path "$ROOT" --filter "EvalCoverageLedger""#
        #expect(Self.parseEvalsSteps(line).first?.filters == ["EvalCoverageLedger"])
        // The direct-invocation distinction is load-bearing: a script run as the
        // command word must be executable, one passed as an argument need only
        // exist. Get that backwards and the eval either false-alarms or blinds.
        let direct = #"step smoke              "$ROOT/script/smoke_all.sh""#
        #expect(Self.parseEvalsSteps(direct).first?.directlyInvoked == ["script/smoke_all.sh"])
        let argument = #"step instrument         swift "$ROOT/script/agent_instrument.swift" --days 7"#
        let parsed = Self.parseEvalsSteps(argument).first
        #expect(parsed?.scriptTargets == ["script/agent_instrument.swift"])
        #expect(parsed?.directlyInvoked.isEmpty == true)
    }

    // MARK: - scripts.evals.boomExcerpt

    /// script/evals.sh:25 slices the instrument report with
    /// `awk '/^\*\*Health\*\*/{p=1} p&&NR<400'`. If the instrument renames that
    /// line, the one-screen summary silently becomes EMPTY and the run still
    /// reports success. Pin the marker at BOTH ends: the instrument still emits
    /// it, and the awk still selects on it.
    @Test func boomExcerptMarkerIsStillEmittedByTheInstrument() throws {
        let evals = try ScriptFenceEval.text("script/evals.sh")
        #expect(evals.contains(#"/^\*\*Health\*\*/"#),
                "evals.sh no longer anchors the BOOM excerpt on the **Health** marker")
        let instrument = try ScriptFenceEval.text("script/agent_instrument.swift")
        #expect(instrument.contains(#"line("**Health**"#),
                "script/agent_instrument.swift no longer emits a line starting with **Health** — the BOOM excerpt would render empty")
    }

    // MARK: - scripts.smoke_all

    /// Every check script smoke_all.sh names must exist and be executable.
    /// `set -euo pipefail` makes a missing one loud when someone runs it — but
    /// nothing runs smoke_all except evals.sh, which swallows its output.
    @Test func everySmokeCheckScriptExistsAndIsExecutable() throws {
        let source = try ScriptFenceEval.text("script/smoke_all.sh")
        var targets: Set<String> = []
        for match in source.components(separatedBy: "$ROOT/").dropFirst() {
            let token = match.prefix { !" \"'\n\t".contains($0) }
            let path = String(token)
            if path.hasSuffix(".sh") || path.hasSuffix(".swift") { targets.insert(path) }
        }
        #expect(targets.count >= 4, "smoke_all.sh named only \(targets.count) script targets")
        var broken: [String] = []
        for target in targets.sorted() {
            let url = ScriptFenceEval.repo.appendingPathComponent(target)
            if !FileManager.default.isExecutableFile(atPath: url.path) { broken.append(target) }
        }
        print("smoke_all eval: \(targets.count) script targets — \(targets.sorted().joined(separator: ", "))")
        #expect(broken.isEmpty, Comment(rawValue: "smoke_all.sh names missing/non-executable script(s): \(broken.joined(separator: ", "))"))
    }

    // MARK: - scripts.releaseLane.gateReachability

    /// Dated exemption (2026-08-23): check_tracked_privacy.sh is a release-lane
    /// gate that the 2-minute check deliberately does not run. Every OTHER
    /// `script/check_*` gate in the canonical gate must also be in the always-on
    /// path, or a gate silently becomes release-only.
    // Canonical command-wiring validates this larger gate's assembly, not the
    // runtime smoke's health. Its real negative controls run above and in the
    // canonical shell lane; the runtime smoke need not execute that lane.
    static let checkGatesExemptFromTheTwoMinuteCheck: Set<String> = [
        "script/check_tracked_privacy.sh", "script/check_canonical_test_wiring.sh",
    ]

    @Test func everyCanonicalCheckGateIsReachableFromTheTwoMinuteCheck() throws {
        let testShell = try ScriptFenceEval.text("script/test.sh")
        let smoke = try ScriptFenceEval.text("script/smoke_all.sh")
        let evals = try ScriptFenceEval.text("script/evals.sh")
        let alwaysOn = smoke + "\n" + evals

        var canonical: Set<String> = []
        for candidate in ScriptFenceEval.names(in: "script", suffix: ".sh")
            + ScriptFenceEval.names(in: "script", suffix: ".swift") {
            guard candidate.hasPrefix("check_") else { continue }
            if testShell.contains("script/\(candidate)") { canonical.insert("script/\(candidate)") }
        }
        #expect(canonical.count >= 3, "found only \(canonical.count) check_* gates in script/test.sh")

        let unreachable = canonical
            .filter { !alwaysOn.contains($0) && !Self.checkGatesExemptFromTheTwoMinuteCheck.contains($0) }
            .sorted()
        print("gate-reachability eval: \(canonical.count) check_* gates in the canonical gate, \(Self.checkGatesExemptFromTheTwoMinuteCheck.count) dated-exempt, \(unreachable.count) unreachable from script/evals.sh")
        #expect(unreachable.isEmpty, Comment(rawValue: "check gate(s) in script/test.sh that the 2-minute check never runs and that are not dated-exempt: \(unreachable.joined(separator: ", "))"))
    }
}
