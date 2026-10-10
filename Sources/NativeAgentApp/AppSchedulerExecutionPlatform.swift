import Foundation
import AppToolRuntime
import AttentionRouting
import NativeAgentCore
import PersistenceCore
import Connectors
import SchedulerExecution
import TelegramBot
import SelfImprovement

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
        let receipt = try await ConnectorActions(
            platform: AppConnectorActionPlatform(dataRoot: PersistenceCore.defaultDataRoot())
        ).runConnectorAction(
            id: id, dryRun: dryRun, input: input,
            externalSendIdempotencyKey: externalSendIdempotencyKey
        )
        return (receipt.id, receipt.status)
    }

    func runDream(force: Bool) async throws -> sending [String: Any] {
        try await BackgroundLoopsAssembly.runDream(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runRem(force: Bool) async throws -> sending [String: Any] {
        try await BackgroundLoopsAssembly.runRem(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runHarnessBenchmark() async throws -> (id: String, status: String?) {
        let run = await HarnessBenchmarkRun.run(dataRoot: PersistenceCore.defaultDataRoot())
        return (run.id, run.status)
    }

    func createWorkshopTask(
        title: String, objective: String, projectSpaceId: String?
    ) async throws -> (id: String, status: String) {
        let execution = try await BackgroundLoopsAssembly.submitDeskTask(
            title: title, objective: objective, projectSpaceId: projectSpaceId
        ).execution
        return (execution.id, execution.status)
    }
}
