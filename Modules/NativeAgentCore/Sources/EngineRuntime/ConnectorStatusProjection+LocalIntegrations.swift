@preconcurrency import EventKit
import MacControl
import NativeAgentCore
import NativeAgentShared
import Connectors
import Foundation
import PersistenceCore
import MacIntegration
import DeviceSync
import AttentionRouting
import AppToolRuntime
import ToolExecution
import Senses
// Blueprint: | `ConnectorStatusProjection+LocalIntegrations.swift` | connector platform actions, EventKit status, local proof and phone readiness snapshots, action evidence; Mac assistant catalog reads invoke the editable `mac-watch-catalog` seed through L0 Parts.call with effects refused; integration recovery parts supply words only over native reasons, preserving operation status/identity/effects, including batch actions, with visible recovery unavailability |

/// The catalog is data, never an execution route for a watch. Even a changed
/// catalog cannot create a schedule through the status/UI read's host.
enum MacAssistantParts {
    static func watchCatalog(dataRoot: URL) async throws -> [MacAssistantWatchRecipe] {
        try await read(id: "mac-watch-catalog", dataRoot: dataRoot, as: [MacAssistantWatchRecipe].self)
    }

    /// These native read consumers admit only the selected part itself. Any
    /// action or primitive effect still needs its own originating gate chain.
    static func read<Value: Codable & Sendable>(id: String, dataRoot: URL, as type: Value.Type) async throws -> Value {
        let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot) { tool, _ in
            tool == id ? nil : .object([
                "status": .string("refused"), "reason": .string("read_only"),
                "detail": .string("This read returns data; effects require their own explicit action."),
                "effects": .string("none")])
        }
        let result = await OwnedProgramInvocation.$host.withValue(host) {
            await Parts(root: dataRoot).call(id: id, input: .object([:]), as: type)
        }
        switch result {
        case .success(let recipes): return recipes
        case .failure(let error): throw error
        }
    }

    /// Only words come back from the part. The operation's status, reason,
    /// identity and effect evidence remain exactly the native result's.
    static func recover(_ result: JSONValue, integration: String, dataRoot: URL) async -> JSONValue {
        func project(_ value: JSONValue, words: [String: String]) -> (value: JSONValue, needsWords: Bool) {
            guard case .object(var fields) = value else { return (value, false) }
            var needsWords = false
            if fields["status"] == .string("failed"), fields["integration"] == .string(integration),
               case .string(let reason)? = fields["reason"] {
                needsWords = true
                if let message = words[reason] { fields["message"] = .string(message) }
            }
            if case .array(let items)? = fields["items"] {
                fields["items"] = .array(items.map { item in
                    let child = project(item, words: words); needsWords = needsWords || child.needsWords
                    return child.value
                })
            }
            if case .object(let actions)? = fields["actions"] {
                fields["actions"] = .object(actions.mapValues { action in
                    let child = project(action, words: words); needsWords = needsWords || child.needsWords
                    return child.value
                })
            }
            return (.object(fields), needsWords)
        }
        guard project(result, words: [:]).needsWords else { return result }
        do {
            let words = try await read(id: integration + "-recovery", dataRoot: dataRoot, as: [String: String].self)
            return project(result, words: words).value
        } catch {
            // A wording failure cannot erase or reinterpret an operation's effects.
            guard case .object(var fields) = result else { return result }
            fields["recovery_error"] = .object(["code": .string((error as? PartCallError)?.code ?? "failed"),
                "message": .string(error.localizedDescription)])
            return .object(fields)
        }
    }
}

extension ConnectorReadiness {
    public static func actionStatusEvidence(actionID: String, root: URL, platform: AppConnectorStatusPlatform) async -> ConnectorActionStatusEvidence? {
        let connectors = (try? await ConnectorReadiness.readConnectorRecords(
            root: root, platform: platform
        )) ?? []
        let actions = ConnectorActionRecord.records(connectors: connectors)
        return actions.first { $0.id == actionID }.map {
            ConnectorActionStatusEvidence(connectorStatus: $0.connectorStatus, authState: $0.authState, enabled: $0.enabled)
        }
    }
}

/// A connector's proof = the Connectors page's own row: connected, and health
/// still "ok" after `ConnectorHealthDecay` (a real call succeeded in the last
/// 7 days). Local files only; one registry read per status call.
extension ConnectorReadiness {
    static func isProven(id: String, root: URL, platform: AppConnectorStatusPlatform) async -> Bool {
        let rows = (try? await readConnectorRecords(root: root, platform: platform)) ?? []
        let row = rows.first { $0.id == id }
        if row?.healthStatus == "ok" { return true }
        // An owner with no registry row (the Mac bridge) is proven the same
        // way a row is: a successful receipt of its own within the window.
        if row == nil, let proof = ConnectorProofLedger.latestByConnector(root: root)[ConnectorProofLedger.canonicalID(id)],
           proof.succeeded, Date().timeIntervalSince(proof.at) < ConnectorHealthDecay.provenWindow {
            return true
        }
        return false
    }
}

/// iPhone push is ready when a notification can actually reach a phone: the
/// person hasn't switched phone delivery off, and either the paired iPhone
/// advertised CloudKit visual notifications or direct APNs has a target.
extension ConnectorReadiness {
    static func mobilePushStatus(deviceSync: DeviceSync) async -> [String: JSONValue] {
        guard NotificationChannelPreference.push() else {
            return ["status": .string("off"), "nextStep": .string("Turn on Deliver to the phone in Settings.")]
        }
        let apnsTargets: Int
        do {
            apnsTargets = try await deviceSync.apns.deliverableTargetCount()
        } catch {
            return ["status": .string("unavailable"), "nextStep": .string(error.localizedDescription)]
        }
        if apnsTargets > 0 {
            return ["status": .string("ready"), "tokenConfigured": .bool(apnsTargets > 0)]
        }
        return ["status": .string("needs_setup"), "nextStep": .string("Configure mobile push in NativeAgent settings")]
    }
}

/// The Mac's side of the connector owners: EventKit permission, the agent's
/// display voice, and whether this is a distributed public build.
public struct AppConnectorStatusPlatform: Sendable {
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
    private let statusPlatform: AppConnectorStatusPlatform
    private let router: @Sendable () -> AttentionRouter
    private let macAssistant: any MacAssistantStatusClient
    private let notification: @Sendable (String, String) async -> [String: JSONValue]

    public init(dataRoot: URL, statusPlatform: AppConnectorStatusPlatform,
                router: @escaping @Sendable () -> AttentionRouter, macAssistant: any MacAssistantStatusClient,
                notification: @escaping @Sendable (String, String) async -> [String: JSONValue]) {
        self.dataRoot = dataRoot
        self.statusPlatform = statusPlatform
        self.router = router
        self.macAssistant = macAssistant
        self.notification = notification
    }

    public func attentionRouter() -> AttentionRouter { router() }

    public func macAction(_ action: ConnectorPlatformAction, input: [String: JSONValue]) async throws -> JSONValue {
        switch action {
        case .calendarListUpcoming: return try await LocalPIMConnectorActions.calendarListUpcoming(input: input)
        case .remindersListDueToday: return try await LocalPIMConnectorActions.remindersListDueToday(input: input, dataRoot: dataRoot)
        case .mailListRecent: return await MacAssistantParts.recover(try await MacAppleScriptBridge.mailListRecent(input: input), integration:"mail", dataRoot:dataRoot)
        case .messagesRecentThreads: return await MacAssistantParts.recover(try await MacAppleScriptBridge.messagesRecentThreads(input: input), integration:"messages", dataRoot:dataRoot)
        case .notesListRecent: return await MacAssistantParts.recover(try await MacAppleScriptBridge.notesListRecent(input: input), integration:"notes", dataRoot:dataRoot)
        case .notesSearch: return await MacAssistantParts.recover(try await MacAppleScriptBridge.notesSearch(input: input), integration:"notes", dataRoot:dataRoot)
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
        macAssistant
    }

    public func statusEvidence(actionID: String) async -> ConnectorActionStatusEvidence? {
        await ConnectorReadiness.actionStatusEvidence(actionID: actionID, root: dataRoot, platform: statusPlatform)
    }

    public func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await ProcessExecution.runBounded(
            executable: "/usr/bin/git", arguments: arguments, currentDirectory: repoRoot, timeout: timeout
        )
    }
}
