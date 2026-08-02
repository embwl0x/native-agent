import Testing
import Foundation

// The FIVE-SITE tool-registration invariant, enforced instead of remembered.
//
// A desk chat tool has to be registered in five places: the DeskTools impl,
// the dispatch switch, the schema builders, the tool catalog, and — the one
// that gets forgotten — SecurityCenter's `builtinToolNames` + `deskWriteTools`.
// The rule is written in three doc comments and was checked by hand at review
// time, which is exactly why `desk_open_pursuit` and `desk_work_log` sat at
// 4-of-5 from the day the pursuit lane shipped until an audit found them on
// 2026-08-02. The consequence wasn't cosmetic: with no SecurityCenter entry,
// `desk_` matches no keyword catcher, so both resolved to
// {tool_call} / .low and `rollbackRequired` was FALSE — the only chat path
// that opens an origin=agent pursuit was the least-classified write on the
// whole desk surface, while its thirteen siblings got ledger_write/.medium.
//
// This test set-diffs the five registries so the next 4-of-5 is a red test
// with the missing name in the message, not an audit finding months later.
//
// It reads SOURCE TEXT rather than the symbols because the five sites live in
// two different modules (ChatOrchestration and TrustCenter) and several of the
// registries are internal to theirs. Grepping is the honest tool here: it sees
// exactly what a reviewer would, and it cannot be fooled by a name that
// compiles but is never registered.
@Suite("Desk tool five-site registration")
struct DeskToolRegistrationTests {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TrustCenterTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // repo root

    /// Every `desk_*` identifier appearing as a quoted string literal in a file.
    private func deskNames(in relativePath: String) throws -> Set<String> {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        var found: Set<String> = []
        // Quoted "desk_..." literals only — a bare `desk_foo` in prose or a
        // comment must not count as a registration.
        let pattern = #""(desk_[a-z0-9_]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { continue }
            found.insert(String(text[r]))
        }
        return found
    }

    /// Site 1 — the implementation is the source of truth for what EXISTS.
    ///
    /// Read from the `func impl_desk_*` DECLARATIONS, not from quoted literals:
    /// the impl file names its tools as functions and only ever quotes them
    /// inside error messages (`"desk_open_pursuit: project and title must be
    /// non-empty"`), so a literal scan here finds zero and the test would
    /// measure nothing. (First draft did exactly that; the `>= 14` sanity
    /// check below is what caught it, which is the reason it exists.)
    private static let implPath =
        "Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+DeskTools.swift"

    private func implementedDeskTools() throws -> Set<String> {
        let url = Self.repoRoot.appendingPathComponent(Self.implPath)
        let text = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"func\s+impl_(desk_[a-z0-9_]+)"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { continue }
            found.insert(String(text[r]))
        }
        return found
    }

    private static let otherSites: [(label: String, path: String)] = [
        ("dispatch switch",
         "Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+Dispatch.swift"),
        ("schema builders",
         "Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+SchemaBuilders.swift"),
        ("tool catalog",
         "Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+ToolCatalog.swift"),
        ("SecurityCenter tool profiles",
         "Modules/NativeAgentCore/Sources/TrustCenter/SecurityCenter+ToolProfiles.swift"),
    ]

    @Test("every desk tool is registered at all five sites")
    func deskToolsRegisteredEverywhere() throws {
        let implemented = try implementedDeskTools()
        // Sanity: if this ever drops to a handful, the impl path moved and the
        // test would pass vacuously.
        #expect(implemented.count >= 14,
                "expected the full desk tool surface at \(Self.implPath), found \(implemented.count)")

        for site in Self.otherSites {
            let registered = try deskNames(in: site.path)
            let missing = implemented.subtracting(registered).sorted()
            // `#expect`'s second argument is a `Comment`, so the message has to
            // be ONE interpolated literal — a `+` concatenation won't compile.
            let detail = "\(site.label) is missing desk tools: "
                + "\(missing.joined(separator: ", ")) — a desk tool must be "
                + "registered at all five sites (see \(site.path))"
            #expect(missing.isEmpty, "\(detail)")
        }
    }

    @Test("every desk write tool carries the ledger_write profile")
    func deskWritesAreClassified() throws {
        let profiles = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(Self.otherSites[3].path),
            encoding: .utf8
        )
        // The write set is the implemented surface minus the known pure reads.
        // A new desk tool defaults to "must be classified" — the failure mode
        // we're closing is a write silently inheriting {tool_call}/.low.
        let pureReads: Set<String> = ["desk_read"]
        let writes = try implementedDeskTools().subtracting(pureReads)
        guard let writeSetRange = profiles.range(of: "let deskWriteTools: Set<String> = [") else {
            Issue.record("deskWriteTools set not found — SecurityCenter+ToolProfiles.swift changed shape")
            return
        }
        let tail = profiles[writeSetRange.upperBound...]
        guard let close = tail.range(of: "]") else {
            Issue.record("deskWriteTools set is unterminated")
            return
        }
        let body = String(tail[..<close.lowerBound])
        let missing = writes.filter { !body.contains("\"\($0)\"") }.sorted()
        let detail = "desk write tools missing from deskWriteTools (they would "
            + "resolve to {tool_call}/.low with rollbackRequired == false): "
            + "\(missing.joined(separator: ", "))"
        #expect(missing.isEmpty, "\(detail)")
    }
}
