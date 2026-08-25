import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
//
// Ledger rows closed here:
//   • chat.tools.resolveSandboxed         (sandbox escape, silent)
//   • chat.tools.allowedTopLevels         (silent widening)
//   • chat.tools.dispatcher.rootForRead   (silent zero on a degenerate install)
//
// Before this file, grep for the three refusal strings this path emits
// ("escapes data root", "absolute paths are not allowed", "allowed subdir of
// data") returned ZERO hits across Modules/**/Tests and tests/. The
// non-Full-Mac read/list path's only confinement had no test at all.
// ─────────────────────────────────────────────────────────────────────────────

/// A hermetic *source-repo* layout: `<root>/data` is the dataRoot, so
/// `rootForRead` (= dataRoot's parent) is `<root>` and the allow-listed
/// top-levels live directly under it. This is BOTH documented healthy shapes
/// (dev checkout, and a bundled install with a stamped REPO_PATH) — they are
/// the same layout on disk, which is itself the property worth pinning.
private struct SandboxEvalTree {
    let repoRoot: URL
    let dataRoot: URL

    static func make() throws -> SandboxEvalTree {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolSandboxEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve up front: /var/folders → /private/var/folders on macOS, and
        // resolveSandboxed compares RESOLVED paths.
        let repoRoot = base.resolvingSymlinksInPath()
        let dataRoot = repoRoot.appendingPathComponent("data", isDirectory: true)
        for relative in ["persona", "data/skills", "workspace", "script"] {
            try FileManager.default.createDirectory(
                at: repoRoot.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("soul".utf8).write(to: repoRoot.appendingPathComponent("persona/SOUL.md"))
        try Data("{}".utf8).write(to: repoRoot.appendingPathComponent("data/skills/registry.json"))
        return SandboxEvalTree(repoRoot: repoRoot, dataRoot: dataRoot)
    }

    func cleanup() { try? FileManager.default.removeItem(at: repoRoot) }
}

private func sandboxDeniedReason(_ error: any Error) -> String {
    if let gate = error as? AutonomyGateError, case .toolDenied(let reason) = gate { return reason }
    return "NOT-A-TOOL-DENIED: \(error)"
}

// MARK: - chat.tools.allowedTopLevels

/// FROZEN LITERAL KEEPER. Adding one entry here widens the unprivileged read
/// surface for EVERY chat surface at once — Telegram and iOS included — and the
/// only diff signal today is the literal itself. Pinning it makes a widening
/// impossible to land without touching this test, which is the review trigger.
/// Narrowing it is equally visible (a removed top-level silently 404s a whole
/// class of reads).
@Test func toolSandbox_allowedTopLevelsAreTheFrozenFour() {
    #expect(
        SwiftToolDispatcher.allowedTopLevels == ["workspace", "persona", "data", "script"],
        """
        allowedTopLevels changed to \(SwiftToolDispatcher.allowedTopLevels.sorted()). \
        Every entry is a read surface handed to every chat surface at once. \
        If this widening is intended, say so in the commit and update this literal.
        """
    )
}

// MARK: - chat.tools.resolveSandboxed

/// The confinement clauses, each asserted as a NAMED refusal rather than an
/// incidental miss. The symlink case is the one with teeth: deleting the
/// `.resolvingSymlinksInPath()` line on the candidate makes `workspace/escape`
/// (a real symlink to /etc) resolve INSIDE the allow-list and an ordinary
/// `read_file` reads /etc/hosts and reports success.
@Test func toolSandbox_refusesAbsoluteEscapeSymlinkAndUnlistedTopLevel() throws {
    let tree = try SandboxEvalTree.make()
    defer { tree.cleanup() }
    // A symlink INSIDE an allow-listed top level pointing outside the root.
    try FileManager.default.createSymbolicLink(
        at: tree.repoRoot.appendingPathComponent("workspace/escape"),
        withDestinationURL: URL(fileURLWithPath: "/etc")
    )
    let dispatcher = SwiftToolDispatcher(dataRoot: tree.dataRoot)

    // 1. Legitimate reads resolve — and BOTH allow-listed trees answer from the
    //    SAME root ("two tools, two roots" is the seam this anchor exists to
    //    close), so this is not a vacuous "everything is denied" pass.
    let soul = try dispatcher.resolveSandboxed("persona/SOUL.md")
    let registry = try dispatcher.resolveSandboxed("data/skills/registry.json")
    #expect(FileManager.default.fileExists(atPath: soul.path))
    #expect(FileManager.default.fileExists(atPath: registry.path))
    #expect(soul.path.hasPrefix(tree.repoRoot.path + "/"))
    #expect(registry.path.hasPrefix(tree.repoRoot.path + "/"))

    // 2. Each refusal is NAMED. The reason substrings are the contract: they
    //    are what the model and the trace see, and they distinguish a decision
    //    from an accident.
    let cases: [(path: String, expectedReason: String)] = [
        ("/etc/hosts", "absolute paths are not allowed"),
        ("../../../etc/hosts", "escapes data root"),
        ("workspace/escape/hosts", "escapes data root"),
        ("Modules/NativeAgentCore/Package.swift", "not under an allowed subdir"),
        ("   ", "empty path"),
    ]
    for testCase in cases {
        do {
            let resolved = try dispatcher.resolveSandboxed(testCase.path)
            Issue.record(
                "'\(testCase.path)' must be refused, resolved to \(resolved.path) instead"
            )
        } catch {
            let reason = sandboxDeniedReason(error)
            #expect(
                reason.contains(testCase.expectedReason),
                "'\(testCase.path)': expected a refusal naming '\(testCase.expectedReason)', got: \(reason)"
            )
        }
    }
}

// MARK: - chat.tools.dispatcher.rootForRead

/// `rootForRead` is parent-of-dataRoot. Two documented install shapes resolve
/// real source content; the third (bundled AppSupport fallback, NO repo stamp)
/// has dataRoot = `<AppSupport>/NativeAgent` with no `/data` suffix, so the
/// anchor lands in `<AppSupport>/` where none of the source trees exist.
///
/// The ledger row predicted a NAMED allow-list refusal there. It is not — and
/// that is the finding this eval pins: `persona/` passes the allow-list on
/// NAME, so the degenerate install returns a well-formed URL to a file that
/// does not exist and the agent says "file not found" for SOUL.md forever, with
/// no alarm anywhere. This test asserts the real envelope in both directions:
/// healthy layouts resolve to EXISTING files, the degenerate one resolves to a
/// path that exists nowhere. Anchor the dispatcher at dataRoot instead of its
/// parent and the healthy case goes red immediately.
@Test func toolSandbox_rootForReadAnchorsSourceContentInBothRepoLayouts() throws {
    let tree = try SandboxEvalTree.make()
    defer { tree.cleanup() }

    // Dev checkout AND stamped-REPO_PATH install are the SAME shape on disk;
    // pinning that equivalence is the point (a change that splits them would
    // reintroduce the two-roots seam).
    for dataRoot in [tree.dataRoot, tree.dataRoot.standardizedFileURL] {
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)
        #expect(dispatcher.rootForRead.path == tree.repoRoot.path)
        let soul = try dispatcher.resolveSandboxed("persona/SOUL.md")
        #expect(
            FileManager.default.fileExists(atPath: soul.path),
            "healthy install must resolve persona/SOUL.md to a real file, got \(soul.path)"
        )
    }

    // Degenerate: AppSupport-style dataRoot with no /data suffix.
    let appSupportSim = tree.repoRoot.appendingPathComponent("AppSupportSim", isDirectory: true)
    let bundledDataRoot = appSupportSim.appendingPathComponent("NativeAgent", isDirectory: true)
    try FileManager.default.createDirectory(at: bundledDataRoot, withIntermediateDirectories: true)
    let bundled = SwiftToolDispatcher(dataRoot: bundledDataRoot)
    #expect(bundled.rootForRead.path == appSupportSim.path)
    let bundledSoul = try bundled.resolveSandboxed("persona/SOUL.md")
    #expect(
        !FileManager.default.fileExists(atPath: bundledSoul.path),
        "the degenerate install must not accidentally find source content"
    )
    #expect(
        bundledSoul.path.hasPrefix(appSupportSim.path + "/"),
        """
        the degenerate install's reads land under \(bundledSoul.path) — inside the \
        app-support anchor, where no source tree exists. This is a NAME-only \
        allow-list pass, not a refusal: every sandboxed read on a bundled install \
        with no REPO_PATH stamp returns file_not_found with no alarm. Recorded here \
        so the shape is visible instead of inferred.
        """
    )
}
