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
    // 2026-09-06: 1a35d953 ("Appearance: dark is the default; only an explicit
    // off follows the system") inverted the default. preferredAppearance now
    // reads `(object(forKey:) as? Bool) ?? true` — absent means dark, and only
    // a real persisted Bool(false) hands the panel to the system appearance.
    // The honesty this pins is unchanged: `as? Bool` still refuses to coerce a
    // malformed value, so a junk string cannot flip the chrome — it falls back
    // to the default like an absent key does.
    @Test("only an explicit Bool false follows the system; absent and malformed values keep the dark default")
    func appearanceMappingIsHonestForStoredValues() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // 2026-09-06 (1a35d953): absent used to mean "follow system", now dark.
        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults)?.name == .darkAqua)
        defaults.set(false, forKey: key)
        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults) == nil)
        // 2026-09-06 (1a35d953): a non-Bool is still not coerced — it is not an
        // opt-out, so it lands on the default (now dark) rather than on system.
        defaults.set("not-a-boolean", forKey: key)
        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults)?.name == .darkAqua)
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
        // 2026-09-06: the opening paint does NOT come from the injected suite —
        // open() builds the request with `Self.preferredAppearance()`, the
        // no-argument reader over .standard (DetachedChatPanel.swift:350). That
        // used to be invisible because an unset preference mapped to nil on both
        // authorities; since 1a35d953 made dark the default, the first frame is
        // dark on a stock machine. Pin it against the same reader instead of a
        // literal so the eval does not depend on the host's real preference.
        #expect(handle.appearance == DetachedChatWindowController.preferredAppearance())

        // With the opening paint no longer a known value, drive the panel to a
        // known state first and count only the writes that follow, so the
        // one-write-per-real-change and nothing-after-teardown pins stay exact.
        defaults.set(false, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance == nil)
        let baselineWrites = handle.appearanceWrites

        defaults.set(true, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance?.name == .darkAqua)
        #expect(handle.appearanceWrites == baselineWrites + 1)

        defaults.set(false, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance == nil)
        #expect(handle.appearanceWrites == baselineWrites + 2)

        observer.stop()
        #expect(!observer.isObserving)
        defaults.set(true, forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()
        #expect(handle.appearance == nil)
        #expect(handle.appearanceWrites == baselineWrites + 2)
    }
}
