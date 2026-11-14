import Agents
import ChatToolRuntime
import ApprovalInbox
import MacIntegration
import Transcripts
import DeviceSync
import MemoryV2
import ProviderRouting
import MacControl
import TriggerScheduler
import Privacy
import SchedulerExecution
import Foundation
import AttentionRouting
import Experiences
import ChromeControl
import Cognition
import CognitiveSubstrate
import Context
import ContextFlow
import Desk
import TrustCenter
import ApprovalTransactions
import ActivityWatch
import AppToolRuntime
import SwiftUI
import UserNotifications
import ServiceManagement
import NativeAgentShared
// Unwired runtime subsystems must fail closed.
import NativeAgentCore
import StandingBots
import ChatTurnRuntime
import ChatTurnContracts
import ChatSessionWork
import AgentConversations
import BackgroundLoops
import BackgroundWork
import DreamREMCycle
import PersistenceCore
import PersonaEngine
import TrustPersistence
import OSLog
@_exported import EngineRuntime
import Connectors
import Browser
import DoctorChecks
import TelegramBot
#if canImport(BackgroundTasks)
import BackgroundTasks
import BackgroundTasks
// Blueprint: | `NativeAgentApp.swift` | Engine launch and app hosts; one delivery watch with launch, network and configured-door wakes |
#endif

@MainActor
final class NativeAgentHotkeyBootstrap {
    static let shared = NativeAgentHotkeyBootstrap()

    private let voice = VoiceInputCapture.forChat()
    private var voiceTurn: GlobalHotkeyVoiceTurn?
    private var wakeObserverToken: NSObjectProtocol?

    func start(appModel: AppModel) {
        ShotgunController.shared.attach(appModel: appModel)
        let hotkeyManager = GlobalHotkey.shared
        let voice = self.voice
        let voiceTurn: GlobalHotkeyVoiceTurn
        if let existing = self.voiceTurn {
            voiceTurn = existing
        } else {
            voiceTurn = GlobalHotkeyVoiceTurn(
                requestPermission: { await voice.requestPermission() },
                isVoiceHoldCurrent: { hotkeyManager.isVoiceHoldCurrent() },
                beginCapture: {
                    voice.startListening()
                    return voice.isListening
                        ? nil
                        : (voice.errorMessage ?? "Voice capture could not start.")
                },
                stopCapture: { await voice.stopListeningResult() },
                discardCapture: { voice.discardListening() },
                submitTurn: { transcript in
                    // The spoken turn goes to the conversation the window shows.
                    let shown = (try? BodyFacePresentation.current(model: appModel))?.scene?.selectedSession
                    return await appModel.sendChat(transcript, attachments: voice.attachment.map { [$0] } ?? [], sessionId: shown)
                },
                reportUnavailable: { message in
                    appModel.statusText = "Voice input unavailable: \(message)"
                    NativeAgentNotifications.post(title: "Voice input unavailable", body: message, deadline: nil)
                },
                reportRejectedTurn: { message in
                    appModel.statusText = "Voice message was not sent: \(message)"
                    NativeAgentNotifications.post(title: "Voice message was not sent", body: message, deadline: nil)
                }
            )
            self.voiceTurn = voiceTurn
        }
        hotkeyManager.onOpenWindow = {
            Task { @MainActor in
                ApplicationLifetime.shared.request(.sidebar(.chat))
            }
        }
        hotkeyManager.onVoiceStart = {
            Task { @MainActor in
                _ = await voiceTurn.beginVoiceTurn()
            }
        }
        hotkeyManager.onVoiceEnd = {
            Task { @MainActor in
                _ = await voiceTurn.endVoiceTurn()
            }
        }
        hotkeyManager.onVoiceCancel = { voiceTurn.cancelVoiceTurn() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Reread Settings at execution because launch may overlap edits; idempotent registration prevents duplicate Carbon churn.
            let defaults = UserDefaults.standard
            let enabled = defaults.object(forKey: "globalHotkeyEnabled") as? Bool ?? true
            hotkeyManager.setEnabled(enabled)
        }

        if let wakeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserverToken)
        }
        let wakeThrottle = WakeResetThrottle()
        wakeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            wakeThrottle.handleWake()
        }
    }
}

@main
enum NativeAgentAppMain {
    @MainActor
    static func main() {
        if AppRelaunch.runRelaunchHelperIfRequested() { return }
        if SwiftToolDispatcher.runScheduledInstallerHelperIfRequestedBlocking() { return }
        NativeAgentEngine.prepareProcessFileLimit()
        guard !NativeAgentLaunchPreflight.shouldSuppressGUIStart() else {
            NativeAgentLaunchPreflight.writeSuppressedLaunchReceipt()
            return
        }

        NativeAgentEnginePorts.installAppPorts(NativeAgentEnginePorts.mounted)

        InlineInteractionResolver.platform = AppInlineInteractionPlatformPort()
        // Capture launch grants before initialization can change this process's permission state.
        _ = SystemPermissionPreflight.grantedAtLaunch
        _ = NSApplication.shared
        guard AppDelegate.claimSingleAppInstance() else { return }
        let dataRoot = PersistenceCore.defaultDataRoot()
        NativeAgentEngine.installRuntimeObservationsAtLaunch(dataRoot: dataRoot)
        NativeAgentApp.main()
    }
}

private enum NativeAgentLaunchPreflight {
    static func shouldSuppressGUIStart(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> Bool {
        guard environment["CODEX_SHELL"] == "1" else { return false }
        return NSString(string: executablePath).standardizingPath
            .hasSuffix("/dist/NativeAgent.app/Contents/MacOS/NativeAgentApp")
    }

    static func writeSuppressedLaunchReceipt() {
        let message = """
            NativeAgent: refusing to launch the dist GUI bundle from a Codex shell; use script/install_app.sh and probe the installed app through the \
            authenticated bridge.\n
            """
        FileHandle.standardError.write(Data(message.utf8))
    }
}

struct AppBackgroundWorkHost: EngineBackgroundWorkHost {
    @MainActor var activityWatch: ActivityWatchController { .shared }
    var attention: AttentionRouter { .shared }
    var approvals: ApprovalExecution { .app() }
    func postMacNotification(title: String, body: String, userInfo: [String: String], soundName: String?) async -> NativeAgentNotificationPostResult {
        await NativeAgentNotifications.postAndReport(
            title: title, body: body, userInfo: userInfo, soundName: soundName, deadline: nil)
    }

    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> DoctorReport {
        try await AppDoctorPort(dataRoot: dataRoot).runtime.runDoctor(
            repair: true, repairScope: .automatic, checks: checks)
    }

    func makeCompletionSender(
        dataRoot: URL,
        silentTelegram: Bool,
        requestedResultDeliveryID: String?,
        authorizeTelegramReply: @escaping @Sendable (TelegramConfig, Int) -> Bool
    ) -> any AgentBridgeCompletionSending {
        EngineAgentBridgeCompletionSender(engine: { .live }, router: { .shared }, dataRoot: dataRoot, silentTelegram: silentTelegram,
            requestedResultDeliveryID: requestedResultDeliveryID, authorizeTelegramReply: authorizeTelegramReply)
    }

    var speechPermission: SpeechPermissionSnapshot {
        Self.speechSnapshot(SystemPermissionPreflight.status(.speechRecognition))
    }

    func requestSpeechPermissionIfNotDetermined() async -> SpeechPermissionSnapshot {
        Self.speechSnapshot(await SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined())
    }

    private static func speechSnapshot(_ status: SystemPermissionStatus) -> SpeechPermissionSnapshot {
        SpeechPermissionSnapshot(rawValue: status.rawValue, isGranted: status == .granted,
            warningSummary: SystemPermissionPreflight.warningSummary(for:
                SystemPermissionSnapshot(capability: .speechRecognition, status: status)),
            settingsLink: SystemPermissionPreflight.settingsURL(for: .speechRecognition)?.absoluteString)
    }

    var voiceName: String { AgentVoice.live.name }
    var agentSubject: String { AgentVoice.live.subject }

    var triggerNotifier: TriggerNotifier {
        { @Sendable note, notify in
            await TriggerNotificationDelivery.notify(note, notify: notify, delivery: NativeAgentEngine.liveDeviceSync,
                router: { .shared }, turn: nil)
        }
    }


}

struct NativeAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = ApplicationLifetime.shared

    init() {
        // CoreGraphics reads the preference at process startup, so changes require relaunch.
        if !UserDefaults.standard.bool(forKey: "CGFontRenderingFontSmoothingDisabled") {
            UserDefaults.standard.set(true, forKey: "CGFontRenderingFontSmoothingDisabled")
        }
        NativeAgentEngine.validateProvidersAtLaunch()
    }

    @MainActor
    static func prepare() async -> Bool {
        let dataRoot = PersistenceCore.defaultDataRoot()
        guard await NativeAgentEngine.prepareStateAtLaunch(
            dataRoot: dataRoot,
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            resources: Bundle.main.resourceURL,
            publicReleaseUnavailable: AppDelegate.presentPublicReleaseDataRootError,
            backupRestoreUnavailable: AppDelegate.presentBackupRestoreError,
            confirmMissingRoots: AppDelegate.confirmLaunchWithMissingRoots
        ) else { return false }
        SensesAssembly.install(dataRoot: dataRoot)
        await NativeAgentEngine.installBotProviderCheck()
        let appModel = AppModel()
        let settingsActs = BodySettingsActHandler(appModel: appModel)
        settingsActs.configure()
        do { try await appModel.engine.faceActs.installPlatform(settingsActs) }
        catch {
            appModel.setFailureStatus(error, action: "install the body settings owner")
            return false
        }
        // The window is its own process; her body never draws one.
        do {
            try AppDelegate.installFaceProcess(dataRoot: dataRoot, source: appModel.engine.face,
                handler: appModel.engine.faceActs, services: settingsActs)
            try await AppDelegate.openFaceWindow()
        } catch {
            appModel.setFailureStatus(error, action: "open the window")
            AppDelegate.presentFaceUnavailable(error)
        }

        MacWorkContinuation.capture = { text, taskReference in
            await appModel.captureMacWorkContinuation(text, taskReference: taskReference)
        }

        // Resume through the window's AppModel and report admission refusal so a durable resumed claim cannot strand a card over a turn that never ran.
        NativeAgentEngine.configureInlineInteractionsAtLaunch(startTurn: { prompt, sessionID, hideUserBubble, turn in
            let envelope = turn.envelope
            var origin = ChatMessageOrigin(surface: envelope?.surface ?? "chat", agent: envelope?.agent)
            origin.peerSources = turn.peerSteering?.checkpointSources ?? []
            origin.elevatedPeerSources = turn.peerSteering?.elevatedSources ?? []
            // The admitted turn retains the continuation's origin through delivery.
            let started = await appModel.startChatTurn(
                prompt, attachments: [], sessionId: sessionID, hideUserBubble: hideUserBubble,
                requireActiveSession: false, origin: origin, parent: turn
            )
            if !hideUserBubble { appModel.publishConversationAnchor(for: started.acceptance) }
            switch started.acceptance {
            case .accepted: return true
            case .rejected: return false
            }
        })

        ApplicationLifetime.shared.appModel = appModel
        return true
    }

    var body: some Scene {

        MenuBarExtra("NativeAgent", systemImage: "brain.head.profile") {
            MenuBarOpenButton()
            Button("Refresh status", systemImage: "arrow.clockwise") {
                Task { await coordinator.appModel?.refreshAll() }
            }
            .disabled(coordinator.appModel == nil)
            Divider()
            Button("Run health checks", systemImage: "stethoscope") {
                Task {
                    guard let appModel = coordinator.appModel else { return }
                    await appModel.runDoctor(repair: false)
                    NativeAgentNotifications.post(title: "NativeAgent health checks", body: appModel.statusText, deadline: nil)
                }
            }
            .disabled(coordinator.appModel == nil)
            Button("Show browser window", systemImage: "safari") {
                BrowserWindowController.shared.showWindow()
            }
            .disabled(coordinator.appModel == nil)
            Divider()
            Button("Restart app", systemImage: "arrow.triangle.2.circlepath") {
                AppRelaunch.relaunchApp(
                    terminate: AppDelegate.terminateFromRunLoop,
                    onSpawnFailure: {
                        ModuleLog.app("[relaunch] failed to spawn relaunch helper for %@: %@", Bundle.main.bundlePath, "\($0)")
                    })
            }
            Divider()
            if let appModel = coordinator.appModel {
                Text(MenuBarStatusPresentation.line(statusText: appModel.statusText,
                    health: appModel.face.slot(.counts).select("health", as: CountsFace.self) { $0?.statuses.health }))
            }
        }

        MenuBarExtra(
            "Activity capture is recording",
            systemImage: "record.circle",
            isInserted: activityCaptureIndicatorBinding
        ) {
            if let appModel = coordinator.appModel { ActivityCaptureMenuBarContent(appModel: appModel) }
        }
    }

    /// MenuBarExtra requires a writable binding; ignore writes so its recording indicator cannot disappear while capture continues.
    private var activityCaptureIndicatorBinding: Binding<Bool> {
        Binding(
            get: {
                coordinator.appModel?.face.slot(.counts).select("capture.recording", as: CountsFace.self) {
                    $0?.statuses.capture?.isCapturing
                } == true
            },
            set: { _ in }
        )
    }
}

private struct ActivityCaptureMenuBarContent: View {
    let appModel: AppModel

    private var capture: ActivityCaptureFace? {
        appModel.face.slot(.counts).select("capture", as: CountsFace.self) { $0?.statuses.capture }
    }

    var body: some View {
        if let capture {
            switch capture.availability {
            case .reading: Text("Reading the activity capture policy…")
            case .unavailable(let issue): Text("Activity capture policy is unavailable. \(issue)")
            case .available:
                Text("Recording which apps you use — app name and duration"
                    + (capture.capturesTitles ? ", plus window titles." : ", no window titles."))
            }
        } else {
            Text("Waiting for activity capture status…")
        }
        Divider()
        Button("Stop recording", systemImage: "stop.circle") {
            Task { await appModel.engine.activityWatch.setCaptureEnabled(false) }
        }
        Button("Activity settings…", systemImage: "gear") {
            SettingsLink.open(.trust)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var approvalNotificationTask: Task<Void, Never>?
    @MainActor var previousWorkApp: NSRunningApplication?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        let info = notification.request.content.userInfo
        let matter = (info["itemId"] as? String) == notification.request.identifier
        guard category == NativeAgentNotificationActions.approvalCategory
                || category == NativeAgentNotificationActions.messageCategory || matter else { return [] }
        return [.banner, .list, .sound]
    }

    /// Only explicit action buttons execute; opening or dismissing a banner must not perform its action.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = NativeAgentNotificationActions.Response(response)
        do { try await ApplicationLifetime.shared.prepare() } catch { return }
        await NativeAgentNotificationActions.handle(action)
    }

    static let residentIOSChatClient = NativeAgentEngine.live.chatClient(
        profile: .ios
    )
}

// Qualify the runtime transcript type to disambiguate ChatOrchestration imports.
typealias ChatMessage = EngineRuntime.ChatMessage
// Use NativeAgentShared UI/decoding types because Core also exports MemoryRecord and ChatSession.
typealias MemoryRecord = NativeAgentShared.MemoryRecord
typealias MultimodalAttachment = NativeAgentShared.MultimodalAttachment
typealias ChatSession = NativeAgentShared.ChatSession

extension NativeAgentEnginePorts {
    static func mounted(dataRoot: URL) -> Self {
        Task {
            await AgentContactHealth.shared.installGrokVerifier(dataRoot: dataRoot) { peer in
                do {
                    // Health verification is standalone work; its callback carries no chat turn.
                    let turn = Turn().with(\.envelope, .native("native:grok.verify"))
                    try await NativeAgentEngine.forRoot(dataRoot).agents.desktop.importGrokRoutine(
                        turn: turn, mac: .init(dataRoot: dataRoot), peer: peer, dataRoot: dataRoot, waitForCreation: false)
                }
                catch let blocker as GrokRoutineAccessibility.Blocker { throw ToolFailureError(blocker.rawValue, effects: .unknown) }
            }
        }
        return Self(
            backgroundWork: AppBackgroundWorkHost(),
            connectorStatus: AppConnectorStatusPlatform(),
            cognitionHost: EngineCognitionHost(attention: .shared),
            deviceSyncHost: EngineDeviceSyncHost(engine: { .live }, router: { .shared }, platform: AppDeviceSyncPlatform()),
            macIntegration: MacIntegrationDeliveryActions(),
            a2aPushConfiguration: { peer in
                let port = await ClaudeBridgeRuntime.shared.activePort
                guard port != 0 else {
                    throw ToolFailureError("The local A2A callback receiver is not listening. No message was sent.", effects: .none,
                        owner: "NativeAgent bridge listener", tap: "Open NativeAgent",
                        code: "agent_callback_receiver_unavailable",
                        instruction: "Repair the bridge listener before sending to this local webhook-capable contact.")
                }
                guard let secret = try AgentPeerCredentials.read(peerID: peer.id) else {
                    throw ToolFailureError(AgentPeerCredentials.unavailableDetail, effects: .none,
                        owner: "Keychain peer:" + peer.id, tap: "Agents → \(peer.name) → Connect",
                        code: "agent_callback_credential_missing", instruction: "Restore this contact's confirmed missing credential before sending.")
                }
                return .object(["url": .string("http://127.0.0.1:\(port)/a2a/notifications"),
                    "authentication": .object(["scheme": .string("Bearer"), "credentials": .string(secret)])])
            },
            completionSender: { EngineAgentBridgeCompletionSender(engine: { .live }, router: { .shared }, dataRoot: $0) },
            standingBotQueue: BotRunQueue(dataRoot: dataRoot),
            appTools: { AppToolExecutor(securityCenter: $0, enforceAutonomySecurity: $1) },
            browserRoutes: .app,
            connectorActions: { AppConnectorActionPlatform(engine: $0) },
            chatPlatform: ChatToolPlatformPort(
                grok: { plan, root, inner, surface, turn, mac in
                    await GrokBotConnection.perform(turn: turn, mac: mac, plan: plan, dataRoot: root,
                        inner: inner, surface: surface, port: NativeAgentEngine.live.agents.desktop)
                },
                desktopChat: { plan, root, turn, mac, conversation in
                    await DesktopChatRoute.perform(turn: turn, mac: mac, conversation: conversation,
                        plan: plan, dataRoot: root)
                },
                desktop: { plan, inner, surface, turn, work, mac in
                    await NativeAgentEngine.live.agents.desktop.run(
                        turn: turn, work: work, mac: mac, plan: plan, inner: inner, surface: surface)
                }
            )
        )
    }
}

private struct AppDeviceSyncPlatform: EngineDeviceSyncPlatform {
    @MainActor func settingsHost() throws -> any QuietSettingsHost {
        guard let appModel = ApplicationLifetime.shared.appModel else {
            throw QuietSettingError.unavailable("The Mac's settings are not loaded yet. Try again in a moment.")
        }
        return AppQuietSettingsHost(appModel)
    }
    @MainActor var oauthPlatform: any NativeOAuthPlatformPort.Type { BodyOAuthPlatform.self }
    @MainActor func adoptProvider(_ id: String) async { await ApplicationLifetime.shared.appModel?.adoptProviderForBlankSurfaces(id) }
    @MainActor func runMacControl(path: String, bodyData: Data, turn: Turn, context: MacOperationContext) async throws -> JSONValue {
        try await TrustCenterMacControlPolicyProvider.run(path: path, bodyData: bodyData,
            dataRoot: PersistenceCore.defaultDataRoot(), turn: turn, context: context)
    }
}

extension ClaudeBridgeRuntime {
    static let shared: ClaudeBridgeRuntime = NativeAgentEngine.makeAgentBridge(engine: { .live },
        grpcPort: { Agents.NativeAgentA2AGRPCListener.shared.port })
}
extension Agents.NativeAgentA2AGRPCListener {
    static let shared: Agents.NativeAgentA2AGRPCListener = NativeAgentEngine.makeA2AListener(engine: { .live }, bridge: { .shared })
}

extension AttentionRouter {
    static let shared: AttentionRouter = {
        let router = AttentionRouter(delivery: .engineDelivery(phone: { note, userInfo in
            try await NativeAgentEngine.liveDeviceSync.relay.sendNotification(title: note.title, subtitle: note.subtitle, body: note.message,
                userInfo: userInfo)
        }))
        let root = PersistenceCore.defaultDataRoot()
        let doors = EventDeadlinePhysiology.storeAndFileEvents(paths: [
            root.appendingPathComponent("notifications/push_tokens.json"), root.appendingPathComponent("paired_phones.json"),
            root.appendingPathComponent("telegram/config.json"), root.appendingPathComponent("connectors/slack/auth.json")],
            notifications: [UserDefaults.didChangeNotification])
        NativeAgentNotifications.keepDeliveryWatch(Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await router.watch() }
                group.addTask {
                    await releaseDelivery("launch", root: root, router: router)
                    guard !Task.isCancelled else { return }
                    for await up in NetworkSense.changes where up {
                        guard !Task.isCancelled else { return }
                        await releaseDelivery("network", root: root, router: router)
                    }
                }
                group.addTask {
                    var previous: JSONValue?
                    do { previous = try await readDeliveryConfiguration(root) }
                    catch { await recordDeliveryFailure("configuration", operation: "attention.delivery.configuration",
                                                       cause: error.localizedDescription, root: root) }
                    for await _ in doors {
                        guard !Task.isCancelled else { return }
                        do {
                            let current = try await readDeliveryConfiguration(root)
                            guard current != previous else { continue }
                            previous = current
                            await releaseDelivery("configuration", root: root, router: router)
                        } catch is CancellationError { return }
                        catch { await recordDeliveryFailure("configuration", operation: "attention.delivery.configuration",
                                                           cause: error.localizedDescription, root: root) }
                    }
                }
                await group.waitForAll()
            }
        })
        return router
    }()

    @concurrent nonisolated private static func releaseDelivery(_ phase: String, root: URL, router: AttentionRouter) async {
        do {
            _ = try await AttentionRouter.release(dataRoot: root, router: router, retrying: true)
            await RepairOwed.settle(root, operation: "attention.delivery.release",
                                   evidence: .init(source: "attention.delivery", id: UUID().uuidString.lowercased())).value
        } catch is CancellationError { return }
        catch { await recordDeliveryFailure(phase, operation: "attention.delivery.release", cause: error.localizedDescription, root: root) }
    }

    @concurrent nonisolated private static func readDeliveryConfiguration(_ root: URL) async throws -> JSONValue {
        let configuration = try deliveryConfiguration(root)
        await RepairOwed.settle(root, operation: "attention.delivery.configuration",
                               evidence: .init(source: "attention.delivery.configuration", id: UUID().uuidString.lowercased())).value
        return configuration
    }

    @concurrent nonisolated private static func recordDeliveryFailure(_ phase: String, operation: String, cause: String, root: URL) async {
        let owner = "attention.delivery"
        let words = "Delivery failed during " + phase + "; effects are unknown. Delivery remains owed: "
            + TurnSecretRedactor.redactDisplayText(cause)
            + ". Inspect the named door or experience store and reconcile unknown deliveries before sending again."
        await ExperienceStore.record(root, "repair:" + operation) { store in
            let open = try await RepairOwed.openDebt(store, operation: operation, owner: owner)
            let id = open?.id ?? ("attention.delivery." + phase + ":" + UUID().uuidString.lowercased())
            let face = Experience.Face(words: words, artifacts: [],
                                       row: .init(id: id, title: "Delivery needs repair", detail: words, tone: .failed), from: owner)
            if let open {
                try await store.append([.face(face)], to: open.id)
            } else {
                let failed = Experience(id: id, kind: .message, cause: ["attention.delivery." + phase],
                    face: face, addressedTo: ["person", "self"], owes: ["repair": .init(to: "self")],
                    claims: RepairDebt(owner: owner, operation: operation, lever: words).claims
                        + [.init(claim: "Delivery attempt failed; effects unknown.", evidence: [])])
                _ = try await store.begin(failed)
            }
        }.value
    }

    /// Observe door identity, excluding registration heartbeats and work-activity updates.
    private static func deliveryConfiguration(_ root: URL) throws -> JSONValue {
        func read(_ path: String) throws -> JSONValue {
            do { return try JSONValue.parse(Data(contentsOf: root.appendingPathComponent(path))) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .null }
        }
        let tokens = try read("notifications/push_tokens.json")
        var phones: [String: JSONValue] = [:]
        if tokens != .null {
            guard case .object(let registrations) = tokens else { throw CocoaError(.fileReadCorruptFile) }
            for (id, value) in registrations {
                guard case .object(let fields) = value else { throw CocoaError(.fileReadCorruptFile) }
                phones[id] = .object(fields.filter { ["token", "environment", "bundleId", "pairedDeviceID"].contains($0.key) })
            }
        }
        return .object(["phones": .object(phones), "pairing": try read("paired_phones.json"),
            "telegram": try read("telegram/config.json"), "slack": try read("connectors/slack/auth.json"),
            "push": .bool(NotificationChannelPreference.push()), "mac": .bool(NotificationChannelPreference.inApp()),
            "telegramEnabled": .bool(NotificationChannelPreference.telegram())])
    }
}
