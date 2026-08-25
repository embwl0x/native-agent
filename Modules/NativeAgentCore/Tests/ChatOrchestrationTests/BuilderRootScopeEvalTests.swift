import Testing
import Foundation
@testable import ChatOrchestration
import PersistenceCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.builder.nativeAgentRepoRoot  (sandbox scope drift)
//
// `nativeAgentRepoRoot` is a hardcoded `~/Projects/NativeAgent`. It becomes a
// SECOND writable root in the builder's seatbelt profile whenever a directory
// of that name happens to validate as a NativeAgent checkout — on any machine
// that is not User's it is dead, and on any machine where such a directory
// exists it silently widens the builder's write scope.
//
// The reports-only shape the ledger flagged: every existing test derives its
// expectation FROM the constant, so changing the constant changes both the code
// and the assertion together and no test can ever catch it. This eval fixes
// that by (1) pinning the literal so a change is a review trigger, and (2)
// bounding the ROOT SET so no THIRD ambient root can appear.
// ─────────────────────────────────────────────────────────────────────────────

private func builderScopeEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BuilderRootScopeEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func builderRootScope_constantIsFrozenAndAllowedRootsCarryNoThirdAmbientRoot() throws {
    // 1. FROZEN LITERAL. Not derived — spelled out, so a change to the constant
    //    cannot silently update its own assertion.
    #expect(
        SwiftToolDispatcher.nativeAgentRepoRoot
            == NSString(string: "~/Projects/NativeAgent").expandingTildeInPath,
        """
        nativeAgentRepoRoot changed to '\(SwiftToolDispatcher.nativeAgentRepoRoot)'. \
        This literal is a candidate SECOND writable root in the builder seatbelt. \
        Widening it widens the builder's write scope on every install where the \
        directory happens to exist.
        """
    )
    #expect(
        SwiftToolDispatcher.nativeAgentRepoRoot.hasPrefix("/"),
        "the constant must be tilde-expanded at definition, or the seatbelt profile gets a literal '~'"
    )

    // 2. ROOT-SET ENVELOPE on a hermetic data root that is NOT a checkout.
    let root = try builderScopeEvalRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let allowed = SwiftToolDispatcher.builderAllowedRoots(dataRoot: root)
    let workspace = SwiftToolDispatcher.builderWorkspaceRoot(dataRoot: root)
    let source = SwiftToolDispatcher.builderSourceRepoRoot(dataRoot: root)

    #expect(allowed.first?.path == workspace.path, "the canonical workspace must always be root #0")
    #expect(
        allowed.count <= 2,
        "the builder may have at most the workspace plus ONE validated source checkout, got: \(allowed.map(\.path))"
    )
    #expect(
        Set(allowed.map(\.path)).count == allowed.count,
        "duplicate roots in the seatbelt profile: \(allowed.map(\.path))"
    )

    // Whatever the second root is, it must be EXACTLY the resolver's answer —
    // never an independently-derived ambient path. This is the assertion a
    // third root (or a differently-derived one) trips.
    if allowed.count == 2 {
        let second = try #require(source, "a second allowed root appeared with no builderSourceRepoRoot to justify it")
        #expect(allowed[1].path == second.path)
        #expect(
            second.path == URL(fileURLWithPath: SwiftToolDispatcher.nativeAgentRepoRoot)
                .standardizedFileURL.resolvingSymlinksInPath().path,
            """
            the second builder root is '\(second.path)', which is not the conventional \
            checkout named by nativeAgentRepoRoot. An ambient writable root the constant \
            does not name is exactly the scope drift this row exists to catch.
            """
        )
    } else {
        #expect(
            source == nil,
            "builderSourceRepoRoot resolved to \(source?.path ?? "-") but builderAllowedRoots did not include it — the two disagree about the builder's write scope"
        )
    }

    // 3. The hermetic data root's workspace is genuinely local to it — a
    //    resolver that fell back to the LIVE workspace would make every builder
    //    test in this suite non-hermetic.
    #expect(
        workspace.path.hasPrefix(root.resolvingSymlinksInPath().path),
        "the hermetic dataRoot's workspace resolved outside it: \(workspace.path)"
    )
}
