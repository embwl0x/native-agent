import Foundation
import Testing
@testable import ChatOrchestration

// `mac.look` and `mac_look` are one tool: the Trust Center registry id and the
// chat catalog name. Agent's 2026-08-22 acceptance run called the dotted form
// for every tool (mac.look / mac.act / mac.view) and got "not in the dispatch
// table" back 20 times — an entire round voided by a spelling. The dispatcher
// and tool_load now resolve the dotted form to the catalog name when that name
// exists, and ONLY then: this is an alias, not a fuzzy match.

private let catalog: Set<String> = ["mac_look", "mac_act", "mac_view", "mac_ax_find", "time_now"]

@Test
func dottedRegistryIdResolvesToTheCatalogName() {
    #expect(SwiftToolDispatcher.canonicalToolName("mac.look") { catalog.contains($0) } == "mac_look")
    #expect(SwiftToolDispatcher.canonicalToolName("mac.act") { catalog.contains($0) } == "mac_act")
    #expect(SwiftToolDispatcher.canonicalToolName("mac.ax_find") { catalog.contains($0) } == "mac_ax_find")
}

@Test
func catalogNamesAndUnknownNamesPassThroughUntouched() {
    // Already canonical: identity.
    #expect(SwiftToolDispatcher.canonicalToolName("mac_look") { catalog.contains($0) } == "mac_look")
    // Dotted but nothing to alias TO: stays unknown (the dispatch table says so).
    #expect(SwiftToolDispatcher.canonicalToolName("mac.nope") { catalog.contains($0) } == "mac.nope")
    // Not dotted: never rewritten even if an underscore twin exists.
    #expect(SwiftToolDispatcher.canonicalToolName("time-now") { catalog.contains($0) } == "time-now")
    // MCP namespace is never touched.
    #expect(SwiftToolDispatcher.canonicalToolName("mcp__x.y") { _ in true } == "mcp__x.y")
}

@Test
func aDottedNameThatIsItselfInTheCatalogIsNotRewritten() {
    // If a catalog ever legitimately carries a dotted name, it wins as-is.
    let dotted: Set<String> = ["weird.tool", "weird_tool"]
    #expect(SwiftToolDispatcher.canonicalToolName("weird.tool") { dotted.contains($0) } == "weird.tool")
}
