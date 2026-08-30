@testable import ChatOrchestration
import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
private final class DeskReloadProbe {
    var count = 0
    func reload() { count += 1 }
}

@Suite("Desk live reloader lifecycle", .serialized)
@MainActor
struct DeskLiveReloaderLifecycleTests {
    /// Positive steps (a reload SHOULD land) poll with a generous deadline —
    /// the 20ms debounce plus main-actor hops routinely exceed a fixed 80ms
    /// window under full-suite parallelism, which made this test the app
    /// suite's one consistent flake (every count exactly one behind).
    /// Negative steps (a reload must NOT land) keep a bounded settle window:
    /// a false pass there shrinks with the window, a false FAIL on the
    /// positive steps doesn't shrink at all.
    private func waitForCount(
        _ probe: DeskReloadProbe, toReach expected: Int,
        deadline: Duration = .seconds(5)
    ) async throws -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if probe.count >= expected { return probe.count == expected }
            try await Task.sleep(for: .milliseconds(10))
        }
        return probe.count == expected
    }

    @Test func hiddenEdgesCatchUpOnceAndStopCancelsLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-live-reloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ops.jsonl")
        let probe = DeskReloadProbe()
        let reloader = DeskLiveReloader(
            debounceDelay: .milliseconds(20),
            visibilityResolver: { true }
        )
        defer { reloader.stop() }

        reloader.activate(paths: [path]) { probe.reload() }
        #expect(try await waitForCount(probe, toReach: 1))

        reloader.deactivate()
        for _ in 0..<10 { reloader.sourceDidChange() }
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.count == 1)

        reloader.activate(paths: [path]) { probe.reload() }
        #expect(try await waitForCount(probe, toReach: 2))

        // Scene deactivation must NOT pause reloads: on macOS the scene goes
        // inactive whenever another app is frontmost — the background-glance
        // case the desk exists for (live defect 2026-08-27). Window visibility
        // owns pausing; setSceneActive only refreshes the window facts.
        reloader.setSceneActive(false)
        reloader.sourceDidChange()
        #expect(try await waitForCount(probe, toReach: 3))
        reloader.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.count == 3)

        reloader.stop()
        reloader.sourceDidChange()
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.count == 3)
    }

    // MARK: glance visibility (live defect 2026-08-27)
    //
    // The desk mounted while another app was frontmost: mainWindow/keyWindow
    // were nil, the old fallback read NSApp.isActive (false), and because the
    // window's actual occlusion never changed, no notification ever corrected
    // the stale answer — "Reading the desk…" forever over an intact store.
    // Glanceability is a fact about WINDOWS, not app activation.

    private typealias Facts = DeskLiveReloader.WindowFacts

    @Test func backgroundVisibleWindowIsGlanceable() {
        // The live failure: app inactive (main/key nil, so only the uniform
        // window sweep can answer), one plainly visible unoccluded window.
        // Must count as glanceable.
        #expect(DeskLiveReloader.resolveGlanceVisibility(
            windows: [Facts(isVisible: true, occlusionVisible: true, canBecomeMain: true)]
        ))
        // And one glanceable window among hidden/panel siblings still wins —
        // an occluded window must not veto a visible one (gpt-5.5 BLOCKING 2).
        #expect(DeskLiveReloader.resolveGlanceVisibility(windows: [
            Facts(isVisible: true, occlusionVisible: false, canBecomeMain: true),
            Facts(isVisible: true, occlusionVisible: true, canBecomeMain: false),
            Facts(isVisible: true, occlusionVisible: true, canBecomeMain: true),
        ]))
    }

    @Test func hiddenOrPanelOnlyWindowsAreNotGlanceable() {
        // Fully occluded → hidden (the pause-when-covered behavior survives).
        #expect(!DeskLiveReloader.resolveGlanceVisibility(
            windows: [Facts(isVisible: true, occlusionVisible: false, canBecomeMain: true)]
        ))
        // Ordered out (closed/miniaturized) → hidden.
        #expect(!DeskLiveReloader.resolveGlanceVisibility(
            windows: [Facts(isVisible: false, occlusionVisible: true, canBecomeMain: true)]
        ))
        // Only non-main-capable windows (status items, panels) visible: those
        // are always "visible", and counting them would defeat the pause
        // entirely — even when one of them is key (gpt-5.5 BLOCKING 1).
        // No windows at all → hidden too.
        #expect(!DeskLiveReloader.resolveGlanceVisibility(
            windows: [Facts(isVisible: true, occlusionVisible: true, canBecomeMain: false)]
        ))
        #expect(!DeskLiveReloader.resolveGlanceVisibility(windows: []))
    }
}

// MARK: bridge tool-loop budget (2026-08-27)

@Suite struct BridgeToolLoopBudgetTests {
    /// The loop runs under surface "chat" (model pick must follow the chat
    /// picker), so a surface-keyed budget can never reach a bridge turn —
    /// proven live when Agent exhausted at 60 with the "claude-bridge"
    /// budget case shipped but unreachable. The override rides the profile.
    @Test func bridgeProfileCarries180AndOthersDefault() {
        #expect(NativeAgentAppChatSurfaceProfile.bridge.toolLoopMaxIterations == 180)
        for p in NativeAgentAppChatSurfaceProfile.allCases where p != .bridge {
            #expect(p.toolLoopMaxIterations == nil)
        }
        #expect(ToolLoopBudget.resolve(surface: "chat", requested: 180) == 180)
        #expect(ToolLoopBudget.resolve(surface: "chat", requested: Int?.none) == 60)
    }

    /// Same trap, wall-clock edition: the A6 interactive 180s ceiling cut a
    /// healthy 24-dispatch bridge marathon at 188s the day it shipped. The
    /// bridge profile carries the unattended tier; the override is clamped
    /// to that tier so a future value can't exceed unattended semantics.
    @Test func bridgeProfileCarriesUnattendedWallClock() {
        #expect(NativeAgentAppChatSurfaceProfile.bridge.turnWallClockSeconds == 3_900)
        for p in NativeAgentAppChatSurfaceProfile.allCases where p != .bridge {
            #expect(p.turnWallClockSeconds == nil)
        }
        final class ClockBox: @unchecked Sendable { var t: UInt64 = 0 }
        let box = ClockBox()
        WholeTurnWallClockBudget.$nowNanoseconds.withValue({ box.t }) {
            let interactive = WholeTurnWallClockBudget.start(surface: "chat")
            let bridged = WholeTurnWallClockBudget.start(surface: "chat", requestedSeconds: 3_900)
            box.t = UInt64(601) * 1_000_000_000  // past the 600s interactive ceiling
            #expect(interactive.isExhausted)
            #expect(!bridged.isExhausted)
            box.t = UInt64(4_000) * 1_000_000_000
            #expect(bridged.isExhausted)
        }
    }
}
