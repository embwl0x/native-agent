import AppIntents
import Foundation
import NativeAgentCore
import ChatOrchestration

private func intentClient() -> NativeClient {
    let base = NativeBaseURLDefaults.read()
    return NativeClient(baseURL: base)
}

/// App Intents have no mounted chat tab to supply an active session identity.
/// Keep one explicit, durable Intent-owned conversation instead of letting the
/// persistent chat boundary mint an unobservable UUID for every shortcut run.
/// The ID still enters Core through `resolveSessionId`, so normalization and
/// path safety remain identical to every other transcript writer.
enum NativeAgentIntentSession {
    static let defaultsKey = "nativeagent.intent.chat.sessionID"

    static func resolve(
        defaults: UserDefaults = .standard,
        newSessionID: () -> String = { "intent:\(UUID().uuidString)" }
    ) throws -> String {
        if let persisted = defaults.string(forKey: defaultsKey) {
            if let normalized = NativeAgentChatSessionID.normalizedPathComponent(persisted) {
                let resolved = try SwiftNativeChatOrchestrationClient.resolveSessionId(normalized)
                if persisted != resolved { defaults.set(resolved, forKey: defaultsKey) }
                return resolved
            }
            // This local presentation preference has no authority over a
            // transcript. A damaged value cannot select a path, so clear it
            // before creating a visible, retained replacement identity.
            defaults.removeObject(forKey: defaultsKey)
        }

        let resolved = try SwiftNativeChatOrchestrationClient.resolveSessionId(newSessionID())
        defaults.set(resolved, forKey: defaultsKey)
        return resolved
    }
}

struct NativeAgentStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get NativeAgent Status"
    static let description = IntentDescription("Checks the local NativeAgent runtime and returns the current health state.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let health = try await intentClient().getHealth()
        let state = health.ok ? "online" : "unavailable"
        return .result(dialog: "NativeAgent is \(state). Version \(health.version).")
    }
}

struct NativeAgentChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask NativeAgent"
    static let description = IntentDescription("Sends a message to NativeAgent's retained Shortcuts conversation.")
    static let openAppWhenRun = false

    @Parameter(title: "Message")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask NativeAgent \(\.$message)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? nativeAgentPrimaryModel
        let reasoningEffort = UserDefaults.standard.string(forKey: "chatReasoningEffort") ?? "high"
        let fileAccess = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
        let sessionID = try NativeAgentIntentSession.resolve()
        let reply = try await intentClient().chat(
            message: message,
            sessionId: sessionID,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess
        )
        return .result(dialog: "\(String(reply.output.prefix(260)))")
    }
}

struct NativeAgentDoctorIntent: AppIntent {
    static let title: LocalizedStringResource = "Run NativeAgent Doctor"
    static let description = IntentDescription("Runs the local Doctor check without unsafe repairs.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let report = try await intentClient().runDoctor(repair: false)
        return .result(dialog: "Doctor finished with status \(report.status). \(report.checks.count) checks ran.")
    }
}

struct NativeAgentWorkshopTaskIntent: AppIntent {
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

struct NativeAgentWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch NativeAgent Workflow"
    static let description = IntentDescription("Launches a registered NativeAgent workflow through the approval-aware native action surface.")
    static let openAppWhenRun = true

    @Parameter(title: "Workflow ID")
    var workflowId: String

    @Parameter(title: "Objective")
    var objective: String

    static var parameterSummary: some ParameterSummary {
        Summary("Launch workflow \(\.$workflowId)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let receipt = try await intentClient().runNativeAction(
            id: "workflow.launch",
            dryRun: false,
            input: ["workflowId": workflowId, "objective": objective]
        )
        return .result(dialog: "Workflow action recorded as \(receipt.status).")
    }
}

struct NativeAgentApprovalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Review NativeAgent Approvals"
    static let description = IntentDescription("Shows the current NativeAgent approval count.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let approvals = try await intentClient().getApprovals()
        let pending = approvals.filter { $0.status == "pending" }.count
        return .result(dialog: "\(pending) NativeAgent approval\(pending == 1 ? "" : "s") pending.")
    }
}

struct NativeAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
