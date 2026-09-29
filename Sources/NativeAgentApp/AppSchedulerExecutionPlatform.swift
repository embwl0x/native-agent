import Foundation
import AppToolRuntime
import AttentionRouting
import NativeAgentCore
import PersistenceCore
import SchedulerExecution
import TelegramBot

extension SchedulerDueJobRunner {
    static let shared = SchedulerDueJobRunner()

    init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.init(root: root, platform: AppSchedulerExecutionPlatform())
    }
}

struct AppSchedulerExecutionPlatform: SchedulerExecutionPlatform {
    var attentionRouter: AttentionRouter { .shared }

    func postNotification(title: String, body: String) async -> NativeAgentNotificationPostResult {
        await NativeAgentNotifications.postAndReport(title: title, body: body)
    }

    func sendTelegramMessage(message: String) async throws {
        _ = try await makeTelegramBot().sendTestMessage(message: message, chatId: nil)
    }

    func notifyInboxIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async {
        await InboxPushNotifier.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity
        )
    }

    func runConnectorAction(
        id: String, dryRun: Bool, input: [String: JSONValue],
        externalSendIdempotencyKey: String
    ) async throws -> (id: String, status: String) {
        let receipt = try await NativeClient(baseURL: "").runConnectorAction(
            id: id, dryRun: dryRun, input: input,
            externalSendIdempotencyKey: externalSendIdempotencyKey
        )
        return (receipt.id, receipt.status)
    }

    func runDream(force: Bool) async throws -> sending [String: Any] {
        try await NativeClient(baseURL: "").runDream(force: force)
    }

    func runRem(force: Bool) async throws -> sending [String: Any] {
        try await NativeClient(baseURL: "").runRem(force: force)
    }

    func startImprovement(objective: String) async throws -> (id: String, status: String?, phase: String?) {
        let run = try await NativeClient(baseURL: "").startImprovement(objective: objective)
        return (run.id, run.status, run.phase)
    }

    func runHarnessBenchmark() async throws -> (id: String, status: String?) {
        let run = try await NativeClient(baseURL: "").runHarnessBenchmark()
        return (run.id, run.status)
    }

    func createWorkshopTask(
        title: String, objective: String, projectSpaceId: String?
    ) async throws -> (id: String, status: String) {
        let execution = try await NativeClient(baseURL: "").createWorkshopTask(
            title: title, objective: objective, projectSpaceId: projectSpaceId
        )
        return (execution.id, execution.status)
    }
}
