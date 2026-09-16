import AppKit
import SwiftUI
import Testing
@testable import NativeAgentApp

@MainActor @Suite(.serialized)
struct EmbeddingsSettingsLifecycleTests {
    @Test("A late status failure cannot restart polling after Settings closes")
    func lateReadAfterDisappearance() async throws {
        guard ProcessInfo.processInfo.environment["NATIVEAGENT_UI_MOTION_CHECK"] == "1" else { return }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embeddings-settings-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        var fetchCount = 0
        var pending: CheckedContinuation<Void, Never>?
        let section = EmbeddingsSettingsSection(
            attention: .constant(false),
            actionOverrides: .init(fetchStatus: {
                fetchCount += 1
                if fetchCount == 1 {
                    // Deliberately non-cooperative read, like an actor request
                    // already executing when its view is removed.
                    await withCheckedContinuation { pending = $0 }
                }
                throw CocoaError(.fileReadUnknown)
            }, releaseMemory: nil)
        )
        let host = NSHostingView(rootView: AnyView(Form { section }.environment(model)))
        let window = NSWindow(contentRect: NSRect(x: 1200, y: 100, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            pending?.resume()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<40 where pending == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(fetchCount == 1)
        let read = try #require(pending)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        pending = nil
        read.resume()
        try await Task.sleep(for: .milliseconds(2300))
        #expect(fetchCount == 1, "A dismissed Settings section must not start a new poll")
    }
}
