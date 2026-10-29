import Foundation
import NativeAgentShared
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution
// Blueprint: | `TriggerInboxPublication.swift` | SwiftNativeTriggerScheduler inbox preparation, locked durable acceptance, notification delivery and activity receipts |

extension SwiftNativeTriggerScheduler {
    // MARK: fire_now — Swift-native

    /// Accept the inbox card durably before asking the host to deliver it.
    public func fireInboxTrigger(name: String) async throws -> TriggerFireResult {
        let prepared = try await prepareInboxTrigger(name: name)
        return await publishInboxTrigger(name: name, occurrence: nil, prepared: prepared)
    }

    internal enum InboxPreparation: Sendable {
        case ready(row: TriggerConfig, notify: [String: Bool], item: JSONValue)
        case refused(TriggerFireResult)
    }

    /// JavaScript and its model run before taking any publication/state lock.
    internal func prepareInboxTrigger(name: String) async throws -> InboxPreparation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }
        guard inboxMasterOn else {
            return .refused(TriggerFireResult(
                status: "disabled", name: name, stub: true,
                error: "Raising things unasked is off (Notifications), so no trigger fires."
            ))
        }
        try await migrateLegacyInboxTriggerFilesIfNeeded()

        // Look up the trigger row.
        let configs: [TriggerConfig]
        let seed: MorningBriefDefaults
        do {
            seed = try await defaults()
            configs = try await Self._readList(
                path: inboxPath,
                defaultValue: seed.inbox, inbox: true
            )
        } catch {
            return .refused(TriggerFireResult(status: "error", name: name, stub: true,
                                     error: String(describing: error)))
        }
        guard let row = configs.first(where: { ExecutionEventVocabulary.matches($0.name, name) }) else {
            return .refused(TriggerFireResult(status: "not_found", name: name, stub: true))
        }

        do { return .ready(row: row, notify: seed.notify, item: try await _buildMorningBriefItem()) }
        catch { return .refused(TriggerFireResult(status: "error", name: name, stub: true, error: String(describing: error))) }
    }

    /// Native publication rechecks authority and owns the one delivery record.
    internal func publishInboxTrigger(name: String, occurrence: String?, prepared: InboxPreparation) async -> TriggerFireResult {
        let row: TriggerConfig, notify: [String: Bool]
        var item: JSONValue
        switch prepared {
        case .refused(let result): return result
        case .ready(let selected, let defaults, let proposal): row = selected; notify = defaults; item = proposal
        }
        let rowKind = "time"
        do {
            try Task.checkCancellation()
            if let occurrence, case .object(var fields) = item {
                fields["trigger_occurrence"] = .string(occurrence)
                item = .object(fields)
            }
            guard inboxMasterOn else {
                return TriggerFireResult(
                    status: "disabled", name: name, stub: true,
                    error: "Raising things unasked is off (Notifications), so no trigger fires."
                )
            }
            let note = Self.notification(for: item, name: name, kind: rowKind)
            let shouldNotify = Self.resolveNotify(row, defaults: notify)
            let prior = try await TriggerNotificationInbox.accept(note, notify: shouldNotify, dataRoot: root)
            let id = prior ?? note.itemId
            let deduped = prior != nil

            var notified = false
            var delivery: JSONValue = .null
            var status = "ok"
            var detail = "trigger '\(name)' fired — inbox item \(id)"

            if deduped {
                detail += "; suppressed as a duplicate of an active inbox item — no push"
            } else {
                if let notifier {
                    delivery = await notifier(note, shouldNotify)
                    notified = shouldNotify && delivery != .null
                    if delivery == .null {
                        // The sender reported failure. Say so on the record
                        // rather than logging "ok".
                        status = "warn"
                        detail += "; card saved but delivery reported failure"
                    } else if case .object(let d) = delivery {
                        if d["delivery"] == .string("failed") || d["status"] == .string("failed") {
                            status = "warn"
                            detail += "; card saved but notification delivery failed"
                        } else if d["deduped_against"] != nil || d["delivery"] == .string("previously_handled") {
                            detail += "; notification already handled — no new push"
                        } else if d["delivery"] == .string("deferred") {
                            detail += "; notification deferred for quiet hours"
                        } else if d["delivery"] == .string("no_channel") {
                            detail += "; no notification channel selected"
                        } else if d["delivered"] == .bool(false) {
                            detail += "; card saved; notification not delivered"
                        } else {
                            detail += "; notification accepted or queued for delivery"
                        }
                    } else {
                        detail += "; notifier handled the notification"
                    }
                } else if shouldNotify {
                    Self.logger.error("trigger '\(name, privacy: .public)' resolved notify=true but NO notifier was injected into this scheduler — the inbox item landed, the push did NOT")
                    status = "warn"
                    detail += "; notify requested but no notifier wired — push NOT dispatched"
                }
                if !shouldNotify { detail += "; notify disabled for this trigger — no push" }
            }

            await appendTriggerEvent(
                item: item, itemId: id, name: name, kind: rowKind,
                notified: notified, placeholder: false, deduped: deduped,
                delivery: delivery, status: status, detail: detail
            )

            return TriggerFireResult(
                status: "fired", name: name, itemId: id, stub: false,
                item: deduped ? nil : item, notified: notified
            )
        } catch {
            return TriggerFireResult(status: "error", name: name, stub: true,
                                     error: String(describing: error))
        }
    }

    // MARK: notify resolution

    /// Saved consent overrides the part's proposed notification preference.
    nonisolated static func resolveNotify(_ cfg: TriggerConfig, defaults: [String: Bool]) -> Bool {
        if case .object(let o)? = cfg.config, case .bool(let b)? = o["notify"] {
            return b
        }
        return defaults[cfg.name] ?? false
    }

    private nonisolated static func notification(
        for item: JSONValue, name: String, kind: String
    ) -> TriggerNotification {
        var title = name
        var summary = ""
        var severity = "info"
        if case .object(let o) = item {
            if case .string(let s)? = o["title"] { title = s }
            if case .string(let s)? = o["summary"] { summary = s }
            if case .string(let s)? = o["severity"] { severity = s }
        }
        // A push body is a glance, not a document.
        let body = summary.count > 240 ? String(summary.prefix(239)) + "…" : summary
        var itemId = ""
        if case .object(let o) = item, case .string(let s)? = o["id"] { itemId = s }
        return TriggerNotification(
            triggerName: name,
            kind: kind,
            title: title,
            body: body,
            screen: "inbox",
            source: "trigger:\(name)",
            urgency: severity == "important" ? "high" : "normal",
            itemId: itemId,
            item: item
        )
    }

    /// The delivery receipt. Written on EVERY fire — `notified: false` when the
    /// push was suppressed, `status: "warn"` when it was requested but
    /// unwireable. Matches the activity envelope
    /// (`PersonaEngine.makePersonaActivityEvent`):
    /// `{id, kind, title, detail, status, missionId, payload, createdAt}`.
    /// Best-effort: a failed receipt write is logged, never thrown — the item
    /// already landed and un-firing it would be worse.
    private func appendTriggerEvent(
        item: JSONValue, itemId: String, name: String, kind: String,
        notified: Bool, placeholder: Bool, deduped: Bool, delivery: JSONValue,
        status: String, detail: String
    ) async {
        var title = name
        if case .object(let o) = item, case .string(let s)? = o["title"] { title = s }

        var payload: [String: JSONValue] = [
            "triggerName": .string(name),
            "triggerKind": .string(kind),
            "itemId": .string(itemId),
            "notified": .bool(notified),
            "placeholder": .bool(placeholder),
        ]
        if deduped { payload["deduped"] = .bool(true) }
        if delivery != .null { payload["delivery"] = delivery }

        let event = SwiftNativePersistenceCore.activityEvent(
            id: uuid(),
            kind: "trigger",
            title: title,
            detail: detail,
            status: status,
            executionId: nil,
            payload: .object(payload),
            createdAt: Self.isoTimestamp(now())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(
                event, to: activityFeedPath, logLabel: "TriggerScheduler"
            )
        } catch {
            Self.logger.error("trigger '\(name, privacy: .public)' fired but its activity receipt FAILED to write: \(String(describing: error), privacy: .public)")
        }
    }

}
