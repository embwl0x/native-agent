import Foundation
@preconcurrency import EventKit
import NativeAgentCore
import PersistenceCore
import Connectors
import MacControl
import TrustCenter
import MacAssistantStatus
import AttentionRouting
import ChatOrchestration

/// TrustCenter's Mac control policy. The connector actions, the Mac
/// integration bridge and the Mac control routes all gate through it.
struct TrustCenterMacControlPolicyProvider: MacControlPolicyProvider {
    var dataRoot: URL = PersistenceCore.defaultDataRoot()
    // Supplied only by the local workbench call site, never decoded from a
    // remote request body. Raw HTTP/iOS callers leave this nil.
    var operatorOrigin: SecurityOriginContext? = nil

    func currentPolicy() async -> MacControlPolicy? {
        guard let snapshot = try? await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked() else { return nil }
        let policy = MacControlPolicy.fromTrustPolicyObject(snapshot.policy)
        guard let operatorOrigin else { return policy }
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            tool: "mac_control", origin: operatorOrigin
        )
        return MacControlGate.policyForAdmittedFullMac(policy, admitted: authority.admitted)
    }

    /// One Mac control route run in-process behind this gate. Unimplemented
    /// actions fail closed in Swift; there is no HTTP fallback. Only the
    /// person's own workbench may carry Full Mac admission.
    static func run(path: String, bodyData: Data, dataRoot: URL, localWorkbench: Bool) async throws -> MacControlRunResult {
        try await MacControlActionRoutes.run(
            path: path, bodyData: bodyData, dataRoot: dataRoot, localWorkbench: localWorkbench
        ) { operatorOrigin, auditPath in
            makeMacControl(
                policyProvider: TrustCenterMacControlPolicyProvider(
                    dataRoot: dataRoot, operatorOrigin: operatorOrigin
                ),
                auditAppendPath: auditPath,
                notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
            )
        }
    }
}


/// The Mac's side of the connector owners: EventKit permission, the agent's
/// display voice, and whether this is a distributed public build.
struct AppConnectorStatusPlatform: ConnectorStatusPlatform {
    func calendarEventKitReadState() -> String {
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

    var agentSubject: String { AgentVoice.live.subject }

    var isPublicReleaseBundle: Bool { NativeAgentPaths.isPublicReleaseBundle }
}

/// The Mac surfaces connector actions run against: PIM, AppleScript,
/// Spotlight, notifications, git, and the Mac assistant status.
struct AppConnectorActionPlatform: ConnectorActionPlatform {
    let dataRoot: URL

    func attentionRouter() -> AttentionRouter { .shared }

    func macAction(_ action: ConnectorPlatformAction, input: [String: JSONValue]) async throws -> JSONValue {
        switch action {
        case .calendarListUpcoming: return try await MacPIMConnectorActions.calendarListUpcoming(input: input)
        case .remindersListDueToday: return try await MacPIMConnectorActions.remindersListDueToday(input: input)
        case .mailListRecent: return try await MacAppleScriptBridge.mailListRecent(input: input)
        case .messagesRecentThreads: return try await MacAppleScriptBridge.messagesRecentThreads(input: input)
        case .notesListRecent: return try await MacAppleScriptBridge.notesListRecent(input: input)
        case .notesSearch: return try await MacAppleScriptBridge.notesSearch(input: input)
        case .contactsSearch: return try await MacContactsAdapter.search(input: input)
        }
    }

    func spotlight(input: [String: JSONValue]) async throws -> MacControlResult {
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(),
            auditAppendPath: MacControlActionRoutes.auditPath(dataRoot: dataRoot)
        )
        return try await impl.dispatch(action: "spotlight", body: input)
    }

    func postMessage(title: String, body: String) async -> [String: JSONValue] {
        await NativeAgentNotifications.postMessage(title: title, body: body).deliveryFields()
    }

    /// Every provider reads local state the app already owns — no network.
    func macAssistantStatusClient() -> any MacAssistantStatusClient {
        makeMacAssistantStatusClient(
            proofs: NativeAppConnectorProofProvider(root: dataRoot),
            push: NativeAppMobilePushStatusProvider(),
            dispatcherTools: StaticDispatcherToolAvailabilityProvider(
                availableTools: SwiftToolDispatcher.catalogRegisteredToolNames
            ),
            localPIM: NativeAppLocalPIMStatusProvider(root: dataRoot)
        )
    }

    func statusEvidence(actionID: String) async -> ConnectorActionStatusEvidence? {
        let connectors = (try? await ConnectorStatusProjection.readConnectorRecords(
            root: dataRoot, platform: AppConnectorStatusPlatform()
        )) ?? []
        let actions = ConnectorActionRecord.records(connectors: connectors)
        return actions.first { $0.id == actionID }.map {
            ConnectorActionStatusEvidence(connectorStatus: $0.connectorStatus, authState: $0.authState, enabled: $0.enabled)
        }
    }

    func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await SystemProcessAdapter.runBounded(
            executable: "/usr/bin/git", arguments: arguments, currentDirectory: repoRoot, timeout: timeout
        )
    }
}

extension SystemProcessAdapter {
    /// One process run bounded by `timeout`; a timeout reads as exit 124
    /// with its stderr (or a line naming the command that timed out).
    static func runBounded(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try await SystemProcessAdapter().run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: timeout
        )
        if result.timedOut {
            let stderr = result.stderr.isEmpty
                ? "\(URL(fileURLWithPath: executable).lastPathComponent) command timed out"
                : result.stderr
            return (124, result.stdout, stderr)
        }
        return (result.exitCode, result.stdout, result.stderr)
    }
}
