import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Chat calm-surface architecture")
struct ChatCalmSurfaceArchitectureTests {
    @Test func sessionRailIsSessionFirstWithoutDashboardPanels() throws {
        let source = try AppSourceScraping.appSource("ChatView.swift")
        let sidebar = try sessionSidebar(in: source)

        #expect(!sidebar.contains("LivingStatusPanel()"))
        #expect(!sidebar.contains("WhatsRunningPanel()"))
        #expect(occurrences(of: "HealthCardPill()", in: sidebar) == 1)

        let search = try #require(sidebar.range(of: "TextField(\"Search sessions\""))
        let staleStatus = try #require(sidebar.range(of: "panelStaleNotice(for: .chat)"))
        let sessionList = try #require(sidebar.range(of: "ScrollView {"))
        #expect(search.lowerBound < staleStatus.lowerBound)
        #expect(search.lowerBound < sessionList.lowerBound)
        #expect(sidebar.contains(".accessibilityLabel(\"Search sessions\")"))
    }

    @Test func globalActivityOwnershipAndPanelModelsRemainIntact() throws {
        let content = try AppSourceScraping.appSource("ContentView.swift")
        let activity = try AppSourceScraping.appSource("ActivityView.swift")
        let running = try AppSourceScraping.appSource("ChatRuntimeStatusChrome.swift")
        let runningOwner = try AppSourceScraping.appSource("AppModel+HealthEmbeddings.swift")
        let living = try AppSourceScraping.appSource("LivingStatusPanel.swift")

        #expect(content.contains("case .activity: ActivityView()"))
        #expect(activity.contains("struct ActivityView: View"))
        #expect(activity.contains("Text(\"Needs your eyes\")"))
        #expect(running.contains("struct WhatsRunningPanel: View"))
        #expect(runningOwner.contains("func loadWhatsRunning()"))
        #expect(living.contains("struct LivingStatusPanel: View"))
    }

    @Test func architecturePinsTheSessionFirstOwnershipBoundary() throws {
        let root = try AppSourceScraping.repositoryRoot()
        let blueprintURL = root.appendingPathComponent("docs/ARCHITECTURE_BLUEPRINT.md")
        let blueprint = try String(contentsOf: blueprintURL, encoding: .utf8)

        #expect(blueprint.contains("Its session rail is session-first"))
        #expect(blueprint.contains("Global running-work and aggregate Today panels are intentionally not composed into Chat"))
        #expect(blueprint.contains("canonical Activity, Desk, approval, health, and cognition owners remain unchanged"))
    }

    @Test func transcriptRenderAuditBaselineRemainsExactlyInstrumented() throws {
        let source = try AppSourceScraping.appSource("ChatMessageListView.swift")

        for key in ["grouper.compute", "markdown.parse", "bubble.body"] {
            #expect(
                occurrences(of: "RenderAudit.bump(\"\(key)\")", in: source) == 1,
                "The existing \(key) render-audit baseline must remain singular and measurable."
            )
        }
    }

    private func sessionSidebar(in source: String) throws -> String {
        let start = try #require(source.range(of: "var sessionSidebar: some View"))
        let end = try #require(
            source.range(
                of: "\n    func sessionSectionHeader",
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let match = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = match.upperBound..<haystack.endIndex
        }
        return count
    }
}
