import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApprovalInbox
import ApprovalTransactions
import Connectors
import MacControl
import MacAssistantStatus
import AttentionRouting

extension NativeClient {
    private var connectorActions: ConnectorActions {
        ConnectorActions(platform: NativeClientConnectorPlatform(client: self))
    }

    private static var defaultConnectorActions: ConnectorActions {
        NativeClient().connectorActions
    }

    typealias ConnectorActionApprovalReplay = ApprovalTransactionCoordinator.ConnectorActionApprovalReplay

    func runConnectorAction(
        id: String,
        dryRun: Bool,
        input: [String: JSONValue] = [:],
        externalSendIdempotencyKey: String? = nil,
        surface: String = "connector_action",
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        try await connectorActions.runConnectorAction(id: id, dryRun: dryRun, input: input, externalSendIdempotencyKey: externalSendIdempotencyKey, surface: surface, dataRoot: dataRoot)
    }

    func runConnectorAction(
        descriptor: ConnectorActionDescriptor,
        dryRun: Bool,
        input: [String: JSONValue] = [:],
        externalSendIdempotencyKey: String? = nil,
        approvedReplayApprovalID: String? = nil,
        surface: String = "connector_action",
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        try await connectorActions.runConnectorAction(descriptor: descriptor, dryRun: dryRun, input: input, externalSendIdempotencyKey: externalSendIdempotencyKey, approvedReplayApprovalID: approvedReplayApprovalID, surface: surface, dataRoot: dataRoot)
    }

    static func fullMacYoloAdmitted(
        tool: String,
        surface: String,
        dataRoot: URL
    ) async -> Bool {
        await ConnectorActions.fullMacYoloAdmitted(tool: tool, surface: surface, dataRoot: dataRoot)
    }

    func fullMacYoloAuthorityAdmitted(tool: String, surface: String) async -> Bool {
        await Self.fullMacYoloAdmitted(
            tool: tool,
            surface: surface,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    func runMacSpotlightSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await connectorActions.runMacSpotlightSearch(input: input)
    }

    static func runMacNotify(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.defaultConnectorActions.runMacNotify(input: input)
    }

    static func runMobileNotify(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.defaultConnectorActions.runMobileNotify(input: input)
    }

    static func runMacAssistantWatchTemplates() async throws -> JSONValue {
        try await Self.defaultConnectorActions.runMacAssistantWatchTemplates()
    }

    static func runSchedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await ConnectorActions.runSchedulerCreateJob(input: input)
    }

    static func runSchedulerListJobs() async throws -> JSONValue {
        try await ConnectorActions.runSchedulerListJobs()
    }

    static func runSchedulerCancelJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await ConnectorActions.runSchedulerCancelJob(input: input)
    }

    static func runMarketTool(_ tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        try await ConnectorActions.runMarketTool(tool, input: input)
    }

    static func readCodexHandoff(input: [String: JSONValue]) throws -> JSONValue {
        try ConnectorActions.readCodexHandoff(input: input)
    }

    static func runCodexWorkJournal(input: [String: JSONValue]) async throws -> JSONValue {
        try await Self.defaultConnectorActions.runCodexWorkJournal(input: input)
    }

    static func codexJournalRoots(
        input: [String: JSONValue],
        maxProjects: Int,
        dataRoot: URL
    ) async throws -> [URL] {
        try await ConnectorActions.codexJournalRoots(input: input, maxProjects: maxProjects, dataRoot: dataRoot)
    }

    static func registeredWorkspaceRoots(dataRoot: URL) async throws -> [URL] {
        try await ConnectorActions.registeredWorkspaceRoots(dataRoot: dataRoot)
    }

    static func codexJournalProject(root: URL, days: Int, maxCommits: Int) async throws -> JSONValue? {
        try await Self.defaultConnectorActions.codexJournalProject(root: root, days: days, maxCommits: maxCommits)
    }

    static func parseCodexJournalCommits(_ raw: String) -> [JSONValue] {
        ConnectorActions.parseCodexJournalCommits(raw)
    }

    static func recentMarkdownEntries(_ text: String, maxEntries: Int, maxEntryChars: Int) -> [String] {
        ConnectorActions.recentMarkdownEntries(text, maxEntries: maxEntries, maxEntryChars: maxEntryChars)
    }

    static func fileModifiedISO(_ path: URL) -> String? {
        ConnectorActions.fileModifiedISO(path)
    }

    static func connectorInputString(_ raw: JSONValue?) -> String? {
        ConnectorActions.connectorInputString(raw)
    }

    static func connectorInputBool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        ConnectorActions.connectorInputBool(raw, default: defaultValue)
    }

    static func connectorInputInt(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        ConnectorActions.connectorInputInt(raw, default: defaultValue)
    }

    static func connectorInputStringArray(_ raw: JSONValue?) -> [String] {
        ConnectorActions.connectorInputStringArray(raw)
    }

    static func connectorOutputStatus(_ output: JSONValue) -> String? {
        ConnectorActions.connectorOutputStatus(output)
    }

    func connectorStatusActionOutput(_ descriptor: ConnectorActionDescriptor) async throws -> JSONValue {
        try await connectorActions.connectorStatusActionOutput(descriptor)
    }

    static func createConnectorActionApproval(
        _ descriptor: ConnectorActionDescriptor,
        input: [String: JSONValue],
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ApprovalRecord {
        try await ConnectorActions.createConnectorActionApproval(descriptor, input: input, dataRoot: dataRoot)
    }

    static func connectorActionApprovalReplay(from record: ApprovalRecord) -> ConnectorActionApprovalReplay? {
        ConnectorActions.connectorActionApprovalReplay(from: record)
    }

    static func validateApprovedConnectorReplay(
        approvalID: String,
        descriptor: ConnectorActionDescriptor,
        input: [String: JSONValue],
        dataRoot: URL
    ) async throws {
        try await ConnectorActions.validateApprovedConnectorReplay(approvalID: approvalID, descriptor: descriptor, input: input, dataRoot: dataRoot)
    }

    static func appendConnectorActionReceipt(
        descriptor: ConnectorActionDescriptor,
        status: String,
        dryRun: Bool,
        approvalId: String?,
        output: JSONValue,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        try await ConnectorActions.appendConnectorActionReceipt(descriptor: descriptor, status: status, dryRun: dryRun, approvalId: approvalId, output: output, dataRoot: dataRoot)
    }
}

private struct NativeClientConnectorPlatform: ConnectorActionPlatform {
    let client: NativeClient

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
            policyProvider: client.macControlPolicyProvider,
            auditAppendPath: client.macControlAuditPath
        )
        return try await impl.dispatch(action: "spotlight", body: input)
    }

    func postMessage(title: String, body: String) async -> [String: JSONValue] {
        await NativeAgentNotifications.postMessage(title: title, body: body).deliveryFields()
    }

    func macAssistantStatusClient() -> any MacAssistantStatusClient {
        NativeClient.makeAppMacAssistantStatusClient(root: PersistenceCore.defaultDataRoot())
    }

    func statusEvidence(actionID: String) async -> ConnectorActionStatusEvidence? {
        let connectors = (try? await client.getConnectors()) ?? []
        let actions = NativeClient.connectorActionRecords(connectors: connectors)
        return actions.first { $0.id == actionID }.map {
            ConnectorActionStatusEvidence(connectorStatus: $0.connectorStatus, authState: $0.authState, enabled: $0.enabled)
        }
    }

    func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await NativeClient.runGit(arguments, repoRoot: repoRoot, timeout: timeout)
    }
}
