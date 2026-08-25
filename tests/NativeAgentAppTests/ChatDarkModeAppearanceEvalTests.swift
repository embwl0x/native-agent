import AppKit
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / setting.nativeagent.darkMode
//
// The detached panel is AppKit-owned, so this drives the real controller with
// a close-capable in-memory panel rather than assuming SwiftUI's AppStorage
// repaint reaches the panel titlebar.

@MainActor
private final class DarkModeEvalPanelHandle: DetachedChatPanelHandle {
    var appearance: NSAppearance? {
        didSet { appearanceWrites += 1 }
    }
    private let onClose: () -> Void
    private(set) var appearanceWrites = 0

    init(appearance: NSAppearance?, onClose: @escaping () -> Void) {
        self.appearance = appearance
        self.onClose = onClose
    }

    func center() {}
    func show() {}
    func close() { onClose() }
}

private func darkModeEvalSession(_ id: String) throws -> ChatSession {
    try JSONDecoder().decode(ChatSession.self, from: Data("""
    {"id":"\(id)","title":"Appearance","createdAt":"2026-08-24T00:00:00Z"}
    """.utf8))
}

@Suite("app.chat · detached panel dark appearance", .serialized)
struct ChatDarkModeAppearanceEvalTests {
    private let key = "nativeagent.darkMode"

    private func isolatedDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "nativeagent.chat.dark-mode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @MainActor
    @Test("only Bool true forces dark AppKit chrome; absent, false, and malformed values follow system")
    func appearanceMappingIsHonestForStoredValues() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults) == nil)
        defaults.set(false, forKey: key)
        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults) == nil)
        defaults.set("not-a-boolean", forKey: key)
        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults) == nil)
        defaults.set(true, forKey: key)
        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults)?.name == .darkAqua)
    }

    @MainActor
    @Test("one observer updates open panel chrome and teardown stops further changes")
    func livePreferenceUpdatesReachMountedPanelExactlyUntilTeardown() async throws {
        let (defaults, suite) = try isolatedDefaults()
        let center = NotificationCenter()
        let observer = DarkModePreferenceObserver(
            center: center,
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
        defer {
            observer.stop()
            defaults.removePersistentDomain(forName: suite)
        }

        var handles: [String: DarkModeEvalPanelHandle] = [:]
        let controller = DetachedChatWindowController(
            defaults: defaults,
            panelBuilder: { request in
                let handle = DarkModeEvalPanelHandle(
                    appearance: request.appearance,
                    onClose: request.onClose
                )
                handles[request.sessionId] = handle
                return handle
            },
            pinSession: { _, _ in },
            appearanceObserver: observer
        )
        let sessionID = "dark-mode-\(UUID().uuidString)"
        let model = AppModel()
        model.chatSessions = [try darkModeEvalSession(sessionID)]

        // Reattaching is a normal bootstrap retry; it must not add a second
        // observer. The observer itself owns that idempotency boundary.
        controller.attach(appModel: model)
        controller.attach(appModel: model)
        #expect(observer.isObserving)

        controller.open(sessionId: sessionID)
        let handle = try #require(handles[sessionID])
        #expect(handle.appearance == nil)

        defaults.set(true, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance?.name == .darkAqua)
        #expect(handle.appearanceWrites == 1)

        defaults.set(false, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance == nil)
        #expect(handle.appearanceWrites == 2)

        observer.stop()
        #expect(!observer.isObserving)
        defaults.set(true, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance == nil)
        #expect(handle.appearanceWrites == 2)
    }
}
