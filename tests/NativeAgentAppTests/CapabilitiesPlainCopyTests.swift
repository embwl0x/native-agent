import Testing
import ChatOrchestration
@testable import NativeAgentApp

struct CapabilitiesPlainCopyTests {
    @Test func everyRegisteredToolHasToolOrFamilyCopy() {
        let names = SwiftToolDispatcher.catalogRegisteredToolNames
            .union(AppChatToolDispatcher.catalogRegisteredToolNames)
        #expect(!names.isEmpty)
        for name in names.sorted() {
            let description = CapabilitiesPlainCopy.toolDescription(name)
            #expect(description != "An additional tool I can use for your tasks.", "Missing copy: \(name)")
            #expect(description != "Use your Mac's apps and controls.", "Missing Mac copy: \(name)")
        }
    }

    @Test func catalogIDsAndCapabilityIDsShareSpecificMacCopy() {
        #expect(CapabilitiesPlainCopy.toolDescription("mac_focus_app") == "Bring an app to the front.")
        #expect(CapabilitiesPlainCopy.toolDescription("mac_ax_status") == "Check permission to use Mac controls.")
        #expect(CapabilitiesPlainCopy.toolDescription("tool:mac.focus_app") == CapabilitiesPlainCopy.toolDescription("mac_focus_app"))
        #expect(CapabilitiesPlainCopy.toolDescription("git_status") == "Check a project's uncommitted changes.")
        #expect(CapabilitiesPlainCopy.toolDescription("swift_build") == "Build a Swift project.")
    }

    @Test func unknownAddedToolsDeliberatelyUseGenericCopy() {
        // Dynamically added tools have no app-owned description to promise.
        #expect(CapabilitiesPlainCopy.toolDescription("mcp__custom__tool") == "An additional tool I can use for your tasks.")
    }
}
