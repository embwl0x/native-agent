import AppKit
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.sidebar.rowContextMenu
//
// The mounted SwiftUI row routes its detached-window actions through
// DetachedChatWindowController.shared. This drives that exact lifecycle owner
// with a close-capable in-memory panel handle, so the eval covers real
// attach/open/focus/close/persistence behavior without creating a window in
// the test process.

@MainActor
private final class ContextMenuPanelHandle: DetachedChatPanelHandle {
    var appearance: NSAppearance?
    private let onClose: () -> Void
    private(set) var centerCount = 0
    private(set) var showCount = 0
    private(set) var closeCount = 0

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func center() {
        centerCount += 1
    }

    func show() {
        showCount += 1
    }

    func close() {
        guard closeCount == 0 else { return }
        closeCount += 1
        onClose()
    }
}

private func rowContextMenuSession(_ id: String) throws -> ChatSession {
    try JSONDecoder().decode(ChatSession.self, from: Data("""
    {"id":"\(id)","title":"Context menu","createdAt":"2026-08-24T00:00:00Z"}
    """.utf8))
}

@MainActor
@Test("sidebar row detached-window actions require attachment and keep panel and persisted state in lockstep")
func chatSidebarRowContextMenuDetachedWindowLifecycle() throws {
    let suiteName = "nativeagent.chat-sidebar-menu.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var handles: [String: ContextMenuPanelHandle] = [:]
    var pinnedSessionIDs: [String] = []
    let controller = DetachedChatWindowController(
        defaults: defaults,
        panelBuilder: { request in
            let handle = ContextMenuPanelHandle(onClose: request.onClose)
            handles[request.sessionId] = handle
            return handle
        },
        pinSession: { _, sessionId in
            pinnedSessionIDs.append(sessionId)
        }
    )
    let sessionID = "sidebar-session-\(UUID().uuidString)"

    // The menu can be rendered before process bootstrap attaches AppModel.
    // That action is explicitly adverse: no panel or persisted id is forged.
    controller.open(sessionId: sessionID)
    #expect(controller.isDetached(sessionID) == false)
    #expect(handles[sessionID] == nil)
    #expect(defaults.string(forKey: DetachedChatWindowController.persistKey) == nil)

    let model = AppModel()
    model.chatSessions = [try rowContextMenuSession(sessionID)]
    controller.attach(appModel: model)

    // "Open in Detached Window" creates one real lifecycle entry and persists
    // the same id. A second open is the context menu's front/focus behavior,
    // never a duplicate panel or pin.
    controller.open(sessionId: sessionID)
    let handle = try #require(handles[sessionID])
    #expect(controller.isDetached(sessionID))
    #expect(defaults.string(forKey: DetachedChatWindowController.persistKey) == sessionID)
    #expect(handle.centerCount == 1)
    #expect(handle.showCount == 1)
    #expect(pinnedSessionIDs == [sessionID])

    controller.focus(sessionId: sessionID)
    controller.open(sessionId: sessionID)
    #expect(handle.showCount == 3)
    #expect(handles.count == 1)
    #expect(pinnedSessionIDs == [sessionID])

    // "Close Detached Window" is reported only after the panel handle invokes
    // its real close callback, which removes both the in-memory row state and
    // the durable restore id.
    controller.close(sessionId: sessionID)
    #expect(handle.closeCount == 1)
    #expect(controller.isDetached(sessionID) == false)
    #expect(handles.count == 1, "the test handle remains inspectable after close")
    #expect(defaults.string(forKey: DetachedChatWindowController.persistKey) == nil)
}
