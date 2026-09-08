import Foundation
import XCTest
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

    func test_workshopScreenHasALiveCallSiteInTheMoreHub() throws {
        let advanced = try MobileEvalSources.mobileSource("AdvancedView.swift")
        XCTAssertTrue(
            advanced.contains("WorkshopView(embedInNavigationStack: false)"),
            "Workshop is unreachable again: the More hub no longer pushes WorkshopView"
        )
        XCTAssertTrue(
            advanced.contains("Label(\"Desk\", systemImage:"),
            "the Workshop row must carry a visible label the user can find"
        )
    }

    /// The More hub owns the surrounding NavigationStack. A destination that
    /// declares its own renders and then pops straight back — the exact trap
    /// SkillsToolsView / MemoryView / the Activity destinations already dodge.
    func test_mountedWorkshopDoesNotNestNavigationStacks() throws {
        let workshop = try MobileEvalSources.mobileSource("WorkshopView.swift")
        XCTAssertTrue(
            workshop.contains("init(embedInNavigationStack: Bool = true)"),
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
}
