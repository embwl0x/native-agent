import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Windowless app lifecycle and navigation", .serialized)
@MainActor
struct NativeAgentAppCoordinatorTests {
    @Test("process services bootstrap once when configured before launch")
    func processServicesBootstrapOnceConfiguredBeforeLaunch() {
        let calls = CallCounter(size: 4)
        let coordinator = makeCoordinator()
        coordinator.configureProcessBootstrap(dependencies(calls: calls))

        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidFinishLaunching()
        coordinator.configureProcessBootstrap(dependencies(calls: calls))

        #expect(calls.values == Array(repeating: 1, count: 4))
    }

    @Test("process services bootstrap once when launch arrives before injection")
    func processServicesBootstrapOnceConfiguredAfterLaunch() {
        let calls = CallCounter(size: 4)
        let coordinator = makeCoordinator()

        coordinator.applicationDidFinishLaunching()
        coordinator.configureProcessBootstrap(dependencies(calls: calls))
        coordinator.configureProcessBootstrap(dependencies(calls: calls))

        #expect(calls.values == Array(repeating: 1, count: 4))
    }

    @Test("routes queued before mount are delivered once in order")
    func queuedRoutesDeliverExactlyOnceAfterMount() {
        let windowCalls = CallCounter(size: 2)
        let coordinator = makeCoordinator(windowCalls: windowCalls)
        coordinator.request(.sidebar(.providers))
        coordinator.request(.activity(.approvals))

        var delivered: [NativeAgentNavigationDestination] = []
        let firstMount = coordinator.mountMainScene { delivered.append($0) }

        #expect(delivered == [.sidebar(.providers), .activity(.approvals)])
        #expect(windowCalls.values == [2, 2])

        coordinator.unmountMainScene(id: firstMount)
        let secondMount = coordinator.mountMainScene { delivered.append($0) }
        #expect(delivered == [.sidebar(.providers), .activity(.approvals)])

        coordinator.request(.activity(.selfImprovement))
        #expect(delivered == [
            .sidebar(.providers),
            .activity(.approvals),
            .activity(.selfImprovement),
        ])
        coordinator.unmountMainScene(id: secondMount)
    }

    @Test("legacy notifications posted before mount are retained")
    func legacyNotificationBeforeMountIsRetained() async {
        let center = NotificationCenter()
        let coordinator = makeCoordinator(notificationCenter: center)
        coordinator.applicationDidFinishLaunching()

        center.post(
            name: .openCommandRouteRequest,
            object: "sidebar:activity/self-improvement"
        )
        await Task.yield()

        var delivered: [NativeAgentNavigationDestination] = []
        _ = coordinator.mountMainScene { delivered.append($0) }
        #expect(delivered == [.activity(.selfImprovement)])
    }

    @Test("screen privacy review routes to Trust")
    func screenPrivacyReviewRoutesToTrust() async {
        let center = NotificationCenter()
        let coordinator = makeCoordinator(notificationCenter: center)
        coordinator.applicationDidFinishLaunching()

        center.post(name: .openTrustMultimodalRequest, object: nil)
        await Task.yield()

        var delivered: [NativeAgentNavigationDestination] = []
        _ = coordinator.mountMainScene { delivered.append($0) }
        #expect(delivered == [.sidebar(.trust)])
    }

    @Test("command entries resolve to exact Activity subsections")
    func commandEntriesResolveToExactActivitySubsections() {
        let approvals = commandEntry(id: "approvals", route: "sidebar:activity")
        let selfImprovement = commandEntry(
            id: "self-improvement-scoreboard",
            route: "sidebar:autoImprovement"
        )

        #expect(NativeAgentNavigationDestination.commandEntry(approvals) == .activity(.approvals))
        #expect(
            NativeAgentNavigationDestination.commandEntry(selfImprovement)
                == .activity(.selfImprovement)
        )
        #expect(
            NativeAgentNavigationDestination.route("sidebar:activity/approvals")
                == .activity(.approvals)
        )
        #expect(
            NativeAgentNavigationDestination.route("sidebar:activity/self-improvement")
                == .activity(.selfImprovement)
        )
        #expect(
            NativeAgentNavigationDestination.route("sidebar:autoImprovement")
                == .activity(.selfImprovement)
        )
        // User authorized retiring the Native Experience surface, 2026-09-01:
        // its deep link must now resolve to nothing rather than to a route
        // that silently lands on a page that no longer exists.
        #expect(NativeAgentNavigationDestination.route("sidebar:journey") == nil)
    }

    @Test("Desk is the primary work surface and retired routes converge on it")
    func deskOwnsLegacyWorkshopExecutionAndWorkRoutes() {
        #expect(SidebarItem.primaryItems.contains(.desk))
        #expect(!SidebarItem.primaryItems.contains(.workshop))
        #expect(!SidebarItem.primaryItems.contains(.legacyWorkshop))
        #expect(!SidebarItem.advancedItems.contains(.desk))
        #expect(SidebarItem.desk.displayName == "Desk")
        #expect(SidebarItem.workshop.normalized == .desk)
        #expect(SidebarItem.legacyWorkshop.normalized == .desk)
        #expect(SidebarItem.desk.normalized == .desk)
        #expect(SidebarItem.work.normalized == .desk)
        #expect(NativeAgentNavigationDestination.route("sidebar:workshop") == .sidebar(.desk))
        #expect(NativeAgentNavigationDestination.route("sidebar:missions") == .sidebar(.desk))
        #expect(NativeAgentNavigationDestination.route("sidebar:desk") == .sidebar(.desk))
    }

    // ui-simplify 2026-09-02 (Lane A): Trust, Providers, Mac Integration and
    // Skills & Tools are SETUP, not places you work, so they left the rail and
    // sit behind the one Advanced door in Settings. They are still reachable —
    // by route, by ⌘K, and from that door — which is what this now pins. The
    // classic shell keeps them primary, in their old order.
    @Test("Trust and Providers are on the shell rail; Mac integration and Skills are tabs")
    func trustIsSetupBehindAdvanced() {
        // User, 2026-09-04: Advanced emptied onto the rail.
        #expect(SidebarItem.shellPrimaryItems.contains(.trust))
        #expect(SidebarItem.shellPrimaryItems.contains(.providers))
        #expect(SidebarItem.shellAdvancedItems.contains(.macIntegration))
        #expect(SidebarItem.shellAdvancedItems.contains(.skills))
        #expect(SidebarItem.shellHome(for: .macIntegration)?.parent == .trust)
        #expect(SidebarItem.shellHome(for: .skills)?.parent == .diagnostics)

        let classic = SidebarItem.classicPrimaryItems
        #expect(classic.contains(.trust))
        #expect(!SidebarItem.classicAdvancedItems.contains(.trust))
        let providersIdx = classic.firstIndex(of: .providers)
        let trustIdx = classic.firstIndex(of: .trust)
        let macIdx = classic.firstIndex(of: .macIntegration)
        #expect(providersIdx != nil && trustIdx != nil && macIdx != nil)
        if let providersIdx, let trustIdx, let macIdx {
            #expect(trustIdx == providersIdx + 1)
            #expect(macIdx == trustIdx + 1)
        }
        #expect(NativeAgentNavigationDestination.route("sidebar:trust") == .sidebar(.trust))
    }

    @Test("The shell rail is twelve places, Settings last, and Today routes to Activity")
    func shellRailIsFivePlaces() {
        #expect(SidebarItem.shellPrimaryItems == [
            .chat, .activity, .memories, .personality, .providers, .trust, .connectors,
            .diagnostics, .capabilities, .inboxPolicy, .desk, .settings,
        ])
        #expect(SidebarItem.inboxPolicy.shellRailTitle == "Notifications")
        #expect(SidebarItem.activity.shellRailTitle == "Today")
        #expect(SidebarItem.activity.displayName == "Activity")
        // Lossless: nothing that was reachable stopped being reachable.
        let reachable = Set(SidebarItem.shellPrimaryItems + SidebarItem.shellAdvancedItems)
        for item in SidebarItem.classicPrimaryItems + SidebarItem.classicAdvancedItems {
            #expect(reachable.contains(item))
        }
    }

    @Test("Developer-surfaces gate partitions Advanced losslessly")
    func developerSurfacesGateIsLossless() {
        let full = SidebarItem.advancedItems
        let developer = SidebarItem.developerItems
        let consumer = SidebarItem.consumerAdvancedItems

        // Developer surfaces are a real subset of the authoritative Advanced set.
        #expect(developer.allSatisfy { full.contains($0) })
        // Consumer + developer partition Advanced exactly — no item is lost, no
        // item is in both buckets.
        #expect(Set(consumer).isDisjoint(with: Set(developer)))
        #expect(Set(consumer).union(developer) == Set(full))
        #expect(consumer.count + developer.count == full.count)

        // Flag OFF → the gated (developer) rows are hidden; consumer rows remain.
        let hidden = SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: false)
        #expect(hidden == consumer)
        #expect(developer.allSatisfy { !hidden.contains($0) })
        // 2026-09-06: df974e5f "New shell shows every developer surface; the
        // switch only gates the classic sidebar" — `developerItems` returns []
        // outside the classic shell (SidebarModels.swift:182), so the named
        // raw internals are only gated in classic. Pin the gate where it still
        // exists rather than hard-coding one shell's membership.
        if NativeAgentShellPreference.isClassic() {
            // A stranger cannot reach raw internals in one click.
            #expect(!hidden.contains(.inspector))
            #expect(!hidden.contains(.mcp))
            #expect(!hidden.contains(.cognition))
        } else {
            // User, 2026-09-04 (NativeAgentDesign.swift:386): developer surfaces
            // are always on in the new shell, so nothing is hidden at all.
            #expect(developer.isEmpty)
            #expect(hidden == full)
        }

        // Flag ON → the full authoritative set renders; nothing is dropped.
        let shown = SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: true)
        #expect(shown == full)
        #expect(developer.allSatisfy { shown.contains($0) })

        // B2.4/B2.6 integration: .cognition/.inspector are never their own
        // page — they render as Diagnostics content in both shells
        // (ContentView.swift:353-354, SidebarItem.shellHome). That survived the
        // rail rebuild; only their listing moved.
        #expect(SidebarItem.shellHome(for: .inspector)?.parent == .diagnostics)
        #expect(SidebarItem.shellHome(for: .cognition)?.parent == .diagnostics)
        // 2026-09-06: ab1e2ace/0b0c083f put Diagnostics and MCP on the rail and
        // df974e5f emptied the gate, so "the audit's raw internals are gated"
        // is a classic-shell claim now; in the new shell they are listed as
        // routes to their Diagnostics/Connectors tab instead.
        if NativeAgentShellPreference.isClassic() {
            #expect(!full.contains(.inspector))
            #expect(!full.contains(.cognition))
            #expect(SidebarItem.diagnostics.isDeveloperSurface)
            #expect(SidebarItem.mcp.isDeveloperSurface)
        } else {
            #expect(SidebarItem.shellHome(for: .mcp)?.parent == .connectors)
        }
        // Set-once consumer tabs stay ungated.
        #expect(!SidebarItem.personality.isDeveloperSurface)
        #expect(!SidebarItem.connectors.isDeveloperSurface)
    }

    @Test("Command Center retired: case is a normalized alias to Desk")
    func commandCenterRetiredAliasesToDesk() {
        // The view is gone; the case survives only as a routing alias so saved
        // scene state and deep links still land somewhere sane.
        #expect(SidebarItem.command.normalized == .desk)
        #expect(!SidebarItem.advancedItems.contains(.command))
        #expect(!SidebarItem.primaryItems.contains(.command))
        #expect(!SidebarItem.developerItems.contains(.command))
        #expect(NativeAgentNavigationDestination.route("sidebar:command") == .sidebar(.desk))
    }

    @Test("Skills and Tools share one sidebar destination with exact child routes")
    func skillsAndToolsShareOneSidebarDestination() {
        // 2026-09-02: Skills & Tools is setup, so it moved behind the Advanced
        // door. Both halves of the shell still route to ONE destination.
        #expect(SidebarItem.shellAdvancedItems.contains(.skills))
        #expect(SidebarItem.classicPrimaryItems.contains(.skills))
        #expect(!SidebarItem.advancedItems.contains(.tools))
        #expect(SidebarItem.tools.normalized == .skills)
        #expect(SidebarItem.skills.displayName == "Skills & Tools")
        #expect(NativeAgentNavigationDestination.route("sidebar:skills") == .skillsTools(.skills))
        #expect(NativeAgentNavigationDestination.route("sidebar:tools") == .skillsTools(.tools))
    }

    private func makeCoordinator(
        notificationCenter: NotificationCenter = NotificationCenter(),
        windowCalls: CallCounter? = nil
    ) -> NativeAgentAppCoordinator {
        NativeAgentAppCoordinator(
            notificationCenter: notificationCenter,
            windowActions: .init(
                activateApplication: { windowCalls?.increment(0) },
                openMainWindow: { windowCalls?.increment(1) }
            )
        )
    }

    private func dependencies(
        calls: CallCounter
    ) -> NativeAgentAppCoordinator.ProcessBootstrapDependencies {
        .init(
            restoreDetachedChats: { calls.increment(0) },
            startPermissionSync: { calls.increment(1) },
            wireGlobalHotkey: { calls.increment(2) },
            warmEmbeddings: { calls.increment(3) }
        )
    }

    private func commandEntry(id: String, route: String) -> CoordinationCommandEntry {
        CoordinationCommandEntry(
            id: id,
            title: nil,
            subtitle: nil,
            category: nil,
            systemImage: nil,
            route: route,
            endpoint: nil,
            keywords: nil,
            status: nil,
            count: nil
        )
    }
}

@MainActor
private final class CallCounter {
    private(set) var values: [Int]

    init(size: Int) {
        values = Array(repeating: 0, count: size)
    }

    func increment(_ index: Int) {
        values[index] += 1
    }
}
