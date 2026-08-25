import Testing
import Foundation
@testable import ChatOrchestration
import MacIntegration

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger rows closed here:
//   • chat.tools.macIntegrationGates        (wrong value — two tables, one truth)
//   • chat.tools.dispatchMacIntegrationTool (wrong gate mode)
//
// There are TWO independently-maintained (tool → integration, mode) maps:
// the hand-written `case "<tool>":` block in SwiftToolDispatcher+Dispatch.swift
// (the gate dispatch actually enforces) and `ToolPreloadHeuristics
// .macIntegrationGates` (the preload filter AND the parallel-dispatch write
// veto). Drift between them means preload advertises a tool the gate will
// refuse, or — worse — treats a WRITE as a read and lets it into the parallel
// set. The scheduler_list_jobs case already deliberately passes .write for a
// LIST, which is exactly the shape a copy-paste mistake takes.
//
// This eval parses the dispatch switch out of source and compares. It resolves
// `MacIntegrationID.<symbol>` by parsing the enum too, so no THIRD table is
// introduced here for the other two to drift against.
// ─────────────────────────────────────────────────────────────────────────────

private func evalRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ChatOrchestrationTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // NativeAgentCore
        .deletingLastPathComponent()  // Modules
        .deletingLastPathComponent()  // repo root
}

/// `public static let calendar = "calendar"` → ["calendar": "calendar"].
private func parseMacIntegrationIDs() throws -> [String: String] {
    let url = evalRepoRoot()
        .appendingPathComponent("Modules/NativeAgentCore/Sources/MacIntegration/MacIntegrationPermissions.swift")
    let text = try String(contentsOf: url, encoding: .utf8)
    var out: [String: String] = [:]
    var insideEnum = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("public enum MacIntegrationID") { insideEnum = true; continue }
        guard insideEnum else { continue }
        if trimmed.hasPrefix("public static let all") { break }
        guard trimmed.hasPrefix("public static let"),
              let equals = trimmed.range(of: "="),
              let openQuote = trimmed.range(of: "\"", range: equals.upperBound..<trimmed.endIndex),
              let closeQuote = trimmed.range(of: "\"", range: openQuote.upperBound..<trimmed.endIndex)
        else { continue }
        let symbol = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "public static let".count)..<equals.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        out[symbol] = String(trimmed[openQuote.upperBound..<closeQuote.lowerBound])
    }
    return out
}

private struct ParsedGate: Equatable {
    let integration: String
    let mode: String
}

/// Scan the dispatch switch for
///   case "<tool>":
///       return try await dispatchMacIntegrationTool(
///           integration: MacIntegrationID.<symbol>,
///           mode: .<read|write>,
private func parseDispatchGateTable(ids: [String: String]) throws -> [String: ParsedGate] {
    let url = evalRepoRoot()
        .appendingPathComponent("Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+Dispatch.swift")
    let text = try String(contentsOf: url, encoding: .utf8)
    var out: [String: ParsedGate] = [:]
    var pendingTool: String?
    var pendingIntegration: String?

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("case \""), trimmed.hasSuffix("\":"),
           let openQuote = trimmed.range(of: "\""),
           let closeQuote = trimmed.range(of: "\"", options: .backwards) {
            pendingTool = String(trimmed[openQuote.upperBound..<closeQuote.lowerBound])
            pendingIntegration = nil
            continue
        }
        if let marker = trimmed.range(of: "integration: MacIntegrationID.") {
            let symbol = String(trimmed[marker.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))
            pendingIntegration = ids[symbol] ?? "UNRESOLVED-SYMBOL:\(symbol)"
            continue
        }
        if trimmed.hasPrefix("mode: ."), let tool = pendingTool, let integration = pendingIntegration {
            let mode = String(trimmed.dropFirst("mode: .".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))
            out[tool] = ParsedGate(integration: integration, mode: mode)
            pendingTool = nil
            pendingIntegration = nil
        }
    }
    return out
}

/// Tools whose dispatch case gates on a Mac Integration permission but which
/// are deliberately (or accidentally) absent from `macIntegrationGates`.
///
/// FINDING, 2026-08-23: `mobile_notify` is the one such tool today. Its dispatch
/// case gates on (notify_mobile, .write), but with no `macIntegrationGates`
/// entry the preload filter passes it through untouched — so the "a
/// policy-denied tool is never preloaded" invariant is false for it, and the
/// parallel-dispatch write veto (which reads this same table) does not see it
/// as a write. It is listed here rather than asserted away so the eval stays
/// green and the gap stays VISIBLE: closing it is a one-line production change
/// (see productionSeamNeeded), and when it lands this literal empties out and
/// this test tells you so.
private let knownGatesTableOmissions: Set<String> = ["mobile_notify"]

@Test func macIntegrationGates_agreeWithTheDispatchSwitchOnEveryTool() throws {
    let ids = try parseMacIntegrationIDs()
    #expect(ids["calendar"] == "calendar", "the MacIntegrationID parse must actually resolve symbols")
    #expect(ids["notifyMac"] == "notify_mac")
    #expect(ids.count >= 11, "parsed only \(ids.count) integration ids — the parser lost the enum")

    let dispatchTable = try parseDispatchGateTable(ids: ids)
    #expect(
        dispatchTable.count >= 30,
        "parsed only \(dispatchTable.count) dispatch gate cases — the parser drifted from the source shape, and a parser that finds nothing would pass everything"
    )
    for (tool, gate) in dispatchTable {
        #expect(
            !gate.integration.hasPrefix("UNRESOLVED-SYMBOL:"),
            "'\(tool)' names an integration id this test could not resolve: \(gate.integration)"
        )
        #expect(["read", "write"].contains(gate.mode), "'\(tool)' has an unknown mode '\(gate.mode)'")
    }

    let preloadTable = ToolPreloadHeuristics.macIntegrationGates

    // 1. Every SHARED key must agree on BOTH id and mode. This is the copy-paste
    //    guard: flip one `.read`/`.write` on either side and it goes red.
    for (tool, gate) in dispatchTable {
        guard let preload = preloadTable[tool] else { continue }
        #expect(
            preload.integration == gate.integration,
            "'\(tool)': dispatch gates on '\(gate.integration)', macIntegrationGates says '\(preload.integration)'"
        )
        #expect(
            preload.mode.rawValue == gate.mode,
            "'\(tool)': dispatch gates on .\(gate.mode), macIntegrationGates says .\(preload.mode.rawValue) — a downgraded mode silently weakens the permission check"
        )
    }

    // 2. Coverage, both directions, with the known gap named explicitly.
    let missingFromPreload = Set(dispatchTable.keys).subtracting(preloadTable.keys)
    #expect(
        missingFromPreload == knownGatesTableOmissions,
        """
        macIntegrationGates must cover EVERY dispatchMacIntegrationTool case (it doubles as the \
        parallel-dispatch write veto). Uncovered: \(missingFromPreload.sorted()); \
        known/allowed: \(knownGatesTableOmissions.sorted()). A NEW name here means a Mac \
        Integration tool that preload will never policy-filter.
        """
    )
    let phantomInPreload = Set(preloadTable.keys).subtracting(dispatchTable.keys)
    #expect(
        phantomInPreload.isEmpty,
        "macIntegrationGates names tools with no dispatch case — preload would advertise a tool that cannot run: \(phantomInPreload.sorted())"
    )
}
