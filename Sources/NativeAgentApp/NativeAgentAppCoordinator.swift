import AppKit
import Foundation

enum NativeAgentNavigationDestination: Equatable, Sendable {
    case sidebar(SidebarItem)
    case activity(ActivitySection)
    case skillsTools(SkillsToolsSection)

    static func route(_ rawRoute: String?) -> Self? {
        guard var route = rawRoute?.trimmingCharacters(in: .whitespacesAndNewlines),
              !route.isEmpty else { return nil }
        if route.hasPrefix("sidebar:") {
            route.removeFirst("sidebar:".count)
        }

        switch route.lowercased() {
        case "activity/approvals", "approvals":
            return .activity(.approvals)
        case "activity/inbox", "inbox":
            return .activity(.inbox)
        case "activity/memory-proposals", "activity/memory_proposals", "memory-proposals":
            return .activity(.memoryProposals)
        case "activity/self-improvement", "activity/self_improvement",
             "autoimprovement", "self-improvement", "self_improvement":
            return .activity(.selfImprovement)
        case "chat":
            return .sidebar(.chat)
        case "activity":
            return .sidebar(.activity)
        case "memories", "memory":
            return .sidebar(.memories)
        case "skills":
            return .skillsTools(.skills)
        case "workshop", "missions", "desk", "command":
            // Retired Workshop/Command Center names remain compatibility
            // aliases; every route lands on the agent's canonical Desk.
            return .sidebar(.desk)
        case "personality":
            return .sidebar(.personality)
        case "connectors":
            return .sidebar(.connectors)
        case "trust":
            return .sidebar(.trust)
        case "providers":
            return .sidebar(.providers)
        case "settings":
            return .sidebar(.settings)
        case "capabilities", "foundry":
            return .sidebar(.capabilities)
        case "knowledge":
            return .sidebar(.knowledge)
        case "dreams", "dream", "rem":
            return .sidebar(.dreams)
        case "cognition", "observatory", "cognitive_observatory":
            return .sidebar(.cognition)
        case "diagnostics", "doctor", "logs":
            return .sidebar(.diagnostics)
        case "telegram":
            return .sidebar(.telegram)
        case "inboxpolicy":
            return .sidebar(.inboxPolicy)
        case "panels":
            return .sidebar(.diagnostics)
        case "tools":
            return .skillsTools(.tools)
        case "mcp", "mcps", "mcp_servers":
            return .sidebar(.mcp)
        case "inspector", "turn_inspector", "readout":
            return .sidebar(.inspector)
        case "macintegration", "mac_integration":
            return .sidebar(.macIntegration)
        default:
            return nil
        }
    }
}

/// Receipt for accepting a navigation request. Delivery means that the mounted
/// scene received the destination; it deliberately does not claim that the
/// destination's UI has finished rendering or completed any work.
enum NativeAgentNavigationRequestReceipt: Equatable, Sendable {
    case deliveredToMountedScene
    case queuedForMainScene
}

@MainActor
final class NativeAgentAppCoordinator {
    static let mainSceneID = "main"

    struct ProcessBootstrapDependencies {
        var restoreDetachedChats: () -> Void
        var startPermissionSync: () -> Void
        var wireGlobalHotkey: () -> Void
        var warmEmbeddings: () -> Void
    }

    struct WindowActions {
        var activateApplication: @MainActor () -> Void
        var openMainWindow: @MainActor () -> Void

        @MainActor
        static var live: WindowActions {
            WindowActions(
                activateApplication: {
                    NSApp.activate(ignoringOtherApps: true)
                },
                openMainWindow: {}
            )
        }
    }

    static let shared = NativeAgentAppCoordinator(
        notificationCenter: .default,
        windowActions: .live
    )

    private let notificationCenter: NotificationCenter
    private var windowActions: WindowActions
    private var processDependencies: ProcessBootstrapDependencies?
    private var didFinishLaunching = false
    private var didBootstrapProcessServices = false
    private var routeObserverTokens: [NSObjectProtocol] = []
    private var pendingDestinations: [NativeAgentNavigationDestination] = []
    private var mountedScene: (
        id: UUID,
        currentPage: () -> QuietPage?,
        deliver: (NativeAgentNavigationDestination) -> Void
    )?

    init(
        notificationCenter: NotificationCenter,
        windowActions: WindowActions
    ) {
        self.notificationCenter = notificationCenter
        self.windowActions = windowActions
    }

    func configureProcessBootstrap(_ dependencies: ProcessBootstrapDependencies) {
        guard !didBootstrapProcessServices else { return }
        processDependencies = dependencies
        bootstrapProcessServicesIfReady()
    }

    /// Retain the scene's opening action so routing can reopen a closed window.
    func configureMainWindowOpening(_ open: @escaping @MainActor () -> Void) {
        windowActions.openMainWindow = open
        if !pendingDestinations.isEmpty {
            windowActions.activateApplication()
            open()
        }
    }

    func applicationDidFinishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        installLegacyRouteObservers()
        bootstrapProcessServicesIfReady()
    }

    @discardableResult
    func mountMainScene(
        currentPage: @escaping () -> QuietPage? = { nil },
        deliver: @escaping (NativeAgentNavigationDestination) -> Void
    ) -> UUID {
        let id = UUID()
        mountedScene = (id, currentPage, deliver)
        _ = drainPendingDestinations()
        return id
    }

    func unmountMainScene(id: UUID) {
        guard mountedScene?.id == id else { return }
        mountedScene = nil
    }

    var currentPage: QuietPage? { mountedScene?.currentPage() }

    @discardableResult
    func request(_ destination: NativeAgentNavigationDestination) -> NativeAgentNavigationRequestReceipt {
        pendingDestinations.append(destination)
        windowActions.activateApplication()
        windowActions.openMainWindow()
        return drainPendingDestinations()
            ? .deliveredToMountedScene
            : .queuedForMainScene
    }

    /// The same destination, with neither half of `request`'s window work.
    ///
    /// `request` activates the app and opens the main window, which is exactly
    /// what quiet self-administration must never do. This hands the
    /// destination to a scene that is ALREADY mounted and returns false if
    /// there is none — it never queues, because a queued destination would
    /// ambush the person the next time a window happened to open.
    func deliverQuietly(_ destination: NativeAgentNavigationDestination) -> Bool {
        guard let deliver = mountedScene?.deliver else { return false }
        deliver(destination)
        return true
    }

    private func bootstrapProcessServicesIfReady() {
        guard didFinishLaunching,
              !didBootstrapProcessServices,
              let processDependencies else { return }
        didBootstrapProcessServices = true
        self.processDependencies = nil
        processDependencies.restoreDetachedChats()
        processDependencies.startPermissionSync()
        processDependencies.wireGlobalHotkey()
        processDependencies.warmEmbeddings()
    }

    @discardableResult
    private func drainPendingDestinations() -> Bool {
        guard let deliver = mountedScene?.deliver, !pendingDestinations.isEmpty else { return false }
        let destinations = pendingDestinations
        pendingDestinations.removeAll(keepingCapacity: true)
        for destination in destinations {
            deliver(destination)
        }
        return true
    }

    private func installLegacyRouteObservers() {
        guard routeObserverTokens.isEmpty else { return }

        observe(.openNextGenRequest) { _ in
            // The request is for the Next-gen section, which is collapsed by
            // default; open it before landing on Capabilities.
            CapabilitiesDisclosurePreference.setNextGenExpanded(true, in: .standard)
            return .sidebar(.capabilities)
        }
        observe(.openApprovalsRequest) { _ in .activity(.approvals) }
        observe(.openTelegramRequest) { _ in .sidebar(.telegram) }
        observe(.openTrustMultimodalRequest) { _ in .sidebar(.trust) }
        // Inbox act → chat draft: the coordinator only activates the window and
        // lands on Chat; ContentView's receiver does the draft injection.
        observe(.openChatDraftRequest) { _ in .sidebar(.chat) }
        // L5 G6, same shape: her message is already persisted, so the
        // coordinator's only job is window activation + landing on Chat.
        // ContentView's receiver reloads the transcript.
        observe(.openSpokenChatRequest) { _ in .sidebar(.chat) }
        observe(.openCommandRouteRequest) { note in
            NativeAgentNavigationDestination.route(note.object as? String)
        }
    }

    private func observe(
        _ name: Notification.Name,
        destination: @escaping @Sendable (Notification) -> NativeAgentNavigationDestination?
    ) {
        let token = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let target = destination(note) else { return }
            Task { @MainActor [weak self] in
                self?.request(target)
            }
        }
        routeObserverTokens.append(token)
    }
}
