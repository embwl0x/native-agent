import Foundation
import Testing
@testable import NativeAgentCore

@Test func nativeAgentPrimaryModel_isConfigured() {
    #expect(!nativeAgentPrimaryModel.isEmpty)
    #expect(nativeAgentPrimaryModel == "gpt-5.6-sol")
}

/// GPT-5.5 is retired from execution and catalogs. Its only executable literal
/// is the shared routing migration sentinel that upgrades persisted picks to
/// GPT-5.6 Sol. Any second occurrence is a new downgrade path.
@Test func retiredGPT55_isOnlyTheSharedMigrationSentinel() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourcesDir = repoRoot
        .appendingPathComponent("Modules")
        .appendingPathComponent("NativeAgentCore")
        .appendingPathComponent("Sources")
    let enumerator = FileManager.default.enumerator(
        at: sourcesDir,
        includingPropertiesForKeys: [.isRegularFileKey]
    )
    var hits: [(file: String, count: Int)] = []
    while let entry = enumerator?.nextObject() as? URL {
        guard entry.pathExtension == "swift" else { continue }
        guard let txt = try? String(contentsOf: entry, encoding: .utf8) else { continue }
        let needle = "\"gpt-5.5\""
        let codeOnly = txt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            .joined(separator: "\n")
        var search = codeOnly[...]
        var count = 0
        while let r = search.range(of: needle) {
            count += 1
            search = search[r.upperBound...]
        }
        if count > 0 {
            let rel = entry.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            hits.append((rel, count))
        }
    }
    let total = hits.reduce(0) { $0 + $1.count }
    #expect(total == 1, "expected exactly one GPT-5.5 migration sentinel; found \(total) in \(hits)")
    #expect(hits.first?.file.hasSuffix("ProviderRouting/ProviderRouting.swift") == true,
            "the lone GPT-5.5 literal must be the shared routing migration sentinel; found: \(hits)")
}
