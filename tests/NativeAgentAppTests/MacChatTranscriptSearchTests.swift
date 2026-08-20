import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac chat transcript search")
struct MacChatTranscriptSearchTests {
    private func message(_ id: String, role: String = "user", content: String) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content)
    }

    @Test func documentsFollowTheVisibleConversationBoundary() {
        let documents = MacChatTranscriptSearch.documents(from: [
            message("user", content: "Human text"),
            message("tool", role: "tool", content: "internal tool payload"),
            message("tool-summary", role: "system", content: "[tool: hidden summary"),
            message("system", role: "system", content: "Visible compaction summary"),
            message("assistant", role: "assistant", content: "Assistant text"),
        ])

        #expect(documents.map(\.messageID) == ["user", "system", "assistant"])
        #expect(documents.map(\.ordinal) == [0, 3, 4])
    }

    @Test func matchingIsCaseDiacriticAndWidthInsensitiveInChronologicalOrder() {
        let documents = MacChatTranscriptSearch.documents(from: [
            message("first", content: "Café planning"),
            message("middle", content: "unrelated"),
            message("last", role: "assistant", content: "CAFE complete"),
        ])

        let response = MacChatTranscriptSearch.search(query: "ｃａｆｅ", documents: documents)

        #expect(response.results.map(\.messageID) == ["first", "last"])
        #expect(response.totalMatchCount == 2)
        #expect(response.isTruncated == false)
    }

    @Test func queryWorkIsScalarBoundedBeforeComparison() {
        let oversized = String(repeating: "e\u{301}", count: 400) + "needle"
        let bounded = MacChatTranscriptSearch.boundedQuery(oversized)

        #expect(bounded.unicodeScalars.count == MacChatTranscriptSearch.maximumQueryScalars)
        #expect(!bounded.contains("needle"))
    }

    @Test @MainActor func controllerDisplaysExactlyTheBoundedQueryItSearches() {
        let controller = MacChatTranscriptSearchController()
        let oversized = String(repeating: "x", count: 300)

        controller.setQuery(oversized)

        #expect(controller.query.unicodeScalars.count == MacChatTranscriptSearch.maximumQueryScalars)
    }

    @Test func repetitiveHistoriesReportExactTotalsAndRetainNewestNavigationTargets() {
        let documents = (0..<2_505).map {
            MacChatTranscriptSearchDocument(
                messageID: "message-\($0)",
                ordinal: $0,
                content: "needle \($0)"
            )
        }

        let response = MacChatTranscriptSearch.search(
            query: "needle",
            documents: documents,
            maximumResults: 2_000
        )

        #expect(response.totalMatchCount == 2_505)
        #expect(response.results.count == 2_000)
        #expect(response.results.first?.messageID == "message-505")
        #expect(response.results.last?.messageID == "message-2504")
        #expect(response.isTruncated)
    }

    @Test func supersededScansStopWithoutPublishingPartialTotals() {
        let documents = (0..<100).map {
            MacChatTranscriptSearchDocument(messageID: "\($0)", ordinal: $0, content: "needle")
        }

        let response = MacChatTranscriptSearch.searchCancellable(
            query: "needle",
            documents: documents,
            shouldCancel: { true }
        )

        #expect(response == nil)
    }

    @Test func cursorStartsAtNewestAndWrapsBothDirections() {
        var cursor = MacChatTranscriptSearchCursor(resultCount: 3)
        #expect(cursor.selectedIndex == 2)
        #expect(cursor.selectNext(resultCount: 3) == 0)
        #expect(cursor.selectPrevious(resultCount: 3) == 2)
        #expect(cursor.selectPrevious(resultCount: 3) == 1)
        #expect(cursor.selectNext(resultCount: 0) == nil)
        #expect(cursor.selectedIndex == nil)
    }

    @Test @MainActor func controllerReportsAsyncStateAndPreservesAStillValidSelection() async throws {
        let controller = MacChatTranscriptSearchController()
        let initial = [
            message("older", content: "needle first"),
            message("newer", role: "assistant", content: "needle second"),
        ]
        controller.replaceSource(messages: initial, sessionID: "session")
        controller.setQuery("needle")

        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .results)
        #expect(controller.statusText == "2 of 2 messages")
        #expect(controller.selectedMessageID == "newer")

        _ = controller.selectPrevious()
        #expect(controller.selectedMessageID == "older")
        controller.replaceSource(
            messages: initial + [message("tail", role: "assistant", content: "no match")],
            sessionID: "session"
        )

        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .results)
        #expect(controller.selectedMessageID == "older")

        controller.setQuery("absent")
        #expect(controller.phase == .searching)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .noResults)
        #expect(controller.statusText == "No matches")
        #expect(controller.selectedMessageID == nil)
    }

    @Test @MainActor func streamingTailUpdatesDoNotRequireAFullSourceReplacement() async throws {
        let controller = MacChatTranscriptSearchController()
        controller.replaceSource(
            messages: [message("older", content: "needle"), message("temporary", role: "assistant", content: "")],
            sessionID: "session"
        )
        controller.setQuery("needle")
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.totalMatchCount == 1)

        controller.replaceLastMessage(
            message("persisted", role: "assistant", content: "needle arrived"),
            ordinal: 1,
            sessionID: "session"
        )
        try await Task.sleep(for: .milliseconds(300))

        #expect(controller.totalMatchCount == 2)
        #expect(controller.results.map(\.messageID) == ["older", "persisted"])
        #expect(controller.selectedMessageID == "older",
                "A live tail update must not yank the reader away from the selected older match.")
    }

    @Test func mainAndDetachedWindowsUseTheSameSearchAndTranscriptOwners() throws {
        let main = try AppSourceScraping.appSource("ChatView.swift")
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        let list = try AppSourceScraping.appSource("ChatMessageListView.swift")

        for source in [main, detached] {
            #expect(source.contains("MacChatTranscriptSearchBar("))
            #expect(source.contains("ChatMessageListView("))
            #expect(source.contains("transcriptSearch.selectionRevision"))
            #expect(source.contains("highlightedMessageID:"))
            #expect(source.contains("refreshTranscriptSearchTailIfPresented()"))
        }
        #expect(!main.contains("ForEach(chatGroups)"))
        #expect(list.contains("MacChatTranscriptSearch.scrollTargetID(for: msg.id)"))
        #expect(list.contains(".accessibilityAddTraits(.isSelected)"))
    }

    @Test func searchIsKeyboardNativeAndAccessible() throws {
        let commands = try AppSourceScraping.appSource("ChatFocusedCommands.swift")
        let search = try AppSourceScraping.appSource("MacChatTranscriptSearch.swift")
        let header = try AppSourceScraping.appSource("ChatHeaderView.swift")

        #expect(commands.contains("Button(\"Find in Conversation…\""))
        #expect(commands.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        #expect(commands.contains(".keyboardShortcut(\"g\", modifiers: .command)"))
        #expect(commands.contains(".keyboardShortcut(\"g\", modifiers: [.command, .shift])"))
        #expect(search.contains(".accessibilityLabel(\"Search conversation\")"))
        #expect(search.contains(".accessibilityLabel(\"Previous search match\")"))
        #expect(search.contains(".accessibilityLabel(\"Next search match\")"))
        #expect(header.contains(".help(\"Search conversation (Command-F)\")"))
    }

    @Test func bothComposersUseOneQuieterActionHierarchyWithoutLosingControls() throws {
        let main = try AppSourceScraping.appSource("ChatView.swift")
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        let chrome = try AppSourceScraping.appSource("ChatComposerChrome.swift")
        let commands = try AppSourceScraping.appSource("ChatFocusedCommands.swift")

        #expect(occurrences(of: "MacChatComposerControlStrip(", in: main) == 1)
        #expect(occurrences(of: "MacChatComposerControlStrip(", in: detached) == 1)
        #expect(!main.contains("ComposerMetaRow("))
        #expect(!chrome.contains("struct ComposerMetaRow"))

        for control in ["Voice Input", "Show Agent My Screen", "Attach Image or File…"] {
            #expect(chrome.contains(control))
        }
        #expect(chrome.contains("if isRunning"))
        #expect(chrome.contains("Button(action: onStop)"))
        #expect(chrome.contains("Button(action: onSend)"))
        #expect(commands.contains("Add Attachment…"))
        #expect(commands.contains("Toggle Voice Input"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let match = haystack.range(of: needle, range: range) {
            count += 1
            range = match.upperBound..<haystack.endIndex
        }
        return count
    }
}
