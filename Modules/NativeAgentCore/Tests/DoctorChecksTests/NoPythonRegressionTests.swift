import Testing
import Foundation
import NativeAgentTestSupport

// Build-time guard for the zero-Python Swift-runtime mandate (2026-06-13).
// Retired daemon source was removed 2026-06-02 and every helper script has
// been ported to Swift. The retired task-ledger helper's cwd-vs-repo data-root drift
// (silently splitting the cross-agent ledger) is exactly the regression class
// this guard exists to make IMPOSSIBLE to ship quietly.
//
// The Doctor stray-daemon check already fails loud at RUNTIME if a Python
// native_agentd is running. This is the SOURCE-time twin: if Claude or codex
// ever reintroduces a `.py` into the project-owned source tree, the test sweep
// turns red immediately instead of letting a Python/Swift split rot in.
//
// SCOPE: project-owned source only (daemon/, Sources/, Modules/, script/).
// User-authored runtime state under data/ is outside this source-tree test.
@Suite("NoPythonRegression")
struct NoPythonRegressionTests {

    @Test func noPythonFilesInProjectSourceTree() throws {
        let root = try SourceTreeRepoRoot.locate()
        let fm = FileManager.default
        let ownedDirs = ["daemon", "Sources", "Modules", "script"]
        var offenders: [String] = []

        for dir in ownedDirs {
            let base = root.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }
            guard let walker = fm.enumerator(
                at: base,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker {
                // Prune build/VCS/dependency trees — those aren't our source and
                // a vendored dep may legitimately carry .py.
                if url.lastPathComponent == ".build" || url.lastPathComponent == ".git"
                    || url.lastPathComponent == "node_modules" {
                    walker.skipDescendants()
                    continue
                }
                if url.pathExtension == "py" {
                    offenders.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "Python re-entered the project source tree — the Swift runtime must stay zero-Python. Port to Swift; do not add .py. Offenders: \(offenders.sorted())"
        )

        // The retired daemon source directory itself must never resurrect.
        #expect(
            !fm.fileExists(atPath: root.appendingPathComponent("daemon").path),
            "daemon/ resurrected — retired daemon source was removed 2026-06-02"
        )
    }

    // Repo-root walk lives in NativeAgentTestSupport.SourceTreeRepoRoot (shared
    // with the LoopRunner and shard-drift guards).
}
