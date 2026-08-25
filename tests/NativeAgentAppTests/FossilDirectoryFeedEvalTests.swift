import Foundation
import Testing

@Suite("fossil directory feed", .serialized)
struct FossilDirectoryFeedEvalTests {
    private let repo = ScriptFenceEval.repo

    @Test("separates long-dormant top-level data from uncovered recent writers")
    func separatesFossilsFromLiveDirectories() throws {
        let parent = try ScriptFenceEval.makeTempDir("fossil-directory-feed")
        defer { try? FileManager.default.removeItem(at: parent) }
        let data = parent.appendingPathComponent("data", isDirectory: true)
        let fossil = data.appendingPathComponent("living_fabric/old.json")
        let live = data.appendingPathComponent("new_uncovered_feed/current.json")
        try FileManager.default.createDirectory(at: fossil.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 17).write(to: fossil)
        try Data(repeating: 2, count: 23).write(to: live)
        let old = Date(timeIntervalSinceNow: -31 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fossil.path)

        let run = try ScriptFenceEval.run(
            "/usr/bin/env",
            ["swift", repo.appendingPathComponent("script/feed_coverage_eval.swift").path,
             "--data-root", data.path, "--days", "7", "--fossil-days", "30"],
            cwd: repo,
            environment: ScriptFenceEval.environment(stubDir: nil),
            timeout: 45
        )

        #expect(run.status == 0, Comment(rawValue: run.combined))
        #expect(run.stdout.contains("`feeds.fossil.dormant_directories` | **FOSSIL** | 2"))
        #expect(run.stdout.contains("## RETIRED/FOSSIL top-level directories"))
        #expect(run.stdout.contains("`living_fabric/` | 17 B"))
        #expect(run.stdout.contains("## UNCOVERED BUT LIVE top-level directories"))
        #expect(run.stdout.contains("`new_uncovered_feed/` | 23 B"))
    }
}
