import AuthoredCapabilities
import Foundation
import Experiences
import AttentionRouting
import DreamREMCycle
import NativeAgentCore
import Senses
import PersistenceCore
import TelegramBot
import TriggerScheduler
import DeviceSync
// Blueprint: | `SchedulerDueJobRunner+Execution.swift` | Shared dream matters and REM receipts; due jobs consume the same recorded result |

extension SchedulerDueJobRunner {
    func execute(job: DueJob) async throws -> JobResult {
        try Task.checkCancellation()
        guard let kind = JobKind(rawValue: job.kind) else {
            throw NSError(domain: "NativeAgentScheduler", code: -410, userInfo: [
                NSLocalizedDescriptionKey: """
                    schedule_kind_unsupported: Scheduled Desk task kind '\(job.kind)' is unsupported. Set a supported kind and its complete payload through \
                    schedule.update.
                    """
            ])
        }
        guard isLiveDataRoot else {
            throw NSError(domain: "NativeAgentScheduler", code: -403, userInfo: [
                NSLocalizedDescriptionKey:
                    """
                        schedule_root_not_live: Scheduled effects are refused for \(root.path). In NativeAgent's running app, use queue.add for intentions or \
                        schedule.create for body rhythms in its active data folder.
                        """
            ])
        }
        switch kind {
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
            // The deadline only fires the signal; the run is the stem's, on its own gate chain. Fires that land while the part's run still waits are one news.
            // Posting is all this job knows: the run's outcome is the ability's own record, never claimed here.
            let part = string(job.payload["part"]) ?? "", signal = string(job.payload["signal"]) ?? ""
            AbilityStore(dataRoot: root).signal(signal, part: part)
            return JobResult(status: "completed", detail: "\(signal) posted for \(part); its run is recorded on the ability: app ability.read {id:\"\(part)\"}",
                             output: .object(["part": .string(part), "delivery": .string("posted")]))
        }
    }

    private func executeConnectorAction(job: DueJob) async throws -> JobResult {
        let actionId = string(job.payload["actionId"]) ?? ""
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

    /// Keep observed rows on the job so only new content posts news; the job identity makes later news replace it on the board. Row IDs take precedence
    /// over digests. The first read establishes a baseline; an incomplete read preserves the last baseline. Observe the part's returned content, never
    /// its call ledger; count-only answers keep their content beside the count.
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
                // Receipt status is not observed content. Nested detail (including a screen's controls) stays in the observation, not an empty row.
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
        let keys = try rows.map { row in
            let ids = row.filter { identifier($0.key) }
            return try JSONValue.object(ids.isEmpty ? row : ids).digest
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
            try Task.checkCancellation()
            throw NSError(domain: "NativeAgentScheduler", code: -411, userInfo: [
                NSLocalizedDescriptionKey: "watch_news_not_saved: unread news was not durably accepted; the previous observation baseline is retained."
            ])
        }
        return (keys, fresh.count)
    }

    private func executeDream(job: DueJob) async throws -> JobResult {
        let response: [String: Any]
        do {
            response = try await platform.runDream(force: false)
        } catch {
            if let disabledResult = Self.disabledDreamResult(for: error) {
                return disabledResult
            }
            throw NSError(domain: "SchedulerDueJobRunner", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The nightly dream (dream cycle) failed: " + JSONValue.describe(error)])
        }
        let entries = Self.anyInt(response["entriesWritten"])
        let disabled = Self.anyBool(response["disabled"])
        let errors = Self.anyStringArray(response["errors"])
        let failedWithoutEntry = entries <= 0 && !errors.isEmpty
        let output: JSONValue = .object(try NativeActionWire.jsonValueBody(response))

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

        return JobResult(status: failedWithoutEntry ? "error" : errors.isEmpty ? "completed" : "warn",
            detail: failedWithoutEntry ? "dream failed before writing; repair remains owed" : "dream result and its matter retained",
            output: output)
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

    /// The shared engine calls this once after a real dream; the scheduler consumes its receipt without filing another matter.
    public func surfaceDreamResult(_ output: JSONValue) async throws -> JSONValue {
        let row = try JSONRow(output)
        guard let entries = try row.optionalInt("entriesWritten"), let sessions = try row.optionalInt("sessionsProcessed"),
              let disabled = try row.optionalBool("disabled") else { throw JSONRow.Malformed.field("dream result") }
        var errors = try row.strings("errors")
        guard !disabled, try row.optionalString("skipReason") != "already_running",
              entries > 0 || !errors.isEmpty else { return .object([:]) }
        let failedWithoutEntry = entries <= 0 && !errors.isEmpty
        let dateKey = NativeAgentDreamCycleSchedule.dreamEntryDateKey(Date())
        let entriesForToday: [DreamDiarySnippet]
        do { entriesForToday = try Self.dreamEntriesForToday(dataRoot: root, dateKey: dateKey) }
        catch {
            // The cycle already ran. Keep its result and name the separate presentation failure; never rerun a dream to reconstruct a card.
            entriesForToday = []
            errors.append("The dream result is retained, but its diary presentation is unavailable: \(error.localizedDescription)")
        }
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
        let delivery = try await tellScheduledMatter(Matter(id: itemId, form: failedWithoutEntry ? .wentWrong : .done,
            from: "dream_cycle", title: title, summary: String(message.prefix(500)), words: message,
            symbol: "moon.stars.fill", badge: "DREAM", artifacts: paths.map { .init(source: Matter.files, id: $0) }),
            reach: .person(from: nil))
        let archivedDreamCards = try await archiveOlderDreamInboxItems(keeping: itemId)

        var receipt: [String: JSONValue] = [
            "inboxItemId": .string(itemId), "archivedOlderDreamInboxItems": .int(Int64(archivedDreamCards)), "delivery": delivery
        ]
        if failedWithoutEntry { receipt["failureKind"] = .string("dream_failed_before_write") }
        return .object(receipt)
    }

    private func executeREM(job: DueJob) async throws -> JobResult {
        // Scheduled REM honors the weekly claim to avoid duplicate proposals.
        let response = try await platform.runRem(force: false)
        let output: JSONValue = .object(try NativeActionWire.jsonValueBody(response))
        guard let rawOutcome = response["outcome"] as? String,
              let outcome = REMRunReportPayload.Outcome(rawValue: rawOutcome) else {
            throw PersistenceCoreError.ioFailure("REM returned no typed outcome; completion is unavailable.")
        }
        if outcome == .skipped {
            guard let reason = response["skipReason"] as? String, !reason.isEmpty else {
                throw PersistenceCoreError.ioFailure("REM skipped without its reason; completion is unavailable.")
            }
            return JobResult(
                status: "skipped",
                detail: "REM pass skipped: \(reason)",
                output: output
            )
        }
        guard outcome == .completed else {
            throw PersistenceCoreError.ioFailure("REM did not complete: \(rawOutcome)")
        }
        let completion = try REMRunReportPayload.validatedManualCompletion(response: response).get()
        let proposals = completion.proposals
        let archived = completion.archivedEntries
        let tombstones = Self.anyInt(response["tombstoneSkips"])
        let evicted = Self.anyBool(response["growthMDEvicted"])

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
        let delivery = try await tellScheduledMatter(Matter(id: itemId, form: .done, from: "rem_cycle",
            title: title, summary: String(message.prefix(500)), words: message, symbol: "sparkles", badge: "REM",
            artifacts: paths.map { .init(source: Matter.files, id: $0) }), reach: .person(from: nil))
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
