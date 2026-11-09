import AppKit
import AppToolRuntime
import EngineRuntime
import Foundation
import MemoryV2
import NativeAgentShared
import Observation
import PersistenceCore

// Blueprint: | `NativeAgentAppCoordinator.swift` | `ApplicationLifetime`: bootstrap and scene navigation; delivery proves acceptance only |

enum NativeAgentNavigationDestination: Equatable, Sendable {
    /// The window process's page for this destination; nil opens the window where it is.
    var faceDestination: FaceDestination? {
        switch self {
        case .sidebar(let item):
            if let home = SidebarItem.shellHome(for: item), var destination = Self.sidebar(home.parent).faceDestination {
                destination.item = home.tab
                return destination
            }
            // The window resolves page names through the same QuietPages owner (QuietPage.item is the forward map).
            let page: String? = switch item {
            case .chat: "chat"
            case .activity: "today"
            case .inboxPolicy: "inbox"
            case .memories: "memories"
            case .desk: "desk"
            case .bots: "bots"
            case .personality: "personality"
            case .providers: "providers"
            case .trust: "trust"
            case .connectors: "connectors"
            case .capabilities: "capabilities"
            case .diagnostics: "diagnostics"
            case .settings: "settings"
            default: nil
            }
            return page.map { FaceDestination(page: $0, item: nil, session: nil, message: nil) }
        case .ownPage(let id): return FaceDestination(page: id, item: nil, session: nil, message: nil)
        case .activity(let section):
            let page = switch section {
            case .approvals: "approvals"
            case .inbox: "today_inbox"
            case .memoryProposals: "memory_proposals"
            case .cognitionProposals: "cognition"
            }
            return FaceDestination(page: page, item: nil, session: nil, message: nil)
        }
    }

    case sidebar(SidebarItem)
    /// A page of the agent's own, by its id.
    case ownPage(String)
    case activity(ActivitySection)

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
        case "chat":
            return .sidebar(.chat)
        case "activity":
            return .sidebar(.activity)
        case "memories":
            return .sidebar(.memories)
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
        case "inboxpolicy":
            return .sidebar(.inboxPolicy)
        case "inspector", "turn_inspector", "readout":
            return .sidebar(.inspector)
        default:
            return nil
        }
    }
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
    private var didFinishLaunching = false
    private var didBootstrapProcessServices = false
    private var routeObserverTokens: [NSObjectProtocol] = []
    func applicationDidFinishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        installRouteObservers()
        bootstrapProcessServicesIfReady()
    }

    func request(_ destination: NativeAgentNavigationDestination) {
        AppDelegate.requestFaceWindowIfInstalled(destination: destination.faceDestination)
    }

    private func bootstrapProcessServicesIfReady() {
        guard didFinishLaunching,
              !didBootstrapProcessServices,
              let appModel else { return }
        didBootstrapProcessServices = true
        Task { @MainActor in await appModel.loadChatState() }
        NativeAgentHotkeyBootstrap.shared.start(appModel: appModel)
        Task.detached(priority: .utility) {
            await EmbeddingModelDownloadController.shared.start()
            await SwiftNativeMemoryV2.shared.warmUpEmbeddingsAtLaunch()
        }
    }

    private func installRouteObservers() {
        guard routeObserverTokens.isEmpty else { return }

        observe(.openApprovalsRequest) { _ in .activity(.approvals) }
        observe(.openTrustMultimodalRequest) { _ in
            Task { @MainActor in SettingsLink.open(.trust) }
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
