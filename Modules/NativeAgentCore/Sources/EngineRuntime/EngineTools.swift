import NativeAgentCore
import NativeAgentShared
import ApprovalTransactions
import AppToolRuntime
import Browser
import Foundation
import Observation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import PersistenceCore
import ToolRegistry
import ToolExecution
import Senses
import PersonaEngine
import AgentWorkspace
// Blueprint: | `EngineTools.swift` | ToolsFacade owns authored tools, slash planning, full form descriptors and shared catalog status classification; `withPartDoor` gives native scheduled/UI owners and Tools Keep the ordinary gated chain and AppChatToolDispatcher host, with originating work identity, resident approval session and caller's file-access posture inherited by part thinking; native callers can supply their authenticated envelope and existing approval filer, preserving Telegram transport and Desk-click authority without another door; one checked skill inventory supplies metadata, source/revision and guidance detail from the same body read (phone metadata omits source). LatestRead orders slash, catalog, authored, skill and native-power reads; committed authored writes use write. Native actions derive from their registry; receipts and notification/browser status retain availability. |

/// The catalog's one status classification for Mac and phone.
public enum ToolCatalogStatus: String, Sendable {
    case locked, unavailable, blocked, approval, active, available
    case onDemand = "on demand"
    case unknown = "status unavailable"
    public enum Tone { case positive, neutral, warning, danger }
    public var title: String { rawValue }
    public var systemImage: String {
        switch self {
        case .locked: "lock"
        case .unavailable: "minus.circle"
        case .blocked: "hand.raised"
        case .approval: "checkmark.shield"
        case .active: "circle.fill"
        case .onDemand: "bolt.circle"
        case .available: "checkmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
    public var tone: Tone {
        switch self {
        case .active: .positive
        case .blocked: .danger
        case .locked, .approval, .unknown: .warning
        case .unavailable, .onDemand, .available: .neutral
        }
    }
}

extension ChatToolCatalogSnapshot {
    public func status(for tool: ChatCatalogTool) -> ToolCatalogStatus {
        func normalized(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let name = normalized(tool.name)
        if !name.isEmpty, (builderPolicyLocked + macAppPolicyLocked).map(normalized).contains(name) { return .locked }
        if tool.availableNow == false { return .unavailable }
        let autonomy = normalized(tool.effectiveAutonomy)
        if autonomy == "blocked" { return .blocked }
        guard tool.availableNow == true, ["", "auto", "confirm"].contains(autonomy) else { return .unknown }
        if autonomy == "confirm" { return .approval }
        let loadState = normalized(tool.loadState)
        if loadState == "loaded" || (!name.isEmpty && currentlyLoaded.map(normalized).contains(name)) { return .active }
        if loadState == "discovery_only" { return .onDemand }
        return loadState.isEmpty ? .available : .unknown
    }
}

/// `NativeAgentEngine.tools`: the tool catalog and the authored-tool
/// registry for one data root, in core types. The Tools page renders
/// `catalog` (every tool, its load state and its trust here) and `authored`;
/// the phone snapshot and Doctor use the same owner. Registry writes (auto-run, promote, quarantine) read back through
/// the same authored-field check.
@MainActor
@Observable
public final class ToolsFacade {
    public private(set) var skills: [SkillRecord] = []
    public private(set) var skillsReadError: String?
    @ObservationIgnored private let skillsRead = LatestRead()
    @ObservationIgnored private let nativePowerRead = LatestRead()

    @discardableResult
    public func refreshSkills(includingSource: Bool = false) async throws -> [SkillRecord] {
        let result: Result<[SkillRecord], Error> = await skillsRead.read({
            do { return .success(try await RuntimeReadouts.skills(dataRoot: dataRoot, includingSource: true)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let inventory): skills = inventory; skillsReadError = nil
            case .failure(let error): skillsReadError = error.localizedDescription
            }
        })
        let read = try result.get()
        return includingSource ? read : read.map { skill in
            var metadata = skill
            metadata.body = nil
            metadata.bodyRevision = nil
            return metadata
        }
    }
    public var nativeActions: [NativeActionRecord] { NativeActionRoutes.swiftNativeActionRecords() }
    public private(set) var nativeActionReceipts: [NativeActionReceipt] = []
    public private(set) var notificationStatus: NotificationRuntimeStatus?
    public private(set) var browserStatus: BrowserRuntimeStatus?
    public private(set) var nativePowerRefresh: PanelRefreshStatus?

    @ObservationIgnored private lazy var catalogRead = LatestRead()
    @ObservationIgnored private lazy var authoredRead = LatestRead()

    public nonisolated let dataRoot: URL
    nonisolated private let manifestReader: @Sendable (String?) async throws -> JSONValue

    /// The full catalog as of the last successful read.
    public private(set) var catalog: ChatToolCatalogSnapshot?
    /// Why the last catalog read failed; nil after a successful one. A failed
    /// read keeps the previous `catalog` so the page can say it is stale.
    public var catalogLoadError: String?
    /// The tools she wrote, as of the last read.
    public private(set) var authored: [ToolRecord] = []

    public func refreshNativePower() async -> [(endpoint: String, label: String, error: Error)] {
        let read = await nativePowerRead.read({
            let receiptRead: (rows: [NativeActionReceipt], malformedRows: Int, blankRows: Int, truncated: Bool, readFailed: Bool, failure: String?) = await RuntimeReadouts.tailJSONL(
                path: SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot).nativeActionsReceiptsPath, limit: 50)
            var notification: NotificationRuntimeStatus?
            var browser: BrowserRuntimeStatus?
            var failures: [(endpoint: String, label: String, error: Error)] = []
            if let failure = receiptRead.failure {
                failures.append(("native action receipts", "tailJSONL", RuntimeReadError.unreadableFeed(failure)))
            }
            do { notification = try await RuntimeReadouts.getNotificationStatus(dataRoot: dataRoot) }
            catch { failures.append(("notification status", "getNotificationStatus", error)) }
            do { browser = try await RuntimeReadouts.getBrowserStatus(dataRoot: dataRoot) }
            catch { failures.append(("browser status", "getBrowserStatus", error)) }
            return (receiptRead.failure == nil ? receiptRead.rows : nil, notification, browser, failures)
        }, publish: { read in
            if let receipts = read.0 { nativeActionReceipts = receipts }
            if let value = read.1 { notificationStatus = value }
            if let value = read.2 { browserStatus = value }
            nativePowerRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                lastSuccessAt: read.3.isEmpty ? Date() : nativePowerRefresh?.lastSuccessAt, failedEndpoints: read.3.map { $0.endpoint })
        })
        return read.3
    }

    public nonisolated init(dataRoot: URL, manifestReader: @escaping @Sendable (String?) async throws -> JSONValue) {
        self.dataRoot = dataRoot
        self.manifestReader = manifestReader
    }

    /// Native owners and authenticated transports enter the same door as a turn.
    /// Its envelope keeps its authority through nested calls and approvals.
    public nonisolated func withPartDoor<Value: Sendable>(envelope: TurnEnvelope,
        fileAccess: String = "auto", approvalFiler: (any ApprovalFiler)? = nil,
        approvedReplay: ApprovedChatToolReplay? = nil,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        let surface = envelope.surface
        let engine = NativeAgentEngine.forRoot(dataRoot)
        let filer: any ApprovalFiler = approvalFiler ?? NativeAgentChatApprovalFiler(dataRoot: dataRoot)
        let tools = engine.toolDispatchClient(enforceAppAutonomy: false, swarmApprovalFiler: filer)
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: fileAccess,
            approvalFiler: filer, dataRoot: dataRoot, verifiedSessionId: ResidentWake.session, approvedReplay: approvedReplay)
        return try await ChatToolSessionContext.$fileAccess.withValue(fileAccess) {
            try await ChatToolSessionContext.$envelope.withValue(envelope) {
                try await AppDoorReentry.$perform.withValue({ name, arguments in
                    try await chain.dispatch(tool: name, input: arguments, surface: surface)
                }) {
                    try await tools.withAuthoredProgramHost(surface: surface, operation: operation)
                }
            }
        }
    }

    /// The trust-aware manifest from this engine's tool-chain composition.
    public nonisolated func loadManifest(detail: String? = nil) async throws -> JSONValue {
        try await manifestReader(detail)
    }

    /// The full manifest, typed for the Tools page.
    public func loadCatalog() async throws -> ChatToolCatalogSnapshot {
        let result: Result<ChatToolCatalogSnapshot, Error> = await catalogRead.read({
            do { return .success(try await readCatalog()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let value):
                catalog = value
                catalogLoadError = nil
            case .failure(let error):
                catalogLoadError = error.localizedDescription
            }
        })
        return try result.get()
    }

    private nonisolated func readCatalog() async throws -> ChatToolCatalogSnapshot {
        let envelope = try await loadManifest(detail: "full")
        guard let snapshot = ChatToolCatalogSnapshot(envelope: envelope) else {
            throw NSError(
                domain: "NativeAgent.ChatToolCatalog",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tool manifest returned an invalid envelope."]
            )
        }
        return snapshot
    }

    /// Checked authored records: missing required fields are omitted by the store;
    /// invalid authored fields fail the read.
    public func listAuthored() async throws -> [ToolRecord] {
        try await authoredRead.read({
            try await SwiftNativeToolRegistry(root: dataRoot).listTools()
        }, publish: { authored = $0 })
    }

    public func refreshAuthored(confirming id: String, status: String) async throws -> Bool {
        let records = try await listAuthored()
        guard records.first(where: { $0.id == id })?.status == status else { return false }
        return true
    }

    /// UI visibility stays separate from Parts' exact keep eligibility.
    public nonisolated func keepRefusal(_ tool: ToolRecord) -> String? {
        guard tool.candidateDigest != nil || ["draft", "disabled"].contains(tool.status) else {
            return tool.status == "active" ? "\(tool.name) is already on." : "Save a version of \(tool.name) before keeping it."
        }
        if (tool.candidateDigest ?? tool.codeFingerprint) != nil, tool.reviewedKeepDigest == nil {
            return "Refresh Tools to read the exact version before keeping it."
        }
        let outcome = Parts(root: dataRoot).keepEligibility(tool, fullMac: false, ownerAuthorized: true)
        return outcome.ok ? nil : outcome.text
    }

    /// The Tools page's Keep: the owner keeps a part's rehearsed waiting
    /// version, or turns it back on (nil version for Markdown guidance);
    /// read back through the authored-field check.
    public nonisolated func keep(id: String, version: String?) async throws -> ToolRecord {
        let outcome = try await withPartDoor(envelope: .native("mac_ui:ability.keep:" + id)) {
            await Parts(root: dataRoot).enable(id, version: version, fullMac: false, ownerAuthorized: true)
        }
        guard outcome.ok else { throw PartError.invalid(outcome.text) }
        return try await readBack(id)
    }

    /// The Tools page's off-switch: the owner's, kept until the owner turns it back on.
    public nonisolated func switchOff(id: String, reason: String) async throws -> ToolRecord {
        let outcome = Parts(root: dataRoot).disable(id, reason: reason, fullMac: false, ownerAuthorized: true)
        guard outcome.ok else { throw PartError.invalid(outcome.text) }
        return try await readBack(id)
    }

    private func readBack(_ id: String) async throws -> ToolRecord {
        guard let record = try await SwiftNativeToolRegistry(root: dataRoot).getTool(id: id) else {
            throw ToolRegistryError.registryUnreadable(reason: "ability \(id) has no registry record")
        }
        authoredRead.write {
            if let index = authored.firstIndex(where: { $0.id == id }) { authored[index] = record }
            else { authored.append(record) }
        }
        return record
    }

    /// Loads the catalog into `catalog`, recording a failure instead of
    /// clearing what the page already shows.
    @discardableResult
    public func refreshCatalog() async -> Bool {
        do {
            _ = try await loadCatalog()
            return true
        } catch {
            nativeLog("[ChatToolCatalog] dispatch failed: \(error.localizedDescription)")
            return false
        }
    }
}
extension ToolsFacade {
    public nonisolated convenience init(dataRoot: URL) {
        self.init(dataRoot: dataRoot) { detail in
            try await NativeAgentEngine.forRoot(dataRoot).toolDispatchClient().toolManifest(detail: detail)
        }
    }
}
