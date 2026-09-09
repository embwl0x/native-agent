import Foundation
import XCTest
import SwiftUI
@testable import NativeAgentMobile

/// Sweep 2026-09-01 items 20 / 36 — `ios.screens / ios.workshop.callSite`.
///
/// Silent-failure class: DEAD SURFACE. `WorkshopView` shipped 492 lines of
/// working directed-work submission and step approve/reject with NO call site
/// anywhere in the app, so the capability existed in the binary and was
/// unreachable from the phone. Nothing failed; the screen simply never
/// appeared. These fences keep the mount, its navigation shape, and the signed
/// action path it depends on from regressing back into an orphan.
final class WorkshopMountEvalTests: XCTestCase {

    @MainActor
    func test_workshopScreenHasALiveCallSiteInTheMoreHub() throws {
        let advanced = try MobileEvalSources.mobileSource("AdvancedView.swift")
        XCTAssertTrue(
            advanced.contains("WorkshopView(embedInNavigationStack: false)"),
            "Workshop is unreachable again: the More hub no longer pushes WorkshopView"
        )
        XCTAssertTrue(
            advanced.contains("Label(\"Desk tasks\", systemImage:"),
            "the Workshop row must carry a visible label the user can find"
        )
        #if DEBUG
        try renderDeskDisclosureFixtures()
        #endif
    }

    /// The More hub owns the surrounding NavigationStack. A destination that
    /// declares its own renders and then pops straight back — the exact trap
    /// SkillsToolsView / MemoryView / the Activity destinations already dodge.
    func test_mountedWorkshopDoesNotNestNavigationStacks() throws {
        let workshop = try MobileEvalSources.mobileSource("WorkshopView.swift")
        XCTAssertTrue(
            workshop.contains("init(embedInNavigationStack: Bool = true, notifiedTaskID: String? = nil)"),
            "WorkshopView must accept the embed flag the More hub passes"
        )
        XCTAssertTrue(
            workshop.contains("if embedInNavigationStack {"),
            "WorkshopView must be able to render without its own NavigationStack"
        )
    }

    /// Mounting a screen must not introduce a second, unsigned way to move
    /// Workshop state. Every button on it goes through the same HMAC-signed
    /// iCloud action channel every other iOS mutation uses.
    func test_workshopActionsStillRouteThroughTheSignedActionChannel() throws {
        let workshop = try MobileEvalSources.mobileSource("WorkshopView.swift")
        for call in [
            "iCloudSyncEngine.shared.submitWorkshopTask(",
            "iCloudSyncEngine.shared.approveStep(",
            "iCloudSyncEngine.shared.rejectStep(",
        ] {
            XCTAssertTrue(workshop.contains(call), "Workshop lost its \(call) call site")
        }

        let actions = try MobileEvalSources.mobileSource("iCloudSyncEngine+Actions.swift")
        for (function, transport) in [
            ("func submitWorkshopTask(", "sendActionWithSignatureRetry"),
            ("func approveStep(", "sendDecisionActionWithSignatureRetry"),
            ("func rejectStep(", "sendDecisionActionWithSignatureRetry"),
        ] {
            guard let start = actions.range(of: function),
                  let end = actions.range(of: "\n    }", range: start.upperBound..<actions.endIndex) else {
                return XCTFail("could not locate \(function) in iCloudSyncEngine+Actions.swift")
            }
            let body = String(actions[start.upperBound..<end.lowerBound])
            XCTAssertTrue(
                body.contains(transport),
                "\(function) must dispatch through \(transport) — an unsigned Workshop write is a forged Mac instruction"
            )
        }
    }

    /// A completion push has to open the tab that actually hosts Workshop.
    /// While the screen was orphaned this notification said `"activity"`,
    /// which opened a tab with no Workshop anywhere on it.
    func test_workshopCompletionNotificationOpensTheTabThatHostsWorkshop() throws {
        // The exact ID survives delegate delivery before ContentView exists,
        // and consumption is one-shot for warm delivery as well.
        MobileDeskTaskNotificationIntent.stage(screen: "workshop", taskID: "completed-task-42")
        XCTAssertEqual(MobileDeskTaskNotificationIntent.consume()?.taskID, "completed-task-42")
        XCTAssertNil(MobileDeskTaskNotificationIntent.consume())
        MobileDeskTaskNotificationIntent.stage(screen: "workshop", taskID: nil)
        XCTAssertNotNil(MobileDeskTaskNotificationIntent.consume())
        MobileDeskTaskNotificationIntent.stage(screen: "chat", taskID: "unrelated")
        XCTAssertNil(MobileDeskTaskNotificationIntent.consume())
        let workshop = try MobileEvalSources.mobileSource("WorkshopView.swift")
        XCTAssertTrue(
            workshop.contains("\"screen\": \"workshop\""),
            "the Workshop completion notification must name the screen it can actually open"
        )

        let contentView = try MobileEvalSources.mobileSource("ContentView.swift")
        guard let routerStart = contentView.range(of: "func tab(forNotificationScreen screen: String) -> Tab {"),
              let routerEnd = contentView.range(
                of: "default: return .activity", range: routerStart.upperBound..<contentView.endIndex
              ) else {
            return XCTFail("could not locate tab(forNotificationScreen:)")
        }
        let routerBody = String(contentView[routerStart.upperBound..<routerEnd.lowerBound])
        XCTAssertTrue(
            routerBody.contains("\"workshop\""),
            "\"workshop\" must have an explicit route, not the silent .activity default"
        )

        // The launch-argument router is the other half of the same vocabulary;
        // the ui-walk tier reaches Workshop through it.
        XCTAssertEqual(
            ContentView.initialTab(fromLaunchArguments: ["NativeAgentMobile", "-initialTab", "workshop"]),
            .more
        )
    }

    #if DEBUG
    /// ImageRenderer draws the changed production components without a window
    /// or screen capture. These are layout fixtures, not a live transport test.
    @MainActor
    private func renderDeskDisclosureFixtures() throws {
        let directory = try MobileEvalSources.repoRoot()
            .appendingPathComponent("mockups/simplicity/round3/phone-desk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for largeText in [false, true] {
                let fixture = VStack(alignment: .leading, spacing: 24) {
                    Text("Desk").font(.largeTitle.bold())
                    MobileDeskTasksLabel().foregroundStyle(.blue)
                    Text("History").font(.headline)
                    MobileLoadedRecordsDisclosure(title: "Show more history", remaining: 43) {}
                    Divider()
                    Text("Approvals").font(.title.bold())
                    Text("Resolved").font(.headline)
                    MobileLoadedRecordsDisclosure(title: "Show more decisions", remaining: 17) {}
                    Divider()
                    Text("Desk tasks").font(.title.bold())
                    MobileDeskTaskUnavailableNotice()
                    WorkshopTaskRow(task: WorkshopTaskRecord(
                        id: "fixture", title: "Prepare the weekly summary",
                        objective: "Collect the completed work into a short summary.",
                        status: "completed", phase: "completed", createdAt: "2026-09-07"
                    ))
                }
                .padding(20)
                .frame(width: 390, alignment: .leading)
                .background(NativeAgentMobileTheme.Colors.canvas)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
                let renderer = ImageRenderer(content: fixture)
                renderer.scale = 2
                let png = try XCTUnwrap(renderer.uiImage?.pngData())
                let name = "\(scheme == .dark ? "dark" : "light")\(largeText ? "-large-text" : "").png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
    #endif
}
