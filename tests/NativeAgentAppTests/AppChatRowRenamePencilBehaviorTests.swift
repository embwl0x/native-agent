import ChatOrchestration
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private struct RowRenamePencilFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-chat-row-rename-pencil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite("App chat sidebar rename-pencil behavior", .serialized)
struct AppChatRowRenamePencilBehaviorTests {
    private func appModel(root: URL) -> AppModel {
        AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
    }

    // app.chat / ui.chat.sidebar.rowRenamePencil
    @Test("sidebar pencil shares one visibility predicate while the non-hover context route remains available")
    func renamePencilPresentationKeepsHoverGatesAndContextRouteCoherent() {
        let nonHover = SessionRowRenamePencilPresentation.make(
            renameAvailable: true,
            hovering: false,
            renaming: false
        )
        #expect(nonHover.opacity == 0)
        #expect(!nonHover.allowsHitTesting)
        #expect(nonHover.accessibilityHidden)
        #expect(nonHover.contextMenuRenameAvailable)

        let hovering = SessionRowRenamePencilPresentation.make(
            renameAvailable: true,
            hovering: true,
            renaming: false
        )
        #expect(hovering.opacity == 1)
        #expect(hovering.allowsHitTesting)
        #expect(!hovering.accessibilityHidden)
        #expect(hovering.contextMenuRenameAvailable)

        let editing = SessionRowRenamePencilPresentation.make(
            renameAvailable: true,
            hovering: true,
            renaming: true
        )
        #expect(editing.opacity == 0)
        #expect(!editing.allowsHitTesting)
        #expect(editing.accessibilityHidden)
        #expect(editing.contextMenuRenameAvailable)

        let unavailable = SessionRowRenamePencilPresentation.make(
            renameAvailable: false,
            hovering: true,
            renaming: false
        )
        #expect(unavailable.opacity == 0)
        #expect(!unavailable.allowsHitTesting)
        #expect(unavailable.accessibilityHidden)
        #expect(!unavailable.contextMenuRenameAvailable)
    }

    // app.chat / ui.chat.sidebar.rowRenamePencil
    @Test("sidebar rename drafts commit and cancel through their production owners")
    func renameCommitPreservesCancellationAndReloadTruth() async throws {
        let fixture = try RowRenamePencilFixture()
        defer { fixture.remove() }
        let session = try await NativeClient.createChatSession(title: "Original", dataRoot: fixture.root)
        let model = appModel(root: fixture.root)
        model.chatSessions = [session]

        // Draft ownership stays in the shared row/tab state machine. A cancel
        // reports no title to ChatView's `onRenameEnd`, so it cannot reach the
        // AppModel persistence owner.
        var cancelled = ChatRenameStateMachine()
        cancelled.begin(title: session.title)
        cancelled.draftTitle = "Half typed"
        #expect(cancelled.cancel() == .cancelled)
        #expect(!cancelled.isRenaming)

        var invalid = ChatRenameStateMachine()
        invalid.begin(title: session.title)
        invalid.draftTitle = " \n\t "
        #expect(invalid.submit(currentTitle: session.title) == .cancelled)
        let beforeCommit = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        #expect(beforeCommit.first(where: { $0.id == session.id })?.title == "Original")
        #expect(model.chatSessions.first(where: { $0.id == session.id })?.title == "Original")

        // Enter/focus-loss delegates the cleaned committed title to the shared
        // AppModel mutation boundary; this is the sole route that writes the
        // session index and refreshes its visible snapshot.
        var committed = ChatRenameStateMachine()
        committed.begin(title: session.title)
        committed.draftTitle = "  Renamed from sidebar  "
        let result = committed.submit(currentTitle: session.title)
        let title: String
        guard case .committed(let cleanedTitle) = result else {
            Issue.record("a non-empty changed draft must produce the title that ChatView forwards to AppModel")
            return
        }
        title = cleanedTitle
        #expect(title == "Renamed from sidebar")
        #expect(!committed.isRenaming)
        await model.renameChatSession(id: session.id, title: title)

        let reloaded = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        #expect(reloaded.first(where: { $0.id == session.id })?.title == "Renamed from sidebar")
        #expect(model.chatSessions.first(where: { $0.id == session.id })?.title == "Renamed from sidebar")
    }
}
