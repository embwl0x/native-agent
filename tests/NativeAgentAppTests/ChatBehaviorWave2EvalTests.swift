import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

/// Behavioral checks for value-only presentation seams used by the live Mac
/// chat surface. These intentionally do not inspect Swift source or recreate
/// view-local state; each assertion calls the production function the view
/// renders.
@Suite("Chat behavior wave 2")
struct ChatBehaviorWave2EvalTests {
    private func session(
        _ id: String,
        title: String,
        messageCount: Int = 0
    ) throws -> ChatSession {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "title": title,
            "messageCount": messageCount,
            "createdAt": "2026-08-24T00:00:00Z",
        ])
        return try JSONDecoder().decode(ChatSession.self, from: data)
    }

    @Test("missing transcript usage stays unknown instead of lying as zero")
    func contextFillPreservesAnAbsentTranscriptFigure() {
        #expect(ContextFillPresentation.transcriptTokens(nil) == "unknown")
        #expect(ContextFillPresentation.transcriptTokens(0) == "0")
        #expect(ContextFillPresentation.transcriptTokens(12_345) != "unknown")
    }

    @Test("the header has an honest fallback title and count grammar")
    func headerTitleAndCountRemainReadableForDegenerateSessions() throws {
        let blank = try session("blank", title: " \n\t ", messageCount: 0)
        let named = try session("named", title: "  Planning  ", messageCount: 1)

        #expect(ChatHeaderPresentation.title(for: nil) == "Chat")
        #expect(ChatHeaderPresentation.title(for: blank) == "New Chat")
        #expect(ChatHeaderPresentation.title(for: named) == "Planning")
        #expect(ChatHeaderPresentation.messageCount(nil) == "0 messages")
        #expect(ChatHeaderPresentation.messageCount(1) == "1 message")
        #expect(ChatHeaderPresentation.messageCount(2) == "2 messages")
    }

    @Test("the context-ready label only appears for a real fingerprint")
    func headerDoesNotPresentAnEmptyFingerprintAsContextReady() {
        #expect(!ChatHeaderPresentation.hasContextFingerprint(nil))
        #expect(!ChatHeaderPresentation.hasContextFingerprint(""))
        #expect(ChatHeaderPresentation.hasContextFingerprint("ctx-verified"))
    }

    @Test("pinned and unpinned sidebar sections remain a true partition")
    func sidebarSectionsKeepPinOrderWithoutDuplicateOrMissingRows() throws {
        let a = try session("a", title: "Alpha")
        let b = try session("b", title: "Beta")
        let c = try session("c", title: "Gamma")
        let invisiblePinned = try session("hidden", title: "Hidden")
        let sections = ChatSidebarSections.split(
            visible: [a, b, c],
            orderedPinned: [c, invisiblePinned, a, a]
        )

        #expect(sections.pinned.map(\.id) == ["c", "a"])
        #expect(sections.unpinned.map(\.id) == ["b"])
        #expect(
            Set(sections.pinned.map(\.id)).union(sections.unpinned.map(\.id))
                == Set(["a", "b", "c"])
        )
    }

    @Test("a stale measured turn card cannot leave the idle transcript inflated")
    func turnCardClearanceHasAFloorAndResetsWhenNoCardIsVisible() {
        let floor = MacChatTurnCardMetrics.floatingClearance
        #expect(ChatViewportPresentation.turnCardClearance(
            showingTurnCard: false, measuredHeight: floor * 3
        ) == floor)
        #expect(ChatViewportPresentation.turnCardClearance(
            showingTurnCard: true, measuredHeight: floor / 2
        ) == floor)
        #expect(ChatViewportPresentation.turnCardClearance(
            showingTurnCard: true, measuredHeight: floor * 2
        ) == floor * 2)
    }

    @Test("Latest is available exactly when auto-follow is disarmed")
    @MainActor
    func latestPillTracksTheActualScrollCoordinatorState() {
        let coordinator = ChatScrollCoordinator()
        #expect(!ChatViewportPresentation.shouldShowLatestPill(
            autoFollow: coordinator.autoFollow
        ))

        coordinator.disarmFollow()
        #expect(ChatViewportPresentation.shouldShowLatestPill(
            autoFollow: coordinator.autoFollow
        ))

        coordinator.forceFollow()
        #expect(!ChatViewportPresentation.shouldShowLatestPill(
            autoFollow: coordinator.autoFollow
        ))
    }

    @Test("slash menu never advertises a hidden developer route")
    func slashMenuRegistryHasUniqueReachableCommandsAtBothVisibilityLevels() {
        let normal = ChatSlashCommandRegistry.visible(showDeveloperSurfaces: false)
        let developer = ChatSlashCommandRegistry.visible(showDeveloperSurfaces: true)

        #expect(Set(normal.map(\.command)).count == normal.count)
        #expect(Set(developer.map(\.command)).count == developer.count)
        #expect(normal.allSatisfy { !$0.developerOnly })
        #expect(developer.contains(where: { $0.route == .nextgen }))
        #expect(normal.allSatisfy {
            ChatSlashCommandRegistry.descriptor(named: $0.command) == $0
        })
        #expect(developer.allSatisfy {
            ChatSlashCommandRegistry.helpText(showDeveloperSurfaces: true)
                .contains($0.helpLine)
        })
    }
}
