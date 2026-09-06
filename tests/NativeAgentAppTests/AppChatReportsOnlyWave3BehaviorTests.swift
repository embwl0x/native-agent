import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private func wave3Session(
    _ id: String,
    title: String = "Chat",
    updatedAt: String? = nil,
    archived: Bool? = nil
) throws -> ChatSession {
    var row: [String: Any] = [
        "id": id,
        "title": title,
        "createdAt": "2026-08-01T00:00:00Z",
    ]
    if let updatedAt { row["updatedAt"] = updatedAt }
    if let archived { row["archived"] = archived }
    return try JSONDecoder().decode(
        ChatSession.self,
        from: JSONSerialization.data(withJSONObject: row)
    )
}

@MainActor
@Suite("App chat reports-only wave 3 behavior")
struct AppChatReportsOnlyWave3BehaviorTests {
    // app.chat / ui.chat.sidebar.rowRenameEditor, ui.chat.pinnedTab.renameEditor
    @Test("both rename editors share one complete single-fire state machine")
    func renameStateMachineRejectsStructuralAndDuplicateEnds() {
        var sidebarEditor = ChatRenameStateMachine()
        sidebarEditor.begin(title: "Original")
        sidebarEditor.draftTitle = "  Sidebar update  "
        #expect(sidebarEditor.submit(currentTitle: "Original") == .committed("Sidebar update"))
        #expect(sidebarEditor.cancel() == .ignored)

        var pinnedTabEditor = ChatRenameStateMachine()
        pinnedTabEditor.begin(title: "Original")
        pinnedTabEditor.draftTitle = "  Tab update  "
        #expect(pinnedTabEditor.focusChanged(isFocused: true, currentTitle: "Original") == .ignored)
        #expect(pinnedTabEditor.focusChanged(isFocused: false, currentTitle: "Original") == .committed("Tab update"))
        #expect(pinnedTabEditor.cancel() == .ignored)

        var state = ChatRenameStateMachine()
        state.begin(title: "Original")
        state.draftTitle = " \n\t "
        #expect(state.submit(currentTitle: "Original") == .cancelled)
        #expect(state.focusChanged(isFocused: false, currentTitle: "Original") == .ignored)

        state.begin(title: "Original")
        #expect(state.submit(currentTitle: "Original") == .cancelled)
        #expect(state.focusChanged(isFocused: false, currentTitle: "Original") == .ignored)

        state.begin(title: "Original")
        state.draftTitle = "Half typed"
        #expect(state.cancel() == .cancelled)
        #expect(state.focusChanged(isFocused: false, currentTitle: "Original") == .ignored)

        state.syncExternalTitle("Renamed elsewhere")
        #expect(state.draftTitle == "Renamed elsewhere")
        state.begin(title: "Renamed elsewhere")
        state.draftTitle = "Local edit"
        state.syncExternalTitle("New external title")
        #expect(state.draftTitle == "Local edit")
    }

    // app.chat / ui.chat.emptyState
    @Test("empty-state suggestion persists to the session tapped before a switch")
    func emptyStateSuggestionUsesTheCanonicalDraftInjectionAction() {
        let model = AppModel()
        let first = "suggestion-a-\(UUID().uuidString)"
        let second = "suggestion-b-\(UUID().uuidString)"
        model.activeChatSessionId = first

        var draftText = ""
        var draftSessionID = "stale-session"
        ChatEmptyStateSuggestionAction.apply(
            "Draft a reply in my voice",
            model: model,
            activeSessionID: model.activeChatSessionId,
            draftText: &draftText,
            draftSessionID: &draftSessionID
        )
        model.activeChatSessionId = second
        #expect(draftText == "Draft a reply in my voice")
        #expect(draftSessionID == first)
        #expect(model.chatDraft(for: second).isEmpty)
        #expect(model.chatDraft(for: first) == "Draft a reply in my voice")
        #expect(model.chatDraftInjectionGeneration == 1)
    }

    // app.chat / ui.chat.queue.queueMenu
    @Test("queue menu ordinals are assigned after hidden turns are removed")
    func queueMenuUsesTheDisplayedTurnIdentity() {
        let hidden = QueuedChatTurn(id: "hidden", text: "internal", hideUserBubble: true)
        let first = QueuedChatTurn(id: "first", text: "first")
        let second = QueuedChatTurn(id: "second", text: "second")
        let turns = [hidden, first, second]
        let menu = ChatQueuePresentation.menuItems(turns)
        #expect(menu.map(\.turn.id) == ["first", "second"])
        #expect(menu.map(\.sendLabel) == ["Send 1 now: first", "Send 2 now: second"])
        #expect(menu.map(\.removeLabel) == ["Remove 1: first", "Remove 2: second"])
        #expect(ChatQueuePresentation.countLabel(turns) == "2 queued")

        let model = AppModel()
        let sessionID = "queue-menu-\(UUID().uuidString)"
        model.queuedChatTurnsBySession[sessionID] = turns
        #expect(model.promoteQueuedChatTurn(menu[1].turn.id, sessionId: sessionID))
        #expect(model.queuedChatTurns(for: sessionID).map(\.id) == ["second", "hidden", "first"])
    }

    // app.chat / api.CommandPalette.ranking
    @Test("palette ranking is deterministic and prioritizes exact visible matches")
    func commandPaletteRankingUsesStablePriority() {
        let pool = [
            PaletteItem(id: "tab", title: "Work", subtitle: "Primary", systemImage: "1", kind: .tab(.chat)),
            PaletteItem(id: "chat", title: "Work", subtitle: "Chat session", systemImage: "2", kind: .chatSession("chat-session")),
            PaletteItem(id: "prefix", title: "Workshop", subtitle: nil, systemImage: "3", kind: .recentAction("new_chat")),
            PaletteItem(id: "subtitle", title: "Else", subtitle: "Work queue", systemImage: "4", kind: .recentAction("reload_all")),
        ]
        let expected = ["tab", "chat", "prefix", "subtitle"]
        #expect(CommandPalettePresentation.filteredItems(pool: pool, query: " work ").map(\.id) == expected)
        #expect(CommandPalettePresentation.filteredItems(pool: pool, query: "work").map(\.id) == expected)
        #expect(CommandPalettePresentation.filteredItems(pool: pool, query: "absent").isEmpty)
    }

    // app.chat / ui.commandPalette.itemPool
    @Test("palette keeps the 50 newest unique live sessions from an 80-row history")
    func commandPalettePoolUsesRecencyAndUniqueSessionIDs() throws {
        let sessions = try (0..<80).map { index in
            let month = index / 28 + 1
            let day = index % 28 + 1
            return try wave3Session(
                "session-\(index)",
                updatedAt: String(format: "2026-%02d-%02dT00:00:00Z", month, day)
            )
        } + [
            wave3Session("session-79", updatedAt: "2026-12-31T00:00:00Z"),
            wave3Session("archived", updatedAt: "2027-01-01T00:00:00Z", archived: true),
        ]
        let visible = CommandPalettePresentation.visibleSessions(sessions)
        let pool = CommandPalettePresentation.itemPool(sessions: sessions, showDeveloperSurfaces: false)
        #expect(visible.count == 50)
        #expect(Set(visible.map(\.id)).count == visible.count)
        #expect(visible.first?.id == "session-79")
        #expect(!visible.contains(where: { $0.id == "archived" }))
        #expect(visible.last?.id == "session-30")
        #expect(Set(pool.map(\.id)).count == pool.count)
    }

    // app.chat / ui.commandPalette.recentActions, setting.showDeveloperSurfaces
    @Test("every advertised palette action is dispatchable and developer routes stay gated")
    func paletteActionsAndDeveloperSurfaceGateStayComplete() throws {
        let normalActions = CommandPaletteRecentAction.visible(showDeveloperSurfaces: false)
        let developerActions = CommandPaletteRecentAction.visible(showDeveloperSurfaces: true)
        #expect(!normalActions.contains(.openDoctor))
        #expect(developerActions == CommandPaletteRecentAction.allCases)
        #expect(developerActions.allSatisfy { CommandPaletteRecentAction(rawValue: $0.rawValue) == $0 })

        let sessions = [try wave3Session("live")]
        let normalPool = CommandPalettePresentation.itemPool(
            sessions: sessions,
            showDeveloperSurfaces: false
        )
        let developerPool = CommandPalettePresentation.itemPool(
            sessions: sessions,
            showDeveloperSurfaces: true
        )
        let normalActionIDs = normalPool.compactMap { item -> String? in
            if case .recentAction(let id) = item.kind { return id }
            return nil
        }
        let developerActionIDs = developerPool.compactMap { item -> String? in
            if case .recentAction(let id) = item.kind { return id }
            return nil
        }
        #expect(normalActionIDs.allSatisfy { CommandPaletteRecentAction(rawValue: $0) != nil })
        #expect(developerActionIDs.allSatisfy { CommandPaletteRecentAction(rawValue: $0) != nil })
        // 2026-09-06: User, 2026-09-04 (NativeAgentDesign.swift:386 and
        // SidebarModels.swift:180) — the new shell gates NOTHING; the stored
        // switch only still gates the classic sidebar, and `developerItems` is
        // empty outside it. A hard pin on "Diagnostics is hidden from a normal
        // pool" therefore describes only the classic shell. What must hold in
        // both is that the pool asks `developerItems`/`visibleAdvancedItems`
        // rather than inventing its own visibility rule.
        #expect(
            normalPool.contains(where: { $0.id == "tab.\(SidebarItem.diagnostics.rawValue)" })
                == !SidebarItem.developerItems.contains(.diagnostics)
        )
        #expect(developerPool.contains(where: { $0.id == "tab.\(SidebarItem.diagnostics.rawValue)" }))

        let normalTabs = Set(normalPool.compactMap { item -> SidebarItem? in
            if case .tab(let tab) = item.kind { return tab }
            return nil
        })
        let developerTabs = Set(developerPool.compactMap { item -> SidebarItem? in
            if case .tab(let tab) = item.kind { return tab }
            return nil
        })
        let developerOnlyTabs = Set(SidebarItem.allCases.filter(\.isDeveloperSurface))
        #expect(developerOnlyTabs.isDisjoint(with: normalTabs))
        #expect(developerOnlyTabs.isSubset(of: developerTabs))

        // 2026-09-06: same reason — the pool routes the caller's flag through
        // `developerSurfacesShown`, which is unconditionally true in the new
        // shell, so `open_doctor` is in BOTH pools there and only the classic
        // shell hides it. Pin the delegation instead of the outcome: a pool
        // that stopped calling `visible(showDeveloperSurfaces:)` fails this in
        // either shell, and the direct gate is still pinned above.
        #expect(normalActionIDs == CommandPaletteRecentAction.visible(
            showDeveloperSurfaces: NativeAgentShellPreference.developerSurfacesShown(false)
        ).map(\.rawValue))
        #expect(developerActionIDs == CommandPaletteRecentAction.visible(
            showDeveloperSurfaces: NativeAgentShellPreference.developerSurfacesShown(true)
        ).map(\.rawValue))
        let developerOnlyActions = Set(CommandPaletteRecentAction.allCases.filter(\.isDeveloperOnly))
        #expect(developerOnlyActions.allSatisfy { action in
            developerActionIDs.contains(action.rawValue)
        })

        let normalSlash = ChatSlashCommandRegistry.visible(showDeveloperSurfaces: false)
        let developerSlash = ChatSlashCommandRegistry.visible(showDeveloperSurfaces: true)
        #expect(normalSlash.allSatisfy { !$0.developerOnly })
        #expect(Set(developerSlash.map(\.id)) == Set(ChatSlashCommandRegistry.all.map(\.id)))
        let developerOnlySlashIDs = Set(ChatSlashCommandRegistry.all.filter(\.developerOnly).map(\.id))
        let normalSlashIDs = Set(normalSlash.map(\.id))
        #expect(developerOnlySlashIDs.allSatisfy {
            !normalSlashIDs.contains($0)
        })
    }
}
