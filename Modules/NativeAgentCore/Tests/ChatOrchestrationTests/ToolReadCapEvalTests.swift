import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.impl_read_file.byteCaps  (silent truncation)
//
// read_file is the highest-traffic read path in the live trace (53 dispatches
// in the window). It truncates at 64KB and list_dir keeps only the first 200
// names. Neither constant was asserted anywhere.
// ─────────────────────────────────────────────────────────────────────────────

private struct ReadCapEvalTree {
    let repoRoot: URL
    let dataRoot: URL
    let fixtureDir: URL

    static func make() throws -> ReadCapEvalTree {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolReadCapEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let repoRoot = base.resolvingSymlinksInPath()
        let dataRoot = repoRoot.appendingPathComponent("data", isDirectory: true)
        let fixtureDir = dataRoot.appendingPathComponent("evalfixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        return ReadCapEvalTree(repoRoot: repoRoot, dataRoot: dataRoot, fixtureDir: fixtureDir)
    }

    func cleanup() { try? FileManager.default.removeItem(at: repoRoot) }
}

/// TRUNCATION MUST BE OBSERVABLE. A 64KB clip with no marker means the agent
/// reads the head of a file and reasons about it as if it were the whole file.
/// The assertion reads the MARKER (and the byte count inside it), never the
/// constant — so raising maxFileBytes keeps this green while DELETING the
/// marker goes red, which is the regression that actually hurts.
@Test func toolReadCaps_readFileTruncationCarriesAnExplicitTotalByteCount() async throws {
    let tree = try ReadCapEvalTree.make()
    defer { tree.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: tree.dataRoot)

    let oversizeBytes = SwiftToolDispatcher.maxFileBytes * 2
    let oversize = String(repeating: "a", count: oversizeBytes)
    try Data(oversize.utf8).write(to: tree.fixtureDir.appendingPathComponent("big.txt"))
    try Data("small".utf8).write(to: tree.fixtureDir.appendingPathComponent("small.txt"))

    guard case .string(let bigText) = try await dispatcher.impl_read_file(
        input: ["path": .string("data/evalfixture/big.txt")]
    ) else {
        Issue.record("read_file must return a string body")
        return
    }
    #expect(
        bigText.contains("[truncated,"),
        "an oversize read must SAY it was truncated; got \(bigText.count) chars with no marker"
    )
    #expect(
        bigText.contains("\(oversizeBytes) bytes total"),
        "the marker must name the real total (\(oversizeBytes)) so the model can ask for the rest"
    )
    // Body stays bounded: the marker is appended to a capped read, not to a
    // full-file slurp. Marker text is short; one KB of slack covers it.
    #expect(bigText.count <= SwiftToolDispatcher.maxFileBytes + 1024)

    guard case .string(let smallText) = try await dispatcher.impl_read_file(
        input: ["path": .string("data/evalfixture/small.txt")]
    ) else {
        Issue.record("read_file must return a string body")
        return
    }
    #expect(smallText == "small")
    #expect(
        !smallText.contains("[truncated,"),
        "a complete read must NOT claim truncation — a false marker is as bad as a missing one"
    )
}

/// list_dir's cap. The property with teeth is that the cap EXISTS and is not
/// clipping ordinary directories: an uncapped listing blows the prompt budget,
/// a cap set too low silently hides files the agent then swears are absent.
///
/// KNOWN GAP, deliberately recorded rather than asserted away: unlike
/// read_file, list_dir returns a bare array with NO elision marker and NO total
/// count, so a 400-entry directory is indistinguishable from a 200-entry one to
/// the model. Making that observable needs a production change (see
/// productionSeamNeeded) — this eval pins the cap that exists today so the
/// silent tail cannot get quietly longer.
@Test func toolReadCaps_listDirIsCappedButOrdinaryDirectoriesAreComplete() async throws {
    let tree = try ReadCapEvalTree.make()
    defer { tree.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: tree.dataRoot)

    let smallDir = tree.fixtureDir.appendingPathComponent("small", isDirectory: true)
    try FileManager.default.createDirectory(at: smallDir, withIntermediateDirectories: true)
    for index in 0..<37 {
        try Data("x".utf8).write(
            to: smallDir.appendingPathComponent(String(format: "f%03d.txt", index))
        )
    }
    guard case .array(let smallNames) = try await dispatcher.impl_list_dir(
        input: ["path": .string("data/evalfixture/small")]
    ) else {
        Issue.record("list_dir must return an array")
        return
    }
    #expect(smallNames.count == 37, "an ordinary directory must be listed in full")

    let bigDir = tree.fixtureDir.appendingPathComponent("big", isDirectory: true)
    try FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
    for index in 0..<400 {
        try Data("x".utf8).write(
            to: bigDir.appendingPathComponent(String(format: "f%03d.txt", index))
        )
    }
    guard case .array(let bigNames) = try await dispatcher.impl_list_dir(
        input: ["path": .string("data/evalfixture/big")]
    ) else {
        Issue.record("list_dir must return an array")
        return
    }
    #expect(
        bigNames.count == 200,
        """
        list_dir must cap a 400-entry directory at the documented 200, got \(bigNames.count). \
        Above 200 the prompt budget is unbounded; below it, the agent silently loses files.
        """
    )
    // The cap keeps the HEAD of a sorted listing — so the tail is what is lost,
    // deterministically. Pinning the ordering makes "which 200" a decision.
    #expect(bigNames.first == .string("f000.txt"))
    #expect(bigNames.last == .string("f199.txt"))
}
