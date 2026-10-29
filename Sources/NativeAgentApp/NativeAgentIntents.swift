import EngineRuntime
import AppIntents
import Foundation
import PersistenceCore
import NativeAgentCore
import NativeAgentShared
import Transcripts
// Blueprint: | `NativeAgentIntents.swift` | `NativeAgentChatIntent`: `perform`, `reply` |

/// One resident agent, named by this installation's canonical persona.
struct ResidentAgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = ResidentAgentQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    @MainActor
    static func current() async throws -> ResidentAgentEntity {
        let profile = try await NativeAgentEngine.live.persona.loadProfile()
        return ResidentAgentEntity(id: "resident", name: NativeAgentIdentity.displayName(profile.name))
    }
}

struct ResidentAgentQuery: EntityStringQuery {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func entities(for identifiers: [String]) async throws -> [ResidentAgentEntity] {
        try await ApplicationLifetime.shared.prepare()
        let agent = try await ResidentAgentEntity.current()
        return identifiers.contains(agent.id) ? [agent] : []
    }

    func entities(matching string: String) async throws -> [ResidentAgentEntity] {
        try await ApplicationLifetime.shared.prepare()
        let agent = try await ResidentAgentEntity.current()
        return agent.name.localizedCaseInsensitiveContains(string) ? [agent] : []
    }

    func suggestedEntities() async throws -> [ResidentAgentEntity] {
        try await ApplicationLifetime.shared.prepare()
        return [try await ResidentAgentEntity.current()]
    }

    func defaultResult() async -> ResidentAgentEntity? {
        do { try await ApplicationLifetime.shared.prepare(); return try await ResidentAgentEntity.current() }
        catch { return nil }
    }
}

/// The original Ask action stays source- and shortcut-compatible. This action
/// adds a finite entity vocabulary; free-form messages are elicited by Siri,
/// never interpolated as a second phrase parameter.
struct AskResidentAgentIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Ask Your Agent"
    static let description = IntentDescription("Ask the resident agent by name in the conversation you're in.")
    static let openAppWhenRun = false

    @Parameter(title: "Agent")
    var agent: ResidentAgentEntity

    @Parameter(title: "Message")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$agent) \(\.$message)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await ApplicationLifetime.shared.prepare()
        guard agent.id == (try await ResidentAgentEntity.current()).id else {
            throw $agent.needsValueError("Choose the resident agent.")
        }
        let reply: String
        if #available(macOS 27, *) {
            reply = try await performBackgroundTask {
                try await NativeAgentChatIntent.reply(to: message)
            }
        } else {
            reply = try await NativeAgentChatIntent.reply(to: message)
        }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

struct NativeAgentStatusIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Get NativeAgent Status"
    static let description = IntentDescription("Checks the local NativeAgent runtime and returns the current health state.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ApplicationLifetime.shared.prepare()
        let health = NativeAgentEngine.live.doctor.readHealth()
        let state = health.ok ? "online" : "unavailable"
        if #available(macOS 27, *), systemContext.isVoiceOnly {
            return .result(dialog: "NativeAgent is \(state).")
        }
        return .result(dialog: "NativeAgent is \(state). Version \(health.version).")
    }
}

struct NativeAgentChatIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Ask NativeAgent"
    static let description = IntentDescription("Sends a message to NativeAgent in the conversation you're in.")
    static let openAppWhenRun = false

    @Parameter(title: "Message")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask NativeAgent \(\.$message)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply: String
        if #available(macOS 27, *) {
            reply = try await performBackgroundTask {
                try await Self.reply(to: message)
            }
        } else {
            reply = try await Self.reply(to: message)
        }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }

    static func reply(to message: String) async throws -> String {
        try await ApplicationLifetime.shared.prepare()
        return try await NativeAgentEngine.live.replyToIntent(message)
    }
}

@available(macOS 27, *)
extension NativeAgentChatIntent: LongRunningIntent {}

@available(macOS 27, *)
extension AskResidentAgentIntent: LongRunningIntent {}

struct NativeAgentDoctorIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Run NativeAgent Doctor"
    static let description = IntentDescription("Runs the local Doctor check without unsafe repairs.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ApplicationLifetime.shared.prepare()
        let report = try await AppDoctorPort(dataRoot: PersistenceCore.defaultDataRoot()).runtime.runDoctor()
        return .result(dialog: "Doctor finished with status \(report.status). \(report.checks.count) checks ran.")
    }
}

struct NativeAgentWorkshopTaskIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Create NativeAgent Desk Task"
    static let description = IntentDescription("Creates a directed task on the configured agent's Desk.")
    static let openAppWhenRun = false

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Objective")
    var objective: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create Desk task \(\.$title) for \(\.$objective)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ApplicationLifetime.shared.prepare()
        let task = try await NativeAgentEngine.submitDeskTask(title: title, objective: objective).execution
        return .result(dialog: "Desk task created: \(task.title).")
    }
}

struct NativeAgentApprovalsIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Review NativeAgent Approvals"
    static let description = IntentDescription("Shows the current NativeAgent approval count.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ApplicationLifetime.shared.prepare()
        let approvals = try await NativeAgentEngine.live.approvals.list()
        let pending = WorkOverviewRead.waitingApprovals(approvals).count
        return .result(dialog: "\(pending) NativeAgent approval\(pending == 1 ? "" : "s") pending.")
    }
}

struct NativeAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskResidentAgentIntent(),
            phrases: [
                "Ask \(\.$agent) in \(.applicationName)",
                "Tell \(.applicationName)'s \(\.$agent)",
                "Ask my agent in \(.applicationName)",
            ],
            shortTitle: "Ask Your Agent",
            systemImageName: "person.bubble"
        )
        AppShortcut(
            intent: NativeAgentStatusIntent(),
            phrases: ["Check \(.applicationName) status", "Ask \(.applicationName) status"],
            shortTitle: "Status",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: NativeAgentChatIntent(),
            phrases: ["Ask \(.applicationName)", "Send \(.applicationName) a message"],
            shortTitle: "Ask",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: NativeAgentDoctorIntent(),
            phrases: ["Run \(.applicationName) Doctor"],
            shortTitle: "Doctor",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: NativeAgentApprovalsIntent(),
            phrases: ["Review \(.applicationName) approvals"],
            shortTitle: "Approvals",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: QueryMemoryIntent(),
            phrases: [
                "Query \(.applicationName) memory",
                "Ask \(.applicationName) about memory",
            ],
            shortTitle: "Query Memory",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: StoreMemoryIntent(),
            phrases: [
                "Save a memory in \(.applicationName)",
                "Tell \(.applicationName) to remember something",
            ],
            shortTitle: "Remember",
            systemImageName: "pencil.and.list.clipboard"
        )
        AppShortcut(
            intent: ListPendingMemoryProposalsIntent(),
            phrases: [
                "List pending memory proposals in \(.applicationName)",
                "Review \(.applicationName) memory proposals",
            ],
            shortTitle: "Pending Proposals",
            systemImageName: "tray.full"
        )
    }
}
