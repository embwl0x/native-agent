import AppKit
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// Report-only app-chat rows promoted here call the production presentation
// seams that their views consume. No source-shape checks are used: every case
// pins an honest visible value, a receipt boundary, or a state transition.

private func appChatSession(_ id: String, title: String) throws -> ChatSession {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "title": title,
        "messageCount": 0,
        "createdAt": "2026-08-24T00:00:00Z",
    ])
    return try JSONDecoder().decode(ChatSession.self, from: data)
}

private func appChatMessage(
    _ id: String,
    role: String,
    content: String
) -> ChatMessage {
    ChatMessage(
        id: id,
        role: role,
        content: content,
        createdAt: "2026-08-24T00:00:00Z"
    )
}

@Suite("App chat report-only truth seams")
struct AppChatReportOnlyTruthSeamsTests {
    // app.chat / ui.chat.contextReceipt.metricTiles,
    // ui.chat.contextReceipt.emptyState, ui.chat.contextReceipt.pillRow,
    // ui.chat.contextReceipt.budgetDetail, ui.chat.contextReceipt.stringList,
    // ui.chat.contextReceipt.sections
    @Test("receipt readouts preserve absence, identity, precedence, and truncation truth")
    func receiptPresentationDoesNotFabricateValues() {
        #expect(ContextReceiptPresentation.metricValue(nil) == "unknown")
        #expect(ContextReceiptPresentation.metricValue(0) == "0")
        #expect(!ContextReceiptPresentation.hasReceiptIdentity(fingerprint: nil, runID: nil))
        #expect(ContextReceiptPresentation.hasReceiptIdentity(fingerprint: nil, runID: "run-1"))
        #expect(ContextReceiptPresentation.hasReceiptIdentity(fingerprint: "", runID: nil))

        #expect(ContextReceiptPresentation.cacheDisplayText(
            status: "fresh", hit: false, budgetStatus: "stale"
        ) == "fresh")
        #expect(ContextReceiptPresentation.cacheDisplayText(
            status: nil, hit: false, budgetStatus: "stale"
        ) == "cache miss")
        #expect(ContextReceiptPresentation.cacheDisplayText(
            status: "", hit: nil, budgetStatus: "fallback"
        ) == "fallback")
        #expect(ContextReceiptPresentation.optionalValue(nil) == "unknown")
        #expect(ContextReceiptPresentation.optionalText(nil) == "unknown")
        #expect(ContextReceiptPresentation.optionalText("") == "unknown")
        #expect(ContextReceiptPresentation.remainingCount(total: 6, displayed: 6) == nil)
        #expect(ContextReceiptPresentation.remainingCount(total: 7, displayed: 6) == 1)
        #expect(ContextReceiptPresentation.remainingCount(total: 40, displayed: 8) == 32)
    }

    // app.chat / ui.chat.transcript.liveToolFlipBox
    @Test("live tool flip box stays live until nonblank assistant text begins")
    func liveToolGroupingRejectsWhitespaceAndSettlesOnText() {
        let tool = appChatMessage("tool-1", role: "tool", content: "read_file")
        let groups = [MessageGroup(id: "toolrun-tool-1", messages: [tool], isToolGroup: true)]
        #expect(ChatTranscriptPresentation.liveToolGroupID(
            groups: groups, isStreaming: true, lastMessage: tool
        ) == "toolrun-tool-1")
        #expect(ChatTranscriptPresentation.liveToolGroupID(
            groups: groups,
            isStreaming: true,
            lastMessage: appChatMessage("assistant-empty", role: "assistant", content: " \n\t ")
        ) == "toolrun-tool-1")
        #expect(ChatTranscriptPresentation.liveToolGroupID(
            groups: groups,
            isStreaming: true,
            lastMessage: appChatMessage("assistant-text", role: "assistant", content: "Started")
        ) == nil)
        #expect(ChatTranscriptPresentation.liveToolGroupID(
            groups: groups, isStreaming: false, lastMessage: tool
        ) == nil)
    }

    // app.chat / ui.chat.transcript.toolPill
    @Test("tool receipts distinguish pending, failure, zero duration, and absence")
    func toolPillNeverConvertsUnknownIntoSuccess() {
        #expect(ToolPillPresentation.outcome(ok: nil) == .pending)
        #expect(ToolPillPresentation.outcome(ok: true) == .succeeded)
        #expect(ToolPillPresentation.outcome(ok: false) == .failed)
        #expect(ToolPillPresentation.durationText(nil) == "unknown duration")
        #expect(ToolPillPresentation.durationText(0) == "0ms")
        #expect(ToolPillPresentation.durationText(19) == "19ms")
    }

    // app.chat / ui.chat.transcript.toolDiff
    @Test("tool diff aligns insertions and reports every omitted line")
    func toolDiffPreservesAlignmentAndTruncationTruth() {
        let inserted = ToolDiffPresentation.lines(
            before: ["one", "two", "three"].joined(separator: "\n"),
            after: ["one", "inserted", "two", "three"].joined(separator: "\n")
        )
        #expect(inserted == [" one", "+inserted", " two", " three"])

        let before = (0..<64).map { "before-\($0)" }.joined(separator: "\n")
        let after = (0..<64).map { "after-\($0)" }.joined(separator: "\n")
        let lines = ToolDiffPresentation.lines(before: before, after: after)
        #expect(lines.count == 61)
        #expect(lines.last == "... (68 more lines)")
        #expect(lines.contains("-before-0"))
    }

    // app.chat / ui.chat.transcript.nonImageAttachmentChip
    @Test("attachment branches form an exact partition even for duplicate ids")
    func attachmentsNeverDisappearBetweenImageAndChipBranches() {
        let attachments = [
            PersistedAttachment(id: "image-local", type: "image", mime: "image/png", name: "a.png", byteSize: 1, path: "/tmp/a.png"),
            PersistedAttachment(id: "image-remote", type: " IMAGE ", mime: "image/png", name: "b.png", byteSize: 1, path: nil),
            PersistedAttachment(id: "pdf", type: "file", mime: "application/pdf", name: "a.pdf", byteSize: 1, path: "/tmp/a.pdf"),
            PersistedAttachment(id: "image-local", type: "image", mime: "image/jpeg", name: "duplicate.jpg", byteSize: 1, path: " "),
        ]
        let partition = ChatAttachmentPresentation.partition(attachments)
        #expect(partition.localImages.map(\.name) == ["a.png"])
        #expect(partition.chips.map(\.name) == ["b.png", "a.pdf", "duplicate.jpg"])
        #expect(partition.localImages.count + partition.chips.count == attachments.count)
    }

    // app.chat / api.SessionDragSource.desktopDropPredicate
    @Test("desktop detach requires a released mouse and a point outside every app window")
    func sessionDragPredicateFailsClosedAtWindowEdges() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 200)
        #expect(!SessionDragPresentation.shouldDetach(
            pressedMouseButtons: 1, screenPoint: NSPoint(x: 350, y: 350), visibleWindowFrames: [frame]
        ))
        #expect(!SessionDragPresentation.shouldDetach(
            pressedMouseButtons: 0, screenPoint: NSPoint(x: 150, y: 150), visibleWindowFrames: [frame]
        ))
        #expect(!SessionDragPresentation.shouldDetach(
            pressedMouseButtons: 0, screenPoint: NSPoint(x: 300.5, y: 150), visibleWindowFrames: [frame]
        ))
        #expect(SessionDragPresentation.shouldDetach(
            pressedMouseButtons: 0, screenPoint: NSPoint(x: 302, y: 150), visibleWindowFrames: [frame]
        ))
    }

    // app.chat / api.DetachedChatPanel.framePlacement
    @Test("detached frame placement chooses the target screen and fails safely without one")
    func detachedFramePlacementHonorsScreenSelectionAndDegeneracy() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1_000, y: 0, width: 1000, height: 800)
        let offRightBottom = DetachedChatFramePlacement.place(
            NSRect(x: 1_980, y: -500, width: 520, height: 600),
            near: NSPoint(x: 1_900, y: 300),
            visibleFrames: [screen, secondary],
            fallbackFrame: screen
        )
        #expect(offRightBottom.minX == 1_480)
        #expect(offRightBottom.minY == 0)
        #expect(offRightBottom.maxX == secondary.maxX)
        let offLeftTop = DetachedChatFramePlacement.place(
            NSRect(x: -20, y: 790, width: 520, height: 600),
            near: NSPoint(x: -1, y: 900),
            visibleFrames: [NSRect(x: 0, y: 0, width: 1, height: 1)],
            fallbackFrame: screen
        )
        #expect(offLeftTop.minX == 0)
        #expect(offLeftTop.maxY == screen.maxY)
        let original = NSRect(x: 40, y: 40, width: 520, height: 600)
        #expect(DetachedChatFramePlacement.place(
            original,
            near: .zero,
            visibleFrames: [NSRect(x: 0, y: 0, width: 0, height: 500)],
            fallbackFrame: nil
        ) == original)
    }

    // app.chat / ui.chat.header.title, ui.chat.header.messageCountLine,
    // ui.chat.sidebar.pinnedSectionSplit, ui.chat.transcript.turnCardClearance,
    // ui.chat.transcript.latestPill, ui.chat.contextFillBar
    @Test("shared chat presentation seams retain their failure-state guarantees")
    func sharedPresentationSeamsRemainHonest() throws {
        let blank = try appChatSession("blank", title: "  \n")
        let pinned = try appChatSession("pinned", title: "Pinned")
        let unpinned = try appChatSession("unpinned", title: "Unpinned")
        let stalePinned = try appChatSession("pinned", title: "Old title")
        let missingPinned = try appChatSession("missing", title: "Removed")
        let sections = ChatSidebarSections.split(
            visible: [pinned, unpinned],
            orderedPinned: [missingPinned, stalePinned, stalePinned]
        )

        #expect(ChatHeaderPresentation.title(for: nil) == "Chat")
        #expect(ChatHeaderPresentation.title(for: blank) == "New Chat")
        #expect(ChatHeaderPresentation.metadata(count: 1, fingerprint: nil)
            == .init(messageCount: "1 message", showsContextReady: false))
        #expect(ChatHeaderPresentation.metadata(count: 2, fingerprint: "")
            == .init(messageCount: "2 messages", showsContextReady: false))
        #expect(ChatHeaderPresentation.metadata(count: 2, fingerprint: "ctx-1")
            == .init(messageCount: "2 messages", showsContextReady: true))
        #expect(sections.pinned.map(\.id) == ["pinned"])
        #expect(sections.pinned.first?.title == "Pinned")
        #expect(sections.unpinned.map(\.id) == ["unpinned"])
        let floor = MacChatTurnCardMetrics.floatingClearance
        #expect(ChatViewportPresentation.turnCardClearance(showingTurnCard: false, measuredHeight: 999) == floor)
        #expect(ChatViewportPresentation.turnCardClearance(showingTurnCard: true, measuredHeight: floor / 2) == floor)
        #expect(ChatViewportPresentation.turnCardClearance(showingTurnCard: true, measuredHeight: floor * 2) == floor * 2)
        #expect(ChatViewportPresentation.shouldShowLatestPill(autoFollow: false))
        #expect(!ChatViewportPresentation.shouldShowLatestPill(autoFollow: true))
        #expect(ChatViewportPresentation.scrollFollowAction(
            deltaY: 0.5, bottomSpacerVisible: true, autoFollow: true
        ) == .none)
        #expect(ChatViewportPresentation.scrollFollowAction(
            deltaY: 0.6, bottomSpacerVisible: true, autoFollow: true
        ) == .disarm)
        #expect(ChatViewportPresentation.scrollFollowAction(
            deltaY: -0.6, bottomSpacerVisible: false, autoFollow: false
        ) == .none)
        #expect(ChatViewportPresentation.scrollFollowAction(
            deltaY: -0.6, bottomSpacerVisible: true, autoFollow: false
        ) == .rearm)
        #expect(ContextFillPresentation.transcriptTokens(nil) == "unknown")
        #expect(ContextFillPresentation.transcriptTokens(0) == "0")
        #expect(ContextFillPresentation.usage(usedTokens: 125, budget: 100)
            == .init(percent: 125, fillFraction: 1, isOverBudget: true))
        #expect(ContextFillPresentation.usage(usedTokens: 25, budget: 100)
            == .init(percent: 25, fillFraction: 0.25, isOverBudget: false))
    }
}
