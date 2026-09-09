import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.inbox.lanePickerDefault
@Suite("Desk inbox lane picker default")
struct DeskInboxLanePickerDefaultEvalTests {
    @Test("fresh inbox opens on For you and presents that lane first")
    func initialLaneAndPickerOrderFavorHumanInbox() {
        #expect(InboxLanePresentation.initialLane == .forYou)
        #expect(InboxLanePresentation.pickerLanes.first == .forYou)
        #expect(InboxLanePresentation.pickerLanes == [.forYou, .system])
        #expect(InboxLanePresentation.pickerLanes.count == InboxLane.allCases.count)
        #expect(InboxLane.allCases.allSatisfy { InboxLanePresentation.pickerLanes.contains($0) })
    }

    @Test("mounted InboxView binds its local state and segmented picker to the shared route")
    func inboxViewUsesExplicitDefaultAndOrder() throws {
        let source = try AppSourceScraping.appSource("InboxView.swift")
        #expect(source.contains("@State private var lane: InboxLane = InboxLanePresentation.initialLane"))
        #expect(source.contains("ForEach(InboxLanePresentation.pickerLanes) { candidate in"))
        #expect(source.contains("Picker(\"Notification category\", selection: $lane)"))
        #expect(!source.contains("ForEach(InboxLane.allCases) { candidate in"))
    }
}
