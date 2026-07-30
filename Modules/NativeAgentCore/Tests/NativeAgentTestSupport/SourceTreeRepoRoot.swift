import Foundation

/// Shared repo-root locator for source-scanning guard tests.
///
/// Several source-conformance guards (NoPythonRegressionTests,
/// LoopRunnerCatchOverrideGuardTests, and the shard-drift guard) walk up from
/// their own `#filePath` to the repo root — the directory that holds both
/// `Sources/` and `Modules/` — before scanning the tree. That walk was
/// copy-pasted per guard; this is the single implementation.
public enum SourceTreeRepoRoot {

    /// Walk up from `startingFrom` (default: the CALLER's source file) to the
    /// repo root containing both `Sources/` and `Modules/`. Guards pass their
    /// own `#filePath` implicitly so the walk starts from wherever the guard
    /// lives, regardless of the module layout.
    public static func locate(
        startingFrom filePath: String = #filePath
    ) throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Sources").path),
               fm.fileExists(atPath: dir.appendingPathComponent("Modules").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NSError(
            domain: "SourceTreeRepoRoot", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate repo root from \(filePath)"]
        )
    }
}
