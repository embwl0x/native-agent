import AppIntents
import Foundation
import NativeAgentCore
import ChatOrchestration
import MacControl
import PersonaEngine
import Transcripts

/// One resident agent, named by this installation's canonical persona.
struct ResidentAgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = ResidentAgentQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var current: ResidentAgentEntity {
        ResidentAgentEntity(id: "resident", name: PersonaCompiler.agentDisplayName())
    }
}

struct ResidentAgentQuery: EntityStringQuery {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func entities(for identifiers: [String]) async throws -> [ResidentAgentEntity] {
        let agent = ResidentAgentEntity.current
        return identifiers.contains(agent.id) ? [agent] : []
    }

    func entities(matching string: String) async throws -> [ResidentAgentEntity] {
        let agent = ResidentAgentEntity.current
        return agent.name.localizedCaseInsensitiveContains(string) ? [agent] : []
    }

    func suggestedEntities() async throws -> [ResidentAgentEntity] {
        [.current]
    }

    func defaultResult() async -> ResidentAgentEntity? { .current }
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
        guard agent.id == ResidentAgentEntity.current.id else {
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

private func intentClient() -> NativeClient {
    NativeClient()
}

struct NativeAgentStatusIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Get NativeAgent Status"
    static let description = IntentDescription("Checks the local NativeAgent runtime and returns the current health state.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
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
        // No pick means no pick: an empty model resolves through the chat
        // surface's Providers group rather than a literal chosen here.
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? ""
        let reasoningEffort = UserDefaults.standard.string(forKey: "chatReasoningEffort") ?? "high"
        let fileAccess = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
        // Siri continues the conversation User is in, at whichever door he last
        // spoke; with none yet, this ask starts one. Either way it is now the
        // conversation he is in.
        let sessionID = try SwiftNativeChatOrchestrationClient.resolveSessionId(
            ConversationAnchor.currentSessionId() ?? UUID().uuidString
        )
        _ = try? await ConversationAnchor.publish(
            sessionId: sessionID, source: "siri", conversationKind: .direct
        )
        // Where User was when he said "take over", before the session queue.
        let takeover = await MacWorkContinuation.admit(message)
        let reply = try await MacWorkContinuation.$current.withValue(takeover) {
            try await TurnAdmission.shared.run(sessionID: sessionID) {
                try await intentClient().chat(
                    message: message,
                    sessionId: sessionID,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    fileAccess: fileAccess
                )
            }
        }
        return reply.output
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
        let report = try await intentClient().runDoctor()
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
        let task = try await intentClient().createWorkshopTask(title: title, objective: objective)
        return .result(dialog: "Desk task created: \(task.title).")
    }
}

// 2026-09-01: `NativeAgentWorkflowIntent` ("Launch NativeAgent Workflow") was
// retired with the workflow run engine (User authorized). It was never in
// `appShortcuts`, and the native action it invoked no longer exists.

struct NativeAgentApprovalsIntent: AppIntent {
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    static let title: LocalizedStringResource = "Review NativeAgent Approvals"
    static let description = IntentDescription("Shows the current NativeAgent approval count.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let approvals = try await NativeAgentEngine.live.approvals.list()
        let pending = approvals.filter { $0.status == "pending" }.count
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
