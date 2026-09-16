import AppKit
import SwiftUI
import StandingBots
import Testing
@testable import NativeAgentApp

@MainActor @Observable
private final class MotionFixture {
    var running = false
    var reduceMotion = false
    var visible = true
}

private struct MotionFixtureView: View {
    let fixture: MotionFixture
    let record: BotsShelfRecord
    var body: some View {
        BotMarkContent(state: BotState(record: record, running: fixture.running),
                       reduceMotion: fixture.reduceMotion, allowsMotion: fixture.visible)
            .frame(width: 96, height: 96)
            .background(Color.white)
    }
}

@MainActor @Suite(.serialized)
struct BotMarkMotionTests {
    @Test("Bot indicator animates only while running with motion enabled")
    func mountedMotionLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["NATIVEAGENT_UI_MOTION_CHECK"] == "1" else { return }
        _ = NSApplication.shared
        let fixture = MotionFixture()
        let bot = BotDefinition(name: "Motion fixture", brief: "Synthetic state only", cadence: .manual,
                                budget: BotBudget(tokens: 1, seconds: 1))
        let record = BotsShelfRecord(definition: bot, entries: [], unreadIDs: [])
        let host = NSHostingView(rootView: MotionFixtureView(fixture: fixture, record: record))
        let window = NSWindow(contentRect: NSRect(x: 1200, y: 100, width: 96, height: 96),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func frames() async throws -> [Data] {
            var images: [Data] = []
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(350))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                images.append(try #require(bitmap.representation(using: .png, properties: [:])))
            }
            return images
        }
        let idle = try await frames()
        #expect(Set(idle).count == 1)
        fixture.running = true
        let running = try await frames()
        #expect(Set(running).count > 1)
        fixture.reduceMotion = true
        try await Task.sleep(for: .milliseconds(200))
        let reduced = try await frames()
        #expect(Set(reduced).count == 1)
        fixture.reduceMotion = false
        let resumed = try await frames()
        #expect(Set(resumed).count > 1)
        fixture.visible = false
        try await Task.sleep(for: .milliseconds(200))
        let hidden = try await frames()
        #expect(Set(hidden).count == 1)
        fixture.visible = true
        let shown = try await frames()
        #expect(Set(shown).count > 1)
        fixture.running = false
        try await Task.sleep(for: .milliseconds(200))
        let stopped = try await frames()
        #expect(Set(stopped).count == 1)
    }
}
