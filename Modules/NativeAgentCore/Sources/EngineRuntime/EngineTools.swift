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
import Desk
import MacControl
// Blueprint: | `EngineTools.swift` | `PartDoor`, `withPartDoor`; Explicit turn, host and originating gated chain for native part calls |

/// A native operation holds its turn and dependencies, including in callbacks it keeps.
public struct PartDoor: Sendable {
    public typealias Dispatch = AppActionExecution.Perform
    public let turn: Turn
    public let host: any OwnedProgramToolHost
    public let dispatch: Dispatch
    public let execution: AppActionExecution
    public var invocation: Parts.Invocation {
        let program = OwnedProgramExecution(turn: turn, surface: turn.envelope?.surface ?? "chat",
            deadlines: execution.deadlines, wake: execution.wake, options: .init(handsBack: execution.handsBack),
            readContent: execution.invocation.readContent, valueIdentity: execution.valueCall,
            deadline: execution.invocation.waitDeadline, onActivity: { execution.deadlines.progressed() })
        let openScreenWatch: (@Sendable (MacScreenWatch.Request, Bool) async throws -> MacScreenWatch)? = execution.openScreenWatch.map { open in
            { @Sendable request, hands in try await open(request, hands, turn) }
        }
        return Parts.Invocation(host: host, execution: program, arrived: execution.arrived,
            progressed: { execution.deadlines.progressed() }, openScreenWatch: openScreenWatch)
    }

    public func perform(_ tool: String, _ input: [String: JSONValue]) async throws -> JSONValue {
        try await dispatch(tool, input, turn, execution)
    }
}

/// Mac and phone share the catalog’s status classification.
public enum ToolCatalogStatus: String, Sendable {
    case locked, unavailable, blocked, approval, active, available
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
        case .available: "checkmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
    public var tone: Tone {
        switch self {
        case .active: .positive
        case .blocked: .danger
        case .locked, .approval, .unknown: .warning
        case .unavailable, .available: .neutral
        }
    }
}

extension ChatToolCatalogSnapshot {
    public func status(for tool: ChatCatalogTool) -> ToolCatalogStatus {
        func normalized(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let name = normalized(tool.name)
        if !name.isEmpty, (builderPolicyLocked + macAppPolicyLocked).map(normalized).contains(name) { return .locked }
        if tool.availableNow == false { return .unavailable }
        guard let recordedAutonomy = tool.effectiveAutonomy else { return .unknown }
        let autonomy = normalized(recordedAutonomy)
        if autonomy == "blocked" { return .blocked }
        guard tool.availableNow == true, ["auto", "confirm"].contains(autonomy) else { return .unknown }
        if autonomy == "confirm" { return .approval }
        if !name.isEmpty, alwaysOnTools.map(normalized).contains(name) { return .active }
        return tool.modelVisible == nil ? .unknown : .available
    }
}

/// Share root-specific catalog and authored inventory across Tools, phone and Doctor; Keep/Off mutations read back through that same checked owner.
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
    public internal(set) var browserDryRunStartedAt: Date?
    public internal(set) var browserDryRunPreview: BrowserRun?
    public internal(set) var browserDryRunError: String?
    @ObservationIgnored var capabilitiesDidChange: (@MainActor @Sendable () async -> Void)?

    @ObservationIgnored private lazy var catalogRead = LatestRead()
    @ObservationIgnored private lazy var authoredRead = LatestRead()

    public nonisolated let dataRoot: URL
    nonisolated private let manifestReader: @Sendable (String?, Turn) async throws -> JSONValue

    public private(set) var catalog: ChatToolCatalogSnapshot?
    /// Retain proven catalog rows with failure state so the page can identify stale evidence.
    public var catalogLoadError: String?
    public private(set) var authored: [ToolRecord] = []

    public func refreshNativePower() async -> [(endpoint: String, label: String, error: Error)] {
        let read = await nativePowerRead.read({
            let receiptRead: (rows: [NativeActionReceipt], malformedRows: Int, blankRows: Int, truncated: Bool, readFailed: Bool,
                failure: String?) = await RuntimeReadouts.tailJSONL(
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
        await capabilitiesDidChange?()
        return read.3
    }

    public nonisolated init(dataRoot: URL, manifestReader: @escaping @Sendable (String?, Turn) async throws -> JSONValue) {
        self.dataRoot = dataRoot
        self.manifestReader = manifestReader
    }

    /// Raw sense reads retain their exact operation while traversing the ordinary gates.
    public nonisolated func readSense(tool: String, input: [String: JSONValue], turn parent: Turn?,
        operation: ExistingCornerReadOperation, admissionOnly: Bool) async throws -> JSONValue {
        let turn = parent ?? Turn().with(\.envelope, .native("sense:read"))
        let surface = TurnEnvelope.current(turn: turn, surface: "chat").surface
        let profile = surface == "chat" ? NativeAgentAppChatSurfaceProfile.mac
            : NativeAgentAppChatSurfaceProfile(rawValue: surface)
        let sessionID = turn.verifiedSessionID
        let filer = sessionID != nil && profile != .background ? NativeAgentChatApprovalFiler(dataRoot: dataRoot) : nil
        var invocation = ChatToolInvocation()
        invocation.metadataOnly = operation.metadataOnly
        invocation.readingRaw = operation.readingRaw
        invocation.frameSource = operation.lookSource
        invocation.passiveObservation = operation.passiveObservation || operation.sense.passive
        invocation.waitDeadline = operation.sense.deadline
        invocation.readCapture = operation.sense.appCapture
        invocation.readContent = operation.sense.readContent
        invocation.senseReads = operation.sense.senseReads
        invocation.senseRead = operation.sense
        let work = ChatTurnWork(admissionOnly: admissionOnly, toolInvocation: invocation)
        var execution = AppActionExecution(invocation: invocation, deadlines: invocation.deadlines, turnWork: work)
        execution.admissionOnly = admissionOnly
        let tools = NativeAgentEngine.forRoot(dataRoot).toolDispatchClient(enforceAppAutonomy: false, actionExecution: execution)
        let dispatcher = makeGatedToolDispatchClient(tools: tools, fileAccess: turn.fileAccess ?? "read_only",
            approvalFiler: filer, dataRoot: dataRoot, verifiedSessionId: sessionID,
            work: work)
        return try await dispatcher.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: execution.invocation)
    }

    /// Native owners and authenticated transports use the same turn door, preserving authority through nested calls and approvals.
    public nonisolated func withPartDoor<Value: Sendable>(envelope: TurnEnvelope,
        fileAccess: String = "auto", approvalFiler: (any ApprovalFiler)? = nil,
        approvedReplay: ApprovedChatToolReplay? = nil,
        turn parent: Turn? = nil, wake: JSONValue? = nil,
        wrote: (@Sendable (URL) -> Void)? = nil,
        continuation: DeskContinuationTurn? = nil,
        admitModel: (@Sendable (Turn?) async throws -> Turn)? = nil,
        execution suppliedExecution: AppActionExecution? = nil,
        operation: @Sendable (PartDoor) async throws -> Value) async throws -> Value {
        let surface = envelope.surface
        let turn = (parent ?? Turn(session: ResidentWake.session).with(\.verifiedSessionID, ResidentWake.session))
            .with(\.envelope, envelope).with(\.fileAccess, fileAccess)
        let engine = NativeAgentEngine.forRoot(dataRoot)
        let filer: any ApprovalFiler = approvalFiler ?? NativeAgentChatApprovalFiler(dataRoot: dataRoot)
        let perform: PartDoor.Dispatch = { name, arguments, turn, execution in
            let scopedTools = engine.toolDispatchClient(enforceAppAutonomy: false, actionExecution: execution)
            let invocation = execution.invocation.with(\.authoredCall, execution.authoredCall)
            let chain = makeGatedToolDispatchClient(tools: scopedTools, fileAccess: fileAccess,
                approvalFiler: filer, dataRoot: self.dataRoot, verifiedSessionId: turn.verifiedSessionID,
                approvedReplay: approvedReplay,
                work: .init(handsBack: execution.handsBack, admissionOnly: execution.admissionOnly, toolInvocation: invocation))
            return try await chain.dispatch(tool: name, input: arguments, surface: surface, turn: turn, invocation: invocation)
        }
        // A native ingress without a supplied operation starts one here; callers with an operation keep it whole.
        let invocation = ChatToolInvocation()
        var execution = suppliedExecution ?? AppActionExecution(invocation: invocation, deadlines: invocation.deadlines,
            turnWork: .init(toolInvocation: invocation))
        execution.perform = perform
        execution.wake = wake
        execution.invocation.wrote = wrote
        execution.invocation.deskContinuation = continuation
        execution.admitModel = admitModel
        let tools = engine.toolDispatchClient(enforceAppAutonomy: false, actionExecution: execution)
        return try await tools.withAuthoredProgramHost(surface: surface, turn: turn, execution: execution) { turn, execution in
            guard let host = execution.host else { throw PartError.invalid("The part door has no host.") }
            return try await operation(PartDoor(turn: turn, host: host, dispatch: perform, execution: execution))
        }
    }

    public nonisolated func loadManifest(detail: String? = nil, turn: Turn? = nil) async throws -> JSONValue {
        // A standalone native catalog read is its ingress; invoked reads keep their caller's turn.
        let turn = turn ?? Turn().with(\.envelope, .personOnMac("mac_ui:tools.catalog"))
        return try await manifestReader(detail, turn)
    }

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
        for tool in snapshot.tools {
            guard let raw = tool.catalogBucket, ChatToolCatalogBucket(rawValue: raw) != nil else {
                throw RuntimeReadError.unreadableFeed(
                    "Tool catalog bucket is unavailable for \(tool.name). Repair its registered catalog entry before reading Tools again.")
            }
        }
        return snapshot
    }

    /// Missing required fields are omitted by the store; invalid authored fields must fail the read.
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

    /// Keep UI visibility separate from exact Parts keep eligibility.
    public nonisolated func keepRefusal(_ tool: ToolRecord, turn: Turn?) -> String? {
        guard tool.candidateDigest != nil || ["draft", "disabled"].contains(tool.status) else {
            return tool.status == "active" ? "\(tool.name) is already on." : "Save a version of \(tool.name) before keeping it."
        }
        if (tool.candidateDigest ?? tool.codeFingerprint) != nil, tool.reviewedKeepDigest == nil {
            return "Refresh Tools to read the exact version before keeping it."
        }
        let outcome = Parts(root: dataRoot).keepEligibility(tool, fullMac: false, ownerAuthorized: true, turn: turn)
        return outcome.ok ? nil : outcome.text
    }

    /// Keep the rehearsed waiting version or re-enable it, then verify authored fields through readback.
    public nonisolated func keep(id: String, version: String?) async throws -> ToolRecord {
        let outcome = try await withPartDoor(envelope: .personOnMac("mac_ui:ability.keep:" + id)) { door in
            await Parts(root: dataRoot).enable(id, version: version, fullMac: false, ownerAuthorized: true, invocation: door.invocation)
        }
        guard outcome.ok else { throw PartError.invalid(outcome.text) }
        return try await readBack(id)
    }

    /// Owner-disabled parts stay off until the owner re-enables them.
    public nonisolated func switchOff(id: String, reason: String) async throws -> ToolRecord {
        let turn = Turn().with(\.envelope, .personOnMac("mac_ui:ability.disable:" + id))
        let outcome = Parts(root: dataRoot).disable(id, reason: reason, fullMac: false, ownerAuthorized: true, turn: turn)
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

    /// Catalog load failures must not clear the page’s proven rows.
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
        self.init(dataRoot: dataRoot) { detail, turn in
            try await NativeAgentEngine.forRoot(dataRoot).toolDispatchClient().toolManifest(detail: detail, turn: turn)
        }
    }
}
