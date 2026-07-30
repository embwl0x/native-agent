import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

extension SchedulerDueJobRunner {
    struct ProactiveScanSurfaceResult: Sendable {
        let itemIds: [String]
        let output: JSONValue
    }

    func surfaceProactiveScan(job: DueJob) async throws -> ProactiveScanSurfaceResult {
        let reason = string(job.payload["reason"]) ?? "scheduled_proactive_scan"
        let scan = await NativeAgentScheduledProactiveScan.evaluate(
            dataRoot: root,
            payload: job.payload,
            persistence: persistence
        )
        var itemIds: [String] = []
        for opportunity in scan.surfaced {
            let itemId = "proactive-\(UUID().uuidString.lowercased())"
            try await appendNotificationInbox(
                title: opportunity.title,
                message: opportunity.summary,
                source: opportunity.source,
                severity: opportunity.severity,
                jobId: job.id,
                itemId: itemId,
                relatedPaths: opportunity.relatedPaths,
                detail: opportunity.detail,
                actions: NativeAgentScheduledProactiveScan.inboxActions(for: opportunity),
                notifyPhone: true
            )
            itemIds.append(itemId)
        }
        return ProactiveScanSurfaceResult(
            itemIds: itemIds,
            output: .object([
                "reason": .string(reason),
                "scannedCount": .int(Int64(scan.scannedCount)),
                "eligibleCount": .int(Int64(scan.eligibleCount)),
                "skippedAlreadySurfacedCount": .int(Int64(scan.skippedAlreadySurfacedCount)),
                "surfaceCount": .int(Int64(itemIds.count)),
                "inboxItemIds": .array(itemIds.map { .string($0) }),
                "opportunityIds": .array(scan.surfaced.map { .string($0.id) }),
            ])
        )
    }

}
