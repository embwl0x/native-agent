import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger rows closed here:
//   • chat.tools.toolCausalBoundary.isExternalProtocolTool  (evidence laundering)
//   • chat.tools.providerToolNameMap                        (dropped call / wrong route)
//
// Both are pure functions with zero prior test references. Both fail as a WRONG
// ANSWER rather than an error: one accepts an external claim on the server's own
// say-so, the other routes a model tool call to the wrong internal tool.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - chat.tools.toolCausalBoundary.isExternalProtocolTool

/// The rule: an MCP result is TRANSPORT evidence, never proof an external
/// effect settled — except NativeAgent's own compatibility server, which has no
/// external transport. The carve-out is a lowercased string compare, so casing
/// and malformed prefixes are exactly where it can silently flip a tool from
/// "needs proof" to "self-certifying".
///
/// Failing safe here means: when in doubt, EXTERNAL is the safe answer (it
/// demands proof) and INTERNAL is never granted to anything whose server id is
/// not literally the internal one. A name with no second separator is not a
/// bridged MCP call at all, so it is not external — it falls through to the
/// ordinary native-tool rules that already own it.
@Test func toolCausalBoundary_externalProtocolClassificationIsCaseSafeAndFailsSafe() {
    let expectations: [(tool: String, external: Bool, why: String)] = [
        ("mcp__nativeagent-internal__x", false, "the internal server has no external transport"),
        ("mcp__NativeAgent-Internal__x", false, "the carve-out must survive any casing"),
        ("MCP__NATIVEAGENT-INTERNAL__X", false, "prefix casing must not defeat the carve-out"),
        ("  mcp__nativeagent-internal__x  ", false, "padding must not defeat the carve-out"),
        ("mcp__other__x", true, "a third-party server's result is transport evidence only"),
        ("mcp__other__a__b", true, "a tool name containing __ is still a third-party call"),
        ("mcp__nativeagent-internal-ish__x", true, "a LOOK-ALIKE server id is not the carve-out"),
        ("read_file", false, "a native tool is not an MCP protocol call"),
        ("mcp__noseparator", false, "a malformed bridged name is not a bridged MCP call"),
        // Empty server id: the predicate treats it as external. That is the
        // SAFE direction (external = "this needs proof"), and it is asserted
        // explicitly so a future 'tidy-up' that folds the empty case into the
        // internal carve-out is visible rather than silent.
        ("mcp____x", true, "an empty server id must never be mistaken for the internal carve-out"),
    ]
    for expectation in expectations {
        #expect(
            ToolCausalBoundary.isExternalProtocolTool(expectation.tool) == expectation.external,
            "'\(expectation.tool)' should be external=\(expectation.external): \(expectation.why)"
        )
    }
}

// MARK: - chat.tools.providerToolNameMap

private func evalSchema(_ name: String, _ description: String = "d") -> LLMToolSchema {
    LLMToolSchema(
        name: name,
        description: description,
        parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
    )
}

/// Two DIFFERENT internal names that sanitize to the SAME provider name is the
/// dangerous input: `mcp__a-b__x` and `mcp__a_b__x` both reduce to `mcp_a_b_x`.
/// If the uniquing regresses, the alias table keeps only the last writer and the
/// model's call to one server silently executes on the other. That is a WRONG
/// ACTION, not an error — nothing anywhere would log it.
///
/// The assertion is a round-trip envelope (every provider name maps back to its
/// EXACT original), not a pin on the generated alias text, so a change to the
/// suffix scheme stays green while a collapse goes red.
@Test func providerToolNameMap_collidingNamesStayUniqueAndRoundTrip() throws {
    let internalNames = [
        "read_file",
        "mcp__a-b__x",
        "mcp__a_b__x",
        "mcp__a.b__x",
        "mcp__server-id__tool.name",
        "tool_load",
    ]
    let map = ProviderToolNameMap(internalNames.map { evalSchema($0, "desc of \($0)") })

    #expect(map.schemas.count == internalNames.count, "no schema may be dropped at the wire boundary")

    let providerNames = map.schemas.map(\.name)
    #expect(
        Set(providerNames).count == providerNames.count,
        "provider names must be unique — duplicates are rejected by providers and route ambiguously: \(providerNames)"
    )
    for name in providerNames {
        #expect(
            name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") },
            "'\(name)' must be [A-Za-z0-9_] only — that is the whole reason this map exists"
        )
        #expect(!name.isEmpty && name.count <= 128)
    }

    // Round-trip: EVERY alias resolves back to its exact original internal name,
    // in order. This is the property a uniquing regression breaks.
    for (index, schema) in map.schemas.enumerated() {
        #expect(
            map.internalName(forProviderName: schema.name) == internalNames[index],
            "'\(schema.name)' must dispatch to '\(internalNames[index])', got '\(map.internalName(forProviderName: schema.name))'"
        )
    }

    // An un-aliased name is left completely alone — same name, UNTOUCHED
    // description. Appending dispatch guidance to a name that needs none would
    // churn the cached prompt prefix every turn for no reason.
    let plain = try #require(map.schemas.first { $0.name == "read_file" })
    #expect(plain.description == "desc of read_file")

    // An aliased name carries its dispatch name in the description, so the
    // model can still say what it actually called.
    let aliased = try #require(map.schemas.first { $0.name != internalNames[1] && map.internalName(forProviderName: $0.name) == internalNames[1] })
    #expect(aliased.description.contains("NativeAgent dispatch name: \(internalNames[1])."))

    // An unknown provider name passes through unchanged rather than resolving
    // to some arbitrary neighbour — a miss must stay a miss.
    #expect(map.internalName(forProviderName: "not_a_tool") == "not_a_tool")
}
