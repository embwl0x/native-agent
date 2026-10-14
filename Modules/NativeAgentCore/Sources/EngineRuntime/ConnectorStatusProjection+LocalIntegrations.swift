@preconcurrency import EventKit
import MacControl
import ChatOrchestration
import NativeAgentCore
import Connectors
import Foundation
import PersistenceCore
import MacAssistantStatus
import MacIntegration
import DeviceSync
import AttentionRouting

extension ConnectorStatusProjection {
    public static func actionStatusEvidence(actionID: String, root: URL, platform: any ConnectorStatusPlatform) async -> ConnectorActionStatusEvidence? {
        let connectors = (try? await ConnectorStatusProjection.readConnectorRecords(
            root: root, platform: platform
        )) ?? []
        let actions = ConnectorActionRecord.records(connectors: connectors)
        return actions.first { $0.id == actionID }.map {
            ConnectorActionStatusEvidence(connectorStatus: $0.connectorStatus, authState: $0.authState, enabled: $0.enabled)
        }
    }
}

public struct NativeAppLocalPIMStatusProvider: LocalPIMStatusProvider {
    let root: URL
    let authorizationStatus: @MainActor @Sendable (String) -> [String: JSONValue]

    public init(root: URL, authorizationStatus: @escaping @MainActor @Sendable (String) -> [String: JSONValue] = LocalPIMConnectorActions.authorizationStatusPayload) {
        self.root = root
        self.authorizationStatus = authorizationStatus
    }

    public func localStatuses() async -> [String: [String: JSONValue]] {
        let integrations = [("local_mail", MacIntegrationID.mail), ("local_calendar", MacIntegrationID.calendar),
                            ("local_reminders", MacIntegrationID.reminders)]
        let permissions: [String: MacIntegrationPermission]
        do {
            permissions = try await MacIntegrationPermissionStore(dataRoot: root).snapshotChecked().permissions
        } catch {
            return Dictionary(uniqueKeysWithValues: integrations.map {
                ($0.0, ["status": .string("unavailable"), "detail": .string(error.localizedDescription)])
            })
        }
        return await MainActor.run {
            Dictionary(uniqueKeysWithValues: integrations.map { id, integration in
                let status = permissions[integration]?.read == true ? authorizationStatus(id) : [
                    "status": .string("needs_policy"),
                    "detail": .string("Read access is disabled in Mac Integrations."),
                    "nextStep": .string("Enable read access in Mac Integrations."),
                ]
                return (id, status)
            })
        }
    }
}

/// Gmail / Google Calendar proof = the Connectors page's own row: connected,
/// and health still "ok" after `ConnectorHealthDecay` (a real call succeeded
/// in the last 7 days). Local files only; one registry read per status call.
public actor NativeAppConnectorProofProvider: ConnectorProofProvider {
    private let root: URL
    private var rows: [ConnectorRecord]?

    private let platform: any ConnectorStatusPlatform
    public init(root: URL, platform: any ConnectorStatusPlatform) {
        self.root = root
        self.platform = platform
    }

    public func proofStatus(provider: String) async -> [String: JSONValue] {
        // The status client says email/calendar; the Google rows are gmail/gcal
        // ("calendar" is the EventKit row).
        let id = ["email": "gmail", "calendar": "gcal"][provider] ?? provider
        if rows == nil {
            rows = (try? await ConnectorStatusProjection.readConnectorRecords(root: root, platform: platform)) ?? []
        }
        let row = rows?.first { $0.id == id }
        if row?.healthStatus == "ok" { return ["verified": .bool(true)] }
        if let row, ["connected", "configured", "connected_unverified"].contains(row.authState ?? "") {
            let name = row.name.isEmpty ? id : row.name
            return [
                "verified": .bool(false),
                "nextStep": .string("You're signed in to \(name), but I haven't had a successful read in the last 7 days, so it isn't verified."),
            ]
        }
        return ["verified": .bool(false), "nextStep": .string("Configure connector proof in the NativeAgent app")]
    }
}

/// iPhone push is ready when a notification can actually reach a phone: the
/// person hasn't switched phone delivery off, and either the paired iPhone
/// advertised CloudKit visual notifications or direct APNs has a target.
public struct NativeAppMobilePushStatusProvider: MobilePushStatusProvider {
    let deviceSync: DeviceSync
    public init(deviceSync: DeviceSync) { self.deviceSync = deviceSync }
    public func pushStatus() async -> [String: JSONValue] {
        guard NotificationChannelPreference.push() else {
            return ["status": .string("off"), "nextStep": .string("Turn on Deliver to the phone in Settings.")]
        }
        let peerReady = await MainActor.run { deviceSync.bridge.cloudKitVisualNotificationPeerReady }
        let apnsTargets: Int
        do {
            apnsTargets = try await deviceSync.apns.deliverableTargetCount()
        } catch {
            return ["status": .string("unavailable"), "nextStep": .string(error.localizedDescription)]
        }
        if peerReady || apnsTargets > 0 {
            return ["status": .string("ready"), "tokenConfigured": .bool(apnsTargets > 0)]
        }
        return ["status": .string("needs_setup"), "nextStep": .string("Configure mobile push in NativeAgent settings")]
    }
}

/// The Mac's side of the connector owners: EventKit permission, the agent's
/// display voice, and whether this is a distributed public build.
public struct AppConnectorStatusPlatform: ConnectorStatusPlatform {
    public func calendarEventKitReadState() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return "ready"
        case .notDetermined:
            return "probe_needed"
        case .writeOnly, .denied, .restricted:
            return "needs_permission"
        @unknown default:
            return "unknown"
        }
    }

    private let subject: @Sendable () -> String
    public init(subject: @escaping @Sendable () -> String) { self.subject = subject }
    public var agentSubject: String { subject() }

    public var isPublicReleaseBundle: Bool { InstallPaths.isPublicReleaseBundle }
}

/// The Mac surfaces connector actions run against: PIM, AppleScript,
/// Spotlight, notifications, git, and the Mac assistant status.
public struct AppConnectorActionPlatform: ConnectorActionPlatform {
    let dataRoot: URL
    private let statusPlatform: any ConnectorStatusPlatform
    private let router: @Sendable () -> AttentionRouter
    private let deviceSync: @Sendable () -> DeviceSync
    private let notification: @Sendable (String, String) async -> [String: JSONValue]

    public init(dataRoot: URL, statusPlatform: any ConnectorStatusPlatform,
                router: @escaping @Sendable () -> AttentionRouter, deviceSync: @escaping @Sendable () -> DeviceSync,
                notification: @escaping @Sendable (String, String) async -> [String: JSONValue]) {
        self.dataRoot = dataRoot
        self.statusPlatform = statusPlatform
        self.router = router
        self.deviceSync = deviceSync
        self.notification = notification
    }

    public func attentionRouter() -> AttentionRouter { router() }

    public func macAction(_ action: ConnectorPlatformAction, input: [String: JSONValue]) async throws -> JSONValue {
        switch action {
        case .calendarListUpcoming: return try await LocalPIMConnectorActions.calendarListUpcoming(input: input)
        case .remindersListDueToday: return try await LocalPIMConnectorActions.remindersListDueToday(input: input)
        case .mailListRecent: return try await MacAppleScriptBridge.mailListRecent(input: input)
        case .messagesRecentThreads: return try await MacAppleScriptBridge.messagesRecentThreads(input: input)
        case .notesListRecent: return try await MacAppleScriptBridge.notesListRecent(input: input)
        case .notesSearch: return try await MacAppleScriptBridge.notesSearch(input: input)
        case .contactsSearch: return try await MacContactsExecutor.search(input: input)
        }
    }

    public func spotlight(input: [String: JSONValue]) async throws -> MacControlResult {
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(),
            auditAppendPath: MacControlActionRoutes.auditPath(dataRoot: dataRoot)
        )
        return try await impl.dispatch(action: "spotlight", body: input)
    }

    public func postMessage(title: String, body: String) async -> [String: JSONValue] {
        await notification(title, body)
    }

    /// Every provider reads local state the app already owns — no network.
    public func macAssistantStatusClient() -> any MacAssistantStatusClient {
        makeMacAssistantStatusClient(
            proofs: NativeAppConnectorProofProvider(root: dataRoot, platform: statusPlatform),
            push: NativeAppMobilePushStatusProvider(deviceSync: deviceSync()),
            dispatcherTools: StaticDispatcherToolAvailabilityProvider(
                availableTools: SwiftToolDispatcher.catalogRegisteredToolNames
            ),
            localPIM: NativeAppLocalPIMStatusProvider(root: dataRoot)
        )
    }

    public func statusEvidence(actionID: String) async -> ConnectorActionStatusEvidence? {
        await ConnectorStatusProjection.actionStatusEvidence(actionID: actionID, root: dataRoot, platform: statusPlatform)
    }

    public func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await SystemProcessAdapter.runBounded(
            executable: "/usr/bin/git", arguments: arguments, currentDirectory: repoRoot, timeout: timeout
        )
    }
}
