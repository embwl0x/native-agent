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
import ChatToolRuntime
import ChatToolParsing
import ChatTurnContracts
import ChatTurnRuntime
import ToolExecution
import Senses
// Blueprint: | `ConnectorStatusProjection+LocalIntegrations.swift` | `mac-watch-catalog`; Read-only catalog and native recovery words |

/// The catalog is data: a status read must never create a schedule.
enum MacAssistantParts {
    static func dueReminders(input: [String: JSONValue], dataRoot: URL, turn: Turn,
                             context: MacOperationContext) async throws -> JSONValue {
        let invocation = ChatToolInvocation().serving(mac: context)
        let execution = AppActionExecution(invocation: invocation, deadlines: invocation.deadlines,
            turnWork: .init(toolInvocation: invocation))
        return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(
            envelope: TurnEnvelope.current(turn: turn, surface: "chat"), fileAccess: turn.fileAccess ?? "auto",
            turn: turn, execution: execution) { door in
            try await LocalPIMConnectorActions.remindersListDueToday(input: input, dataRoot: dataRoot, invocation: door.invocation)
        }
    }

    /// A part-answered door verb run for a native owner: the door's own gates and cards judge it, and the verb's result comes back.
    static func verb(_ action: String, input: [String: JSONValue], dataRoot: URL, envelope: TurnEnvelope, turn: Turn? = nil) async throws -> JSONValue {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: envelope, fileAccess: turn?.fileAccess ?? "auto", turn: turn) { door in
            CanonicalToolNameDispatcher.actionResult(try await door.perform("app", ["action": .string(action), "args": .object(input)]), action: action)
        }
    }

    static func watchCatalog(dataRoot: URL) async throws -> MacAssistantWatchCatalog {
        try await read(id: "mac-watch-catalog", dataRoot: dataRoot, as: MacAssistantWatchCatalog.self)
    }

    /// Admitting a part does not admit its effects; each effect needs its own originating gate chain.
    static func read<Value: Codable & Sendable>(id: String, dataRoot: URL, as type: Value.Type) async throws -> Value {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("connectors:" + id), fileAccess: "read_only") { door in
            switch await Parts(root: dataRoot).call(id: id, input: .object([:]), within: .init(actions: [], capabilities: []),
                invocation: door.invocation, as: type) {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    /// Parts supply words only; native status, reason, identity and effect evidence remain authoritative.
    static func recover(_ result: JSONValue, integration: String, dataRoot: URL) async -> JSONValue {
        func project(_ value: JSONValue, words: [String: String]) -> (value: JSONValue, needsWords: Bool) {
            let reply = ToolResult(value)
            guard case .object(var fields) = reply.payload else { return (reply.payload, false) }
            var needsWords = false
            if fields["status"]?.stringValue == reply.status, reply.said("failed"), fields["integration"] == .string(integration),
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
    public static func actionStatusEvidence(actionID: String, root: URL, platform: AppConnectorStatusPlatform) async throws -> ConnectorActionStatusEvidence? {
        let connectors = try await ConnectorReadiness.readConnectorRecords(
            root: root, platform: platform
        )
        let actions = ConnectorActionRecord.records(connectors: connectors)
        return actions.first { $0.id == actionID }.map {
            ConnectorActionStatusEvidence(connectorStatus: $0.connectorStatus, authState: $0.authState, enabled: $0.enabled)
        }
    }
}

/// Use the Connectors page’s decayed health proof: connected with a successful call within 7 days; read local state once.
extension ConnectorReadiness {
    static func isProven(id: String, root: URL, platform: AppConnectorStatusPlatform) async throws -> Bool {
        let rows = try await readConnectorRecords(root: root, platform: platform)
        let row = rows.first { $0.id == id }
        if row?.healthStatus == "ok" { return true }
        // Owners without registry rows need their own successful receipt within the same window.
        if row == nil, let proof = try ConnectorProofLedger.latestByConnector(root: root)[ConnectorProofLedger.canonicalID(id)],
           proof.succeeded, Date().timeIntervalSince(proof.at) < ConnectorHealthDecay.provenWindow {
            return true
        }
        return false
    }
}

/// Share checked pairing authority; optional APNS wakes do not determine notification support.
extension ConnectorReadiness {
    static func mobilePushStatus(deviceSync: DeviceSync) async -> [String: JSONValue] {
        guard NotificationChannelPreference.push() else {
            return ["status": .string("off"), "nextStep": .string("Turn on Deliver to the phone in Settings.")]
        }
        do {
            let phone = try await deviceSync.apns.notificationReadiness(dataRoot: deviceSync.dataRoot)
            return ["status": .string(phone.supported ? "ready" : "needs_setup"),
                    "nextStep": .string(phone.supported ? phone.detail : "Pair the companion iPhone app with this Mac.")]
        } catch {
            return ["status": .string("unavailable"), "nextStep": .string(error.localizedDescription)]
        }
    }
}

public struct AppConnectorStatusPlatform: Sendable {
    public func calendarEventKitReadState() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
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
    let chooseSharedFolder: (@MainActor @Sendable (UUID?) async throws -> (name: String, path: String, writable: Bool)?)?
    /// Opens the stem's secure paste for a Grok Bot contact's routine credentials (the contact's id).
    let showGrokSecureSetup: (@MainActor @Sendable (String) async throws -> Void)?
    let showProviderSetup: (@MainActor @Sendable (ProviderInfo, URL) async throws -> Void)?
    public init(subject: @escaping @Sendable () -> String,
                chooseSharedFolder: (@MainActor @Sendable (UUID?) async throws -> (name: String, path: String, writable: Bool)?)? = nil,
                showGrokSecureSetup: (@MainActor @Sendable (String) async throws -> Void)? = nil,
                showProviderSetup: (@MainActor @Sendable (ProviderInfo, URL) async throws -> Void)? = nil) {
        self.subject = subject
        self.chooseSharedFolder = chooseSharedFolder
        self.showGrokSecureSetup = showGrokSecureSetup
        self.showProviderSetup = showProviderSetup
    }
    public var agentSubject: String { subject() }

    public var isPublicReleaseBundle: Bool { InstallPaths.isPublicReleaseBundle }
}

public struct AppConnectorActionPlatform: ConnectorActionPlatform {
    let dataRoot: URL
    private let statusPlatform: AppConnectorStatusPlatform
    private let macAssistant: any MacAssistantStatusClient
    private let notification: @Sendable (String, String, Turn) async -> [String: JSONValue]

    public init(dataRoot: URL, statusPlatform: AppConnectorStatusPlatform,
                macAssistant: any MacAssistantStatusClient,
                notification: @escaping @Sendable (String, String, Turn) async -> [String: JSONValue]) {
        self.dataRoot = dataRoot
        self.statusPlatform = statusPlatform
        self.macAssistant = macAssistant
        self.notification = notification
    }

    public func spotlight(input: [String: JSONValue], turn: Turn) async throws -> MacControlResult {
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(),
            auditDataRoot: dataRoot
        )
        return try await impl.dispatch(action: "spotlight", body: input, turn: turn, context: .init(dataRoot: dataRoot))
    }

    public func postMessage(title: String, body: String, turn: Turn) async -> [String: JSONValue] {
        await notification(title, body, turn)
    }

    /// Every provider reads local state the app already owns — no network.
    public func macAssistantStatusClient() -> any MacAssistantStatusClient {
        macAssistant
    }

    public func statusEvidence(actionID: String) async throws -> ConnectorActionStatusEvidence? {
        try await ConnectorReadiness.actionStatusEvidence(actionID: actionID, root: dataRoot, platform: statusPlatform)
    }

    public func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await ProcessExecution.runBounded(
            executable: "/usr/bin/git", arguments: arguments, currentDirectory: repoRoot, timeout: timeout
        )
    }
}
