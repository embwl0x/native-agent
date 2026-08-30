import Foundation
import Testing

@Suite("scripts · eval ledger merge")
struct EvalLedgerMergeTests {
    private func fragment(
        id: String = "surface.one",
        kind: String = "public-api",
        where whereText: String = "Sources/One.swift:1",
        coverage: [[String: String]] = []
    ) -> [String: Any] {
        [
            "fence": "core.misc",
            "fragment": [
                "ranRun": "fixture",
                "uncertain": [],
                "surfaces": [[
                    "id": id,
                    "kind": kind,
                    "where": whereText,
                    "coverage": coverage,
                ]],
            ],
            "critic": ["missed": [], "disputed": []],
        ]
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func run(
        fragments: [Any],
        overrides: [[String: Any]]? = nil,
        campaigns: [[String: Any]]? = nil,
        campaignIDs: [String] = []
    ) throws -> (ScriptFenceEval.RunResult, [[String: Any]]) {
        let root = try ScriptFenceEval.makeTempDir("ledger-merge")
        let input = root.appendingPathComponent("fragments.json")
        let output = root.appendingPathComponent("out", isDirectory: true)
        try writeJSON(fragments, to: input)
        var arguments = [
            ScriptFenceEval.repo.appendingPathComponent("script/evals_ledger_merge.swift").path,
            input.path,
            "--out", output.path,
        ]
        if let overrides {
            let url = root.appendingPathComponent("overrides.json")
            try writeJSON(overrides, to: url)
            arguments += ["--overrides", url.path]
        }
        if let campaigns {
            let idsURL = root.appendingPathComponent("campaign-ids.json")
            try writeJSON(["surfaces": campaignIDs.map { ["fence": "core.misc", "id": $0] }], to: idsURL)
            let url = root.appendingPathComponent("campaigns.json")
            try writeJSON(campaigns, to: url)
            arguments += ["--campaigns", url.path]
        }
        let result = try ScriptFenceEval.run(
            "/usr/bin/env", ["swift"] + arguments,
            cwd: ScriptFenceEval.repo,
            environment: ScriptFenceEval.environment(stubDir: nil),
            timeout: 60
        )
        guard result.status == 0 else { return (result, []) }
        let data = try Data(contentsOf: output.appendingPathComponent("ledger.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (result, object?["surfaces"] as? [[String: Any]] ?? [])
    }

    @Test func missingStrengthNeverSilentlyMeansAsserting() throws {
        let (result, rows) = try run(fragments: [fragment(coverage: [[
            "tier": "test",
            "ref": "Tests/OneTests.swift:1",
        ]])])
        #expect(result.status == 0, Comment(rawValue: result.combined))
        #expect(rows.first?["status"] as? String == "REPORTS-ONLY")
    }

    @Test func malformedCoverageEntryFailsClosedInsteadOfDisappearing() throws {
        var malformed = fragment()
        var body = try #require(malformed["fragment"] as? [String: Any])
        var surfaces = try #require(body["surfaces"] as? [[String: Any]])
        surfaces[0]["coverage"] = [
            ["tier": "test", "ref": "Tests/RealTests.swift:1", "strength": "asserts"],
            "stale non-object evidence",
        ] as [Any]
        body["surfaces"] = surfaces
        malformed["fragment"] = body

        let (result, _) = try run(fragments: [malformed])
        #expect(result.status != 0)
        #expect(result.stderr.contains("coverage[1] must be an object"),
                Comment(rawValue: result.combined))
    }

    @Test func malformedFragmentAndSurfaceRowsFailClosedInsteadOfDisappearing() throws {
        let (badFragment, _) = try run(fragments: ["not an object"])
        #expect(badFragment.status != 0)
        #expect(badFragment.stderr.contains("fragment[0] must be an object"),
                Comment(rawValue: badFragment.combined))

        var malformed = fragment()
        var body = try #require(malformed["fragment"] as? [String: Any])
        body["surfaces"] = ["not a surface object"]
        malformed["fragment"] = body
        let (badSurface, _) = try run(fragments: [malformed])
        #expect(badSurface.status != 0)
        #expect(badSurface.stderr.contains("fragment.surfaces[0] must be an object"),
                Comment(rawValue: badSurface.combined))
    }

    @Test func duplicateInventoryKeepsBothDefinitionSites() throws {
        var second = fragment(where: "Sources/Two.swift:9", coverage: [[
            "tier": "test",
            "ref": "Tests/TwoTests.swift:4",
            "strength": "asserts",
        ]])
        second["fence"] = "core.misc"
        let secondSurfaces = (second["fragment"] as? [String: Any])?["surfaces"] as? [[String: Any]] ?? []
        let secondSurface = try #require(secondSurfaces.first)
        var one = fragment()
        var critic = one["critic"] as? [String: Any] ?? [:]
        critic["missed"] = [secondSurface]
        one["critic"] = critic

        let (result, rows) = try run(fragments: [one])
        #expect(result.status == 0, Comment(rawValue: result.combined))
        #expect(rows.count == 1)
        let location = rows.first?["where"] as? String ?? ""
        #expect(location.contains("Sources/One.swift:1"))
        #expect(location.contains("Sources/Two.swift:9"))
        #expect(rows.first?["status"] as? String == "COVERED")
    }

    @Test func overridesAreValidatedAndCanAddAnExplicitSurface() throws {
        let added: [String: Any] = [
            "fence": "core.misc",
            "id": "surface.added",
            "kind": "setting",
            "where": "Sources/Added.swift:2",
            "coverage": [[
                "tier": "test",
                "ref": "Tests/AddedTests.swift:3",
                "strength": "asserts",
            ]],
        ]
        let (green, rows) = try run(fragments: [fragment()], overrides: [added])
        #expect(green.status == 0, Comment(rawValue: green.combined))
        #expect(rows.map { $0["id"] as? String }.contains("surface.added"))

        var invalid = added
        invalid["kind"] = "made-up-kind"
        let (red, _) = try run(fragments: [fragment()], overrides: [invalid])
        #expect(red.status != 0)
        #expect(red.stderr.contains("unknown or missing kind"), Comment(rawValue: red.combined))
    }

    @Test func campaignsApplyOneReviewedEvaluatorToAFrozenIDSet() throws {
        let campaign: [String: Any] = [
            "name": "fixture-closure",
            "surfaceIDsFile": "campaign-ids.json",
            "coverage": [[
                "tier": "test",
                "ref": "Tests/TotalSurfaceContractTests.swift",
                "strength": "asserts",
            ]],
        ]
        let (green, rows) = try run(
            fragments: [fragment()], campaigns: [campaign], campaignIDs: ["surface.one"]
        )
        #expect(green.status == 0, Comment(rawValue: green.combined))
        #expect(rows.first?["status"] as? String == "COVERED")

        let (red, _) = try run(
            fragments: [fragment()], campaigns: [campaign], campaignIDs: ["surface.renamed"]
        )
        #expect(red.status != 0)
        #expect(red.stderr.contains("surface is missing"), Comment(rawValue: red.combined))
    }

    @Test func unchangedCanonicalInputsRenderByteIdenticalOutputs() throws {
        let root = try ScriptFenceEval.makeTempDir("ledger-determinism")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("fragments.json")
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try writeJSON([fragment(coverage: [[
            "tier": "test",
            "ref": "Tests/OneTests.swift:1",
            "strength": "asserts",
        ]])], to: input)
        func generate(_ output: URL) throws -> ScriptFenceEval.RunResult {
            try ScriptFenceEval.run(
                "/usr/bin/env", [
                    "swift",
                    ScriptFenceEval.repo.appendingPathComponent("script/evals_ledger_merge.swift").path,
                    input.path, "--out", output.path,
                ],
                cwd: ScriptFenceEval.repo,
                environment: ScriptFenceEval.environment(stubDir: nil),
                timeout: 60)
        }
        let firstRun = try generate(first)
        let secondRun = try generate(second)
        #expect(firstRun.status == 0, Comment(rawValue: firstRun.combined))
        #expect(secondRun.status == 0, Comment(rawValue: secondRun.combined))
        let firstLedger = try Data(contentsOf: first.appendingPathComponent("ledger.json"))
        let secondLedger = try Data(contentsOf: second.appendingPathComponent("ledger.json"))
        let firstCoverage = try Data(contentsOf: first.appendingPathComponent("COVERAGE.md"))
        let secondCoverage = try Data(contentsOf: second.appendingPathComponent("COVERAGE.md"))
        #expect(firstLedger == secondLedger)
        #expect(firstCoverage == secondCoverage)
        #expect(!firstCoverage.suffix(2).elementsEqual(Data("\n\n".utf8)),
                "generated coverage must not fail git diff --check with a blank line at EOF")
        let ledger = try #require(
            JSONSerialization.jsonObject(with: firstLedger) as? [String: Any])
        #expect(ledger["generatedAt"] == nil)
    }
}
