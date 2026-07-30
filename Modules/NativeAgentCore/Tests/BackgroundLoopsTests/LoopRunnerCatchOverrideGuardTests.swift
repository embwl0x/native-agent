import Testing
import Foundation
import NativeAgentTestSupport

// Source-time guard for the LoopRunner honest-outcome contract (audit F2;
// re-framed for the C7 primary-method flip, 2026-07-17).
//
// POST-FLIP INVARIANT: `LoopRunner.tickOutcome()` is now the PRIMARY protocol
// requirement with NO default; `tick()` is the defaulted fire-and-forget
// wrapper (`_ = await tickOutcome()`). Because tickOutcome has no default, the
// COMPILER now forces every loop to implement it — a loop can no longer
// silently inherit a `.completed`-returning default and swallow a caught error.
//
// This guard is the SOURCE-time backstop for that structural guarantee: it
// asserts every LoopRunner conformer defines its own `tickOutcome()`. Its value
// is regression insurance — if a future refactor reintroduces a default
// `tickOutcome()` in an `extension LoopRunner` (re-opening the swallow), the
// compiler would STOP enforcing per-loop overrides and a loop could quietly
// rely on the default again. This test fails loud the moment any conformer
// lacks its own tickOutcome, whether or not a default exists — so the honest-
// outcome method is proven present on every loop, not merely assumed.
//
// This mirrors NoPythonRegressionTests: a whole-source-tree sweep, zero runtime
// cost, fails loud the moment the invariant is violated instead of letting the
// rot land silently. It reads Swift source directly (no module dependency on
// the app target) so it covers loops wherever they live — the core
// BackgroundLoops framework AND the app-side assembly loops.
//
// GUARD SHAPE — why source-scan over runtime enumeration: "does this loop
// declare its own tickOutcome" is a property of the SOURCE. A source-
// conformance test is the cheapest reliable guard, and the repo already has
// precedent for exactly this pattern.
//
// FALSE-POSITIVE posture: the scan aggregates a loop's main declaration PLUS
// every `extension TypeName` block across ALL scanned files (a conformance can
// be declared on an extension while the body lives on the main type, or vice
// versa), then requires `func tickOutcome` to appear somewhere in that
// aggregate. The protocol default-impl extensions themselves (`LoopRunner`,
// `EventDeadlineLoopRunner`) are excluded — they are not conformers.
@Suite("LoopRunnerCatchOverrideGuard")
struct LoopRunnerCatchOverrideGuardTests {

    @Test func everyLoopMustImplementTickOutcome() throws {
        let root = try SourceTreeRepoRoot.locate()
        let fm = FileManager.default

        // Source trees only — never Tests (mock loops there may intentionally
        // catch-and-report for a fixture) and never build/VCS/dependency trees.
        let scanRoots = ["Sources", "Modules"]
        // Cross-file aggregation (review round 2): a loop's `catch` can live in
        // `extension Foo` in ANOTHER file (TelegramPollLoop+Approvals.swift is
        // the live example), and its conformance can be declared on an
        // extension while the body lives on the main type. So: collect every
        // type/extension block in the tree keyed by type name, mark which
        // names conform to a LoopRunner protocol, then judge each conforming
        // name over its aggregated blocks.
        var blocksByName: [String: [Self.DeclBlock]] = [:]
        var loopNames: Set<String> = []

        for dir in scanRoots {
            let base = root.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }
            guard let walker = fm.enumerator(
                at: base,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in walker {
                let name = url.lastPathComponent
                if name == ".build" || name == ".git" || name == "node_modules" || name == "Tests" {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }

                let raw = try String(contentsOf: url, encoding: .utf8)
                let sanitized = Self.stripCommentsAndStrings(raw)
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")

                for block in Self.declBlocks(in: sanitized, file: rel) {
                    blocksByName[block.name, default: []].append(block)
                    if block.conformsToLoopRunner {
                        loopNames.insert(block.name)
                    }
                }
            }
        }

        // The protocols themselves (and their default-impl extensions) are not
        // conformers — `extension LoopRunner` legitimately defines the default
        // tickOutcome and must not count as a scanned loop.
        loopNames.remove("LoopRunner")
        loopNames.remove("EventDeadlineLoopRunner")

        var offenders: [String] = []
        for loopName in loopNames {
            let blocks = blocksByName[loopName] ?? []
            let implementsTickOutcome = blocks.contains {
                $0.body.range(of: #"\bfunc\s+tickOutcome\b"#, options: .regularExpression) != nil
            }
            if !implementsTickOutcome {
                let files = Set(blocks.map(\.file)).sorted().joined(separator: ", ")
                offenders.append("\(loopName) (\(files))")
            }
        }

        // Sanity: the scanner must actually be finding loop types. 25 concrete
        // conformers exist at time of writing (2026-07-17, counted in review
        // round 2 — 18 direct LoopRunner + 7 EventDeadlineLoopRunner). If a
        // refactor drops detection below 20 the guard has likely gone blind
        // and would pass vacuously — fail instead of shrinking silently.
        #expect(
            loopNames.count >= 20,
            "LoopRunner catch/override guard found only \(loopNames.count) conformer(s) (25 existed 2026-07-17) — scanner likely went blind after a refactor; verify header detection still matches how loops declare conformance. Found: \(loopNames.sorted())"
        )

        #expect(
            offenders.isEmpty,
            """
            LoopRunner honest-outcome contract violated. These loop types do NOT \
            declare their own tickOutcome(), so they can only be relying on a \
            (reintroduced) default that would report .completed to the scheduler \
            regardless of what actually happened. Implement tickOutcome() on each \
            loop and return the honest LoopTickOutcome (.completed / .skipped / \
            .failed). Offenders: \(offenders.sorted())
            """
        )
    }

    // MARK: - Source scanning

    struct DeclBlock {
        let name: String
        let body: String
        let file: String
        let conformsToLoopRunner: Bool
    }

    /// Find EVERY type declaration and extension (class/actor/struct/enum/
    /// extension) and return each one's balanced `{...}` body plus whether its
    /// header names a LoopRunner protocol. Conformance matching is
    /// SUFFIX-tolerant (`LoopRunner\b`, no leading boundary) so
    /// `EventDeadlineLoopRunner` conformers are seen — the round-1 `\b`-both-
    /// sides pattern silently missed all 7 of them (review round 2, HIGH).
    /// Excludes `protocol` decls (the requirement itself legitimately has no
    /// override) by only listing concrete keywords. Input MUST be
    /// comment/string-sanitized so brace matching is reliable.
    static func declBlocks(in source: String, file: String) -> [DeclBlock] {
        var result: [DeclBlock] = []
        let chars = Array(source)
        // Header: a decl keyword, then anything up to the type's own opening
        // brace that is NOT itself a brace. The header span (name → brace)
        // carries the conformance list when one is declared inline.
        let header = try! NSRegularExpression(
            pattern: #"\b(?:final\s+class|class|actor|struct|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)([^{}]*?)\{"#
        )
        let conformance = try! NSRegularExpression(pattern: #"LoopRunner\b"#)
        let ns = source as NSString
        for m in header.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let typeName = ns.substring(with: m.range(at: 1))
            let headerTail = ns.substring(with: m.range(at: 2))
            let conforms = conformance.firstMatch(
                in: headerTail,
                range: NSRange(location: 0, length: (headerTail as NSString).length)
            ) != nil
            // The regex ends at the opening brace; walk from there to its match.
            let openBrace = m.range.location + m.range.length - 1
            if let body = balancedBraceBody(chars, openBraceIndex: openBrace) {
                result.append(DeclBlock(
                    name: typeName,
                    body: body,
                    file: file,
                    conformsToLoopRunner: conforms
                ))
            }
        }
        return result
    }

    /// Given the index of an opening `{` in `chars`, return the substring
    /// between it and its matching close brace (exclusive of the braces), or nil
    /// if unbalanced. Assumes comments/strings already stripped.
    static func balancedBraceBody(_ chars: [Character], openBraceIndex: Int) -> String? {
        guard openBraceIndex < chars.count, chars[openBraceIndex] == "{" else { return nil }
        var depth = 0
        var i = openBraceIndex
        let start = openBraceIndex + 1
        while i < chars.count {
            let c = chars[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return String(chars[start..<i]) }
            }
            i += 1
        }
        return nil
    }

    /// Replace the CONTENTS of line comments, block comments, and string
    /// literals with spaces (newlines preserved), so brace/keyword scanning
    /// never trips over a `{`, `}`, or `catch` that lives inside text. Handles
    /// `//`, `/* */` (nested), `"..."`, `"""..."""`, and backslash escapes.
    static func stripCommentsAndStrings(_ source: String) -> String {
        enum Mode { case normal, line, block, str, multiStr }
        var mode: Mode = .normal
        var blockDepth = 0
        var out: [Character] = []
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        let n = chars.count
        func peek(_ o: Int) -> Character? { (i + o) < n ? chars[i + o] : nil }

        while i < n {
            let c = chars[i]
            switch mode {
            case .normal:
                if c == "/", peek(1) == "/" {
                    mode = .line; out.append(" "); out.append(" "); i += 2; continue
                }
                if c == "/", peek(1) == "*" {
                    mode = .block; blockDepth = 1; out.append(" "); out.append(" "); i += 2; continue
                }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    mode = .multiStr; out.append(" "); out.append(" "); out.append(" "); i += 3; continue
                }
                if c == "\"" {
                    mode = .str; out.append(" "); i += 1; continue
                }
                out.append(c); i += 1
            case .line:
                if c == "\n" { mode = .normal; out.append(c) } else { out.append(" ") }
                i += 1
            case .block:
                if c == "/", peek(1) == "*" {
                    blockDepth += 1; out.append(" "); out.append(" "); i += 2; continue
                }
                if c == "*", peek(1) == "/" {
                    blockDepth -= 1; out.append(" "); out.append(" "); i += 2
                    if blockDepth == 0 { mode = .normal }
                    continue
                }
                out.append(c == "\n" ? "\n" : " "); i += 1
            case .str:
                if c == "\\", peek(1) != nil {
                    out.append(" "); out.append(" "); i += 2; continue
                }
                if c == "\"" { mode = .normal; out.append(" "); i += 1; continue }
                out.append(c == "\n" ? "\n" : " "); i += 1
            case .multiStr:
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    mode = .normal; out.append(" "); out.append(" "); out.append(" "); i += 3; continue
                }
                out.append(c == "\n" ? "\n" : " "); i += 1
            }
        }
        return String(out)
    }

    // Repo-root walk lives in NativeAgentTestSupport.SourceTreeRepoRoot (shared
    // with the NoPython and shard-drift guards).
}
