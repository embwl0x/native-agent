import Foundation
import Testing

/// `scripts` fence — WIRING evals.
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

    // MARK: - scripts.smoke_all

    /// Every check script smoke_all.sh names must exist and be executable.
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

}
