import Foundation
import Testing
@testable import ChatOrchestration
@testable import NativeAgentApp

// THE KEEPER. docs/evals/ledger.json is the eval-of-the-evals: one row per
// observable surface. This test enumerates what can be enumerated MECHANICALLY
// (source modules, Mac/iOS screens, built-in tool names, @AppStorage keys,
// scripts) and fails when something exists with NO ledger row — the
// timer_inventory.tsv trick, generalized. A checked-in baseline
// (docs/evals/keeper-baseline.json) tolerates KNOWN gaps (reported, burned down
// like the instrument's reach walk); a NEW gap fails the build.
@Suite("EvalCoverageLedger")
struct EvalCoverageLedgerTests {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) && u.path != "/" { u.deleteLastPathComponent() }
        return u
    }()

    struct Ledger { let rows: [[String: Any]]; let haystack: String }
    static func loadLedger() throws -> Ledger {
        let data = try Data(contentsOf: repo.appendingPathComponent("docs/evals/ledger.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rows = obj["surfaces"] as? [[String: Any]] ?? []
        let hay = rows.map { "\($0["id"] ?? "") \($0["where"] ?? "")" }.joined(separator: "\n").lowercased()
        return Ledger(rows: rows, haystack: hay)
    }
    static func baseline() -> Set<String> {
        guard let d = try? Data(contentsOf: repo.appendingPathComponent("docs/evals/keeper-baseline.json")),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return Set(arr)
    }
    static func files(under rel: String, suffix: String) -> [String] {
        let root = repo.appendingPathComponent(rel)
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return e.compactMap { $0 as? String }.filter { $0.hasSuffix(suffix) && !$0.contains(".build/") }
    }

    /// Every enumerable surface must have a ledger row (by file path or name).
    /// Known gaps live in the baseline; a NEW gap fails.
    @Test func everyEnumerableSurfaceHasALedgerRow() throws {
        let ledger = try Self.loadLedger()
        #expect(ledger.rows.count > 1000, "ledger looks empty: \(ledger.rows.count) rows")
        var expected: [String] = []
        // 1. Core source modules (≥3 files)
        let coreRoot = Self.repo.appendingPathComponent("Modules/NativeAgentCore/Sources")
        for m in (try? FileManager.default.contentsOfDirectory(atPath: coreRoot.path)) ?? [] {
            let n = Self.files(under: "Modules/NativeAgentCore/Sources/\(m)", suffix: ".swift").count
            if n >= 3 { expected.append("module:Sources/\(m)/") }
        }
        // 2. Mac screens + 3. iOS screens
        for f in Self.files(under: "Sources/NativeAgentApp", suffix: "View.swift") { expected.append("screen:\(f.split(separator: "/").last!)") }
        for f in Self.files(under: "iOS/NativeAgentMobile", suffix: "View.swift") where !f.contains("Tests") { expected.append("screen:\(f.split(separator: "/").last!)") }
        // 4. Core and app-owned native tool names
        for t in SwiftToolDispatcher.reservedBuiltInNames { expected.append("tool:\(t)") }
        for t in AppChatToolDispatcher.catalogRegisteredToolNames { expected.append("tool:\(t)") }
        // 5. @AppStorage keys in the Mac app
        for f in Self.files(under: "Sources/NativeAgentApp", suffix: ".swift") {
            let text = (try? String(contentsOf: Self.repo.appendingPathComponent("Sources/NativeAgentApp/\(f)"), encoding: .utf8)) ?? ""
            var i = text.startIndex
            while let r = text.range(of: "@AppStorage(\"", range: i..<text.endIndex) {
                let rest = text[r.upperBound...]
                if let q = rest.firstIndex(of: "\"") { expected.append("setting:\(rest[..<q])") }
                i = r.upperBound
            }
        }
        // 6. scripts
        for f in (try? FileManager.default.contentsOfDirectory(atPath: Self.repo.appendingPathComponent("script").path)) ?? [] where f.hasSuffix(".sh") || f.hasSuffix(".swift") || f.hasSuffix(".py") {
            expected.append("script:\(f)")
        }
        func covered(_ key: String) -> Bool {
            let needle = key.split(separator: ":", maxSplits: 1).last.map(String.init)!.lowercased()
            return ledger.haystack.contains(needle)
        }
        let missing = expected.filter { !covered($0) }
        let baseline = Self.baseline()
        let newGaps = missing.filter { !baseline.contains($0) }
        let burned = baseline.filter { !missing.contains($0) }
        print("eval-coverage keeper: \(expected.count) enumerable surfaces, \(missing.count) without a ledger row (\(baseline.count) in baseline, \(newGaps.count) NEW, \(burned.count) burned down)")
        if !missing.isEmpty { print("  missing:\n    " + missing.sorted().joined(separator: "\n    ")) }
        #expect(newGaps.isEmpty, Comment(rawValue: "NEW surfaces with no ledger row — add a row to docs/evals/ledger.json (and an eval) or a dated entry in docs/evals/keeper-baseline.json:\n  " + newGaps.sorted().joined(separator: "\n  ")))
    }
}
