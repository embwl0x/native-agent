import Foundation
import Experiences
import AttentionRouting
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler
// Blueprint: | `SchedulerDueJobRunner+ProactiveScan.swift` | Proactive matters refer to their source experiences |

extension SchedulerDueJobRunner {
    struct ProactiveScanSurfaceResult: Sendable {
        let itemIds: [String]
        let output: JSONValue
    }

    func surfaceProactiveScan(job: DueJob) async throws -> ProactiveScanSurfaceResult {
        let reason = string(job.payload["reason"]) ?? "scheduled_proactive_scan"
        let scan = try await NativeAgentScheduledProactiveScan.evaluate(
            dataRoot: root,
            payload: job.payload
        )
        var itemIds: [String] = []
        for opportunity in scan.surfaced {
            let itemId = "proactive-\(UUID().uuidString.lowercased())"
            let actions = try NativeAgentScheduledProactiveScan.inboxActions(for: opportunity).map { value -> PartFace.Action in
                let row = try JSONRow(value)
                return .init(id: try row.string("id"), label: try row.string("label"))
            }
            try await tellScheduledMatter(Matter(id: itemId,
                form: opportunity.severity == "actionable" ? .ask : .words, from: opportunity.source,
                title: opportunity.title, summary: opportunity.summary, words: opportunity.detail, choices: actions,
                evidence: opportunity.relatedMatters.map { .init(source: "experiences/experiences.sqlite", id: $0) },
                artifacts: opportunity.relatedPaths.map { .init(source: Matter.files, id: $0) }), reach: .person(from: nil))
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
