import AuthoredCapabilities
import Foundation
import Experiences
import AttentionRouting
import DeviceSync
import DreamREMCycle
import NativeAgentCore
import NativeAgentShared
import Senses
import PersistenceCore
import Privacy
import TriggerScheduler
// Blueprint: | `ClockWork.swift` | `ClockWork`: what the one clock's dream, REM, watch and scan deliveries tell; one dream matter shared with manual dreams |

/// The work behind the one clock's body times. The clock owns when; this owns what each delivery leaves behind: the dream's matter (shared with a dream
/// run by hand), the weekly REM card, a watch's news and a scan's opportunity cards.
public struct ClockWork: Sendable {
    struct DreamDiarySnippet: Sendable {
        let path: String
        let title: String
        let summary: String
    }

    let root: URL
    let attentionRouter: @Sendable () -> AttentionRouter

    public init(root: URL, attentionRouter: @escaping @Sendable () -> AttentionRouter) {
        self.root = root
        self.attentionRouter = attentionRouter
    }

    // MARK: - The dream

    /// The shared engine calls this once after a real dream, scheduled or by hand: it files the dream's one matter and puts older ones away.
    public func surfaceDreamResult(_ output: JSONValue) async throws -> JSONValue {
        let row = try JSONRow(output)
        guard let entries = try row.optionalInt("entriesWritten"), let sessions = try row.optionalInt("sessionsProcessed"),
              let disabled = try row.optionalBool("disabled") else { throw JSONRow.Malformed.field("dream result") }
        var errors = try row.strings("errors")
        guard !disabled, try row.optionalString("skipReason") != "already_running",
              entries > 0 || !errors.isEmpty else { return .object([:]) }
        let failedWithoutEntry = entries <= 0 && !errors.isEmpty
        guard let dateKey = try row.optionalString("entryDate") else {
            throw PersistenceCoreError.ioFailure("The dream result has no entry date; its presentation remains owed.")
        }
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
        let message = Self.dreamInboxMessage(entriesWritten: entries, sessionsProcessed: sessions, errors: errors, entries: entriesForToday)
        let itemId = "dream-cycle-\(dateKey)-\(UUID().uuidString.lowercased())"
        let delivery = try await tell(Matter(id: itemId, form: failedWithoutEntry ? .wentWrong : .done,
            from: "dream_cycle", title: title, summary: String(message.prefix(500)), words: message,
            symbol: "moon.stars.fill", badge: "DREAM", artifacts: paths.map { .init(source: Matter.files, id: $0) }))
        let archivedDreamCards = try await archiveOlderDreamInboxItems(keeping: itemId)
        var receipt: [String: JSONValue] = [
            "inboxItemId": .string(itemId), "archivedOlderDreamInboxItems": .int(Int64(archivedDreamCards)), "delivery": delivery
        ]
        if failedWithoutEntry { receipt["failureKind"] = .string("dream_failed_before_write") }
        return .object(receipt)
    }

    // MARK: - REM

    /// The weekly REM pass's result (`NativeAgentEngine.runRem` with force false): a completed pass with proposals files one card; a skipped pass or one
    /// with none says so in its receipt only. A pass that neither completed nor skipped throws.
    public func surfaceREMResult(_ response: [String: Any]) async throws -> JSONValue {
        let output: JSONValue = .object(try NativeActionWire.jsonValueBody(response))
        guard let rawOutcome = response["outcome"] as? String, let outcome = REMRunReportPayload.Outcome(rawValue: rawOutcome) else {
            throw PersistenceCoreError.ioFailure("REM returned no typed outcome; completion is unavailable.")
        }
        if outcome == .skipped {
            guard let reason = response["skipReason"] as? String, !reason.isEmpty else {
                throw PersistenceCoreError.ioFailure("REM skipped without its reason; completion is unavailable.")
            }
            return output
        }
        guard outcome == .completed else { throw PersistenceCoreError.ioFailure("REM did not complete: \(rawOutcome)") }
        let completion = try REMRunReportPayload.validatedManualCompletion(response: response).get()
        guard completion.proposals > 0 else { return output }
        let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
        let message = Self.remInboxMessage(proposalsGenerated: completion.proposals, archivedEntries: completion.archivedEntries,
            tombstoneSkips: Self.anyInt(response["tombstoneSkips"]), growthMDEvicted: Self.anyBool(response["growthMDEvicted"]))
        let itemId = "rem-cycle-\(DreamREMSchedule.todayKey())-\(UUID().uuidString.lowercased())"
        let delivery = try await tell(Matter(id: itemId, form: .done, from: "rem_cycle", title: "\(agentName) REM cycle",
            summary: String(message.prefix(500)), words: message, symbol: "sparkles", badge: "REM",
            artifacts: Self.remRelatedPaths(dataRoot: root).map { .init(source: Matter.files, id: $0) }))
        var receipt = output.objectValue ?? [:]
        receipt["inboxItemId"] = .string(itemId)
        receipt["delivery"] = delivery
        return .object(receipt)
    }

    // MARK: - A watch

    /// One read of a watch. Rows are keyed by their ids (or their whole content); the first read only sets the baseline, and later reads post the rows
    /// new since the last one as news. Returns every key this read saw, for the watch to keep, and how many were new. A read whose content cannot be
    /// observed, or news the board did not accept, throws and keeps the last baseline.
    public static func watch(id: String, name: String, actionId: String, seen last: [String]?, output: JSONValue) async throws -> (seen: [String], fresh: Int) {
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
        guard let last else { return (keys, 0) }
        var seen = Set(last)
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
            address: "\(name) (scheduled \(id))",
            summary: "\(fresh.count) new since the last read:\n" + context + lines.map { "• " + $0 }.joined(separator: "\n") + more,
            at: Date(), observationID: id, changeID: fresh.map { keys[$0] }.joined(separator: ",")))
        guard accepted else {
            try Task.checkCancellation()
            throw NSError(domain: "NativeAgentScheduler", code: -411, userInfo: [
                NSLocalizedDescriptionKey: "watch_news_not_saved: unread news was not durably accepted; the previous observation baseline is retained."
            ])
        }
        return (keys, fresh.count)
    }

    // MARK: - A proactive scan

    /// One scan: each opportunity it surfaces is one card to the person, referring to its source experiences. Returns the cards' ids.
    public func scan(payload: [String: JSONValue]) async throws -> [String] {
        let scan = try await NativeAgentScheduledProactiveScan.evaluate(dataRoot: root, payload: payload)
        var itemIds: [String] = []
        for opportunity in scan.surfaced {
            let itemId = "proactive-\(UUID().uuidString.lowercased())"
            let actions = try NativeAgentScheduledProactiveScan.inboxActions(for: opportunity).map { value -> PartFace.Action in
                let row = try JSONRow(value)
                return .init(id: try row.string("id"), label: try row.string("label"))
            }
            try await tell(Matter(id: itemId,
                form: opportunity.severity == "actionable" ? .ask : .words, from: opportunity.source,
                title: opportunity.title, summary: opportunity.summary, words: opportunity.detail, choices: actions,
                evidence: opportunity.relatedMatters.map { .init(source: "experiences/experiences.sqlite", id: $0) },
                artifacts: opportunity.relatedPaths.map { .init(source: Matter.files, id: $0) }))
            itemIds.append(itemId)
        }
        return itemIds
    }

    // MARK: - Telling

    /// One matter to the person, bounded and redacted; the receipt names each door's verdict.
    @discardableResult
    func tell(_ matter: Matter) async throws -> JSONValue {
        let face = Matter(id: matter.id, form: matter.form, from: matter.from,
            title: NativeAppSecretRedactor.redactText(String(matter.title.prefix(160))),
            summary: NativeAppSecretRedactor.redactText(String(matter.summary.prefix(500))),
            words: NativeAppSecretRedactor.redactText(String(matter.words.prefix(2000))), symbol: matter.symbol,
            badge: matter.badge, open: matter.open, choices: matter.choices, evidence: matter.evidence, artifacts: matter.artifacts)
        let outcome = try await attentionRouter().tell(face, reach: .person(from: nil), turn: nil)
        var delivered: [JSONValue] = [], errors: [JSONValue] = [], pending: [JSONValue] = []
        for (door, verdict) in outcome.destinationOutcomes.sorted(by: { $0.key < $1.key }) {
            switch verdict {
            case .delivered: delivered.append(.string(door))
            case .deferred: pending.append(.string(door + ": deferred"))
            case .notDelivered(let reason): errors.append(.string(door + ": " + reason))
            case .unknown(_, let reason): pending.append(.string(door + ": " + reason))
            case .suppressed(let preference): pending.append(.string(door + ": suppressed by " + preference))
            }
        }
        var fields: [String: JSONValue] = ["delivered": .array(delivered), "errors": .array(errors),
                                         "not_delivered": .array(pending), "destinations": .object(outcome.destinationFields)]
        if let held = outcome.deferredFields { fields.merge(held.filter { $0.key != "delivered" }) { _, new in new } }
        return .object(fields)
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
}
