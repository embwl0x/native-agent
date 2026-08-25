import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.builtInSchemaCache  (stale UI / wrong value)
//
// The built-in schema cache is keyed on (6 access bits, sorted requestedNames).
// The silent failure is a gate that changes schema CONTENT without moving one
// of those bits: the cache then serves a stale catalog forever. That is exactly
// why the W7 activity bit had to be added to the key after the fact.
//
// Two halves, both cheap:
//   (a) every one of the six flags is genuinely load-bearing on the generated
//       schema set — so each bit in the key earns its place;
//   (b) the accessFlags expression covers EVERY `include*` parameter of
//       `cachedBuiltInToolSchemas`, each with a distinct power-of-two. Add a
//       seventh gate without a bit and this goes red instead of shipping a
//       cache that cannot tell the two catalogs apart.
// ─────────────────────────────────────────────────────────────────────────────

private func schemaCacheEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchemaCacheKeyEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// (a) Flip one flag at a time off a hard-OFF baseline; each must change the
/// emitted schema NAME SET. A flag that changes nothing is a dead bit in the
/// key; a flag that changes something but is missing from the key is a stale
/// catalog. This half proves the first.
@Test func builtInSchemaCache_everyAccessFlagChangesTheEmittedCatalog() throws {
    let root = try schemaCacheEvalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)

    func names(
        file: Bool = false, system: Bool = false, app: Bool = false,
        axRead: Bool = false, axInject: Bool = false, activity: Bool = false
    ) -> Set<String> {
        Set(dispatcher.builtInToolSchemas(
            includeFullMacFileTools: file,
            includeFullMacSystemTools: system,
            includeFullMacAppTools: app,
            includeFullMacAccessibilityReadTools: axRead,
            includeFullMacAccessibilityInjectionTools: axInject,
            includeActivityQueryTool: activity
        ).map(\.name))
    }

    let baseline = names()
    #expect(!baseline.isEmpty, "the hard-OFF catalog must still carry the always-on core")

    let flips: [(label: String, set: Set<String>)] = [
        ("includeFullMacFileTools", names(file: true)),
        ("includeFullMacSystemTools", names(system: true)),
        ("includeFullMacAppTools", names(app: true)),
        ("includeFullMacAccessibilityReadTools", names(axRead: true)),
        ("includeFullMacAccessibilityInjectionTools", names(axInject: true)),
        ("includeActivityQueryTool", names(activity: true)),
    ]
    for flip in flips {
        #expect(
            flip.set != baseline,
            "\(flip.label) changed no schema — it is a dead bit in the cache key, or the gate stopped working"
        )
        #expect(
            flip.set.isSuperset(of: baseline),
            "\(flip.label) must ADD capability, never silently drop an always-on tool"
        )
    }

    // Distinct flags must not produce identical catalogs — otherwise two
    // different keys legitimately map to the same value and one of the bits is
    // redundant rather than load-bearing.
    let distinctCatalogs = Set(flips.map { $0.set })
    #expect(
        distinctCatalogs.count == flips.count,
        "two access flags produce the SAME catalog; one of them is not carrying its own capability"
    )

    // requestedNames is the other half of the key: a filtered build must be a
    // subset, so two different name sets can never share a cache value.
    let filtered = Set(dispatcher.builtInToolSchemas(requestedNames: ["read_file"]).map(\.name))
    #expect(filtered.isSubset(of: baseline))
    #expect(filtered != baseline, "requestedNames must actually filter, or it is a dead half of the key")
}

/// (b) The cache key must cover every gate the schema builder reads. Parsed out
/// of source rather than restated, so this cannot drift into agreeing with
/// itself.
@Test func builtInSchemaCache_keyCoversEveryIncludeFlagWithADistinctBit() throws {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    guard let functionStart = text.range(of: "private func cachedBuiltInToolSchemas(") else {
        Issue.record("cachedBuiltInToolSchemas moved — this eval must move with it")
        return
    }
    guard let keyStart = text.range(of: "let key = BuiltInSchemaCacheKey(", range: functionStart.upperBound..<text.endIndex) else {
        Issue.record("BuiltInSchemaCacheKey construction not found after cachedBuiltInToolSchemas")
        return
    }
    let body = String(text[functionStart.upperBound..<keyStart.lowerBound])

    // Parameter list: every `include<Name>: Bool` up to the accessFlags line.
    var declaredFlags: [String] = []
    var bitForFlag: [String: Int] = [:]
    for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("include"), line.contains(": Bool") {
            declaredFlags.append(String(line.prefix(while: { $0 != ":" })))
            continue
        }
        // e.g. `| (includeFullMacSystemTools ? 2 : 0)` or the leading
        // `let accessFlags = (includeFullMacFileTools ? 1 : 0)`
        guard let open = line.range(of: "(include") else { continue }
        let inner = line[open.lowerBound...].dropFirst()
        guard let questionMark = inner.range(of: " ? "),
              let colon = inner.range(of: " : ", range: questionMark.upperBound..<inner.endIndex)
        else { continue }
        let flag = String(inner[inner.startIndex..<questionMark.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard let bit = Int(inner[questionMark.upperBound..<colon.lowerBound].trimmingCharacters(in: .whitespaces))
        else { continue }
        bitForFlag[flag] = bit
    }

    #expect(declaredFlags.count >= 6, "parsed only \(declaredFlags.count) include-flags — the parser drifted")
    #expect(
        Set(bitForFlag.keys) == Set(declaredFlags),
        """
        every include-flag must contribute a bit to the cache key. \
        declared=\(declaredFlags.sorted()) keyed=\(bitForFlag.keys.sorted()). \
        A gate that changes schema content without moving a key bit serves a stale \
        catalog forever — that is how the W7 activity bit came to be added late.
        """
    )
    let bits = Array(bitForFlag.values)
    #expect(Set(bits).count == bits.count, "two flags share a key bit — they become indistinguishable: \(bitForFlag)")
    for (flag, bit) in bitForFlag {
        #expect(bit > 0 && (bit & (bit - 1)) == 0, "\(flag)'s bit \(bit) is not a distinct power of two")
    }
}
