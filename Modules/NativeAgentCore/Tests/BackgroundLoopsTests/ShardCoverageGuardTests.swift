import XCTest
import Foundation
import NativeAgentTestSupport

// Source-time guard against Swift-Testing SHARD DRIFT (tightness round 2,
// 2026-07-18). `script/test.sh` runs the NativeAgentCore Swift-Testing suites
// SHARDED by target name (CORE_SWIFT_TEST_SHARDS), because the swiftpm-testing
// helper SIGPIPEs when the whole 3k+ suite runs as one process. The shard list
// is hand-maintained — and when three targets (CognitiveSubstrateTests +478,
// GitHubConnectorTests +57, SlackConnectorTests +1) were added WITHOUT a shard
// entry, all 536 of their @Test functions were SILENTLY NEVER RUN in the gate.
// The XCTest pass excludes swift-testing (`--disable-xctest` on the shard side,
// `--disable-swift-testing` on the XCTest side), so a Swift-Testing target
// absent from every shard is covered by NOTHING.
//
// THIS guard makes that impossible to reship: it parses CORE_SWIFT_TEST_SHARDS
// out of script/test.sh, enumerates every Tests/<Target>/ directory that holds
// at least one `@Test` declaration, and asserts each such target appears in
// EXACTLY one shard. Add a new Swift-Testing target without a shard entry and
// this fails loud.
//
// WHY XCTest (not @Test): a @Test guard would itself be shard-gated — the very
// failure mode it guards against could hide it. XCTest runs in the UNFILTERED
// `swift test --disable-swift-testing` pass (script/test.sh:44, no `--filter`),
// so this guard runs regardless of the shard list. The guard that protects the
// shards must not depend on them.
final class ShardCoverageGuardTests: XCTestCase {

    func testEverySwiftTestingTargetIsInExactlyOneShard() throws {
        let root = try SourceTreeRepoRoot.locate()
        let testScript = root.appendingPathComponent("script/test.sh")
        let script = try String(contentsOf: testScript, encoding: .utf8)

        let shardTargets = try Self.parseShardTargets(from: script)
        XCTAssertGreaterThan(
            shardTargets.count, 20,
            "Parsed only \(shardTargets.count) shard targets from CORE_SWIFT_TEST_SHARDS — the parser likely went blind after a script edit; verify the array shape in script/test.sh."
        )

        let testsDir = root.appendingPathComponent("Modules/NativeAgentCore/Tests", isDirectory: true)
        let swiftTestingTargets = try Self.swiftTestingTargets(under: testsDir)
        XCTAssertFalse(
            swiftTestingTargets.isEmpty,
            "Found no Tests/<Target>/ directories containing an @Test — the scanner likely went blind; verify \(testsDir.path) still holds the Swift-Testing suites."
        )

        // (1) Every Swift-Testing target must live in exactly one shard.
        var missing: [String] = []
        var duplicated: [String] = []
        for target in swiftTestingTargets.sorted() {
            let count = shardTargets.filter { $0 == target }.count
            if count == 0 { missing.append(target) }
            else if count > 1 { duplicated.append("\(target) (\(count)×)") }
        }
        XCTAssertTrue(
            missing.isEmpty,
            """
            Swift-Testing target(s) with @Test suites are absent from every shard in \
            CORE_SWIFT_TEST_SHARDS (script/test.sh) — their tests would be SILENTLY \
            SKIPPED by the gate (the T-H1 regression). Add each to a shard entry: \
            \(missing)
            """
        )
        XCTAssertTrue(
            duplicated.isEmpty,
            "Target(s) listed in more than one shard (a target must be in exactly one): \(duplicated)"
        )

        // (2) Reverse drift: a shard entry naming a target directory that no
        // longer exists is a stale reference (typo or a removed target).
        let existingTargetDirs = try Self.testTargetDirectories(under: testsDir)
        let stale = Set(shardTargets).subtracting(existingTargetDirs).sorted()
        XCTAssertTrue(
            stale.isEmpty,
            "Shard entry references target(s) with no Tests/<Target>/ directory (stale after a rename/removal): \(stale)"
        )
    }

    // MARK: - script/test.sh parsing

    /// Flatten CORE_SWIFT_TEST_SHARDS into the multiset of target names it
    /// lists. Each array element is a quoted, `|`-separated group
    /// (`"ATests|BTests"`); comment lines carry no quotes and drop out.
    static func parseShardTargets(from script: String) throws -> [String] {
        guard let openRange = script.range(of: "CORE_SWIFT_TEST_SHARDS=(") else {
            throw GuardError("CORE_SWIFT_TEST_SHARDS=( not found in script/test.sh")
        }
        let afterOpen = script[openRange.upperBound...]
        // The array closes at the first line that is exactly `)` (trimmed).
        var body = ""
        for line in afterOpen.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == ")" { break }
            body += line + "\n"
        }
        // Extract every "double-quoted" group, then split on '|'.
        let quoted = try NSRegularExpression(pattern: "\"([^\"]*)\"")
        let ns = body as NSString
        var targets: [String] = []
        for m in quoted.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let group = ns.substring(with: m.range(at: 1))
            for name in group.split(separator: "|") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { targets.append(trimmed) }
            }
        }
        return targets
    }

    // MARK: - Tests-tree enumeration

    /// Immediate subdirectory names of Tests/ that are test targets (suffix
    /// `Tests`). Excludes the TestSupport helper targets.
    static func testTargetDirectories(under testsDir: URL) throws -> Set<String> {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        var names: Set<String> = []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir, url.lastPathComponent.hasSuffix("Tests") {
                names.insert(url.lastPathComponent)
            }
        }
        return names
    }

    /// Test target directories that contain at least one `@Test` declaration.
    static func swiftTestingTargets(under testsDir: URL) throws -> Set<String> {
        let fm = FileManager.default
        var result: Set<String> = []
        for target in try testTargetDirectories(under: testsDir) {
            let dir = testsDir.appendingPathComponent(target, isDirectory: true)
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            var hasTest = false
            for case let url as URL in walker where url.pathExtension == "swift" {
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.containsTestAttribute(raw) {
                    hasTest = true
                    break
                }
            }
            if hasTest { result.insert(target) }
        }
        return result
    }

    /// True if `source` uses the Swift-Testing `@Test` attribute, ignoring
    /// `//` line comments (so a comment merely mentioning @Test doesn't count).
    static func containsTestAttribute(_ source: String) -> Bool {
        for line in source.components(separatedBy: "\n") {
            let code: Substring
            if let commentStart = line.range(of: "//") {
                code = line[line.startIndex..<commentStart.lowerBound]
            } else {
                code = line[...]
            }
            if code.range(of: #"(^|\s)@Test\b"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    struct GuardError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
