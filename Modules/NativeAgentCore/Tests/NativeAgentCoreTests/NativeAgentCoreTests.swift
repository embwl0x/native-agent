import Foundation
import Testing
@testable import NativeAgentCore

@Test func nativeAgentPrimaryModel_isConfigured() {
    #expect(!nativeAgentPrimaryModel.isEmpty)
    #expect(nativeAgentPrimaryModel == "gpt-5.6-sol")
}

/// User, 2026-09-13: "All model selections should be taken care of at the picker;
/// how can any have to resolve to 5.5?" — so a retired model id has NO executable
/// literal at all. The migration sentinel that used to fold persisted `gpt-5.5`
/// picks onto the primary is gone with it: a pick the catalog no longer carries
/// simply stops being a pick, and the surface returns to its Providers group's
/// choice. Any occurrence here is a model chosen in code.
@Test func retiredModelIDsHaveNoExecutableLiteral() throws {
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
        // Every id this build has retired, not just the first one.
        let needles = ["\"gpt-5.5\"", "\"gpt-5.4\"", "\"gpt-5.4-mini\""]
        let codeOnly = txt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            .joined(separator: "\n")
        var count = 0
        for needle in needles {
            var search = codeOnly[...]
            while let r = search.range(of: needle) {
                count += 1
                search = search[r.upperBound...]
            }
        }
        if count > 0 {
            let rel = entry.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            hits.append((rel, count))
        }
    }
    let total = hits.reduce(0) { $0 + $1.count }
    #expect(total == 0, "a retired model id must not appear as an executable literal; found \(total) in \(hits)")
}
