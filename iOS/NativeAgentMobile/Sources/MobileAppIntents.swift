import AppIntents
import Foundation

struct MobileAgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = MobileAgentQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct MobileAgentQuery: EntityStringQuery {
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func entities(for identifiers: [String]) async throws -> [MobileAgentEntity] {
        let agent = try await MobileIntentRuntime.agent()
        return identifiers.contains(agent.id) ? [agent] : []
    }
    func entities(matching string: String) async throws -> [MobileAgentEntity] {
        let agent = try await MobileIntentRuntime.agent()
        return agent.name.localizedCaseInsensitiveContains(string) ? [agent] : []
    }
    func suggestedEntities() async throws -> [MobileAgentEntity] { [try await MobileIntentRuntime.agent()] }
    func defaultResult() async throws -> MobileAgentEntity? { try await MobileIntentRuntime.agent() }
}

struct MobileAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Your Agent"
    static let description = IntentDescription("Send a message to your agent on your computer and return the reply.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Agent") var agent: MobileAgentEntity
    @Parameter(title: "Message") var message: String
    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$agent) \(\.$message)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await MobileIntentRuntime.validate(agent)
        let reply: String
        if #available(iOS 27, *) {
            reply = try await performBackgroundTask {
                try await MobileIntentRuntime.reply(to: message, timeout: 300)
            }
        } else { reply = try await MobileIntentRuntime.reply(to: message, timeout: 25) }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

struct MobileRememberIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember with Your Agent"
    static let description = IntentDescription("Send your agent a memory note and return her reply.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Agent") var agent: MobileAgentEntity
    @Parameter(title: "Note") var note: String
    static var parameterSummary: some ParameterSummary { Summary("Tell \(\.$agent) to remember \(\.$note)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await MobileIntentRuntime.validate(agent)
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $note.needsValueError("Enter a memory note.")
        }
        let text = "Please remember this: \(note)"
        let reply: String
        if #available(iOS 27, *) {
            reply = try await performBackgroundTask {
                try await MobileIntentRuntime.reply(to: text, timeout: 300)
            }
        } else { reply = try await MobileIntentRuntime.reply(to: text, timeout: 25) }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

@available(iOS 27, *)
extension MobileAskIntent: LongRunningIntent {}
@available(iOS 27, *)
extension MobileRememberIntent: LongRunningIntent {}

struct MobileApprovalEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pending Approval"
    static let defaultQuery = MobileApprovalQuery()
    let id: String
    let title: String
    let detail: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }
}

struct MobileApprovalQuery: EntityQuery {
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func suggestedEntities() async throws -> [MobileApprovalEntity] {
        try await MobileIntentRuntime.pendingApprovals().filter {
            ActivityScreenPresentation.canDecideRemotely(action: $0.action)
        }.map {
            MobileApprovalEntity(id: $0.id, title: $0.title,
                detail: $0.reason ?? $0.action)
        }
    }
    func entities(for identifiers: [String]) async throws -> [MobileApprovalEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

struct MobileApproveIntent: AppIntent {
    static let title: LocalizedStringResource = "Approve a Pending Request"
    static let description = IntentDescription("Choose a pending request from your computer and approve it after confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Agent") var agent: MobileAgentEntity
    @Parameter(title: "Approval") var approval: MobileApprovalEntity
    static var parameterSummary: some ParameterSummary { Summary("Approve \(\.$approval) for \(\.$agent)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MobileIntentRuntime.validate(agent)
        guard let current = try await MobileApprovalQuery().entities(for: [approval.id]).first else {
            throw MobileIntentRuntime.failure("This request is no longer pending.")
        }
        try await requestConfirmation(dialog: "Approve \(current.title)? \(current.detail)")
        try await MobileIntentRuntime.decide(id: current.id, approve: true)
        return .result(dialog: "Approved \(current.title).")
    }
}

struct MobileStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Your Agent's Status"
    static let description = IntentDescription("Read your agent's one-line status from the last synced snapshot.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Agent") var agent: MobileAgentEntity
    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$agent)'s status") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await MobileIntentRuntime.validate(agent)
        await iCloudSyncEngine.shared.refreshLightweightSnapshots()
        guard let status = iCloudSyncEngine.shared.organismLivingStatus, status.availabilityState == .live else {
            throw MobileIntentRuntime.failure("Your agent's status is unavailable in the synced snapshot.")
        }
        let line = status.behaviorLine.components(separatedBy: .newlines).joined(separator: " ")
        let reply = "\(agent.name), as of \(status.generatedAt.formatted(date: .abbreviated, time: .shortened)): \(line)"
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

struct NativeAgentMobileShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MobileAskIntent(), phrases: ["Ask \(\.$agent) in \(.applicationName)", "Ask my agent in \(.applicationName)"], shortTitle: "Ask Your Agent", systemImageName: "person.bubble")
        AppShortcut(intent: MobileRememberIntent(), phrases: ["Tell \(\.$agent) to remember in \(.applicationName)", "Remember in \(.applicationName)"], shortTitle: "Remember", systemImageName: "brain")
        AppShortcut(intent: MobileApproveIntent(), phrases: ["Approve a request for \(\.$agent) in \(.applicationName)", "Approve in \(.applicationName)"], shortTitle: "Approve", systemImageName: "checkmark.shield")
        AppShortcut(intent: MobileStatusIntent(), phrases: ["Check on \(\.$agent) in \(.applicationName)", "Status in \(.applicationName)"], shortTitle: "Status", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: MobileQuickAskIntent(), phrases: ["Quick Ask in \(.applicationName)"], shortTitle: "Quick Ask", systemImageName: "bubble.left")
    }
}
