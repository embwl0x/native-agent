import AppKit
import Foundation

enum NativeAgentNavigationDestination: Equatable, Sendable {
    case sidebar(SidebarItem)
    case activity(ActivitySection)
    case skillsTools(SkillsToolsSection)

    static func commandEntry(_ entry: CoordinationCommandEntry) -> Self? {
        switch entry.id {
        case "approvals":
            return .activity(.approvals)
        case "self-improvement-scoreboard":
            return .activity(.selfImprovement)
        default:
            return route(entry.route)
        }
    }

    static func route(_ rawRoute: String?) -> Self? {
        guard var route = rawRoute?.trimmingCharacters(in: .whitespacesAndNewlines),
              !route.isEmpty else { return nil }
        if route.hasPrefix("sidebar:") {
            route.removeFirst("sidebar:".count)
        }

        switch route.lowercased() {
        case "journey", "learning-journey", "experience":
            return .activity(.journey)
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

@MainActor
final class NativeAgentAppCoordinator {
    struct ProcessBootstrapDependencies {
        var restoreDetachedChats: () -> Void
        var startPermissionSync: () -> Void
        var wireGlobalHotkey: () -> Void
        var warmEmbeddings: () -> Void
        var runInitialDoctor: () -> Void
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
                openMainWindow: {
                    if !presentLiveMainWindow() {
                        // Activation can materialize a closed SwiftUI Window on the
                        // next run-loop turn. Retry once before leaving the typed
                        // route queued for ContentView's eventual mount.
                        Task { @MainActor in
                            _ = presentLiveMainWindow()
                        }
                    }
                }
            )
        }

        @MainActor
        private static func presentLiveMainWindow() -> Bool {
            if let window = NSApp.windows.first(where: {
                !($0 is NSPanel) && $0.title == "NativeAgent"
            }) {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                return true
            }

            // A closed SwiftUI Window may no longer have an NSWindow to order
            // directly, but its system-provided Window-menu item remains the
            // supported user entry point. Dispatch that same action so SwiftUI
            // recreates the single "main" scene rather than constructing a
            // parallel AppKit window.
            guard let item = NSApp.windowsMenu?.items.first(where: {
                $0.title == "NativeAgent"
            }), let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    static let shared = NativeAgentAppCoordinator(
        notificationCenter: .default,
        windowActions: .live
    )

    private let notificationCenter: NotificationCenter
    private let windowActions: WindowActions
    private var processDependencies: ProcessBootstrapDependencies?
    private var didFinishLaunching = false
    private var didBootstrapProcessServices = false
    private var routeObserverTokens: [NSObjectProtocol] = []
    private var pendingDestinations: [NativeAgentNavigationDestination] = []
    private var mountedScene: (
        id: UUID,
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

    func applicationDidFinishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        installLegacyRouteObservers()
        bootstrapProcessServicesIfReady()
    }

    @discardableResult
    func mountMainScene(
        deliver: @escaping (NativeAgentNavigationDestination) -> Void
    ) -> UUID {
        let id = UUID()
        mountedScene = (id, deliver)
        drainPendingDestinations()
        return id
    }

    func unmountMainScene(id: UUID) {
        guard mountedScene?.id == id else { return }
        mountedScene = nil
    }

    func request(_ destination: NativeAgentNavigationDestination) {
        pendingDestinations.append(destination)
        windowActions.activateApplication()
        windowActions.openMainWindow()
        drainPendingDestinations()
    }

    func request(commandEntry: CoordinationCommandEntry) {
        guard let destination = NativeAgentNavigationDestination.commandEntry(commandEntry) else { return }
        request(destination)
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
        processDependencies.runInitialDoctor()
    }

    private func drainPendingDestinations() {
        guard let deliver = mountedScene?.deliver, !pendingDestinations.isEmpty else { return }
        let destinations = pendingDestinations
        pendingDestinations.removeAll(keepingCapacity: true)
        for destination in destinations {
            deliver(destination)
        }
    }

    private func installLegacyRouteObservers() {
        guard routeObserverTokens.isEmpty else { return }

        observe(.openNextGenRequest) { _ in .sidebar(.capabilities) }
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
