import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Windowless app lifecycle and navigation", .serialized)
@MainActor
struct NativeAgentAppCoordinatorTests {
    @Test("process services bootstrap once when configured before launch")
    func processServicesBootstrapOnceConfiguredBeforeLaunch() {
        let calls = CallCounter(size: 5)
        let coordinator = makeCoordinator()
        coordinator.configureProcessBootstrap(dependencies(calls: calls))

        coordinator.applicationDidFinishLaunching()
        coordinator.applicationDidFinishLaunching()
        coordinator.configureProcessBootstrap(dependencies(calls: calls))

        #expect(calls.values == Array(repeating: 1, count: 5))
    }

    @Test("process services bootstrap once when launch arrives before injection")
    func processServicesBootstrapOnceConfiguredAfterLaunch() {
        let calls = CallCounter(size: 5)
        let coordinator = makeCoordinator()

        coordinator.applicationDidFinishLaunching()
        coordinator.configureProcessBootstrap(dependencies(calls: calls))
        coordinator.configureProcessBootstrap(dependencies(calls: calls))

        #expect(calls.values == Array(repeating: 1, count: 5))
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
    }

    @Test("Workshop is the primary work surface and legacy routes converge on it")
    func workshopOwnsLegacyWorkshopExecutionAndDeskRoutes() {
        #expect(SidebarItem.primaryItems.contains(.workshop))
        #expect(!SidebarItem.primaryItems.contains(.legacyWorkshop))
        #expect(!SidebarItem.advancedItems.contains(.desk))
        #expect(SidebarItem.legacyWorkshop.normalized == .workshop)
        #expect(SidebarItem.desk.normalized == .workshop)
        #expect(SidebarItem.work.normalized == .workshop)
        #expect(NativeAgentNavigationDestination.route("sidebar:workshop") == .sidebar(.workshop))
        #expect(NativeAgentNavigationDestination.route("sidebar:missions") == .sidebar(.workshop))
        #expect(NativeAgentNavigationDestination.route("sidebar:desk") == .sidebar(.workshop))
    }

    @Test("Trust is primary, seated between Providers and Mac Integration")
    func trustIsPrimaryBetweenProvidersAndMacIntegration() {
        let primary = SidebarItem.primaryItems
        #expect(primary.contains(.trust))
        #expect(!SidebarItem.advancedItems.contains(.trust))
        let providersIdx = primary.firstIndex(of: .providers)
        let trustIdx = primary.firstIndex(of: .trust)
        let macIdx = primary.firstIndex(of: .macIntegration)
        #expect(providersIdx != nil && trustIdx != nil && macIdx != nil)
        if let providersIdx, let trustIdx, let macIdx {
            #expect(trustIdx == providersIdx + 1)
            #expect(macIdx == trustIdx + 1)
        }
        #expect(NativeAgentNavigationDestination.route("sidebar:trust") == .sidebar(.trust))
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
        // A stranger cannot reach raw internals in one click.
        #expect(!hidden.contains(.inspector))
        #expect(!hidden.contains(.mcp))
        #expect(!hidden.contains(.cognition))

        // Flag ON → the full authoritative set renders; nothing is dropped.
        let shown = SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: true)
        #expect(shown == full)
        #expect(developer.allSatisfy { shown.contains($0) })

        // The developer surfaces named by the audit are actually gated.
        // B2.4/B2.6 integration: .cognition/.inspector are route-only
        // Diagnostics segments — not sidebar rows in any bucket — and the
        // Diagnostics row that fronts them is itself developer-gated.
        #expect(!full.contains(.inspector))
        #expect(!full.contains(.cognition))
        #expect(SidebarItem.diagnostics.isDeveloperSurface)
        #expect(SidebarItem.mcp.isDeveloperSurface)
        // Set-once consumer tabs stay ungated.
        #expect(!SidebarItem.personality.isDeveloperSurface)
        #expect(!SidebarItem.connectors.isDeveloperSurface)
    }

    @Test("Command Center retired: case is a normalized alias to Workshop")
    func commandCenterRetiredAliasesToWorkshop() {
        // The view is gone; the case survives only as a routing alias so saved
        // scene state and deep links still land somewhere sane.
        #expect(SidebarItem.command.normalized == .workshop)
        #expect(!SidebarItem.advancedItems.contains(.command))
        #expect(!SidebarItem.primaryItems.contains(.command))
        #expect(!SidebarItem.developerItems.contains(.command))
        #expect(NativeAgentNavigationDestination.route("sidebar:command") == .sidebar(.workshop))
    }

    @Test("Skills and Tools share one sidebar destination with exact child routes")
    func skillsAndToolsShareOneSidebarDestination() {
        #expect(SidebarItem.primaryItems.contains(.skills))
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
            warmEmbeddings: { calls.increment(3) },
            runInitialDoctor: { calls.increment(4) }
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
