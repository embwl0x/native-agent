import AuthoredCapabilities
import Foundation
import AttentionRouting
import DreamREMCycle
import NativeAgentCore
import Senses
import PersistenceCore
import TelegramBot
import TriggerScheduler
import DeviceSync
// Blueprint: | `SchedulerDueJobRunner+Execution.swift` | `SchedulerDueJobRunner`: `execute` (a `part` job fires its part's `schedule:` signal), `watch` (a `connector_action` read posts the rows new since its last read as one news per job), `channelIsSwitchedOn`, `disabledDreamResult` |

extension SchedulerDueJobRunner {
    func execute(job: DueJob) async throws -> JobResult {
        try Task.checkCancellation()
        guard let kind = JobKind(rawValue: job.kind) else {
            throw NSError(domain: "NativeAgentScheduler", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "schedule_kind_unsupported: Scheduled Desk task kind '\(job.kind)' is unsupported. Set a supported kind and its complete payload through schedule.update."
            ])
        }
        guard isLiveDataRoot else {
            throw NSError(domain: "NativeAgentScheduler", code: -403, userInfo: [
                NSLocalizedDescriptionKey:
                    "schedule_root_not_live: Scheduled effects are refused for \(root.path). Use schedule.create in NativeAgent's running app to schedule this Desk task in its active data folder."
            ])
        }
        switch kind {
        case .notify:
            return try await executeNotify(job: job)
        case .connectorAction:
            return try await executeConnectorAction(job: job)
        case .dream:
            return try await executeDream(job: job)
        case .rem:
            return try await executeREM(job: job)
        case .harnessBenchmark:
            let run = try await platform.runHarnessBenchmark()
            let runStatus = run.status ?? "unknown"
            return JobResult(
                status: runStatus == "passed" ? "completed" : "warn",
                detail: "harness benchmark \(runStatus)",
                output: .object([
                    "runId": .string(run.id),
                    "status": .string(runStatus),
                ])
            )
        case .proactiveScan:
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
        case .part:
            // The deadline only fires the signal; the run is the stem's, on its own gate chain.
            // Fires that land while the part's run still waits are one news. Posting is all
            // this job knows: the run's outcome is the ability's own record, never claimed here.
            let part = string(job.payload["part"]) ?? "", signal = string(job.payload["signal"]) ?? ""
            AbilityStore(dataRoot: root).signal(signal, part: part)
            return JobResult(status: "completed", detail: "\(signal) posted for \(part); its run is recorded on the ability: app ability.read {id:\"\(part)\"}",
                             output: .object(["part": .string(part), "delivery": .string("posted")]))
        case .turn:
            return try await executeTurn(job: job)
        case .workshop:
            let title = string(job.payload["title"]) ?? job.name
            let objective = string(job.payload["objective"]) ?? ""
            guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "NativeAgentScheduler", code: -400, userInfo: [
                    NSLocalizedDescriptionKey: "schedule_objective_missing: Scheduled Desk task has no objective. Set payload.objective through schedule.update."
                ])
            }
            let execution = try await platform.createWorkshopTask(
                title: title,
                objective: objective,
                projectSpaceId: string(job.payload["projectSpaceId"])
            )
            return JobResult(
                status: "completed",
                detail: "Desk execution \(execution.id) queued",
                output: .object([
                    "executionId": .string(execution.id),
                    "status": .string(execution.status),
                    "expectedEvidence": job.payload["expectedEvidence"] ?? .string("canonical Desk completion receipt"),
                ])
            )
        }
    }

    /// A scheduled turn: the job's prompt runs as one turn of hers; the reply is
    /// the job's record and an inbox card under the job's name.
    private func executeTurn(job: DueJob) async throws -> JobResult {
        let prompt = (string(job.payload["prompt"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NSError(domain: "NativeAgentScheduler", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "schedule_prompt_missing: Scheduled turn has no prompt. Set payload.prompt through schedule.update."
            ])
        }
        let title = string(job.payload["title"]) ?? job.name
        let turn = try await platform.runScheduledTurn(name: title, prompt: prompt)
        let reply = String(turn.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        try await appendNotificationInbox(
            title: title,
            message: reply.isEmpty ? "The turn ended without a reply." : reply,
            source: "scheduled_turn",
            severity: "info",
            jobId: job.id,
            itemId: Self.notificationItemId(job: job, channel: "inbox")
        )
        return JobResult(
            status: "completed",
            detail: "turn ran on \(turn.model)",
            output: .object(["model": .string(turn.model), "reply": .string(reply)])
        )
    }

    private func executeNotify(job: DueJob) async throws -> JobResult {
        let overdue = Date().timeIntervalSince1970 - job.dueEpoch
        if overdue > 2 * 60 * 60 {
            return JobResult(
                status: "skipped",
                detail: "missed notification delivery window by \(overdue / 60) minute(s)",
                output: .object(["overdueSeconds": .double(overdue)])
            )
        }

        let title = NativeAgentNotificationDefaults.title(string(job.payload["title"]), dataRoot: root)
        let message = string(job.payload["message"]) ?? string(job.payload["body"]) ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentScheduler", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "schedule_message_missing: Scheduled Desk task has no notification text. Set payload.message through schedule.update."
            ])
        }

        let channels = try SchedulerJobNormalizer.deliveryChannels(job.payload)
        var delivered: [String] = []
        var errors: [String] = []
        var skipped: [String] = []
        for channel in channels {
            defer {
                notificationOutcomes[job.occurrenceKey] = .object([
                    "delivered": .array(delivered.map(JSONValue.string)),
                    "errors": .array(errors.map(JSONValue.string)),
                    "switchedOff": .array(skipped.map(JSONValue.string)),
                ])
            }
            try Task.checkCancellation()
            guard Date().timeIntervalSince1970 - job.dueEpoch <= 2 * 60 * 60 else {
                skipped.append(channel + ": notification delivery window expired")
                continue
            }
            let channelText = deliveryText(channel: channel, payload: job.payload, fallbackTitle: title, fallbackMessage: message)
            // A channel the person switched off is not delivered and not an
            // error: the job ran, this way out is closed. It is reported
            // separately from `delivered` so the run record never claims a
            // notification reached someone it did not.
            guard Self.channelIsSwitchedOn(channel) else {
                skipped.append(channel)
                continue
            }
            do {
                switch channel {
                case "mac":
                    let result = await platform.postNotification(
                        title: channelText.title,
                        body: channelText.message
                    )
                    if result.posted {
                        delivered.append(channel)
                    } else {
                        errors.append("\(channel): \(result.error ?? result.delivery)")
                    }
                case "push":
                    // Explicit push delivery stays pinned to the phone.
                    let outcome = try await platform.attentionRouter.route(
                        eventId: "scheduler:\(job.id):\(job.occurrenceKey)",
                        importance: .ownerWaiting,
                        title: channelText.title,
                        body: channelText.message,
                        userInfo: [
                            "screen": "inbox",
                            "source": "scheduler",
                            "jobId": job.id,
                            "occurrenceKey": job.occurrenceKey,
                        ],
                        pinnedTo: .phone
                    )
                    if outcome.deliveryProjection.reachedAChannel {
                        delivered.append(channel)
                    } else if outcome.deliveryProjection == .noChannel {
                        errors.append("\(channel): no notification channel is available; check phone notification setup")
                    } else {
                        errors.append("\(channel): notification was not delivered")
                    }
                case "telegram":
                    try await platform.sendTelegramMessage(message: channelText.message)
                    delivered.append(channel)
                case "inbox", "chat":
                    try await appendNotificationInbox(
                        title: channelText.title,
                        message: channelText.message,
                        source: string(job.payload["source"]) ?? "scheduled_job",
                        severity: channel == "chat" ? "important" : "info",
                        jobId: job.id,
                        itemId: Self.notificationItemId(job: job, channel: channel)
                    )
                    delivered.append(channel)
                case "activity":
                    try await appendActivity(
                        jobId: job.id,
                        title: channelText.title,
                        detail: channelText.message,
                        status: "ok",
                        payload: .object([
                            "jobId": .string(job.id),
                            "jobName": .string(job.name),
                            "deliveryChannel": .string("activity"),
                            "occurrenceKey": .string(job.occurrenceKey),
                        ])
                    )
                    delivered.append(channel)
                default:
                    errors.append("\(channel): unsupported delivery channel")
                }
            } catch is CancellationError {
                errors.append("\(channel): delivery unconfirmed after cancellation")
                throw CancellationError()
            } catch {
                errors.append("\(channel): \(error.localizedDescription)")
                try Task.checkCancellation()
            }
        }

        let status = delivered.isEmpty ? (errors.isEmpty ? "skipped" : "error") : (errors.isEmpty ? "completed" : "warn")
        var detail = !errors.isEmpty
            ? "notification_delivery_failed: confirmed delivered: \(delivered.isEmpty ? "none" : delivered.joined(separator: ",")); failed or unconfirmed: \(errors.joined(separator: "; ")). Inspect these channel receipts before resuming this scheduled Desk task."
            : delivered.isEmpty ? "notification_channels_off: No notification was delivered. Enable a chosen channel in Notifications settings for future scheduled Desk task notices."
            : "delivered via \(delivered.joined(separator: ","))"
        if !skipped.isEmpty {
            detail += "; switched off: \(skipped.joined(separator: ","))"
        }
        return JobResult(
            status: status,
            detail: detail,
            output: .object([
                "delivered": .array(delivered.map { .string($0) }),
                "errors": .array(errors.map { .string($0) }),
                "switchedOff": .array(skipped.map { .string($0) }),
            ])
        )
    }

    /// The person's delivery switches, for the channels a scheduled job can
    /// name. Records — the inbox card, the activity row — are NOT switchable:
    /// they are how the app remembers a thing happened, not a way it reaches
    /// out. Only the channels that actually interrupt someone are.
    static func channelIsSwitchedOn(_ channel: String) -> Bool {
        switch channel {
        case "mac": return NotificationChannelPreference.inApp()
        case "push": return NotificationChannelPreference.push()
        case "telegram": return NotificationChannelPreference.telegram()
        default: return true
        }
    }

    private func executeConnectorAction(job: DueJob) async throws -> JobResult {
        let actionId = string(job.payload["actionId"]) ?? string(job.payload["action_id"]) ?? ""
        guard !actionId.isEmpty else {
            throw NSError(domain: "NativeAgentScheduler", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "schedule_action_missing: Scheduled read has no action to read. Set payload.actionId through schedule.update."
            ])
        }
        let input: [String: JSONValue]
        if case .object(let obj)? = job.payload["input"] { input = obj } else { input = [:] }
        let read = try await platform.read(action: actionId, input: input)
        let watched = try await Self.watch(job: job, actionId: actionId, output: read)
        return JobResult(
            status: "completed",
            detail: "\(actionId) read; \(watched.fresh) new since the last read",
            output: .object(["actionId": .string(actionId), "newRows": .int(Int64(watched.fresh))]),
            seen: watched.seen
        )
    }

    /// Every scheduled read is a watch, below the model. Its rows (the objects in
    /// the result's arrays) are compared with the ones its last read kept on the job;
    /// the rows new since then are posted as one news from this job, so the next
    /// replaces it on the board. A row is known by its identifier fields (id, …Id,
    /// …_id) when it has them, else by its digest. The first read only keeps what
    /// it saw; a read that did not complete keeps nothing, so the last stays.
    /// The rows are what the read returned, under the door's receipt (`result`):
    /// a part's own answer (`returned`), never its runner's ledger of calls. A read whose
    /// `returned` is only a count (Dream Diary, Studio) keeps its rows beside it.
    static func watch(job: DueJob, actionId: String, output: JSONValue) async throws -> (seen: [String], fresh: Int) {
        var payload = output
        if case .object(let receipt) = payload, receipt["action"] != nil, let result = receipt["result"] { payload = result }
        if case .object(var read) = payload {
            // The door's receipt cannot turn an absent observation into content.
            for key in ["calls", "changed", "read_only", "irreversible", "effect"] { read[key] = nil }
            if case .string? = read["execution"] { read["execution"] = nil }
            if let returned = read["returned"] {
                // Some parts return a count and expose their content beside it.
                read["returned"] = nil
                let collections = read.filter { if case .array = $0.value { return true }; return false }
                switch returned {
                case .int, .double: payload = collections.isEmpty ? returned : .object(collections)
                default: payload = returned
                }
            } else {
                if read["ok"] != nil || Set(read.keys) == ["status"] {
                    read["ok"] = nil; read["status"] = nil
                }
                payload = .object(read)
            }
        }
        func project(_ value: JSONValue, collectionRoot: Bool = true) throws -> [[String: JSONValue]] {
            switch value {
            case .null:
                throw NSError(domain: "NativeAgentScheduler", code: -412, userInfo: [
                    NSLocalizedDescriptionKey: "watch_shape_unsupported: the read returned no observable content; the previous baseline is retained."
                ])
            case .array(let values):
                return try values.flatMap { try project($0, collectionRoot: false) }
            case .object(let fields):
                // Receipt status is not observed content. Nested detail (including
                // a screen's controls) stays in the observation, not an empty row.
                guard !fields.isEmpty else { return try project(.null) }
                let arrays = fields.keys.sorted().compactMap { key -> [JSONValue]? in
                    if case .array(let values)? = fields[key] { return values }; return nil
                }
                if collectionRoot, !arrays.isEmpty {
                    let siblings = fields.filter { if case .array = $0.value { return false }; return true }
                    let rows = try arrays.flatMap { try $0.flatMap { try project($0, collectionRoot: false) } }
                    return (siblings.isEmpty ? [] : [siblings]) + rows
                }
                return [fields]
            default: return [["value": value]]
            }
        }
        let rows = try project(payload)
        func identifier(_ key: String) -> Bool { key == "id" || key.hasSuffix("Id") || key.hasSuffix("_id") || key.hasSuffix("ID") }
        let keys = rows.map { row in
            let ids = row.filter { identifier($0.key) }
            return JSONValue.object(ids.isEmpty ? row : ids).digest
        }
        guard let last = job.row.objectValue?["lastSeen"]?.arrayValue else { return (keys, 0) }
        var seen = Set(last.compactMap(\.stringValue))
        let fresh = rows.indices.filter { seen.insert(keys[$0]).inserted }
        guard let firstFresh = fresh.first else { return (keys, 0) }
        // Agreement among rows does not make their meaningful content irrelevant.
        let shared = rows[firstFresh].filter { key, value in
            !identifier(key) && fresh.count > 1 && fresh.allSatisfy { rows[$0][key] == value }
        }
        func content(_ row: [String: JSONValue]) -> String {
            row.keys.sorted().compactMap { key -> String? in
                guard !identifier(key), let value = row[key] else { return nil }
                let text = value.scalarText.flatMap { $0.isEmpty ? nil : $0 }
                return "\(key): \(text ?? String(describing: value))"
            }.joined(separator: ", ")
        }
        let lines = fresh.prefix(5).map { index in
            let line = content(rows[index].filter { shared[$0.key] == nil })
            return line.isEmpty ? "distinct observation \(index + 1)" : line
        }
        let context = shared.isEmpty ? "" : "Shared context: \(content(shared))\n"
        let more = fresh.count > 5 ? "\nand \(fresh.count - 5) more; \(actionId) reads them all." : ""
        let accepted = await SenseNewsBoard.shared.post(SenseNews(senseID: actionId, version: 1,
            address: "\(job.name) (scheduled \(job.id))",
            summary: "\(fresh.count) new since the last read:\n" + context + lines.map { "• " + $0 }.joined(separator: "\n") + more,
            at: Date(), observationID: job.id, changeID: fresh.map { keys[$0] }.joined(separator: ",")))
        guard accepted else {
            throw NSError(domain: "NativeAgentScheduler", code: -411, userInfo: [
                NSLocalizedDescriptionKey: "watch_news_not_saved: unread news was not durably accepted; the previous observation baseline is retained."
            ])
        }
        return (keys, fresh.count)
    }

    private static func notificationItemId(job: DueJob, channel: String) -> String {
        let raw = "\(job.occurrenceKey).\(channel)"
        let safe = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        return "scheduled-\(String(safe).prefix(180))"
    }

    private func executeDream(job: DueJob) async throws -> JobResult {
        let response: [String: Any]
        do {
            response = try await platform.runDream(force: false)
        } catch {
            if let disabledResult = Self.disabledDreamResult(for: error) {
                return disabledResult
            }
            // Named once here: what failed reading, by the field it names.
            throw NSError(domain: "SchedulerDueJobRunner", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The nightly dream (dream cycle) failed: " + JSONValue.describe(error)])
        }
        let entries = Self.anyInt(response["entriesWritten"])
        let sessions = Self.anyInt(response["sessionsProcessed"])
        let disabled = Self.anyBool(response["disabled"])
        let errors = Self.anyStringArray(response["errors"])
        let failedWithoutEntry = entries <= 0 && !errors.isEmpty
        let output = Self.jsonValue(from: response)

        if disabled {
            return JobResult(
                status: "skipped",
                detail: "dream cycle disabled",
                output: output
            )
        }

        // The in-flight pass owns its work; this occurrence remains owed.
        if (response["skipReason"] as? String) == "already_running" {
            let retryObj = Self.object(output)
            return JobResult(
                status: "skipped",
                detail: "another dream run holds the reservation; its work is still running",
                output: .object(retryObj)
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
        let title = failedWithoutEntry ? "\(agentName) dream needs repair" : "\(agentName) dreamed"
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
            relatedPaths: paths,
            presentation: Self.dreamCardPresentation
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
        }
        return JobResult(
            status: failedWithoutEntry ? "error" : (errors.isEmpty ? "completed" : "warn"),
            detail: failedWithoutEntry
                ? "dream pass failed before writing; repair remains owed"
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
        // Scheduled REM honors the weekly claim to avoid duplicate proposals.
        let response = try await platform.runRem(force: false)
        let proposals = Self.anyInt(response["proposalsGenerated"])
        let archived = Self.anyInt(response["archivedEntries"])
        let tombstones = Self.anyInt(response["tombstoneSkips"])
        let evicted = Self.anyBool(response["growthMDEvicted"])
        let output = Self.jsonValue(from: response)

        // Reservation loss is not a completed pass.
        if (response["skipReason"] as? String) == "already_running" {
            let retryObj = Self.object(output)
            return JobResult(
                status: "skipped",
                detail: "another REM pass holds the reservation; its work is still running",
                output: .object(retryObj)
            )
        }

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
            // This card is a receipt; each proposal has its own rem.proposal approval.
            severity: "info",
            jobId: job.id,
            itemId: itemId,
            relatedPaths: paths,
            presentation: Self.remCardPresentation
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
