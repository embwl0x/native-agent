import Foundation
import DreamREMCycle
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

extension SchedulerDueJobRunner {
    func execute(job: DueJob, now: Date) async throws -> JobResult {
        switch job.kind {
        case "notify":
            return try await executeNotify(job: job, now: now)
        case "connector_action":
            return try await executeConnectorAction(job: job)
        case "dream":
            return try await executeDream(job: job)
        case "rem":
            return try await executeREM(job: job)
        case "improve":
            let objective = string(job.payload["objective"]) ?? "Make NativeAgent meaningfully better."
            let run = try await NativeClient(baseURL: "").startImprovement(objective: objective)
            let runStatus = run.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let status = runStatus == "disabled" ? "skipped" : "completed"
            let detail = runStatus == "disabled"
                ? "self-improvement disabled"
                : "improvement run \(run.id) staged"
            return JobResult(
                status: status,
                detail: detail,
                output: .object([
                    "runId": .string(run.id),
                    "phase": .string(run.phase),
                    "status": .string(run.status),
                ])
            )
        case "harness_benchmark":
            let run = try await NativeClient(baseURL: "").runHarnessBenchmark()
            let runStatus = run.status ?? "unknown"
            return JobResult(
                status: runStatus == "passed" ? "completed" : "warn",
                detail: "harness benchmark \(runStatus)",
                output: .object([
                    "runId": .string(run.id),
                    "status": .string(runStatus),
                ])
            )
        case "proactive_scan":
            let scan = try await surfaceProactiveScan(job: job)
            if scan.itemIds.isEmpty {
                return JobResult(
                    status: "skipped",
                    detail: "proactive scan found no new opportunities",
                    output: scan.output
                )
            }
            return JobResult(
                status: "completed",
                detail: "proactive scan surfaced \(scan.itemIds.count) opportunity card(s)",
                output: scan.output
            )
        default:
            throw NSError(domain: "NativeAgentScheduler", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported scheduled job kind: \(job.kind)"
            ])
        }
    }

    private func executeNotify(job: DueJob, now: Date) async throws -> JobResult {
        let overdue = now.timeIntervalSince1970 - job.dueEpoch
        if overdue > 2 * 60 * 60 {
            return JobResult(
                status: "skipped",
                detail: "missed notification delivery window by \(Int(overdue / 60)) minute(s)",
                output: .object(["overdueSeconds": .int(Int64(overdue))])
            )
        }

        let title = NativeAgentNotificationDefaults.title(string(job.payload["title"]), dataRoot: root)
        let message = string(job.payload["message"]) ?? string(job.payload["body"]) ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentScheduler", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "notify job requires a message"
            ])
        }

        let channels = deliveryChannels(job.payload["delivery"])
        var delivered: [String] = []
        var errors: [String] = []
        for channel in channels {
            let channelText = deliveryText(channel: channel, payload: job.payload, fallbackTitle: title, fallbackMessage: message)
            do {
                switch channel {
                case "mac":
                    let result = await NativeAgentNotifications.postAndReport(
                        title: channelText.title,
                        body: channelText.message
                    )
                    if result.posted {
                        delivered.append(channel)
                    } else {
                        errors.append("\(channel): \(result.error ?? result.delivery)")
                    }
                case "push":
                    try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                        title: channelText.title,
                        body: channelText.message,
                        userInfo: ["screen": "inbox", "source": "scheduler", "jobId": job.id]
                    )
                    delivered.append(channel)
                case "telegram":
                    _ = try await makeTelegramBot().sendTestMessage(message: channelText.message, chatId: nil)
                    delivered.append(channel)
                case "inbox", "chat":
                    try await appendNotificationInbox(
                        title: channelText.title,
                        message: channelText.message,
                        source: string(job.payload["source"]) ?? "scheduled_job",
                        severity: channel == "chat" ? "important" : "info",
                        jobId: job.id
                    )
                    delivered.append(channel)
                case "activity":
                    try await appendActivity(
                        jobId: job.id,
                        kind: job.kind,
                        title: channelText.title,
                        detail: channelText.message,
                        status: "ok",
                        payload: .object([
                            "jobId": .string(job.id),
                            "jobName": .string(job.name),
                            "deliveryChannel": .string("activity"),
                        ])
                    )
                    delivered.append(channel)
                default:
                    errors.append("\(channel): unsupported delivery channel")
                }
            } catch {
                errors.append("\(channel): \(error.localizedDescription)")
            }
        }

        if delivered.isEmpty && !errors.isEmpty {
            throw NSError(domain: "NativeAgentScheduler", code: -502, userInfo: [
                NSLocalizedDescriptionKey: errors.joined(separator: "; ")
            ])
        }
        let status = errors.isEmpty ? "completed" : "warn"
        let detail = errors.isEmpty
            ? "delivered via \(delivered.joined(separator: ","))"
            : "delivered via \(delivered.joined(separator: ",")); errors: \(errors.joined(separator: "; "))"
        return JobResult(
            status: status,
            detail: detail,
            output: .object([
                "delivered": .array(delivered.map { .string($0) }),
                "errors": .array(errors.map { .string($0) }),
            ])
        )
    }

    private func executeConnectorAction(job: DueJob) async throws -> JobResult {
        let actionId = string(job.payload["actionId"]) ?? string(job.payload["action_id"]) ?? ""
        guard !actionId.isEmpty else {
            throw NSError(domain: "NativeAgentScheduler", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "connector_action job requires actionId"
            ])
        }
        let input: [String: JSONValue]
        if case .object(let obj)? = job.payload["input"] { input = obj } else { input = [:] }
        let receipt = try await NativeClient(baseURL: "").runConnectorAction(id: actionId, dryRun: false, input: input)
        return JobResult(
            status: receipt.status == "completed" ? "completed" : receipt.status,
            detail: "connector action \(actionId) \(receipt.status)",
            output: .object([
                "actionId": .string(actionId),
                "receiptId": .string(receipt.id),
                "status": .string(receipt.status),
            ])
        )
    }

    private func executeDream(job: DueJob) async throws -> JobResult {
        let response: [String: Any]
        do {
            response = try await NativeClient(baseURL: "").runDream(force: false)
        } catch {
            if let disabledResult = Self.disabledDreamResult(for: error) {
                return disabledResult
            }
            throw error
        }
        let entries = Self.anyInt(response["entriesWritten"])
        let sessions = Self.anyInt(response["sessionsProcessed"])
        let disabled = Self.anyBool(response["disabled"])
        let errors = Self.anyStringArray(response["errors"])
        let failedWithoutEntry = entries <= 0 && !errors.isEmpty
        let retryableFailure = failedWithoutEntry && Self.dreamErrorsAreRetryable(errors)
        let output = Self.jsonValue(from: response)

        if disabled {
            return JobResult(
                status: "skipped",
                detail: "dream cycle disabled",
                output: output
            )
        }

        if entries == 0 && errors.isEmpty {
            return JobResult(
                status: "skipped",
                detail: "dream pass found no new entries",
                output: output
            )
        }

        let dateKey = NativeAgentDreamCycleSchedule.dreamEntryDateKey(Date())
        let entriesForToday = Self.dreamEntriesForToday(dataRoot: root, dateKey: dateKey)
        let paths = entriesForToday.map { $0.path }
        let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
        let title = failedWithoutEntry ? "\(agentName) dream needs retry" : "\(agentName) dreamed"
        let message = Self.dreamInboxMessage(
            entriesWritten: entries,
            sessionsProcessed: sessions,
            errors: errors,
            entries: entriesForToday
        )
        let itemId = "dream-cycle-\(dateKey)-\(UUID().uuidString.lowercased())"
        try await appendNotificationInbox(
            title: title,
            message: message,
            source: "dream_cycle",
            severity: entries > 0 || failedWithoutEntry ? "important" : "info",
            jobId: job.id,
            itemId: itemId,
            relatedPaths: paths
        )
        let archivedDreamCards = try await archiveOlderDreamInboxItems(keeping: itemId)
        let delivery = entries > 0
            ? await postCycleNotification(title: title, body: Self.notificationBody(message), jobId: job.id, source: "dream_cycle", itemId: itemId)
            : .object(["delivered": .array([]), "errors": .array([])])
        let detail = entries > 0
            ? "dream pass wrote \(entries) entr\(entries == 1 ? "y" : "ies") and surfaced inbox item"
            : "dream pass ran with no new entries; surfaced inbox receipt"
        var outputObj = Self.object(output)
        outputObj["inboxItemId"] = .string(itemId)
        outputObj["archivedOlderDreamInboxItems"] = .int(Int64(archivedDreamCards))
        outputObj["delivery"] = delivery
        if failedWithoutEntry {
            outputObj["failureKind"] = .string("dream_failed_before_write")
            outputObj["retryable"] = .bool(retryableFailure)
            if retryableFailure {
                outputObj["retryAfterSeconds"] = .int(15 * 60)
            }
        }
        return JobResult(
            status: failedWithoutEntry ? "error" : (errors.isEmpty ? "completed" : "warn"),
            detail: failedWithoutEntry
                ? (retryableFailure
                    ? "dream pass failed before writing; retry scheduled in 15 minutes"
                    : "dream pass failed before writing; attention needed")
                : detail,
            output: .object(outputObj)
        )
    }

    static func disabledDreamResult(for error: Error) -> JobResult? {
        guard case DreamREMCycleError.cycleDisabled(let code, let detail) = error else {
            return nil
        }
        return JobResult(
            status: "skipped",
            detail: "dream cycle disabled",
            output: .object([
                "disabled": .bool(true),
                "error": .string(code),
                "detail": .string(detail),
            ])
        )
    }

    private func executeREM(job: DueJob) async throws -> JobResult {
        let response = try await NativeClient(baseURL: "").runRem()
        let proposals = Self.anyInt(response["proposalsGenerated"])
        let archived = Self.anyInt(response["archivedEntries"])
        let tombstones = Self.anyInt(response["tombstoneSkips"])
        let evicted = Self.anyBool(response["growthMDEvicted"])
        let output = Self.jsonValue(from: response)

        if proposals <= 0 {
            var outputObj = Self.object(output)
            outputObj["delivery"] = .object([
                "delivered": .array([]),
                "errors": .array([]),
                "skippedReason": .string("no_rem_proposals_quiet"),
            ])
            return JobResult(
                status: "completed",
                detail: "REM pass generated 0 proposals; quiet activity receipt only",
                output: .object(outputObj)
            )
        }

        let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
        let title = "\(agentName) REM cycle"
        let message = Self.remInboxMessage(
            proposalsGenerated: proposals,
            archivedEntries: archived,
            tombstoneSkips: tombstones,
            growthMDEvicted: evicted
        )
        let itemId = "rem-cycle-\(NativeAgentDreamCycleSchedule.runDateKey(Date()))-\(UUID().uuidString.lowercased())"
        let paths = Self.remRelatedPaths(dataRoot: root)
        try await appendNotificationInbox(
            title: title,
            message: message,
            source: "rem_cycle",
            severity: "actionable",
            jobId: job.id,
            itemId: itemId,
            relatedPaths: paths
        )
        let delivery = await postCycleNotification(title: title, body: Self.notificationBody(message), jobId: job.id, source: "rem_cycle", itemId: itemId)
        var outputObj = Self.object(output)
        outputObj["inboxItemId"] = .string(itemId)
        outputObj["delivery"] = delivery
        return JobResult(
            status: "completed",
            detail: "REM pass generated \(proposals) proposal\(proposals == 1 ? "" : "s") and surfaced inbox item",
            output: .object(outputObj)
        )
    }

}
