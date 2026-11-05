import AppKit
import AppToolRuntime
import Foundation
import MemoryV2
import Observation
import PersistenceCore

// Blueprint: | `NativeAgentAppCoordinator.swift` | `ApplicationLifetime`: bootstrap and scene navigation; delivery proves acceptance only |

enum NativeAgentNavigationDestination: Equatable, Sendable {
    case sidebar(SidebarItem)
    case activity(ActivitySection)
    case skillsTools(SkillsToolsSection)
    case chatShortcut(ChatSlashPage)
    case savedThing(PaletteSavedDestination)

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
        case "memories":
            return .sidebar(.memories)
        case "skills":
            return .skillsTools(.skills)
        case "desk":
            return .sidebar(.desk)
        case "bots":
            return .sidebar(.bots)
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
        case "tools":
            return .skillsTools(.tools)
        case "inspector", "turn_inspector", "readout":
            return .sidebar(.inspector)
        case "macintegration", "mac_integration":
            return .sidebar(.macIntegration)
        default:
            return nil
        }
    }
}

/// Delivery proves mounted-scene acceptance only, never finished rendering or work.
enum NativeAgentNavigationRequestReceipt: Equatable, Sendable {
    case deliveredToMountedScene
    case queuedForMainScene
}

@MainActor @Observable
final class ApplicationLifetime {
    static let mainSceneID = "main"
    var appModel: AppModel? {
        didSet { bootstrapProcessServicesIfReady() }
    }
    @ObservationIgnored private var preparationTask: Task<Void, Error>?

    func prepare() async throws {
        if let preparationTask {
            try await preparationTask.value
            return
        }
        let task = Task {
            guard await NativeAgentApp.prepare() else { throw CocoaError(.fileReadUnknown) }
        }
        preparationTask = task
        try await task.value
    }

    static let shared = ApplicationLifetime()

    private let notificationCenter = NotificationCenter.default
    private var openMainWindow: @MainActor () -> Void = {}
    private var didFinishLaunching = false
    private var didBootstrapProcessServices = false
    private var routeObserverTokens: [NSObjectProtocol] = []
    private var pendingDestinations: [NativeAgentNavigationDestination] = []
    private var mountedScene: (
        id: UUID,
        visiblePageInput: () -> [String: JSONValue]?,
        deliver: (NativeAgentNavigationDestination) -> Void
    )?

    func configureMainWindowOpening(_ open: @escaping @MainActor () -> Void) {
        openMainWindow = open
        if !pendingDestinations.isEmpty {
            NSApp.activate()
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
        visiblePageInput: @escaping () -> [String: JSONValue]? = { nil },
        deliver: @escaping (NativeAgentNavigationDestination) -> Void
    ) -> UUID {
        let id = UUID()
        mountedScene = (id, visiblePageInput, deliver)
        _ = drainPendingDestinations()
        return id
    }

    func unmountMainScene(id: UUID) {
        guard mountedScene?.id == id else { return }
        mountedScene = nil
    }

    var visiblePageInput: [String: JSONValue]? { mountedScene?.visiblePageInput() }
    var currentPage: QuietPage? {
        guard SimpleViewMode.current == SimpleViewMode.advanced,
              case .string(let page)? = visiblePageInput?["page"] else { return nil }
        return QuietPages.page(named: page)
    }

    @discardableResult
    func request(_ destination: NativeAgentNavigationDestination) -> NativeAgentNavigationRequestReceipt {
        pendingDestinations.append(destination)
        NSApp.activate()
        openMainWindow()
        return drainPendingDestinations()
            ? .deliveredToMountedScene
            : .queuedForMainScene
    }

    /// Quiet routing requires a mounted scene and never queues: a deferred route would interrupt the person when a window next opens.
    func deliverQuietly(_ destination: NativeAgentNavigationDestination) -> Bool {
        guard let deliver = mountedScene?.deliver else { return false }
        UserDefaults.standard.set(SimpleViewMode.advanced, forKey: SimpleViewMode.key)
        deliver(destination)
        return true
    }

    private func bootstrapProcessServicesIfReady() {
        guard didFinishLaunching,
              !didBootstrapProcessServices,
              let appModel else { return }
        didBootstrapProcessServices = true
        DetachedChatWindowController.shared.attach(appModel: appModel)
        DetachedChatWindowController.shared.restoreFromPersist()
        Task { @MainActor in await appModel.loadChatState() }
        NativeAgentHotkeyBootstrap.shared.start(appModel: appModel)
        Task.detached(priority: .utility) {
            await EmbeddingModelDownloadController.shared.start()
            await SwiftNativeMemoryV2.shared.warmUpEmbeddingsAtLaunch()
        }
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

        observe(.openApprovalsRequest) { _ in .activity(.approvals) }
        observe(.openTelegramRequest) { _ in .sidebar(.telegram) }
        observe(.openTrustMultimodalRequest) { _ in
            Task { @MainActor in SettingsLink.open(.trust, tab: TrustTab.features.rawValue) }
            return nil
        }
        observe(.openChatDraftRequest) { _ in .sidebar(.chat) }
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
