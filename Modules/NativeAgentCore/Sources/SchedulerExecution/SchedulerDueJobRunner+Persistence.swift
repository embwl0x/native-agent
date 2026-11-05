import Privacy
import Foundation
import Experiences
import AttentionRouting
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler
import DeviceSync
import AppToolRuntime
// Blueprint: | `SchedulerDueJobRunner+Persistence.swift` | Activity evidence, one scheduled tell, and in-memory dream receipt readings |

extension SchedulerDueJobRunner {
    func update(job: DueJob, result: JobResult, at runDate: Date) async throws {
        if job.kind == "dream" {
            let output = Self.object(result.output)
            if (result.status == "error" || output["skipReason"] == .string("already_running")), output["remedy"] == nil {
                await RepairOwed.owe(root, id: "scheduled-dream-repair:" + UUID().uuidString, kind: .run,
                    evidence: [.init(source: "scheduler/jobs.json", id: job.occurrenceKey)],
                    operation: "dream", owner: "scheduler/jobs.json > " + job.id,
                    words: "Scheduled dream remains owed: " + result.detail,
                    nextCall: ToolFailureError.call("app", ["action": .string("mind.dream")])).value
            }
        }
        try await schedulerJobs.settleOccurrence(
            jobId: job.id, occurrenceKey: job.occurrenceKey, status: result.status,
            detail: result.detail, seen: result.seen, at: runDate
        )
    }

    func appendActivity(
        jobId: String?,
        title: String,
        detail: String,
        status: String,
        payload: JSONValue
    ) async throws {
        var payloadObj: [String: JSONValue] = [:]
        if case .object(let obj) = payload { payloadObj = obj }
        if let jobId { payloadObj["jobId"] = .string(jobId) }
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: "scheduler",
            title: NativeAppSecretRedactor.redactText(title),
            detail: NativeAppSecretRedactor.redactText(String(detail.prefix(1000))),
            status: status,
            executionId: nil,
            payload: NativeAppSecretRedactor.redactValue(.object(payloadObj)),
            createdAt: Self.iso(Date())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(
                event, to: activityPath, logLabel: "SchedulerDueJobRunner"
            )
        } catch {
            noteFault("Scheduler activity evidence could not be written: \(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    func tellScheduledMatter(_ matter: Matter, reach: AttentionRouter.Reach) async throws -> JSONValue {
        let face = Matter(id: matter.id, form: matter.form, from: matter.from,
            title: NativeAppSecretRedactor.redactText(String(matter.title.prefix(160))),
            summary: NativeAppSecretRedactor.redactText(String(matter.summary.prefix(500))),
            words: NativeAppSecretRedactor.redactText(String(matter.words.prefix(2000))), symbol: matter.symbol,
            badge: matter.badge, open: matter.open, choices: matter.choices, evidence: matter.evidence, artifacts: matter.artifacts)
        let outcome = try await platform.attentionRouter.tell(face, reach: reach, turn: nil)
        var delivered: [JSONValue] = [], errors: [JSONValue] = [], pending: [JSONValue] = []
        for (door, verdict) in outcome.destinationOutcomes.sorted(by: { $0.key < $1.key }) {
            switch verdict {
            case .delivered: delivered.append(.string(door))
            case .notDelivered(let reason):
                if outcome.deferredForQuietHours { pending.append(.string(door + ": deferred")) }
                else { errors.append(.string(door + ": " + reason)) }
            case .unknown(_, let reason): pending.append(.string(door + ": " + reason))
            case .suppressed(let preference): pending.append(.string(door + ": suppressed by " + preference))
            }
        }
        return .object(["delivered": .array(delivered), "errors": .array(errors),
                        "not_delivered": .array(pending), "destinations": .object(outcome.destinationFields)])
    }

    @discardableResult
    func archiveOlderDreamInboxItems(keeping keepItemId: String) async throws -> Int {
        let forPerson = ForPerson.at(root)
        var count = 0
        for old in try await forPerson.matters() where old.face?.from == "dream_cycle" && old.id != keepItemId
            && (ForPerson.reading(old) == .unread || ForPerson.reading(old) == .read) {
            try await forPerson.putAway(old.id, .resolved)
            count += 1
        }
        return count
    }

    func dreamMatterExists(dateKey: String) async throws -> Bool {
        try await ForPerson.at(root).matters().contains {
            $0.face?.from == "dream_cycle" && Self.matterDiaryDateKeys($0).contains(dateKey)
        }
    }

    static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'+00:00'"
        return formatter.string(from: date)
    }

    func string(_ raw: JSONValue?) -> String? {
        SchedulerJobRuntime.string(raw)
    }

    func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        SchedulerJobRuntime.int(raw, default: defaultValue)
    }
}
