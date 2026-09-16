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

/// Partial reads must expose the real total and a continuation that traverses
/// the same authorized path without losing source text or exceeding the cap.
@Test func toolReadCaps_readFileTruncationCarriesAnExplicitTotalByteCount() async throws {
    let tree = try ReadCapEvalTree.make()
    defer { tree.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: tree.dataRoot)

    let oversizeBytes = SwiftToolDispatcher.maxFileBytes * 2
    let oversize = String(repeating: "a", count: oversizeBytes)
    try Data(oversize.utf8).write(to: tree.fixtureDir.appendingPathComponent("big.txt"))
    try Data("small".utf8).write(to: tree.fixtureDir.appendingPathComponent("small.txt"))

    guard case .object(let big) = try await dispatcher.impl_read_file(
        input: ["path": .string("data/evalfixture/big.txt")]
    ), case .string(let bigText)? = big["content"], case .object(let next)? = big["next"] else {
        Issue.record("Partial read needs window metadata"); return
    }
    #expect(big["bytes"] == .int(Int64(oversizeBytes)))
    #expect(big["has_more"] == .bool(true))
    #expect(bigText.count == SwiftToolDispatcher.maxFileBytes)
    #expect(next["path"] == .string("data/evalfixture/big.txt"))
    guard case .object(let tail) = try await dispatcher.impl_read_file(input: next),
          case .string(let tailText)? = tail["content"] else { Issue.record("Missing tail"); return }
    #expect(tail["has_more"] == .bool(false))
    #expect(bigText + tailText == oversize)

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

/// Both directory routes expose bounded entries plus honest continuation;
/// the agent must be able to reach a previously hidden tail without guessing.
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
    guard case .object(let smallResult) = try await dispatcher.impl_list_dir(
        input: ["path": .string("data/evalfixture/small")]
    ), case .array(let smallNames)? = smallResult["entries"] else {
        Issue.record("list_dir must return entries with coverage")
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
    guard case .object(let bigResult) = try await dispatcher.impl_list_dir(
        input: ["path": .string("data/evalfixture/big")]
    ), case .array(let bigNames)? = bigResult["entries"] else {
        Issue.record("list_dir must return entries with coverage")
        return
    }
    #expect(
        bigNames.count == 200,
        """
        list_dir must cap a 400-entry directory at the documented 200, got \(bigNames.count). \
        Above 200 the prompt budget is unbounded; below it, the agent silently loses files.
        """
    )
    // The first page is deterministic; its continuation reaches the tail.
    #expect(bigNames.first == .string("f000.txt"))
    #expect(bigNames.last == .string("f199.txt"))
    #expect(smallResult["has_more"] == .bool(false))
    #expect(bigResult["has_more"] == .bool(true))
    #expect(bigResult["total_matching"] == .int(400))
    guard case .object(let next)? = bigResult["next"],
          case .object(let last) = try await dispatcher.impl_list_dir(input: next),
          case .array(let tail)? = last["entries"] else {
        Issue.record("Missing directory continuation"); return
    }
    #expect(next["path"] == .string("data/evalfixture/big"))
    #expect(tail.count == 200)
    #expect(tail.first == .string("f200.txt"))
    #expect(tail.last == .string("f399.txt"))
    #expect(last["has_more"] == .bool(false))
}

@Test func basicReadFileContinuationPreservesUnicodeAndRejectsMutation() async throws {
    let tree = try ReadCapEvalTree.make()
    defer { tree.cleanup() }
    let dispatcher = SwiftToolDispatcher(dataRoot: tree.dataRoot)
    let file = tree.fixtureDir.appendingPathComponent("unicode.txt")
    let content = "aé🙂漢e\u{0301} tail"
    try Data(content.utf8).write(to: file)
    var input: [String: JSONValue] = ["path": .string("data/evalfixture/unicode.txt"), "max_bytes": .int(4)]
    var text = ""
    var savedNext: [String: JSONValue]?
    for _ in 0..<20 {
        guard case .object(let result) = try await dispatcher.impl_read_file(input: input),
              case .string(let page)? = result["content"] else { Issue.record("Missing window"); return }
        text += page
        guard case .object(let next)? = result["next"] else { break }
        savedNext = next
        input = next
    }
    #expect(text == content)
    try Data("replaced".utf8).write(to: file, options: .atomic)
    guard let savedNext, case .object(let changed) = try await dispatcher.impl_read_file(input: savedNext) else {
        Issue.record("Missing changed-file result"); return
    }
    #expect(changed["error_code"] == .string("file_changed"))
    #expect(changed["content"] == nil)
}
